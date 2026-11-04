extends "res://game/net/playground_net_bridge_base.gd"


## Builds the inventory's half of the wire, when the game has an inventory.
## Through [method _tell], never [method _broadcast]: [PlaygroundInventoryNet] can reach ONE peer only.
func _attach_inventory() -> void:
	if game.inventory == null:
		return

	inventory_net = PlaygroundInventoryNet.new()
	inventory_net.name = "Inventory"
	add_child(inventory_net)

	if net.is_server:
		inventory_net.bind_server(game.inventory)
		inventory_net.tell_fn = func(peer_id: int, body: PackedByteArray) -> void:
			_tell(peer_id, PlaygroundEvents.Kind.INVENTORY, body)
		inventory_net.notice_fn = func(peer_id: int, text: String) -> void:
			_tell(peer_id, PlaygroundEvents.Kind.NOTICE,
				PlaygroundEvents.write_notice(player_for_peer(peer_id), text))
		inventory_net.charge_fn = _charge
		inventory_net.bag_key_fn = inventory_key_fn
	else:
		inventory_net.bind_client(game.inventory)
		inventory_net.ask_fn = func(body: PackedByteArray) -> void:
			_ask(PlaygroundEvents.Ask.INVENTORY, body)
		inventory_net.refused.connect(func(reason: String) -> void:
			inventory_refused.emit(reason))


## Re-dresses a player whose avatar changed after they joined, and tells everybody.
func refresh_skins(session_id: int) -> void:
	if net == null or not net.is_server or not skin_fn.is_valid():
		return
	var player: PlaygroundPlayer = game.players.get(_player_key(session_id))
	var dressed: Variant = skin_fn.call(session_id)
	if player == null or not (dressed is PackedInt32Array) or (dressed as PackedInt32Array) == player.skins:
		return
	player.set_skins(dressed)
	_broadcast(PlaygroundEvents.Kind.JOIN, _join_body(session_id))


func add_player(
	peer_id: int, session_id: int, display_name: String, record_key: StringName = &""
) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var id := _player_key(session_id)

	if peer_id > 0:
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	# add_player emits player_added, which _on_player_added answers by building the
	# entity and announcing the JOIN. The peer mapping is set FIRST so that handler
	# can find the peer this player belongs to.
	var player := game.add_player(id, display_name, record_key)

	if player == null:
		_player_of_peer.erase(peer_id)
		_peer_of_player.erase(session_id)
		return DotResult.fail(DotError.CODE_STATE, "The game refused the player.")

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		_admit(peer_id)

	return DotResult.success(player)


## A player the game made itself — a bot, a test — gets an entity exactly like one a
## peer asked for. Its peer id is zero, and that is not the broadcast address by
## accident: [method _tell] refuses zero, because `net.send(msg, 0)` IS a broadcast and
## game-hungario once sent every player's private message to everybody through exactly
## this hole.
func _on_player_added(id: StringName) -> void:
	if net == null or not net.is_server:
		return

	var session_id := session_of(id)

	if _behaviours.has(session_id):
		return

	var player: PlaygroundPlayer = game.players.get(id)
	if player == null:
		return

	# Dressed before the JOIN that describes them goes out, so nobody sees the stock look
	# first and the member's own a moment later.
	if skin_fn.is_valid():
		var dressed: Variant = skin_fn.call(session_id)
		if dressed is PackedInt32Array:
			player.set_skins(dressed)

	var identity := _build_entity(player, peer_for_player(session_id))
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a player", {"error": str(registered.error)})
		return

	_broadcast(PlaygroundEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)


func _on_player_removed(id: StringName) -> void:
	var session_id := session_of(id)
	if _behaviours.has(session_id):
		# The game removed it itself; the entity and the LEAVE are still ours.
		_release_entity(session_id)
		_broadcast(PlaygroundEvents.Kind.LEAVE, PlaygroundEvents.write_player(session_id))
		roster_changed.emit(session_id)


