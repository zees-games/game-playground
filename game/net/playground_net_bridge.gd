extends "playground_net_bridge_ask.gd"



func attach(p_game: Playground, p_net: DotNetManager, link_parent: Node) -> DotResult:
	if p_game == null or p_net == null or link_parent == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs all three.")

	if p_game.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The game and the manager disagree about who is authoritative.",
			"game=%s net.is_server=%s" % [p_game.authoritative, p_net.is_server]
		)

	game = p_game
	net = p_net
	weapon_net.attach(self)

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	# The styles' declared ordering, not a sort of the ids: StringNames compare by interned pointer,
	# so a sort gives two peers two tables and a style index that means a different style on each.
	_style_ids.assign(game.style_order)

	net.send_fn = _send

	var event := net.messages.register(
		PlaygroundEvent.NAME, PlaygroundEvent,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)
	if not event.ok:
		return event
	var request := net.messages.register(
		PlaygroundRequest.NAME, PlaygroundRequest,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)
	if not request.ok:
		return request

	net.messages.on(PlaygroundEvent.NAME, _on_event)
	net.messages.on(PlaygroundRequest.NAME, _on_request)

	link = PlaygroundNetLink.attached_to(link_parent, self, net.is_server)
	# Not parent.add_child: the link must sit under the server (RPC paths) yet die with this bridge;
	# a bare add_child left a second link after a module reload and renamed the live one.
	DotGameLink.attach(link, link_parent, self, PlaygroundNetLink.NODE_NAME)

	_attach_inventory()

	# Both ends: a client game running its own loop would simulate the local player twice a tick.
	game.external_tick = true

	# The map's toys: the server's leave the registry before their nodes go and the new ones are
	# named; a client's mirrors stay registered and are handed this end's toys when they exist.
	if net.is_server:
		game.toys_clearing.connect(_release_toys)
	else:
		game.toys_clearing.connect(_unpair_toys)
		game.toys_built.connect(_pair_pending_toys)

	if net.is_server:
		game.player_added.connect(_on_player_added)
		game.player_removed.connect(_on_player_removed)
		game.props.spawned.connect(_on_prop_spawned)
		game.props.removed.connect(_on_prop_removed)
		game.props.refused.connect(_on_prop_refused)
		game.map_ready.connect(_on_map_ready)
		game.vehicles.ride.entered.connect(_on_ride_entered)
		game.vehicles.ride.exited.connect(_on_ride_exited)
		game.pickup.changed.connect(_on_pickup_changed)
		game.held_changed.connect(_on_held_changed)
		game.pane_broken.connect(_on_pane_broken)
		game.prop_shattered.connect(func(at: Vector3, material: int) -> void:
			_broadcast(PlaygroundEvents.Kind.SHATTER, PlaygroundEvents.write_shatter(at, material)))
		game.movement_changed.connect(func() -> void:
			_broadcast(PlaygroundEvents.Kind.MOVEMENT, PlaygroundEvents.write_movement(_movement_of_game())))
		game.addon_message.connect(func(addon: String, body: Dictionary) -> void:
			_broadcast(PlaygroundEvents.Kind.ADDON, PlaygroundEvents.write_addon(addon, body)))
		# To the one who hit, and nobody else: a confirmation is about what YOU did.
		game.hit_landed.connect(func(id: StringName, victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
			_tell(peer_for_player(session_of(id)), PlaygroundEvents.Kind.HIT,
				PlaygroundEvents.write_hit(victim, amount, point, killed, headshot)))
		game.weapon_picked_up.connect(_on_weapon_picked_up)

		_connect_projectiles()

		# A map loaded before the bridge was attached has its toys already.
		if game.toys != null:
			_register_toys()

	return DotResult.success(true)


func remove_peer(peer_id: int) -> void:
	_ready_unseated.erase(peer_id)

	if _player_of_peer.has(peer_id):
		remove_player(int(_player_of_peer[peer_id]))


## Removes a player whether or not a peer is behind it — a bot has none.
func remove_player(session_id: int) -> void:
	if not _behaviours.has(session_id):
		return

	var peer_id := peer_for_player(session_id)
	var was_ready := _ready_peers.has(peer_id)
	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)
	_tool_of.erase(session_id)
	held_props.erase(session_id)
	_prev_buttons.erase(session_id)
	_drop_toy(session_id)
	_armed_of.erase(session_id)

	# Released before the game is told, so _on_player_removed finds nothing and this stays the one
	# place a leaving player is announced.
	_release_entity(session_id)

	if inventory_net != null:
		inventory_net.release(peer_id, session_id)

	game.remove_player(_player_key(session_id))

	if net != null and peer_id > 0:
		# By whether dot-net has the peer, not `was_ready`: a real disconnect is already off the
		# ready set, and keying on it leaked every disconnected peer's buffers for the server's life.
		if net.peers().has(peer_id):
			net.remove_peer(peer_id)
		if net.interest != null:
			net.interest.forget_peer(peer_id)

	_broadcast(PlaygroundEvents.Kind.LEAVE, PlaygroundEvents.write_player(session_id))
	# Off the ready set by now, so the broadcast skipped them; a still-connected one is told, a
	# closed socket is not sent to (rpc_id would log an unknown peer).
	if was_ready and link != null and link.can_reach(peer_id):
		_tell(peer_id, PlaygroundEvents.Kind.LEAVE, PlaygroundEvents.write_player(session_id))
	roster_changed.emit(session_id)


