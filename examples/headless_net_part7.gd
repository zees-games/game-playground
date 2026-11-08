extends "res://examples/headless_net_part6.gd"

## The gun a connected client draws takes the server's count once it has gone quiet.
##
## The drawn rig fires shots the server never hears, then both fire and the gun is refilled; armed without `PlaygroundPlayerNet._correct_drawn`, the "takes the server's count" and refill checks fail.

## A downed player is the server's (`PlaygroundDowns` sets `PlaygroundPlayer.downed` every
## tick); the client draws them crawling.
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


var _dac_theirs: PlaygroundPlayer
var _dac_mirror: PlaygroundPlayer
var _dac_server_rig: ZeeWeaponRig
var _dac_drawn: ZeeWeaponRig
var _dac_settle: int
var _dac_drive
var _dac_spent: int
var _dac_def: DotWeaponDef

func _test_drawn_ammo_corrected() -> void:
	_section("the drawn gun takes the server's ammunition count")

	_dac_theirs = _server_player()
	_dac_mirror = _client_player()
	_client_bridge.ask_weapon(&"zee_smg")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)

	_dac_server_rig = _dac_theirs.zee_rig as ZeeWeaponRig if _dac_theirs != null else null
	# The client's drawn gun, as PlaygroundClient._arm_zee builds it: LOCAL, no authority.
	_dac_drawn = PlaygroundZee.arm(_dac_mirror, _client_game.weapon_def(&"zee_smg"),
		ZeeWeaponRig.Role.LOCAL, false, _client_game.tick_rate, _tick) if _dac_mirror != null else null
	_check(_dac_server_rig != null and _dac_drawn != null, "a gun on the server and one drawn on the client")
	if _dac_server_rig == null or _dac_drawn == null:
		_done()
		return

	var full := _dac_drawn.arsenal.current().magazine
	var tick_sec := 1.0 / float(maxi(_client_game.tick_rate, 1))
	_dac_settle = int(ceil(PlaygroundZee.SETTLE_SEC / tick_sec)) + 24

	# One tick on both ends, the drawn gun driven the way PlaygroundClient._net_physics does.
	_dac_drive = func(drawn_fire: bool) -> void:
		var buttons := DotFpsCommand.BUTTON_USER_0 if drawn_fire else 0
		var command := PlaygroundZee.command_for(buttons, 0.0, 0.0, PlaygroundZee.slot_of(_dac_drawn))
		var _outcome := _dac_drawn.simulate_tick(command, _tick)
		PlaygroundZee.note_drawn(_dac_mirror, _dac_drawn, command, tick_sec)

	# Shots the server never hears.
	for _i in range(40):
		_dac_drive.call(true)
		await _step()
	var refused := _dac_drawn.arsenal.current().magazine
	_check(refused < full, "the drawn gun fired shots the server did not", "%d of %d" % [refused, full])

	for _i in range(8):
		_dac_drive.call(false)
		await _step()
	_check(_dac_drawn.arsenal.current().magazine == refused,
		"and is not corrected while the shots could still be in flight")

	for _i in range(_dac_settle):
		_dac_drive.call(false)
		await _step()
	_check(_dac_drawn.arsenal.current().magazine == _dac_server_rig.arsenal.current().magazine,
		"once quiet, it takes the server's count",
		"drawn %d, server %d" % [_dac_drawn.arsenal.current().magazine, _dac_server_rig.arsenal.current().magazine])

	# Both fire, then the gun in hand is asked for again: the server refills its own rig, and
	# says nothing to the drawn one but the snapshot.
	var fire := DotFpsCommand.new()
	fire.set_button(DotFpsCommand.BUTTON_USER_0, true)
	for _i in range(30):
		_dac_drive.call(true)
		await _step(fire)
	for _i in range(8):
		_dac_drive.call(false)
		await _step()
	_dac_spent = _dac_server_rig.arsenal.current().magazine
	_client_bridge.ask_weapon(&"zee_smg")
	_exchange()
	await _steps(4)
	_dac_def = _dac_server_rig.current_def()
	await _test_drawn_ammo_corrected_2()

func _test_drawn_ammo_corrected_2() -> void:
	_check(_dac_theirs.zee_rig == _dac_server_rig and _dac_spent < _dac_def.magazine
		and _dac_server_rig.arsenal.current().magazine == _dac_def.magazine
		and _dac_server_rig.arsenal.ammo().count(_dac_def.ammo_type) >= _dac_def.reserve,
		"asking for the gun in hand refills it on the server, without a fresh rig",
		"spent to %d, now %d" % [_dac_spent, _dac_server_rig.arsenal.current().magazine])
	for _i in range(_dac_settle):
		_dac_drive.call(false)
		await _step()
	_check(_dac_drawn.arsenal.current().magazine == _dac_def.magazine
		and _dac_drawn.arsenal.ammo().count(_dac_def.ammo_type) == _dac_server_rig.arsenal.ammo().count(_dac_def.ammo_type),
		"and the refill reaches the drawn gun",
		"drawn %d / %d" % [_dac_drawn.arsenal.current().magazine, _dac_drawn.arsenal.ammo().count(_dac_def.ammo_type)])

	PlaygroundZee.disarm(_dac_mirror)
	_client_bridge.ask_tool(&"phys")
	_exchange()
	await _steps(4)
	_done()