## Every prop the spawner creates becomes a replicated entity.
##
## [b]Announced reliably AND replicated by snapshot, and it needs both.[/b] The snapshot
## moves it; the event says what it is, because a client cannot build a barrel from a
## position. A spawner factory would have to name a script, and this game's props are
## named by PATH in the catalogue precisely so a dot-cloud pack can deliver them — a
## mounted pack's `class_name` globals are not registered in the host.
func _on_prop_spawned(prop: DotPropInstance) -> void:
	if net == null or not net.is_server or prop == null or prop.node == null:
		return

	var body := prop.node as Node3D
	if body == null:
		return

	# A vehicle replicates through DotVehicleNetSync — its wheels' angle and which seats
	# are full cannot be derived from a position — so which behaviour a body gets is
	# decided by the catalogue, once, here. The table below is the same on both ends and
	# `_apply_prop` reads it the same way.
	var behaviour := _behaviour_for(prop.def)
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var as_vehicle := behaviour as PlaygroundVehicleNet

	if as_vehicle != null and game.vehicles != null:
		as_vehicle.vehicle = game.vehicles.vehicle_for_node(body)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	# SERVER, not SHARED: nothing about a rigid body is predicted, so there is no owner
	# to share with. See PlaygroundPropNet for why that is a decision and not a gap.
	identity.authority = DotNetIdentity.Authority.SERVER
	body.add_child(identity)

	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a prop", {"error": str(registered.error)})
		return

	_prop_nets[prop.instance_id] = behaviour
	behaviour.net_id_of = net_id_of_node
	behaviour.pull()

	_broadcast(PlaygroundEvents.Kind.PROP, PlaygroundEvents.write_prop(
		identity.net_id,
		prop.def.id,
		session_of(prop.owner_id),
		PlaygroundSpawnables.kind_of(prop.def) == PlaygroundSpawnables.Kind.ENTITY,
		body.global_position
	))


# --- Server: wave NPCs ------------------------------------------------------

## Replicates everything [param spawner] spawns, as props are: a PROP event says what it is
## and a [PlaygroundPropNet] moves it. Called by the module once the waves exist.
##
## [b]Through the prop path, not a second one.[/b] A wave NPC was never replicated at all —
## a connected client saw the waves' effects (stress, the director's pacing, players going
## down) and not one NPC. What a client needs is a body where the server's is, which is
## exactly what the prop path already does for any body; its definition is found in
## [member npc_catalogue] when the prop catalogue does not have it.
func watch_npc_spawner(spawner: DotNpcSpawner, catalogue: DotNpcCatalogue) -> void:
	npc_catalogue = catalogue

	if spawner == null or net == null or not net.is_server:
		return

	spawner.spawned.connect(_on_npc_spawned)
	spawner.removed.connect(_on_npc_removed)
	# Before `removed`, while the body is there: how it falls, sent with the PROP_GONE.
	spawner.died.connect(func(npc: DotNpcInstance, by: StringName) -> void:
		var _fall := game.decide_npc_death(npc.node as Node3D, by, npc.def.max_health if npc.def != null else 0.0))


func _on_npc_spawned(npc: DotNpcInstance) -> void:
	var body := npc.node as Node3D

	if body == null or net == null or not net.is_server:
		return

	var behaviour := PlaygroundPropNet.new()
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	body.add_child(identity)

	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate an NPC", {"error": str(registered.error)})
		return

	_prop_nets[npc.instance_id] = behaviour
	_npc_kinds[npc.instance_id] = npc.def.id
	behaviour.net_id_of = net_id_of_node
	behaviour.pull()

	_broadcast(PlaygroundEvents.Kind.PROP, PlaygroundEvents.write_prop(
		identity.net_id, npc.def.id, 0, true, body.global_position
	))


