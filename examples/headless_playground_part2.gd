extends "res://examples/headless_playground_part1.gd"

func _check_near(
	value: float, expected: float, epsilon: float, what: String
) -> void:
	_check(
		absf(value - expected) <= epsilon, what,
		"%.4f vs %.4f" % [value, expected]
	)


func _test_buttons_and_doors() -> void:
	_section("buttons, levers and doors")

	# The lobby, whichever map the section before left loaded: the corner this uses is its.
	var on_lobby: DotResult = await playground.change_map(&"pg_flatgrass")
	if not on_lobby.ok:
		_check(false, "the sandbox loads", on_lobby.error.message)
		_done()
		return

	# A player of its own, as the other sections that need a body do: "bot" carries whatever
	# the sections before left it with.
	var player := playground.add_player(&"presser", "Presser")
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	player.teleport(Vector3(-60.0, 1.0, -36.0), 0.0)
	# Landed before the button goes at eye height: a metre's fall is forty ticks.
	await _look(&"presser", 0.0, 90)

	var eye := player.eye_position()
	var button := playground.props.spawn(&"button", &"presser", Vector3(-60.0, eye.y, -38.0))
	DotPhysGun.set_frozen(button, true)
	var lever := playground.props.spawn(&"lever", &"presser", Vector3(-57.0, 0.5, -38.0))
	DotPhysGun.set_frozen(lever, true)
	var door := playground.props.spawn(&"door", &"presser", Vector3(-62.0, 1.3, -44.0))
	await get_tree().physics_frame
	_check(door != null and door.frozen, "a door stands frozen where it is put")
	var shut := (door.node as Node3D).global_transform

	var wire := preload("res://game/toolgun/tool_wire.gd").new()
	var gun := WireGun.new()
	gun.game = playground
	var first: DotResult = wire.primary(gun, {"prop": button})
	var second: DotResult = wire.primary(gun, {"prop": door})
	_check(first.ok and second.ok and playground.io.links_from(button.instance_id).size() == 1,
		"the Wire mode wires the button to the door", "%s / %s" % [first.error if not first.ok else "ok", second.error if not second.ok else "ok"])
	var from_door: DotResult = wire.primary(gun, {"prop": door})
	_check(from_door.ok and not wire.pending.is_empty(), "a door can start a wire too: it says opened and closed")
	wire.cancel()

	var used := playground.use_vehicle(&"presser")
	_check(used.ok and playground.door_is_open(door.instance_id), "F on the button opens the door", used.error.message if not used.ok else "")
	for i in range(int(playground.DOOR_SECONDS * playground.tick_rate) + 4):
		await get_tree().physics_frame
	var swung := shut.basis.z.angle_to((door.node as Node3D).global_transform.basis.z)
	_check(is_equal_approx(playground.door_swing(door.instance_id), 1.0) and absf(rad_to_deg(swung) - 90.0) < 2.0,
		"and it swings a quarter turn about its hinge", "%.1f degrees" % rad_to_deg(swung))
	var hinge := shut * Vector3(-1.0, 0.0, 0.0)
	_check(((door.node as Node3D).global_transform * Vector3(-1.0, 0.0, 0.0)).distance_to(hinge) < 0.01, "the hinge edge stays where it was")

	var again := playground.use_vehicle(&"presser")
	for i in range(int(playground.DOOR_SECONDS * playground.tick_rate) + 4):
		await get_tree().physics_frame
	_check(again.ok and not playground.door_is_open(door.instance_id) and (door.node as Node3D).global_transform.is_equal_approx(shut),
		"F again closes it, back where it stood", "%s, open %s, at %s vs %s" % [again.error.message if not again.ok else "ok", playground.door_is_open(door.instance_id), (door.node as Node3D).global_transform.origin, shut.origin])

	# A lever sets rather than flips: on is open, off is shut.
	var _lw := playground.io.link(lever.instance_id, &"switched", door.instance_id, &"toggle")
	player.teleport(Vector3(-57.0, 1.0, -36.0), 0.0)
	# Down at the lever on the floor: the sign of pitch is read off the aim, not assumed.
	await _look(&"presser", 30.0, 4)
	var down := -30.0 if player.aim_direction().y > 0.0 else 30.0
	await _look(&"presser", down, 30)
	var thrown := playground.use_prop(&"presser")
	_check(thrown.ok and playground.door_is_open(door.instance_id), "a lever thrown on opens it",
		"%s; aim %s from %s, lever at %s" % [thrown.error.message if not thrown.ok else "ok", player.aim_direction(), player.eye_position(), lever.position()])
	var _off := playground.use_prop(&"presser")
	_check(not playground.door_is_open(door.instance_id), "and thrown off shuts it")

	playground.props.remove(button.instance_id)
	_check(playground.io.links_to(door.instance_id).size() == 1, "removing the button takes its wire and leaves the lever's")
	_check(not playground.use_prop(&"nobody").ok, "and nobody uses anything from nowhere")

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	playground.remove_player(&"presser")
	_done()