func _test_grenade_for_a_joiner() -> void:
	_section("a grenade already in the air is sent to a player who joins")
	await _disconnect()
	_server_game.projectiles.clear()
	_client_game.projectiles.clear()

	var outcome := DotWeaponOutcome.new()
	var spawn := DotWeaponSpawn.new()
	spawn.id = &"frag"
	spawn.origin = Vector3(-40, 8, -40)
	spawn.velocity = Vector3(1, 3, 0)
	spawn.gravity_scale = 1.0
	spawn.radius = 0.08
	spawn.splash_radius = 5.2
	spawn.fuse_ticks = _server_game.tick_rate * 3
	spawn.life_ticks = _server_game.tick_rate * 4
	outcome.spawns.append(spawn)
	_server_game.projectiles.accept(outcome, &"u1")
	await _steps(6)
	_check(_server_game.projectiles.live_count() == 1 and _client_game.projectiles.live_count() == 0,
		"it flies on the server while nobody is connected to be told")

	await _reconnect(SESSION)
	_check(_client_game.projectiles.live_count() == 1,
		"the joiner is told about it on join, not only about launches after",
		"%d on the client" % _client_game.projectiles.live_count())
	var theirs := _client_game.projectiles.flying()
	var ours := _server_game.projectiles.flying()
	_check(not theirs.is_empty() and not ours.is_empty()
			and theirs[0].position.distance_to(ours[0].position) < 3.0,
		"and its copy is near where the server's is, not back at the thrower's hand")
	_server_game.projectiles.clear()
	_client_game.projectiles.clear()
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


## The claim: the aim bit a client sends is the server rig's BUTTON_AIM and the pace of the motor on both ends.
## Armed: with `last_aim` not reaching `PlaygroundZee.command_for` in the bridge, the aimed checks fail.
func _test_the_aim_bit_crosses() -> void:
	_section("the aim bit crosses the wire, slows the player and the prediction agrees")

	var theirs := _server_player()
	var mirror := _client_player()
	_client_bridge.ask_weapon(&"zee_smg")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)
	var rig: ZeeWeaponRig = theirs.zee_rig as ZeeWeaponRig if theirs != null else null
	# The client's drawn gun, as PlaygroundClient._arm_zee builds it, driven with the aim as `_net_physics` does.
	var drawn: ZeeWeaponRig = PlaygroundZee.arm(mirror, _client_game.weapon_def(&"zee_smg"),
		ZeeWeaponRig.Role.LOCAL, false, _client_game.tick_rate, _tick, null, _client_game.ads_rules) if mirror != null else null
	var armed := rig != null and rig.current_def() != null and drawn != null
	_check(armed, "a gun on the server and one drawn on the client")
	if not armed:
		_done()
		return

	var paced := _server_game.ads_rules.move_speed_for(rig.current_def().id)
	var start := theirs.global_position
	var walk_step := func(command: DotFpsCommand, aim: bool) -> void:
		var _o := drawn.simulate_tick(PlaygroundZee.command_for(0, 0.0, 0.0, PlaygroundZee.slot_of(drawn), aim), _tick)
		await _step(command, aim)

	var run := func(direction: Vector2, aim: bool) -> float:
		var walk := DotFpsCommand.new()
		walk.move = direction
		theirs.teleport(start, 0.0)
		for _i in range(INPUT_LEAD + 8):
			await walk_step.call(null, false)
		var from := theirs.controller.state.position
		for _i in range(_server_game.tick_rate / 2):
			await walk_step.call(walk, aim)
		return theirs.controller.state.position.distance_to(from)
	var best := Vector2.ZERO
	var hip_run := 0.0
	for direction: Vector2 in [Vector2(0.0, 1.0), Vector2(1.0, 0.0), Vector2(-1.0, 0.0), Vector2(0.0, -1.0)]:
		var reach: float = await run.call(direction, false)
		if reach > hip_run:
			hip_run = reach
			best = direction
	_check(rig.ads_move_scale() == 1.0, "unaimed, the server's rig does not slow the player")

	var aimed_run: float = await run.call(best, true)
	_check(absf(rig.ads_move_scale() - paced) < 0.001,
		"aimed, the server's rig is at the rules' pace", "scale %.2f of %.2f" % [rig.ads_move_scale(), paced])
	_check(hip_run > 0.5 and absf(aimed_run / hip_run - paced) < 0.1,
		"and the server's body walks at that pace", "hip %.2f m aimed %.2f m, ratio %.2f of %.2f" % [hip_run, aimed_run, aimed_run / maxf(hip_run, 0.001), paced])
	var apart := mirror.controller.state.position.distance_to(theirs.controller.state.position)
	_check(apart < 0.3, "the prediction, slowed alike, agrees with the server", "%.3f m" % apart)

	for _i in range(INPUT_LEAD + 8):
		await walk_step.call(null, false)
	_check(rig.ads_move_scale() == 1.0, "let go, the pace comes back")
	theirs.teleport(start, 0.0)
	await _steps(INPUT_LEAD + 8)
	PlaygroundZee.disarm(mirror)
	_done()


func _test_the_flashlight_crosses() -> void:
	_section("the flashlight is asked for, and the server's state comes back to everybody")

	var theirs := _server_player()
	var mirror := _client_player()
	if theirs == null or mirror == null:
		_check(false, "both ends have the player")
		_done()
		return

	var was := theirs.flashlight
	_client_bridge.ask_flashlight()
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)
	_check(theirs.flashlight != was, "the server switched it")
	_check(mirror.flashlight == theirs.flashlight, "and the owner is told")

	_client_bridge.ask_flashlight()
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)
	_check(theirs.flashlight == was and mirror.flashlight == was, "the next ask switches it back")

	theirs.downed = true
	_client_bridge.ask_flashlight()
	_exchange()
	await _steps(4)
	_check(theirs.flashlight == was, "a downed player's ask is refused")
	theirs.downed = false
	_done()
