extends "res://examples/headless_playground_part8.gd"

func _test_the_wheel_cycles_tools() -> void:
	_section("the wheel cycles tools")

	var keys := PlaygroundBindings.make()
	var prev_row := {}
	var next_row := {}
	var jump_wheel := 0
	for row in keys.rows:
		var action := StringName(str(row["action"]))
		if action == DotMenuBindings.WEAPON_PREVIOUS_ACTION:
			prev_row = row
		elif action == DotMenuBindings.WEAPON_NEXT_ACTION:
			next_row = row
		elif action == DotMenuBindings.JUMP_ACTION and str(row["default"]).begins_with("Wheel"):
			jump_wheel += 1
	_check(str(prev_row.get("default", "")) == "Wheel up" and str(next_row.get("default", "")) == "Wheel down",
		"the weapon actions default to Wheel up and Wheel down", "%s / %s" % [prev_row.get("default"), next_row.get("default")])
	_check(jump_wheel == 0, "and the wheel is on no jump row", str(jump_wheel))

	var client := PlaygroundClient.new()
	client.name = "WheelClient"
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	client.config = config
	add_child(client)
	for _i in range(4):
		await get_tree().process_frame
	await _gate_opens(client)

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true

	var ring := client._tool_ring()
	_check(ring.size() >= 2 and ring[0] == &"phys", "a client has two or more tools to cycle", str(ring))

	client.mouse_capture_override = true
	client._was_driving = true
	client._set_tool(ring[0])
	client.call("_unhandled_input", down)
	_check(client.tool == ring[1], "a wheel-down press moves one slot on", str(client.tool))
	client.call("_unhandled_input", up)
	_check(client.tool == ring[0], "and a wheel-up press moves one back", str(client.tool))
	client.call("_unhandled_input", up)
	_check(client.tool == ring[ring.size() - 1], "wrapping round past the first", str(client.tool))

	client._set_tool(ring[0])
	var before_holding: bool = client._holding
	client._holding = true
	client.call("_unhandled_input", down)
	_check(client.tool == ring[0], "while holding a prop the wheel does not change tools", str(client.tool))
	client._holding = before_holding

	client.queue_free()
	await get_tree().process_frame
	_done()


var _g_bot: PlaygroundPlayer
var _g_launched_at
var _g_danger_heard: bool
var _g_lowest
var _g_soldier_body: Node3D
var _g_soldier_health
var _g_crate_body: RigidBody3D
var _g_crate_start
var _g_blasts: Array
var _g_on_blast
var _g_ticks: int
var _g_bounced: bool
var _g_at: Vector3
var _g_stood
var _g_rocket_blasts: Array
var _g_on_rocket

func _test_grenades() -> void:
	_section("grenades and rockets fly")
	await _sandbox_floor()
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	playground.projectiles.clear()

	_g_bot = playground.players[&"bot"]
	_g_bot.teleport(Vector3(0, 1.0, 12.0), 0.0)
	await get_tree().physics_frame

	# A crate and a soldier where it rolls to under sv_grenade_friction's default, a little apart.
	var crate := playground.props.spawn(&"crate", &"bot", Vector3(1.5, 0.6, -10.0))
	var soldier := playground.props.spawn(&"npc_soldier", &"bot", Vector3(-1.5, 1.2, -10.0))
	await get_tree().physics_frame
	await get_tree().physics_frame

	var rig := PlaygroundZee.arm(_g_bot, playground.weapon_def(&"zee_frag"), ZeeWeaponRig.Role.SERVER, true,
		playground.tick_rate, playground.current_tick())
	_check(rig != null, "a player holds a frag")

	var ctx := DotWeaponContext.new()
	ctx.origin = _g_bot.eye_position()
	# Thrown down at the floor ahead, so it lands and rolls between the crate and the
	# soldier rather than sailing over both.
	ctx.direction = Vector3(0, -0.6, -1).normalized()
	ctx.authority = true
	var thrown := 0
	for i in 60:
		ctx.tick = playground.current_tick() + i
		var command := DotWeaponCommand.new()
		command.set_button(DotWeaponCommand.BUTTON_ATTACK, i < 6)
		command.slot = PlaygroundZee.slot_of(rig)
		var outcome := rig.simulate_tick(command, ctx.tick, ctx)
		thrown += outcome.spawns.size()
		playground.player_shots_fired(&"bot", outcome)
		if thrown > 0:
			break
	_check(thrown == 1 and playground.projectiles.live_count() == 1,
		"releasing it throws one grenade, and the game flies it",
		"%d thrown, %d live" % [thrown, playground.projectiles.live_count()])

	_g_launched_at = _g_bot.eye_position()
	_g_danger_heard = false
	_g_lowest = INF
	_g_soldier_body = soldier.node if soldier != null else null
	var soldier_start := _g_soldier_body.global_position if _g_soldier_body != null else Vector3.ZERO
	_g_soldier_health = float(_g_soldier_body.get("health")) if _g_soldier_body != null else 0.0
	_g_crate_body = crate.node as RigidBody3D if crate != null else null
	_g_crate_start = _g_crate_body.global_position if _g_crate_body != null else Vector3.ZERO
	_g_blasts = []
	_g_on_blast = func(serial: int, _g_at: Vector3, radius: float) -> void: _g_blasts.append([serial, _g_at, radius])
	playground.projectiles.detonated.connect(_g_on_blast)
	_g_ticks = 0
	_g_bounced = false
	if not await _test_grenades_2():
		return
	await _test_grenades_3()
	await _test_grenades_4()
	_g_bot = null
	_g_launched_at = null
	_g_lowest = null
	_g_soldier_body = null
	_g_soldier_health = null
	_g_crate_body = null
	_g_crate_start = null
	_g_blasts = []
	_g_on_blast = null
	_g_stood = null
	_g_rocket_blasts = []
	_g_on_rocket = null