# --- Saved builds ----------------------------------------------------------

func _test_saved_builds() -> void:
	_section("saved builds")

	var on_lobby: DotResult = await playground.change_map(&"pg_flatgrass")
	if not on_lobby.ok:
		_check(false, "the sandbox loads", on_lobby.error.message)
		_done()
		return

	var builder := playground.add_player(&"builder", "Builder")
	playground.props.limits.spawn_interval = 0.0
	builder.teleport(Vector3(-60.0, 1.0, -30.0), 30.0)
	await _look(&"builder", 0.0, 90)
	var at := builder.controller.state.position
	var yaw := builder.controller.state.yaw

	# A small build: two planks welded, a painted crate on top, a big one frozen, and a button
	# wired to a door.
	var a := playground.props.spawn(&"plank", &"builder", at + Vector3(0.0, 0.2, -3.0))
	var b := playground.props.spawn(&"plank", &"builder", at + Vector3(1.0, 0.2, -3.0))
	var crate := playground.props.spawn(&"crate", &"builder", at + Vector3(0.0, 0.8, -3.0))
	var big := playground.props.spawn(&"crate_large", &"builder", at + Vector3(-3.0, 1.0, -3.0))
	var button := playground.props.spawn(&"button", &"builder", at + Vector3(2.0, 1.0, -3.0))
	var door := playground.props.spawn(&"door", &"builder", at + Vector3(4.0, 1.3, -4.0))
	await get_tree().physics_frame
	for p: DotPropInstance in [a, b, crate, big, button]:
		DotPhysGun.set_frozen(p, true)
	var _w: DotResult = playground.constraints.weld(&"builder", a.node as RigidBody3D, b.node as RigidBody3D, a.position())
	(crate.node as PlaygroundProp).set_tint(Color(0.2, 0.4, 0.9))
	var _grown := (big.node as PlaygroundProp).set_size_scale(1.5)
	# Physics the edit mode changed: no gravity, twice as heavy, slippery and bouncy.
	ToolPhysprop._apply(big.node as RigidBody3D, false, 2.0, 0.3, 0.6)
	var _wire := playground.io.link(button.instance_id, &"pressed", door.instance_id, &"toggle")
	var before := {}
	for p in playground.props.props_of(&"builder"):
		before[p.def.id] = before.get(p.def.id, []) + [(p.node as Node3D).global_transform]

	var store := PlaygroundBuilds.new()
	store.directory = "user://test_builds"
	DotPaths.remove_tree(store.directory)
	var doc := store.capture(playground, &"builder", at, yaw)
	_check(doc.ok and (doc.value["props"] as Array).size() == 6 and (doc.value["links"] as Array).size() == 1
		and (doc.value["wires"] as Array).size() == 1, "a build captures its props, its weld and its wire", str(doc.error) if not doc.ok else "")
	_check(store.save("key:1", "bridge", doc.value).ok and store.names("key:1") == PackedStringArray(["bridge"]), "it is saved under the player's key")
	_check(not store.save("key:1", "../escape", doc.value).ok, "and a name that is a path is refused")

	playground.props.clear_player(&"builder")
	await get_tree().physics_frame
	var loaded := store.load_build("key:1", "bridge")
	var placed := store.place(playground, &"builder", loaded.value, at, yaw)
	await get_tree().physics_frame
	_check(placed.ok and int(placed.value) == 6 and playground.props.props_of(&"builder").size() == 6,
		"loaded back, every prop is there again", str(placed.error) if not placed.ok else "")

	var worst := 0.0
	for p in playground.props.props_of(&"builder"):
		var nearest := INF
		for t: Transform3D in before.get(p.def.id, []):
			nearest = minf(nearest, t.origin.distance_to((p.node as Node3D).global_position))
		worst = maxf(worst, nearest)
	_check(worst < 0.01, "where they stood", "%.4f m off" % worst)
	var again := playground.props.props_of(&"builder")
	var painted := again.filter(func(p: DotPropInstance) -> bool: return p.def.id == &"crate")
	var grown := again.filter(func(p: DotPropInstance) -> bool: return p.def.id == &"crate_large")
	# Paint is kept as an HTML colour, so to the nearest 1/255.
	var paint: Color = (painted[0].node as PlaygroundProp).tint if not painted.is_empty() else Color.BLACK
	var paint_off := absf(paint.r - 0.2) + absf(paint.g - 0.4) + absf(paint.b - 0.9)
	_check(paint_off < 0.02 and not grown.is_empty() and is_equal_approx((grown[0].node as PlaygroundProp).size_scale, 1.5) and grown[0].frozen,
		"painted, resized and frozen as they were", "paint %s, scale %s, frozen %s" % [paint,
			(grown[0].node as PlaygroundProp).size_scale if not grown.is_empty() else -1.0, grown[0].frozen if not grown.is_empty() else false])
	var big_body: RigidBody3D = grown[0].node as RigidBody3D if not grown.is_empty() else null
	_check(big_body != null and big_body.gravity_scale == 0.0
		and is_equal_approx(big_body.mass, big.def.mass * pow(1.5, 3.0) * 2.0)
		and big_body.physics_material_override != null
		and is_equal_approx(big_body.physics_material_override.friction, 0.3)
		and is_equal_approx(big_body.physics_material_override.bounce, 0.6),
		"and with the gravity, weight, friction and bounce it was edited to",
		"gravity %.1f, %.1f kg" % [big_body.gravity_scale, big_body.mass] if big_body != null else "none")
	_check(not (doc.value["props"] as Array).any(func(e: Dictionary) -> bool: return e.has("physics") and str(e["id"]) == "crate"),
		"and a prop nobody edited writes no physics at all")
	var new_button: DotPropInstance = again.filter(func(p: DotPropInstance) -> bool: return p.def.id == &"button")[0]
	_check(playground.constraints.count_owned(&"builder") >= 1 and playground.io.links_from(new_button.instance_id).size() == 1,
		"with the weld and the wire made again")

	# Put down somewhere else, turned: it goes in front of whoever loads it.
	playground.props.clear_player(&"builder")
	var turned := store.place(playground, &"builder", loaded.value, at + Vector3(0.0, 0.0, 20.0), yaw + 90.0)
	var centre := Vector3.ZERO
	for p in playground.props.props_of(&"builder"):
		centre += p.position()
	centre /= maxf(playground.props.props_of(&"builder").size(), 1)
	_check(turned.ok and centre.z > at.z + 15.0, "and loaded elsewhere, it is put down there", "centre %s" % centre)

	# A catalogue that has lost a prop refuses the build by name.
	var broken: Dictionary = (loaded.value as Dictionary).duplicate(true)
	broken["props"][0]["id"] = "crate_old"
	var refused := PlaygroundBuilds.validate(broken, playground.props.catalogue)
	_check(not refused.ok and refused.error.message.contains("crate_old"), "a build with a prop this server lacks is refused by name",
		refused.error.message if not refused.ok else "")

	# Limits are asked first, so nothing appears when it will not all fit.
	playground.props.clear_player(&"builder")
	var old_limits: Dictionary = playground.props.limits.group_limits.duplicate()
	playground.props.limits.group_limits[DotPropDef.GROUP_PROPS] = 3
	var too_big := store.place(playground, &"builder", loaded.value, at, yaw)
	_check(not too_big.ok and playground.props.props_of(&"builder").is_empty(), "a build past the player's limit puts nothing down",
		too_big.error.message if not too_big.ok else "")
	playground.props.limits.group_limits = old_limits

	# What the Q menu's Builds tab is sent: a name, a size, and whether it is a custom prop.
	var listed := store.summaries("key:1")
	_check(listed.size() == 1 and listed[0]["name"] == "bridge" and int(listed[0]["props"]) == 6
		and not bool(listed[0]["custom"]), "a player's builds list with their sizes", str(listed))
	var two_welded := {"props": [{"id": "plank"}, {"id": "plank"}], "links": [{"kind": "weld", "a": 0, "b": 1}]}
	var to_world := {"props": [{"id": "plank"}, {"id": "plank"}], "links": [{"kind": "weld", "a": 0, "b": 1}, {"kind": "weld", "a": 1, "b": -1}]}
	var roped := {"props": [{"id": "plank"}, {"id": "plank"}], "links": [{"kind": "rope", "a": 0, "b": 1}]}
	_check(PlaygroundBuilds.is_custom_prop(two_welded) and not PlaygroundBuilds.is_custom_prop(to_world)
		and not PlaygroundBuilds.is_custom_prop(roped) and not PlaygroundBuilds.is_custom_prop({"props": [{"id": "plank"}]}),
		"a custom prop is two or more props welded into one piece, and nothing welded to the world")
	var wire := PlaygroundEvents.write_builds([{"name": "bridge", "props": 6, "custom": false}, {"name": "car", "props": 9, "custom": true}])
	var back := PlaygroundEvents.read_builds(DotNetReader.new(wire))
	_check(bool(back["ok"]) and (back["builds"] as Array).size() == 2 and back["builds"][1]["name"] == "car"
		and bool(back["builds"][1]["custom"]) and int(back["builds"][0]["props"]) == 6, "and the list crosses the wire whole", str(back))

	DotPaths.remove_tree(store.directory)
	playground.props.clear_player(&"builder")
	playground.remove_player(&"builder")
	_done()