func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1
	weapon_net.watch(game.weapon_layer)
	var _t_net := DotFrameCost.now()
	if net != null:
		net.server_tick(tick)
	DotFrameCost.add(&"br.dotnet_tick", _t_net)
	ensure_game_ticked(tick)


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return
	_game_ticked_for = tick

	for session_id in _behaviours:
		var behaviour: PlaygroundPlayerNet = _behaviours[session_id]
		# Only what a peer sent. A bot has no peer and is driven by something else — a
		# test, an AI — and an empty command applied over the top of that would stand
		# it still.
		if behaviour.player != null and behaviour.identity != null \
				and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())

	var _t_g := DotFrameCost.now()
	game.tick_once(tick)
	DotFrameCost.add(&"br.game_tick_once", _t_g)

	# The tools, from the buttons the commands carried. After the movement, because a
	# gun is aimed from where the player ENDED the tick.
	var _t_d := DotFrameCost.now()
	for session_id in _behaviours:
		_drive_tools(int(session_id), _behaviours[session_id])
	DotFrameCost.add(&"br.drive_tools", _t_d)

	# After the game moved them, before the snapshot is built. A prop pulled before the
	# physics step would replicate where it was last tick, which is the whole family's
	# "produced correctly and consumed by nothing" one step along: correct data, wrong
	# instant, and nothing errors.
	var _t_p := DotFrameCost.now()
	for instance_id in _prop_nets:
		(_prop_nets[instance_id] as PlaygroundPropNet).pull()
	DotFrameCost.add(&"br.prop_pull", _t_p)

	# Every bag the server changed this tick, to its owner, once. After the game ticked,
	# because a spawn from the bag happens inside it.
	if inventory_net != null:
		inventory_net.flush()