func _test_grenades_2() -> bool:

	for i in 128 * 5:
		await get_tree().physics_frame
		_g_ticks += 1
		var live := playground.projectiles.flying()
		if not live.is_empty():
			_g_lowest = minf(_g_lowest, live[0].position.y)
			_g_bounced = _g_bounced or live[0].bounces > 0
			for sound in playground.npc_sounds.audible(live[0].position, playground.npc_world.now(), 1.0):
				if sound.kind == DotNpcAiSounds.Kind.DANGER:
					_g_danger_heard = true
		if not _g_blasts.is_empty():
			break

	playground.projectiles.detonated.disconnect(_g_on_blast)
	_check(_g_danger_heard, "while it is live it is a DANGER on the armed NPCs' board")
	_check(_g_bounced, "it bounces off the floor rather than going off on it")
	_check(_g_lowest > -0.5, "and never falls through the floor", "lowest %.2f" % _g_lowest)
	_check(_g_blasts.size() == 1, "it goes off once, on its fuse",
		"%d blasts in %d ticks" % [_g_blasts.size(), _g_ticks])
	_check(_g_ticks > 128 * 2, "not before the fuse", "%d ticks" % _g_ticks)

	if _g_blasts.is_empty():
		PlaygroundZee.disarm(_g_bot)
		_done()
		return false

	_g_at = _g_blasts[0][1]
	print("    frag thrown from %s went off at %s after %d ticks" % [_g_launched_at, _g_at, _g_ticks])
	_check(_g_at.z < _g_launched_at.z - 3.0, "somewhere in front of the thrower", str(_g_at))
	await get_tree().physics_frame
	await get_tree().physics_frame

	if _g_crate_body != null and is_instance_valid(_g_crate_body) and _g_crate_body.global_position.distance_to(_g_at) < 5.2:
		_check(_g_crate_body.global_position.distance_to(_g_crate_start) > 0.2 or _g_crate_body.linear_velocity.length() > 0.5,
			"a crate inside the blast is thrown",
			"moved %.2f m" % _g_crate_body.global_position.distance_to(_g_crate_start))
	else:
		_check(false, "a crate inside the blast is thrown", "the crate was not in it")

	var soldier_gap := _g_soldier_body.global_position.distance_to(_g_at) \
		if _g_soldier_body != null and is_instance_valid(_g_soldier_body) else INF
	_check(_g_soldier_body == null or not is_instance_valid(_g_soldier_body)
		or float(_g_soldier_body.get("health")) < _g_soldier_health or soldier_gap > 5.2,
		"the soldier beside it was hurt or was out of the blast when it went off",
		"%.1f m from it" % soldier_gap)
	print("    the soldier was %.1f m from the blast (splash 5.2), at %.0f of %.0f" % [
		soldier_gap, float(_g_soldier_body.get("health")) if is_instance_valid(_g_soldier_body) else 0.0, _g_soldier_health])

	# A grenade cooked past its fuse goes off where it is, so nobody beside it has time to run.
	_g_stood = playground.props.spawn(&"npc_soldier", &"bot", Vector3(-8, 1.2, -8))
	await get_tree().physics_frame
	return true