# --- Boot ------------------------------------------------------------------

func _test_boots() -> void:
	_section("booting")

	_check(playground.maps != null, "the map session exists")
	# The run timer is an optional addon (`addons/pg_timer` adapts dot-timer when a server
	# links it), so what is asserted is that the two agree: no addon, no timer.
	_check(
		(playground.run_timer != null) == _timer_linked(),
		"a run timer exists exactly when dot-timer is linked",
		"linked: %s, attached: %s" % [_timer_linked(), playground.run_timer != null]
	)
	_check(playground.props != null, "the prop spawner exists")
	_check(playground.boards != null, "the leaderboards exist")

	# Two built in: the flat grass plane and `pg_generated` -- the one map in this family
	# that is not written down -- and the custom maps game-playground-maps links in, each
	# built by `pg_data`. The count is asserted rather than the ids because a map added
	# and not registered is the failure this is here to catch, and a list of ids would be
	# a second copy of `Playground.map_catalogue()`.
	var data_maps := 0
	for map: DotMapDef in playground.maps.catalogue.maps:
		if map.meta.has("doc"):
			data_maps += 1
	_check(
		playground.maps.catalogue.size() == 2 + CUSTOM_MAPS.size() and data_maps == CUSTOM_MAPS.size(),
		"two maps built in and the custom ones beside them, one of them generated",
		"%d in all, %d documents" % [playground.maps.catalogue.size(), data_maps]
	)
	_check(
		playground.maps.catalogue.has(&"pg_generated"),
		"including the generated one, which is a map def like any other -- a rotation, a "
		+ "ballot and a cooldown work on it without anything opening the scene"
	)
	_check(
		playground.maps.catalogue.problems().is_empty(),
		"and none of them has a problem",
		", ".join(playground.maps.catalogue.problems())
	)
	_check(
		playground.props.catalogue.problems().is_empty(),
		"and neither does the prop catalogue"
	)

	var loaded: DotResult = await playground.change_map(&"pg_flatgrass")
	_check(loaded.ok, "the flat grass map loads",
		loaded.error.message if not loaded.ok else "")
	_check(playground.current_map_node() != null, "and is a PlaygroundMap")

	var player := playground.add_player(&"bot", "Bot")
	_check(player != null, "a player joins")
	_check(
		(player.timer != null) == _timer_linked(),
		"and gets a run timer only when the server has one"
	)

	await get_tree().physics_frame

	_check(
		player.global_position.distance_to(playground.current_map_node().spawn_for(0)) < 1.0,
		"and the player is at the map's spawn"
	)
	_done()


