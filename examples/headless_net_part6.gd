extends "res://examples/headless_net_part5.gd"

## A peer dot-server has spawned but that has not said READY hears NOTHING on this link.
##
## [b]A real join, in the order a real one happens.[/b] [DotClientLink] reports LOADED the
## moment it has added the game scene, which fires `client_spawn` and adds the player; the
## client builds `Server/Playground` only once its first map is up, and says READY after
## that. The JOIN the add produced went out as `rpc()` to every socket, and on every real
## join the new one logged "Failed to get path from RPC: Server/Playground". The loopback
## hands a broadcast over as peer 0, so "nothing to peer 0" is what that looks like here.
## `pg-rpc-before-scene`.
func _test_nothing_before_ready() -> void:
	_section("a spawned peer that has not said READY is sent nothing on the link")

	var late_peer := CLIENT_PEER + 5
	var late := SESSION + 5

	_server_events.clear()
	_recording = true
	var added := _server_bridge.add_player(late_peer, late, "Di")
	await _steps(2)

	_check(
		added.ok and _event_kinds(0).is_empty() and _event_kinds(late_peer).is_empty(),
		"the join is broadcast to nobody, and the joining peer is told nothing yet",
		"to 0: %s, to them: %s" % [_event_kinds(0), _event_kinds(late_peer)]
	)
	_check(
		_event_kinds(CLIENT_PEER).has(PlaygroundEvents.Kind.JOIN),
		"while a peer that is already in is told about them",
		str(_event_kinds(CLIENT_PEER))
	)

	# Voice is the one send that is not an EVENT. The module adds a peer to the voice
	# router at `client_spawn`, which is this add; somebody talking in the gap relayed to
	# the joiner over the link before it had the node a frame lands on.
	var services := PlaygroundServices.new()
	services.name = "VoiceServices"
	services.service_scope = &"server"
	services.bridge = _server_bridge
	services.punishments_path = NET_PUNISHMENTS
	_server_bridge.get_parent().add_child(services)
	var _up: DotResult = services.setup(null, _server_game, _server_bridge)
	services.add_peer(CLIENT_PEER)
	services.add_peer(late_peer)
	_server_voice.clear()
	var heard: DotResult = services.voice.relay(CLIENT_PEER, _voice_frame())
	_check(
		heard.ok and int(heard.value) == 1 and not _server_voice.has(late_peer)
			and not _server_voice.has(0) and services.voice_held == 1,
		"somebody talking is addressed to them and NOT sent over the link yet",
		"%s, to: %s, held %d" % [str(heard.value) if heard.ok else str(heard.error),
			_server_voice, services.voice_held]
	)

	_server_events.clear()
	_server_bridge.link.deliver(&"request", late_peer, _request_bytes(PlaygroundEvents.Ask.READY))
	await _steps(2)
	var theirs := _event_kinds(late_peer)
	_check(
		theirs.has(PlaygroundEvents.Kind.HELLO) and theirs.has(PlaygroundEvents.Kind.JOIN),
		"and READY is what tells them, their own JOIN included",
		str(theirs)
	)

	_server_voice.clear()
	heard = services.voice.relay(CLIENT_PEER, _voice_frame())
	_check(
		heard.ok and _server_voice == [late_peer] and services.voice_held == 1,
		"and after READY they hear the next frame",
		"to: %s, held %d" % [_server_voice, services.voice_held]
	)
	services.get_parent().remove_child(services)
	services.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(NET_PUNISHMENTS))
	_check(
		not DotRegistry.has(DotModerationManager.MUTE_SERVICE),
		"and the voice section's services leave no mute source behind"
	)

	_server_events.clear()
	_server_bridge.remove_player(late)
	await _steps(2)
	_check(
		_event_kinds(0).is_empty() and _event_kinds(CLIENT_PEER).has(PlaygroundEvents.Kind.LEAVE),
		"their leaving is told peer by peer too",
		"to 0: %s, to us: %s" % [_event_kinds(0), _event_kinds(CLIENT_PEER)]
	)
	_recording = false
	_server_events.clear()
	_done()