func _test_grenades_3() -> void:
	if _g_stood != null:
		var stood_health := float(_g_stood.node.get("health"))
		var cooked := DotWeaponSpawn.new()
		cooked.id = &"frag"
		cooked.origin = (_g_stood.node as Node3D).global_position + Vector3(1.0, 0.0, 0.0)
		cooked.splash_radius = 5.2
		cooked.splash_damage = 115.0
		cooked.life_ticks = 4
		var _c := playground.projectiles.launch(cooked, &"bot")
		for i in 3:
			await get_tree().physics_frame
		_check(not is_instance_valid(_g_stood.node) or float(_g_stood.node.get("health")) < stood_health,
			"a soldier a metre from a blast is hurt by it",
			"%.0f of %.0f" % [float(_g_stood.node.get("health")) if is_instance_valid(_g_stood.node) else 0.0, stood_health])
	else:
		_check(false, "a soldier a metre from a blast is hurt by it", "no soldier spawned")
	_check(playground.projectiles.flashes_live() >= 1, "a flash is drawn where it went off")
	PlaygroundZee.disarm(_g_bot)

	# An NPC gets out from under one
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	await get_tree().physics_frame
	var runner := playground.props.spawn(&"npc_soldier", &"bot", Vector3(10, 1.2, -10))
	await get_tree().physics_frame
	var runner_body: Node3D = runner.node if runner != null else null
	var fused := DotWeaponSpawn.new()
	fused.id = &"frag"
	fused.origin = runner_body.global_position + Vector3(0.8, -0.4, 0.0) if runner_body != null else Vector3.ZERO
	fused.gravity_scale = 1.0
	fused.radius = 0.08
	fused.splash_radius = 5.2
	fused.splash_damage = 0.0
	fused.fuse_ticks = 128 * 2
	fused.life_ticks = 128 * 3
	var _f := playground.projectiles.launch(fused, &"bot")
	var start := runner_body.global_position if runner_body != null else Vector3.ZERO
	var farthest := 0.0
	for i in 128 * 2 - 4:
		await get_tree().physics_frame
		if runner_body == null or not is_instance_valid(runner_body):
			break
		farthest = maxf(farthest, runner_body.global_position.distance_to(fused.origin))
	_check(farthest > start.distance_to(fused.origin) + 2.0, "a soldier next to a live grenade runs from it",
		"from %.1f m to at most %.1f m" % [start.distance_to(fused.origin), farthest])
	for i in 16:
		await get_tree().physics_frame
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	# A rocket goes off on contact
	var rocket := DotWeaponSpawn.new()
	rocket.id = &"launcher"
	rocket.origin = Vector3(0, 1.5, 0)
	rocket.velocity = Vector3(0, -30, 0)
	rocket.splash_radius = 3.0
	rocket.splash_damage = 0.0
	rocket.life_ticks = 128 * 4
	_g_rocket_blasts = []
	_g_on_rocket = func(_serial: int, where: Vector3, _radius: float) -> void: _g_rocket_blasts.append(where)
	playground.projectiles.detonated.connect(_g_on_rocket)
	var _r := playground.projectiles.launch(rocket, &"bot")
	for i in 32:
		await get_tree().physics_frame
		if not _g_rocket_blasts.is_empty():
			break