## Runs one player's physics gun or gravity gun from the buttons their command carried. The triggers are
## BUTTONS, per-tick and continuous, riding in [member DotFpsCommand.buttons]; reliable requests would lag
## the mouse. The server actuates them: the client's props are frozen and drawn from snapshots.
func _drive_tools(session_id: int, behaviour: PlaygroundPlayerNet) -> void:
	if behaviour == null or behaviour.player == null or behaviour.identity == null:
		return
	if behaviour.identity.owner_peer_id <= 0:
		return

	var player := behaviour.player
	var buttons := behaviour.last_move.buttons
	var before := int(_prev_buttons.get(session_id, 0))
	_prev_buttons[session_id] = buttons

	var primary := (buttons & DotFpsCommand.BUTTON_USER_0) != 0
	var secondary := (buttons & DotFpsCommand.BUTTON_USER_1) != 0
	var primary_pressed := primary and (before & DotFpsCommand.BUTTON_USER_0) == 0
	var secondary_pressed := secondary and (before & DotFpsCommand.BUTTON_USER_1) == 0

	var space := player.get_world_3d().direct_space_state if player.is_inside_tree() else null
	var origin := player.eye_position()
	var aim := player.aim_direction()
	var view := Basis()
	var delta := 1.0 / float(maxi(game.tick_rate, 1))
	var may_touch := game.may_touch_others()

	var tool_id: StringName = _tool_of.get(session_id, &"phys")

	# A zee weapon owns all three buttons while it is in hand, and the physics gun none of
	# them: falling through to it would grab a crate with every shot.
	var rig := player.zee_rig as ZeeWeaponRig
	if rig != null and is_instance_valid(rig):
		var command := PlaygroundZee.command_for(
			buttons, behaviour.last_move.yaw, behaviour.last_move.pitch,
			PlaygroundZee.slot_of(rig), behaviour.last_aim
		)
		var outcome := rig.simulate_tick(command, game.current_tick())
		var _moved := PlaygroundZee.shove_props(player, outcome, may_touch)
		# NPCs hear it, and the ones it hits are hurt.
		game.player_shots_fired(player.player_id, outcome)

		if shot_fn.is_valid():
			for shot: DotShot in outcome.shots:
				shot_fn.call(player.player_id, shot)
		return

	# [b]A toy is run here too, for the zee weapons' reason.[/b] Its buttons went to the
	# physics gun, so a connected player holding the launcher grabbed crates with it: the
	# toys only ever ran on the client that held them, which on a server is a client that
	# decides what it spawned and removed. Pressed edges for primary and secondary, a tick
	# every tick (a charge, a cooldown, a beam). A prop it spawns is charged like one from
	# the menu, after the spawn, and taken back out if the purse refuses.
	var toy: PlaygroundWeapon = _toy_of.get(session_id)
	if toy != null:
		var reload_pressed := (buttons & DotFpsCommand.BUTTON_USER_2) != 0 \
			and (before & DotFpsCommand.BUTTON_USER_2) == 0
		if primary_pressed:
			_toy_result(session_id, player.player_id, toy, toy.primary(space, origin, aim))
		if secondary_pressed:
			_toy_result(session_id, player.player_id, toy, toy.secondary(space, origin, aim))
		if reload_pressed:
			_toy_result(session_id, player.player_id, toy, toy.reload(space, origin, aim))
		toy.tick(space, origin, aim, delta)
		return

	if tool_id == &"grav":
		if primary_pressed:
			player.grav_gun.punt(space, origin, aim, may_touch)
		if secondary_pressed:
			player.grav_gun.pull(space, origin, aim, may_touch)
		elif secondary:
			player.grav_gun.carry(origin, aim, delta)
		elif not secondary and player.grav_gun.is_carrying():
			player.grav_gun.drop()
		return

	if primary_pressed:
		var grabbed := game.phys_gun_grab(player, space, origin, aim, view, may_touch)
		# A refusal to pick somebody up says why; a prop refusal is already reported by
		# the spawner's own signal, and a miss is not worth a notice.
		if not grabbed.ok and grabbed.error.context.has("pickup"):
			_tell(peer_for_player(session_id), PlaygroundEvents.Kind.NOTICE,
				PlaygroundEvents.write_notice(session_id, grabbed.error.message))
	elif primary:
		player.phys_gun.hold(origin, aim, view, delta)
	elif not primary:
		game.phys_gun_release(player)

	if secondary_pressed:
		player.phys_gun.freeze_held()