## Whether this checkout has dot-timer linked in, which is what turns `addons/pg_timer` on.
static func _timer_linked() -> bool:
	return FileAccess.file_exists("res://addons/dot_timer/plugin.cfg")


func _test_tick_rate_comes_from_the_engine() -> void:
	_section("the tick rate comes from the engine, which is what a server sets")

	# The chain: an operator writes `sv_tickrate` in server.cfg; dot-server writes
	# `Engine.physics_ticks_per_second`; the playground reads it, and a run timer (when a
	# server links one) adopts it. Getting it wrong does not fail loudly, which is why
	# this is a test rather than a comment; the timer's half is in `_test_the_run_timer`.
	_check(
		playground.tick_rate == Engine.physics_ticks_per_second,
		"the playground counts in the engine's rate",
		"%d vs %d" % [playground.tick_rate, Engine.physics_ticks_per_second]
	)
	_done()


func _test_styles() -> void:
	_section("styles move both halves together")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	_check(playground.set_player_style(&"bot", &"sideways"), "a style can be set")
	_check(
		player.movement_style != null and player.movement_style.id == &"sideways",
		"the movement half is on"
	)
	_check(
		player.timer == null or player.timer.get("style").id == &"sideways",
		"and so is the ranking half, when a run timer is on"
	)
	_check(
		player.controller.style != null
			and player.controller.style.id == &"sideways",
		"and the controller has it, which assigning the property alone would not do"
	)

	# The command filter is the visible half: sideways removes the forward key, and
	# it has to happen before the motor sees the command.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)

	player.controller.apply_command(forward)

	_check_near(
		player.controller.current_command.move.y, 0.0, 0.0001,
		"and the forward key is filtered out of the command"
	)

	# A style change abandons a run, because half a run on each is a run on neither.
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	playground.set_player_style(&"bot", &"low_gravity")

	_check(
		player.timer == null or not player.timer.get("run").is_active(),
		"and changing style leaves no run in progress"
	)
	_check_near(
		player.controller.tunables.gravity, 10.0, 0.01,
		"low gravity halves the gravity the motor reads"
	)

	# Back to normal, and the base is restored rather than compounded — the reason
	# the controller keeps `_base_tunables`.
	playground.set_player_style(&"bot", &"normal")
	_check_near(
		player.controller.tunables.gravity, 20.0, 0.01,
		"and switching back restores it rather than halving it again"
	)
	_done()