## A connected client standing on a prop the server moves (prop surfing).
##
## [b]Measured, because the client cannot carry itself the way the server does.[/b] Riding is
## `DotPropCarry`, resolved from the body underfoot; on a client that body is a frozen mirror
## the bridge moves by interpolation, with no velocity, so the client's own prediction stands
## still on a moving deck and only the server's corrections move it. This counts what that
## costs against standing on the same deck while it is still.
func _test_riding_over_the_wire() -> void:
	_section("riding a moving prop, connected")

	var mine := _client_player()
	var theirs := _server_player()
	var deck := _server_game.props.spawn(&"platform", theirs.player_id, Vector3(-60.0, 3.0, -60.0))
	var body := deck.body() as RigidBody3D if deck != null else null
	if body == null:
		_check(false, "a platform to ride")
		_done()
		return
	body.gravity_scale = 0.0
	_exchange()
	theirs.teleport(Vector3(-60.0, 3.4, -60.0), 0.0)
	for i in 64:
		body.linear_velocity = Vector3.ZERO
		await _step()

	var before := _corrections_and_snaps()
	for i in 128:
		body.linear_velocity = Vector3.ZERO
		await _step()
	var still := _corrections_and_snaps() - before
	var start := theirs.controller.state.position

	before = _corrections_and_snaps()
	var worst := 0.0
	for i in 128:
		body.linear_velocity = Vector3(3.0, 0.0, 0.0)
		await _step()
		worst = maxf(worst, mine.controller.state.position.distance_to(theirs.controller.state.position))
	var moving := _corrections_and_snaps() - before
	var carried := theirs.controller.state.position.x - start.x
	print("    riding over the wire: the server carried the player %.2f m in 128 ticks; client corrections %d while the deck moved against %d while it stood still; worst gap %.3f m" % [carried, moving, still, worst])

	_check(carried > 2.0, "the server carries a connected player on a moving deck", "%.2f m" % carried)
	_check(worst < 0.5, "and the client stays within half a metre of where the server has them", "%.3f m" % worst)
	# Measured 2026-10-06: before the client carried itself, 32 (one every snapshot) moving
	# and 32 still, the second because the client's player had mask 1 and stood on nothing.
	# With both fixed, 8 moving and 0 still: the 8 are the start, while the mirror's
	# interpolated motion catches up from rest. That 8 was really 7 to 12 idle and up to 16
	# under load: the mirror's velocity was measured against the wall clock between draws.
	# Measured 2026-10-11 from the server's positions per snapshot tick instead: 4, in 30 runs
	# out of 30, idle and loaded alike. No room for a loaded machine is needed, because
	# nothing here reads a clock; 6 is margin for a schedule change, and the old wall-clock
	# measure never came in under 7.
	_check(still <= 2 and moving <= 6,"and a client stands on a still deck with no corrections, and rides a moving one with few",
		"%d moving, %d still" % [moving, still])

	var _gone := _server_game.props.remove(deck.instance_id)
	_exchange()
	theirs.teleport(Vector3(0.0, 1.0, 0.0), 0.0)
	await _steps(32)
	_done()