# --- The client tick -------------------------------------------------------

func _on_request(message: DotNetMessage) -> void:
	var ask := message as PlaygroundRequest
	if ask == null or net == null or not net.is_server:
		return

	var peer_id := ask.sender_peer_id
	# Before the seat check: a READY can come before the seat (see `_ready_unseated`), and
	# `_admit` keeps it rather than drop it.
	if ask.kind == PlaygroundEvents.Ask.READY:
		_admit(peer_id)
		return

	var session_id := player_for_peer(peer_id)
	if session_id == 0:
		return

	var id := _player_key(session_id)
	var reader := ask.reader()
	match ask.kind:
		PlaygroundEvents.Ask.SPAWN_PROP:
			_spawn_for(id, PlaygroundEvents.read_id(reader))
		PlaygroundEvents.Ask.GIVE_WEAPON:
			_give_weapon(session_id, id, PlaygroundEvents.read_id(reader))
		PlaygroundEvents.Ask.SELECT_TOOL:
			_select_tool(session_id, id, PlaygroundEvents.read_id(reader))
		PlaygroundEvents.Ask.ARM_PROP:
			var arm := PlaygroundEvents.read_arm(reader)
			if bool(arm["ok"]):
				_on_arm(peer_id, session_id, id, arm)
		PlaygroundEvents.Ask.UNDO:
			game.undo(id)
		PlaygroundEvents.Ask.CLEAR_MINE:
			game.props.clear_player(id)
		PlaygroundEvents.Ask.RESTART:
			game.spawn_player(id)
		PlaygroundEvents.Ask.CHECKPOINT:
			# A run timer's practice checkpoints; nothing to do without one.
			var action := PlaygroundEvents.read_index(reader)
			if game.run_timer != null:
				game.run_timer.call("checkpoint", id, action)
		PlaygroundEvents.Ask.RTV:
			game.rock_the_vote(id)
		PlaygroundEvents.Ask.SAY:
			var said := PlaygroundEvents.read_say(reader)

			if bool(said["ok"]):
				# Emitted rather than acted on. Everything about what a line means is
				# [DotChatRouter]'s, and the router is [PlaygroundModule]'s.
				say_requested.emit(
					peer_id, StringName(str(said["channel"])), str(said["text"])
				)
		PlaygroundEvents.Ask.VOTE:
			vote_requested.emit(peer_id, PlaygroundEvents.read_vote(reader))
		PlaygroundEvents.Ask.LOADOUT:
			var wanted := PlaygroundEvents.read_loadout(reader)

			if bool(wanted["ok"]):
				loadout_requested.emit(peer_id, wanted["pairs"])
		PlaygroundEvents.Ask.USE_VEHICLE:
			var used := game.use_vehicle(id)

			# A refusal goes back to the one player who asked. "There is nowhere to
			# stand" is the single most confusing thing this system can do silently: the
			# player presses the key, nothing happens, and there is no way to tell it
			# from a key that is not bound.
			if not used.ok:
				_tell(peer_id, PlaygroundEvents.Kind.NOTICE,
					PlaygroundEvents.write_notice(session_id, used.error.message))
		PlaygroundEvents.Ask.STYLE:
			if game.set_player_style(id, _style_id(PlaygroundEvents.read_index(reader))):
				_broadcast(PlaygroundEvents.Kind.JOIN, _join_body(session_id))
		PlaygroundEvents.Ask.INVENTORY:
			if inventory_net != null:
				inventory_net.on_ask(peer_id, session_id, reader)