## arena_weapons' thrown set, through the projectile layer: provider ids, AwGrenade flight, zones.
func _test_aw_grenades() -> void:
	_section("arena_weapons grenades")
	var layer: PlaygroundProjectiles = playground.projectiles
	for id: StringName in [&"aw_frag", &"aw_sticky", &"aw_flash", &"aw_smoke", &"aw_incendiary"]:
		_check(PlaygroundZee.pack_def(id) != null, "the provider taught the game %s" % id)
	_check(layer.rules is AwGrenadeRules and layer.rules == playground.grenade_rules
		and playground.grenade_rules.prefix() == "sv_grenade" and playground.grenade_rules.fields().has(&"smoke_seconds"),
		"sv_grenade_* rules are the layer's")

	var frag := _aw_spawn(&"aw_frag", Vector3(30, 1.0, 30), Vector3(3, 2, 0), 40)
	var f := layer.launch(frag, &"bot")
	_check(f != null and f.grenade != null, "a thrown aw_frag flies as an AwGrenade")
	var blasts := []
	var on_blast := func(_s: int, at: Vector3, _r: float) -> void: blasts.append(at)
	layer.detonated.connect(on_blast)
	for i in 80:
		await get_tree().physics_frame
		if not blasts.is_empty():
			break
	layer.detonated.disconnect(on_blast)
	_check(blasts.size() == 1 and layer.live_count() == 0, "and goes off when its fuse runs out")

	var sticky := _aw_spawn(&"aw_sticky", Vector3(30, 1.0, 30), Vector3(0, -2, 0), 200)
	var st := layer.launch(sticky, &"bot")
	for i in 40:
		await get_tree().physics_frame
	_check(st != null and st.grenade != null and st.grenade.stuck, "a sticky grenade sticks where it lands")
	layer.clear()

	var zones := layer.effects
	var smoke := layer.launch(_aw_spawn(&"aw_smoke", Vector3(40, 1.0, 40), Vector3.ZERO, 2), &"bot")
	var fire := layer.launch(_aw_spawn(&"aw_incendiary", Vector3(44, 1.0, 44), Vector3.ZERO, 2), &"bot")
	for i in 8:
		await get_tree().physics_frame
	_check(smoke != null and fire != null and zones.active_smokes() == 1, "a smoke grenade leaves a cloud")
	_check(zones.active_fires() == 1, "an incendiary leaves a fire zone")

	# A flash two metres from the bot, in the open: it is blinded, once, and the ledger holds it.
	_g_bot.teleport(Vector3(50, 1.0, 50), 0.0)
	var told := []
	var on_blind := func(who: StringName, seconds: float) -> void: told.append([who, seconds])
	zones.blinded.connect(on_blind)
	var flash := layer.launch(_aw_spawn(&"aw_flash", Vector3(50, 1.4, 47), Vector3.ZERO, 2), &"u9")
	for i in 8:
		await get_tree().physics_frame
	zones.blinded.disconnect(on_blind)
	_check(flash != null and told.size() == 1 and told[0][0] == &"bot" and float(told[0][1]) > 0.0,
		"a flash blinds a player through the blinded signal", str(told))
	var wire_fire := PlaygroundEvents.write_detonate(3, Vector3(1, 2, 3), 4.0, 2, 7.5)
	var wr := DotNetReader.new(wire_fire)
	var _sub := wr.read_uint(PlaygroundEvents.PROJECTILE_SUB_BITS)
	var rd := PlaygroundEvents.read_detonate(wr)
	_check(bool(rd["ok"]) and int(rd["fx"]) == 2 and absf(float(rd["seconds"]) - 7.5) < 0.001,
		"a detonation carries the utility kind and its seconds", str(rd))
	var plain := DotNetReader.new(PlaygroundEvents.write_detonate(3, Vector3(1, 2, 3), 4.0))
	var _sub2 := plain.read_uint(PlaygroundEvents.PROJECTILE_SUB_BITS)
	var pr := PlaygroundEvents.read_detonate(plain)
	_check(bool(pr["ok"]) and int(pr["fx"]) == 0, "and a plain blast carries none")
	var bl := DotNetReader.new(PlaygroundEvents.write_blind(3.5))
	_check(bl.read_uint(PlaygroundEvents.PROJECTILE_SUB_BITS) == PlaygroundEvents.ProjectileTell.BLIND
		and absf(float(PlaygroundEvents.read_blind(bl)["seconds"]) - 3.5) < 0.01, "a blind tell carries its seconds")
	layer.clear()
	_done()


func _aw_spawn(id: StringName, at: Vector3, velocity: Vector3, fuse: int) -> DotWeaponSpawn:
	var spawn := DotWeaponSpawn.new()
	spawn.id = id
	spawn.origin = at
	spawn.velocity = velocity
	spawn.gravity_scale = 1.0
	spawn.radius = 0.08
	spawn.splash_radius = 4.0
	spawn.splash_damage = 50.0
	spawn.fuse_ticks = fuse
	spawn.life_ticks = 128 * 3
	return spawn