## A connected player presses a button with F, and a door wired to it swings on the server and
## on this client's mirror of it. F is the vehicle request already on the wire; the server
## tries a button first ([method Playground.use_vehicle]).
func _test_button_over_the_wire() -> void:
	_section("a button pressed over the wire opens a door")

	var theirs := _server_player()
	await _steps(32)
	var eye := theirs.eye_position()
	var button := _server_game.props.spawn(&"button", theirs.player_id, eye + theirs.aim_direction() * 1.8)
	var door := _server_game.props.spawn(&"door", theirs.player_id, theirs.controller.state.position + Vector3(4.0, 1.3, 0.0))
	if button == null or door == null:
		_check(false, "a button and a door")
		_done()
		return
	DotPhysGun.set_frozen(button, true)
	var _wired := _server_game.io.link(button.instance_id, &"pressed", door.instance_id, &"toggle")
	_exchange()
	await _steps(8)
	# The server keys its behaviours by instance id; a client keys its mirrors by net id.
	var server_net: PlaygroundPropNet = _server_bridge._prop_nets.get(door.instance_id)
	var mirror: PlaygroundPropNet = _client_bridge._prop_nets.get(server_net.identity.net_id) \
		if server_net != null and server_net.identity != null else null
	var shut_basis := (door.node as Node3D).global_basis

	_client_bridge.ask_use_vehicle()
	_exchange()
	await _steps(int(_server_game.DOOR_SECONDS * _server_game.tick_rate) + 48)

	var server_turn := rad_to_deg(shut_basis.z.angle_to((door.node as Node3D).global_basis.z))
	_check(_server_game.door_is_open(door.instance_id) and absf(server_turn - 90.0) < 2.0,
		"F at a button opens the door wired to it, on the server", "%.1f degrees" % server_turn)
	var client_turn := rad_to_deg(shut_basis.z.angle_to(mirror.prop.global_basis.z)) if mirror != null and mirror.prop != null else -1.0
	_check(absf(client_turn - server_turn) < 2.0, "and this client's door swung with it", "%.1f against %.1f" % [client_turn, server_turn])
	_check(mirror != null and mirror.prop.global_position.distance_to((door.node as Node3D).global_position) < 0.05,
		"standing where the server's does")

	var _a := _server_game.props.remove(button.instance_id)
	var _b := _server_game.props.remove(door.instance_id)
	_exchange()
	await _steps(4)
	_done()


## The toys are run by the SERVER too (`[game-playground-1]` part 2): a connected player's
## launcher used to grab crates, because its buttons went to the physics gun.
func _test_toys_over_the_wire() -> void:
	_section("the toys are run by the server")

	var theirs := _server_player()
	var id: StringName = theirs.player_id if theirs != null else &""
	_server_game.props.clear_player(id)
	_client_bridge.ask_arm(&"crate")
	_client_bridge.ask_weapon(&"launcher")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)

	var toy: Variant = _server_bridge._toy_of.get(SESSION)
	_check(toy != null and str(toy.def.id) == "launcher" and toy.armed == &"crate",
		"the server holds the asker's launcher, loaded with what they armed",
		str(toy.describe()) if toy != null else "no toy")

	var fire := DotFpsCommand.new()
	fire.set_button(DotFpsCommand.BUTTON_USER_0, true)
	var before := _server_game.props.player_count(id)
	await _steps(2, fire)
	await _steps(4)
	_check(_server_game.props.player_count(id) == before + 1,
		"one press of fire throws one crate, on the server",
		"%d props before, %d after" % [before, _server_game.props.player_count(id)])

	_client_bridge.ask_weapon(&"remover")
	_exchange()
	await _steps(4)
	var alt := DotFpsCommand.new()
	alt.set_button(DotFpsCommand.BUTTON_USER_1, true)
	await _steps(2, alt)
	await _steps(4)
	_check(_server_game.props.player_count(id) == 0 and theirs.phys_gun.held == null,
		"and the remover's alt clears what they made, with the physics gun never involved",
		"%d left" % _server_game.props.player_count(id))

	_client_bridge.ask_tool(&"phys")
	_exchange()
	await _steps(4)
	_check(not _server_bridge._toy_of.has(SESSION), "a tool puts the toy away")
	_done()