func _on_npc_removed(npc: DotNpcInstance, reason: StringName) -> void:
	var behaviour: PlaygroundPropNet = _prop_nets.get(npc.instance_id)
	_prop_nets.erase(npc.instance_id)
	_npc_kinds.erase(npc.instance_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	var net_id := behaviour.identity.net_id
	net.registry.unregister(net_id)
	_broadcast(PlaygroundEvents.Kind.PROP_GONE, PlaygroundEvents.write_prop_gone(
		net_id, reason, _death_of(npc.node, reason)))


func _on_prop_removed(prop: DotPropInstance, reason: StringName) -> void:
	if net == null or not net.is_server or prop == null:
		return

	var behaviour: PlaygroundPropNet = _prop_nets.get(prop.instance_id)
	_prop_nets.erase(prop.instance_id)

	if behaviour == null or behaviour.identity == null:
		return

	var net_id := behaviour.identity.net_id
	net.registry.unregister(net_id)

	_broadcast(PlaygroundEvents.Kind.PROP_GONE, PlaygroundEvents.write_prop_gone(
		net_id, reason, _death_of(prop.node, reason)))


## A refusal goes to the one player who asked, not to everybody. A budget message is
## the most common thing this server says and it is nobody else's business.
func _on_prop_refused(player_id: StringName, prop_id: StringName, reason: String) -> void:
	var session_id := session_of(player_id)
	_tell(peer_for_player(session_id), PlaygroundEvents.Kind.NOTICE,
		PlaygroundEvents.write_notice(session_id, "Cannot spawn %s: %s" % [prop_id, reason]))


## Somebody's physics gun took hold of a prop or let go of one: everybody is told, so every
## client can draw the beam. Until 2026-10-07 `write_held`/`read_held` existed and nothing
## sent or read them, so a connected player saw nobody else's beam and not their own either.
func _on_held_changed(id: StringName, prop: DotPropInstance, held: bool) -> void:
	if net == null or not net.is_server:
		return
	var session := session_of(id)
	var net_id := net_id_of_node(prop.node) if held and prop != null and prop.node != null else 0
	if net_id > 0:
		held_props[session] = net_id
	else:
		held_props.erase(session)
	_broadcast(PlaygroundEvents.Kind.HELD, PlaygroundEvents.write_held(session, net_id, prop.frozen if prop != null else false))


## A pane broke on the server: everybody removes their own copy of it. The shards are props
## and travel as props; this is only the box, which every client built itself.
func _on_pane_broken(index: int, _at: Vector3, _material: StringName) -> void:
	if net == null or not net.is_server:
		return
	_broadcast(PlaygroundEvents.Kind.PANE, PlaygroundEvents.write_pane(index))


## Tells everybody that somebody got in or out.
##
## [b]Everybody, not just the rider.[/b] The other clients are the ones who have to stop
## drawing a player walking and start drawing them sitting in a car, and it is the same
## reasoning the occupancy mask already carries: a "get in" prompt over a full seat is a
## prompt that lies.
func announce_seat(
	vehicle: DotVehicleInstance, rider_id: StringName, seat: DotVehicleSeat, seated: bool
) -> void:
	if net == null or not net.is_server or vehicle == null:
		return

	var index := 0

	for i in vehicle.def.seats.size():
		if vehicle.def.seats[i].id == seat.id:
			index = i
			break

	_broadcast(PlaygroundEvents.Kind.SEAT, PlaygroundEvents.write_seat(
		session_of(rider_id), net_id_of_node(vehicle.node), index, seated
	))


# --- Server: the tick ------------------------------------------------------

func _admit(peer_id: int) -> void:
	if peer_id <= 0:
		return
	if not _player_of_peer.has(peer_id):
		_ready_unseated[peer_id] = true
		return

	var fresh := not _ready_peers.has(peer_id)
	_ready_peers[peer_id] = true
	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	var session_id := int(_player_of_peer[peer_id])

	_tell(peer_id, PlaygroundEvents.Kind.HELLO, PlaygroundEvents.write_hello(
		session_id, game.tick_rate, net.clock.tick,
		game.maps.current.id if game.maps.current != null else &""
	))

	for other in _behaviours.keys():
		_tell(peer_id, PlaygroundEvents.Kind.JOIN, _join_body(int(other)))

	# Who is being carried. A joiner who missed the SEAT would predict a held player.
	for id in game.players:
		if game.pickup.is_held(id):
			_tell(peer_id, PlaygroundEvents.Kind.SEAT, PlaygroundEvents.write_seat(session_of(id), 0, 0, true))

	# What everybody is already holding. A WEAPON event is sent once, when it changes, so a
	# joiner would otherwise see nobody's gun until its holder switched.
	for other in _tool_of.keys():
		_tell(peer_id, PlaygroundEvents.Kind.WEAPON, PlaygroundEvents.write_weapon(
			int(other), _tool_of[other]
		))
	# And every pane broken on this map, so the joiner's copy of the map has the same holes.
	for index: int in game.broken_panes:
		_tell(peer_id, PlaygroundEvents.Kind.PANE, PlaygroundEvents.write_pane(index))
	# And what everybody is holding, for the same reason: HELD is sent when it changes.
	for holder in held_props.keys():
		_tell(peer_id, PlaygroundEvents.Kind.HELD, PlaygroundEvents.write_held(int(holder), int(held_props[holder]), false))

	weapon_net.send_snapshot(peer_id, game.weapon_layer)
	# The map's toys, by net id in toy order: the joiner's own copies are paired with them.
	if not _toys_body.is_empty():
		_tell(peer_id, PlaygroundEvents.Kind.TOYS, _toys_body)

	# The time left now: on a quiet map the clock's next change never comes.
	if clock_fn.is_valid():
		_tell(peer_id, PlaygroundEvents.Kind.CLOCK, PlaygroundEvents.write_clock(clock_fn.call()))

	_tell_world_props(peer_id)

	# Grenades already in the air: a launch is sent once, so a joiner never saw them.
	if game.projectiles != null:
		for launch: Dictionary in game.projectiles.join_launches():
			_tell(peer_id, PlaygroundEvents.Kind.PROJECTILE, PlaygroundEvents.write_launch(
				int(launch["serial"]), launch["spawn"], launch["owner_id"], bool(launch["sticks"])
			))

	# Their own bag, whole, to them alone: a reconnecting player already has one.
	if inventory_net != null:
		inventory_net.admit(peer_id, session_id)

	# Once, so a READY said twice does not replay the backlog and the join line.
	if fresh:
		peer_admitted.emit(peer_id)


## Every prop and wave NPC already in the world, so a late joiner does not walk into unseen things.
func _tell_world_props(peer_id: int) -> void:
	for instance_id in _prop_nets.keys():
		var prop := game.props.get_prop(int(instance_id))
		var behaviour: PlaygroundPropNet = _prop_nets[instance_id]
		if behaviour == null or behaviour.identity == null:
			continue
		# A wave NPC is in the table, not in the prop spawner.
		if prop == null and _npc_kinds.has(instance_id):
			_tell(peer_id, PlaygroundEvents.Kind.PROP, PlaygroundEvents.write_prop(
				behaviour.identity.net_id, _npc_kinds[instance_id], 0, true, behaviour.net_position
			))
			continue
		if prop == null:
			continue
		_tell(peer_id, PlaygroundEvents.Kind.PROP, PlaygroundEvents.write_prop(
			behaviour.identity.net_id,
			prop.def.id,
			session_of(prop.owner_id),
			PlaygroundSpawnables.kind_of(prop.def) == PlaygroundSpawnables.Kind.ENTITY,
			behaviour.net_position
		))


func _on_map_ready(map: DotMapDef) -> void:
	_broadcast(PlaygroundEvents.Kind.MAP, PlaygroundEvents.write_map(map.id))
	_register_toys()
	# Re-announced after a map change: a client rebuilt its world and needs to be told
	# who is in it again. dot-map's own sync replaces the world and nothing else.
	for session_id in _behaviours.keys():
		_broadcast(PlaygroundEvents.Kind.JOIN, _join_body(int(session_id)))


# --- Both ends: the map's toys ---------------------------------------------------

## Server: an entity for each of the map's toys, and TOYS naming them.
func _register_toys() -> void:
	if net == null or not net.is_server or game == null:
		return
	_release_toys()
	var ids := PackedInt64Array()
	if game.toys != null:
		for toy in game.toys.toys:
			var behaviour := _toy_entity(toy, toy, 0)
			if behaviour == null:
				break
			ids.append(behaviour.identity.net_id)
	_toys_body = PlaygroundEvents.write_toys(game.maps.current.id if game.maps.current != null else &"", ids)
	_broadcast(PlaygroundEvents.Kind.TOYS, _toys_body)


## Tells one player what their tool gun has selected. The prop is named by the net id it
## replicates under, so the client can find its own mirror of it.
func _tell_selection(session_id: int, report: Dictionary) -> void:
	var node: Variant = report.get("node")
	var net_id := net_id_of_node(node) if node is Node else 0
	_tell(peer_for_player(session_id), PlaygroundEvents.Kind.SELECTION, PlaygroundEvents.write_selection(
		net_id, str(report.get("name", "")), report.get("settings", {}), str(report.get("refused", ""))
	))


## Puts one of this player's saved builds down in front of them. Client side.
func ask_load_build(build_name: String) -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_arm(
		PlaygroundEvents.ARM_LOAD_BUILD, StringName(build_name)
	))