## `addons/pg_timer`, the adapter that turns dot-timer on when a server links it: run only
## when `res://addons/dot_timer` is there. What it proves is the chain the playground no
## longer names: the hook found and attached, the manager on the engine's rate, a style
## reaching both halves, a checkpoint, and a run from a START to an END on this map filed
## back through `Playground.run_filed`.
func _test_the_run_timer() -> void:
	_section("the run timer, from addons/pg_timer")

	var timer: Node = playground.run_timer
	_check(timer != null and str(timer.get_script().resource_path).ends_with("pg_timer/playground_hook.gd"),
		"the adapter found the timer and attached itself")
	var manager: Node = timer.get("manager") if timer != null else null
	_check(manager != null and int(manager.get("tick_rate")) == playground.tick_rate,
		"and its manager counts in the playground's rate",
		"%s vs %d" % [str(manager.get("tick_rate")) if manager != null else "none", playground.tick_rate])
	_check(manager != null and bool(manager.call("tick_rate_matches_engine")),
		"so the two agree, which is the misconfiguration that is otherwise silent")

	var player: PlaygroundPlayer = playground.players[&"bot"]
	_check(player.timer != null and player.post_move_fn.is_valid(),
		"a player has a timer and the adapter's after-move hook")

	_check(playground.set_player_style(&"bot", &"sideways")
			and player.timer.get("style").id == &"sideways",
		"a style reaches the ranking half through the adapter")
	playground.set_player_style(&"bot", &"normal")

	playground.spawn_player(&"bot")
	await get_tree().physics_frame
	var home := player.controller.state.position
	var saved: String = timer.call("checkpoint", &"bot", 0)
	player.teleport(home + Vector3(5.0, 0.0, 0.0), player.controller.state.yaw)
	var back: String = timer.call("checkpoint", &"bot", 1)
	_check(saved.begins_with("Checkpoint 1") and player.controller.state.position.distance_to(home) < 0.5,
		"a checkpoint saves and takes the player back", "%s / %s" % [saved, back])
	var _cleared: String = timer.call("checkpoint", &"bot", 2)

	# A course drawn here, by path, the way a map document's zones arrive: a START round
	# the spawn and an END 20 m ahead of where the player faces.
	var zone_script: GDScript = load("res://addons/dot_timer/core/dot_timer_zone.gd")
	var set_script: GDScript = load("res://addons/dot_timer/core/dot_timer_zone_set.gd")
	var kinds: Dictionary = zone_script.get_script_constant_map()["Kind"]
	playground.spawn_player(&"bot")
	await get_tree().physics_frame
	home = player.controller.state.position
	var yaw := player.controller.state.yaw
	var ahead := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var course: Object = set_script.new()
	course.set("map_id", playground.maps.current.id)
	var start: Object = zone_script.call("make", kinds["START"], 0)
	start.call("set_box", home - Vector3(2.0, 1.0, 2.0), home + Vector3(2.0, 3.0, 2.0))
	course.call("add", start)
	var end_at := home + ahead * 20.0
	var finish: Object = zone_script.call("make", kinds["END"], 0)
	finish.call("set_box", end_at - Vector3(4.0, 1.0, 4.0), end_at + Vector3(4.0, 3.0, 4.0))
	course.call("add", finish)
	var bound: DotResult = manager.call("set_zones", course)
	_check(bound.ok, "a zone set binds", bound.error.message if not bound.ok else "")

	var filed := []
	var on_filed := func(id: StringName, time: float, rank: int, reason: String) -> void:
		filed.append([id, time, rank, reason])
	playground.run_filed.connect(on_filed)
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	forward.yaw = yaw
	await _drive(&"bot", forward, playground.tick_rate * 8)
	playground.run_filed.disconnect(on_filed)
	_check(filed.size() == 1 and filed[0][0] == &"bot" and float(filed[0][1]) > 1.0,
		"walking from the start to the end files a run, back through Playground.run_filed",
		str(filed))

	var _unbound: DotResult = manager.call("set_zones", null)
	_done()