## A zee-dot-weapons gun is run by the SERVER, from the buttons the client holds.
##
## [b]Unlike the toys, which a client actuates itself.[/b] A gun the server did not run is a
## client deciding what it hit, so `_give_weapon` puts a deciding rig on the server's copy of
## the player and `_drive_tools` ticks it. Armed by skipping that branch: the two firing
## checks fail (0 uses in 256 ticks).
func _test_zee_over_the_wire() -> void:
	_section("a zee weapon is run by the server")

	var theirs := _server_player()
	_client_bridge.ask_weapon(&"zee_smg")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)

	var rig: Variant = theirs.zee_rig if theirs != null else null
	_check(
		rig is ZeeWeaponRig and (rig as ZeeWeaponRig).authority
			and (rig as ZeeWeaponRig).role == ZeeWeaponRig.Role.SERVER,
		"the server puts a deciding rig in the asker's hands"
	)

	# Arrays, because a lambda captures a scalar by value.
	var uses: Array[int] = []
	var resolved: Array[int] = []
	_server_bridge.shot_fn = func(_id: StringName, _shot: DotShot) -> void: resolved.append(1)
	if rig is ZeeWeaponRig:
		(rig as ZeeWeaponRig).used.connect(
			func(o: DotWeaponOutcome) -> void: uses.append(o.shots.size())
		)

	# What a client draws of it: the server's WEAPON event puts the SMG on the body, and the
	# fire counter crosses in the snapshot. Armed: without the bridge's `show_held` the first
	# fails; without the specs in `PlaygroundPlayerNet` the counter check does.
	var mirror := _client_player()
	var drawn: Variant = mirror.zee_world if mirror != null else null
	_check(
		drawn is ZeeWorldModel and (drawn as ZeeWorldModel).equipped() == &"smg",
		"a client draws the SMG in that player's hands",
		str((drawn as ZeeWorldModel).equipped()) if drawn is ZeeWorldModel else "nothing"
	)

	# Outside the body, not inside it. The mount named the torso until 2026-10-03, which hung
	# every gun at the capsule's centre with two pixels of barrel showing (rendered with
	# `tools/screenshot_net.sh --zee=rifle`). Armed: mounted on "Torso" this is 0.00 m.
	var torso: Variant = mirror.character.rig.find_child("Torso", true, false) if mirror != null and mirror.character != null else null
	var torso_radius := ((torso as MeshInstance3D).mesh as CapsuleMesh).radius if torso is MeshInstance3D and (torso as MeshInstance3D).mesh is CapsuleMesh else 0.0
	# A body drawn as the character kit's figure has no capsule: its torso is the kit's own
	# `torso` mesh, and "outside the body" is past half its widest horizontal extent.
	var kit_torso: Variant = mirror.character.rig.find_child("torso", true, false) if mirror != null and mirror.character != null else null
	# One of the family's people: half its chest, measured off the people at 1.8 m.
	if torso_radius <= 0.0 and mirror != null and mirror.character != null \
			and mirror.character.rig.find_child("Figure", true, false) is DotHumanoidFigure:
		torso_radius = 0.2
	if torso_radius <= 0.0 and kit_torso is MeshInstance3D:
		var box := (kit_torso as MeshInstance3D).global_transform * (kit_torso as MeshInstance3D).get_aabb()
		torso_radius = maxf(box.size.x, box.size.z) * 0.5
	var off_axis := -1.0
	if drawn is ZeeWorldModel:
		var at := (drawn as ZeeWorldModel).global_position - mirror.global_position
		off_axis = Vector2(at.x, at.z).length()
	_check(
		torso_radius > 0.0 and off_axis > torso_radius,
		"and holds it outside the body",
		"%.2f m off the axis, torso radius %.2f" % [off_axis, torso_radius]
	)

	var fire := DotFpsCommand.new()
	fire.set_button(DotFpsCommand.BUTTON_USER_0, true)
	await _steps(256, fire)
	await _steps(8)

	var mirror_net: PlaygroundPlayerNet = _client_bridge._behaviours.get(SESSION)
	_check(
		mirror_net != null and mirror_net.net_fire_seq != 0 and mirror_net._seen_fire_seq == mirror_net.net_fire_seq,
		"the client sees the fire counter move, and has acted on it",
		"seq %d" % (mirror_net.net_fire_seq if mirror_net != null else -1)
	)

	_check(uses.size() > 1, "the server fires it from the buttons the client holds",
		"%d uses in 256 ticks" % uses.size())
	_check(resolved.size() >= uses.size() and resolved.size() > 0,
		"and hands every shot to whatever resolves it", "%d shots" % resolved.size())

	# Somebody arriving now was never sent the WEAPON event: READY replays what everybody
	# holds. Armed: without the `_tool_of` loop in `_admit` this fails.
	PlaygroundZee.show_held(mirror, null)
	await get_tree().process_frame
	_client_bridge.ask_ready()
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)
	var replayed: Variant = mirror.zee_world if mirror != null else null
	_check(
		replayed is ZeeWorldModel and (replayed as ZeeWorldModel).equipped() == &"smg",
		"a client that says READY again is told what everybody is holding"
	)

	_client_bridge.ask_tool(&"phys")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)
	_check(theirs != null and theirs.zee_rig == null,
		"the physics gun takes it back out of their hands on the server")
	_check(mirror != null and mirror.zee_world == null,
		"and off the body the client draws")

	_server_bridge.shot_fn = Callable()
	_done()