## Asks the server to start an addon's menu entry, [param key] being `addon/item`, with the
## point the player is looking at. Client side.
func ask_addon_item(key: String, at: Vector3) -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_arm(
		PlaygroundEvents.ARM_ADDON_ITEM, StringName(key), JSON.stringify([at.x, at.y, at.z])
	))


## A player's saved builds, to that player. Server side.
func send_builds(peer_id: int, list: Array) -> void:
	_tell(peer_id, PlaygroundEvents.Kind.BUILDS, PlaygroundEvents.write_builds(list))


## A line on one player's HUD. Server side.
func tell_notice(peer_id: int, text: String) -> void:
	_tell(peer_id, PlaygroundEvents.Kind.NOTICE,
		PlaygroundEvents.write_notice(player_for_peer(peer_id), text))


func _drop_toy(session_id: int) -> void:
	var toy: PlaygroundWeapon = _toy_of.get(session_id)
	if toy != null:
		toy.holster()
	_toy_of.erase(session_id)


func _select_tool(session_id: int, id: StringName, tool_id: StringName) -> void:
	if not game.players.has(id):
		return
	if tool_id != &"phys" and tool_id != &"grav":
		return

	# Whatever the old tool was holding is let go. A player who swaps to the gravity gun
	# with a crate on the end of the physics gun would otherwise leave it hanging in the
	# air, owned by a tool they are no longer using and released by nothing.
	var player: PlaygroundPlayer = game.players.get(id)
	if player != null:
		game.phys_gun_release(player)
		player.grav_gun.drop()
		PlaygroundZee.disarm(player)
	_drop_toy(session_id)

	_tool_of[session_id] = tool_id
	_broadcast(PlaygroundEvents.Kind.WEAPON, PlaygroundEvents.write_weapon(session_id, tool_id))