func _test_grenades_4() -> void:
	playground.projectiles.detonated.disconnect(_g_on_rocket)
	_check(_g_rocket_blasts.size() == 1 and absf((_g_rocket_blasts[0] as Vector3).y) < 0.3,
		"a rocket with no fuse goes off where it meets the floor", str(_g_rocket_blasts))

	# What a client is told, and its copy decides nothing
	var spawn := DotWeaponSpawn.new()
	spawn.id = &"sticky"
	spawn.origin = Vector3(1, 2, 3)
	spawn.velocity = Vector3(4.5, 6.25, -7.0)
	spawn.gravity_scale = 1.0
	spawn.radius = 0.08
	spawn.splash_radius = 4.0
	spawn.fuse_ticks = 200
	spawn.life_ticks = 300
	var wire := PlaygroundEvents.write_launch(9, spawn, &"u3", true)
	var reader := DotNetReader.new(wire)
	_check(reader.read_uint(PlaygroundEvents.PROJECTILE_SUB_BITS) == PlaygroundEvents.ProjectileTell.LAUNCH,
		"a launch says it is one")
	var read := PlaygroundEvents.read_launch(reader)
	var back: DotWeaponSpawn = read["spawn"]
	_check(bool(read["ok"]) and int(read["serial"]) == 9 and back.velocity == spawn.velocity
		and back.fuse_ticks == 200 and bool(back.meta[&"sticks"]) and read["owner_id"] == &"u3"
		and back.origin.distance_to(spawn.origin) < 0.01,
		"and carries everything a client flies its copy from", str(read))

	var mirror := PlaygroundProjectiles.new()
	mirror.authority = false
	add_child(mirror)
	var copy := mirror.launch(back, &"u3", RID(), 9)
	for i in 320:
		mirror.tick(1.0 / 128.0)
	_check(mirror.live_count() == 1, "a client's copy does not go off by itself, past its fuse")
	mirror.detonate_remote(9, Vector3(2, 0, 2), 4.0)
	_check(mirror.live_count() == 0 and copy.view == null, "and goes when the server says it went off")
	mirror.queue_free()

	await _test_aw_grenades()
	_done()


var _an_body: Node
var _an_bot: PlaygroundPlayer
var _an_before: float
var _an_rebel: DotPropInstance

func _test_armed_npcs() -> void:
	_section("NPCs with weapons")
	await _sandbox_floor()

	var soldier := playground.props.spawn(&"npc_soldier", &"bot", Vector3(0, 1.2, 0))
	await get_tree().physics_frame
	_check(soldier != null, "a soldier spawns")

	if soldier == null:
		_done()
		return

	_an_body = soldier.node
	_check(String(_an_body.get("weapon_id")) == "zee_smg" and _an_body.call("is_armed"),
		"carrying the weapon its catalogue entry names")
	_check(playground.armed_npcs.has(_an_body), "and the world knows it is armed")
	_check(_an_body.get("brain") != null and _an_body.get("brain").get("squad") != null,
		"with a tactical brain, in its owner's squad")

	_check(playground.set_npc_weapon_choice(&"bot", &"zee_shotgun").ok, "a player picks what their NPCs carry")
	_check(not playground.set_npc_weapon_choice(&"bot", &"zee_frag").ok,
		"and cannot pick a grenade, which an NPC has no arc to throw")
	var shotgunner := playground.props.spawn(&"npc_soldier", &"bot", Vector3(-6, 1.2, 0))
	await get_tree().physics_frame
	_check(shotgunner != null and String(shotgunner.node.get("weapon_id")) == "zee_shotgun",
		"and the next one carries it")
	playground.npc_weapon_choice.erase(&"bot")
	if shotgunner != null:
		playground.props.remove(shotgunner.instance_id)

	# A player's shot hurts it
	_an_bot = playground.players[&"bot"]
	_an_bot.teleport(Vector3(0, 1.0, 12.0), 0.0)
	await get_tree().physics_frame
	var rig := PlaygroundZee.arm(_an_bot, playground.weapon_def(&"zee_rifle"), ZeeWeaponRig.Role.SERVER, true,
		playground.tick_rate, playground.current_tick())
	var target: Node3D = _an_body
	_an_before = float(_an_body.get("health"))
	var ctx := DotWeaponContext.new()
	ctx.origin = _an_bot.eye_position()
	ctx.direction = (target.global_position + Vector3.UP * 0.3 - ctx.origin).normalized()
	ctx.authority = true
	for i in 40:
		ctx.tick = playground.current_tick() + i
		var command := DotWeaponCommand.new()
		command.set_button(DotWeaponCommand.BUTTON_ATTACK, i % 2 == 0)
		command.slot = PlaygroundZee.slot_of(rig)
		var outcome := rig.simulate_tick(command, ctx.tick, ctx)
		playground.player_shots_fired(&"bot", outcome)
		if float(_an_body.get("health")) < _an_before:
			break
	_check(float(_an_body.get("health")) < _an_before, "a player's shot hurts an NPC",
		"%.0f of %.0f" % [float(_an_body.get("health")), _an_before])
	PlaygroundZee.disarm(_an_bot)

	# Replicated
	var net := PlaygroundNpcNet.new()
	net.prop = _an_body
	net.pull()
	_check(net.net_weapon == "zee_smg", "a client is told which weapon it holds")
	net.free()

	# Soldiers and rebels fight each other
	_an_bot.teleport(Vector3(-60.0, 1.0, -60.0), 0.0)
	# Healed first: the player's shots above already hurt it, and a fight measured against
	# that would end before it began.
	_an_body.set("health", float(_an_body.get("max_health")))
	_an_before = float(_an_body.get("max_health"))
	_an_rebel = playground.props.spawn(&"npc_rebel", &"bot", Vector3(0, 1.2, -14))
	await _test_armed_npcs_2()