func _test_leaderboards() -> void:
	_section("records reach the leaderboards")

	var scope := {
		"map": "pg_flatgrass",
		"track": "0",
		"style": "normal",
	}

	var page: DotResult = await playground.boards.page_async(&"fastest", scope)
	var rows: Array = page.value

	# The run above may or may not have been fast enough to clear the style's
	# minimum time, so this files one directly — what is under test is the path from
	# a record to a board, not the bot's driving.
	if rows.is_empty():
		await playground.boards.submit_async(
			&"fastest", scope, &"bot", "Bot", 42.5
		)
		page = await playground.boards.page_async(&"fastest", scope)
		rows = page.value

	_check(rows.size() >= 1, "there is a time on the board")

	if rows.size() >= 1:
		_check((rows[0] as DotLeaderboardEntry).rank == 1, "ranked first")

	# Faster than whatever is on top, rather than a fixed number: the bot's own time
	# depends on how the run above went, and a hard-coded 20 seconds made this test
	# pass or fail on the bot's driving instead of on the board's ordering.
	var beat := (rows[0] as DotLeaderboardEntry).value - 1.0

	await playground.boards.submit_async(&"fastest", scope, &"other", "Other", beat)

	page = await playground.boards.page_async(&"fastest", scope)
	rows = page.value

	_check(
		(rows[0] as DotLeaderboardEntry).player_id == &"other",
		"a faster time takes the top",
		String((rows[0] as DotLeaderboardEntry).player_id)
	)
	_check(
		(rows[1] as DotLeaderboardEntry).rank == 2,
		"and the ranks are rewritten"
	)

	# A different scope is a different board — the thing a canonical scope key
	# exists to guarantee.
	var other_scope := scope.duplicate()
	other_scope["style"] = "sideways"

	var other: DotResult = await playground.boards.page_async(&"fastest", other_scope)
	_check(
		(other.value as Array).is_empty(),
		"and another style's board is separate"
	)

	# The same scope built in a different order must be the SAME board.
	var reordered := {
		"style": "normal", "map": "pg_flatgrass", "track": "0",
	}
	var same: DotResult = await playground.boards.page_async(&"fastest", reordered)
	_check(
		(same.value as Array).size() == rows.size(),
		"while the same scope in a different order is the same board",
		"%d vs %d" % [(same.value as Array).size(), rows.size()]
	)
	_done()