# --- Client: applying ------------------------------------------------------

func _apply_weapon(reader: DotNetReader) -> void:
	var held := PlaygroundEvents.read_weapon(reader)
	if not bool(held["ok"]):
		return
	PlaygroundZee.show_held(
		game.players.get(_player_key(int(held["player_id"]))),
		game.weapon_def(held["weapon_id"] as StringName)
	)
	weapon_changed.emit(int(held["player_id"]), held["weapon_id"] as StringName)


func _apply_held(reader: DotNetReader) -> void:
	var holding := PlaygroundEvents.read_held(reader)
	if not bool(holding["ok"]):
		return
	if int(holding["net_id"]) > 0:
		held_props[int(holding["player_id"])] = int(holding["net_id"])
	else:
		held_props.erase(int(holding["player_id"]))


## Every launch to every client, so each flies a copy and draws the arc. Sent once, not replicated as an
## entity: a grenade lives seconds and its path is a pure function of where it left and how fast.
func _on_projectile_launched(flying: RefCounted) -> void:
	_broadcast(PlaygroundEvents.Kind.PROJECTILE, PlaygroundEvents.write_launch(
		int(flying.get("serial")), flying.get("spawn"), flying.get("owner_id"), bool(flying.get("sticks"))
	))


## The local thrower's own launches, flown now; [method _apply_projectile] adopts them when
## the server's launch arrives. Returns how many.
func predict_launches(outcome: DotWeaponOutcome, owner_body: Node = null) -> int:
	if game.projectiles == null or game.projectiles.authority or outcome == null:
		return 0

	var rid := (owner_body as CollisionObject3D).get_rid() if owner_body is CollisionObject3D else RID()

	for spawn: DotWeaponSpawn in outcome.spawns:
		var _f: Variant = game.projectiles.predict(spawn, _player_key(local_player_id), rid)

	return outcome.spawns.size()


## Where it went off, which the client's copy does not decide for itself — see
## PlaygroundProjectiles.
func _on_projectile_detonated(serial: int, at: Vector3, radius: float) -> void:
	var told: Dictionary = game.projectiles.take_told(serial)
	_broadcast(PlaygroundEvents.Kind.PROJECTILE, PlaygroundEvents.write_detonate(
		serial, at, radius, int(told.get("fx", 0)), float(told.get("seconds", 0.0))
	))