func _test_armed_npcs_2() -> void:
	await get_tree().physics_frame
	var rebel_body: Node = _an_rebel.node if _an_rebel != null else null
	var fired_before := int((_an_body.get("zee_rig") as ZeeWeaponRig).fire_seq)
	var hurt := false
	for i in 128 * 8:
		await get_tree().physics_frame
		if not is_instance_valid(_an_body) or not is_instance_valid(rebel_body):
			hurt = true
			break
		if float(_an_body.get("health")) < _an_before - 0.1 or float(rebel_body.get("health")) < float(rebel_body.get("max_health")):
			hurt = true
			break
	_check(hurt, "a soldier and a rebel find each other and fight",
		"soldier targets '%s', rebel targets '%s'" % [
			String(_an_body.get("npc").target_id) if is_instance_valid(_an_body) else "(gone)",
			String(rebel_body.get("npc").target_id) if is_instance_valid(rebel_body) else "(gone)",
		])
	_check(not is_instance_valid(_an_body) or int((_an_body.get("zee_rig") as ZeeWeaponRig).fire_seq) > fired_before
		or (rebel_body != null and is_instance_valid(rebel_body) and int((rebel_body.get("zee_rig") as ZeeWeaponRig).fire_seq) > 0),
		"with their own weapons")

	# Death drops the weapon, and walking over it picks it up
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	await get_tree().physics_frame
	var doomed := playground.props.spawn(&"npc_soldier", &"bot", Vector3(0, 1.2, 0))
	await get_tree().physics_frame
	var at: Vector3 = (doomed.node as Node3D).global_position
	var had := float(doomed.node.get("health"))
	var landed: Array = []
	var on_hit := func(by: StringName, victim: int, amount: float, _at: Vector3, killed: bool, _head: bool) -> void:
		landed.append([by, victim, amount, killed])
	playground.hit_landed.connect(on_hit)
	doomed.node.call("take_damage", 9999.0, &"bot")
	playground.hit_landed.disconnect(on_hit)
	_check(landed.size() == 1 and landed[0][0] == &"bot" and DotEntity.kind_of(int(landed[0][1])) == DotEntity.KIND_NPC
		and absf(float(landed[0][2]) - had) < 0.01 and bool(landed[0][3]),
		"the player who killed it is told so, for the health it had rather than the 9999 thrown",
		"%s, had %.0f" % [str(landed), had])
	await get_tree().physics_frame
	var dropped: DotPropInstance = null
	for prop in playground.props.all_props():
		if prop.def != null and String(prop.def.id) == "pickup_zee_smg":
			dropped = prop
	_check(dropped != null, "a soldier that dies drops its weapon")
	_check(playground.armed_npcs.is_empty(), "and is no longer an armed NPC")

	var picked: Array = []
	var on_pick := func(who: StringName, weapon: StringName) -> void: picked.append([who, weapon])
	playground.weapon_picked_up.connect(on_pick)
	_an_bot.teleport(at, 0.0)
	for i in 160:
		await get_tree().physics_frame
		if not picked.is_empty():
			break
	_check(not picked.is_empty() and picked[0][0] == &"bot" and picked[0][1] == &"zee_smg",
		"and the player who walks over it picks it up", str(picked))
	playground.weapon_picked_up.disconnect(on_pick)

	# A weapon spawned from the menu counts against `weapons`
	var placed := playground.props.spawn(Playground.pickup_id_of(&"zee_pistol"), &"bot", Vector3(8, 1, 8))
	_check(placed != null and playground.props.group_count(&"bot", &"weapons") == 1,
		"a weapon put on the ground counts against the weapons limit")

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