# --- Props -----------------------------------------------------------------

func _test_props() -> void:
	_section("props")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	playground.props.limits.spawn_interval = 0.0

	var at := player.global_position + Vector3(0.0, 3.0, -4.0)
	var crate := playground.props.spawn(&"crate", &"bot", at)

	_check(crate != null, "a crate spawns")
	_check(playground.props.world_count() == 1, "and is counted")
	_check(
		crate != null and crate.node.get_parent() == playground.world,
		"under the world node the map is in"
	)

	# The physics gun. Grabbed directly rather than through a ray, because what is
	# under test here is the join — the gun, the spawner and the world — and not
	# Godot's raycast, which dot-props covers.
	player.phys_gun.held = crate
	crate.held_by = &"bot"
	player.phys_gun.hold_distance = 4.0

	var origin := player.eye_position()
	var aim := player.aim_direction()

	for _i in range(90):
		player.phys_gun.hold(origin, aim, Basis.IDENTITY, TICK)
		await get_tree().physics_frame

	var goal := origin + aim * player.phys_gun.hold_distance
	_check(
		crate.position().distance_to(goal) < 2.0,
		"a held crate follows the aim",
		"%.2f m away" % crate.position().distance_to(goal)
	)

	player.phys_gun.freeze_held()
	_check(crate.frozen, "and can be frozen in place")
	_check(player.phys_gun.held == null, "which lets go of it")

	# Undo, and then cleanup on leave.
	playground.props.spawn(&"barrel", &"bot", at)
	_check(playground.props.world_count() == 2, "a second prop spawns")
	_check(playground.props.undo(&"bot"), "and can be undone")
	_check(playground.props.world_count() == 1, "leaving the first")

	var node := crate.node

	playground.props.player_left(&"bot")

	_check(playground.props.world_count() == 0, "a departing player's props go")

	await get_tree().process_frame
	await get_tree().process_frame

	_check(not is_instance_valid(node), "and the node is actually freed")
	_done()


# --- Changing maps ---------------------------------------------------------