## One ARM_PROP ask: which tool mode, NPC weapon, spawned weapon, build or addon item the player armed.
func _on_arm(peer_id: int, session_id: int, id: StringName, arm: Dictionary) -> void:
	match int(arm["sub"]):
		PlaygroundEvents.ARM_TOOL:
			_set_tool_mode(session_id, arm["id"] as StringName, str(arm["payload"]))
		PlaygroundEvents.ARM_NPC_WEAPON:
			var chosen := game.set_npc_weapon_choice(id, arm["id"] as StringName)
			if not chosen.ok:
				_tell(peer_id, PlaygroundEvents.Kind.NOTICE,
					PlaygroundEvents.write_notice(session_id, chosen.error.message))
		PlaygroundEvents.ARM_SPAWN_WEAPON:
			var weapon_id := arm["id"] as StringName
			if game.weapon_def(weapon_id) != null:
				_spawn_for(id, Playground.pickup_id_of(weapon_id))
		PlaygroundEvents.ARM_DROP_WEAPON:
			var _gun = game.weapon_layer.throw_for(id)
		PlaygroundEvents.ARM_FLASHLIGHT:
			var _switched := game.toggle_flashlight(id)
		PlaygroundEvents.ARM_BUILDS:
			builds_requested.emit(peer_id)
		PlaygroundEvents.ARM_LOAD_BUILD:
			build_load_requested.emit(peer_id, String(arm["id"]))
		PlaygroundEvents.ARM_ADDON_ITEM:
			var looked: Variant = JSON.parse_string(str(arm["payload"])) if str(arm["payload"]) != "" else null
			var at := Vector3.ZERO
			if looked is Array and (looked as Array).size() == 3:
				at = Vector3(float(looked[0]), float(looked[1]), float(looked[2]))
			var started := game.activate_addon_item(String(arm["id"]), session_id, at, id)
			DotLog.result(CHANNEL, "an addon item was asked for", started)
			if not started.ok:
				_tell(peer_id, PlaygroundEvents.Kind.NOTICE,
					PlaygroundEvents.write_notice(session_id, started.error.message))
		_:
			var prop_id := arm["id"] as StringName
			if game.props.catalogue != null and game.props.catalogue.get_prop(prop_id) != null:
				_armed_of[session_id] = prop_id
				var toy: PlaygroundWeapon = _toy_of.get(session_id)
				if toy != null:
					toy.armed = prop_id