func _reconnect(session: int) -> void:
	_server_bridge.add_player(CLIENT_PEER, session, "Ada")
	_client_bridge.ask_ready()
	_exchange()
	await _steps(4)


func _disconnect() -> void:
	_server_bridge.remove_peer(CLIENT_PEER)
	_exchange()
	await _steps(4)


## A client flooding its bag. Its own section, just before the rejoin, because it spends the
## peer's whole budget and every client op for the next second is refused for it — which is
## the rule working, and would read as a bug in whatever section came next. The rejoin's
## disconnect is what resets it.
func _test_inventory_flood() -> void:
	_section("a client flooding its bag is told no past thirty a second, and rolls every no back")

	var mine := _client_bag()
	var server := _server_bag()
	var net_half: PlaygroundInventoryNet = _client_bridge.inventory_net
	var reasons: Array[String] = []
	var on_refused := func(reason: String) -> void: reasons.append(reason)
	_client_bridge.inventory_refused.connect(on_refused)
	var before_flood := 0

	# Answered, not dropped: every one of them is already applied on the client.
	var home := _cell_of(mine, &"beach_ball")
	var away := _first_free(mine)
	for i in range(40):
		var from := home if i % 2 == 0 else away
		var to := away if i % 2 == 0 else home
		var _flooded := mine.apply(DotInvOp.move(BACKPACK, _uid_at(mine, from), BACKPACK, to))
	_check(net_half.in_flight_count() == 40, "a client sends forty moves in one tick")
	_exchange()
	await _steps(2)
	var said_no := reasons.slice(before_flood)
	_check(
		said_no.size() >= 5 and said_no.size() <= 35 and said_no.has("too many inventory operations"),
		"the server takes about thirty and refuses the rest as too many (%d refused)" % said_no.size(),
		str(said_no.slice(0, 3))
	)
	_check(
		net_half.in_flight_count() == 0 and _bag_summary(mine) == _bag_summary(server),
		"and after every refusal is rolled back the two bags agree",
		"%s vs %s" % [_bag_summary(mine), _bag_summary(server)]
	)

	_client_bridge.inventory_refused.disconnect(on_refused)
	_done()