func _test_map_change() -> void:
	_section("changing map under a live player")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	playground.spawn_player(&"bot")
	playground.props.limits.spawn_interval = 0.0
	playground.props.spawn(
		&"crate", &"bot", player.global_position + Vector3.UP * 3.0
	)

	# Moving, so the change happens with everything in flight — a player in motion (and a
	# run in progress, when a timer is on), a prop in the world, and geometry about to be
	# freed under both.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _drive(&"bot", forward, 200)

	var was_running: bool = player.timer != null and player.timer.get("run").is_active()
	var props_before := playground.props.world_count()

	_check(props_before == 1, "a prop is in the world")

	var changed: DotResult = await playground.change_map(&"pg_generated")

	_check(changed.ok, "the map changes",
		changed.error.message if not changed.ok else "")
	_check(
		playground.maps.current.id == &"pg_generated",
		"and the session is on the new one"
	)
	_check(
		player.timer == null or not player.timer.get("run").is_active(),
		"a run in progress is abandoned rather than carried across",
		"was running: %s" % was_running
	)
	_check(
		playground.props.world_count() == 0,
		"and the props are cleared with the geometry they stood on"
	)
	_check(
		playground.current_map_node() != null
			and playground.current_map_node().get_script() == load("res://maps/pg_generated.gd"),
		"and the new map's node is the one in the world"
	)

	await get_tree().physics_frame

	_check(
		player.global_position.distance_to(
			playground.current_map_node().spawn_for(0)
		) < 2.0,
		"and the player is at the new map's spawn"
	)

	# And the new map is actually runnable: hold jump and forward, and the player
	# should hop rather than walk.
	var hopping := DotFpsCommand.new()
	hopping.move = Vector2(0.0, 1.0)
	hopping.set_button(DotFpsCommand.BUTTON_JUMP, true)

	player.controller.stats.reset()
	await _drive(&"bot", hopping, 400)

	_check(
		player.controller.stats.jumps >= 3,
		"holding jump on the new map produces hops",
		"%d jumps" % player.controller.stats.jumps
	)
	_check(
		player.controller.stats.perfect_jumps > 0,
		"and auto-hop makes them perfect",
		"%d/%d" % [
			player.controller.stats.perfect_jumps,
			player.controller.stats.measured_jumps
		]
	)
	_done()


func _test_map_time_limit() -> void:
	_section("a map that ends on its own")

	# A server that never changes map is not a server. The session says the map is
	# over; the playground decides what happens next — which here is the rotation.
	playground.maps.time_limit.duration = 60.0
	playground.maps.time_limit.warn_at = 10.0
	playground.maps.time_limit.start()

	var was := playground.maps.current.id

	var warned := [0]
	playground.maps.time_warning.connect(func(_left: float) -> void: warned[0] += 1)

	# Advanced through the game's own loop, so this exercises the wiring rather than
	# the time limit in isolation — which dot-map's own suite covers.
	for _i in range(70):
		playground.maps.advance(1.0)

	_check(warned[0] == 1, "the warning fires once", "%d" % warned[0])

	# The change is a coroutine started from a signal, so it lands a frame later.
	for _i in range(10):
		await get_tree().process_frame

	_check(
		playground.maps.current.id != was,
		"and the map changes when the clock runs out",
		"%s -> %s" % [String(was), String(playground.maps.current.id)]
	)
	_check(
		playground.maps.time_limit.running,
		"with the clock restarted on the new one"
	)

	# Rocking the vote.
	playground.maps.time_limit.duration = 3600.0
	playground.maps.time_limit.rtv_min_players = 1
	playground.maps.time_limit.rtv_fraction = 1.0
	playground.maps.time_limit.start()

	var before := playground.maps.current.id

	_check(
		playground.rock_the_vote(&"bot"),
		"one player of one carries a unanimous vote"
	)

	for _i in range(10):
		await get_tree().process_frame

	_check(
		playground.maps.current.id != before,
		"and the map changes",
		"%s -> %s" % [String(before), String(playground.maps.current.id)]
	)

	# A player who leaves takes their vote with them.
	playground.maps.time_limit.start()
	playground.maps.time_limit.rtv_fraction = 0.6
	playground.maps.time_limit.rtv_min_players = 2

	playground.maps.time_limit.rock_the_vote(&"ghost", 4)
	_check(playground.maps.time_limit.rtv_votes() == 1, "a vote is counted")

	playground.remove_player(&"ghost")
	_check(
		playground.maps.time_limit.rtv_votes() == 1,
		"removing somebody who was not playing changes nothing"
	)

	playground.add_player(&"ghost", "Ghost")
	playground.maps.time_limit.rock_the_vote(&"ghost", 4)
	playground.remove_player(&"ghost")

	_check(
		not playground.maps.time_limit.has_rocked(&"ghost"),
		"and a player who leaves takes their vote with them"
	)

	playground.maps.time_limit.duration = 0.0
	playground.maps.time_limit.start()
	_done()