func _apply_projectile(reader: DotNetReader) -> void:
	if game.projectiles == null:
		return

	match reader.read_uint(PlaygroundEvents.PROJECTILE_SUB_BITS):
		PlaygroundEvents.ProjectileTell.LAUNCH:
			var launch := PlaygroundEvents.read_launch(reader)
			if bool(launch["ok"]):
				var _flying: Variant = game.projectiles.launch_told(
					launch["spawn"], launch["owner_id"], int(launch["serial"]),
					launch["owner_id"] == _player_key(local_player_id)
				)
		PlaygroundEvents.ProjectileTell.DETONATE:
			var blast := PlaygroundEvents.read_detonate(reader)
			if bool(blast["ok"]):
				game.projectiles.detonate_remote(
					int(blast["serial"]), blast["position"], float(blast["radius"]),
					int(blast["fx"]), float(blast["seconds"])
				)
		PlaygroundEvents.ProjectileTell.BLIND:
			var blind := PlaygroundEvents.read_blind(reader)
			if bool(blind["ok"]):
				game.projectiles.blind_remote(float(blind["seconds"]), float(blind["strength"]))


func _apply_hello(reader: DotNetReader) -> void:
	var hello := PlaygroundEvents.read_hello(reader)
	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])

	# Before anything else arrives for it: the bag that follows is this identity's.
	if inventory_net != null:
		inventory_net.on_hello(local_player_id)

	# The server's tick rate, before anything is derived from it and before sync_from_server, whose clock
	# converts through tick_rate. A client counting at its export's 60 against a server on 128 has every time wrong.
	_adopt_tick_rate(int(hello["tick_rate"]))

	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	var map_id: StringName = hello["map_id"]
	if map_id != &"" and (game.maps.current == null or game.maps.current.id != map_id):
		game.change_map(map_id)

	_claim_local_player()

	hello_received.emit(local_player_id)


## Puts the whole client (game, timers, netcode clock and the ENGINE) on the server's tick rate.
##
## Four places hold the tick rate and must move together: `game.tick_rate`; `net.config.tick_rate` (read by [method DotNetInput.sanitise] and the interpolator);
## `net.clock.tick_rate`, built at `setup()` and not updated by writing the config; and `Engine.physics_ticks_per_second`, which decides whether it LOOKS right.
## A server never calls this: its rate is `sv_tickrate`.
func _adopt_tick_rate(rate: int) -> void:
	if net == null or net.is_server or game == null or rate <= 0 or rate == game.tick_rate:
		return

	var before := game.tick_rate

	if not game.set_tick_rate(rate):
		return

	net.config.tick_rate = game.tick_rate
	net.clock.tick_rate = game.tick_rate
	# dot-net API 7 has DotNetClock.adopt_tick_rate(), which also raises the engine's step cap
	# to a quarter second of ticks (8 steps are 62.5 ms at 128 Hz, so a client under 16 fps ran
	# fewer ticks than the server). A shell built before it gets the same rule here, as
	# game-g2gfast does; remove this branch when the oldest shell is API 7.
	if DotAddonApi.build_level("dot_net") >= 7:
		DotNetClock.adopt_tick_rate(game.tick_rate)
	else:
		Engine.max_physics_steps_per_frame = maxi(Engine.max_physics_steps_per_frame, ceili(0.25 * float(game.tick_rate)))
		Engine.physics_ticks_per_second = game.tick_rate

	DotLog.info(CHANNEL, "adopted the server's tick rate", {
		"was": before, "now": game.tick_rate, "engine": Engine.physics_ticks_per_second,
	})


## Who owns a mirrored player on this client: this client for its own player, 0 otherwise.
##
## Matched by session id, not sent on the wire: the id HELLO already carries is the whole answer and `is_owner` (owner == local peer) cannot disagree.
## Never the local peer for anybody else, or this client would predict somebody whose keys it never had; a local peer of 0 claims nothing (0 is the server's owner id).
func _mirror_owner(session_id: int) -> int:
	if net == null or net.local_peer_id <= 0:
		return 0

	if local_player_id != 0 and session_id == local_player_id:
		return net.local_peer_id

	return 0


## The local player's mirror, claimed if it arrived before HELLO said whose it was.
##
## Not the order `_admit` sends in, which is why this is belt and braces rather than a path
## this game takes: a JOIN broadcast that reached this peer before its HELLO would otherwise
## leave the local player unpredicted for the rest of the session, with every other check
## still passing — which is the bug [method _apply_join] documents. A vehicle is never
## claimed: it is not a player mirror, and a rigid body is not predicted (family decision).
func _claim_local_player() -> void:
	var mine: PlaygroundPlayerNet = _behaviours.get(local_player_id)

	if mine == null or mine.identity == null or not mine.identity.is_registered():
		return

	var claimed := _mirror_owner(local_player_id)

	if claimed == 0 or mine.identity.owner_peer_id == claimed:
		return

	DotLog.debug(CHANNEL, "claimed the local player after HELLO", {
		"session": local_player_id, "net_id": mine.identity.net_id,
	})
	var _changed := net.registry.change_owner(mine.identity.net_id, claimed)