## A person who reconnects is a new userid to dot-server, and the same person to their bag.
func _test_inventory_rejoin() -> void:
	_section("a player who reconnects is sent their whole bag, under a new userid")

	var rejoin := SESSION + 20
	var person := &"bag:ada"
	var inv := _server_game.inventory
	var net_half: PlaygroundInventoryNet = _server_bridge.inventory_net
	var old_key := net_half.bag_key(SESSION)

	# What the module sets: who a session IS, for a bag that should outlast it.
	_server_bridge.inventory_key_fn = func(session_id: int) -> String:
		return String(person) if session_id == SESSION or session_id == rejoin else ""

	# An op still in flight when the connection drops, whose request never arrives.
	var mine_then := _client_bag()
	var stranded := mine_then.apply(DotInvOp.move(
		BACKPACK, _uid_at(mine_then, _cell_of(mine_then, &"beach_ball")), BACKPACK, _first_free(mine_then)
	))
	if stranded.ok and not _to_server.is_empty():
		_to_server.pop_back()

	await _disconnect()
	_check(
		not inv.has_bag(old_key),
		"the bag the first connection had was the session's, and went with it"
	)
	await _reconnect(SESSION)
	_check(
		stranded.ok and _client_bridge.inventory_net.in_flight_count() == 0
			and _bag_summary(_client_bag()) == _bag_summary(inv.for_player(person)),
		"nothing from the old connection is replayed onto the new bag, though dot-server gave the same userid",
		"%d in flight, %s vs %s" % [
			_client_bridge.inventory_net.in_flight_count(), _bag_summary(_client_bag()),
			_bag_summary(inv.for_player(person))
		]
	)
	_check(
		net_half.bag_key(SESSION) == person and _client_bag() != null,
		"reconnected, this player's bag is now kept under who they are"
	)

	var gave := inv.give(person, &"crate").ok and inv.give(person, &"barrel").ok \
		and inv.give(person, &"beach_ball").ok
	await _steps(2)
	var mine := _client_bag()
	var ball := _uid_at(mine, _cell_of(mine, &"beach_ball"))
	var moved := mine != null and mine.apply(DotInvOp.move(BACKPACK, ball, BACKPACK, Vector2i(7, 4))).ok
	_exchange()
	_check(
		gave and moved and _bag_summary(_client_bag()) == _bag_summary(inv.for_player(person)),
		"they fill it — three things from the server and a move of their own",
		"%s vs %s" % [_bag_summary(_client_bag()), _bag_summary(inv.for_player(person))]
	)

	_recording = true
	_server_events.clear()
	await _disconnect()
	_check(inv.has_bag(person), "they leave, and the bag stays: it belongs to somebody the server will know again")
	var away := inv.give(person, &"die")
	await _steps(2)
	_check(
		away.ok and _inventory_events(CLIENT_PEER).is_empty() and _inventory_peers().is_empty(),
		"an admin gives them a die while they are away, and nobody is sent anything"
	)
	_recording = false
	var held := _bag_summary(inv.for_player(person))

	await _reconnect(rejoin)
	_check(
		_client_bridge.local_player_id == rejoin,
		"they come back, and dot-server gives them a new userid"
	)
	_check(
		_bag_summary(_client_bag()) == held and _client_bag().doc.count_of(&"die") == 1
			and _client_bag().doc.count_of(&"crate") == 1 and _client_bag().doc.count_of(&"barrel") == 1,
		"and the whole bag, uids and all, including what arrived while they were away",
		"%s vs %s" % [_bag_summary(_client_bag()), held]
	)
	_check(
		_client_game.inventory.keys().size() == 1,
		"in the one bag this client holds: the old connection's is gone",
		str(_client_game.inventory.keys())
	)

	var mine_again := _client_bag()
	var back_ball := _uid_at(mine_again, Vector2i(7, 4))
	var again := mine_again.apply(DotInvOp.move(BACKPACK, back_ball, BACKPACK, Vector2i(8, 4)))
	_exchange()
	_check(
		again.ok and _cell_of(inv.for_player(person), &"beach_ball") == Vector2i(8, 4)
			and _client_bridge.inventory_net.in_flight_count() == 0,
		"and an op on it after the rejoin is confirmed against the same bag on the server"
	)

	# The original connection back, for the section after this one.
	await _disconnect()
	_server_bridge.inventory_key_fn = Callable()
	await _reconnect(SESSION)
	_check(
		_client_bridge.local_player_id == SESSION and _client_player() != null,
		"and the original connection is back for the section after this"
	)

	_done()