func _on_event(message: DotNetMessage) -> void:
	var event := message as PlaygroundEvent
	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()
	match event.kind:
		PlaygroundEvents.Kind.HELLO:
			_apply_hello(reader)
		PlaygroundEvents.Kind.JOIN:
			_apply_join(reader)
		PlaygroundEvents.Kind.LEAVE:
			var session_id := PlaygroundEvents.read_player(reader)
			_release_entity(session_id)
			game.remove_player(_player_key(session_id))
			roster_changed.emit(session_id)
		PlaygroundEvents.Kind.MAP:
			var map_id := PlaygroundEvents.read_map(reader)
			if game.maps.current == null or game.maps.current.id != map_id:
				game.change_map(map_id)
		PlaygroundEvents.Kind.ADDON:
			var said_by := PlaygroundEvents.read_addon(reader)
			if bool(said_by["ok"]) and game.addons != null:
				game.addons.deliver(str(said_by["addon"]), said_by["body"])
		PlaygroundEvents.Kind.TOYS:
			var told := PlaygroundEvents.read_toys(reader)
			if bool(told["ok"]):
				_apply_toys(told)
		PlaygroundEvents.Kind.PROP:
			_apply_prop(reader)
		PlaygroundEvents.Kind.PROP_GONE:
			_apply_prop_gone(reader)
		PlaygroundEvents.Kind.WEAPON:
			_apply_weapon(reader)
		PlaygroundEvents.Kind.PANE:
			var pane := PlaygroundEvents.read_pane(reader)
			if bool(pane["ok"]):
				game.break_pane(int(pane["index"]))
		PlaygroundEvents.Kind.SHATTER:
			var burst := PlaygroundEvents.read_shatter(reader)
			if bool(burst["ok"]):
				game.prop_shattered.emit(burst["at"], int(burst["material"]))
		PlaygroundEvents.Kind.MOVEMENT:
			_adopt_movement(PlaygroundEvents.read_movement(reader))
		PlaygroundEvents.Kind.HELD:
			_apply_held(reader)
		PlaygroundEvents.Kind.NOTICE:
			var notice := PlaygroundEvents.read_notice(reader)
			if bool(notice["ok"]):
				notice_received.emit(int(notice["player_id"]), str(notice["text"]))
		PlaygroundEvents.Kind.SEAT:
			_apply_seat(reader)
		PlaygroundEvents.Kind.CHAT:
			var wire := PlaygroundEvents.read_chat(reader)
			if bool(wire["ok"]):
				chat_received.emit(wire)
		PlaygroundEvents.Kind.COMBAT:
			var hit := PlaygroundEvents.read_combat(reader)
			if bool(hit["ok"]):
				combat_received.emit(hit)
		PlaygroundEvents.Kind.MATCH:
			var clock := PlaygroundEvents.read_match(reader)
			if bool(clock["ok"]):
				match_received.emit(clock)
		PlaygroundEvents.Kind.PROGRESS:
			var earned := PlaygroundEvents.read_progress(reader)
			if bool(earned["ok"]):
				progress_received.emit(earned)
		PlaygroundEvents.Kind.VOTE:
			var cue := PlaygroundEvents.read_vote_cue(reader)
			if bool(cue["ok"]):
				vote_cue_received.emit(cue)
		PlaygroundEvents.Kind.CLOCK:
			var clock := PlaygroundEvents.read_clock(reader)

			if bool(clock["ok"]):
				clock_view.adopt(clock, Time.get_ticks_msec() / 1000.0)
				clock_received.emit(clock)
		PlaygroundEvents.Kind.INVENTORY:
			if inventory_net != null:
				inventory_net.on_tell(reader)
		PlaygroundEvents.Kind.PROJECTILE:
			_apply_projectile(reader)
		PlaygroundEvents.Kind.BUILDS:
			var listed := PlaygroundEvents.read_builds(reader)
			if bool(listed["ok"]):
				builds_received.emit(listed["builds"])
		PlaygroundEvents.Kind.SELECTION:
			var picked := PlaygroundEvents.read_selection(reader)
			if bool(picked["ok"]):
				selection_received.emit(picked)
		PlaygroundEvents.Kind.HIT:
			var hit := PlaygroundEvents.read_hit(reader)
			if bool(hit["ok"]):
				hit_received.emit(int(hit["victim"]), float(hit["amount"]), hit["point"],
					bool(hit["killed"]), bool(hit["headshot"]))
		_:
			var _weapon := weapon_net.apply(event.kind, reader, game.weapon_layer)


func _apply_join(reader: DotNetReader) -> void:
	var join := PlaygroundEvents.read_join(reader)
	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var id := _player_key(session_id)

	var player: PlaygroundPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]))
		if player == null:
			return
		# A client never samples: the client loop hands it commands.
		player.sampler = null
		player.samples_input = false

		# [b]This client's own player is owned by this client, and nobody else is.[/b] Until
		# 2026-09-25 every mirror was built with owner 0, the local one included — so on a
		# connected client `is_owner` was false for it, `registry.predicted()` was empty,
		# `client_tick` simulated nobody, and the player moved only when a snapshot came
		# back: INPUT_LEAD + 1 ticks behind the key. No check saw it, because "it moves" and
		# "the server agrees" both hold for a client that adopts every snapshot, and the
		# correction rate is lowest of all for a predictor that never runs. headless_net's
		# "this client predicts its own player" is the section that sees it.
		var identity := _build_entity(player, _mirror_owner(session_id))
		var registered := net.registry.register(
			identity, int(join["net_id"]), net.clock.tick, net.config
		)
		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			game.remove_player(id)
			return
	else:
		player.display_name = str(join["name"])

	game.set_player_style(id, _style_id(int(join["style_index"])))
	var mirrored: PlaygroundPlayer = game.players.get(id)
	if mirrored != null:
		mirrored.set_skins(join.get("skins", PackedInt32Array()))
	roster_changed.emit(session_id)