var _nc_tick := 100000

## Presses V once (a fresh edge) and returns whether the body is in noclip afterwards.
func _press_noclip(player: PlaygroundPlayer) -> bool:
	for pressed in [true, false]:
		var cmd := DotFpsCommand.new()
		cmd.yaw = player.controller.state.yaw
		cmd.pitch = player.controller.state.pitch
		cmd.buttons = DotFpsCommand.BUTTON_NOCLIP if pressed else 0
		player.controller.apply_command(cmd)
		_nc_tick += 1
		player.controller.simulate_tick(_nc_tick, 1.0 / 60.0)
	return player.controller.state.mode == DotFpsState.Mode.NOCLIP


func _test_noclip_is_a_permission() -> void:
	_section("noclip is a permission")

	var player := playground.add_player(&"nc_bot", "Nc")
	await get_tree().physics_frame
	var saved_mode := playground.config.noclip

	playground.config.noclip = "permission"
	playground.noclip_policy = Callable()
	playground._sync_noclip_permits()
	_check(_press_noclip(player), "solo: V toggles noclip on")
	_check(not _press_noclip(player), "solo: and off again")

	playground.noclip_policy = func(_id: StringName) -> bool: return false
	playground._sync_noclip_permits()
	_check(not _press_noclip(player), "online without permission: V does nothing")

	playground.noclip_policy = func(id: StringName) -> bool: return id == &"nc_bot"
	playground._sync_noclip_permits()
	_check(_press_noclip(player), "online with the group's permission: V toggles noclip")

	playground.noclip_policy = func(_id: StringName) -> bool: return false
	playground._sync_noclip_permits()
	_check(player.controller.state.mode != DotFpsState.Mode.NOCLIP, "losing the permission ends noclip")
	_check(not _press_noclip(player), "and the key is dead again")

	playground.config.noclip = "everyone"
	playground._sync_noclip_permits()
	_check(_press_noclip(player), "mode everyone ignores the policy")
	_check(not _press_noclip(player), "and toggles off")

	playground.config.noclip = "off"
	playground.noclip_policy = Callable()
	playground._sync_noclip_permits()
	_check(not _press_noclip(player), "mode off: not even solo")

	playground.config.noclip = saved_mode
	playground.noclip_policy = Callable()
	playground.remove_player(&"nc_bot")
	_done()


func _test_view_cycle() -> void:
	_section("the view key cycles first, third, selfie")

	var rules := playground.make_view_rules()
	_check(rules.next_mode(&"fp") == &"tp", "fp goes to third person first")
	_check(rules.next_mode(&"tp") == &"selfie", "third person goes to the playground's selfie")
	_check(rules.next_mode(&"selfie") == &"fp", "selfie wraps to first person")

	var stock := DotPlayerViewRules.new()
	_check(stock.next_mode(&"tp") == &"fp" and stock.next_mode(&"fp") == &"tp", "the addon's own cycle is first and third only")

	_check(rules.set_cvar("mp_viewcycle", "fp,selfie") and rules.next_mode(&"fp") == &"selfie", "mp_viewcycle reorders the cycle")
	_check(not rules.set_cvar("mp_viewcycle", ""), "an empty mp_viewcycle is refused")
	_check(rules.set_cvar("mp_viewcycle", "fp,bogus,tp") and rules.next_mode(&"fp") == &"tp", "an unknown id in the cycle is skipped")

	rules.force_view = DotPlayerViewRules.FIRST_ONLY
	_check(rules.next_mode(&"fp") == &"fp", "a forced view does not cycle")
	_done()