func _on_ride_entered(
	vehicle: DotVehicleInstance, rider_id: StringName, seat: DotVehicleSeat
) -> void:
	announce_seat(vehicle, rider_id, seat, true)


## Somebody was picked up or let go. A SEAT with no vehicle: the held client stops
## predicting and adopts the server's position, which is all being carried needs — and
## exactly what a client older than picking up does with it.
func _on_pickup_changed(_holder_id: StringName, target_id: StringName, held: bool) -> void:
	if net == null or not net.is_server:
		return
	_broadcast(PlaygroundEvents.Kind.SEAT, PlaygroundEvents.write_seat(session_of(target_id), 0, 0, held))


func _on_ride_exited(
	vehicle: DotVehicleInstance,
	rider_id: StringName,
	seat: DotVehicleSeat,
	_at: Vector3
) -> void:
	announce_seat(vehicle, rider_id, seat, false)


## A client's copy of "that player is in a car".
##
## [b]The client does not run the ride at all.[/b] It has no vehicle spawner, no exit
## sweep and no seats — the server owns every one of those — so what arrives is the
## answer rather than the question. What the client does with it is stop predicting a
## player who is no longer walking, which is the one thing it would otherwise get wrong
## on its own screen: a predicted controller simulating a passenger fights the position
## the snapshots are putting them at, every tick, at a metre a time.
func _apply_seat(reader: DotNetReader) -> void:
	var info := PlaygroundEvents.read_seat(reader)

	if not bool(info["ok"]):
		return

	var behaviour: PlaygroundPlayerNet = _behaviours.get(int(info["player_id"]))

	if behaviour == null or behaviour.player == null:
		return

	# The vehicle too, when this client has it, so the body sits facing the car's way.
	var vehicle_net: PlaygroundPropNet = _prop_nets.get(int(info["vehicle_net_id"]))
	var vehicle_node: Node3D = null
	if vehicle_net != null and is_instance_valid(vehicle_net.prop):
		vehicle_node = vehicle_net.prop as Node3D
	if int(info["vehicle_net_id"]) == 0:
		# Vehicle 0 is a player held by a physics gun (PlaygroundPickup): not predicted,
		# not seated, and no seat_changed, because nobody got into anything.
		behaviour.player.set_held(bool(info["seated"]))
		return
	behaviour.player.set_riding(bool(info["seated"]), vehicle_node)
	seat_changed.emit(int(info["player_id"]), bool(info["seated"]))


func _apply_prop_gone(reader: DotNetReader) -> void:
	var info := PlaygroundEvents.read_prop_gone(reader)
	if not bool(info["ok"]):
		return

	var net_id := int(info["net_id"])

	var behaviour: PlaygroundPropNet = _prop_nets.get(net_id)
	_prop_nets.erase(net_id)

	if behaviour == null:
		return

	if net != null:
		net.registry.unregister(net_id)

	if behaviour.prop != null and is_instance_valid(behaviour.prop):
		# A killed NPC goes down the way the server picked, copied from its drawn figure
		# before the mirror goes.
		var figure := behaviour.prop.get_node_or_null(^"Figure") as Node3D
		if info.has("death") and figure != null:
			body_fell.emit(figure, info["death"])
		behaviour.prop.queue_free()

	props_changed.emit()


# --- Sending ---------------------------------------------------------------

## To every READY peer, one at a time, and never to peer 0.
##
## Not `net.send(msg, 0)`, an `rpc()` to every socket: a peer connects before its client builds
## `Server/Playground`, so the early JOIN hit a missing node. [method _admit] tells it everything on READY.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or body.is_empty():
		return
	for peer_id in _ready_peers.keys():
		net.send(PlaygroundEvent.new(kind, body), int(peer_id))


## To one peer, and never to peer 0.
##
## [b]Zero is the broadcast address.[/b] game-hungario gave a bot peer id 0, and every
## private per-player message sent to that bot went to every client on the server. A
## player with no peer — a bot, a test — simply is not told, which is correct: there is
## nobody there to tell.
func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or peer_id <= 0 or body.is_empty():
		return
	net.send(PlaygroundEvent.new(kind, body), peer_id)