## A grenade the server throws is flown by the client too, and goes off where the server says.
##
## The client is told the launch (one PROJECTILE event) and flies its own copy so the arc is
## drawn, and its copy never goes off by itself: the blast, the damage and the shove are the
## server's, and the client is told where with a DETONATE.
func _test_grenade_over_the_wire() -> void:
	_section("a grenade over the wire")
	_server_game.projectiles.clear()
	_client_game.projectiles.clear()

	var outcome := DotWeaponOutcome.new()
	var spawn := DotWeaponSpawn.new()
	spawn.id = &"frag"
	spawn.origin = Vector3(-40, 4, -40)
	spawn.velocity = Vector3(3, 2, 0)
	spawn.gravity_scale = 1.0
	spawn.radius = 0.08
	spawn.splash_radius = 5.2
	spawn.splash_damage = 0.0
	# In the server's own ticks, as dot-weapon hands a spawn over (it scales the pack's
	# 64 Hz rows to the arsenal's rate): one second.
	spawn.fuse_ticks = _server_game.tick_rate
	spawn.life_ticks = _server_game.tick_rate * 2
	outcome.spawns.append(spawn)
	var thrown := _server_game.projectiles.accept(outcome, &"u1")
	_check(thrown == 1 and spawn.fuse_ticks == _server_game.tick_rate,
		"the server flies it as given, not rescaled a second time",
		"fuse %d ticks at %d Hz" % [spawn.fuse_ticks, _server_game.tick_rate])

	var blasts: Array = []
	var on_blast := func(_serial: int, at: Vector3, _radius: float) -> void: blasts.append(at)
	_client_game.projectiles.detonated.connect(on_blast)
	# An Array, because a lambda captures a local by value.
	var server_blasts: Array = []
	var on_server := func(_serial: int, at: Vector3, _radius: float) -> void: server_blasts.append(at)
	_server_game.projectiles.detonated.connect(on_server)

	await _steps(4)
	_check(_client_game.projectiles.live_count() == 1, "the client is told and flies a copy")

	var worst := 0.0
	var client_live_while_server := true
	for i in _server_game.tick_rate - 8:
		await _step()
		var server_live := _server_game.projectiles.flying()
		var client_live := _client_game.projectiles.flying()
		if server_live.is_empty():
			break
		if client_live.is_empty():
			client_live_while_server = false
			break
		worst = maxf(worst, server_live[0].position.distance_to(client_live[0].position))
	print("    the client's copy stayed within %.3f m of the server's" % worst)
	_check(client_live_while_server, "the client's copy lasts as long as the server's")
	_check(worst < 0.5, "and flies the same arc, within half a metre", "%.3f m" % worst)

	await _steps(24)
	_server_game.projectiles.detonated.disconnect(on_server)
	_client_game.projectiles.detonated.disconnect(on_blast)
	var server_at: Vector3 = server_blasts[0] if not server_blasts.is_empty() else Vector3.INF

	_check(_server_game.projectiles.live_count() == 0 and server_blasts.size() == 1, "the server sets it off on its fuse")
	_check(_client_game.projectiles.live_count() == 0 and blasts.size() == 1,
		"and the client's copy goes with it, once", "%d blasts on the client" % blasts.size())
	_check(not blasts.is_empty() and (blasts[0] as Vector3).distance_to(server_at) < 0.05,
		"where the server says, not where the copy was",
		"%s against %s" % [str(blasts[0]) if not blasts.is_empty() else "-", str(server_at)])
	_done()


## The gun a connected client draws takes the server's count once it has gone quiet.
##
## [b]Nothing used to write the server's count back.[/b] The drawn rig simulates from the same
## buttons, so the two agree until a shot is refused or the server refills the gun; from then
## the HUD read the client's own sum for good (game-zombie-zone's 15 / 105). Here the drawn rig
## fires shots the server never hears (a refused shot), and then both fire and the gun in hand
## is asked for again (a refill). Armed: without `PlaygroundPlayerNet._correct_drawn` the
## "takes the server's count" and "the refill reaches the drawn gun" checks fail.
## A downed player is the server's (`PlaygroundDowns` sets `PlaygroundPlayer.downed` every
## tick); the client draws them crawling. Before `net_downed` they stood for the ninety seconds.
func _test_downed_over_the_wire() -> void:
	_section("a downed player is drawn down on the client, and up again")

	var theirs := _server_player()
	var mirror := _client_player()
	if theirs == null or mirror == null:
		_check(false, "both ends have the player")
		_done()
		return

	theirs.downed = true
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(2)
	mirror.face_body()
	var body := mirror.character.body() if mirror.character != null else null
	var figure := body.get_node_or_null(^"Figure") as DotHumanoidFigure if body != null else null
	_check(mirror.downed, "the client hears they are down")
	_check(
		figure != null and figure.downed,
		"and the person crawls",
		"figure %s" % ("missing" if figure == null else str(figure.describe().get("clip", "")))
	)

	theirs.downed = false
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(2)
	mirror.face_body()
	_check(not mirror.downed and figure != null and not figure.downed, "and stands when picked up")
	_done()