## Builds the client's copy of a prop and mirrors the net id it was given.
##
## [b]Adopted, never allocated.[/b] A receiving peer has to take the id it was sent —
## dot-2d's scatter had exactly this bug and could not be mirrored at all until it grew
## an `adopt()`. Registering with 0 here would give the prop a different id on every
## client and every snapshot for it would land on nothing.
func _apply_prop(reader: DotNetReader) -> void:
	var info := PlaygroundEvents.read_prop(reader)
	if not bool(info["ok"]):
		return

	var net_id := int(info["net_id"])

	if _prop_nets.has(net_id):
		return

	if game.props.catalogue == null:
		return

	var def := game.props.catalogue.get_prop(info["kind_id"])
	var scene_path := def.scene_path if def != null else ""

	# A wave NPC: drawn from the waves' catalogue, as a bare body with no brain — the server
	# thinks for it, exactly as it does for an NPC entity.
	if npc_catalogue == null:
		# A client never runs the module that sets it. The waves' catalogue is a static of
		# the game's own, the same on both ends — which is what makes a kind id meaningful.
		npc_catalogue = PlaygroundWaves.shared_catalogue()

	if def == null and npc_catalogue != null:
		var npc_def := npc_catalogue.get_npc(info["kind_id"])
		if npc_def != null:
			scene_path = npc_def.scene_path

	if def == null and scene_path == "":
		# Not an error: a server may run a catalogue this build does not have, and the
		# honest answer is to draw nothing rather than to guess.
		DotLog.debug(CHANNEL, "a prop this build does not have", {"id": str(info["kind_id"])})
		return

	var scene: PackedScene = load(scene_path) if scene_path != "" else null
	if scene == null:
		DotLog.warn(CHANNEL, "a prop's scene would not load", {"path": scene_path})
		return

	var body := scene.instantiate() as Node3D
	if body == null:
		return

	# [b]Frozen before it enters the tree, not on its first draw.[/b]
	# `PlaygroundPropNet._draw` freezes a mirror too, but only once an interpolated
	# frame arrives — and until then the mirror was a live rigid body falling under the
	# client's own physics, which is exactly the movement `headless_net`'s "it falls on
	# the client because the server's physics moved it" exists to rule out.
	var rigid := body as RigidBody3D
	if rigid != null:
		rigid.freeze = true

	var world := game.world if game.world != null else game
	world.add_child(body)
	body.global_position = info["position"]

	var as_prop := body as PlaygroundProp
	if as_prop != null and def != null:
		as_prop.configure(def)
	elif def == null:
		# A wave NPC's mirror, dressed by the rule the server's own copy was.
		PlaygroundWaves.dress(body, str(info["kind_id"]))

	# On the layout's layer, not the scene's 1/1: the client predicts its own player against its copy of the
	# world, so a mirror must sit where the server classified it. PROP carries no frozen state; later
	# reclassification happens on the server only. See docs/netcode.md on `[prop-mirror-layer-1]`.
	if game.player_stack != null and def != null:
		var _put := game.player_stack.classify(body, Playground.layer_for(def, false))

	# An NPC's script is attached on the server and its behaviour runs there. A client
	# copy is a body being drawn where the server says it is, so the script is
	# deliberately NOT attached here: it would run a second, disagreeing AI.

	var behaviour := _behaviour_for(def)
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	body.add_child(identity)

	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not mirror a prop", {"error": str(registered.error)})
		body.queue_free()
		return

	_prop_nets[net_id] = behaviour
	behaviour.mirror_of = _mirror_node
	behaviour.tick_seconds_fn = func() -> float: return net.clock.tick_duration()
	props_changed.emit()
	prop_arrived.emit(body.global_position, int(info["owner_id"]))