func _test_drawn_ammo_corrected() -> void:
	_section("the drawn gun takes the server's ammunition count")

	var theirs := _server_player()
	var mirror := _client_player()
	_client_bridge.ask_weapon(&"zee_smg")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)

	var server_rig: ZeeWeaponRig = theirs.zee_rig as ZeeWeaponRig if theirs != null else null
	# The client's drawn gun, as PlaygroundClient._arm_zee builds it: LOCAL, no authority.
	var drawn: ZeeWeaponRig = PlaygroundZee.arm(mirror, _client_game.weapon_def(&"zee_smg"),
		ZeeWeaponRig.Role.LOCAL, false, _client_game.tick_rate, _tick) if mirror != null else null
	_check(server_rig != null and drawn != null, "a gun on the server and one drawn on the client")
	if server_rig == null or drawn == null:
		_done()
		return

	var full := drawn.arsenal.current().magazine
	var tick_sec := 1.0 / float(maxi(_client_game.tick_rate, 1))
	var settle := int(ceil(PlaygroundZee.SETTLE_SEC / tick_sec)) + 24

	# One tick on both ends, the drawn gun driven the way PlaygroundClient._net_physics does.
	var drive := func(drawn_fire: bool) -> void:
		var buttons := DotFpsCommand.BUTTON_USER_0 if drawn_fire else 0
		var command := PlaygroundZee.command_for(buttons, 0.0, 0.0, PlaygroundZee.slot_of(drawn))
		var _outcome := drawn.simulate_tick(command, _tick)
		PlaygroundZee.note_drawn(mirror, drawn, command, tick_sec)

	# Shots the server never hears.
	for _i in range(40):
		drive.call(true)
		await _step()
	var refused := drawn.arsenal.current().magazine
	_check(refused < full, "the drawn gun fired shots the server did not", "%d of %d" % [refused, full])

	for _i in range(8):
		drive.call(false)
		await _step()
	_check(drawn.arsenal.current().magazine == refused,
		"and is not corrected while the shots could still be in flight")

	for _i in range(settle):
		drive.call(false)
		await _step()
	_check(drawn.arsenal.current().magazine == server_rig.arsenal.current().magazine,
		"once quiet, it takes the server's count",
		"drawn %d, server %d" % [drawn.arsenal.current().magazine, server_rig.arsenal.current().magazine])

	# Both fire, then the gun in hand is asked for again: the server refills its own rig, and
	# says nothing to the drawn one but the snapshot.
	var fire := DotFpsCommand.new()
	fire.set_button(DotFpsCommand.BUTTON_USER_0, true)
	for _i in range(30):
		drive.call(true)
		await _step(fire)
	for _i in range(8):
		drive.call(false)
		await _step()
	var spent := server_rig.arsenal.current().magazine
	_client_bridge.ask_weapon(&"zee_smg")
	_exchange()
	await _steps(4)
	var def := server_rig.current_def()
	_check(theirs.zee_rig == server_rig and spent < def.magazine
		and server_rig.arsenal.current().magazine == def.magazine
		and server_rig.arsenal.ammo().count(def.ammo_type) >= def.reserve,
		"asking for the gun in hand refills it on the server, without a fresh rig",
		"spent to %d, now %d" % [spent, server_rig.arsenal.current().magazine])
	for _i in range(settle):
		drive.call(false)
		await _step()
	_check(drawn.arsenal.current().magazine == def.magazine
		and drawn.arsenal.ammo().count(def.ammo_type) == server_rig.arsenal.ammo().count(def.ammo_type),
		"and the refill reaches the drawn gun",
		"drawn %d / %d" % [drawn.arsenal.current().magazine, drawn.arsenal.ammo().count(def.ammo_type)])

	PlaygroundZee.disarm(mirror)
	_client_bridge.ask_tool(&"phys")
	_exchange()
	await _steps(4)
	_done()


func _test_leave() -> void:
	_section("leaving")

	_server_bridge.remove_peer(CLIENT_PEER)
	_exchange()
	await _steps(4)

	_check(_server_player() == null, "the server drops the player")
	_check(int(_server_bridge.describe()["players"]) == 0, "and their entity")
	_check(_client_player() == null, "and the client is told")
	_done()
