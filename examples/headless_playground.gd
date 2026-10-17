extends Node

const PlaygroundBindings := preload("../game/playground_bindings.gd")
const Playground := preload("../game/playground.gd")
const PlaygroundBrowser := preload("../game/client/playground_browser.gd")
const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundGeometry := preload("../game/playground_geometry.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundEntity := preload("../game/entities/playground_entity.gd")
const PlaygroundIcons := preload("../game/playground_icons.gd")
const PlaygroundMapSurvey := preload("../game/playground_map_survey.gd")
const PlaygroundPickup := preload("../game/playground_pickup.gd")
const PlaygroundBuilds := preload("../game/playground_builds.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundProp := preload("../game/playground_prop.gd")
const PlaygroundSpawnMenu := preload("../game/playground_spawn_menu.gd")
const PlaygroundSpawnables := preload("../game/playground_spawnables.gd")
const PgBhopIntro := preload("../maps/pg_bhop_intro.gd")
const PgSurfIntro := preload("../maps/pg_surf_intro.gd")
const PlaygroundVehicle := preload("../game/playground_vehicle.gd")
const PlaygroundWeaponDef := preload("../game/weapons/playground_weapon_def.gd")
const PlaygroundWeapons := preload("../game/playground_weapons.gd")
const PlaygroundZee := preload("../game/playground_zee.gd")
const PlaygroundProjectiles := preload("../game/playground_projectiles.gd")
const PlaygroundEvents := preload("../game/net/playground_events.gd")
const PlaygroundAddons := preload("../game/playground_addons.gd")
const PlaygroundMaterials := preload("../game/playground_materials.gd")
const ToolPhysprop := preload("../game/toolgun/tool_physprop.gd")
const PlaygroundLimits := preload("../game/playground_limits.gd")
const PlaygroundNpcNet := preload("../game/net/playground_npc_net.gd")

## Runs the whole playground: a bot surfs a map from start to finish, its run is
## timed and filed, props are spawned and moved, and the map is changed underneath.
##
## [codeblock]
## godot --headless --path . res://examples/headless_playground.tscn
## [/codeblock]
##
## [b]This is the only thing in the family that runs the joins between these five
## addons.[/b] Each has its own suite and each passes with the others absent, and the
## family's own history says that proves very little: every bug that has cost a day
## here was in a seam — a bridge reconciling on top of another bridge, a client
## message keyed on the wrong id, a value computed and consumed by nothing. So this
## test is about the joins, not about the parts:
##
## - the timer is ticked from the movement loop, with the position the move produced;
## - a style change moves both halves together;
## - a zone's effect reaches the player through the game and not through the timer;
## - a record is filed, scored, and reaches the leaderboard;
## - a map change tears down runs, props and geometry in an order that survives;
## - a prop can be spawned, held, and freed without leaking a node.
##
## The bot's input is a scripted [DotFpsCommand] rather than a device, which is the
## whole reason [DotFpsSampler] is a separate object.

const TICK := 1.0 / 128.0

## Preloaded rather than named: the built-in maps have no `class_name`, deliberately
## — they are content, and a map that reserved a global identifier in every consuming
## project is the thing dot-map exists to avoid.
const PgLobby := preload("res://maps/pg_lobby.gd")

const CHECKS := 1026

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total above is the other half — see docs/testing.md.
const SECTIONS := 54

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var playground: Playground = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	# The real `PlaygroundClient`s below each build a presentation layer, and that layer's
	# settings go to a scratch directory emptied first, never the player's own file (see
	# `PlaygroundPresentation.use_scratch_settings`).
	var _scratch := PlaygroundPresentation.use_scratch_settings("headless_playground")
	_run.call_deferred()


func _run() -> void:
	print("playground — headless integration")
	print("")

	playground = Playground.new()

	var config := PlaygroundConfig.new()
	# Records in memory: a headless run must not write into the user's data
	# directory, and a suite that did could not be run twice with the same result.
	config.records_directory = ""
	# No map on boot: the tests below load their own and would race a boot load.
	config.initial_map = &"pg_lobby"
	config.map_seconds = 0.0
	playground.config = config

	add_child(playground)

	# Two frames: the playground's own `_ready` awaits its first map change, so one
	# is not enough for it to have finished booting.
	await get_tree().process_frame
	await get_tree().process_frame

	# `-- --only=<method>` runs the boot and that one section, for working on it: nothing
	# else runs, so the totals are not checked and the exit code is the section's alone.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			await _test_boots()
			await Callable(self, arg.substr(7)).call()
			print("")
			print("ONLY %s: %d passed, %d failed (totals not checked)" % [arg.substr(7), _passed, _failed])
			for line in _failures:
				print("  FAIL  %s" % line)
			get_tree().quit(1 if _failed > 0 else 0)
			return

	await _test_boots()
	await _test_tick_rate_comes_from_the_engine()
	await _test_zone_file_matches_the_map()
	await _test_surf_run()
	await _test_styles()
	await _test_leaderboards()
	await _test_checkpoints()
	await _test_props()
	await _test_map_change()
	await _test_map_time_limit()
	await _test_props_are_built_from_their_definitions()
	await _test_model_props()
	await _test_entities_run_their_scripts()
	await _test_weapons()
	await _test_zee_weapons()
	await _test_limits_per_kind()
	await _test_the_tool_gun()
	await _test_armed_npcs()
	await _test_addon_hook_and_npc_tools()
	await _test_grenades()
	await _test_spawn_menu()
	await _test_the_sandbox_and_its_course()
	await _test_vehicles()
	await _test_picking_players_up()
	await _test_riding_a_moving_prop()
	await _test_breaking_props()
	await _test_buttons_and_doors()
	await _test_saved_builds()
	await _test_editing_a_selected_prop()
	await _test_the_narrows()
	await _test_the_plunge()
	await _test_the_jump_course()
	await _test_the_switchback()
	await _test_the_ascent()
	await _test_the_cascade()
	await _test_the_long_bank()
	await _test_the_transfer()
	await _test_the_stepping_stones()
	await _test_the_launch()
	await _test_the_relay()
	await _test_the_ladder()
	await _test_the_float()
	await _test_the_drop()
	await _test_the_maps_are_surveyed()
	await _test_nothing_drawn_is_walked_through()
	await _test_a_maps_own_props()
	await _test_toys()
	await _test_every_maps_toys_stand_clear()
	await _test_map_materials()
	await _test_glass()
	await _test_water()
	await _test_ice_slime_foliage()
	await _test_camera_motion()
	await _test_the_client_boots()

	print("")
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [
		_passed, _failed, _completed, _entered
	])

	for line in _failures:
		print("  FAIL  %s" % line)

	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


## The first-person camera's motion, through the client's own `PlaygroundPlayer.present_camera`
## once a physics tick: a drop dips and comes back, a hop does not, a strafe leans each way,
## speed widens the lens, a teleport drops it all, and with every setting at 0 nothing moves.
## Before 2026-10-11 none of it reached the screen (the DotFpsView nothing ran).
func _test_camera_motion() -> void:
	_section("the camera dips, leans and widens, and only when it should")

	var _lobby: DotResult = await playground.change_map(&"pg_lobby")
	var feel := playground.add_player(&"feel", "Feel")
	var camera := Camera3D.new()
	feel.add_child(camera)
	feel.enable_camera_motion()
	for i in 40:
		await get_tree().physics_frame
	var home := feel.controller.state.position
	var yaw := feel.controller.state.yaw
	var dt := 1.0 / float(Engine.physics_ticks_per_second)

	var run := func(command: DotFpsCommand, ticks: int, column: StringName) -> Array:
		feel.controller.apply_command(command)
		var out: Array = []
		for i in ticks:
			await get_tree().physics_frame
			feel.present_camera(camera, dt, 100.0)
			match column:
				&"dip": out.append(feel.camera_motion.eye_drop())
				&"roll": out.append(feel.camera_motion.roll())
				&"fov": out.append(camera.fov)
		return out

	var still := DotFpsCommand.new()
	still.yaw = yaw

	feel.teleport(home + Vector3(0.0, 7.0, 0.0), yaw)
	var drop: Array = await run.call(still, int(1.6 / dt), &"dip")
	_check(drop.min() < -0.04 and absf(float(drop.back())) < 0.005,
		"a 7 m drop dips the eye and it comes back",
		"deepest %.3f m, last %.4f" % [drop.min(), drop.back()])

	var hop := still.duplicate_command()
	hop.set_button(DotFpsCommand.BUTTON_JUMP, true)
	var hops: Array = await run.call(hop, int(1.5 / dt), &"dip")
	_check(hops.min() == 0.0, "a chain of hops (6.8 m/s each) never bobs the view", "deepest %.3f" % hops.min())

	var right := still.duplicate_command()
	right.move = Vector2(1.0, 0.0)
	var left := still.duplicate_command()
	left.move = Vector2(-1.0, 0.0)
	var lean_r: Array = await run.call(right, int(0.8 / dt), &"roll")
	var lean_l: Array = await run.call(left, int(0.8 / dt), &"roll")
	_check(absf(float(lean_r.back())) > 0.4 and absf(float(lean_r.back())) <= 2.0
		and signf(float(lean_r.back())) == -signf(float(lean_l.back())),
		"a strafe leans the view about a degree, each way",
		"right %.2f, left %.2f deg" % [lean_r.back(), lean_l.back()])

	feel.teleport(home + Vector3(0.0, 40.0, 0.0), yaw)
	feel.controller.state.velocity = DotFpsMotor.forward_for(yaw) * 22.0
	var lens: Array = await run.call(still, int(0.8 / dt), &"fov")
	_check(float(lens.back()) > 103.0 and float(lens.back()) < 106.0,
		"at 22 m/s the lens widens a few degrees", "%.2f" % lens.back())
	feel.teleport(home, yaw)
	feel.present_camera(camera, dt, 100.0)
	_check(feel.camera_motion.eye_drop() == 0.0 and feel.camera_motion.roll() == 0.0 and camera.fov == 100.0,
		"and a teleport drops all of it", "fov %.2f" % camera.fov)

	# The control: every setting at 0 and the same drop and strafe move nothing.
	feel.set_camera_motion_scales(0.0, 0.0, 0.0)
	feel.teleport(home + Vector3(0.0, 7.0, 0.0), yaw)
	var flat: Array = await run.call(still, int(1.6 / dt), &"dip")
	var level: Array = await run.call(right, int(0.8 / dt), &"roll")
	_check(flat.min() == 0.0 and level.min() == 0.0 and level.max() == 0.0,
		"with every camera motion setting at 0 nothing moves", "dip %.3f, roll %.2f" % [flat.min(), level.max()])

	playground.remove_player(&"feel")
	_done()


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


func _check_near(
	value: float, expected: float, epsilon: float, what: String
) -> void:
	_check(
		absf(value - expected) <= epsilon, what,
		"%.4f vs %.4f" % [value, expected]
	)


## Runs the simulation for [param ticks], driving [param id] with [param command].
##
## Commands are applied per tick and the physics is stepped per tick, which is what
## makes this reproducible: a test that awaited frames would run a different number of
## simulation ticks on a loaded machine.
func _drive(
	id: StringName, command: DotFpsCommand, ticks: int
) -> void:
	var player: PlaygroundPlayer = playground.players[id]

	for _i in range(ticks):
		player.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame


# --- Picking players up ----------------------------------------------------

## Points [param id] at [param pitch] degrees (yaw 0, so along -Z) for [param ticks] ticks.
func _look(id: StringName, pitch: float, ticks: int) -> void:
	var look := DotFpsCommand.new()
	look.yaw = 0.0
	look.pitch = pitch
	await _drive(id, look, ticks)


func _beam_grab(holder: PlaygroundPlayer) -> DotResult:
	return playground.phys_gun_grab(
		holder, playground.get_world_3d().direct_space_state,
		holder.eye_position(), holder.aim_direction(), Basis.IDENTITY, true
	)


func _test_picking_players_up() -> void:
	_section("picking players up")

	var changed: DotResult = await playground.change_map(&"pg_lobby")
	_check(changed.ok, "the sandbox loads")

	var pickup := playground.pickup
	var holder := playground.add_player(&"holder", "Holder")
	var held := playground.add_player(&"held", "Held")

	# The empty corner the vehicles use, four metres apart along -Z, the holder facing the
	# other. Settled first, so nobody is falling when the beam reaches them.
	holder.teleport(Vector3(-60.0, 1.0, -40.0), 0.0)
	held.teleport(Vector3(-60.0, 1.0, -44.0), 0.0)
	await _look(&"holder", 0.0, 30)
	await _look(&"held", 0.0, 30)
	var floor_y := held.controller.state.position.y

	var took := _beam_grab(holder)
	_check(took.ok, "the physics gun picks up the player in front of it", took.error.message if not took.ok else "")
	_check(pickup.held_by(&"held") == &"holder" and pickup.holding(&"holder") == &"held", "and both ends know who holds whom")
	_check(held.riding, "and the held player stops walking", "a rider with no vehicle: not simulated, not predicted")
	_check(holder.phys_gun.held == null, "and no prop behind them was grabbed as well")

	# Look up: the held player goes up with the beam, whatever their own keys say.
	var up := 40.0
	holder.controller.state.pitch = up
	if holder.aim_direction().y < 0.0:
		up = -up
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	held.controller.apply_command(forward)
	await _look(&"holder", up, 60)
	var lifted := held.controller.state.position.y - floor_y
	_check(lifted > 1.5, "looking up lifts them with the beam", "%.2f m off the floor" % lifted)
	var reach := held.controller.state.position.distance_to(holder.controller.state.position)
	_check(reach < pickup.reach + 1.0, "and they stay on the end of it", "%.2f m from the holder" % reach)
	_check(held.global_position.is_equal_approx(held.controller.state.position), "with the node and the movement state together")

	# Swing the beam down and let go mid-swing: a throw keeps the beam's velocity.
	await _look(&"holder", -up * 0.25, 4)
	playground.phys_gun_release(holder)
	var thrown := held.controller.state.velocity.length()
	_check(not pickup.is_held(&"held") and not held.riding, "letting go puts them back on their own legs")
	_check(thrown > 1.0, "and throws them with the beam's velocity", "%.2f m/s" % thrown)
	await _look(&"held", 0.0, 90)
	_check(held.controller.state.time_since_grounded == 0.0, "and they land on their own feet", "%.2f s airborne" % held.controller.state.time_since_grounded)

	# Immunity by role, and the override.
	held.teleport(Vector3(-60.0, 1.0, -44.0), 0.0)
	await _look(&"holder", 0.0, 20)
	var roles := {&"held": PackedStringArray(["admin"]), &"holder": PackedStringArray()}
	pickup.roles_fn = func(id: StringName) -> PackedStringArray: return roles.get(id, PackedStringArray())
	pickup.immune_roles = PlaygroundPickup.parse_roles("admin, vip")
	took = _beam_grab(holder)
	_check(not took.ok and not pickup.is_held(&"held"), "an immune role cannot be picked up")
	_check(not took.ok and took.error.context.has("pickup"), "and the refusal says it was about a player, not a prop")
	_check(not took.ok and took.error.message.contains("admin"), "naming the role", took.error.message if not took.ok else "")
	_check(holder.phys_gun.held == null, "and nothing behind them is grabbed instead")
	roles[&"holder"] = PackedStringArray(["root"])
	took = _beam_grab(holder)
	_check(took.ok, "an override role picks them up anyway")
	_check(PlaygroundPickup.parse_roles(" admin,,vip  root ") == PackedStringArray(["admin", "vip", "root"]), "a role list parses commas and spaces")

	# A holder who leaves lets go; a held player cannot pick anybody up.
	took = _beam_grab(held)
	_check(not took.ok, "a held player cannot pick anybody up")
	var third := playground.add_player(&"third", "Third")
	third.teleport(Vector3(-60.0, 1.0, -36.0), 180.0)
	await _look(&"third", 0.0, 10)
	playground.remove_player(&"holder")
	await get_tree().physics_frame
	_check(not pickup.is_held(&"held") and not held.riding, "a holder leaving lets go of them")
	_check(pickup.hold_count() == 0, "and holds nobody")

	# Off is off: the beam meets a player and does nothing to them.
	pickup.enabled = false
	held.teleport(Vector3(-60.0, 1.0, -40.0), 0.0)
	# Yaw 0 looks along -Z, from -36 toward them at -40. (It said 180 once, and this check
	# passed with the beam pointed at nobody.)
	var third_look := DotFpsCommand.new()
	third_look.yaw = 0.0
	await _drive(&"third", third_look, 20)
	took = _beam_grab(third)
	# Off, the beam skips players and falls through to the prop gun, which finds no prop.
	_check(not pickup.is_held(&"held") and not took.ok,
		"with picking up off, nobody is held", took.error.message if not took.ok else "held")

	pickup.enabled = true
	pickup.immune_roles = PackedStringArray()
	pickup.roles_fn = Callable()

	# Creative mode: out of anybody's beam, and nobody's beam is theirs.
	held.teleport(Vector3(-60.0, 1.0, -40.0), 0.0)
	await _drive(&"third", third_look, 10)
	var _creative := playground.set_creative(&"held", true)
	took = _beam_grab(third)
	_check(not took.ok and not pickup.is_held(&"held") and took.error.message.contains("creative"),
		"a player in creative mode cannot be picked up", took.error.message if not took.ok else "")
	var _off := playground.set_creative(&"held", false)
	var _creative_third := playground.set_creative(&"third", true)
	took = _beam_grab(third)
	_check(not took.ok and not pickup.is_held(&"held"), "and cannot pick anybody up")
	var _off_third := playground.set_creative(&"third", false)
	took = _beam_grab(third)
	_check(took.ok and pickup.is_held(&"held"), "and with it off, both are ordinary again")
	playground.phys_gun_release(third)

	playground.remove_player(&"held")
	playground.remove_player(&"third")
	_done()


# --- Prop surfing ----------------------------------------------------------

## Moves [param body] at [param velocity] for [param ticks] ticks, written every tick so
## nothing but this moves it, while [param rider] stands still on top.
func _slide(body: RigidBody3D, velocity: Vector3, rider: StringName, ticks: int) -> void:
	var still := DotFpsCommand.new()
	for i in ticks:
		body.linear_velocity = velocity
		body.angular_velocity = Vector3.ZERO
		await _drive(rider, still, 1)


func _test_riding_a_moving_prop() -> void:
	_section("riding a moving prop")

	# The lobby, whichever map the section before left loaded: the corner this uses is its.
	var on_lobby: DotResult = await playground.change_map(&"pg_lobby")
	if not on_lobby.ok:
		_check(false, "the sandbox loads", on_lobby.error.message)
		_done()
		return

	var rider := playground.add_player(&"surfer", "Surfer")
	playground.props.limits.spawn_interval = 0.0
	# A 4 m platform floating in the empty vehicle corner, gravity off so only the test
	# moves it, and the rider stood on its middle.
	var deck := playground.props.spawn(&"platform", &"surfer", Vector3(-60.0, 3.0, -60.0))
	var body := deck.body() as RigidBody3D if deck != null else null
	_check(body != null, "a platform to stand on")
	if body == null:
		_done()
		return
	body.gravity_scale = 0.0
	rider.teleport(Vector3(-60.0, 3.4, -60.0), 0.0)
	await _slide(body, Vector3.ZERO, &"surfer", 30)
	_check(rider.controller.state.is_grounded(), "the rider stands on it",
		"rider y %.2f, deck at %s, rider mask %d node mask %d, deck layer %d, ground %d" % [rider.controller.state.position.y, body.global_position, rider.collision_mask,
			rider.controller.tunables.collision_mask, body.collision_layer, rider.controller.state.ground_id])

	var start := rider.controller.state.position
	var deck_start := body.global_position
	await _slide(body, Vector3(3.0, 0.0, 0.0), &"surfer", 128)
	var moved := rider.controller.state.position.x - start.x
	var deck_moved := body.global_position.x - deck_start.x
	_check(deck_moved > 2.0 and absf(moved - deck_moved) < 0.4,
		"a moving prop carries whoever stands on it", "rider %.2f m, deck %.2f m" % [moved, deck_moved])
	_check(rider.global_position.is_equal_approx(rider.controller.state.position) and rider.controller.state.is_grounded(),
		"and they stay on it, node and state together")

	playground.config.prop_surfing = false
	start = rider.controller.state.position
	deck_start = body.global_position
	await _slide(body, Vector3(-1.0, 0.0, 0.0), &"surfer", 64)
	moved = rider.controller.state.position.x - start.x
	_check(absf(moved) < 0.1 and body.global_position.x - deck_start.x < -0.4,
		"with prop surfing off, the deck slides out from under them", "rider %.2f m" % moved)
	playground.config.prop_surfing = true

	var _gone := playground.props.remove(deck.instance_id)
	playground.remove_player(&"surfer")
	_done()


# --- Destruction -----------------------------------------------------------

func _test_breaking_props() -> void:
	_section("breaking props")

	# The lobby, whichever map the section before left loaded: the corner this uses is its.
	var on_lobby: DotResult = await playground.change_map(&"pg_lobby")
	if not on_lobby.ok:
		_check(false, "the sandbox loads", on_lobby.error.message)
		_done()
		return

	var player: PlaygroundPlayer = playground.players[&"bot"]
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	player.teleport(Vector3(-60.0, 1.0, -60.0), 90.0)
	await get_tree().physics_frame

	var eye := player.eye_position()
	var aim := player.aim_direction()
	var crate := playground.props.spawn(&"crate", &"bot", eye + aim * 4.0)
	await get_tree().physics_frame

	# Off by default: a pistol emptied into a crate shoves it and breaks nothing.
	var rig := PlaygroundZee.arm(
		player, playground.weapon_def(&"zee_pistol"), ZeeWeaponRig.Role.SERVER, true,
		playground.tick_rate, playground.current_tick()
	)
	var _off := _fire_at_crates(rig, player, 120)
	_check(not playground.config.destruction and crate.is_alive(), "with destruction off, shots break nothing")

	# On: the same shots, through the game's own shot handling, take its health and break it.
	playground.config.destruction = true
	var before := playground.props.world_count()
	crate.node.global_position = eye + aim * 4.0
	(crate.node as RigidBody3D).linear_velocity = Vector3.ZERO
	await get_tree().physics_frame
	var landed: Array = []
	var on_hit := func(by: StringName, victim: int, amount: float, _at: Vector3, killed: bool, _head: bool) -> void:
		landed.append([by, victim, amount, killed])
	playground.hit_landed.connect(on_hit)
	var fired := _fire_at_crates(rig, player, 400, crate)
	playground.hit_landed.disconnect(on_hit)
	var crate_key := Playground.hit_victim_id(DotEntity.KIND_PROP, crate.instance_id)
	_check(not landed.is_empty() and landed.all(func(h: Array) -> bool: return h[0] == &"bot" and int(h[1]) == crate_key)
		and bool(landed[landed.size() - 1][3]) and landed.filter(func(h: Array) -> bool: return bool(h[3])).size() == 1,
		"every shot that took health is confirmed to the shooter, the last as the one that broke it",
		"%d confirmations for %d shots" % [landed.size(), fired])
	_check(not crate.is_alive(), "with it on, a pistol shoots a crate apart", "%d shots, health %.0f" % [fired, playground.prop_damage.health_of(crate.instance_id)])
	var pieces := playground.props.all_props().filter(func(p: DotPropInstance) -> bool: return p.def.id == &"debris")
	_check(pieces.size() > 0 and playground.props.world_count() >= before - 1 + pieces.size(),
		"and leaves debris where it was", "%d pieces" % pieces.size())
	_check(pieces.size() > 0 and pieces[0].owner_id == &"", "owned by nobody")
	PlaygroundZee.disarm(player)

	# Debris goes on its own.
	for i in range(int(playground.config.debris_seconds * playground.tick_rate) + 8):
		await get_tree().physics_frame
	var left := playground.props.all_props().filter(func(p: DotPropInstance) -> bool: return p.def.id == &"debris")
	_check(left.is_empty(), "and the debris is cleared up after a few seconds", "%d left" % left.size())

	# A barrel goes up, and a crate beside it goes with it.
	var barrel := playground.props.spawn(&"barrel", &"bot", Vector3(-50.0, 1.0, -60.0))
	var near := playground.props.spawn(&"crate", &"bot", Vector3(-49.0, 0.6, -60.0))
	var far := playground.props.spawn(&"crate", &"bot", Vector3(-40.0, 0.6, -60.0))
	await get_tree().physics_frame
	var _shot := playground.hurt_prop(barrel.node, 100.0, &"bot")
	_check(not barrel.is_alive() and not near.is_alive() and far.is_alive(),
		"a barrel shot open goes up and takes the crate beside it, not the one ten metres off")

	# A protected owner's props do not break.
	var theirs := playground.props.spawn(&"crate", &"other", Vector3(-45.0, 0.6, -55.0))
	playground.props.set_protected(&"other", true)
	_check(not playground.hurt_prop(theirs.node, 100.0, &"bot") and theirs.is_alive(), "a creative builder's crate does not break")
	playground.props.set_protected(&"other", false)
	var slab := playground.props.spawn(&"slab", &"bot", Vector3(-45.0, 1.0, -70.0))
	_check(slab != null and not playground.hurt_prop(slab.node, 1000.0, &"bot") and slab.is_alive(),
		"and a slab, which somebody builds on, has no health to lose", "spawned %s" % (slab != null))

	playground.config.destruction = false
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


## Holds and releases the trigger for up to [param ticks], every outcome through the game's own
## `player_shots_fired`; stops early once [param until] has broken. Returns the shots fired.
func _fire_at_crates(rig: ZeeWeaponRig, player: PlaygroundPlayer, ticks: int, until: DotPropInstance = null) -> int:
	var fired := 0
	var state := player.controller.state
	for i in range(ticks):
		var held := DotFpsCommand.BUTTON_USER_0 if (i / 8) % 2 == 0 else 0
		var outcome := rig.simulate_tick(
			PlaygroundZee.command_for(held, state.yaw, state.pitch, PlaygroundZee.slot_of(rig)),
			playground.current_tick() + i
		) if rig != null else null
		if outcome != null:
			fired += outcome.shots.size()
			playground.player_shots_fired(player.player_id, outcome)
		if until != null and not until.is_alive():
			break
	return fired


# --- Buttons and doors -----------------------------------------------------

## A stand-in for the tool gun: a mode asks its gun for the game and nothing else.
class WireGun:
	extends RefCounted
	var game: Node = null


func _test_buttons_and_doors() -> void:
	_section("buttons, levers and doors")

	# The lobby, whichever map the section before left loaded: the corner this uses is its.
	var on_lobby: DotResult = await playground.change_map(&"pg_lobby")
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

	var on_lobby: DotResult = await playground.change_map(&"pg_lobby")
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
	_check(playground.timers != null, "the timer manager exists")
	_check(playground.props != null, "the prop spawner exists")
	_check(playground.boards != null, "the leaderboards exist")

	# Four built in: the sandbox, two courses, and `pg_generated` -- the one map in this
	# family that is not written down -- and the custom maps game-playground-maps links in,
	# each built by `pg_data`. The count is asserted rather than the ids because a map
	# added and not registered is the failure this is here to catch, and a list of ids
	# would be a second copy of `Playground.map_catalogue()`.
	var data_maps := 0
	for map: DotMapDef in playground.maps.catalogue.maps:
		if map.meta.has("doc"):
			data_maps += 1
	_check(
		playground.maps.catalogue.size() == 4 + CUSTOM_MAPS.size() and data_maps == CUSTOM_MAPS.size(),
		"four maps built in and the custom ones beside them, one of them generated",
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

	var loaded: DotResult = await playground.change_map(&"pg_surf_intro")
	_check(loaded.ok, "the surf map loads",
		loaded.error.message if not loaded.ok else "")
	_check(playground.current_map_node() != null, "and is a PlaygroundMap")

	var player := playground.add_player(&"bot", "Bot")
	_check(player != null, "a player joins")
	_check(player.timer != null, "and gets a timer")
	_check(
		player.timer.zones != null and player.timer.zones.map_id == &"pg_surf_intro",
		"bound to the map's zones"
	)

	# The zones themselves. A start with no end is the commonest thing wrong with a
	# hand-drawn zone file, and it is playable and unfinishable.
	var zones := player.timer.zones
	_check(zones.problems().is_empty(), "the map's zones are well formed",
		", ".join(zones.problems()))
	_check(
		zones.playable_tracks() == PackedInt32Array(
			[DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST, PgSurfIntro.CASCADE_TRACK,
				PgSurfIntro.BANK_TRACK, PgSurfIntro.TRANSFER_TRACK]
		),
		"and all five of its tracks can be run",
		str(zones.playable_tracks())
	)

	# The thin-zone check, at the speed a surfer actually reaches on this map.
	var thin := zones.thin_zones(40.0, playground.tick_rate)
	_check(
		thin.is_empty(),
		"and no zone is thin enough for a fast player to pass through",
		"%d thin" % thin.size()
	)

	await get_tree().physics_frame

	_check(
		player.global_position.distance_to(
			playground.current_map_node().spawn_for(DotTimerTrack.MAIN)
		) < 1.0,
		"and the player is at the map's spawn"
	)
	_done()


func _test_tick_rate_comes_from_the_engine() -> void:
	_section("the tick rate comes from the engine, which is what a server sets")

	# The chain: an operator writes `sv_tickrate` in server.cfg; dot-server writes
	# `Engine.physics_ticks_per_second`; the playground reads it; the timer manager
	# adopts it; and it lands on every record filed.
	#
	# Getting it wrong does not fail loudly — a timer counting 128 a second on a
	# server stepping 64 reports every run at twice its length, and nothing about
	# the run looks unusual — which is why this is a test rather than a comment.
	_check(
		playground.tick_rate == Engine.physics_ticks_per_second,
		"the playground counts in the engine's rate",
		"%d vs %d" % [playground.tick_rate, Engine.physics_ticks_per_second]
	)
	_check(
		playground.timers.tick_rate == playground.tick_rate,
		"and so does the timer manager",
		"%d vs %d" % [playground.timers.tick_rate, playground.tick_rate]
	)
	_check(
		playground.timers.tick_rate_matches_engine(),
		"so the two agree, which is the misconfiguration that is otherwise silent"
	)

	# And the record carries it, which is what settles a dispute afterwards.
	var run := DotTimerRun.make(0, &"normal", playground.timers.timer_for(&"bot").tick_interval()
		if playground.players.has(&"bot") else 1.0 / float(playground.tick_rate))
	run.begin(0.0)
	run.ticks = playground.tick_rate
	run.finish(0.0)

	var record := DotTimerRecord.from_run(run, &"m", &"p", "P")

	_check(
		record.tick_rate == playground.tick_rate,
		"a record is stamped with the rate it was measured at",
		"%d" % record.tick_rate
	)
	_check_near(record.time, 1.0, 0.01, "and its time is that rate's worth of ticks")
	_done()


func _test_zone_file_matches_the_map() -> void:
	_section("the shipped zone files match the geometry")

	# A map's zones and its geometry are built from the same constants here, and a
	# written-out copy of them lives in maps/ to demonstrate the file route that a
	# DELIVERED map has to use. This is the check that the two have not drifted —
	# because a zone file drawn against geometry that has since moved is a
	# leaderboard nobody can compare, and nothing else would ever notice.
	#
	# [b]Every map that builds zones, discovered, and not `pg_surf_intro` alone.[/b]
	# This asked one map's file for as long as it existed, so `pg_lobby`'s and
	# `pg_bhop_intro`'s could drift from their maps with nothing said — game-g2gfast's
	# `_test_zone_files_match` carried the same one-map-short list until it discovered.
	var ids := _zone_map_ids()
	_check(ids.size() == 3, "three maps build zones", str(ids))

	for id in ids:
		var loaded := DotTimerZoneSet.load_json("res://maps/%s.zones.json" % id)
		var built: DotTimerZoneSet = (load("res://maps/%s.gd" % id) as GDScript).build_zones()
		var shipped: DotTimerZoneSet = loaded.value if loaded.ok else null

		_check(
			shipped != null and shipped.fingerprint() == built.fingerprint(),
			"%s's shipped file matches what the map builds" % id,
			loaded.error.message if not loaded.ok
				else "%s vs %s" % [shipped.fingerprint(), built.fingerprint()]
		)

		# `[track-zone-1]`: every route on every map, per track — a start, a finish, a
		# spawn and a pit of its own. Asked of the SHIPPED file as well as the map,
		# because a pitless declaration lives in `meta`, which the fingerprint ignores:
		# a file exported before one was added matches and is still incomplete.
		var incomplete := built.route_problems()
		if shipped != null:
			incomplete.append_array(shipped.route_problems())
		_check(
			shipped != null and incomplete.is_empty(),
			"%s's every route has a start, a finish, a spawn and a pit" % id,
			", ".join(incomplete)
		)
	_done()


## The maps that build their own zones: a script in res://maps with `build_zones`.
##
## The question `tools/export_zones.gd` answers with a list, asked the other way, so
## that a map added to one and not the other is a failure rather than a file nobody
## wrote. `pg_generated` has no zones and is not in it.
func _zone_map_ids() -> Array[String]:
	var out: Array[String] = []

	for file in DirAccess.get_files_at("res://maps"):
		if not file.ends_with(".gd"):
			continue

		var script := load("res://maps/" + file) as GDScript

		for method in script.get_script_method_list():
			if method.name == "build_zones":
				out.append(file.get_basename())
				break

	out.sort()
	return out


# --- A run -----------------------------------------------------------------

func _test_surf_run() -> void:
	_section("a surf run, start to finish")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var started := [0]
	var finished: Array[DotTimerRun] = []

	player.timer.run_started.connect(func(_run: DotTimerRun) -> void: started[0] += 1)
	player.timer.run_finished.connect(
		func(run: DotTimerRun) -> void: finished.append(run)
	)

	# Walk off the start platform and down the valley. The bot holds forward and
	# strafes, which on a surf ramp is what gains speed — see
	# DotFpsMotor.accelerate.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	forward.yaw = 0.0

	await _drive(&"bot", forward, 200)

	_check(started[0] >= 1, "leaving the start zone begins a run", "%d" % started[0])
	_check(player.timer.run.is_running(), "and it is running")

	# Down the ramps. Not grounded, because the ramps are steeper than the player
	# can stand on — which is the whole of surf.
	var airborne := 0
	var top_speed := 0.0
	var entry_z := player.controller.state.position.z
	var deepest_z := entry_z
	var deepest_y := player.controller.state.position.y
	var deepest_x := player.controller.state.position.x

	for i in range(1400):
		var command := DotFpsCommand.new()
		# Strafe alternately, turning with it, which is what a surfer does.
		var phase := (i / 90) % 2
		command.move = Vector2(1.0 if phase == 0 else -1.0, 0.0)
		command.yaw = wrapf(
			(-1.0 if phase == 0 else 1.0) * float(i % 90) * 0.35
			+ (0.0 if phase == 0 else -31.5),
			-180.0, 180.0
		)

		player.controller.apply_command(command)
		await get_tree().physics_frame

		if not player.controller.state.is_grounded():
			airborne += 1

		top_speed = maxf(top_speed, player.speed())

		if player.controller.state.position.z < deepest_z:
			deepest_z = player.controller.state.position.z
			deepest_y = player.controller.state.position.y
			deepest_x = player.controller.state.position.x

		if finished.size() > 0:
			break

	_check(
		airborne > 400,
		"most of the descent is spent not grounded, which is what surf is",
		"%d airborne ticks" % airborne
	)
	_check(top_speed > 12.0, "and the player reaches surf speed",
		"%.1f m/s" % top_speed)

	# What the scripted strafe pattern actually achieves, PRINTED rather than only
	# asserted — see game-arena's "what a bot actually travels at" group and
	# `[bot-drive-1]`. A check's detail line shows only when it fails, so a figure
	# that is merely asserted is a figure nobody reads again once it passes, and
	# every question about how a map should be shaped is a question about this
	# number. The route is %.0f m long; anything short of that is where a bot
	# stops being evidence about the map.
	var travelled := entry_z - deepest_z
	var route := absf(PgSurfIntro.END_Z - PgSurfIntro.START_Z)

	print(
		"        the scripted surfer covered %.1f m of %.1f m (%.0f%%), "
		% [travelled, route, 100.0 * travelled / route]
		+ "ending at x %.1f y %.1f, %d splits crossed"
		% [deepest_x, deepest_y, player.timer.run.splits.size()]
	)

	# Whether the bot happened to reach the finish is not the point — a scripted
	# strafe pattern is not a player. What has to be true is that the run was timed,
	# the statistics were folded in, and the machinery did not fall over.
	_check(
		player.controller.stats.jumps >= 0
			and player.controller.stats.ticks > 1000,
		"the movement statistics accumulated over the run",
		"%d ticks" % player.controller.stats.ticks
	)
	_check(player.controller.motor.stuck_ticks == 0,
		"and the collide-and-slide never ran out of iterations",
		"%d stuck" % player.controller.motor.stuck_ticks)
	_check(
		is_finite(player.controller.state.position.length()),
		"and the position stayed finite"
	)

	# Now finish it deliberately, by putting the player in the finish zone. The
	# route down is a movement question and is tested in dot-player-controller; what is
	# under test HERE is that a crossing produces a timed, filed run.
	if finished.is_empty():
		var zones := player.timer.zones
		var finish := zones.first_of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN)

		player.controller.state.position = finish.centre() + Vector3.UP * 0.5
		player.controller.state.velocity = Vector3(0.0, 0.0, -6.0)

		await _drive(&"bot", forward, 4)

	_check(finished.size() == 1, "the run finishes exactly once",
		"%d" % finished.size())

	if finished.size() == 1:
		_check(finished[0].time() > 0.0, "with a positive time",
			finished[0].formatted_time())
		_check(
			finished[0].status == DotTimerRun.Status.FINISHED,
			"and the run is in the finished state"
		)
		_check(
			finished[0].stats.has("jumps"),
			"and the movement statistics were folded into it",
			str(finished[0].stats.keys())
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
		player.timer.style != null and player.timer.style.id == &"sideways",
		"and so is the ranking half"
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
		not player.timer.run.is_active(),
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


func _test_leaderboards() -> void:
	_section("records reach the leaderboards")

	var scope := {
		"map": "pg_surf_intro",
		"track": "0",
		"style": "normal",
	}

	var page: DotResult = await playground.boards.page(&"fastest", scope)
	var rows: Array = page.value

	# The run above may or may not have been fast enough to clear the style's
	# minimum time, so this files one directly — what is under test is the path from
	# a record to a board, not the bot's driving.
	if rows.is_empty():
		await playground.boards.submit(
			&"fastest", scope, &"bot", "Bot", 42.5
		)
		page = await playground.boards.page(&"fastest", scope)
		rows = page.value

	_check(rows.size() >= 1, "there is a time on the board")

	if rows.size() >= 1:
		_check((rows[0] as DotLeaderboardEntry).rank == 1, "ranked first")

	# Faster than whatever is on top, rather than a fixed number: the bot's own time
	# depends on how the run above went, and a hard-coded 20 seconds made this test
	# pass or fail on the bot's driving instead of on the board's ordering.
	var beat := (rows[0] as DotLeaderboardEntry).value - 1.0

	await playground.boards.submit(&"fastest", scope, &"other", "Other", beat)

	page = await playground.boards.page(&"fastest", scope)
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

	var other: DotResult = await playground.boards.page(&"fastest", other_scope)
	_check(
		(other.value as Array).is_empty(),
		"and another style's board is separate"
	)

	# The same scope built in a different order must be the SAME board.
	var reordered := {
		"style": "normal", "map": "pg_surf_intro", "track": "0",
	}
	var same: DotResult = await playground.boards.page(&"fastest", reordered)
	_check(
		(same.value as Array).size() == rows.size(),
		"while the same scope in a different order is the same board",
		"%d vs %d" % [(same.value as Array).size(), rows.size()]
	)
	_done()


# --- Props -----------------------------------------------------------------

func _test_checkpoints() -> void:
	_section("practice checkpoints, through the game")

	var player: PlaygroundPlayer = playground.players[&"bot"]
	var checkpoints := playground.timers.checkpoints_for(&"bot")

	_check(checkpoints != null, "a player has a checkpoint set")

	if checkpoints == null:
		return

	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _drive(&"bot", forward, 120)

	var somewhere := player.controller.state.position

	checkpoints.save(
		somewhere,
		player.controller.state.velocity,
		player.controller.state.yaw,
		player.controller.state.pitch,
		player.controller.state.is_grounded()
	)

	_check(checkpoints.count() == 1, "a checkpoint is saved")

	await _drive(&"bot", forward, 120)

	_check(
		player.controller.state.position.distance_to(somewhere) > 1.0,
		"the player moves on"
	)

	var restored := checkpoints.load_current()
	_check(restored != null, "and the checkpoint can be restored")

	if restored != null:
		player.teleport(restored.position, restored.yaw)
		player.controller.state.velocity = restored.velocity

		await get_tree().physics_frame

		_check(
			player.controller.state.position.distance_to(somewhere) < 1.0,
			"putting them back where they saved it",
			"%.2f m away" % player.controller.state.position.distance_to(somewhere)
		)
	_done()


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

	# Start a run, so the change happens with everything in flight — a run in
	# progress, a prop in the world, and geometry about to be freed under both.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _drive(&"bot", forward, 200)

	var was_running := player.timer.run.is_active()
	var props_before := playground.props.world_count()

	_check(props_before == 1, "a prop is in the world")

	var changed: DotResult = await playground.change_map(&"pg_bhop_intro")

	_check(changed.ok, "the map changes",
		changed.error.message if not changed.ok else "")
	_check(
		playground.maps.current.id == &"pg_bhop_intro",
		"and the session is on the new one"
	)
	_check(
		not player.timer.run.is_active(),
		"a run in progress is abandoned rather than carried across",
		"was running: %s" % was_running
	)
	_check(
		playground.props.world_count() == 0,
		"and the props are cleared with the geometry they stood on"
	)
	_check(
		player.timer.zones != null
			and player.timer.zones.map_id == &"pg_bhop_intro",
		"the timer is rebound to the new map's zones"
	)

	await get_tree().physics_frame

	_check(
		player.global_position.distance_to(
			playground.current_map_node().spawn_for(DotTimerTrack.MAIN)
		) < 2.0,
		"and the player is at the new map's spawn"
	)

	# And the bhop map is actually runnable: hold jump and forward, and the player
	# should hop rather than walk.
	var hopping := DotFpsCommand.new()
	hopping.move = Vector2(0.0, 1.0)
	hopping.set_button(DotFpsCommand.BUTTON_JUMP, true)

	player.controller.stats.reset()
	await _drive(&"bot", hopping, 400)

	_check(
		player.controller.stats.jumps >= 3,
		"holding jump on the bhop map produces hops",
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


## The stock model props and a dropped-in model.
func _test_model_props() -> void:
	_section("model props and the drop-in folder")

	var on_lobby: DotResult = await playground.change_map(&"pg_lobby")
	if not on_lobby.ok:
		_check(false, "the sandbox loads", on_lobby.error.message)
		_done()
		return

	var catalogue := playground.props.catalogue
	var models: Array[DotPropDef] = []
	var uncredited := 0
	var categories: Dictionary = {}

	var everything: Array[DotPropDef] = []
	for category in catalogue.categories():
		everything.append_array(catalogue.in_category(StringName(category)))

	for def in everything:
		if PlaygroundProp.model_of(def) == "":
			continue
		models.append(def)
		categories[def.category] = true
		var credit: Variant = def.meta.get("credit", {})
		if not (credit is Dictionary) or str((credit as Dictionary).get("author", "")) == "" \
				or str((credit as Dictionary).get("licence", "")) == "":
			uncredited += 1

	_check(models.size() >= 50, "the menu has 50 or more model props", str(models.size()))
	_check(uncredited == 0, "each names an author and a licence", "%d without" % uncredited)
	_check(categories.size() >= 5, "across several categories", str(categories.keys()))

	var player: PlaygroundPlayer = playground.players[&"bot"]
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	player.teleport(Vector3(-60.0, 1.0, -60.0), 90.0)

	var shapeless := 0
	var spawned: Array = []
	var failed_spawns := 0
	var origin := Vector3(-80.0, 1.5, -90.0)

	for i in range(models.size()):
		var at := origin + Vector3(float(i % 12) * 3.5, 0.0, float(i / 12) * 3.5)
		var made := playground.props.spawn(models[i].id, &"bot", at)
		if made == null or made.node == null:
			failed_spawns += 1
			continue
		spawned.append([made, at.y])
		var coll := made.node.get_node_or_null("Collision") as CollisionShape3D
		if coll == null or coll.shape == null or coll.shape is ConcavePolygonShape3D:
			shapeless += 1

	_check(failed_spawns == 0, "every model prop spawns", "%d refused" % failed_spawns)
	_check(shapeless == 0, "each with a collision shape, never a trimesh", "%d without" % shapeless)

	for i in range(150):
		await get_tree().physics_frame

	var fallen := 0
	for pair in spawned:
		var body: Node3D = pair[0].node
		if not is_instance_valid(body) or body.global_position.y < -0.5:
			fallen += 1

	_check(fallen == 0, "and every one stays above the floor", "%d fell through" % fallen)
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	# The drop-in folder: a model with a sidecar, one without, and a hostile sidecar.
	var dir := "user://pg_drop_fixture"
	DirAccess.make_dir_recursive_absolute(dir)
	var src := FileAccess.get_file_as_bytes("res://assets/props/food/apple.glb")
	for file in ["widget", "plain_thing"]:
		var out := FileAccess.open("%s/%s.glb" % [dir, file], FileAccess.WRITE)
		out.store_buffer(src)
		out.close()
	# The atlas a Kenney model names beside itself; a loose model without it logs a load error.
	DirAccess.make_dir_recursive_absolute(dir + "/Textures")
	var atlas := FileAccess.open(dir + "/Textures/colormap.png", FileAccess.WRITE)
	atlas.store_buffer(FileAccess.get_file_as_bytes("res://assets/props/food/Textures/colormap.png"))
	atlas.close()
	var side := FileAccess.open("%s/widget.json" % dir, FileAccess.WRITE)
	side.store_string(JSON.stringify({
		"name": "My widget", "category": "Custom Stuff", "mass": 7.5, "scale": 2.0,
		"icon": "../../etc/passwd"
	}))
	side.close()
	var hostile := FileAccess.open("%s/../pg_drop_fixture/Bad Id!.glb" % dir, FileAccess.WRITE)
	hostile.store_buffer(src)
	hostile.close()

	playground.config.props_dir = dir
	var added := playground.rescan_props()
	_check(added.has("widget") and added.has("plain_thing"), "a model dropped in a folder appears", str(added))

	var widget := catalogue.get_prop(&"widget")
	_check(widget != null and widget.display_name == "My widget", "with the name its sidecar gave")
	_check(widget != null and is_equal_approx(widget.mass, 7.5), "and its mass")
	_check(widget != null and widget.category == &"custom_stuff", "and a category cleaned to an id")
	_check(widget != null and widget.icon_path == "", "a sidecar's icon cannot leave the folder")
	_check(
		catalogue.has(&"plain_thing")
		and catalogue.get_prop(&"plain_thing").category == &"custom",
		"a model with no sidecar lands in the custom category"
	)
	_check(not catalogue.has(&"Bad Id!"), "no id is taken raw from a file name")

	var dropped := playground.props.spawn(&"widget", &"bot", Vector3(-70.0, 1.5, -70.0))
	_check(dropped != null and dropped.node != null, "and it spawns")
	for i in range(60):
		await get_tree().physics_frame
	_check(
		dropped != null and is_instance_valid(dropped.node)
		and (dropped.node as Node3D).global_position.y > -0.5,
		"and rests on the floor"
	)

	var again := playground.rescan_props()
	_check(again.is_empty(), "a second scan adds nothing twice")

	_check(DotPropFolder.sanitize_id("Bad Id!") == "bad_id", "sanitised ids are lower-case words")
	_check(DotPropFolder.sanitize_id("../../x") == "x", "and carry no path")
	_check(not catalogue.has(&"res://assets/props/food/apple.glb"), "a path is not an id")

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


## Every prop this build ships is one scene, and the definition is what differs.
##
## [b]The mass column is the one that matters.[/b] `DotPropDef.mass` is read by
## exactly one thing in dot-props — a physics gun's `grab_mass_limit` — so before the
## spawner put it on the body, a catalogue that said 900 kg and a scene saved at 20 kg
## gave a prop that was refused for being too heavy and then punted like a beach ball.
## Nothing errored, and the two numbers were only ever compared by a player wondering
## why.
func _test_props_are_built_from_their_definitions() -> void:
	_section("props built from their definitions")

	var at := Vector3(0.0, 40.0, 0.0)

	playground.props.limits.spawn_interval = 0.0

	var ball := playground.props.spawn(&"beach_ball", &"bot", at)
	var boulder := playground.props.spawn(
		&"boulder", &"bot", at + Vector3(6.0, 0.0, 0.0)
	)

	_check(ball != null and boulder != null, "two props spawn")

	if ball == null or boulder == null:
		return

	var ball_body := ball.node as PlaygroundProp
	var boulder_body := boulder.node as PlaygroundProp

	_check(
		ball_body != null and boulder_body != null,
		"and both are the project's own configurable body"
	)

	_check_near(ball_body.mass, 2.0, 0.01, "a beach ball weighs what it says")
	_check_near(boulder_body.mass, 900.0, 0.01, "and a boulder weighs what it says")

	# The whole reason for that check: they are the same scene file, so the only
	# thing that can make them different masses is the definition reaching the body.
	_check(
		ball.def.scene_path == boulder.def.scene_path,
		"from one scene, which is why the mass had to come from the definition"
	)

	var ball_shape := (ball_body.get_node("Collision") as CollisionShape3D).shape
	var boulder_shape := (
		boulder_body.get_node("Collision") as CollisionShape3D
	).shape

	_check(ball_shape is SphereShape3D, "a ball is round")
	_check(
		ball_shape is SphereShape3D
		and is_equal_approx((ball_shape as SphereShape3D).radius, 1.2),
		"at the radius its extent asks for"
	)
	_check(
		boulder_shape is SphereShape3D
		and (boulder_shape as SphereShape3D).radius > (
			ball_shape as SphereShape3D
		).radius,
		"and the boulder is bigger than it while weighing 450 times as much"
	)

	var plank := playground.props.spawn(&"plank", &"bot", at + Vector3.UP * 4.0)
	var plank_shape := (
		(plank.node as PlaygroundProp).get_node("Collision") as CollisionShape3D
	).shape

	_check(
		plank_shape is BoxShape3D
		and (plank_shape as BoxShape3D).size.is_equal_approx(
			Vector3(3.0, 0.15, 0.6)
		),
		"and a plank is a plank"
	)

	# The catalogue itself, because the menu is built out of it and a category with
	# nothing in it is a tab that does nothing.
	var catalogue := playground.props.catalogue
	var categories := catalogue.categories()

	_check(catalogue.size() >= 12, "the catalogue has enough in it to build with",
		"%d props" % catalogue.size())
	_check(categories.size() >= 3, "in at least three categories",
		"%s" % ", ".join(categories))

	for category in categories:
		_check(
			not catalogue.in_category(StringName(category)).is_empty(),
			"category '%s' has props in it" % category
		)

	_check(catalogue.problems().is_empty(), "and nothing is wrong with it",
		"; ".join(catalogue.problems()))

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


## Bonus 2: the spiral, and the two things about it that a count cannot check.
##
## [b]Its gaps are checked against the MOVEMENT, not against a number somebody liked.[/b]
## A spiral re-tuned to a larger radius or fewer platforms is a course that cannot be
## finished, and nothing about it looks wrong: the platforms are still there, still
## evenly spaced, still rising. The only thing that says it is broken is a jump arc, so
## that is what this asserts — the same reasoning `dm_atrium`'s stair height needed, one
## dimension over.
func _test_the_tower(playground: Playground, zones: DotTimerZoneSet) -> void:
	var track := DotTimerTrack.BONUS_FIRST + 1

	_check(
		zones.of_kind(DotTimerZone.Kind.START, track).size() == 1,
		"the tower on bonus 2 has one start"
	)
	_check(
		zones.of_kind(DotTimerZone.Kind.END, track).size() == 1,
		"and one finish"
	)
	_check(
		zones.of_kind(DotTimerZone.Kind.STAGE, track).size() == 2,
		"and two splits"
	)
	_check(
		zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"and a spawn and somewhere to land when you come off it, like every route here",
		", ".join(zones.route_problems())
	)

	# [b]Every jump on the spiral, measured box to box against the CLIMBING reach.[/b]
	#
	# What stood here until 2026-09-23 was the error `[reach-1]` found on the jump course
	# two days earlier, one corner over and never asked about: it took the reach from a
	# FLAT jump (airborne 2v/g) off a `DotFpsTunables.new()` — the addon's defaults, with
	# a jump height of 1.1 where the server applies 1.15 — and called 4.64 m a jump on a
	# course that climbs 0.6 m a step, where the real number is 4.02. Then it measured
	# the pad-to-first-platform step centre to centre minus a width, which called 0.2 m
	# of air 3.8 m, and stopped at the sixteenth platform, so the inward jump onto the
	# finish cap — the widest gap on the tower — was never measured by anything. The
	# geometry happened to be fine. The check would have passed a 4.5 m gap nobody can
	# cross, and `_the_old_tower_rule_passes_an_unjumpable_gap` below says so.
	_check_route_reach(PgLobby.tower_route(), "the tower")
	_the_old_tower_rule_passes_an_unjumpable_gap()

	# The splits are HEIGHT bands, and the reason is that a vertical line across a
	# spiral is crossed twice per turn. Two bands at the same height would be the same
	# bug wearing a different hat, so they have to be apart by more than their own
	# thickness.
	var stages := zones.of_kind(DotTimerZone.Kind.STAGE, track)
	var heights: Array[float] = []

	for stage in stages:
		# `centre()`, not an AABB: [DotTimerZone] has no `aabb()` and the first version
		# of this called one. It did not fail the suite — the script error aborted this
		# function and the two checks below it never ran, so the run reported 201 passed
		# and 0 failed while being two checks short. The same hazard as an un-awaited
		# coroutine, reached from a different direction, and the reason a suite's own
		# stderr is worth reading even when it exits 0.
		heights.append(stage.centre().y)

	_check(
		heights.size() == 2 and absf(heights[0] - heights[1]) > 1.0,
		"and its two splits are at different heights",
		"%s; a vertical line across a spiral is crossed twice per turn" % str(heights)
	)

	# The finish is above the pillar, so the last jump is inward rather than round.
	var finish := PgLobby.tower_finish_centre()
	_check(
		absf(finish.x - PgLobby.TOWER_X) < 0.01
			and absf(finish.z - PgLobby.TOWER_Z) < 0.01,
		"and it finishes in the middle, so the last jump is a different jump"
	)


## Whether a jump of [param gap] metres of clear air, landing [param rise] higher, is one
## the movement makes. The one rule every route sweep below asks.
static func _jump_is_inside(gap: float, rise: float) -> bool:
	return rise <= PgLobby.climb_limit() and gap <= PgLobby.jump_reach(rise)


## Sweeps every jump on a route — a list of the boxes a player lands on, in order — and
## asserts each is inside [method _jump_is_inside]. Two checks, and it PRINTS the worst
## jump whether it passes or not, because a check's detail line shows only on failure and
## the number is the thing a person re-tuning the course needs.
##
## Also asserts the rule itself: a jump halfway between the climbing reach and what a
## flat jump off the addon's default tunables says is refused. That is the arithmetic the
## tower was checked with until 2026-09-23, so this is the check that fails if the rule is
## ever "simplified" back to it.
##
## [param walks] names the boxes a player walks off rather than jumps from — the foot of a
## ramp — and those steps are skipped here: a ramp's rise is not a jump's, and the ascent's
## are twice the apex on purpose. Its own section checks them as slopes.
func _check_route_reach(
	route: Array[AABB], name: String, walks: Array[int] = []
) -> void:
	var worst := -INF
	var worst_at := -1
	var worst_gap := 0.0
	var worst_rise := 0.0
	var tallest := 0.0
	var inside := true

	for i in range(1, route.size()):
		if walks.has(i - 1):
			continue

		var gap := PgLobby.gap_between(route[i - 1], route[i])
		var rise := route[i].end.y - route[i - 1].end.y
		tallest = maxf(tallest, rise)

		if not _jump_is_inside(gap, rise):
			inside = false

		# The tightest jump, as a fraction of the reach it has to be made in.
		var reach := PgLobby.jump_reach(rise)
		var used := gap / reach if reach > 0.0 else INF

		if used > worst:
			worst = used
			worst_at = i
			worst_gap = gap
			worst_rise = rise

	print("    %s: %d jumps, the tightest is #%d, %.2f m of air %.2f m up against a %.2f m reach (%.0f%%)" % [
		name, route.size() - 1 - walks.size(), worst_at, worst_gap, worst_rise,
		PgLobby.jump_reach(worst_rise), worst * 100.0,
	])

	_check(
		inside,
		"every jump on %s is inside the climbing reach, box to box" % name,
		"jump #%d is %.2f m of air %.2f m up against a %.2f m reach"
			% [worst_at, worst_gap, worst_rise, PgLobby.jump_reach(worst_rise)]
	)
	_check(
		tallest <= PgLobby.climb_limit(),
		"and no step on %s is also a wall" % name,
		"tallest %.2f m against a %.3f m climb limit" % [tallest, PgLobby.climb_limit()]
	)


## The old tower rule, kept only to be refused: flat airtime, addon default tunables.
func _the_old_tower_rule_passes_an_unjumpable_gap() -> void:
	var defaults := DotFpsTunables.new()
	var launch := sqrt(2.0 * defaults.gravity * defaults.jump_height)
	var old_reach := defaults.max_speed * 2.0 * launch / defaults.gravity
	var real_reach := PgLobby.jump_reach(PgLobby.TOWER_RISE)
	var between := (old_reach + real_reach) * 0.5

	_check(
		between < old_reach and not _jump_is_inside(between, PgLobby.TOWER_RISE),
		"a %.2f m gap a tower step up, which the old flat-jump rule passed, is refused" % between,
		"old reach %.2f, climbing reach %.2f" % [old_reach, real_reach]
	)


## Drives a bot along a route of standable boxes, steering by yaw every tick.
##
## [b]This is what the spiral needed, and it is not air-strafing.[/b] The written reason
## bonus 2 had no drive was that "a spiral is finished by air-strafing round a corner",
## and that was a description of the BOT, not of the course: every bot here held one yaw
## for its whole run, so a course that turned was one it could only ever fall off. A
## course whose gaps are half a reach needs no carried speed at all — it needs a player
## who faces the next platform before jumping at it, and a scripted bot can do that
## exactly, reading the route off the map.
##
## Three rules, and each is a thing a player does:
##
## - **Face the next box's centre, every tick, in the air too.** On the ground that
##   turns the run; in the air it is a brake as much as a steer — `air_accelerate` is
##   100 with a 1 m/s wish cap, so a wish pointed back at a centre the bot has passed
##   takes its speed off within a few ticks, and it lands near the middle rather than
##   off the far side.
## - **Jump on the last grounded tick before the edge**, judged by a point
##   [param look_ahead] metres ahead along the heading leaving the box it stands on.
##   Not jump held: see `_jumping_at` for why that gets a bot nowhere.
## - **What it stands on is decided by where it is**, not by a counter. A bot that falls
##   onto a lower turn of a spiral simply resumes from there, which is how a respawn
##   and a missed landing both come out right without a special case.
##
## [param walks] names the boxes whose next step is WALKED — a ramp up to the next box —
## rather than jumped. Off one of those the bot never jumps, and it counts the ticks it
## spends grounded between the two boxes, which is on the ramp: a drive that finishes
## with none on some ramp got up it some other way.
##
## Returns `{started, finished, splits, reached, ticks, respawns, walked, distance,
## top_speed}`; `reached` is the highest box index stood on, reported so a failure names
## the jump; `walked` maps each of [param walks] to its grounded ramp ticks; `distance` is
## the horizontal ground the bot covered (respawn teleports left out) and `top_speed` its
## fastest horizontal speed, both for `[bot-drive-1]`'s printed pace.
func _drive_route(
	player: PlaygroundPlayer, route: Array[AABB], max_ticks: int,
	look_ahead: float = 0.3, walks: Array[int] = []
) -> Dictionary:
	# Arrays, not locals: a GDScript lambda captures by value.
	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var splits: Array[int] = []
	var respawns: Array[int] = [0]
	var teleports: Array[int] = [0]

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true
	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == player.player_id and zone.kind == DotTimerZone.Kind.RESPAWN:
			respawns[0] += 1
		if id == player.player_id and zone.kind == DotTimerZone.Kind.TELEPORT:
			teleports[0] += 1

	player.timer.run_started.connect(on_start)
	player.timer.stage_reached.connect(on_stage)
	player.timer.run_finished.connect(on_finish)
	playground.timers.effect_requested.connect(on_effect)

	var on := 0
	var reached := 0
	var ticks := 0
	var walked := {}
	# `[bot-drive-1]`: how far the bot actually went and how fast, so a drive that
	# finishes is also a drive whose pace is on the page. Horizontal, and a tick that
	# moved further than any run can (a respawn's teleport) is not counted.
	var distance := 0.0
	var top_speed := 0.0
	var last_at := player.global_position

	# `[surf-ramp-1]`: where the ground and the descent came from — on one of the
	# route's own boxes, in the air, or grounded on something else.
	var tally := _motion_tally()

	for i in walks:
		walked[i] = 0

	for tick in range(max_ticks):
		ticks = tick
		var at := player.global_position
		var grounded := player.controller.state.is_grounded()
		var where := "air"

		if grounded:
			# Highest first: on a spiral a box is directly under another one.
			var on_a_box := false

			for i in range(route.size() - 1, -1, -1):
				if _standing_on(at, route[i]):
					on = i
					on_a_box = true
					break

			if not on_a_box and walked.has(on):
				walked[on] = int(walked[on]) + 1

			where = "on" if on_a_box else "else"

		reached = maxi(reached, on)

		var target := route[mini(on + 1, route.size() - 1)]
		var aim := target.get_center()
		var heading := Vector3(aim.x - at.x, 0.0, aim.z - at.z)

		# Wish along the ERROR, not along the heading: the velocity it wants minus the
		# one it has. On the ground that turns a run 45 degrees in a few ticks instead
		# of carrying the last jump's direction into this one — which is how the first
		# version of this fell off platform 4 every time. In the air it is the only
		# steer there is: a wish along the velocity adds nothing once the speed is past
		# `max_air_wish_speed`, and a wish across it is what air control is for.
		var velocity := player.controller.state.velocity
		var flat := Vector3(velocity.x, 0.0, velocity.z)
		var want := heading.normalized() * PgLobby.MOVE_SPEED
		var wish := want - flat

		if wish.length() < 0.2:
			wish = heading

		var command := DotFpsCommand.new()
		command.move = Vector2(0.0, 1.0)
		command.yaw = rad_to_deg(atan2(-wish.x, -wish.z))

		# Jump on the last grounded tick before the edge, judged along where the bot is
		# actually going rather than where it is facing — OR once the next box is
		# within a body's reach, whichever comes first.
		#
		# The second half is the tower's first jump. The pad's corner is 0.2 m from the
		# first platform's and that platform's UNDERSIDE is 0.2 m above the pad, so a
		# jump taken at the lip puts the body into the platform's side face on the way
		# up and kills every bit of horizontal speed: the first version of this bot
		# bonked on it, dropped off the corner, and was respawned. A player jumps a
		# ledge like that from a stride back, and so does this.
		if grounded and on < route.size() - 1 and not walks.has(on):
			var going := flat if flat.length() > 0.5 else heading
			var ahead := at + going.normalized() * look_ahead
			var close := PgLobby.gap_between(AABB(at, Vector3.ZERO), target) < 1.0
			# Off a box a ramp climbed to, only once actually over it. Near the crest
			# `_standing_on`'s margin already calls the bot on the box while it is still
			# on the ramp, with the look-ahead short of the box too — which reads as "past
			# the edge", and the first drive of the ascent jumped from the top of every
			# ramp across the whole crest into the gap beyond it.
			var arriving := walks.has(on - 1) and not _over(at, route[on])
			if not arriving and (close or not _over(ahead, route[on])):
				command.set_button(DotFpsCommand.BUTTON_JUMP, true)

		player.controller.apply_command(command)
		await get_tree().physics_frame

		var moved := Vector2(
			player.global_position.x - last_at.x, player.global_position.z - last_at.z
		).length()
		if moved < 1.0:
			distance += moved
		_tally_tick(tally, last_at, player.global_position, where)
		last_at = player.global_position
		var now := player.controller.state.velocity
		top_speed = maxf(top_speed, Vector2(now.x, now.z).length())

		if finished[0]:
			# The finish zone reaches a metre under the pad, so a run can end in the
			# air over it before the bot has ever stood there.
			reached = route.size() - 1
			break

	player.timer.run_started.disconnect(on_start)
	player.timer.stage_reached.disconnect(on_stage)
	player.timer.run_finished.disconnect(on_finish)
	playground.timers.effect_requested.disconnect(on_effect)

	# And stop driving. A bot keeps the last command it was given — this file has been
	# bitten by that once already — so a route drive leaves it standing still.
	player.controller.apply_command(DotFpsCommand.new())

	return {
		"started": started[0],
		"finished": finished[0],
		"splits": splits,
		"reached": reached,
		"ticks": ticks,
		"respawns": respawns[0],
		"teleports": teleports[0],
		"walked": walked,
		"distance": distance,
		"top_speed": top_speed,
		"tally": tally,
	}


## Whether a point is over a box seen from above.
static func _over(at: Vector3, box: AABB) -> bool:
	return (
		at.x >= box.position.x and at.x <= box.end.x
		and at.z >= box.position.z and at.z <= box.end.z
	)


## Whether a grounded player at [param at] is standing on [param box]: over it, with a
## margin for the body's radius past the edge, and at its top surface.
static func _standing_on(at: Vector3, box: AABB) -> bool:
	var margin := 0.4
	return (
		at.x >= box.position.x - margin and at.x <= box.end.x + margin
		and at.z >= box.position.z - margin and at.z <= box.end.z + margin
		and absf(at.y - box.end.y) < 0.35
	)


# --- Where a route's ground and descent come from (`[surf-ramp-1]`) -----------

## A tally of one drive's motion, split three ways by what the player was on at the START
## of each tick: [code]on[/code] the thing the route is named for (its platforms, its
## stones, its road), in the [code]air[/code], or grounded on something [code]else[/code].
##
## [b]Why it exists.[/b] `pg_surf_intro`'s main run "surfs" on ramps that are level along
## their length, and every check over it passed about a player who was falling. The
## question that found it — how much of the route's ground and descent happens on the
## surface the route is named after — is asked of every timed route on `pg_lobby` by
## this, and printed.
static func _motion_tally() -> Dictionary:
	var out := {}
	for where in ["on", "air", "else"]:
		out[where] = {"distance": 0.0, "descent": 0.0, "ascent": 0.0, "ticks": 0}
	return out


## One tick's motion into [param tally]. A tick that moved further than any run can, a
## metre sideways or up or down in 1/128 s, is a respawn's teleport and is left out.
static func _tally_tick(tally: Dictionary, before: Vector3, after: Vector3, where: String) -> void:
	var flat := Vector2(after.x - before.x, after.z - before.z).length()
	var dy := after.y - before.y

	if flat >= 1.0 or absf(dy) >= 1.0:
		return

	var bucket: Dictionary = tally[where]
	bucket["distance"] = float(bucket["distance"]) + flat
	bucket["ticks"] = int(bucket["ticks"]) + 1

	if dy < 0.0:
		bucket["descent"] = float(bucket["descent"]) - dy
	else:
		bucket["ascent"] = float(bucket["ascent"]) + dy


## The sum of one field over all three parts of [param tally].
static func _tally_total(tally: Dictionary, field: String) -> float:
	var total := 0.0
	for where in tally:
		total += float((tally[where] as Dictionary)[field])
	return total


## Prints where [param tally]'s ground and descent happened, against the route's own net
## rise ([param route_rise]). [param surface] names what the route is about.
func _print_where(route_name: String, surface: String, tally: Dictionary, route_rise: float) -> void:
	var covered := _tally_total(tally, "distance")
	var descent := _tally_total(tally, "descent")
	var ascent := _tally_total(tally, "ascent")
	var part := func(field: String, where: String, total: float) -> String:
		var value := float((tally[where] as Dictionary)[field])
		return "%.1f (%.0f%%)" % [value, 100.0 * value / maxf(total, 0.001)]

	print("    %s, where the ground went: %.1f m covered: %s on %s, %s in the air, %s on anything else" % [
		route_name, covered, part.call("distance", "on", covered), surface,
		part.call("distance", "air", covered), part.call("distance", "else", covered),
	])
	print("    %s, where the descent came from: %.1f m down (%.1f up, net %+.1f against the route's %+.1f): %s on %s, %s in the air, %s on anything else" % [
		route_name, descent, ascent, ascent - descent, route_rise,
		part.call("descent", "on", descent), surface,
		part.call("descent", "air", descent), part.call("descent", "else", descent),
	])


## The length of a route of boxes as a bot that took every jump straight covers it:
## [param from] to the first box after the pad, then centre to centre, along the ground.
static func _route_length(from: Vector3, route: Array[AABB]) -> float:
	var length := 0.0
	for i in range(1, route.size()):
		var to := route[i].get_center()
		length += Vector2(to.x - from.x, to.z - from.z).length()
		from = to
	return length


## `[bot-drive-1]`: the drive covered at least [param covered_floor] of the route, at a
## pace of at least [param pace_floor] of [param max_speed]. The floors are per route and
## set just under what the bot measured (2026-09-27), because a route with many jumps
## spends time in the air where a bot cannot hold its ground speed; a bot crawling at 40%
## of its speed fails every one of them.
func _check_pace(
	route_name: String, covered: float, length: float, pace: float, max_speed: float,
	pace_floor: float, covered_floor: float = 0.9
) -> void:
	_check(
		covered >= length * covered_floor and pace >= max_speed * pace_floor,
		"%s is covered at a running pace, not a crawl (%.0f%% of the route, %.0f%% of max speed or more)"
			% [route_name, covered_floor * 100.0, pace_floor * 100.0],
		"%.1f m of %.1f at %.2f m/s against %.1f" % [covered, length, pace, max_speed]
	)


## `[surf-ramp-1]`: none of the ground and none of the descent of a drive happened on
## something other than the route's own surface or the air above it.
func _check_where(route_name: String, surface: String, tally: Dictionary) -> void:
	var elsewhere: Dictionary = tally["else"]
	_check(
		float(elsewhere["distance"]) < 1.0 and float(elsewhere["descent"]) < 0.1,
		"%s is run on its %s and the air between them, and nothing else" % [route_name, surface],
		"%.1f m and %.2f m of descent on something else"
			% [float(elsewhere["distance"]), float(elsewhere["descent"])]
	)


## `[bot-drive-1]`: prints "covered X of Y m in T s: V m/s against a max" and returns V.
func _print_pace(
	route_name: String, covered: float, length: float, ticks: int, max_speed: float,
	top: float
) -> float:
	var seconds := float(ticks) / float(Engine.physics_ticks_per_second)
	var pace := covered / maxf(seconds, 0.001)
	print("    %s: covered %.1f m of a %.1f m route in %.2f s: %.2f m/s against a %.1f m/s max, top %.2f" % [
		route_name, covered, length, seconds, pace, max_speed, top,
	])
	return pace


## The chaser goes through dot-npc's perception, not "the nearest player this tick".
##
## [b]Every check here fails on the version this replaced.[/b] The old chaser called
## `nearest_player()` on every one of the 128 ticks a second this game runs at, and both
## of the failures below are what that produces: two players a metre apart make it turn
## back and forth for ever, and one who steps out of range makes it forget mid-stride.
##
## Driven by hand rather than by letting the simulation run, because the thing being
## tested is the decision and not the walking — and a suite that moved real players
## around would be measuring the movement code.
func _test_a_chaser_commits(playground: Playground) -> void:
	var at := Vector3(0.0, 2.0, 0.0)
	var spawned := playground.props.spawn(&"npc_chaser", &"bot", at)

	if spawned == null:
		_check(false, "a chaser spawns for the commitment check")
		return

	var chaser := spawned.node as PlaygroundEntity

	_check(chaser.npc != null, "an entity has a dot-npc row")
	_check(
		chaser.npc.def.sight_range == 40.0,
		"whose perception comes from the catalogue rather than from the script",
		"%.0f m" % chaser.npc.def.sight_range
	)

	# Two candidates a fraction of a metre apart, swapping which is marginally nearer
	# every tick. This is the shape the old chaser flickered on.
	var near := DotNpcSenses.Candidate.new(&"one", Vector3(0, 2, -10), &"player")
	var also := DotNpcSenses.Candidate.new(&"two", Vector3(0, 2, -10.4), &"player")

	playground.npc_candidates = [near, also]

	var first := playground.npc_senses.update_target(
		chaser.npc, playground.npc_candidates, 0.0, 8
	)
	var switches := 0
	var last := first

	for tick in 40:
		near.position = Vector3(0, 2, -10.0 - (0.5 if tick % 2 == 0 else 0.0))
		also.position = Vector3(0, 2, -10.0 - (0.0 if tick % 2 == 0 else 0.5))

		var now := playground.npc_senses.update_target(
			chaser.npc, playground.npc_candidates, float(tick) * 0.1, 8
		)

		if now != last:
			switches += 1

		last = now

	_check(first != &"", "a chaser commits to somebody")
	_check(
		switches == 0,
		"and does not flicker between two players standing together",
		"%d switches in 40 ticks; the old chaser switched on most of them" % switches
	)

	# The target walks out of sight. The chaser must keep going for the grace period
	# rather than turning away mid-stride.
	playground.npc_candidates = []

	_check(
		playground.npc_senses.update_target(chaser.npc, [], 5.0, 8) != &"",
		"and keeps chasing one that stepped out of sight",
		"a doorway would otherwise be a perfect escape"
	)
	_check(
		playground.npc_senses.update_target(chaser.npc, [], 20.0, 8) == &"",
		"and gives up once the grace has expired"
	)

	# A target that disconnects. The grace would otherwise walk the NPC to an empty
	# corner for two and a half seconds, steering at a position nobody is at.
	playground.npc_candidates = [
		DotNpcSenses.Candidate.new(&"ghost", Vector3(0, 2, -6), &"player")
	]
	playground.npc_senses.update_target(chaser.npc, playground.npc_candidates, 21.0, 8)

	_check(chaser.npc.target_id == &"ghost", "a chaser can commit to anybody it sees")
	_check(
		chaser.target() == null and chaser.npc.target_id == &"",
		"and drops one that is not a player in this game any more",
		"or it walks to an empty corner for the whole grace period"
	)

	playground.props.remove(spawned.instance_id)
	playground.npc_candidates = []

	_test_a_hunter_decides(playground)


## The same NPC with a **decision** instead of an `if`: dot-npc-ai's state machine and
## the arena shooters' characteristics table.
##
## [b]`npc_chaser` is still in the catalogue and is still correct.[/b] What this one adds
## is a reaction time, a character per NPC, and a machine whose transitions are the design
## — and keeping both is the only honest way to say what the addon actually bought.
func _test_a_hunter_decides(playground: Playground) -> void:
	var spawned := playground.props.spawn(&"npc_hunter", &"bot", Vector3(0.0, 2.0, 0.0))

	if spawned == null:
		_check(false, "a hunter spawns")
		return

	var hunter := spawned.node as PlaygroundEntity

	_check(hunter.npc != null, "a hunter has a dot-npc row too")
	_check(
		hunter.get("machine") != null,
		"and a state machine rather than a hand-written if"
	)
	_check(
		hunter.get("character") != null,
		"and a character, which is what a difficulty setting is instead of"
	)

	var character: DotNpcAiCharacter = hunter.get("character")

	# [b]Seeded from the instance, and this is the check that matters.[/b] A preset is one
	# resource, and twenty NPCs sharing it share a seed — so every one of them reacts at
	# the same moment, which reads as a firing squad rather than as a fight.
	var second := playground.props.spawn(&"npc_hunter", &"bot", Vector3(4.0, 2.0, 0.0))

	if second != null:
		var other: DotNpcAiCharacter = (second.node as PlaygroundEntity).get("character")
		_check(
			other != null and other.seed_value != character.seed_value,
			"two hunters do not share a seed",
			"%d against %d" % [
				other.seed_value if other != null else -1, character.seed_value
			]
		)
		playground.props.remove(second.instance_id)

	# It starts patrolling, not chasing. A machine whose initial state was wrong would be
	# an NPC that sprinted at somebody it had not seen.
	var machine: DotNpcAiMachine = hunter.get("machine")
	_check(
		machine.current() == &"patrol",
		"a hunter starts on patrol (%s)" % String(machine.current())
	)

	# Somebody walks into view. [b]It must NOT go straight to chasing[/b] — the reaction
	# time is spent in ALERT, and an NPC that skipped it is one no player can surprise.
	#
	# [b]A REAL player, and that is not incidental.[/b] `PlaygroundEntity.target` resolves
	# a candidate id back through `game.players` and clears the target when it finds
	# nothing — deliberately, because a disconnected player has no position and steering at
	# their last one walks the NPC to an empty corner for the whole grace period. A test
	# with a candidate and no player is therefore a test of that clearing, not of this.
	var seen := playground.add_player(&"seen", "Seen")
	seen.teleport(Vector3(0.0, 2.0, -8.0))

	playground.npc_candidates = [
		DotNpcSenses.Candidate.new(&"seen", Vector3(0, 2, -8), &"player")
	]
	playground.npc_senses.update_target(
		hunter.npc, playground.npc_candidates, 0.0, 8
	)
	hunter.entity_tick(1.0 / 128.0)

	_check(
		machine.current() == &"alert",
		"and turns to look before it commits (%s)" % String(machine.current()),
		"reaction time is what makes it an opponent rather than a target"
	)

	# And then it does commit, once the reaction time has passed.
	for _step in range(int(128.0 * 1.5)):
		hunter.entity_tick(1.0 / 128.0)

	_check(
		machine.current() == &"chase",
		"and chases once its reaction time has passed (%s)" % String(machine.current())
	)

	# The target leaves. It searches where they were rather than stopping dead — an NPC
	# you escape by stepping behind a crate is one nobody has to run from.
	playground.npc_candidates = []
	hunter.npc.target_id = &""

	hunter.entity_tick(1.0 / 128.0)
	_check(
		machine.current() == &"lost",
		"and goes looking when it loses them (%s)" % String(machine.current())
	)

	playground.props.remove(spawned.instance_id)
	playground.npc_candidates = []
	playground.remove_player(&"seen")


# --- Limits per kind, the tool gun, armed NPCs -------------------------------------

## Clears the sandbox and puts the bot somewhere out of everybody's way.
func _sandbox_floor() -> void:
	var loaded: DotResult = await playground.change_map(&"pg_lobby")
	_check(loaded.ok, "the sandbox loads")
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var bot: PlaygroundPlayer = playground.players.get(&"bot")
	if bot != null:
		bot.teleport(Vector3(-60.0, 1.0, -60.0), 0.0)
	await get_tree().physics_frame


func _test_limits_per_kind() -> void:
	_section("limits per kind, and per role")
	await _sandbox_floor()

	# The count is under test, not the cost: an earlier section leaves a cost budget set,
	# and a turret costing three ran out of that rather than of anything checked here.
	var budget_was := playground.props.limits.per_player_budget
	playground.props.limits.per_player_budget = 0

	var limits := playground.spawn_limits
	limits.defaults[PlaygroundLimits.NPCS] = 3
	limits.apply_to(playground.props.limits)

	var placed := 0
	for i in 3:
		if playground.props.spawn(&"npc_wanderer", &"bot", Vector3(float(i) * 3.0, 1.2, 10.0)) != null:
			placed += 1
	_check(placed == 3, "three NPCs fit a limit of three")

	var reasons: Array = []
	var listen := func(_p: StringName, _id: StringName, why: String) -> void: reasons.append(why)
	playground.props.refused.connect(listen)
	_check(playground.props.spawn(&"npc_hunter", &"bot", Vector3(0, 1.2, 14)) == null,
		"and a fourth, of another kind of NPC, is refused")
	_check(not reasons.is_empty() and str(reasons[-1]).contains("npcs"),
		"saying it is the NPC limit", str(reasons))
	_check(playground.props.spawn(&"crate", &"bot", Vector3(0, 1.2, 18)) != null,
		"while a crate is a prop and still spawns")
	_check(playground.props.spawn(&"turret_spinner", &"bot", Vector3(6, 1.2, 18)) != null,
		"and so does a turret, which is an entity and not an NPC", str(reasons))

	# A role. The bot is a VIP, and VIPs get five.
	limits.roles_fn = func(id: StringName) -> PackedStringArray:
		return PackedStringArray(["vip"]) if id == &"bot" else PackedStringArray()
	_check(limits.set_roles_from("vip: npcs=5 props=400; admin: npcs=0").ok, "per-role limits parse")
	_check(playground.props.spawn(&"npc_wanderer", &"bot", Vector3(12, 1.2, 10)) != null,
		"and a role with more lets its holder past the default")
	_check(limits.limit_for(&"bot", PlaygroundLimits.NPCS) == 5
		and limits.limit_for(&"somebody", PlaygroundLimits.NPCS) == 3,
		"for them and nobody else")

	limits.roles_fn = func(_id: StringName) -> PackedStringArray: return PackedStringArray(["vip", "admin"])
	_check(limits.limit_for(&"bot", PlaygroundLimits.NPCS) == 0,
		"the most generous role wins, and none at all beats any number")

	var kept := limits.roles.duplicate(true)
	_check(not limits.set_roles_from("vip: npcz=4").ok and limits.roles == kept,
		"a typo is refused, and the roles that were there are kept")

	var lines := "\n".join(limits.describe_for(&"bot", playground.props.group_usage(&"bot")))
	_check(lines.contains("npcs") and lines.contains("balloons"),
		"pg_limits names every kind", lines)

	playground.props.refused.disconnect(listen)
	limits.roles_fn = Callable()
	limits.roles = {}
	limits.defaults = PlaygroundLimits.DEFAULTS.duplicate()
	limits.apply_to(playground.props.limits)
	playground.props.limits.per_player_budget = budget_was
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


## Points the tool gun at [param body] from three metres away and presses [param button].
##
## [b]After a physics step, not in the same frame as the last press.[/b] A resize rebuilds
## the body's collision shape, and the physics server's queries do not see a new shape
## until it has stepped: the first version of this pressed four buttons in one frame and
## every press after a resize traced straight through the crate. No player can click twice
## inside one physics step, so the wait is the real sequence, not a workaround.
func _tool_at(gun: Object, body: Node3D, button: StringName) -> DotResult:
	await get_tree().physics_frame
	var space := body.get_world_3d().direct_space_state
	var origin := body.global_position + Vector3(0.0, 0.2, 3.0)
	var aim := (body.global_position - origin).normalized()
	return gun.call(button, space, origin, aim)


func _test_the_tool_gun() -> void:
	_section("the tool gun")
	await _sandbox_floor()

	var def := playground.weapon_def(&"toolgun")
	_check(def != null, "the tool gun is a weapon on offer")
	var gun := PlaygroundWeapons.make(def)
	_check(gun != null and gun.has_method("set_mode"), "and it loads as one")

	if gun == null:
		_done()
		return

	gun.equip(playground, def)
	gun.wielder = &"bot"

	# --- Inflate and deflate ---------------------------------------------------------
	var crate := playground.props.spawn(&"crate", &"bot", Vector3(0, 0.6, 0))
	await get_tree().physics_frame
	var body := crate.node as RigidBody3D
	var base_mass := crate.def.mass

	_check(gun.call("set_mode", &"resize", {"step": 0.5}).ok, "it switches to inflate/deflate")
	_check((await _tool_at(gun, body, &"primary")).ok, "left click inflates")
	_check(is_equal_approx(float(body.get("size_scale")), 1.5), "by the step",
		"scale %.3f" % float(body.get("size_scale")))
	var box := (body.get_node("Collision") as CollisionShape3D).shape as BoxShape3D
	_check(box != null and box.size.x > 1.4, "and the collision is rebuilt bigger, not scaled",
		str(box.size) if box != null else "no box")
	_check(is_equal_approx(body.mass, base_mass * 1.5 * 1.5 * 1.5),
		"and it weighs what a crate that size would", "%.1f kg" % body.mass)
	var _down := await _tool_at(gun, body, &"secondary")
	_check(is_equal_approx(float(body.get("size_scale")), 1.0), "right click deflates it back exactly")
	var _down2 := await _tool_at(gun, body, &"secondary")
	var _back := await _tool_at(gun, body, &"reload")
	_check(is_equal_approx(float(body.get("size_scale")), 1.0) and is_equal_approx(body.mass, base_mass),
		"and reload puts it back to its own size")
	_check(gun.call("set_mode", &"resize", {"step": 99999.0}).ok
		and float(gun.call("current").call("setting", "step")) <= 1.0,
		"a setting from a client is clamped to the tool's own range")
	var _reset_step: Variant = gun.call("set_mode", &"resize", {"step": 0.5})
	for i in 10:
		var _up := await _tool_at(gun, body, &"primary")
	_check(float(body.get("size_scale")) <= PlaygroundProp.MAX_SCALE, "and nothing grows past the largest")
	var _reset := await _tool_at(gun, body, &"reload")

	# --- Paint -----------------------------------------------------------------------
	var _c: Variant = gun.call("set_mode", &"colour", {"colour": "6fbf5a"})
	var _p := await _tool_at(gun, body, &"primary")
	_check((body.get("tint") as Color).is_equal_approx(Color.html("6fbf5a")), "the colour tool paints")
	var other := playground.props.spawn(&"crate", &"bot", Vector3(4, 0.6, 0))
	await get_tree().physics_frame
	var _c2: Variant = gun.call("set_mode", &"colour", {"colour": "e05252"})
	var _copied := await _tool_at(gun, body, &"secondary")
	_check(str(gun.call("current").call("setting", "colour")) == "6fbf5a",
		"right click copies a prop's colour into the tool")
	var _unpaint := await _tool_at(gun, body, &"reload")
	_check((body.get("tint") as Color).a == 0.0, "and reload takes the paint off")

	# --- Weld ------------------------------------------------------------------------
	var other_body := other.node as RigidBody3D
	var _w: Variant = gun.call("set_mode", &"weld", {})
	var first: DotResult = await _tool_at(gun, body, &"primary")
	_check(first.ok and str(first.value) == "first", "a weld takes a first prop")
	var made: DotResult = await _tool_at(gun, other_body, &"primary")
	_check(made.ok and playground.constraints.size() == 1, "and a second, and they are welded")
	_check(made.ok and is_instance_valid(made.value.joint) and made.value.joint is Generic6DOFJoint3D,
		"by a real joint the physics enforces")
	_check(playground.constraint_count(&"bot") == 1, "counted against its owner")
	var _unweld := await _tool_at(gun, body, &"reload")
	_check(playground.constraints.size() == 0, "and reload takes the weld off")

	# --- The constraint limit ----------------------------------------------------------
	playground.spawn_limits.defaults[PlaygroundLimits.CONSTRAINTS] = 1
	var _w1 := await _tool_at(gun, body, &"secondary")
	var refused: DotResult = await _tool_at(gun, other_body, &"secondary")
	_check(not refused.ok and refused.error.message.contains("constraints"),
		"welds, ropes and no-collides have their own limit",
		refused.error.message if not refused.ok else "allowed")
	playground.spawn_limits.defaults[PlaygroundLimits.CONSTRAINTS] = 100
	playground.constraints.remove_owned(&"bot")

	# --- No-collide --------------------------------------------------------------------
	var _n: Variant = gun.call("set_mode", &"nocollide", {})
	var _n1 := await _tool_at(gun, body, &"primary")
	var _n2 := await _tool_at(gun, other_body, &"primary")
	_check(body.get_collision_exceptions().has(other_body) and other_body.get_collision_exceptions().has(body),
		"no-collide lets two props through each other, both ways")
	var _n3 := await _tool_at(gun, body, &"reload")
	_check(not body.get_collision_exceptions().has(other_body), "and reload puts their collision back")

	# --- Rope ----------------------------------------------------------------------------
	var anchor := playground.props.spawn(&"crate", &"bot", Vector3(10, 8, 0))
	var hanging := playground.props.spawn(&"crate", &"bot", Vector3(10, 6, 0))
	await get_tree().physics_frame
	var anchor_body := anchor.node as RigidBody3D
	var hanging_body := hanging.node as RigidBody3D
	anchor_body.freeze = true
	var _r: Variant = gun.call("set_mode", &"rope", {"slack": 1.0})
	var _r1 := await _tool_at(gun, anchor_body, &"primary")
	var roped: DotResult = await _tool_at(gun, hanging_body, &"primary")
	_check(roped.ok, "a rope ties two props")
	var length: float = roped.value.length if roped.ok else 0.0
	for i in 180:
		await get_tree().physics_frame
	var span: float = roped.value.a_point().distance_to(roped.value.b_point()) if roped.ok else INF
	_check(span <= length + 0.25, "and holds a falling crate at its length",
		"%.2f m on a %.2f m rope" % [span, length])
	_check(not (anchor_body.get("ropes") as Array).is_empty(),
		"and one of its props carries the rope for a client to draw")

	# --- Balloon ---------------------------------------------------------------------------
	var lifted := playground.props.spawn(&"crate", &"bot", Vector3(-10, 0.6, 0))
	await get_tree().physics_frame
	var lifted_body := lifted.node as RigidBody3D
	var start_y := lifted_body.global_position.y
	var _b: Variant = gun.call("set_mode", &"balloon", {"lift": 3000.0, "length": 2.0})
	var tied: DotResult = await _tool_at(gun, lifted_body, &"primary")
	_check(tied.ok, "a balloon is tied on")
	_check(playground.props.group_count(&"bot", &"balloons") == 1,
		"counted as a balloon, not as a prop")
	for i in 240:
		await get_tree().physics_frame
	_check(lifted_body.global_position.y > start_y + 1.0, "and lifts the crate",
		"%.2f m up" % (lifted_body.global_position.y - start_y))

	# --- Physical properties ------------------------------------------------------------------
	var _pp: Variant = gun.call("set_mode", &"physprop", {"gravity": false, "weight": 2.0})
	var _pp1 := await _tool_at(gun, other_body, &"primary")
	_check(other_body.gravity_scale == 0.0 and is_equal_approx(other_body.mass, other.def.mass * 2.0),
		"physical properties switch gravity off and change the weight")

	# --- Ownership -----------------------------------------------------------------------------
	var theirs := playground.props.spawn(&"crate", &"someone", Vector3(-4, 0.6, 6))
	await get_tree().physics_frame
	var was := playground.config.touch_others_props
	playground.config.touch_others_props = false
	var _rs: Variant = gun.call("set_mode", &"resize", {})
	var not_mine: DotResult = await _tool_at(gun, theirs.node as Node3D, &"primary")
	_check(not not_mine.ok and not_mine.error.message.contains("not yours"),
		"and on a server that says so, it cannot touch somebody else's")
	playground.config.touch_others_props = was

	# --- The remover ------------------------------------------------------------------------------
	var _rm: Variant = gun.call("set_mode", &"weld", {})
	var _w2 := await _tool_at(gun, body, &"primary")
	var _w3 := await _tool_at(gun, other_body, &"primary")
	var _rmv: Variant = gun.call("set_mode", &"remover", {})
	var gone: DotResult = await _tool_at(gun, body, &"secondary")
	_check(gone.ok and int(gone.value) == 2, "right click with the remover takes a whole contraption",
		str(gone.value) if gone.ok else gone.error.message)

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_check(playground.constraints.size() == 0, "and every constraint goes with its props")
	_done()


## The tool gun's edit mode: click a prop, and the settings ARE that prop.
func _test_editing_a_selected_prop() -> void:
	_section("editing a selected prop with the tool gun")
	await _sandbox_floor()

	var def := playground.weapon_def(&"toolgun")
	var gun := PlaygroundWeapons.make(def) if def != null else null
	if gun == null:
		_check(false, "a tool gun to edit with")
		_done()
		return
	gun.equip(playground, def)
	gun.wielder = &"bot"
	_check(gun.call("set_mode", &"edit", {}).ok, "the tool gun has an edit mode")
	var mode: Object = gun.call("current")

	# A crate that is already not as catalogued, so reading it back says something.
	var crate := playground.props.spawn(&"crate", &"bot", Vector3(0, 0.6, 0))
	var other := playground.props.spawn(&"crate", &"bot", Vector3(5, 0.6, 0))
	await get_tree().physics_frame
	var body := crate.node as RigidBody3D
	var other_body := other.node as RigidBody3D
	body.call("set_size_scale", 1.5)
	body.call("set_tint", Color.html("e05252"))
	await get_tree().physics_frame

	# --- Selecting reads the prop -----------------------------------------------------
	var picked: DotResult = await _tool_at(gun, body, &"primary")
	var report: Dictionary = picked.value if picked.ok and picked.value is Dictionary else {}
	_check(report.get("node") == body, "left click selects the prop under the crosshair")
	var read: Dictionary = report.get("settings", {})
	_check(is_equal_approx(float(read.get("size", 0.0)), 1.5) and str(read.get("colour", "")) == "e05252",
		"and answers with what it IS: its size and its paint", str(read))
	_check(bool(read.get("gravity", false)) and not bool(read.get("frozen", true))
		and is_equal_approx(float(read.get("weight", 0.0)), 1.0),
		"its gravity, its freeze and its weight", str(read))
	_check(str(report.get("name", "")) != "", "and its name, for the HUD")

	# --- A change lands on it as it arrives ------------------------------------------
	var changed := read.duplicate()
	changed["size"] = 2.0
	changed["colour"] = "6fbf5a"
	changed["gravity"] = false
	changed["weight"] = 3.0
	changed["friction"] = 0.2
	changed["bounce"] = 0.5
	_check(gun.call("set_mode", &"edit", changed).ok, "a settings change is taken")
	await get_tree().physics_frame
	_check(is_equal_approx(float(body.get("size_scale")), 2.0), "and resizes the selected prop",
		"%.2f" % float(body.get("size_scale")))
	_check((body.get("tint") as Color).is_equal_approx(Color.html("6fbf5a")), "repaints it")
	_check(body.gravity_scale == 0.0 and is_equal_approx(body.mass, crate.def.mass * 8.0 * 3.0),
		"switches its gravity off and makes it heavier, with the size", "%.1f kg" % body.mass)
	_check(body.physics_material_override != null and is_equal_approx(body.physics_material_override.friction, 0.2)
		and is_equal_approx(body.physics_material_override.bounce, 0.5), "and changes its friction and bounce")
	_check(is_equal_approx(float(other_body.get("size_scale")), 1.0) and (other_body.get("tint") as Color).a == 0.0,
		"and nothing else")

	# --- The second prop's settings are its own, not the first's ------------------------
	var second: DotResult = await _tool_at(gun, other_body, &"primary")
	var second_read: Dictionary = (second.value as Dictionary).get("settings", {}) if second.ok else {}
	_check(is_equal_approx(float(second_read.get("size", 0.0)), 1.0) and bool(second_read.get("gravity", false)),
		"selecting a second prop reads ITS properties, not the last one's", str(second_read))
	var only_colour := second_read.duplicate()
	only_colour["colour"] = "5276e0"
	var _c: Variant = gun.call("set_mode", &"edit", only_colour)
	_check(is_equal_approx(float(other_body.get("size_scale")), 1.0) and other_body.gravity_scale == 1.0
		and (other_body.get("tint") as Color).is_equal_approx(Color.html("5276e0")),
		"so a menu sending every setting back changes only the one that moved")
	_check(is_equal_approx(float(body.get("size_scale")), 2.0), "and the first prop is left alone")

	# --- Its own colour takes the paint off -----------------------------------------------
	var own := only_colour.duplicate()
	own["colour"] = PlaygroundProp.colour_of(other.def).to_html(false)
	var _o: Variant = gun.call("set_mode", &"edit", own)
	_check((other_body.get("tint") as Color).a == 0.0, "choosing the catalogue's own colour takes the paint off")

	# --- Freezing asks the freeze limit, unfreezing does not ------------------------------
	var freeze := own.duplicate()
	freeze["frozen"] = true
	var _f: Variant = gun.call("set_mode", &"edit", freeze)
	_check(other.frozen and other_body.freeze, "it freezes the prop")
	var reselect: DotResult = await _tool_at(gun, body, &"primary")
	var was_frozen_cap := playground.props.limits.per_player_frozen
	playground.props.limits.per_player_frozen = 1
	var freeze_first := ((reselect.value as Dictionary).get("settings", {}) as Dictionary).duplicate()
	freeze_first["frozen"] = true
	var _ff: Variant = gun.call("set_mode", &"edit", freeze_first)
	var after_refusal: Dictionary = mode.call("selection_report")
	_check(not crate.frozen and not bool((after_refusal.get("settings", {}) as Dictionary).get("frozen", true)),
		"a freeze past the limit is refused and the setting springs back", str(after_refusal.get("settings")))
	_check(str(after_refusal.get("refused", "")).contains("frozen"), "and the report says why",
		str(after_refusal.get("refused")))
	playground.props.limits.per_player_frozen = was_frozen_cap

	# --- Reload puts it back --------------------------------------------------------------
	var _back: DotResult = await _tool_at(gun, body, &"reload")
	_check(is_equal_approx(float(body.get("size_scale")), 1.0) and (body.get("tint") as Color).a == 0.0
		and body.gravity_scale == 1.0 and is_equal_approx(body.mass, crate.def.mass),
		"reload puts size, paint, gravity and weight back to the catalogue's", "%.1f kg" % body.mass)
	var re_other: DotResult = await _tool_at(gun, other_body, &"reload")
	_check(re_other.ok and other.frozen, "and leaves a frozen prop frozen")

	# --- Letting go -----------------------------------------------------------------------
	var gone: DotResult = await _tool_at(gun, body, &"secondary")
	_check(gone.ok and (gone.value as Dictionary).get("node") == null, "right click lets go of it")
	var after := (mode.get("settings") as Dictionary).duplicate()
	after["size"] = 3.0
	var _a: Variant = gun.call("set_mode", &"edit", after)
	_check(is_equal_approx(float(body.get("size_scale")), 1.0), "and a change with nothing selected changes nothing")

	var _p: DotResult = await _tool_at(gun, body, &"primary")
	var _sw: Variant = gun.call("set_mode", &"resize", {})
	var stale := after.duplicate()
	var _e: Variant = gun.call("set_mode", &"edit", stale)
	_check(is_equal_approx(float(body.get("size_scale")), 1.0),
		"switching to another tool lets go too, so switching back never lands old settings on it")

	# --- Ownership is asked again on every change -------------------------------------------
	var theirs := playground.props.spawn(&"crate", &"someone", Vector3(-5, 0.6, 0))
	await get_tree().physics_frame
	var was_touch := playground.config.touch_others_props
	playground.config.touch_others_props = true
	var theirs_pick: DotResult = await _tool_at(gun, theirs.node as Node3D, &"primary")
	_check(theirs_pick.ok, "on a server that allows it, somebody else's prop can be selected")
	playground.config.touch_others_props = false
	var grow := ((theirs_pick.value as Dictionary).get("settings", {}) as Dictionary).duplicate() if theirs_pick.ok else {}
	grow["size"] = 2.5
	var _g: Variant = gun.call("set_mode", &"edit", grow)
	var refused: Dictionary = mode.call("selection_report")
	_check(is_equal_approx(float((theirs.node as Node3D).get("size_scale")), 1.0) and refused.get("node") == null,
		"and once the server stops allowing it, the next change is refused and the selection dropped",
		str(refused.get("refused")))
	playground.config.touch_others_props = was_touch

	# --- A selected prop that is removed ------------------------------------------------------
	var doomed := playground.props.spawn(&"crate", &"bot", Vector3(0, 0.6, 6))
	await get_tree().physics_frame
	var _d: DotResult = await _tool_at(gun, doomed.node as Node3D, &"primary")
	var _rm := playground.props.remove(doomed.instance_id)
	await get_tree().physics_frame
	var _x: Variant = gun.call("set_mode", &"edit", grow)
	_check((mode.call("selection_report") as Dictionary).get("node") == null,
		"a selected prop that is removed is simply no longer selected")

	# --- The wire ---------------------------------------------------------------------------------
	var bytes := PlaygroundEvents.write_selection(42, "Wooden crate", {"size": 2.0, "frozen": true}, "")
	var back := PlaygroundEvents.read_selection(DotNetReader.new(bytes))
	_check(bool(back["ok"]) and int(back["net_id"]) == 42 and str(back["name"]) == "Wooden crate"
		and is_equal_approx(float((back["settings"] as Dictionary)["size"]), 2.0) and bool((back["settings"] as Dictionary)["frozen"]),
		"a selection survives the wire", str(back))

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


func _test_armed_npcs() -> void:
	_section("NPCs with weapons")
	await _sandbox_floor()

	var soldier := playground.props.spawn(&"npc_soldier", &"bot", Vector3(0, 1.2, 0))
	await get_tree().physics_frame
	_check(soldier != null, "a soldier spawns")

	if soldier == null:
		_done()
		return

	var body := soldier.node
	_check(String(body.get("weapon_id")) == "zee_smg" and body.call("is_armed"),
		"carrying the weapon its catalogue entry names")
	_check(playground.armed_npcs.has(body), "and the world knows it is armed")
	_check(body.get("brain") != null and body.get("brain").get("squad") != null,
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

	# --- A player's shot hurts it -------------------------------------------------------------
	var bot: PlaygroundPlayer = playground.players[&"bot"]
	bot.teleport(Vector3(0, 1.0, 12.0), 0.0)
	await get_tree().physics_frame
	var rig := PlaygroundZee.arm(bot, playground.weapon_def(&"zee_rifle"), ZeeWeaponRig.Role.SERVER, true,
		playground.tick_rate, playground.current_tick())
	var target: Node3D = body
	var before := float(body.get("health"))
	var ctx := DotWeaponContext.new()
	ctx.origin = bot.eye_position()
	ctx.direction = (target.global_position + Vector3.UP * 0.3 - ctx.origin).normalized()
	ctx.authority = true
	for i in 40:
		ctx.tick = playground.current_tick() + i
		var command := DotWeaponCommand.new()
		command.set_button(DotWeaponCommand.BUTTON_ATTACK, i % 2 == 0)
		command.slot = PlaygroundZee.slot_of(rig)
		var outcome := rig.simulate_tick(command, ctx.tick, ctx)
		playground.player_shots_fired(&"bot", outcome)
		if float(body.get("health")) < before:
			break
	_check(float(body.get("health")) < before, "a player's shot hurts an NPC",
		"%.0f of %.0f" % [float(body.get("health")), before])
	PlaygroundZee.disarm(bot)

	# --- Replicated --------------------------------------------------------------------------
	var net := PlaygroundNpcNet.new()
	net.prop = body
	net.pull()
	_check(net.net_weapon == "zee_smg", "a client is told which weapon it holds")
	net.free()

	# --- Soldiers and rebels fight each other -------------------------------------------------
	bot.teleport(Vector3(-60.0, 1.0, -60.0), 0.0)
	# Healed first: the player's shots above already hurt it, and a fight measured against
	# that would end before it began.
	body.set("health", float(body.get("max_health")))
	before = float(body.get("max_health"))
	var rebel := playground.props.spawn(&"npc_rebel", &"bot", Vector3(0, 1.2, -14))
	await get_tree().physics_frame
	var rebel_body: Node = rebel.node if rebel != null else null
	var fired_before := int((body.get("zee_rig") as ZeeWeaponRig).fire_seq)
	var hurt := false
	for i in 128 * 8:
		await get_tree().physics_frame
		if not is_instance_valid(body) or not is_instance_valid(rebel_body):
			hurt = true
			break
		if float(body.get("health")) < before - 0.1 or float(rebel_body.get("health")) < float(rebel_body.get("max_health")):
			hurt = true
			break
	_check(hurt, "a soldier and a rebel find each other and fight",
		"soldier targets '%s', rebel targets '%s'" % [
			String(body.get("npc").target_id) if is_instance_valid(body) else "(gone)",
			String(rebel_body.get("npc").target_id) if is_instance_valid(rebel_body) else "(gone)",
		])
	_check(not is_instance_valid(body) or int((body.get("zee_rig") as ZeeWeaponRig).fire_seq) > fired_before
		or (rebel_body != null and is_instance_valid(rebel_body) and int((rebel_body.get("zee_rig") as ZeeWeaponRig).fire_seq) > 0),
		"with their own weapons")

	# --- Death drops the weapon, and walking over it picks it up ---------------------------------
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
	bot.teleport(at, 0.0)
	for i in 160:
		await get_tree().physics_frame
		if not picked.is_empty():
			break
	_check(not picked.is_empty() and picked[0][0] == &"bot" and picked[0][1] == &"zee_smg",
		"and the player who walks over it picks it up", str(picked))
	playground.weapon_picked_up.disconnect(on_pick)

	# --- A weapon spawned from the menu counts against `weapons` ----------------------------------
	var placed := playground.props.spawn(Playground.pickup_id_of(&"zee_pistol"), &"bot", Vector3(8, 1, 8))
	_check(placed != null and playground.props.group_count(&"bot", &"weapons") == 1,
		"a weapon put on the ground counts against the weapons limit")

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


## A tool gun press at the ground under (x, z), from above: the waypoint and spawner tools
## work on a point in the world, not on a prop.
func _tool_at_ground(gun: Object, x: float, z: float, button: StringName) -> DotResult:
	await get_tree().physics_frame
	var space := playground.world.get_world_3d().direct_space_state
	return gun.call(button, space, Vector3(x, 4.0, z), Vector3.DOWN)


func _write_fake_addon(root: String, name: String, hook_source: String) -> void:
	DirAccess.make_dir_recursive_absolute("%s/%s" % [root, name])
	if hook_source != "":
		var file := FileAccess.open("%s/%s/playground_hook.gd" % [root, name], FileAccess.WRITE)
		file.store_string(hook_source)
		file.close()
	else:
		var file := FileAccess.open("%s/%s/other.gd" % [root, name], FileAccess.WRITE)
		file.store_string("extends Node\nfunc _init() -> void:\n\tprint('SHOULD NOT RUN')\n")
		file.close()


## The addons folder hook, then the waypoint and NPC spawner tools. See [PlaygroundAddons].
func _test_addon_hook_and_npc_tools() -> void:
	_section("the addons hook, waypoints and the NPC spawner")
	await _sandbox_floor()

	# --- The hook, against a scratch folder shaped like res://addons ------------------------------
	var root := "user://pg_addon_scratch"
	var hooked := """extends Node
var got: Array = []
func playground_register(menu) -> void:
	menu.add_item("hello", "Say hello", func(ctx): ctx.send({"hi": 1}), "Greetings", "hint")
	menu.add_item("hello", "again", func(_ctx): pass)
func playground_receive(msg: Dictionary) -> void:
	got.append(msg)
"""
	_write_fake_addon(root, "fake_with_hook", hooked)
	_write_fake_addon(root, "fake_plain", "")
	_write_fake_addon(root, "fake_broken", "extends Node\nfunc nothing() -> void:\n\tpass\n")
	var broken_file := FileAccess.open("%s/fake_broken/playground_hook.gd" % root, FileAccess.WRITE)
	broken_file.store_string("extends Node\nfunc nothing() -> void:\n\tpass\n")
	broken_file.close()

	var addons := PlaygroundAddons.new()
	var host := Node3D.new()
	add_child(host)
	var count := addons.scan(host, true, root)
	_check(count == 1 and addons.hook_count() == 1, "one folder with a hook is loaded", str(count))
	_check(addons.skipped().has("fake_plain") and not addons.skipped().has("fake_with_hook"),
		"a folder without one is passed over, and its scripts never run")
	_check(addons.items().size() == 1 and addons.items()[0].key() == "fake_with_hook/hello",
		"the hook's item is registered, and a duplicate id is refused")
	_check(addons.describe_items()[0]["category"] == "Greetings", "with its category for the menu")

	var told: Array = []
	addons.message.connect(func(addon: String, body: Dictionary) -> void: told.append([addon, body]))
	var ctx := PlaygroundAddons.Context.new()
	_check(addons.activate("fake_with_hook/hello", ctx).ok, "choosing the entry runs its callback")
	_check(told.size() == 1 and told[0][0] == "fake_with_hook" and int(told[0][1]["hi"]) == 1,
		"what the callback sends reaches the clients' bridge")
	_check(addons.deliver("fake_with_hook", {"x": 2}) and host.get_child(0).get("got").size() == 1,
		"and on a client the hook's own receive is handed it")
	_check(not addons.activate("nope/nothing", ctx).ok, "an unknown entry is refused")
	_check(not addons.deliver("fake_plain", {}), "and a message for an addon with no hook goes nowhere")

	var wire := PlaygroundEvents.write_addon("fake_with_hook", {"x": 2})
	var back := PlaygroundEvents.read_addon(DotNetReader.new(wire))
	_check(bool(back["ok"]) and back["addon"] == "fake_with_hook" and int(back["body"]["x"]) == 2,
		"an addon message survives the wire")
	_check(preload("../game/net/playground_event.gd").fits(), "and every event kind still fits its field")
	host.queue_free()

	# --- The real folder: dot_core has no hook, natural-disasters has an adapter -------------------
	_check(playground.addons != null and playground.addons.skipped().has("dot_core"),
		"the game scanned the real addons folder, and the libraries in it were left alone")
	var tornado: Object = playground.addons.find("pg_natural_disasters/tornado")

	if tornado == null:
		print("  skip  natural-disasters is not linked in addons/")
	else:
		_check(playground.addons.find("pg_natural_disasters/earthquake") != null
			and playground.addons.find("pg_natural_disasters/thunderstorm") != null,
			"the disasters are menu entries")
		var told_everyone: Array = []
		playground.addon_message.connect(func(a: String, b: Dictionary) -> void: told_everyone.append(a))
		var started := playground.activate_addon_item("pg_natural_disasters/tornado", 0, Vector3(30, 0, 30))
		_check(started.ok, "choosing Tornado starts one", started.error.message if not started.ok else "")
		var hook: Node = playground.find_child("Addon_pg_natural_disasters", true, false)
		_check(hook != null and bool(hook.manager.call("is_active", &"tornado")), "and it is running")
		_check(not told_everyone.is_empty(), "and every client is told")
		hook.manager.call("stop")

	# --- The waypoint tool ------------------------------------------------------------------------
	var def := playground.weapon_def(&"toolgun")
	var gun := PlaygroundWeapons.make(def)
	gun.equip(playground, def)
	gun.wielder = &"bot"
	var points_before: int = playground.waypoints.size()
	_check(gun.call("set_mode", &"waypoint", {"chain": true}).ok, "the tool gun takes the waypoint tool")
	var first: DotResult = await _tool_at_ground(gun, 20.0, 20.0, &"primary")
	var second: DotResult = await _tool_at_ground(gun, 28.0, 20.0, &"primary")
	_check(first.ok and second.ok and playground.waypoints.size() == points_before + 2,
		"two points are laid", str(playground.waypoints.size()))

	if first.ok and second.ok:
		var a: Node = first.value
		var b: Node = second.value
		_check(a.links.has(b) and b.links.has(a), "and linked, both ways, because the second chained to the last")
		_check(not (a.get("ropes") as Array).is_empty(), "with a rope between them for every client to draw")
		var third: DotResult = await _tool_at_ground(gun, 28.0, 28.0, &"primary")
		_check(third.ok and third.value.links.has(b), "a third chains on from the second")
		playground.props.remove((a.get("instance") as DotPropInstance).instance_id)
		await get_tree().physics_frame
		await get_tree().physics_frame
		_check(not b.links.has(a), "removing a point unlinks its neighbours")

	var cleared: DotResult = await _tool_at_ground(gun, 0.0, 0.0, &"reload")
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(cleared.ok and playground.waypoints.size() == points_before, "reload removes my points")

	# --- A route is walked --------------------------------------------------------------------------
	var route: Array = []
	var last: Node = null
	for x in [-10.0, 10.0]:
		var laid: DotResult = await _tool_at_ground(gun, x, -20.0, &"primary")
		if laid.ok:
			route.append(laid.value)
	_check(route.size() == 2 and route[0].links.has(route[1]), "a patrol route of two points")
	var walker := playground.props.spawn(&"npc_wanderer", &"bot", Vector3(-10, 1.0, -20))
	await get_tree().physics_frame
	var start: Vector3 = (walker.node as Node3D).global_position if walker != null else Vector3.ZERO
	var far := 0.0
	for i in 128 * 12:
		await get_tree().physics_frame
		if walker == null or not is_instance_valid(walker.node):
			break
		far = maxf(far, (walker.node as Node3D).global_position.distance_to(start))
		if far > 8.0:
			break
	_check(far > 8.0, "an NPC with a route walks it", "%.1f m from the start" % far)
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	await get_tree().physics_frame

	# --- The NPC spawner tool -----------------------------------------------------------------------
	_check(gun.call("set_mode", &"npc_spawn", {"kind": "npc_soldier", "weapon": "zee_shotgun", "count": 2.0}).ok,
		"the tool gun takes the NPC spawner")
	var squad: DotResult = await _tool_at_ground(gun, 40.0, 0.0, &"primary")
	_check(squad.ok and int(squad.value) == 2, "a click spawns two NPCs")
	var armed := 0
	for entity in playground.armed_npcs:
		if is_instance_valid(entity) and String(entity.get("weapon_id")) == "zee_shotgun":
			armed += 1
	_check(armed == 2, "each carrying the weapon the tool was set to", str(armed))

	# Tool-spawned NPCs shoot: an enemy of theirs a few metres off, and they fire.
	_check(gun.call("set_mode", &"npc_spawn", {"kind": "npc_rebel", "weapon": "default", "count": 1.0}).ok, "and a rebel")
	var _rebel: DotResult = await _tool_at_ground(gun, 40.0, -14.0, &"primary")
	var fired := false
	for i in 128 * 8:
		await get_tree().physics_frame
		for entity in playground.armed_npcs:
			var rig: Variant = entity.get("zee_rig") if is_instance_valid(entity) else null
			if rig != null and int((rig as ZeeWeaponRig).fire_seq) > 0:
				fired = true
		if fired:
			break
	_check(fired, "NPCs the tool spawned use their weapons")

	# --- A spawn point ------------------------------------------------------------------------------
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	await get_tree().physics_frame
	var _sp: Variant = gun.call("set_mode", &"npc_spawn", {
		"kind": "npc_wanderer", "weapon": "none", "point": true, "interval": 1.0, "limit": 2.0,
	})
	var point_res: DotResult = await _tool_at_ground(gun, -40.0, 30.0, &"primary")
	_check(point_res.ok and point_res.value.has_meta(&"spawn_point"), "a spawn point is laid")
	var made := 0
	for i in 128 * 10:
		await get_tree().physics_frame
		made = 0
		for prop in playground.props.all_props():
			if prop.def != null and String(prop.def.id) == "npc_wanderer":
				made += 1
		if made >= 2:
			break
	_check(made == 2, "and it keeps making NPCs, up to its limit", str(made))
	for i in 128 * 3:
		await get_tree().physics_frame
	made = 0
	for prop in playground.props.all_props():
		if prop.def != null and String(prop.def.id) == "npc_wanderer":
			made += 1
	_check(made == 2, "and stops there")

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	DirAccess.remove_absolute("%s/fake_with_hook/playground_hook.gd" % root)
	_done()


## A zee grenade is thrown, flies, bounces, goes off, and NPCs get out from under it.
##
## [b]This game used to drop a weapon outcome's spawns[/b], so a thrown frag cost a grenade
## and never existed. Every check here goes through the real path: a rig, its outcome, and
## `player_shots_fired`, which is what the server's bridge and the offline client both call.
func _test_grenades() -> void:
	_section("grenades and rockets fly")
	await _sandbox_floor()
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	playground.projectiles.clear()

	var bot: PlaygroundPlayer = playground.players[&"bot"]
	bot.teleport(Vector3(0, 1.0, 12.0), 0.0)
	await get_tree().physics_frame

	# A crate and a soldier where it will land, a little apart.
	var crate := playground.props.spawn(&"crate", &"bot", Vector3(1.5, 0.6, 2.0))
	var soldier := playground.props.spawn(&"npc_soldier", &"bot", Vector3(-1.5, 1.2, 2.0))
	await get_tree().physics_frame
	await get_tree().physics_frame

	var rig := PlaygroundZee.arm(bot, playground.weapon_def(&"zee_frag"), ZeeWeaponRig.Role.SERVER, true,
		playground.tick_rate, playground.current_tick())
	_check(rig != null, "a player holds a frag")

	var ctx := DotWeaponContext.new()
	ctx.origin = bot.eye_position()
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

	var launched_at := bot.eye_position()
	var danger_heard := false
	var lowest := INF
	var soldier_body: Node3D = soldier.node if soldier != null else null
	var soldier_start := soldier_body.global_position if soldier_body != null else Vector3.ZERO
	var soldier_health := float(soldier_body.get("health")) if soldier_body != null else 0.0
	var crate_body: RigidBody3D = crate.node as RigidBody3D if crate != null else null
	var crate_start := crate_body.global_position if crate_body != null else Vector3.ZERO
	var blasts: Array = []
	var on_blast := func(serial: int, at: Vector3, radius: float) -> void: blasts.append([serial, at, radius])
	playground.projectiles.detonated.connect(on_blast)
	var ticks := 0
	var bounced := false

	for i in 128 * 5:
		await get_tree().physics_frame
		ticks += 1
		var live := playground.projectiles.flying()
		if not live.is_empty():
			lowest = minf(lowest, live[0].position.y)
			bounced = bounced or live[0].bounces > 0
			for sound in playground.npc_sounds.audible(live[0].position, playground.npc_world.now(), 1.0):
				if sound.kind == DotNpcAiSounds.Kind.DANGER:
					danger_heard = true
		if not blasts.is_empty():
			break

	playground.projectiles.detonated.disconnect(on_blast)
	_check(danger_heard, "while it is live it is a DANGER on the armed NPCs' board")
	_check(bounced, "it bounces off the floor rather than going off on it")
	_check(lowest > -0.5, "and never falls through the floor", "lowest %.2f" % lowest)
	_check(blasts.size() == 1, "it goes off once, on its fuse",
		"%d blasts in %d ticks" % [blasts.size(), ticks])
	_check(ticks > 128 * 2, "not before the fuse", "%d ticks" % ticks)

	if blasts.is_empty():
		PlaygroundZee.disarm(bot)
		_done()
		return

	var at: Vector3 = blasts[0][1]
	print("    frag thrown from %s went off at %s after %d ticks" % [launched_at, at, ticks])
	_check(at.z < launched_at.z - 3.0, "somewhere in front of the thrower", str(at))
	await get_tree().physics_frame
	await get_tree().physics_frame

	if crate_body != null and is_instance_valid(crate_body) and crate_body.global_position.distance_to(at) < 5.2:
		_check(crate_body.global_position.distance_to(crate_start) > 0.2 or crate_body.linear_velocity.length() > 0.5,
			"a crate inside the blast is thrown",
			"moved %.2f m" % crate_body.global_position.distance_to(crate_start))
	else:
		_check(false, "a crate inside the blast is thrown", "the crate was not in it")

	var soldier_gap := soldier_body.global_position.distance_to(at) \
		if soldier_body != null and is_instance_valid(soldier_body) else INF
	_check(soldier_body == null or not is_instance_valid(soldier_body)
		or float(soldier_body.get("health")) < soldier_health or soldier_gap > 5.2,
		"the soldier beside it was hurt or was out of the blast when it went off",
		"%.1f m from it" % soldier_gap)
	print("    the soldier was %.1f m from the blast (splash 5.2), at %.0f of %.0f" % [
		soldier_gap, float(soldier_body.get("health")) if is_instance_valid(soldier_body) else 0.0, soldier_health])

	# A grenade cooked past its fuse goes off where it is, so nobody beside it has time to run.
	var stood := playground.props.spawn(&"npc_soldier", &"bot", Vector3(-8, 1.2, -8))
	await get_tree().physics_frame
	if stood != null:
		var stood_health := float(stood.node.get("health"))
		var cooked := DotWeaponSpawn.new()
		cooked.id = &"frag"
		cooked.origin = (stood.node as Node3D).global_position + Vector3(1.0, 0.0, 0.0)
		cooked.splash_radius = 5.2
		cooked.splash_damage = 115.0
		cooked.life_ticks = 4
		var _c := playground.projectiles.launch(cooked, &"bot")
		for i in 3:
			await get_tree().physics_frame
		_check(not is_instance_valid(stood.node) or float(stood.node.get("health")) < stood_health,
			"a soldier a metre from a blast is hurt by it",
			"%.0f of %.0f" % [float(stood.node.get("health")) if is_instance_valid(stood.node) else 0.0, stood_health])
	else:
		_check(false, "a soldier a metre from a blast is hurt by it", "no soldier spawned")
	_check(playground.projectiles.flashes_live() >= 1, "a flash is drawn where it went off")
	PlaygroundZee.disarm(bot)

	# --- An NPC gets out from under one ----------------------------------------------------------
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

	# --- A rocket goes off on contact -------------------------------------------------------------
	var rocket := DotWeaponSpawn.new()
	rocket.id = &"launcher"
	rocket.origin = Vector3(0, 1.5, 0)
	rocket.velocity = Vector3(0, -30, 0)
	rocket.splash_radius = 3.0
	rocket.splash_damage = 0.0
	rocket.life_ticks = 128 * 4
	var rocket_blasts: Array = []
	var on_rocket := func(_serial: int, where: Vector3, _radius: float) -> void: rocket_blasts.append(where)
	playground.projectiles.detonated.connect(on_rocket)
	var _r := playground.projectiles.launch(rocket, &"bot")
	for i in 32:
		await get_tree().physics_frame
		if not rocket_blasts.is_empty():
			break
	playground.projectiles.detonated.disconnect(on_rocket)
	_check(rocket_blasts.size() == 1 and absf((rocket_blasts[0] as Vector3).y) < 0.3,
		"a rocket with no fuse goes off where it meets the floor", str(rocket_blasts))

	# --- What a client is told, and its copy decides nothing --------------------------------------
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

	_done()


## An entity is a prop with a script, and the script is loaded by path.
##
## [b]This is the whole "spawning things that carry code" mechanism.[/b] The scene is a
## bare `RigidBody3D`; the script comes from `meta`, is loaded by PATH rather than by
## class, and is attached by `Playground._configure_entity`. The path matters: a
## mounted dot-cloud pack's `class_name` globals are not registered in the host, so an
## entity named by class could only ever ship inside the build.
func _test_entities_run_their_scripts() -> void:
	_section("entities that run their own scripts")

	# On the sandbox, deliberately. The previous tests leave the game on whichever map
	# they finished with, and an NPC walking about on the bhop map's blocks-with-gaps
	# falls off one — so "does the chaser close the distance" would be measuring the
	# terrain rather than the script. Flat ground is the only surface on which the
	# answer is about the entity.
	var loaded: DotResult = await playground.change_map(&"pg_lobby")
	_check(loaded.ok, "the sandbox loads")

	playground.spawn_player(&"bot")

	# Driven with an EMPTY command for a moment, which is not busywork.
	# `DotFpsController.apply_command` sets the pending command and it stays set: the
	# bot arrives here still holding forward and jump from the bhop test several
	# tests ago, so it auto-hops across the sandbox for the whole of this one — and
	# "does the chaser close the distance" then measures a player who is running
	# away. It also gives them the third of a second it takes to fall the metre from
	# the spawn onto the floor.
	await _drive(&"bot", DotFpsCommand.new(), 60)

	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	var at := Vector3(0.0, 1.2, 0.0)
	var npc := playground.props.spawn(&"npc_wanderer", &"bot", at)

	_check(npc != null, "an entity spawns")

	if npc == null:
		return

	var body := npc.node as PlaygroundEntity

	_check(body != null, "and its body is a PlaygroundEntity, not a plain prop")
	_check(
		body != null and body.get_script() != null
		and body.get_script().resource_path
			== PlaygroundSpawnables.script_of(npc.def),
		"running exactly the script its definition names",
		body.get_script().resource_path if body != null else "none"
	)
	_check(
		playground.entities.has(body),
		"and it is on the list the simulation ticks"
	)

	# `_ready` has already run by the time the script is attached — the spawner adds
	# the body to the world before it emits — so `bind` is what an entity gets
	# instead, and an entity whose world never arrived would sit there being a crate.
	_check(body != null and body.game == playground, "it knows its world")
	_check(body != null and body.instance == npc, "and its own row in the spawner")

	# It moves. Everything above is satisfied by an entity that does nothing at all.
	var before := body.global_position
	var ticks := 0
	var moved := 0.0

	while ticks < 240:
		await get_tree().physics_frame
		ticks += 1
		moved = maxf(moved, before.distance_to(body.global_position))

	_check(moved > 1.0, "and it walks about", "%.2f m" % moved)
	_check(body.age > 0.0, "counting simulated time, not wall time",
		"%.2f s" % body.age)

	# A held entity is furniture. Without that, the NPC fights the physics gun's
	# spring — the gun writes a velocity toward the goal and the NPC writes one
	# toward wherever it was walking — and the prop shudders between them.
	npc.held_by = &"bot"

	var held_at := body.global_position
	body.linear_velocity = Vector3.ZERO

	for _i in range(30):
		await get_tree().physics_frame

	_check(
		held_at.distance_to(body.global_position) < 0.6,
		"a held entity stops driving itself",
		"%.2f m" % held_at.distance_to(body.global_position)
	)

	npc.held_by = &""

	# A chaser goes toward somebody. The bot is at the origin-ish; put the chaser
	# out and check the distance closes, which is the one thing that distinguishes
	# this script from the wanderer.
	var player: PlaygroundPlayer = playground.players[&"bot"]
	var chaser := playground.props.spawn(
		&"npc_chaser", &"bot", player.global_position + Vector3(14.0, 1.2, 0.0)
	)

	_check(chaser != null, "a chaser spawns")

	if chaser != null:
		var opening := chaser.position().distance_to(
			player.global_position
		)

		for _i in range(300):
			await get_tree().physics_frame

		var closing := chaser.position().distance_to(
			player.global_position
		)

		_check(
			closing < opening - 3.0,
			"and walks toward the player",
			"%.1f m -> %.1f m" % [opening, closing]
		)

	_test_a_chaser_commits(playground)

	# A definition whose script is missing does not leave a body in the world. One
	# that did would sit there being a crate, which is indistinguishable from an NPC
	# with nothing to do — and "the NPC does not move" sends the next person to the
	# movement code.
	var broken := DotPropDef.make(&"npc_broken", PlaygroundSpawnables.SCENE_ENTITY)
	broken.meta = {"kind": "entity", "script": "res://game/entities/nope.gd"}
	playground.props.catalogue.add(broken)

	var before_count := playground.props.world_count()
	var refused := playground.props.spawn(&"npc_broken", &"bot", at)

	await get_tree().process_frame

	_check(
		playground.props.world_count() == before_count,
		"an entity whose script is missing leaves nothing in the world",
		"%d -> %d" % [before_count, playground.props.world_count()]
	)
	_check(
		refused == null or not refused.is_alive(),
		"and its row is dead rather than counted against a budget"
	)

	# One that points at a real script which is not an entity is the same failure by
	# a different route, and it is the one a copy-paste actually produces.
	var wrong := DotPropDef.make(&"npc_wrong", PlaygroundSpawnables.SCENE_ENTITY)
	wrong.meta = {"kind": "entity", "script": "res://game/playground_config.gd"}
	playground.props.catalogue.add(wrong)

	before_count = playground.props.world_count()
	playground.props.spawn(&"npc_wrong", &"bot", at)

	await get_tree().process_frame

	_check(
		playground.props.world_count() == before_count,
		"and so does one whose script is not an entity"
	)

	playground.props.catalogue.remove(&"npc_broken")
	playground.props.catalogue.remove(&"npc_wrong")
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	await get_tree().process_frame

	_check(playground.entities.is_empty(), "clearing the world empties the tick list")
	_done()


## zee-dot-weapons: the pack in the menu, a server's rig firing from the eye, and a shot
## that shoves a crate.
##
## [b]The aim is the check that matters.[/b] Without `PlaygroundPlayer.component()`
## dot-weapon's bridge takes a shot from the body's transform, whose basis is identity here
## — so every shot leaves northwards from the feet, fires, costs ammunition and hits
## nothing, and every other number about it is right.
func _test_zee_weapons() -> void:
	_section("zee-dot-weapons")

	var zee := PlaygroundZee.defs()

	# A delivered game has only what is vendored in assets/ (zee-dot-weapons tools/sync-art.sh).
	var models := ZeeWeaponArtTable.validate_models()
	_check(models.ok, "every model the weapon art table names is vendored",
		"" if models.ok else models.error.message)

	_check(zee.size() == ZeeWeaponIds.all().size(), "every weapon in the pack is offered",
		"%d of %d" % [zee.size(), ZeeWeaponIds.all().size()])

	var usable := 0
	var offered := 0
	for def in zee:
		if def.validate().ok:
			usable += 1
		if playground.weapon_def(def.id) == def or playground.weapon_def(def.id) != null:
			offered += 1
	_check(usable == zee.size(), "each one a usable definition with no script")
	_check(offered == zee.size(), "and each one in the game's own list, which the menu shows")
	_check(
		playground.weapon_def(&"launcher") != null
			and not PlaygroundZee.is_zee(playground.weapon_def(&"launcher")),
		"the pack's launcher does not take the toy launcher's id"
	)
	_check(
		Array(PlaygroundWeapons.categories(playground.weapons)).has("sidearms"),
		"the menu's categories come from the pack's slots"
	)

	var player: PlaygroundPlayer = playground.players[&"bot"]
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	player.teleport(Vector3(-60.0, 1.0, -60.0), 90.0)
	await get_tree().physics_frame

	var rig := PlaygroundZee.arm(
		player, playground.weapon_def(&"zee_pistol"), ZeeWeaponRig.Role.SERVER, true,
		playground.tick_rate, playground.current_tick()
	)
	_check(rig != null and player.zee_rig == rig, "a server's rig goes on the player")
	_check(player.component(&"DotFpsController") == player.controller,
		"and the player answers dot-weapon's controller lookup")

	# A crate four metres along the way the player faces.
	var eye := player.eye_position()
	var aim := player.aim_direction()
	var crate := playground.props.spawn(&"crate", &"bot", eye + aim * 4.0)
	await get_tree().physics_frame

	var shots: Array[DotShot] = []
	var moved := 0
	var state := player.controller.state

	for i in range(200):
		var held := DotFpsCommand.BUTTON_USER_0 if (i / 20) % 2 == 0 else 0
		var outcome := rig.simulate_tick(
			PlaygroundZee.command_for(held, state.yaw, state.pitch, PlaygroundZee.slot_of(rig)),
			playground.current_tick() + i
		) if rig != null else null
		if outcome != null:
			shots.append_array(outcome.shots)
			moved += PlaygroundZee.shove_props(player, outcome, true)
		if moved > 0:
			break

	_check(not shots.is_empty(), "it fires", "%d shots" % shots.size())

	if not shots.is_empty():
		var first := shots[0]
		_check(first.origin.distance_to(eye) < 0.5, "from the eye, not the feet",
			"%.2f m off" % first.origin.distance_to(eye))
		_check(first.direction.normalized().dot(aim) > 0.98, "the way the player is facing",
			"dot %.3f" % first.direction.normalized().dot(aim))

	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(moved > 0 and crate != null and crate.body().linear_velocity.dot(aim) > 0.5,
		"and with the arena off it shoves the crate it hits, away from the shooter",
		"%.2f m/s along the aim" % (crate.body().linear_velocity.dot(aim) if crate != null else 0.0))

	PlaygroundZee.disarm(player)
	_check(player.zee_rig == null, "disarmed, the rig is gone")

	# [b]The pack is written at 64 Hz and this server runs 128[/b]; until dot-weapon scaled
	# a row by its authored_tick_rate every zee weapon here fired, reloaded and deployed
	# twice as fast. A second on an SMG's trigger is as many shots as at 64 Hz.
	var smg := PlaygroundZee.arm(
		player, playground.weapon_def(&"zee_smg"), ZeeWeaponRig.Role.SERVER, true,
		playground.tick_rate, playground.current_tick()
	)
	var rate := playground.tick_rate
	_check(smg != null and smg.arsenal.tick_rate == rate,
		"a zee rig's arsenal runs at the server's rate", "%d Hz" % rate)
	if smg != null:
		var row := smg.current_def()
		var base := playground.current_tick() + 1000
		var fired := 0
		for i in range(rate * 3):
			var held := DotFpsCommand.BUTTON_USER_0 if i >= rate * 2 else 0
			var out := smg.simulate_tick(
				PlaygroundZee.command_for(held, state.yaw, state.pitch, PlaygroundZee.slot_of(smg)),
				base + i
			)
			if out != null and out.used and i >= rate * 2:
				fired += 1
		var at_64 := int(ceil(float(ZeeWeaponPack.TICK_RATE) / float(row.use_interval_ticks)))
		_check(fired == at_64, "a second of SMG fire is as many shots at %d Hz as at 64" % rate,
			"%d here, %d at 64" % [fired, at_64])
		var reload_here := float(smg.arsenal.ticks_for(row, row.reload_ticks)) / float(rate)
		var deploy_here := float(smg.arsenal.ticks_for(row, row.deploy_ticks)) / float(rate)
		var tick64 := 1.0 / float(ZeeWeaponPack.TICK_RATE)
		_check(
			absf(reload_here - float(row.reload_ticks) * tick64) <= tick64
				and absf(deploy_here - float(row.deploy_ticks) * tick64) <= tick64,
			"and its reload and deploy take the same seconds",
			"reload %.3f s, deploy %.3f s" % [reload_here, deploy_here]
		)
	PlaygroundZee.disarm(player)

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


## Weapons: a script loaded by path, held rather than spawned.
func _test_weapons() -> void:
	_section("weapons")

	var defs := PlaygroundWeapons.built_in()

	_check(defs.size() >= 3, "the build ships an arsenal", "%d" % defs.size())
	_check(
		playground.weapons.size() == defs.size() + PlaygroundZee.defs().size(),
		"and the game offers it, with zee-dot-weapons after it"
	)

	for def in defs:
		_check(def.validate().ok, "'%s' is a usable definition" % def.id)

	var launcher := PlaygroundWeapons.make(
		PlaygroundWeapons.find(defs, &"launcher")
	)

	_check(launcher != null, "a weapon is built from its definition")
	_check(
		launcher != null and launcher.get_script().resource_path
			== PlaygroundWeapons.find(defs, &"launcher").script_path,
		"running exactly the script it names"
	)

	# The two ways a catalogue entry is wrong, and neither may hand back a working-
	# looking weapon: a base `PlaygroundWeapon` whose buttons do nothing is
	# indistinguishable from a weapon that is fine and pointed at nothing.
	var missing := PlaygroundWeaponDef.make(&"x", "X", "res://game/weapons/nope.gd")
	_check(
		PlaygroundWeapons.make(missing) == null,
		"a weapon whose script is missing is refused"
	)

	var not_a_weapon := PlaygroundWeaponDef.make(
		&"y", "Y", "res://game/playground_config.gd"
	)
	_check(
		PlaygroundWeapons.make(not_a_weapon) == null,
		"and so is one whose script is not a weapon"
	)

	# The launcher fires whatever the menu armed, which is what saves it having a
	# second list of ammunition and a second way to choose from it.
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	launcher.equip(playground, PlaygroundWeapons.find(defs, &"launcher"))
	launcher.wielder = &"bot"
	launcher.armed = &"beach_ball"

	var fired := launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

	_check(fired.ok, "the launcher fires")

	if fired.ok:
		var shot := fired.value as DotPropInstance

		_check(shot.def.id == &"beach_ball", "the prop the menu armed")
		_check(
			shot.body().linear_velocity.length() > 10.0,
			"at a muzzle velocity",
			"%.1f m/s" % shot.body().linear_velocity.length()
		)

		# A muzzle velocity, not an impulse. An impulse is divided by the mass, which
		# is right for a punt and exactly wrong here: a launcher whose boulder leaves
		# at a fortieth of the speed of its ball is one nobody can aim.
		launcher.armed = &"boulder"

		var heavy := launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

		_check(
			heavy.ok and is_equal_approx(
				(heavy.value as DotPropInstance).body().linear_velocity.length(),
				shot.body().linear_velocity.length()
			),
			"and a 900 kg prop leaves as fast as a 2 kg one"
		)

	# Armed with something the catalogue no longer has — a map change can do that —
	# it falls back rather than being refused with "no such prop", which reads as the
	# weapon being broken rather than as the ammunition being gone.
	launcher.armed = &"nothing_like_this"

	var fallback := launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

	_check(fallback.ok, "an armed prop that no longer exists falls back")

	# The impulse gun shoves what is near it, and leaves frozen props alone: freezing
	# is how a builder says "this is finished", and a blast that undid it would make
	# the two tools fight.
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	var loose := playground.props.spawn(&"crate", &"bot", Vector3(2.0, 1.0, 0.0))
	var stuck := playground.props.spawn(&"crate", &"bot", Vector3(-2.0, 1.0, 0.0))

	DotPhysGun.set_frozen(stuck, true)

	var impulse := PlaygroundWeapons.make(PlaygroundWeapons.find(defs, &"impulse"))
	impulse.equip(playground, PlaygroundWeapons.find(defs, &"impulse"))
	impulse.wielder = &"bot"

	loose.body().linear_velocity = Vector3.ZERO

	var blast := impulse.primary(null, Vector3.ZERO, Vector3.FORWARD)

	# Two steps, not one. `apply_central_impulse` is not readable in
	# `linear_velocity` until the step that consumes it has run — dot-props' own
	# suite found the same thing and says so — and awaiting a physics frame lands
	# before that step rather than after it.
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(blast.ok and int(blast.value) >= 1, "the impulse gun moves something")
	_check(
		loose.body().linear_velocity.length() > 1.0,
		"a loose prop is shoved",
		"%.1f m/s" % loose.body().linear_velocity.length()
	)
	_check(
		stuck.body().linear_velocity.length() < 0.5,
		"and a frozen one is left alone",
		"%.1f m/s" % stuck.body().linear_velocity.length()
	)

	# The remover's right click clears what you own, and goes through the spawner so
	# the budget it frees is real.
	var remover := PlaygroundWeapons.make(PlaygroundWeapons.find(defs, &"remover"))
	remover.equip(playground, PlaygroundWeapons.find(defs, &"remover"))
	remover.wielder = &"bot"

	var cleared := remover.secondary(null, Vector3.ZERO, Vector3.FORWARD)

	_check(cleared.ok and int(cleared.value) >= 2, "the remover clears your props")
	_check(playground.props.player_count(&"bot") == 0, "and the budget goes with them")

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


## The spawn menu, driven the way a player drives it.
##
## [b]dot-ui's suite cannot reach this and neither can dot-props'.[/b] A menu built
## out of a catalogue is exactly the seam this project exists to run: the screen stack
## is one addon, the catalogue is another, and the code joining them is here. It is
## also a `Control` built entirely in code, which is the shape that produced the
## family's `set_anchors_preset` bug — so the sizes are checked, not just the
## contents.
func _test_spawn_menu() -> void:
	_section("the spawn menu")

	var menu := PlaygroundSpawnMenu.new()
	menu.catalogue = playground.props.catalogue
	menu.weapons = playground.weapons
	add_child(menu)

	# Registered on a real stack rather than shown directly: pushing is what calls
	# `_on_push`, and `_on_push` is what fills the grid.
	var stack := DotScreenStack.new()
	add_child(stack)

	var ready := stack.setup()
	_check(ready.ok, "the screen stack sets up")

	var registered := stack.register(menu)
	_check(registered.ok, "and the menu registers on it")

	var pushed := stack.push(menu.screen_id())
	_check(pushed.ok, "and opens")
	_check(stack.any_open(), "and the stack knows a menu is up")

	await get_tree().process_frame

	_check(
		menu.size.x > 100.0 and menu.size.y > 100.0,
		"the menu has a size, which a Control built in code does not get for free",
		"%.0f x %.0f" % [menu.size.x, menu.size.y]
	)

	# [b]The server browser, on the same stack and measured the same way.[/b] It is the
	# second screen this game has built in code, and the failure it can have is the one
	# dot-ui had five of: `set_anchors_preset` describes how a rectangle FOLLOWS its
	# parent and changes nothing until something resizes it, so a Control keeps the zero
	# size it was created with — and every child then lays out inside nothing while being,
	# by every property, correctly configured. Only a size says so.
	var servers := PlaygroundBrowser.new()
	add_child(servers)

	var browser_registered := stack.register(servers)
	_check(browser_registered.ok, "the server browser registers too")

	var browser_open := stack.push(servers.screen_id())
	_check(browser_open.ok, "and opens")

	await get_tree().process_frame

	_check(
		servers.size.x > 100.0 and servers.size.y > 100.0,
		"and has a size rather than being an invisible 0 x 0",
		"%.0f x %.0f" % [servers.size.x, servers.size.y]
	)
	_check(
		servers.browser != null and servers.browser.count() > 0,
		"with something on the list, so a first run is not an empty box",
		"%d" % (servers.browser.count() if servers.browser != null else -1)
	)

	# [b]Filtering is local and always will be.[/b] A server that decided which of its own
	# properties to report is a server that reports whatever gets it listed — so the
	# filter lives on the model, and a screen that filtered its own rows would be a second
	# filter that disagrees with the one favourites are pinned by.
	_check(
		servers.browser.filter != null,
		"and a filter the client owns rather than one the server answers"
	)

	# The site's listing: off unless a site is named, and this game's servers when one is.
	var env_key := "DOT_BROWSER_BACKBONE_URL"
	var had := OS.get_environment(env_key)
	OS.unset_environment(env_key)
	var off: DotResult = PlaygroundBrowser.site_listing()
	_check(
		off.ok and off.value == null
			and not servers.browser.sources().any(
				func(s: DotBrowserSource) -> bool: return s.source_name() == &"backbone"
			),
		"no site listing is read when none is configured"
	)
	OS.set_environment(env_key, "http://127.0.0.1:9")
	var on: DotResult = PlaygroundBrowser.site_listing()
	var listing: DotBrowserSourceBackbone = on.value if on.ok else null
	_check(
		listing != null and listing.config.page_url(1).contains("app=playground"),
		"and this game's servers are when one is",
		listing.config.page_url(1) if listing != null else str(on.error)
	)
	# Where the site comes from when nobody passed a flag. Web: ?backbone= > page origin;
	# native: argv > env > the exported default (argv over env is DotConfig.load_layered's
	# order and cannot be injected here). Each result is also the one a reversed order
	# would get wrong, so a swap fails a check.
	OS.unset_environment(env_key)
	var web_both := PlaygroundBrowser.resolve_default_site({
		"web": true, "origin": "https://site.example", "query": "https://other.example"
	})
	_check(web_both == "https://other.example", "on the web ?backbone= beats the page origin", web_both)
	var web_origin := PlaygroundBrowser.resolve_default_site({"web": true, "origin": "https://site.example", "query": ""})
	_check(web_origin == "https://site.example", "and with no query the page's own origin is the site", web_origin)
	var web_file := PlaygroundBrowser.resolve_default_site({"web": true, "origin": "null", "query": ""})
	_check(web_file == "", "and a page with no usable origin lists no site", web_file)
	var web_listing: DotResult = PlaygroundBrowser.site_listing({"web": true, "origin": "https://site.example", "query": ""})
	_check(
		web_listing.ok and web_listing.value != null
			and web_listing.value.config.page_url(1).begins_with("https://site.example/api/content/server/list")
			and web_listing.value.config.page_url(1).contains("app=playground"),
		"so a web client lists its own site's servers without a flag"
	)
	var saved_default := PlaygroundBrowser.default_backbone_url
	PlaygroundBrowser.default_backbone_url = "https://deploy.example"
	var native_default := PlaygroundBrowser.resolve_default_site({"web": false, "origin": "https://site.example", "query": "https://other.example"})
	_check(native_default == "https://deploy.example", "on native the exported default is used and the page is never asked", native_default)
	OS.set_environment(env_key, "http://127.0.0.1:9")
	var env_wins: DotResult = PlaygroundBrowser.site_listing({"web": false})
	_check(
		env_wins.ok and env_wins.value != null and env_wins.value.config.backbone_url == "http://127.0.0.1:9",
		"and the environment beats that default",
		str(env_wins.value.config.backbone_url) if env_wins.ok and env_wins.value != null else str(env_wins.error)
	)
	PlaygroundBrowser.default_backbone_url = saved_default
	if had != "":
		OS.set_environment(env_key, had)
	else:
		OS.unset_environment(env_key)

	stack.pop()
	servers.queue_free()

	# --- Props tab -----------------------------------------------------------

	var props_shown := menu.shown()
	var prop_count := 0

	# Hidden entries (debris) are the game's, not the menu's, as the menu's own filter says.
	for def in playground.props.catalogue.props:
		if PlaygroundSpawnables.kind_of(def) == PlaygroundSpawnables.Kind.PROP and not bool(def.meta.get("hidden", false)):
			prop_count += 1

	_check(
		props_shown.size() == prop_count,
		"the props tab shows every prop and no entities",
		"%d of %d" % [props_shown.size(), prop_count]
	)
	_check(
		not props_shown.has(&"npc_wanderer"),
		"and an entity is not among them"
	)
	_check(menu.card_for(&"crate") != null, "each one has a card that names it")

	# Icons. Nothing here ships art, so every card is drawn from the definition —
	# and a card with no icon at all is the failure that looks like a working menu
	# right up until somebody opens it.
	var crate_card := menu.card_for(&"crate")
	var ball_card := menu.card_for(&"ball")

	_check(
		crate_card != null and crate_card.icon != null
		and crate_card.icon.get_width() == PlaygroundIcons.SIZE,
		"with an icon on it"
	)
	_check(
		crate_card != null and ball_card != null
		and crate_card.icon != ball_card.icon,
		"and a box and a sphere do not get the same one"
	)

	# The cache is keyed on the drawing, not on the prop, so two props that draw the
	# same share a texture. That is what stops a four-hundred-prop catalogue building
	# four hundred images every time somebody presses Q.
	_check(
		PlaygroundIcons.generated(PlaygroundIcons.Glyph.BOX, 1.0, Color.RED)
		== PlaygroundIcons.generated(PlaygroundIcons.Glyph.BOX, 1.0, Color.RED),
		"an icon drawn twice is one texture"
	)

	# Clicking spawns. The menu never spawns anything itself — it emits, and the
	# client asks the server — which is what lets this file work unchanged when the
	# spawn becomes a dot-net message.
	var chosen: Array[StringName] = []
	menu.prop_chosen.connect(
		func(id: StringName) -> void: chosen.append(id)
	)

	menu.card_for(&"barrel").pressed.emit()

	_check(chosen.size() == 1 and chosen[0] == &"barrel",
		"clicking a prop asks for that prop")
	_check(menu.selected == &"barrel", "and arms it for the spawn key")

	# Search reaches across every category on the tab, because a player who types
	# "barrel" wants the barrel and not "no such prop, you are on the Toys tab".
	menu._on_search_changed("boulder")
	await get_tree().process_frame

	var found := menu.shown()
	_check(found.has(&"boulder"), "searching finds a prop by name")
	_check(found.size() < props_shown.size(), "and narrows the grid")

	menu._on_search_changed("zzzz")
	await get_tree().process_frame

	_check(
		menu.shown().is_empty(),
		"a search that matches nothing shows nothing"
	)

	menu._on_search_changed("")
	await get_tree().process_frame

	# --- Entities tab --------------------------------------------------------

	menu.show_tab(PlaygroundSpawnMenu.Tab.ENTITIES)
	await get_tree().process_frame

	var entities_shown := menu.shown()

	_check(not entities_shown.is_empty(), "the entities tab has entities on it")
	_check(
		entities_shown.has(&"npc_wanderer") and not entities_shown.has(&"crate"),
		"and no props"
	)

	# --- Weapons tab ---------------------------------------------------------

	menu.show_tab(PlaygroundSpawnMenu.Tab.WEAPONS)
	await get_tree().process_frame

	var weapons_shown := menu.shown()

	_check(
		weapons_shown.size() == playground.weapons.size(),
		"the weapons tab shows every weapon",
		"%d of %d" % [weapons_shown.size(), playground.weapons.size()]
	)

	var equipped: Array[StringName] = []
	menu.weapon_chosen.connect(
		func(id: StringName) -> void: equipped.append(id)
	)

	menu.card_for(&"launcher").pressed.emit()

	_check(
		equipped.size() == 1 and equipped[0] == &"launcher",
		"and clicking one asks to equip it rather than to spawn it"
	)

	# Switching tabs clears the filter. Carrying "containers" onto the weapons tab
	# would show nothing and read as the tab being broken.
	menu.show_tab(PlaygroundSpawnMenu.Tab.PROPS)
	await get_tree().process_frame

	_check(
		menu.shown().size() == prop_count,
		"and going back to props shows all of them again"
	)

	# The Builds tab asks the server when it opens, and a click asks for that build.
	var opened := [0]
	var picked: Array[String] = []
	menu.builds_opened.connect(func() -> void: opened[0] += 1)
	menu.build_chosen.connect(func(build_name: String) -> void: picked.append(build_name))
	menu.show_tab(PlaygroundSpawnMenu.Tab.BUILDS)
	await get_tree().process_frame
	_check(opened[0] == 1 and menu.shown().is_empty(), "the Builds tab asks for the player's builds, and shows none until they come")
	menu.set_builds([{"name": "bridge", "props": 6, "custom": false}, {"name": "car", "props": 9, "custom": true}])
	await get_tree().process_frame
	_check(str(menu.shown()) == str([&"bridge", &"car"]), "then shows each one", str(menu.shown()))
	menu.card_for(&"car").pressed.emit()
	_check(str(picked) == str(["car"]), "and clicking one asks for it by name")
	_check(menu._categories_for_tab() == PackedStringArray(["builds", "custom props"]),
		"with a welded build filed as a custom prop")
	menu.show_tab(PlaygroundSpawnMenu.Tab.PROPS)
	await get_tree().process_frame

	_check(
		PlaygroundSpawnMenu.name_of_tool(&"phys") == "physics gun"
		and PlaygroundSpawnMenu.name_of_tool(&"") == "nothing",
		"a tool id has a name, and an empty one is not silently a gravity gun"
	)

	var popped := stack.pop(menu.screen_id())
	_check(popped.ok and not stack.any_open(), "the menu closes")

	stack.queue_free()
	_done()


# --- The sandbox, and the course in the corner of it ------------------------

## `pg_lobby` is a sandbox on the main track and a jump course on bonus 1.
##
## [b]Both halves are the test.[/b] The main track still has no start and no end, so
## everything the game does works with no timer running — which is what `pg_lobby`
## has always been for. The bonus track is a real course with a start, a finish, a
## split and a reset volume, which is what proves the timer is not a surf-and-bhop
## thing: nothing about a jump course is a movement genre.
func _test_the_sandbox_and_its_course() -> void:
	_section("the sandbox and its course")

	var changed: DotResult = await playground.change_map(&"pg_lobby")
	_check(changed.ok, "the sandbox loads")

	var player: PlaygroundPlayer = playground.players[&"bot"]
	var zones := playground.timers.zones

	_check(zones != null and not zones.zones.is_empty(), "and it has zones")

	if zones == null:
		return

	_check(
		zones.of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN).is_empty()
		and zones.of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN).is_empty(),
		"the main track has no start and no end: it is somewhere to build"
	)
	_check(
		zones.of_kind(
			DotTimerZone.Kind.START, DotTimerTrack.BONUS_FIRST
		).size() == 1,
		"and the course on bonus 1 has one start"
	)
	_check(
		zones.of_kind(
			DotTimerZone.Kind.END, DotTimerTrack.BONUS_FIRST
		).size() == 1,
		"and one finish"
	)
	_check(zones.problems().is_empty(), "with nothing wrong with the set",
		"; ".join(zones.problems()))

	var tracks := playground.tracks_on_this_map()
	_check(
		tracks == [
			DotTimerTrack.MAIN,
			DotTimerTrack.BONUS_FIRST,
			DotTimerTrack.BONUS_FIRST + 1,
			PgLobby.CIRCUIT_TRACK,
			PgLobby.STONES_TRACK,
			PgLobby.LAUNCH_TRACK,
			PgLobby.RELAY_TRACK,
		],
		"the game can see all seven tracks without being told about them",
		str(tracks)
	)

	_test_the_tower(playground, zones)
	_test_the_circuit(playground, zones)

	# The main track, exactly as before: walking about starts nothing.
	player.timer.set_track(DotTimerTrack.MAIN)
	playground.spawn_player(&"bot")

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)

	await _drive(&"bot", forward, 200)

	_check(
		not player.timer.run.is_active(),
		"no run starts on the track with no start zone"
	)
	_check(
		player.controller.state.is_grounded(),
		"and the player walks on it normally"
	)

	playground.props.limits.spawn_interval = 0.0
	var crate := playground.props.spawn(
		&"crate", &"bot", player.global_position + Vector3.UP * 3.0
	)
	_check(crate != null, "and can still spawn props")

	# The course. Switching track moves the player to its spawn, which is the only
	# way onto it — the start pad is six metres up on a pillar.
	_check(player.timer.set_track(DotTimerTrack.BONUS_FIRST), "the track switches")
	playground.spawn_player(&"bot")

	var spawn := PgLobby.build_zones().first_of_kind(
		DotTimerZone.Kind.SPAWN, DotTimerTrack.BONUS_FIRST
	)

	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the player on the course's start pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	# Walking off the pad starts the run, and falling off the course puts the player
	# back on the pad. Driven as one stretch and watched through the signals rather
	# than sampled between two short drives: a bot walking off a platform is at the
	# mercy of where in a tick it left the edge, and a test that checked "has it
	# started yet" after a fixed number of ticks would be timing-sensitive for no
	# reason.
	var started: Array[bool] = [false]
	var respawns: Array[int] = []

	# An Array, not a counter: a GDScript lambda captures locals by value, so an int
	# incremented in a handler reads zero outside it and the test reports a failure
	# for a signal that fired perfectly.
	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			respawns.append(zone.id)

	player.timer.run_started.connect(on_start)
	playground.timers.effect_requested.connect(on_effect)

	# [b]Driven until the respawn happens rather than for a fixed 400 ticks, and the
	# difference is the whole reason this comment is here.[/b] A bot holding forward
	# off a start pad falls, is put back on the pad, walks off it again and starts a
	# SECOND run — so "is a run active at tick 400" is a question about how many times
	# that cycle fitted into 400 ticks, which is a function of where the first gap is.
	# Widening or narrowing one gap on a course fifty metres away changed the answer,
	# and the check failed while reporting nothing about what it was written to prove.
	#
	# Stopping at the respawn and then standing still is deterministic: a player who is
	# not walking cannot leave the pad, so a run that is still active after this is a
	# run the respawn did not abandon, which is the thing being asked.
	for _tick in range(400):
		player.controller.apply_command(forward.duplicate_command())
		await get_tree().physics_frame

		if not respawns.is_empty():
			break

	var still := DotFpsCommand.new()
	for _tick in range(8):
		player.controller.apply_command(still.duplicate_command())
		await get_tree().physics_frame

	player.timer.run_started.disconnect(on_start)
	playground.timers.effect_requested.disconnect(on_effect)

	_check(started[0], "walking off the pad starts a run on the bonus track")

	# This is the check that would have failed for as long as this family has
	# existed. `DotTimer.effect_requested` was declared, forwarded by the manager and
	# connected by both games — and emitted by NOTHING, so every RESPAWN zone in the
	# family did exactly nothing and a player who fell off a surf map fell for ever.
	# Fixed in dot-timer; this is the join it was missing from.
	_check(
		not respawns.is_empty(),
		"falling off the course asks the game to put the player back"
	)

	# And the game actually did it: six metres up, on the course, rather than on the
	# sandbox floor the course is built over.
	_check(
		player.global_position.y > 5.0,
		"which puts them back on the course rather than under it",
		"y = %.2f" % player.global_position.y
	)
	_check(
		not player.timer.run.is_active(),
		"and the run they were on is abandoned rather than left running"
	)

	# The same volume, on the main track, must do nothing: somebody building under
	# the course would otherwise be teleported onto it every few seconds.
	player.timer.set_track(DotTimerTrack.MAIN)

	var under := Vector3(PgLobby.COURSE_X, 1.0, PgLobby.COURSE_START_Z)
	player.teleport(under, 0.0)

	await _drive(&"bot", still, 60)

	_check(
		player.global_position.distance_to(under) < 3.0,
		"a sandbox player standing under the course is left alone",
		"%.2f m away" % player.global_position.distance_to(under)
	)

	await _walk_the_tower(player)
	await _drive_the_circuit()

	playground.remove_player(&"bot")
	_check(playground.players.is_empty(), "a player can leave cleanly")
	_check(
		playground.props.world_count() == 0,
		"and their props go with them"
	)
	_done()


## A bot climbs bonus 2 from its pad to the cap on top of the pillar.
##
## [b]Until 2026-09-23 this was "only the first jump, and that is the honest limit of a
## bot here", and the limit was the bot's.[/b] The written reason was that a spiral is
## finished by air-strafing round a corner. Measured, it is not: every gap on the tower
## is 2.04 m of air against a 4.02 m climbing reach, so nobody has to carry any speed
## round anything — they have to FACE the next platform before jumping at it, which is
## a thing a scripted bot can do exactly and which no bot in this family had ever been
## written to do. Every one held a single yaw for its whole run. See [method _drive_route].
##
## What this still proves before it drives, and both are invisible to every count: the
## spawn faces the course, and it is outside the pillar.
func _walk_the_tower(player: PlaygroundPlayer) -> void:
	var track := DotTimerTrack.BONUS_FIRST + 1

	_check(player.timer.set_track(track), "the tower's track switches")
	playground.spawn_player(&"bot")

	var spawn := PgLobby.build_zones().first_of_kind(DotTimerZone.Kind.SPAWN, track)

	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the player on the tower's pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	_check(
		Vector3(
			player.global_position.x - PgLobby.TOWER_X,
			0.0,
			player.global_position.z - PgLobby.TOWER_Z
		).length() > PgLobby.TOWER_PILLAR * 0.5,
		"outside the pillar rather than inside it",
		"a spawn inside a pillar is a player who cannot move, and every count passes"
	)

	var first := PgLobby.tower_platform_centre(0)
	var facing := player.aim_direction()
	var toward := Vector3(
		first.x - player.global_position.x, 0.0, first.z - player.global_position.z
	).normalized()

	_check(
		facing.dot(toward) > 0.9,
		"facing the first platform rather than the pillar",
		"dot %.2f; a spiral has no obvious forward and finding it costs a second"
			% facing.dot(toward)
	)

	var route := PgLobby.tower_route()

	# 16 platforms and a cap at roughly a second a jump is ~2,200 ticks; 4,000 leaves
	# room for a fall onto a lower turn and the climb back, without being so long that a
	# stuck bot takes a minute to say so.
	var length := _route_length(player.global_position, route)
	var drive: Dictionary = await _drive_route(player, route, 4000)

	print("    the tower: platform %d of %d, splits %s, finish %s, %d ticks, %d respawns" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["respawns"]),
	])
	var pace := _print_pace(
		"the tower", float(drive["distance"]), length, int(drive["ticks"]),
		PgLobby.MOVE_SPEED, float(drive["top_speed"])
	)
	_check_pace("the tower", float(drive["distance"]), length, pace, PgLobby.MOVE_SPEED, 0.75)
	_print_where("the tower", "platforms", drive["tally"], route[route.size() - 1].end.y - route[0].end.y)
	_check_where("the tower", "platforms", drive["tally"])

	_check(drive["started"], "leaving the tower's pad starts a run on bonus 2")
	_check(
		int(drive["reached"]) >= 1,
		"and a bot running off the pad reaches the first platform",
		"never got onto one; the spawn faces it and the gap is 0.2 m"
	)
	_check(
		drive["splits"] == [1, 2],
		"it climbs through both height bands, in order",
		str(drive["splits"])
	)
	_check(
		drive["finished"],
		"and reaches the cap on the pillar: bonus 2 run end to end",
		"got to box %d of %d at y %.1f in %d ticks"
			% [int(drive["reached"]), route.size() - 1,
				player.global_position.y, int(drive["ticks"])]
	)
	_check(
		int(drive["respawns"]) == 0,
		"without once being put back on the pad",
		"%d respawns; a drive that finishes on its third attempt is a drive that is lucky"
			% int(drive["respawns"])
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)


# --- The narrows -----------------------------------------------------------

## `pg_bhop_intro`'s bonus route, driven start to finish.
##
## [b]This is the first bonus track in this family that anything has ever run.[/b]
## Every other bonus here is checked by switching onto it, looking at the spawn and
## switching back — which is why they went for as long as they did with no respawn
## zone on them at all. A route nothing has completed is a route nobody knows is
## completable.
##
## [b]The driver is the interesting part, and it is not "hold forward and jump".[/b]
## That is what the rest of this suite does and it produces a player travelling at
## **one** metre a second: with `auto_hop` on and jump held, the player leaves the
## ground on the tick it lands, so `accelerate` (7 m/s on the ground) never gets a
## tick to work in, and air acceleration cannot make up the difference because
## `max_air_wish_speed` is 1.0 — that cap is the whole reason air-strafing is a skill
## rather than a button. A real player gains speed by turning into the strafe; a bot
## that holds one direction cannot, and it bleeds back to the cap.
##
## So this bot jumps **at the gaps** instead of continuously, which keeps it on the
## ground long enough to hold 7 m/s and is why the narrows has a constant
## [constant PgBhopIntro.BONUS_GAP]: 3.5 m is 0.5 s of flight at that speed against
## the 0.68 s a 1.15 m jump buys, so the route is clearable without ever gaining any.
## The main run deliberately is not — its last gap is 7 m and only a player who has
## been strafing can cross it, which is what that route is for.
func _test_the_narrows() -> void:
	print("")
	_section("the narrows — pg_bhop_intro's bonus route")

	var loaded: DotResult = await playground.change_map(&"pg_bhop_intro")
	_check(loaded.ok, "the bhop map loads",
		loaded.error.message if not loaded.ok else "")

	var zones := PgBhopIntro.build_zones()

	_check(zones.problems().is_empty(), "its zones are well formed",
		", ".join(zones.problems()))
	_check(
		zones.playable_tracks() == PackedInt32Array(
			[
				DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST,
				PgBhopIntro.SWITCHBACK_TRACK, PgBhopIntro.ASCENT_TRACK,
				PgBhopIntro.LADDER_TRACK, PgBhopIntro.FLOAT_TRACK, PgBhopIntro.DROP_TRACK,
			]
		),
		"and all seven of its routes can be run, the switchback, the ascent, the ladder, the float and the drop included",
		str(zones.playable_tracks())
	)

	# The splits, on both routes. A map with one start and one finish exercises none
	# of dot-timer's per-stage machinery, which is the reason these were added.
	_check(
		zones.of_kind(DotTimerZone.Kind.STAGE, DotTimerTrack.MAIN).size() == 3,
		"the main run has three splits"
	)

	var track := DotTimerTrack.BONUS_FIRST

	_check(
		zones.of_kind(DotTimerZone.Kind.START, track).size() == 1
			and zones.of_kind(DotTimerZone.Kind.END, track).size() == 1,
		"the narrows has one start and one finish"
	)
	_check(
		zones.of_kind(DotTimerZone.Kind.STAGE, track).size() == 3,
		"and three splits"
	)
	_check(
		zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"and a spawn and a respawn volume, which no bonus track in this family had until one was run",
		", ".join(zones.route_problems())
	)

	# The course narrows, which is the whole difficulty. Asserted against the map's own
	# arithmetic rather than against numbers copied here: a second description of where
	# a block is and how wide it is, is a second thing that can disagree with the
	# geometry — and on a timer map that is a leaderboard nobody can compare.
	_check(
		is_equal_approx(PgBhopIntro.bonus_width_at(0), PgBhopIntro.BONUS_FIRST_WIDTH)
			and is_equal_approx(
				PgBhopIntro.bonus_width_at(PgBhopIntro.BONUS_BLOCKS - 1),
				PgBhopIntro.BONUS_LAST_WIDTH
			),
		"its blocks run from the full width down to the last one"
	)

	var thin := zones.thin_zones(12.0, playground.tick_rate)
	_check(thin.is_empty(),
		"and no zone is thin enough for a hopping player to pass through",
		"%d thin" % thin.size())

	var player := playground.add_player(&"bot", "Bot")
	_check(player.timer.set_track(track), "the track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the player on the narrows' start pad, six metres above the main run",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	# Arrays rather than counters: a GDScript lambda captures locals by value, so an
	# int incremented in a handler reads zero outside it and the test reports a
	# failure for a signal that fired perfectly.
	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var splits: Array[int] = []

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true

	player.timer.run_started.connect(on_start)
	player.timer.stage_reached.connect(on_stage)
	player.timer.run_finished.connect(on_finish)

	var command := DotFpsCommand.new()
	command.move = Vector2(0.0, 1.0)

	var ticks := 0
	var finish_at := zones.first_of_kind(DotTimerZone.Kind.END, track).centre()
	var length := Vector2(
		finish_at.x - player.global_position.x, finish_at.z - player.global_position.z
	).length()
	var covered := 0.0
	var top_speed := 0.0
	var last_at := player.global_position

	# Capped well above the ~1890 ticks the route takes, and broken out of on the
	# finish rather than run to the end: a drive that keeps going past the finish pad
	# walks the bot off the far side of it.
	for i in range(2400):
		command.set_button(
			DotFpsCommand.BUTTON_JUMP,
			_jumping_at(player.global_position.z)
		)
		player.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame
		ticks = i
		var moved := Vector2(
			player.global_position.x - last_at.x, player.global_position.z - last_at.z
		).length()
		if moved < 1.0:
			covered += moved
		last_at = player.global_position
		var now := player.controller.state.velocity
		top_speed = maxf(top_speed, Vector2(now.x, now.z).length())

		if finished[0]:
			break

	player.timer.run_started.disconnect(on_start)
	player.timer.stage_reached.disconnect(on_stage)
	player.timer.run_finished.disconnect(on_finish)

	var pace := _print_pace(
		"the narrows", covered, length, ticks + 1, PgLobby.MOVE_SPEED, top_speed
	)
	_check_pace("the narrows", covered, length, pace, PgLobby.MOVE_SPEED, 0.9)

	_check(started[0], "leaving the start pad starts a run on the narrows")

	var speed := Vector2(
		player.controller.state.velocity.x, player.controller.state.velocity.z
	).length()
	_check(
		speed > 6.0,
		"the bot holds its ground speed the whole way rather than bleeding to the air cap",
		"%.2f m/s" % speed
	)

	_check(
		splits == [1, 2, 3],
		"it crosses all three splits, in order",
		str(splits)
	)

	# The check this whole section exists for.
	_check(
		finished[0],
		"and reaches the finish: a bonus route completed end to end, which nothing "
		+ "in this family had ever done",
		"gave up at tick %d, z = %.1f" % [ticks, player.global_position.z]
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


## Whether the bot should be holding jump at [param z] on the narrows.
##
## The gaps are where a jump is needed and nowhere else — see the note on
## [method _test_the_narrows] for why holding it continuously is the thing that does
## not work. Read off the map's own block arithmetic so that moving a block moves the
## jump with it.
static func _jumping_at(z: float) -> bool:
	for i in range(PgBhopIntro.BONUS_BLOCKS):
		var edge: float = (
			PgBhopIntro.bonus_block_near_z(i) - PgBhopIntro.BONUS_BLOCK_LENGTH
		)

		if z <= edge + 0.8 and z > edge - 0.2:
			return true

	return false


## The plunge — `pg_surf_intro`'s bonus route, driven from its pad to its finish.
##
## [b]The reason this route exists is the measurement in [method _test_surf_run].[/b]
## The main run's two ramps are level along their length, so the whole descent comes
## from the stepped floor between them and the ramps never give the player anything;
## a scripted strafer covers 5% of that route and crosses none of its splits. The
## plunge is one face pitched past [code]max_slope_angle[/code] and descending along
## the run, so gravity accelerates the player ALONG it — which is the thing the map
## was supposed to be about and was not.
##
## It is straight, and that is deliberate for the reason
## [method _test_the_narrows] gives about a constant gap: a scripted bot cannot
## air-strafe, so a route that needs turning is a route no suite runs end to end.
## Here the bot holds forward and nothing else. No jump pattern is needed at all —
## on a face nobody can stand on there is no ground to leave.
func _test_the_plunge() -> void:
	print("")
	_section("the plunge — pg_surf_intro's bonus route")

	var loaded: DotResult = await playground.change_map(&"pg_surf_intro")
	_check(loaded.ok, "the surf map loads again",
		loaded.error.message if not loaded.ok else "")

	var zones := PgSurfIntro.build_zones()
	var track := DotTimerTrack.BONUS_FIRST

	_check(zones.problems().is_empty(), "its zones are well formed",
		", ".join(zones.problems()))
	_check(
		zones.playable_tracks() == PackedInt32Array(
			[DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST, PgSurfIntro.CASCADE_TRACK,
				PgSurfIntro.BANK_TRACK, PgSurfIntro.TRANSFER_TRACK]
		),
		"and the surf map has five routes now rather than one",
		str(zones.playable_tracks())
	)

	# Asked per track rather than of whichever one happened to be current — see
	# `[track-zone-1]`. A zone carries a track, so a set that is complete for track 0
	# and partial for track 1 passes `problems()` while being an unfinishable route.
	# This was four checks walking this track's kinds by name; it is dot-timer's
	# `route_problems()` now, which asks the same of every route.
	_check(
		zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"the plunge has its own start, finish, spawn and pit",
		", ".join(zones.route_problems())
	)

	_check(
		zones.of_kind(DotTimerZone.Kind.STAGE, track).size()
			== PgSurfIntro.CHUTE_SPLITS.size(),
		"and a split for each fraction the map names"
	)

	# A player on this route is the fastest thing on the map, so it is the one where
	# a thin line is certain to be passed through rather than merely likely.
	var thin := zones.thin_zones(30.0, playground.tick_rate)
	_check(thin.is_empty(),
		"and no zone is thin enough for a player at 30 m/s to cross without entering",
		"%d thin" % thin.size())

	var player := playground.add_player(&"bot", "Bot")

	# The face has to be unstandable or none of this is surf. Asked of the tunables
	# this game actually runs a player with, rather than of a number written down a
	# second time here — the angle is the one thing about this route that cannot be
	# changed without changing what the route IS.
	var max_slope: float = player.controller.tunables.max_slope_angle
	_check(
		PgSurfIntro.CHUTE_PITCH > max_slope,
		"the face is steeper than a player can stand on",
		"%.0f° against %.0f°" % [PgSurfIntro.CHUTE_PITCH, max_slope]
	)

	_check(player.timer.set_track(track), "the track switches to the plunge")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the player on the plunge's pad, beside the main run rather than on it",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	# Arrays, because a GDScript lambda captures locals by value.
	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var splits: Array[int] = []

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true

	player.timer.run_started.connect(on_start)
	player.timer.stage_reached.connect(on_stage)
	player.timer.run_finished.connect(on_finish)

	var command := DotFpsCommand.new()
	command.move = Vector2(0.0, 1.0)
	command.yaw = 0.0

	var ticks := 0
	var airborne := 0
	var top_speed := 0.0

	for i in range(2000):
		player.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame
		ticks = i

		if not player.controller.state.is_grounded():
			airborne += 1

		top_speed = maxf(top_speed, player.speed())

		if finished[0]:
			break

	player.timer.run_started.disconnect(on_start)
	player.timer.stage_reached.disconnect(on_stage)
	player.timer.run_finished.disconnect(on_finish)

	_check(started[0], "leaving the start pad starts a run on the plunge")

	# The whole difference between the two routes, stated as a number. PRINTED as
	# well as asserted, because a detail line shows only on failure and this is the
	# figure every future question about this map is really about.
	print(
		"        the plunge: %.1f m/s top speed, %d airborne ticks of %d, "
		% [top_speed, airborne, ticks + 1]
		+ "finished %s" % ("yes" if finished[0] else "no")
	)

	_check(
		top_speed > 20.0,
		"the face makes the player fast, which the main run's ramps never do",
		"%.1f m/s" % top_speed
	)
	_check(
		splits == [1, 2],
		"it crosses both splits, in order",
		str(splits)
	)
	_check(
		finished[0],
		"and reaches the finish holding nothing but forward",
		"gave up at tick %d, z = %.1f, y = %.1f"
			% [ticks, player.global_position.z, player.global_position.y]
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


# --- The client -------------------------------------------------------------

## A real `PlaygroundClient` boots and ends up with a player, a camera and a menu.
##
## [b]The one path in this project no other test touches, and it broke silently.[/b]
## Everything above drives `Playground` directly, because that is the half that runs
## headless — so the client's own boot sequence was covered by nothing, and when it
## started waiting for a signal that had already been emitted it simply stopped
## halfway through `_ready`. No error, no failed load, nothing in the log: a black
## screen with a `Playground` ticking behind it. Only a screenshot showed it.
##
## `change_map` completes without ever suspending when the map is a scene already in
## the build, which is every map here — so this test exercises exactly the case that
## broke. It would deadlock, not fail, without `booted` being checked before the
## await; the suite's own `timeout` is what turns that into a red run.
# --- Vehicles --------------------------------------------------------------

## A car spawned from the prop catalogue, driven, ridden in and got out of.
##
## [b]The whole point of this test is that a vehicle here is BOTH things at once.[/b]
## dot-vehicle's own 122 checks drive real bodies through real physics, and every one of
## them spawns through [method DotVehicleSpawner.spawn] into a world with nothing else in
## it. What has never run anywhere is a vehicle that is also a [DotPropInstance] — on a
## prop budget, on an undo stack, adopted rather than spawned, with its wheels built by
## the game after the body was created by somebody else.
func _test_vehicles() -> void:
	_section("vehicles")

	var changed: DotResult = await playground.change_map(&"pg_lobby")
	_check(changed.ok, "the sandbox loads")

	# The sandbox test above lets its player leave, so this one brings the bot back.
	var driver := playground.add_player(&"bot", "Bot")
	playground.props.limits.spawn_interval = 0.0

	# The corner of the plate opposite the jump course and the tower, which is the one
	# part of this map that is flat and empty for sixty metres in every direction. A car
	# is not a player: it covers the width of the sandbox in a few seconds, and the first
	# version of this test drove into the scenery and measured a stationary car.
	var at := Vector3(-60.0, 1.2, -60.0)
	driver.teleport(at + Vector3(2.5, 0.0, 0.0), 0.0)

	var spawned := playground.props.spawn(&"buggy", &"bot", at)

	_check(spawned != null, "a buggy spawns out of the PROP catalogue")

	if spawned == null:
		return

	_check(
		PlaygroundSpawnables.kind_of(spawned.def) == PlaygroundSpawnables.Kind.VEHICLE,
		"and the catalogue says it is a vehicle"
	)

	var vehicle := playground.vehicles.vehicle_for_node(spawned.node)

	_check(vehicle != null, "and it was adopted by the vehicle spawner")

	if vehicle == null:
		return

	_check(vehicle.chassis is DotVehicleWheeled, "with Godot's raycast wheels under it")

	var body := spawned.node as PlaygroundVehicle
	_check(body != null and body.wheel_count() == 4, "and four wheels actually built")
	_check(
		body != null and is_equal_approx(body.mass, vehicle.def.tuning().mass),
		"and one mass, read off the tunables by both catalogues",
		"%.1f vs %.1f" % [
			body.mass if body != null else -1.0, vehicle.def.tuning().mass
		]
	)

	# Let it settle onto its suspension before anything is measured. A raycast vehicle
	# spawned in the air is falling, and a "did it drive forward" measured through the
	# drop is measuring the drop.
	for _i in range(40):
		await get_tree().physics_frame

	_check(
		playground.use_vehicle(&"bot").ok,
		"the bot standing beside it gets in"
	)
	_check(driver.riding, "and stops being a player who walks")
	_check(vehicle.driver() == &"bot", "in the driving seat")
	_check(
		driver.get_parent() != playground and driver.is_inside_tree(),
		"with the rider's node carried by the vehicle",
		"which is what puts a rider's camera on it without a line about cameras"
	)

	# Forward. `move.y` is forward for a walking player and it is forward here.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)

	var before := vehicle.position()
	await _drive(&"bot", forward, 200)

	var travelled := vehicle.position() - before

	_check(travelled.length() > 4.0, "it drives", "%.2f m" % travelled.length())
	_check(
		vehicle.forward_speed() > 0.5,
		"FORWARDS, which is the one dot-vehicle says a car gets wrong",
		"%.2f m/s along its own -Z" % vehicle.forward_speed()
	)
	_check(
		driver.controller.state.position.distance_to(vehicle.position()) < 4.0,
		"and the driver's replicated position went with it",
		"a passenger drawn where they got in is invisible in one process"
	)

	# Steering. Both directions, because a check that only measured "it turned" would
	# pass for a car that turns the wrong way — which is exactly the bug dot-vehicle
	# found in itself.
	var right := DotFpsCommand.new()
	right.move = Vector2(1.0, 1.0)

	var heading_before := -(vehicle.node as Node3D).global_basis.z
	await _drive(&"bot", right, 160)
	var heading_after := -(vehicle.node as Node3D).global_basis.z

	# Positive Y in a cross product of before × after means the turn was to the LEFT in
	# Godot's left-handed-looking convention, so a right turn is negative.
	var turn := heading_before.cross(heading_after).y

	_check(turn < -0.05, "steering right turns it right", "cross.y = %.3f" % turn)

	# A passenger, which is the case that only breaks with two people in it.
	var passenger := playground.add_player(&"rider", "Rider")
	passenger.teleport(vehicle.position() + Vector3(0.0, 0.0, 4.0))

	_check(
		playground.vehicles.ride.enter(vehicle, &"rider", passenger).ok,
		"a second player gets in as a passenger"
	)
	_check(vehicle.occupant_count() == 2, "and the car has two people in it")
	_check(vehicle.driver() == &"bot", "with the driver unchanged")

	var passenger_before := passenger.controller.state.position
	await _drive(&"bot", forward, 120)

	_check(
		passenger.controller.state.position.distance_to(passenger_before) > 1.0,
		"the passenger is carried too",
		"%.2f m" % passenger.controller.state.position.distance_to(passenger_before)
	)

	# Getting out, which is the half dot-vehicle says the bugs are in.
	#
	# Asserted on the SPEED first. A refusal test run against a car that happens to be
	# stationary passes without testing anything, which is how the first version of this
	# read: "not ok, or slow enough" is true for a car nobody managed to move.
	# Put back on a clean patch and pointed down the plate before anything about SPEED is
	# measured. Not tidiness: everything up to here has been steering it, and a test that
	# measures a speed at the end of a drive it did not control is a test that measures
	# whatever it happened to hit.
	(vehicle.node as Node3D).global_transform = Transform3D(Basis.IDENTITY, at)
	vehicle.body().linear_velocity = Vector3.ZERO
	vehicle.body().angular_velocity = Vector3.ZERO

	for _i in range(30):
		await get_tree().physics_frame

	await _drive(&"bot", forward, 220)

	_check(
		vehicle.speed() > vehicle.def.tuning().max_exit_speed,
		"the car is going fast enough for the exit rule to have something to say",
		"%.2f m/s vs %.1f" % [vehicle.speed(), vehicle.def.tuning().max_exit_speed]
	)

	var moving := playground.vehicles.ride.exit(vehicle, &"rider")
	_check(
		not moving.ok,
		"and getting out at that speed is refused",
		"speed %.1f, limit %.1f" % [vehicle.speed(), vehicle.def.tuning().max_exit_speed]
	)

	var stop := DotFpsCommand.new()
	stop.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	await _drive(&"bot", stop, 200)

	_check(vehicle.speed() < 2.0, "the brake stops it", "%.2f m/s" % vehicle.speed())

	var out := playground.vehicles.ride.exit(vehicle, &"rider")
	_check(out.ok, "and then the passenger can get out", str(out.error) if not out.ok else "")
	_check(not passenger.riding, "and is walking again")
	_check(
		passenger.global_position.distance_to(vehicle.position()) > 0.9,
		"put down beside the car rather than inside it",
		"%.2f m" % passenger.global_position.distance_to(vehicle.position())
	)
	_check(
		passenger.get_parent() == playground,
		"and handed back to whoever had them before"
	)

	# How far it takes to stop, which "the brake stops it" never said. dot-vehicle handed
	# Godot's wheels the brake in newtons where Godot reads an impulse per physics step, so
	# the buggy stopped from 50 km/h within a couple of metres on either brake, at this
	# project's 128 ticks as at 60. Since dot-vehicle 4f4afaf they are forces.
	var foot := await _stopping(vehicle, at, &"bot", DotFpsCommand.BUTTON_CROUCH)
	var hand := await _stopping(vehicle, at, &"bot", DotFpsCommand.BUTTON_JUMP)
	print("  ..    the buggy from 50 km/h: brake (crouch) %.2f m, handbrake (jump) %.2f m" % [foot, hand])
	_check(foot > 7.0 and foot < 14.0, "the brake stops the buggy from 50 km/h in metres, not on the spot",
		"%.2f m" % foot)
	_check(hand > 6.8 and hand < 16.0, "and so does the handbrake", "%.2f m" % hand)
	# S: the brake while the buggy still rolls forward, reverse once it has stopped
	# (dot-vehicle's `brake_then_reverse`). On reverse thrust alone it was the engine's 35 %
	# against a brake several times that.
	var back := await _stopping(vehicle, at, &"bot", BACK_KEY)
	var reverse := DotFpsCommand.new()
	reverse.move = Vector2(0.0, -1.0)
	var stopped_at := vehicle.position()
	await _drive(&"bot", reverse, 192)
	var heading := -(vehicle.node as Node3D).global_transform.basis.z
	var backed := -(vehicle.position() - stopped_at).dot(heading)
	print("  ..    the buggy from 50 km/h on S: %.2f m to a stop, then %.2f m back at %.2f m/s after 1.5 s more" % [back, backed, vehicle.forward_speed()])
	_check(back < foot + 1.5, "S stops the buggy like the brake while it rolls forward, not on reverse thrust",
		"%.2f m against the brake's %.2f m" % [back, foot])
	_check(vehicle.forward_speed() < -1.0 and backed > 1.0, "and once it has stopped, S held reverses it",
		"%.2f m/s, %.2f m back" % [vehicle.forward_speed(), backed])
	# Stood still again, or it rolls away from the passenger put down beside it below.
	await _drive(&"bot", stop, 128)
	# Back beside the car, which those runs drove 60 m from where the passenger got out.
	passenger.teleport(vehicle.position() + Vector3(2.5, 0.0, 0.0))

	# The hovercraft, which is the only thing proving the chassis is a subclass point
	# rather than a promise.
	var skiff_prop := playground.props.spawn(&"skiff", &"bot", Vector3(-24.0, 1.5, 24.0))
	_check(skiff_prop != null, "a skiff spawns")

	if skiff_prop != null:
		var skiff := playground.vehicles.vehicle_for_node(skiff_prop.node)
		_check(skiff != null and skiff.chassis is DotVehicleHover, "on the hover chassis")
		_check(
			(skiff_prop.node as PlaygroundVehicle).wheel_count() == 0,
			"with no wheels built for it"
		)

		for _i in range(120):
			await get_tree().physics_frame

		_check(
			skiff != null and skiff.position().y > 0.55,
			"and it is still off the ground a second later",
			# Above its own half-height plus a margin: a skiff whose hover did nothing
			# would come to rest with its box on the floor at exactly 0.35.
			"y = %.2f" % (skiff.position().y if skiff != null else -1.0)
		)

	# Deleting the car with somebody in it. A rider left inside a freed vehicle is a
	# player parented to nothing: invisible, unkillable, and unable to enter anything
	# else for the rest of the round, with no error anywhere.
	_check(playground.use_vehicle(&"rider").ok, "the passenger gets back in")

	playground.props.remove(spawned.instance_id, DotPropSpawner.REASON_ADMIN)
	await get_tree().physics_frame

	_check(
		not playground.vehicles.ride.is_riding(&"rider")
		and not playground.vehicles.ride.is_riding(&"bot"),
		"removing the PROP evacuates everybody in the vehicle"
	)
	_check(not driver.riding, "and the driver is a walking player again")
	_check(
		playground.vehicles.world_count() == 1,
		"and the vehicle spawner has let go of it, leaving only the skiff",
		"%d left" % playground.vehicles.world_count()
	)

	playground.remove_player(&"rider")
	_done()



## [method _stopping]'s stand-in for a button: S held rather than a button pressed.
const BACK_KEY := -1


## Metres [param vehicle] takes from 50 km/h to a standstill, put back at [param at] facing
## +Z first, with [param button] held by [param id] (crouch the brake, jump the handbrake,
## [constant BACK_KEY] for S, which stops at the moment it stops rolling forward).
func _stopping(vehicle: DotVehicleInstance, at: Vector3, id: StringName, button: int) -> float:
	# Facing +Z, into the plate: -Z from here meets the plate's edge at about z = -72, which
	# a buggy reaching 50 km/h gets to first.
	(vehicle.node as Node3D).global_transform = Transform3D(Basis(Vector3.UP, PI), at)
	vehicle.body().linear_velocity = Vector3.ZERO
	vehicle.body().angular_velocity = Vector3.ZERO
	for _i in range(30):
		await get_tree().physics_frame

	var player: PlaygroundPlayer = playground.players[id]
	var go := DotFpsCommand.new()
	go.move = Vector2(0.0, 1.0)
	var guard := 1200
	while vehicle.forward_speed() < 13.89 and guard > 0:
		player.controller.apply_command(go.duplicate_command())
		await get_tree().physics_frame
		guard -= 1

	print("  ..    %s: %.1f m/s after %d ticks of throttle" % [{DotFpsCommand.BUTTON_CROUCH: "brake", BACK_KEY: "S"}.get(button, "handbrake"), vehicle.forward_speed(), 1200 - guard])
	var start := vehicle.position()
	var stop := DotFpsCommand.new()
	if button == BACK_KEY:
		stop.move = Vector2(0.0, -1.0)
	else:
		stop.set_button(button, true)
	guard = 1200
	while (vehicle.forward_speed() > 0.0 if button == BACK_KEY else vehicle.speed() > 0.3) and guard > 0:
		player.controller.apply_command(stop.duplicate_command())
		await get_tree().physics_frame
		guard -= 1

	var end := vehicle.position()
	return Vector2(end.x - start.x, end.z - start.z).length()


# --- The jump course -------------------------------------------------------

## `pg_lobby`'s bonus 1, driven from its start pad to its finish.
##
## [b]Nothing had ever run this course.[/b] Every check over it until now switched onto
## the track, looked at the spawn and switched back — which proves a player can be put
## at the bottom of it and nothing at all about whether they can get to the top. That is
## the whole of `[bonus-run-2]`, and the reason it is worth doing on this course in
## particular is that bonus 1 is the one route in this map a bot genuinely can run: it
## is a straight line, so the skill in it is timing rather than turning, and a bot
## holding forward that jumps at each leading edge is doing what a player does.
##
## The gaps are read off [PgLobby]'s own arithmetic rather than copied here, for the
## reason every map in this family says: a second description of where a platform is, is
## a second thing that can disagree with the geometry.
func _test_the_jump_course() -> void:
	print("")
	_section("the jump course — pg_lobby's bonus 1, run end to end")

	var loaded: DotResult = await playground.change_map(&"pg_lobby")
	_check(loaded.ok, "the lobby loads",
		loaded.error.message if not loaded.ok else "")

	var track := DotTimerTrack.BONUS_FIRST
	var zones := PgLobby.build_zones()

	var player := playground.add_player(&"bot", "Bot")

	# [b]The map's copy of the movement is the movement.[/b] `PgLobby` sizes its gaps
	# against three numbers it declares itself, because a map is content and cannot
	# reach into the game's player class — so the copy is deliberate and this is the
	# other half of that bargain. A course tuned against a jump height the server no
	# longer uses is a course that quietly stops being finishable, which is the exact
	# failure this section was written to find.
	var tunables := player.controller.tunables
	_check(
		is_equal_approx(tunables.max_speed, PgLobby.MOVE_SPEED)
			and is_equal_approx(tunables.jump_height, PgLobby.JUMP_HEIGHT)
			and is_equal_approx(tunables.gravity, PgLobby.MOVE_GRAVITY),
		"the map's movement constants are the ones the server applies",
		"map %.2f/%.2f/%.2f against %.2f/%.2f/%.2f"
			% [PgLobby.MOVE_SPEED, PgLobby.JUMP_HEIGHT, PgLobby.MOVE_GRAVITY,
				tunables.max_speed, tunables.jump_height, tunables.gravity]
	)

	# [b]And the rule the course lives under, which is the honest fix.[/b] Every gap
	# here has to be inside what the movement can actually cross while climbing
	# COURSE_RISE — measured off the map's own arithmetic, so re-tuning the ramp cannot
	# move the geometry past the rule. Before this course was driven the widest gap was
	# 5.65 m against a 3.68 m reach, and nothing anywhere said so: a zone set does not
	# know how far a player can jump, and every count over the course passed.
	var reach := PgLobby.jump_reach(PgLobby.COURSE_RISE)
	_check(
		PgLobby.widest_gap() <= reach,
		"no gap on the course is wider than a jump crosses while climbing a step",
		"widest %.2f m against a reach of %.2f m"
			% [PgLobby.widest_gap(), reach]
	)

	# And box to box, pad and finish pad included. `widest_gap` above reads the ramp
	# the platforms are placed by; this reads the platforms, so a pad resized or a
	# finish moved is asked about too.
	_check_route_reach(PgLobby.course_route(), "the jump course")

	_check(player.timer.set_track(track), "the course's track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on the start pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var splits: Array[int] = []

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true

	player.timer.run_started.connect(on_start)
	player.timer.stage_reached.connect(on_stage)
	player.timer.run_finished.connect(on_finish)

	var command := DotFpsCommand.new()
	command.move = Vector2(0.0, 1.0)
	command.yaw = spawn.destination_yaw

	# How far along it got, in platforms. Reported whether it finishes or not, because
	# "it fell off" is worth nothing as a result and "it fell off at the sixth gap"
	# names the gap.
	var reached := -1
	var ticks := 0
	var route := PgLobby.course_route()
	var length := _route_length(player.global_position, route)
	var tally := _motion_tally()
	var top_speed := 0.0
	var last_at := player.global_position

	# Capped above the ~1700 ticks the course takes at walking pace. It was 1200 while
	# the course was nine platforms and unfinishable, which is a cap that reports the
	# same failure as a bot stuck at a gap: at twelve platforms a bot on the last third
	# ran out of ticks rather than out of route.
	for i in range(2400):
		command.set_button(
			DotFpsCommand.BUTTON_JUMP, _jumping_on_the_course(player.global_position.z)
		)
		var where := "air"
		if player.controller.state.is_grounded():
			where = "else"
			for box in route:
				if _standing_on(last_at, box):
					where = "on"
		player.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame
		ticks = i
		_tally_tick(tally, last_at, player.global_position, where)
		last_at = player.global_position
		var now := player.controller.state.velocity
		top_speed = maxf(top_speed, Vector2(now.x, now.z).length())

		for step in range(PgLobby.COURSE_STEPS):
			var at := PgLobby.platform_centre(step)
			var over := (
				absf(player.global_position.x - at.x) < PgLobby.PLATFORM.x * 0.5
				and absf(player.global_position.z - at.z) < PgLobby.PLATFORM.z * 0.5
				and player.global_position.y >= at.y
			)
			if over and step > reached:
				reached = step

		if finished[0]:
			break

	player.timer.run_started.disconnect(on_start)
	player.timer.stage_reached.disconnect(on_stage)
	player.timer.run_finished.disconnect(on_finish)

	var pace := _print_pace(
		"the jump course", _tally_total(tally, "distance"), length, ticks + 1,
		PgLobby.MOVE_SPEED, top_speed
	)
	_check_pace("the jump course", _tally_total(tally, "distance"), length, pace, PgLobby.MOVE_SPEED, 0.85)
	_print_where("the jump course", "platforms", tally,
		route[route.size() - 1].end.y - route[0].end.y)
	_check_where("the jump course", "platforms", tally)

	_check(started[0], "leaving the start pad starts a run on the course")
	_check(
		reached >= 0,
		"the bot makes the first platform",
		"never got onto one"
	)
	_check(
		splits == [1, 2],
		"it crosses both splits, in order",
		str(splits)
	)
	_check(
		finished[0],
		"and reaches the finish pad: bonus 1 run end to end",
		"gave up at tick %d on platform %d of %d, z = %.1f, y = %.1f"
			% [ticks, reached, PgLobby.COURSE_STEPS - 1,
				player.global_position.z, player.global_position.y]
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


## Whether the bot should be holding jump at [param z] on the jump course.
##
## Pressed just before each leading edge and nowhere else. The course runs toward -Z, so
## the edge a player leaves from is the platform's near side in that direction, and the
## pad is eight metres deep where a platform is three — both are read off the map rather
## than written down again.
static func _jumping_on_the_course(z: float) -> bool:
	var edges: Array[float] = [PgLobby.COURSE_START_Z - PgLobby.PAD.z * 0.5]

	for i in range(PgLobby.COURSE_STEPS):
		edges.append(PgLobby.platform_centre(i).z - PgLobby.PLATFORM.z * 0.5)

	for edge in edges:
		if z <= edge + 0.7 and z > edge - 0.3:
			return true

	return false


# --- The switchback ---------------------------------------------------------

## `pg_bhop_intro`'s bonus 2, driven start to finish by a bot that turns.
##
## [b]The first route in this family built to be turned round and run by a bot.[/b] The
## narrows, the plunge and `the needle` in game-g2gfast are all straight, and each says
## so as a design decision: a bot that holds one yaw cannot run a route that turns. The
## tower on `pg_lobby` showed that was a limit of the bots rather than of routes, and
## this is the first route designed after that was known: three legs joined by two
## quarter turns, climbing 7 m, driven by [method _drive_route] reading the map's own
## [method PgBhopIntro.switchback_route].
##
## The zones are walked on this track by NAME rather than by trusting `problems()` —
## `[track-zone-1]`: a set complete for one track and partial for another passes a
## per-zone check while being a route nobody can finish.
func _test_the_switchback() -> void:
	print("")
	_section("the switchback — pg_bhop_intro's bonus 2, run end to end")

	var loaded: DotResult = await playground.change_map(&"pg_bhop_intro")
	_check(loaded.ok, "the bhop map loads",
		loaded.error.message if not loaded.ok else "")

	var track := PgBhopIntro.SWITCHBACK_TRACK
	var zones := PgBhopIntro.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
	}

	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 2},
		"bonus 2 has a start, a finish, a spawn, a respawn and two splits, on its own track",
		str(kinds)
	)
	_check(
		playground.tracks_on_this_map() == [
			DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST, track,
			PgBhopIntro.ASCENT_TRACK, PgBhopIntro.LADDER_TRACK, PgBhopIntro.FLOAT_TRACK,
			PgBhopIntro.DROP_TRACK,
		],
		"and the game sees seven tracks on the map without being told",
		str(playground.tracks_on_this_map())
	)

	var route := PgBhopIntro.switchback_route()
	_check_route_reach(route, "the switchback")

	var player := playground.add_player(&"bot", "Bot")

	_check(player.timer.set_track(track), "the switchback's track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	await _the_spawn_yaw_survives_a_tick(player, spawn)

	var first := route[1].get_center()
	var toward := Vector3(
		first.x - player.global_position.x, 0.0, first.z - player.global_position.z
	).normalized()
	_check(
		player.aim_direction().dot(toward) > 0.9,
		"facing the first block",
		"dot %.2f; yaw %.1f, the spawn says %.1f"
			% [player.aim_direction().dot(toward), player.controller.state.yaw,
				spawn.destination_yaw]
	)

	# Fourteen jumps at about a second each is ~1,800 ticks.
	var length := _route_length(player.global_position, route)
	var drive: Dictionary = await _drive_route(player, route, 4000)

	print("    the switchback: box %d of %d, splits %s, finish %s, %d ticks, %d respawns" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["respawns"]),
	])
	var pace := _print_pace(
		"the switchback", float(drive["distance"]), length, int(drive["ticks"]),
		PgLobby.MOVE_SPEED, float(drive["top_speed"])
	)
	_check_pace("the switchback", float(drive["distance"]), length, pace, PgLobby.MOVE_SPEED, 0.85)

	_check(drive["started"], "leaving the pad starts a run on bonus 2")
	_check(
		drive["splits"] == [1, 2],
		"it turns through both turning blocks' splits, in order",
		str(drive["splits"])
	)
	_check(
		drive["finished"],
		"and reaches the finish pad: the switchback run end to end",
		"got to box %d of %d at (%.1f, %.1f, %.1f) in %d ticks"
			% [int(drive["reached"]), route.size() - 1,
				player.global_position.x, player.global_position.y,
				player.global_position.z, int(drive["ticks"])]
	)
	_check(
		int(drive["respawns"]) == 0,
		"without once being put back on the pad",
		"%d respawns" % int(drive["respawns"])
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


# --- The ascent -------------------------------------------------------------

## `pg_bhop_intro`'s bonus 3, driven start to finish, walking every ramp.
##
## [b]The first route here a player cannot finish by jumping alone.[/b] Every crest is
## [constant PgBhopIntro.ASCENT_RAMP_RISE] above the block below it — over the jump apex —
## so the bot reaching the finish at all says each ramp was walked up; the per-ramp count
## of grounded ticks between block and crest says it was walked rather than bounced up.
## Until dot-player-controller's `[slope-1]` a slope under the limit read as airborne on
## its first tick, and this drive would stall at the foot of the first ramp.
##
## The geometry is also asked of the physics space rather than of the arithmetic alone: a
## ray down onto the middle of each ramp finds the height the map says, so a ramp built
## tilted the wrong way or dropped along the wrong axis — the plunge's 0.8 m lip — fails
## here before any bot does.
func _test_the_ascent() -> void:
	print("")
	_section("the ascent — pg_bhop_intro's bonus 3, jumped and walked end to end")

	var loaded: DotResult = await playground.change_map(&"pg_bhop_intro")
	_check(loaded.ok, "the bhop map loads",
		loaded.error.message if not loaded.ok else "")

	var track := PgBhopIntro.ASCENT_TRACK
	var zones := PgBhopIntro.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
	}

	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 3},
		"bonus 3 has a start, a finish, a spawn, a respawn and three splits, on its own track",
		str(kinds)
	)
	_check(
		zones.route_problems().is_empty(),
		"and every route on the map, this one included, is complete by route_problems()",
		", ".join(zones.route_problems())
	)

	var route := PgBhopIntro.ascent_route()
	var walks := PgBhopIntro.ascent_walks()
	_check_route_reach(route, "the ascent", walks)

	# The ramps, as slopes: walkable by the tunables the server applies, taller than a
	# jump, and actually where the arithmetic says in the physics space.
	var player := playground.add_player(&"bot", "Bot")
	var max_slope: float = player.controller.tunables.max_slope_angle
	var ramps := PgBhopIntro.ascent_ramps()
	var steepest := 0.0
	var shortest_rise := INF
	var worst_miss := 0.0
	var space := playground.get_world_3d().direct_space_state

	for i in range(ramps.size()):
		var ramp: Dictionary = ramps[i]
		var foot: Vector3 = ramp["foot"]
		var crest: Vector3 = ramp["crest"]
		steepest = maxf(steepest, float(ramp["pitch"]))
		shortest_rise = minf(shortest_rise, crest.y - foot.y)

		var middle := (foot + crest) * 0.5
		var query := PhysicsRayQueryParameters3D.create(
			middle + Vector3.UP * 5.0, middle + Vector3.DOWN * 5.0
		)
		var hit := space.intersect_ray(query)
		var miss: float = (
			absf((hit["position"] as Vector3).y - middle.y) if not hit.is_empty() else INF
		)
		worst_miss = maxf(worst_miss, miss)

	print("    the ascent: %d ramps, %.0f to %.0f degrees against a %.0f limit, each %.2f m up against a %.2f m apex" % [
		ramps.size(), float(ramps[0]["pitch"]), steepest, max_slope, shortest_rise,
		PgLobby.JUMP_HEIGHT,
	])

	_check(
		steepest < max_slope,
		"every ramp is walkable: the steepest is under the server's max_slope_angle",
		"%.1f against %.1f" % [steepest, max_slope]
	)
	_check(
		shortest_rise > PgLobby.JUMP_HEIGHT,
		"and every ramp climbs more than a jump can, so the only way up is to walk it",
		"%.2f m against a %.2f m apex" % [shortest_rise, PgLobby.JUMP_HEIGHT]
	)
	_check(
		worst_miss < 0.02,
		"and a ray onto the middle of each ramp finds the surface where the map says",
		"worst %.3f m off" % worst_miss
	)

	_check(player.timer.set_track(track), "the ascent's track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	await _the_spawn_yaw_survives_a_tick(player, spawn)

	# Five jumps and four ramps at about a second each; 3,000 leaves room.
	var length := _route_length(player.global_position, route)
	var drive: Dictionary = await _drive_route(player, route, 3000, 0.3, walks)
	var walked: Dictionary = drive["walked"]

	print("    the ascent: box %d of %d, splits %s, finish %s, %d ticks, %d respawns, ramp ticks %s" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["respawns"]),
		str(walked.values()),
	])
	var pace := _print_pace(
		"the ascent", float(drive["distance"]), length, int(drive["ticks"]),
		PgLobby.MOVE_SPEED, float(drive["top_speed"])
	)
	_check_pace("the ascent", float(drive["distance"]), length, pace, PgLobby.MOVE_SPEED, 0.8)

	_check(drive["started"], "leaving the pad starts a run on bonus 3")
	_check(
		drive["splits"] == [1, 2, 3],
		"it crosses the three crests' splits, in order",
		str(drive["splits"])
	)

	var every_ramp_walked := walked.size() == ramps.size()

	for i in walked:
		if int(walked[i]) < 5:
			every_ramp_walked = false

	_check(
		every_ramp_walked,
		"standing on every ramp on the way up rather than bouncing off it",
		"grounded ticks per ramp %s" % str(walked)
	)
	_check(
		drive["finished"],
		"and reaches the finish pad: the ascent run end to end",
		"got to box %d of %d at (%.1f, %.1f, %.1f) in %d ticks"
			% [int(drive["reached"]), route.size() - 1,
				player.global_position.x, player.global_position.y,
				player.global_position.z, int(drive["ticks"])]
	)
	_check(
		int(drive["respawns"]) == 0,
		"without once being put back on the pad",
		"%d respawns" % int(drive["respawns"])
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


## A spawn's yaw, read after the simulation has run rather than before it.
##
## [b]Every spawn-yaw check in this file used to read the yaw on the tick it was set,
## and that is the only tick it was ever true.[/b] `PlaygroundPlayer.teleport` wrote
## `controller.state.yaw` directly, and a command carries absolute view angles — so the
## next tick set it back to whatever the command said. A client's sampler had never been
## told and still faced where the mouse last left it; a bot with no command got the
## controller's starved-tick substitute, a fresh command facing yaw 0. Both are asked
## here, and both failed before the fix: this section's own "facing the first block"
## read `yaw 0.0, the spawn says 90.0` once the bot had been standing on a map for a
## while, and passed on a freshly-added one only because its controller had not started
## ticking yet.
# --- The cascade ------------------------------------------------------------

## `pg_surf_intro`'s bonus 2, driven start to finish.
##
## [b]The first route in this game that jumps DOWN.[/b] Every other bhop route climbs or
## stays level, so this is the first time `_check_route_reach` is asked about a jump
## whose reach is longer than a flat one, and the first time `_drive_route` lands from a
## fall. Every block is offset to the other side of the line, so every jump but the pad's
## and the finish's is a diagonal the bot has to face before taking.
func _test_the_cascade() -> void:
	print("")
	_section("the cascade — pg_surf_intro's bonus 2, jumped down end to end")

	var loaded: DotResult = await playground.change_map(&"pg_surf_intro")
	_check(loaded.ok, "the surf map loads",
		loaded.error.message if not loaded.ok else "")

	var track := PgSurfIntro.CASCADE_TRACK
	var zones := PgSurfIntro.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
	}

	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 2},
		"bonus 2 has a start, a finish, a spawn, a respawn and two splits, on its own track",
		str(kinds)
	)
	_check(
		playground.tracks_on_this_map() == [
			DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST, track, PgSurfIntro.BANK_TRACK,
			PgSurfIntro.TRANSFER_TRACK,
		],
		"and the game sees five tracks on the map without being told",
		str(playground.tracks_on_this_map())
	)

	var route := PgSurfIntro.cascade_route()
	_check_route_reach(route, "the cascade")

	# What makes it this route and not a fourth copy of the switchback: every jump
	# lands lower, and every jump between two blocks is across the line as well as
	# along it, so the bot cannot hold one yaw down it.
	var shape := PackedStringArray()
	for i in range(1, route.size()):
		if route[i].end.y >= route[i - 1].end.y:
			shape.append("#%d does not drop" % i)
		if i > 1 and i < route.size() - 1 \
				and absf(route[i].get_center().x - route[i - 1].get_center().x) < 1.0:
			shape.append("#%d does not turn" % i)
	_check(shape.is_empty(),
		"every jump drops, and every block-to-block jump is a diagonal",
		", ".join(shape))

	# The reset is under everything, or a fall onto nothing is a fall for ever.
	var reset := zones.first_of_kind(DotTimerZone.Kind.RESPAWN, track)
	var lowest := INF
	for box in route:
		lowest = minf(lowest, box.position.y)
	_check(
		reset.to.y < lowest,
		"and its reset is under the lowest block",
		"reset top %.2f, lowest block bottom %.2f" % [reset.to.y, lowest]
	)

	var player := playground.add_player(&"bot", "Bot")

	_check(player.timer.set_track(track), "the cascade's track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	await _the_spawn_yaw_survives_a_tick(player, spawn)

	var first := route[1].get_center()
	var toward := Vector3(
		first.x - player.global_position.x, 0.0, first.z - player.global_position.z
	).normalized()
	_check(
		player.aim_direction().dot(toward) > 0.9,
		"facing the first block",
		"dot %.2f; yaw %.1f, the spawn says %.1f"
			% [player.aim_direction().dot(toward), player.controller.state.yaw,
				spawn.destination_yaw]
	)

	# Eleven jumps at under a second each.
	var length := _route_length(player.global_position, route)
	var drive: Dictionary = await _drive_route(player, route, 3000)

	print("    the cascade: box %d of %d, splits %s, finish %s, %d ticks, %d respawns" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["respawns"]),
	])
	var pace := _print_pace(
		"the cascade", float(drive["distance"]), length, int(drive["ticks"]),
		PgLobby.MOVE_SPEED, float(drive["top_speed"])
	)
	_check_pace("the cascade", float(drive["distance"]), length, pace, PgLobby.MOVE_SPEED, 0.85)

	_check(drive["started"], "leaving the pad starts a run on bonus 2")
	_check(
		drive["splits"] == [1, 2],
		"it drops through both splits, in order",
		str(drive["splits"])
	)
	_check(
		drive["finished"],
		"and reaches the finish pad: the cascade run end to end",
		"got to box %d of %d at (%.1f, %.1f, %.1f) in %d ticks"
			% [int(drive["reached"]), route.size() - 1,
				player.global_position.x, player.global_position.y,
				player.global_position.z, int(drive["ticks"])]
	)
	_check(
		int(drive["respawns"]) == 0,
		"without once being put back on the pad",
		"%d respawns" % int(drive["respawns"])
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


## Bonus 3 on `pg_surf_intro`: a face banked past standing and pitched along its length,
## ridden from its pad to its finish by holding INTO it.
##
## [b]The bot holds right while it is below a line on the bank and lets go above it, and
## never touches forward.[/b] That is the one surf skill a scripted bot has (game-g2gfast's
## single bank is ridden the same way), and it is the whole skill this route asks: gravity
## pulls a rider toward the low lip on every tick and the pitch carries them down the bank.
## The line is the pad's centre, which the spawn stands on.
##
## What it decides: the rider stays on the bank to its far end, crosses both splits,
## lands in the finish and is never put back; it is faster than running, and the descent
## of the route came from the bank rather than from falling off it — `[surf-ramp-1]`'s
## question, which the main run fails, asserted here because this route exists to pass it.
func _test_the_long_bank() -> void:
	print("")
	_section("the long bank — pg_surf_intro's bonus 3, surfed by holding into it")

	var loaded: DotResult = await playground.change_map(&"pg_surf_intro")
	_check(loaded.ok, "the surf map loads",
		loaded.error.message if not loaded.ok else "")

	var track := PgSurfIntro.BANK_TRACK
	var zones := PgSurfIntro.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
	}
	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 2}
			and zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"bonus 3 has a start, a finish, a spawn, a respawn and two splits, on its own track",
		"%s %s" % [str(kinds), ", ".join(zones.route_problems())]
	)
	_check(
		playground.tracks_on_this_map() == [
			DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST, PgSurfIntro.CASCADE_TRACK, track,
			PgSurfIntro.TRANSFER_TRACK,
		],
		"and the game sees five tracks on the map without being told",
		str(playground.tracks_on_this_map())
	)
	var thin := zones.thin_zones(30.0, playground.tick_rate)
	_check(thin.is_empty(),
		"and no zone is thin enough for a rider at 30 m/s to cross without entering",
		"%d thin" % thin.size())

	var player := playground.add_player(&"bot", "Bot")

	# Surf, asked of the face rather than of the roll written down: the face's own slope,
	# with the pitch in it, against the slope the server lets a player stand on.
	var normal := PgSurfIntro.bank_normal()
	var slope := rad_to_deg(acos(normal.y))
	var max_slope: float = player.controller.tunables.max_slope_angle
	_check(
		slope > max_slope + 5.0,
		"the bank is steeper than a player can stand on, by more than five degrees",
		"%.1f° against %.0f°" % [slope, max_slope]
	)

	# And it falls along the route: what the main run's ramps do not do.
	var corners := PgSurfIntro.bank_corners()
	var near_mid := (corners[0] + corners[1]) * 0.5
	var far_mid := (corners[2] + corners[3]) * 0.5
	var bank_drop := near_mid.y - far_mid.y
	_check(
		bank_drop > 10.0 and far_mid.z < near_mid.z - 100.0,
		"and it falls along its length, so the bank is what makes a rider fast",
		"%.1f m down over %.1f m" % [bank_drop, near_mid.z - far_mid.z]
	)

	# The finish pad: past the far edge (a rider arriving does not hit its face) and under
	# it; and the reset under all of it.
	var finish_pad := PgSurfIntro.bank_finish()
	var far_z := PgSurfIntro.bank_far_z()
	_check(
		finish_pad.end.z < minf(corners[2].z, corners[3].z)
			and finish_pad.end.y < far_mid.y - 1.0,
		"the finish pad is beyond the bank's far edge and under it",
		"pad z %.1f..%.1f top %.1f; far edge z %.1f, middle %.1f"
			% [finish_pad.position.z, finish_pad.end.z, finish_pad.end.y, far_z, far_mid.y]
	)
	var reset := zones.first_of_kind(DotTimerZone.Kind.RESPAWN, track)
	var lowest := finish_pad.position.y
	for corner in corners:
		lowest = minf(lowest, corner.y - 1.0)
	_check(
		reset.to.y < lowest,
		"and its reset is under everything on the route",
		"reset top %.2f, lowest %.2f" % [reset.to.y, lowest]
	)

	_check(player.timer.set_track(track), "the long bank's track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)
	await _the_spawn_yaw_survives_a_tick(player, spawn)

	var ride: Dictionary = await _ride_the_bank(player, 3000)
	var tally: Dictionary = ride["tally"]
	var ticks := int(ride["ticks"])
	var length := spawn.destination.z - (finish_pad.end.z - 2.0)

	print("    the long bank: rode to z %.1f of %.1f, x %.1f..%.1f, splits %s, finish %s, %d ticks, %d respawns" % [
		float(ride["rode_to"]), far_z, float(ride["x_low"]), float(ride["x_high"]),
		str(ride["splits"]), str(ride["finished"]), ticks, int(ride["respawns"]),
	])
	var pace := _print_pace(
		"the long bank", _tally_total(tally, "distance"), length, ticks,
		PgSurfIntro.MOVE_SPEED, float(ride["top_speed"])
	)
	_print_where("the long bank", "the bank", tally, -bank_drop)

	_check(ride["started"], "dropping off the pad starts a run on bonus 3")
	_check(
		float(ride["rode_to"]) <= far_z + 2.0,
		"a bot holding into the bank rides it to its far end",
		"left it at z %.1f of %.1f" % [float(ride["rode_to"]), far_z]
	)
	# [fps-face-edge-stop]: leaving over the far END grazed the edge, and the motor used to
	# answer that graze by zeroing the velocity. "Rode to" cannot see it -- it stops at the
	# edge either way -- so ask the speed on each side of it.
	_check(
		float(ride["edge_speed"]) > 15.0
			and float(ride["past_speed"]) > 0.9 * float(ride["edge_speed"]),
		"and leaves over the far edge without losing its speed there",
		"%.1f m/s on the last tick over the bank, %.1f on the first past it" % [
			float(ride["edge_speed"]), float(ride["past_speed"])]
	)
	_check(ride["splits"] == [1, 2], "it crosses both splits, in order", str(ride["splits"]))
	_check(
		ride["finished"] and int(ride["respawns"]) == 0,
		"and lands in the finish without once being put back",
		"finished %s, %d respawns, at %s" % [
			str(ride["finished"]), int(ride["respawns"]), str(player.global_position.round()),
		]
	)
	_check_pace("the long bank", _tally_total(tally, "distance"), length, pace,
		PgSurfIntro.MOVE_SPEED, BANK_PACE_FLOOR)
	_check(
		float(ride["top_speed"]) > 20.0,
		"and the bank makes the rider fast, past 20 m/s",
		"%.1f m/s" % float(ride["top_speed"])
	)

	# `[surf-ramp-1]`, asserted: the descent between the pad and the far edge came from
	# riding the bank, not from falling. The drop to the finish pad is the air's.
	var on_descent := float((tally["on"] as Dictionary)["descent"])
	_check(
		on_descent >= bank_drop * 0.9,
		"most of the descent is on the bank, which is the whole reason this route exists",
		"%.1f m on the bank of a %.1f m bank" % [on_descent, bank_drop]
	)
	_check_where("the long bank", "bank", tally)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


## The long bank's pace floor, as a fraction of `MOVE_SPEED`: set under what the bot
## measured (see `_test_the_long_bank`). Over 1, because a surf route slower than running
## is not one.
const BANK_PACE_FLOOR := 2.0


## Rides [param player] from the bank's pad to its finish. Returns what happened and a
## `[surf-ramp-1]` tally of the run: "on" is the bank's face, "air" is airborne off it,
## "else" is anything grounded.
func _ride_the_bank(player: PlaygroundPlayer, max_ticks: int) -> Dictionary:
	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var splits: Array[int] = []
	var respawns: Array[int] = [0]

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true
	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == player.player_id and zone.kind == DotTimerZone.Kind.RESPAWN:
			respawns[0] += 1

	player.timer.run_started.connect(on_start)
	player.timer.stage_reached.connect(on_stage)
	player.timer.run_finished.connect(on_finish)
	playground.timers.effect_requested.connect(on_effect)

	var line := PgSurfIntro.BANK_PAD_X
	var near_z := PgSurfIntro.BANK_NEAR_Z
	var far_z := PgSurfIntro.bank_far_z()
	var tally := _motion_tally()
	var ticks := 0
	var top := 0.0
	var rode_to := INF
	# The speed on the last tick over the bank and the first tick past its far edge: a
	# rider that leaves at speed and one stopped dead on the edge both "ride to" it.
	var edge_speed := -1.0
	var past_speed := -1.0
	var x_low := INF
	var x_high := -INF
	var last := player.global_position

	for i in range(max_ticks):
		var at := player.global_position
		var on_bank := _on_the_bank(at)
		var command := DotFpsCommand.new()
		command.yaw = 0.0

		if player.controller.state.is_grounded() and not on_bank:
			command.move = Vector2(0.0, 1.0)
		else:
			command.move = Vector2(1.0 if at.x < line else 0.0, 0.0)

		player.controller.apply_command(command)
		await get_tree().physics_frame
		ticks = i + 1

		var now := player.global_position
		if started[0] and not finished[0]:
			var where := "on" if on_bank else (
				"else" if player.controller.state.is_grounded() else "air")
			_tally_tick(tally, last, now, where)
			top = maxf(top, player.speed())
		if _on_the_bank(now):
			rode_to = minf(rode_to, now.z)
			edge_speed = player.speed()
		elif past_speed < 0.0 and now.z < far_z and rode_to < INF:
			past_speed = player.speed()
			x_low = minf(x_low, now.x)
			x_high = maxf(x_high, now.x)
		last = now

		if finished[0] or respawns[0] > 0:
			break

	player.timer.run_started.disconnect(on_start)
	player.timer.stage_reached.disconnect(on_stage)
	player.timer.run_finished.disconnect(on_finish)
	playground.timers.effect_requested.disconnect(on_effect)

	# Let go of the stick: a bot keeps the last command it was given.
	player.controller.apply_command(DotFpsCommand.new())

	return {
		"started": started[0], "finished": finished[0], "splits": splits,
		"respawns": respawns[0], "ticks": ticks, "top_speed": top, "tally": tally,
		"rode_to": rode_to, "x_low": x_low, "x_high": x_high,
		"edge_speed": edge_speed, "past_speed": past_speed,
	}


## Whether feet at [param at] are on the bank's face: over it, and at most 0.8 m above
## it — a capsule resting on a 56-degree face stands its feet about 0.3 m off the plane.
static func _on_the_bank(at: Vector3) -> bool:
	var corners := PgSurfIntro.bank_corners()
	var low_x := minf(corners[0].x, corners[2].x)
	var high_x := maxf(corners[1].x, corners[3].x)
	if at.z > PgSurfIntro.BANK_NEAR_Z or at.z < PgSurfIntro.bank_far_z():
		return false
	if at.x < low_x or at.x > high_x:
		return false
	var above := at.y - PgSurfIntro.bank_surface_y(at.x, at.z)
	return above > -0.2 and above < 0.8


## Bonus 4 on pg_surf_intro, the transfer: two faces side by side facing each other across
## a gap, the second lower and starting a third of the way down the first.
##
## [b]Ridden by the long bank's rule, with the side switched for the jump.[/b] On the first
## face the bot holds right while it is below the riding line; [constant
## PgSurfIntro.TRANSFER_AT] metres into the second face's length it lets go and holds LEFT,
## off the first face's low lip and across; on the second it holds left while it is below
## that face's line (below is +X there). It never touches forward on either. Which hand it
## held on which face is asserted, because the switch is what this route asks for.
func _test_the_transfer() -> void:
	print("")
	_section("the transfer — pg_surf_intro's bonus 4, two faces facing each other across a gap")

	var loaded: DotResult = await playground.change_map(&"pg_surf_intro")
	_check(loaded.ok, "the surf map loads", loaded.error.message if not loaded.ok else "")

	var track := PgSurfIntro.TRANSFER_TRACK
	var zones := PgSurfIntro.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
	}
	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 2}
			and zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"bonus 4 has a start, a finish, a spawn, a respawn and two splits, on its own track",
		"%s %s" % [str(kinds), ", ".join(zones.route_problems())]
	)
	_check(
		playground.tracks_on_this_map() == [
			DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST, PgSurfIntro.CASCADE_TRACK,
			PgSurfIntro.BANK_TRACK, track,
		],
		"and the game sees five tracks on the map without being told",
		str(playground.tracks_on_this_map())
	)
	var thin := zones.thin_zones(30.0, playground.tick_rate)
	_check(thin.is_empty(),
		"and no zone is thin enough for a rider at 30 m/s to cross without entering",
		"%d thin" % thin.size())

	var player := playground.add_player(&"bot", "Bot")
	var max_slope: float = player.controller.tunables.max_slope_angle
	var n0 := PgSurfIntro.transfer_normal(0)
	var n1 := PgSurfIntro.transfer_normal(1)
	var slope0 := rad_to_deg(acos(n0.y))
	var slope1 := rad_to_deg(acos(n1.y))
	_check(
		slope0 > max_slope + 5.0 and slope1 > max_slope + 5.0,
		"both faces are steeper than a player can stand on, by more than five degrees",
		"%.1f° and %.1f° against %.0f°" % [slope0, slope1, max_slope]
	)
	_check(
		n0.x < -0.5 and n1.x > 0.5,
		"and they lean opposite ways: the first is high on the right, the second on the left",
		"normals %s and %s" % [str(n0), str(n1)]
	)

	var line0 := PgSurfIntro.transfer_line_x(0)
	var line1 := PgSurfIntro.transfer_line_x(1)
	var far0 := PgSurfIntro.transfer_far_z(0)
	var near1 := PgSurfIntro.transfer_near_centre(1).z
	var far1 := PgSurfIntro.transfer_far_z(1)
	var lip0 := PgSurfIntro.transfer_lip_x(0)
	var lip1 := PgSurfIntro.transfer_lip_x(1)
	var drop0 := PgSurfIntro.transfer_surface_y(0, line0, PgSurfIntro.TRANSFER_NEAR_Z) \
		- PgSurfIntro.transfer_surface_y(0, line0, far0)
	var drop1 := PgSurfIntro.transfer_surface_y(1, line1, near1) \
		- PgSurfIntro.transfer_surface_y(1, line1, far1)
	var under := PgSurfIntro.transfer_surface_y(0, lip0, near1) \
		- PgSurfIntro.transfer_surface_y(1, lip1, near1)
	_check(
		drop0 > 6.0 and drop1 > drop0 and far1 < far0 - 40.0,
		"each falls along its length, and the second, after the transfer, falls further and runs on past the first",
		"%.1f m then %.1f m; far edges z %.1f and %.1f" % [drop0, drop1, far0, far1]
	)
	_check(
		lip0 - lip1 >= 1.5 and under > 2.0 and near1 < 0.0 and near1 > far0 + 30.0,
		"the second face starts alongside the first, across a clear gap and under its low lip",
		"gap %.1f m, %.1f m under, starting at z %.1f" % [lip0 - lip1, under, near1]
	)

	var finish_pad := PgSurfIntro.transfer_finish()
	var c1 := PgSurfIntro.transfer_corners(1)
	_check(
		finish_pad.end.z < minf(c1[2].z, c1[3].z)
			and finish_pad.end.y < PgSurfIntro.transfer_surface_y(1, line1, far1) - 1.0,
		"the finish pad is beyond the second face's far edge and under it",
		"pad z %.1f..%.1f top %.1f" % [finish_pad.position.z, finish_pad.end.z, finish_pad.end.y]
	)
	var reset := zones.first_of_kind(DotTimerZone.Kind.RESPAWN, track)
	var lowest := finish_pad.position.y
	for face in range(2):
		for corner in PgSurfIntro.transfer_corners(face):
			lowest = minf(lowest, corner.y - 1.0)
	_check(reset.to.y < lowest, "and its reset is under everything on the route",
		"reset top %.2f, lowest %.2f" % [reset.to.y, lowest])

	_check(player.timer.set_track(track), "the transfer's track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame
	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)
	await _the_spawn_yaw_survives_a_tick(player, spawn)

	var ride: Dictionary = await _ride_the_transfer(player, 3000)
	var tally: Dictionary = ride["tally"]
	var ticks := int(ride["ticks"])
	var length := spawn.destination.z - (finish_pad.end.z - 2.0)
	var held: Dictionary = ride["held"]

	print("    the transfer: first face to z %.1f of %.1f, second to z %.1f of %.1f, held %s, splits %s, finish %s, %d ticks, %d respawns" % [
		float(ride["rode_to"][0]), far0, float(ride["rode_to"][1]), far1, str(held),
		str(ride["splits"]), str(ride["finished"]), ticks, int(ride["respawns"]),
	])
	var pace := _print_pace(
		"the transfer", _tally_total(tally, "distance"), length, ticks,
		PgSurfIntro.MOVE_SPEED, float(ride["top_speed"])
	)
	_print_where("the transfer", "the two faces", tally, -(drop0 + drop1))

	_check(ride["started"], "dropping off the pad starts a run on bonus 4")
	_check(
		float(ride["rode_to"][0]) < near1 - PgSurfIntro.TRANSFER_AT + 1.0
			and float(ride["rode_to"][1]) <= far1 + PgSurfIntro.TRANSFER_FINISH_LINE + 1.0,
		"a bot rides the first face past where the second begins, crosses, and rides the second to its end",
		"first to z %.1f, second to z %.1f of %.1f"
			% [float(ride["rode_to"][0]), float(ride["rode_to"][1]), far1]
	)
	_check(
		int(held["right_first"]) > 0 and int(held["left_second"]) > 0
			and int(held["right_second"]) == 0,
		"holding right on the first face and left on the second, never right on the second",
		str(held)
	)
	_check(ride["splits"] == [1, 2], "it crosses both splits, the gap first", str(ride["splits"]))
	_check(
		ride["finished"] and int(ride["respawns"]) == 0,
		"and lands in the finish without once being put back",
		"finished %s, %d respawns, at %s" % [
			str(ride["finished"]), int(ride["respawns"]), str(player.global_position.round()),
		]
	)
	_check_pace("the transfer", _tally_total(tally, "distance"), length, pace,
		PgSurfIntro.MOVE_SPEED, BANK_PACE_FLOOR)
	_check(
		float(ride["top_speed"]) > 20.0,
		"and the faces make the rider fast, past 20 m/s",
		"%.1f m/s" % float(ride["top_speed"])
	)
	# `[surf-ramp-1]`, asserted with the air this route is built to have: the transfer is a
	# fall of at least TRANSFER_DROP between the lips and the finish is TRANSFER_FINISH_DROP
	# under the far end, so the air's share is real here. More of the descent is still the
	# faces', and nothing is anything else's.
	var on_descent := float((tally["on"] as Dictionary)["descent"])
	var air_descent := float((tally["air"] as Dictionary)["descent"])
	_check(
		on_descent > air_descent and on_descent >= drop1,
		"more of the descent is ridden on the faces than fallen between them",
		"%.1f m on the faces, %.1f m in the air, the second face falls %.1f m"
			% [on_descent, air_descent, drop1]
	)
	_check_where("the transfer", "faces", tally)
	_check(not player.timer.run.is_active(), "and the run is over rather than still running")

	playground.remove_player(&"bot")
	_done()


## Rides [param player] from the transfer's pad to its finish: the long bank's rule on
## each face, with the side the face leans. Returns what happened, the `[surf-ramp-1]`
## tally ("on" is either face), the furthest Z reached on each face, and how many ticks
## it held each hand on each.
func _ride_the_transfer(player: PlaygroundPlayer, max_ticks: int) -> Dictionary:
	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var splits: Array[int] = []
	var respawns: Array[int] = [0]

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true
	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == player.player_id and zone.kind == DotTimerZone.Kind.RESPAWN:
			respawns[0] += 1

	player.timer.run_started.connect(on_start)
	player.timer.stage_reached.connect(on_stage)
	player.timer.run_finished.connect(on_finish)
	playground.timers.effect_requested.connect(on_effect)

	var line0 := PgSurfIntro.transfer_line_x(0)
	var line1 := PgSurfIntro.transfer_line_x(1)
	var lip0 := PgSurfIntro.transfer_lip_x(0)
	var let_go_z := PgSurfIntro.transfer_near_centre(1).z - PgSurfIntro.TRANSFER_AT
	var crossed := false
	var tally := _motion_tally()
	var ticks := 0
	var top := 0.0
	var rode_to := [INF, INF]
	var held := {"right_first": 0, "left_first": 0, "right_second": 0, "left_second": 0}
	var last := player.global_position

	for i in range(max_ticks):
		var at := player.global_position
		var face := _on_a_transfer_face(at)
		var command := DotFpsCommand.new()
		command.yaw = 0.0

		crossed = crossed or at.x < lip0 - 0.5
		if player.controller.state.is_grounded() and face < 0:
			command.move = Vector2(0.0, 1.0)
		elif crossed:
			command.move = Vector2(-1.0 if at.x > line1 else 0.0, 0.0)
		elif at.z > let_go_z:
			command.move = Vector2(1.0 if at.x < line0 else 0.0, 0.0)
		else:
			command.move = Vector2(-1.0, 0.0)

		if face >= 0 and command.move.x != 0.0:
			var key := ("right_" if command.move.x > 0.0 else "left_") \
				+ ("first" if face == 0 else "second")
			held[key] = int(held[key]) + 1

		player.controller.apply_command(command)
		await get_tree().physics_frame
		ticks = i + 1

		var now := player.global_position
		var face_now := _on_a_transfer_face(now)
		if started[0] and not finished[0]:
			var where := "on" if face_now >= 0 else (
				"else" if player.controller.state.is_grounded() else "air")
			_tally_tick(tally, last, now, where)
			top = maxf(top, player.speed())
		if face_now >= 0:
			rode_to[face_now] = minf(float(rode_to[face_now]), now.z)
		last = now

		if finished[0] or respawns[0] > 0:
			break

	player.timer.run_started.disconnect(on_start)
	player.timer.stage_reached.disconnect(on_stage)
	player.timer.run_finished.disconnect(on_finish)
	playground.timers.effect_requested.disconnect(on_effect)
	player.controller.apply_command(DotFpsCommand.new())

	return {
		"started": started[0], "finished": finished[0], "splits": splits,
		"respawns": respawns[0], "ticks": ticks, "top_speed": top, "tally": tally,
		"rode_to": rode_to, "held": held,
	}


## Which transfer face feet at [param at] are on (0 or 1), or -1: over it, and at most
## 0.8 m above it, as [method _on_the_bank].
static func _on_a_transfer_face(at: Vector3) -> int:
	for face in range(2):
		var c := PgSurfIntro.transfer_corners(face)
		var low_x := minf(minf(c[0].x, c[1].x), minf(c[2].x, c[3].x))
		var high_x := maxf(maxf(c[0].x, c[1].x), maxf(c[2].x, c[3].x))
		if at.z > PgSurfIntro.transfer_near_centre(face).z or at.z < PgSurfIntro.transfer_far_z(face):
			continue
		if at.x < low_x or at.x > high_x:
			continue
		var above := at.y - PgSurfIntro.transfer_surface_y(face, at.x, at.z)
		if above > -0.2 and above < 0.8:
			return face
	return -1


func _test_the_stepping_stones() -> void:
	print("")
	_section("the stepping stones — pg_lobby's bonus 4, landed stone by stone")

	var loaded: DotResult = await playground.change_map(&"pg_lobby")
	_check(loaded.ok, "the sandbox loads",
		loaded.error.message if not loaded.ok else "")

	var track := PgLobby.STONES_TRACK
	var zones := PgLobby.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
	}

	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 2},
		"bonus 4 has a start, a finish, a spawn, a respawn and two splits, on its own track",
		str(kinds)
	)
	_check(
		zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"and dot-timer finds nothing missing from any route on the map",
		", ".join(zones.route_problems())
	)

	var route := PgLobby.stones_route()
	_check_route_reach(route, "the stepping stones")

	# What makes it this course and not a fifth copy of the jump course: every stone is
	# narrower than the last, every stone-to-stone jump crosses the line, and a jump at
	# full running reach lands PAST every stone — so each one is a jump a player has to
	# take speed off in the air to land, which no other route here asks.
	var shape := PackedStringArray()
	var widest_margin := -INF
	for i in range(1, route.size()):
		var gap := PgLobby.gap_between(route[i - 1], route[i])
		var rise := route[i].end.y - route[i - 1].end.y
		var beyond := gap + route[i].size.x
		if i < route.size() - 1:
			widest_margin = maxf(widest_margin, beyond / PgLobby.jump_reach(rise))
		if i < route.size() - 1 and beyond >= PgLobby.jump_reach(rise):
			shape.append("#%d: %.2f m of air and stone against a %.2f m reach" % [
				i, beyond, PgLobby.jump_reach(rise)])
		if i > 1 and i < route.size() - 1:
			if route[i].size.x >= route[i - 1].size.x:
				shape.append("#%d is no narrower than #%d" % [i, i - 1])
			if absf(route[i].get_center().z - route[i - 1].get_center().z) < 1.0:
				shape.append("#%d does not cross the line" % i)
	print("    the stepping stones: stones %.2f m down to %.2f m; the far edge of a stone is at most %.0f%% of a running jump" % [
		route[1].size.x, route[route.size() - 2].size.x, widest_margin * 100.0,
	])
	_check(shape.is_empty(),
		"every stone is narrower than the last, across the line, and overshot flat out",
		", ".join(shape))

	var reset := zones.first_of_kind(DotTimerZone.Kind.RESPAWN, track)
	var lowest_top := INF
	for box in route:
		lowest_top = minf(lowest_top, box.end.y)
	_check(
		reset.from.y <= 0.0 and reset.to.y < lowest_top - 1.0,
		"and its reset is the air on the plate under it, well below every stone",
		"reset %.2f..%.2f, lowest top %.2f" % [reset.from.y, reset.to.y, lowest_top]
	)

	var player := playground.add_player(&"bot", "Bot")

	_check(player.timer.set_track(track), "the stepping stones' track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	await _the_spawn_yaw_survives_a_tick(player, spawn)

	var first := route[1].get_center()
	var toward := Vector3(
		first.x - player.global_position.x, 0.0, first.z - player.global_position.z
	).normalized()
	_check(
		player.aim_direction().dot(toward) > 0.9,
		"facing the first stone",
		"dot %.2f; yaw %.1f, the spawn says %.1f"
			% [player.aim_direction().dot(toward), player.controller.state.yaw,
				spawn.destination_yaw]
	)

	var length := _route_length(player.global_position, route)
	var drive: Dictionary = await _drive_route(player, route, 3000)

	print("    the stepping stones: box %d of %d, splits %s, finish %s, %d ticks, %d respawns" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["respawns"]),
	])
	var pace := _print_pace(
		"the stepping stones", float(drive["distance"]), length, int(drive["ticks"]),
		PgLobby.MOVE_SPEED, float(drive["top_speed"])
	)
	_check_pace("the stepping stones", float(drive["distance"]), length, pace, PgLobby.MOVE_SPEED, 0.7)
	_print_where("the stepping stones", "stones", drive["tally"], route[route.size() - 1].end.y - route[0].end.y)
	_check_where("the stepping stones", "stones", drive["tally"])

	_check(drive["started"], "leaving the pad starts a run on bonus 4")
	_check(
		drive["splits"] == [1, 2],
		"it lands through both splits, in order",
		str(drive["splits"])
	)
	_check(
		drive["finished"],
		"and reaches the finish pad: the stepping stones run end to end",
		"got to box %d of %d at (%.1f, %.1f, %.1f) in %d ticks"
			% [int(drive["reached"]), route.size() - 1,
				player.global_position.x, player.global_position.y,
				player.global_position.z, int(drive["ticks"])]
	)
	_check(
		int(drive["respawns"]) == 0,
		"without once being put back on the pad",
		"%d respawns" % int(drive["respawns"])
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


# --- The launch ---------------------------------------------------------------

## `pg_lobby`'s bonus 5, driven start to finish.
##
## [b]The one route here nobody can get round on their own legs[/b]: every deck is past a
## jump (3 m up, or 6 m out), and every one is inside the throw of the booster before it,
## a dot-timer PUSH zone that `PlaygroundPlayer` applies. So the checks are the two
## halves of that: the geometry says no gap is a jump and every gap is inside
## `PgLobby.launch_reach`, a booster's measured throw matches `launch_apex`, and a bot
## that never presses jump walks onto each booster and is carried deck to deck.
## Set just under what the drive measured; see `_check_pace`.
const LAUNCH_PACE_FLOOR := 0.85


func _test_the_launch() -> void:
	print("")
	_section("the launch — pg_lobby's bonus 5, thrown deck to deck by its boosters")

	var loaded: DotResult = await playground.change_map(&"pg_lobby")
	_check(loaded.ok, "the sandbox loads",
		loaded.error.message if not loaded.ok else "")

	var track := PgLobby.LAUNCH_TRACK
	var zones := PgLobby.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
		"push": zones.of_kind(DotTimerZone.Kind.PUSH, track).size(),
	}

	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 2, "push": 3},
		"bonus 5 has a start, a finish, a spawn, a respawn, two splits and three boosters, on its own track",
		str(kinds)
	)
	_check(
		zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"and dot-timer finds nothing missing from any route on the map",
		", ".join(zones.route_problems())
	)

	# The shape: no step is a jump, and every step is inside the throw with a metre of
	# deck to come down on.
	var route := PgLobby.launch_route()
	var shape := PackedStringArray()
	var widest := 0.0
	for i in range(1, route.size()):
		var gap := PgLobby.gap_between(route[i - 1], route[i])
		var rise := route[i].end.y - route[i - 1].end.y
		var reach := PgLobby.launch_reach(rise)
		widest = maxf(widest, (gap + 1.0) / reach)
		print("    the launch: #%d is %.2f m of air %.2f m up; a jump reaches %s, the booster %.2f m" % [
			i, gap, rise,
			"nothing" if rise > PgLobby.climb_limit() else "%.2f m" % PgLobby.jump_reach(rise),
			reach,
		])
		if rise <= PgLobby.climb_limit() and gap <= PgLobby.jump_reach(rise):
			shape.append("#%d can be jumped" % i)
		if gap + 1.0 > reach:
			shape.append("#%d: %.2f m + 1 against a %.2f m throw" % [i, gap, reach])
	_check(shape.is_empty(),
		"no deck can be jumped to, and every one is inside the booster's throw (tightest %.0f%%)" % (widest * 100.0),
		", ".join(shape))

	var pushes := zones.of_kind(DotTimerZone.Kind.PUSH, track)
	var standing := PackedStringArray()
	for i in range(pushes.size()):
		var push: DotTimerZone = pushes[i]
		var boost := PgLobby.launch_boost(i)
		if (
			absf(push.from.y - (boost.end.y - 0.5)) > 0.01
			or push.from.z != boost.position.z or push.to.z != boost.end.z
			or push.direction != Vector3(0.0, PgLobby.LAUNCH_BOOST_ACCEL, 0.0)
		):
			standing.append("#%d" % i)
	_check(standing.is_empty(), "each booster's push stands on it and throws straight up",
		", ".join(standing))

	var reset := zones.first_of_kind(DotTimerZone.Kind.RESPAWN, track)
	_check(
		reset.from.y <= 0.0 and reset.to.y < route[0].end.y - 0.5,
		"and its reset is the air on the plate under it, below every deck",
		"reset %.2f..%.2f, pad top %.2f" % [reset.from.y, reset.to.y, route[0].end.y]
	)

	var player := playground.add_player(&"bot", "Bot")

	_check(player.timer.set_track(track), "the launch's track switches")

	# A throw, measured: stood still in the middle of the first booster, hands off.
	var boost0 := PgLobby.launch_boost(0)
	player.teleport(boost0.get_center() + Vector3(0.0, boost0.size.y * 0.5 + 0.05, 0.0), 180.0)
	var base := boost0.end.y
	var apex := base
	var rising := false
	for tick in range(200):
		await get_tree().physics_frame
		var vy := player.controller.state.velocity.y
		apex = maxf(apex, player.global_position.y)
		if vy > 1.0:
			rising = true
		elif rising and vy < 0.0:
			break
	var thrown := apex - base
	print("    the launch: a booster throws a player standing on it %.2f m up; launch_apex says %.2f" % [
		thrown, PgLobby.launch_apex()])
	_check(
		absf(thrown - PgLobby.launch_apex()) < PgLobby.launch_apex() * 0.15,
		"a booster throws a player standing on it as high as launch_apex says",
		"%.2f m against %.2f" % [thrown, PgLobby.launch_apex()]
	)

	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	await _the_spawn_yaw_survives_a_tick(player, spawn)

	_check(
		player.aim_direction().dot(Vector3(0.0, 0.0, 1.0)) > 0.9,
		"facing up the line",
		"dot %.2f; yaw %.1f" % [player.aim_direction().dot(Vector3(0.0, 0.0, 1.0)),
			player.controller.state.yaw]
	)

	# Every box is walked: the bot never presses jump, and walks off each deck's end
	# through its booster.
	var walks: Array[int] = [0, 1, 2]
	var length := _route_length(player.global_position, route)
	var drive: Dictionary = await _drive_route(player, route, 3000, 0.3, walks)

	print("    the launch: box %d of %d, splits %s, finish %s, %d ticks, %d respawns" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["respawns"]),
	])
	var pace := _print_pace(
		"the launch", float(drive["distance"]), length, int(drive["ticks"]),
		PgLobby.MOVE_SPEED, float(drive["top_speed"])
	)
	_check_pace("the launch", float(drive["distance"]), length, pace, PgLobby.MOVE_SPEED, LAUNCH_PACE_FLOOR)
	_print_where("the launch", "decks", drive["tally"], route[route.size() - 1].end.y - route[0].end.y)
	_check_where("the launch", "decks", drive["tally"])

	_check(drive["started"], "leaving the pad starts a run on bonus 5")
	_check(
		drive["splits"] == [1, 2],
		"it is thrown through both splits, in order",
		str(drive["splits"])
	)
	_check(
		drive["finished"],
		"and onto the finish deck without once pressing jump: the launch runs end to end",
		"got to box %d of %d at (%.1f, %.1f, %.1f) in %d ticks"
			% [int(drive["reached"]), route.size() - 1,
				player.global_position.x, player.global_position.y,
				player.global_position.z, int(drive["ticks"])]
	)
	_check(
		int(drive["respawns"]) == 0,
		"without once being put back on the pad",
		"%d respawns" % int(drive["respawns"])
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


# --- The relay ----------------------------------------------------------------

## A relay drive's pace floor, as a fraction of `MOVE_SPEED`; see `_check_pace`. Measured
## 6.36 m/s (91%, the stops at the gates included), so the floor sits just under it.
const RELAY_PACE_FLOOR := 0.88


## `pg_lobby`'s bonus 6, driven start to finish.
##
## [b]Three legs joined by nothing but two gates[/b], dot-timer TELEPORT zones hanging past
## the end of a leg that put the player on the next one, stopped and turned round. So the
## checks are what makes that true: no jump joins two legs; each gate's destination is
## over the next pad, facing along a leg that runs the other way; a walk-off falls under a
## gate's sill and a jump goes through it; and a bot that faces the next box and jumps is
## put through both gates, both splits and the finish, counted teleport by teleport.
func _test_the_relay() -> void:
	print("")
	_section("the relay — pg_lobby's bonus 6, three legs joined only by two gates")

	var loaded: DotResult = await playground.change_map(&"pg_lobby")
	_check(loaded.ok, "the sandbox loads",
		loaded.error.message if not loaded.ok else "")

	var track := PgLobby.RELAY_TRACK
	var zones := PgLobby.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
		"teleport": zones.of_kind(DotTimerZone.Kind.TELEPORT, track).size(),
	}
	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 2, "teleport": 2}
			and zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"bonus 6 has a start, a finish, a spawn, a respawn, two splits and two gates, on its own track",
		"%s %s" % [str(kinds), ", ".join(zones.route_problems())]
	)

	# Every jump inside a leg (the jump into a gate included: a gate is a column level with
	# the deck before it) is inside the climbing reach. The step from a gate to the next
	# pad is skipped: it is not a jump, and the next check says it cannot be one.
	var route := PgLobby.relay_route()
	var gates := PgLobby.relay_gates()
	_check_route_reach(route, "the relay", gates)

	# What makes it this route: no deck of one leg can be jumped to from any deck of the
	# leg before it, so the gate is the only way on.
	var joined := PackedStringArray()
	var closest := INF
	for leg in range(1, PgLobby.RELAY_Z.size()):
		for a in PgLobby.relay_leg(leg - 1):
			for b in PgLobby.relay_leg(leg):
				var gap := PgLobby.gap_between(a, b)
				var rise := b.end.y - a.end.y
				closest = minf(closest, gap)
				if rise <= PgLobby.climb_limit() and gap <= PgLobby.jump_reach(rise):
					joined.append("leg %d to leg %d: %.2f m, %.2f m up" % [leg - 1, leg, gap, rise])
	print("    the relay: the legs are %.2f m of air apart at their closest, %.1f m up a leg; a jump reaches %.2f m on the level" % [
		closest, PgLobby.RELAY_BASE_Y[1] - PgLobby.RELAY_BASE_Y[0], PgLobby.jump_reach(0.0)])
	_check(joined.is_empty(), "no jump joins one leg to the next: only the gate does", ", ".join(joined))

	# Each gate: its zone fills the opening past the leg's last deck, and puts the player
	# over the next pad facing along a leg that runs the other way.
	var teleports := zones.of_kind(DotTimerZone.Kind.TELEPORT, track)
	var aimed := PackedStringArray()
	for i in range(teleports.size()):
		var zone: DotTimerZone = teleports[i]
		var leg_before := PgLobby.relay_leg(i)
		var opening := PgLobby.relay_gate_zone(leg_before[leg_before.size() - 1])
		var pad: AABB = PgLobby.relay_leg(i + 1)[0]
		var yaw := deg_to_rad(zone.destination_yaw)
		var facing := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var along := Vector3(PgLobby.relay_direction(i + 1), 0.0, 0.0)
		if (
			not zone.from.is_equal_approx(opening.position) or not zone.to.is_equal_approx(opening.end)
			or not _over(zone.destination, pad) or zone.destination.y <= pad.end.y
			or facing.dot(along) < 0.99
			or PgLobby.relay_direction(i + 1) == PgLobby.relay_direction(i)
		):
			aimed.append("gate %d: %s..%s to %s facing %.0f" % [
				i, str(zone.from), str(zone.to), str(zone.destination), zone.destination_yaw])
	_check(aimed.is_empty(),
		"each gate fills its opening and lands on the next pad, turned round to face along it",
		"; ".join(aimed))

	# A gate is jumped into: walking off the deck at full speed falls under the sill
	# before the gate, and a running jump is inside the opening there.
	var g := PgLobby.MOVE_GRAVITY
	var air := PgLobby.RELAY_GATE_GAP / PgLobby.MOVE_SPEED
	var walked_off := 0.5 * g * air * air
	var up := sqrt(2.0 * g * PgLobby.JUMP_HEIGHT)
	var jumped := up * air - 0.5 * g * air * air
	var far := (PgLobby.RELAY_GATE_GAP + PgLobby.RELAY_GATE_DEPTH) / PgLobby.MOVE_SPEED
	var jumped_far := up * far - 0.5 * g * far * far
	print("    the relay: at a gate a walk-off is %.2f m down (sill %.2f); a running jump %.2f m up, %.2f m at its far side (opening %.1f)" % [
		walked_off, PgLobby.RELAY_GATE_SILL, jumped, jumped_far, PgLobby.RELAY_GATE_HEIGHT])
	_check(
		walked_off > PgLobby.RELAY_GATE_SILL
			and jumped > -PgLobby.RELAY_GATE_SILL and jumped < PgLobby.RELAY_GATE_HEIGHT
			and jumped_far > -PgLobby.RELAY_GATE_SILL,
		"a gate is missed by walking off the deck and made by jumping at it",
		"walk-off %.2f m down; jump %.2f m, %.2f m" % [walked_off, jumped, jumped_far]
	)

	var reset := zones.first_of_kind(DotTimerZone.Kind.RESPAWN, track)
	var covered := true
	for box in route:
		if reset.to.y > PgLobby.RELAY_BASE_Y[0] - 0.5 or reset.from.x > box.position.x \
				or reset.to.x < box.end.x or reset.from.z > box.position.z \
				or reset.to.z < box.end.z:
			covered = false
	_check(covered, "and its reset is the air on the plate under all three legs, below every deck",
		"reset %s..%s" % [str(reset.from), str(reset.to)])

	var player := playground.add_player(&"bot", "Bot")
	_check(player.timer.set_track(track), "the relay's track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	await _the_spawn_yaw_survives_a_tick(player, spawn)

	# The route's length is the three legs' own, from where the bot is put on each.
	var length := 0.0
	for leg in range(PgLobby.RELAY_Z.size()):
		var from := player.global_position if leg == 0 else PgLobby.relay_arrival(leg)
		length += _route_length(from, PgLobby.relay_leg(leg))

	# A gate is part of the route: the run goes through it. Every other teleport here
	# stops the run (`PlaygroundPlayer.teleport`), which this route found.
	var stops: Array[String] = []
	var on_stop := func(_run: DotTimerRun, reason: StringName) -> void:
		stops.append("%s at %s" % [reason, str(player.global_position)])
	player.timer.run_stopped.connect(on_stop)
	var drive: Dictionary = await _drive_route(player, route, 4000, 0.3)
	player.timer.run_stopped.disconnect(on_stop)

	print("    the relay: box %d of %d, splits %s, finish %s, %d ticks, %d teleports, %d respawns" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["teleports"]),
		int(drive["respawns"]),
	])
	var pace := _print_pace(
		"the relay", float(drive["distance"]), length, int(drive["ticks"]),
		PgLobby.MOVE_SPEED, float(drive["top_speed"])
	)
	_check_pace("the relay", float(drive["distance"]), length, pace, PgLobby.MOVE_SPEED, RELAY_PACE_FLOOR)
	_print_where("the relay", "decks", drive["tally"],
		route[route.size() - 1].end.y - route[0].end.y)
	_check_where("the relay", "decks", drive["tally"])

	_check(drive["started"], "leaving the pad starts a run on bonus 6")
	_check(stops.is_empty(), "and nothing stops it on the way, the gates included", ", ".join(stops))
	_check(
		int(drive["teleports"]) == 2,
		"both gates put it on the next leg, and nothing else moved it",
		"%d teleports" % int(drive["teleports"])
	)
	_check(
		drive["splits"] == [1, 2],
		"it reaches both splits, each on the pad a gate lands on, in order",
		str(drive["splits"])
	)
	_check(
		drive["finished"],
		"and the finish: the relay runs end to end, through both gates",
		"got to box %d of %d at (%.1f, %.1f, %.1f) in %d ticks"
			% [int(drive["reached"]), route.size() - 1,
				player.global_position.x, player.global_position.y,
				player.global_position.z, int(drive["ticks"])]
	)
	_check(
		int(drive["respawns"]) == 0,
		"without once being put back on the pad",
		"%d respawns" % int(drive["respawns"])
	)
	_check(not player.timer.run.is_active(), "and the run is over rather than still running")

	playground.remove_player(&"bot")
	_done()


# --- The ladder ---------------------------------------------------------------

## `pg_bhop_intro`'s bonus 4, driven start to finish.
##
## [b]The route where every jump is as high as a jump is allowed to be.[/b] Eleven jumps,
## each [constant PgBhopIntro.LADDER_RISE] up, which is held here between 95% and 100% of
## `climb_limit()`: under it by the family's rule, and close enough to it that the route
## is the highest-climbing one on any map here rather than the jump course again. Its
## gaps are held at the other end too: each is longer than a full-speed jump covers while
## still under the next rung's top, so no gap is one a player meets the face of whatever
## they do.
##
## The drive prints the ground covered against the route's length and the pace against
## `MOVE_SPEED` (`[bot-drive-1]`), and asserts the pace: a bot that crawled up would
## finish too, and "it finished" alone would not say the gaps were jumps.
func _test_the_ladder() -> void:
	print("")
	_section("the ladder — pg_bhop_intro's bonus 4, eleven jumps each nearly as high as a jump")

	var loaded: DotResult = await playground.change_map(&"pg_bhop_intro")
	_check(loaded.ok, "the bhop map loads",
		loaded.error.message if not loaded.ok else "")

	var track := PgBhopIntro.LADDER_TRACK
	var zones := PgBhopIntro.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
	}

	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 2},
		"bonus 4 has a start, a finish, a spawn, a respawn and two splits, on its own track",
		str(kinds)
	)
	_check(
		zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"and dot-timer finds nothing missing from any route on the map",
		", ".join(zones.route_problems())
	)

	var route := PgBhopIntro.ladder_route()
	_check_route_reach(route, "the ladder")

	# What makes it this route: every rise within 5% of the climb limit, and every gap
	# longer than the ground a full-speed jump covers before its feet are over the next
	# top. The second is the ascending root of the same arithmetic `jump_reach` uses.
	var limit := PgLobby.climb_limit()
	var launch := sqrt(2.0 * PgLobby.MOVE_GRAVITY * PgLobby.JUMP_HEIGHT)
	var shape := PackedStringArray()
	var lowest := INF
	var shortest_margin := INF
	for i in range(1, route.size()):
		var gap := PgLobby.gap_between(route[i - 1], route[i])
		var rise := route[i].end.y - route[i - 1].end.y
		lowest = minf(lowest, rise)
		if rise < limit * 0.95 or rise > limit:
			shape.append("#%d climbs %.2f m" % [i, rise])
		var rising := (launch - sqrt(launch * launch - 2.0 * PgLobby.MOVE_GRAVITY * rise)) \
			/ PgLobby.MOVE_GRAVITY * PgLobby.MOVE_SPEED
		shortest_margin = minf(shortest_margin, gap - rising)
		if gap <= rising:
			shape.append("#%d is %.2f m of air, and a jump is under the top for %.2f m" % [
				i, gap, rising])
	print("    the ladder: %d jumps, each at least %.2f m up against a %.3f m climb limit; the shortest gap is %.2f m longer than a jump spends rising to the top" % [
		route.size() - 1, lowest, limit, shortest_margin,
	])
	_check(shape.is_empty(),
		"every jump climbs within 5% of the climb limit, over a gap longer than the climb",
		", ".join(shape))

	var reset := zones.first_of_kind(DotTimerZone.Kind.RESPAWN, track)
	var covered := true
	for box in route:
		if reset.to.y > box.position.y or reset.from.x > box.position.x \
				or reset.to.x < box.end.x or reset.from.z > box.position.z \
				or reset.to.z < box.end.z:
			covered = false
	_check(
		covered,
		"and its reset is under the foot of every column, the whole route long",
		"reset %s..%s" % [str(reset.from), str(reset.to)]
	)

	var player := playground.add_player(&"bot", "Bot")

	_check(player.timer.set_track(track), "the ladder's track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	await _the_spawn_yaw_survives_a_tick(player, spawn)

	# The route's length: spawn to the first rung's middle and middle to middle after,
	# along the ground. What a bot that took every jump straight covers.
	var length := _route_length(player.global_position, route)

	var drive: Dictionary = await _drive_route(player, route, 3000, 0.1)

	print("    the ladder: box %d of %d, splits %s, finish %s, %d ticks, %d respawns" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["respawns"]),
	])
	var pace := _print_pace(
		"the ladder", float(drive["distance"]), length, int(drive["ticks"]),
		PgLobby.MOVE_SPEED, float(drive["top_speed"])
	)

	_check(drive["started"], "leaving the pad starts a run on bonus 4")
	_check(
		drive["splits"] == [1, 2],
		"it climbs through both rungs' splits, in order",
		str(drive["splits"])
	)
	_check(
		drive["finished"],
		"and reaches the finish: the ladder run end to end",
		"got to box %d of %d at (%.1f, %.1f, %.1f) in %d ticks"
			% [int(drive["reached"]), route.size() - 1,
				player.global_position.x, player.global_position.y,
				player.global_position.z, int(drive["ticks"])]
	)
	_check(
		int(drive["respawns"]) == 0,
		"without once being put back on the pad",
		"%d respawns" % int(drive["respawns"])
	)
	_check(
		float(drive["distance"]) >= length * 0.95 and pace >= PgLobby.MOVE_SPEED * 0.6,
		"covering the route at a jumping pace, not a crawl",
		"%.1f m of %.1f at %.2f m/s" % [float(drive["distance"]), length, pace]
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


# --- The drop -----------------------------------------------------------------

## A drop drive's pace floor, as a fraction of `MOVE_SPEED`. Measured 6.81 m/s (97%), so the
## floor sits under it with room for a landing that costs a stride.
const DROP_PACE_FLOOR := 0.9


## `pg_bhop_intro`'s bonus 6, driven start to finish.
##
## [b]The ladder turned over.[/b] Eight jumps down a staircase of columns, each landing
## `DROP_STEP` lower, and every gap wider than a running jump on the level. So the shape
## check is a pair: every jump OUT of `jump_reach(0)` (the drop is what the route is made
## of) and every one inside `jump_reach(-DROP_STEP)` by `_check_route_reach`, which prints
## the tightest. Then the drive, which touches nothing but forward and jump, and its pace.
func _test_the_drop() -> void:
	print("")
	_section("the drop — pg_bhop_intro's bonus 6, eight jumps nobody makes on the level")

	var loaded: DotResult = await playground.change_map(&"pg_bhop_intro")
	_check(loaded.ok, "the bhop map loads",
		loaded.error.message if not loaded.ok else "")

	var track := PgBhopIntro.DROP_TRACK
	var zones := PgBhopIntro.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
	}

	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 2},
		"bonus 6 has a start, a finish, a spawn, a respawn and two splits, on its own track",
		str(kinds)
	)
	_check(
		zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"and dot-timer finds nothing missing from any route on the map",
		", ".join(zones.route_problems())
	)

	var route := PgBhopIntro.drop_route()
	_check_route_reach(route, "the drop")

	# What makes it this route: every jump lands DROP_STEP lower, over a gap no running
	# jump on the level crosses.
	var level := PgLobby.jump_reach(0.0)
	var shape := PackedStringArray()
	var narrowest := INF
	for i in range(1, route.size()):
		var gap := PgLobby.gap_between(route[i - 1], route[i])
		var fall := route[i - 1].end.y - route[i].end.y
		narrowest = minf(narrowest, gap)
		if not is_equal_approx(fall, PgBhopIntro.DROP_STEP):
			shape.append("#%d drops %.2f m" % [i, fall])
		if gap <= level:
			shape.append("#%d is %.2f m of air, which a level jump (%.2f) crosses" % [i, gap, level])
	print("    the drop: %d jumps, each %.1f m down; the narrowest gap is %.2f m against a %.2f m level jump, %.2f m with the drop" % [
		route.size() - 1, PgBhopIntro.DROP_STEP, narrowest, level,
		PgLobby.jump_reach(-PgBhopIntro.DROP_STEP),
	])
	_check(shape.is_empty(),
		"every jump drops the same height over a gap wider than any jump on the level",
		", ".join(shape))

	var reset := zones.first_of_kind(DotTimerZone.Kind.RESPAWN, track)
	var covered := true
	for box in route:
		if reset.to.y > box.position.y or reset.from.x > box.position.x \
				or reset.to.x < box.end.x or reset.from.z > box.position.z \
				or reset.to.z < box.end.z:
			covered = false
	_check(
		covered,
		"and its reset is under the foot of every column, the whole route long",
		"reset %s..%s" % [str(reset.from), str(reset.to)]
	)

	var player := playground.add_player(&"bot", "Bot")

	_check(player.timer.set_track(track), "the drop's track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	await _the_spawn_yaw_survives_a_tick(player, spawn)

	var length := _route_length(player.global_position, route)

	var drive: Dictionary = await _drive_route(player, route, 3000, 0.1)

	print("    the drop: box %d of %d, splits %s, finish %s, %d ticks, %d respawns" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["respawns"]),
	])
	var pace := _print_pace(
		"the drop", float(drive["distance"]), length, int(drive["ticks"]),
		PgLobby.MOVE_SPEED, float(drive["top_speed"])
	)

	_check(drive["started"], "leaving the pad starts a run on bonus 6")
	_check(
		drive["splits"] == [1, 2],
		"it drops through both columns' splits, in order",
		str(drive["splits"])
	)
	_check(
		drive["finished"],
		"and reaches the finish: the drop run end to end",
		"got to box %d of %d at (%.1f, %.1f, %.1f) in %d ticks"
			% [int(drive["reached"]), route.size() - 1,
				player.global_position.x, player.global_position.y,
				player.global_position.z, int(drive["ticks"])]
	)
	_check(
		int(drive["respawns"]) == 0,
		"without once being put back on the pad",
		"%d respawns" % int(drive["respawns"])
	)
	_check(
		float(drive["distance"]) >= length * 0.95
			and pace >= PgLobby.MOVE_SPEED * DROP_PACE_FLOOR,
		"covering the route at a running pace, not a crawl",
		"%.1f m of %.1f at %.2f m/s" % [float(drive["distance"]), length, pace]
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


# --- The float ----------------------------------------------------------------

## A float drive's pace floor, as a fraction of `MOVE_SPEED`. Measured 6.05 m/s (86%), so the
## floor sits just under it.
const FLOAT_PACE_FLOOR := 0.8


## `pg_bhop_intro`'s bonus 5, driven start to finish.
##
## [b]The route nobody can run on their own legs.[/b] Seven jumps, every one either wider
## than a running jump on the ground or a step higher than a jump's apex, inside one
## GRAVITY zone at `FLOAT_GRAVITY` that the game applies in the air. So the checks come in
## pairs: every jump is OUT of the ground's reach (the zone is what the route is made of),
## and every jump is INSIDE the float's reach with room to spare; and a bot standing on
## the pad and jumping once peaks where `float_apex` says, measured. Then the drive, which
## never touches anything but forward and jump, and its pace.
func _test_the_float() -> void:
	print("")
	_section("the float — pg_bhop_intro's bonus 5, seven jumps nobody can make outside its gravity")

	var loaded: DotResult = await playground.change_map(&"pg_bhop_intro")
	_check(loaded.ok, "the bhop map loads", loaded.error.message if not loaded.ok else "")

	var track := PgBhopIntro.FLOAT_TRACK
	var zones := PgBhopIntro.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
		"gravity": zones.of_kind(DotTimerZone.Kind.GRAVITY, track).size(),
	}
	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 2, "gravity": 1}
			and zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"bonus 5 has a start, a finish, a spawn, a respawn, two splits and a gravity zone, on its own track",
		"%s %s" % [str(kinds), ", ".join(zones.route_problems())]
	)

	var route := PgBhopIntro.float_route()
	var gravity := zones.first_of_kind(DotTimerZone.Kind.GRAVITY, track)
	_check(
		gravity != null and is_equal_approx(gravity.number, PgBhopIntro.FLOAT_GRAVITY),
		"its gravity zone carries the route's multiplier (%.1f)" % PgBhopIntro.FLOAT_GRAVITY
	)

	# Every jump, both ways: out of the ground's reach, inside the float's.
	var outside := PackedStringArray()
	var inside := PackedStringArray()
	var worst := 0.0
	var worst_at := -1
	var tallest := 0.0
	for i in range(1, route.size()):
		var gap := PgLobby.gap_between(route[i - 1], route[i])
		var rise := route[i].end.y - route[i - 1].end.y
		tallest = maxf(tallest, rise)
		var ground := PgLobby.jump_reach(rise) if rise <= PgLobby.climb_limit() else 0.0
		var floated := PgBhopIntro.float_reach(rise)
		print("    the float: #%d is %.2f m of air %.2f m up; on the ground a jump reaches %s, in the float %.2f m (%.0f%%)" % [
			i, gap, rise, ("%.2f m" % ground) if ground > 0.0 else "nothing", floated,
			gap / floated * 100.0 if floated > 0.0 else INF])
		if ground > 0.0 and gap <= ground:
			outside.append("#%d (%.2f m, a jump reaches %.2f)" % [i, gap, ground])
		if floated <= 0.0 or gap > floated * 0.9:
			inside.append("#%d (%.2f m of %.2f)" % [i, gap, floated])
		if floated > 0.0 and gap / floated > worst:
			worst = gap / floated
			worst_at = i
	_check(outside.is_empty(),
		"no jump on the float can be made on the ground: each is too far or too high",
		", ".join(outside))
	_check(inside.is_empty(),
		"and every one is inside 90%% of the float's reach (tightest #%d, %.0f%%)" % [worst_at, worst * 100.0],
		", ".join(inside))
	_check(
		tallest <= PgBhopIntro.float_apex() * DotFpsTunables.CLIMB_MARGIN,
		"and no step is a wall even in the float",
		"tallest %.2f m against %.2f" % [tallest, PgBhopIntro.float_apex() * DotFpsTunables.CLIMB_MARGIN]
	)

	var zone_box := AABB(gravity.from, gravity.to - gravity.from)
	var covered := true
	for box in route:
		var air := AABB(
			Vector3(box.position.x, box.end.y, box.position.z),
			Vector3(box.size.x, PgBhopIntro.float_apex(), box.size.z)
		)
		if not zone_box.encloses(air):
			covered = false
	var reset := zones.first_of_kind(DotTimerZone.Kind.RESPAWN, track)
	_check(
		covered and reset.to.y <= gravity.from.y,
		"the gravity zone covers every column and a full float jump over it, and the reset is under it",
		"zone %s..%s, reset top %.2f" % [str(gravity.from), str(gravity.to), reset.to.y]
	)

	var player := playground.add_player(&"bot", "Bot")
	_check(player.timer.set_track(track), "the float's track switches")

	# One jump, measured: stood still in the middle of the pad, jump pressed once.
	var pad: AABB = route[0]
	player.teleport(pad.get_center() + Vector3(0.0, pad.size.y * 0.5 + 0.05, 0.0), 0.0)
	for _i in range(32):
		player.controller.apply_command(DotFpsCommand.new())
		await get_tree().physics_frame
	var apex := player.controller.state.position.y
	var base := apex
	var airborne := 0
	var settled := player.controller.state.is_grounded()
	for tick in range(600):
		var command := DotFpsCommand.new()
		# Held until it leaves the ground: one press is on the tick the controller reads it.
		command.set_button(DotFpsCommand.BUTTON_JUMP, airborne == 0)
		player.controller.apply_command(command)
		await get_tree().physics_frame
		apex = maxf(apex, player.controller.state.position.y)
		if not player.controller.state.is_grounded():
			airborne += 1
		elif airborne > 2:
			break
	var seconds := float(airborne) / float(Engine.physics_ticks_per_second)
	print("    the float: a jump from the pad peaks %.2f m up (float_apex %.2f, the ground's %.2f) and lands %.2f s later" % [
		apex - base, PgBhopIntro.float_apex(), PgLobby.JUMP_HEIGHT, seconds])
	_check(
		settled and absf((apex - base) - PgBhopIntro.float_apex()) < PgBhopIntro.float_apex() * 0.1,
		"a jump in the float peaks where float_apex says",
		"%.2f m against %.2f" % [apex - base, PgBhopIntro.float_apex()]
	)

	playground.spawn_player(&"bot")
	await get_tree().physics_frame
	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and the spawn puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)
	await _the_spawn_yaw_survives_a_tick(player, spawn)

	var length := _route_length(player.global_position, route)
	var drive: Dictionary = await _drive_route(player, route, 4000, 0.1)
	print("    the float: box %d of %d, splits %s, finish %s, %d ticks, %d respawns" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["respawns"]),
	])
	var pace := _print_pace(
		"the float", float(drive["distance"]), length, int(drive["ticks"]),
		PgLobby.MOVE_SPEED, float(drive["top_speed"])
	)
	_print_where("the float", "columns", drive["tally"], route[route.size() - 1].end.y - route[0].end.y)

	_check(drive["started"], "leaving the pad starts a run on bonus 5")
	_check(drive["splits"] == [1, 2], "it floats through both splits, in order", str(drive["splits"]))
	_check(
		drive["finished"],
		"and reaches the finish: the float run end to end",
		"got to box %d of %d at %s in %d ticks" % [
			int(drive["reached"]), route.size() - 1, str(player.global_position), int(drive["ticks"])]
	)
	_check(int(drive["respawns"]) == 0, "without once being put back on the pad",
		"%d respawns" % int(drive["respawns"]))
	_check_pace("the float", float(drive["distance"]), length, pace, PgLobby.MOVE_SPEED, FLOAT_PACE_FLOOR)
	_check_where("the float", "columns", drive["tally"])
	_check(not player.timer.run.is_active(), "and the run is over rather than still running")

	playground.remove_player(&"bot")
	_done()


# --- The survey ---------------------------------------------------------------

## Every hand-built map, swept for closed slots, standable ground no spawn reaches, and
## ground a spawn reaches that leads nowhere (`[gate-sweep-2]`). `pg_generated` is not in
## it: it is not hand-built, and `PlaygroundWorldGen`'s own validator floods it from its
## spawn on every seed.
##
## [b]The survey is asked about a fixture first, so a sweep that finds nothing is known to
## be looking.[/b] Three maps passing clean says nothing about a detector that cannot fire;
## the fixture has one of each thing it looks for, and each is asserted found.
func _test_the_maps_are_surveyed() -> void:
	print("")
	_section("the hand-built maps, surveyed for slots, unreached ground and traps")

	_the_survey_sees_what_it_looks_for()

	for id in _zone_map_ids():
		var script := load("res://maps/%s.gd" % id) as GDScript
		var map: Node3D = script.new()
		map._build()

		# The map brings its light with it (`PlaygroundGeometry.light`): exactly one sun and
		# one environment, or the second is silently ignored by the renderer. dot-lighting's
		# shadowless `Fill` (painted()) is not a second sun.
		var suns := map.get_children().filter(func(n: Node) -> bool: return n is DirectionalLight3D and n.name != "Fill").size()
		var skies := map.get_children().filter(func(n: Node) -> bool: return n is WorldEnvironment).size()
		_check(suns == 1 and skies == 1, "%s: carries one sun and one sky (its dot-lighting document)" % id,
			"%d suns, %d environments" % [suns, skies])

		var zones: DotTimerZoneSet = script.build_zones()
		var spawns: Array[Vector3] = [map.fallback_spawn]
		for zone in zones.zones:
			# A TELEPORT's destination is a place a player is put, like a spawn: pg_lobby's
			# relay legs are joined by nothing else, which the survey (walks, drops, slides,
			# jumps) does not model.
			if zone.kind in [DotTimerZone.Kind.SPAWN, DotTimerZone.Kind.TELEPORT]:
				spawns.append(zone.destination)

		var declared: Array = map.survey_declared()
		var started := Time.get_ticks_msec()
		var found: Dictionary = PlaygroundMapSurvey.survey(map, zones, spawns, declared)
		map.free()

		print("    %s: %d standable cells in %d regions, %d spawns, %d declared, %d falls into nothing, %d ms" % [
			id, int(found["cells"]), int(found["regions"]), spawns.size(), declared.size(),
			int(found["void_falls"]), Time.get_ticks_msec() - started,
		])

		_check((found["spawnless"] as Array).is_empty(),
			"%s: every spawn stands on standable ground" % id,
			", ".join(found["spawnless"]))
		_check((found["slots"] as Array).is_empty(),
			"%s: no two boxes leave a slot narrower than a player" % id,
			"; ".join(found["slots"]))
		_check((found["unreached"] as Array).is_empty(),
			"%s: nothing standable is out of reach of every spawn, but what it declares" % id,
			"; ".join(found["unreached"]))
		_check((found["trapped"] as Array).is_empty(),
			"%s: and nowhere a spawn reaches is a place with no way out" % id,
			"; ".join(found["trapped"]))

	# The custom maps game-playground-maps delivers, linked in as `maps/custom`. Named rather
	# than listed off the directory, so a checkout without the link fails here instead of
	# surveying nothing and passing.
	var data_script := load("res://maps/pg_data.gd") as GDScript
	for id in CUSTOM_MAPS:
		var path := "res://maps/custom/%s.json" % id
		var map: Node3D = data_script.new()
		var configured: DotResult = map.configure_doc(path)
		_check(configured.ok, "%s: the document loads" % id, str(configured.error) if not configured.ok else "")
		var spawns: Array[Vector3] = [map.fallback_spawn]
		var declared: Array = map.survey_declared()
		var started := Time.get_ticks_msec()
		var found: Dictionary = PlaygroundMapSurvey.survey(map, DotTimerZoneSet.new(), spawns, declared)
		map.free()
		print("    %s: %d standable cells in %d regions, %d declared, %d falls into nothing, %d ms" % [
			id, int(found["cells"]), int(found["regions"]), declared.size(),
			int(found["void_falls"]), Time.get_ticks_msec() - started,
		])
		_check((found["spawnless"] as Array).is_empty(), "%s: the spawn stands on standable ground" % id,
			", ".join(found["spawnless"]))
		_check((found["slots"] as Array).is_empty(), "%s: no slot narrower than a player" % id,
			"; ".join(found["slots"]))
		_check((found["unreached"] as Array).is_empty(), "%s: nothing standable out of reach, but what it declares" % id,
			"; ".join(found["unreached"]))
		_check((found["trapped"] as Array).is_empty(), "%s: and no place with no way out" % id,
			"; ".join(found["trapped"]))

	_done()


# --- The collision audit ---------------------------------------------------------

## dot-core's [DotCollisionAudit] over every map as built: visible geometry with no shape
## under it, which a player walks through. The strict pass: every mesh sits on its own body here, and the lenient one
## would let a stray shape nearby cover a missing one. What is passable on purpose (liquids, foliage, panes, trigger
## visuals) carries `dot_no_collision` where the map builds it, with the reason there; a map
## fails on any finding left. Props are dot-props bodies and map toys are built under the
## playground, so neither is in a map node. The audit is structural and needs no tree.
func _test_nothing_drawn_is_walked_through() -> void:
	print("")
	_section("every map's drawn geometry has collision or says it is passable")

	var cases: Array = []
	for id in _zone_map_ids():
		cases.append([id, "res://maps/%s.gd" % id, ""])
	cases.append(["pg_generated", "res://maps/pg_generated.gd", "generated"])
	for id in CUSTOM_MAPS:
		cases.append([id, "res://maps/pg_data.gd", "res://maps/custom/%s.json" % id])

	for case: Array in cases:
		var map: Node3D = (load(case[1]) as GDScript).new()
		if case[2] == "generated":
			map.configure(1)
		elif case[2] != "":
			map.configure_doc(case[2])
		else:
			map._build()

		var res := DotCollisionAudit.audit(map)
		var found := 0
		if res.ok:
			var report: DotCollisionAudit = res.value
			found = report.count()
			print("    %s: %d findings of %d examined, %d opted out" % [case[0], found, report.examined, report.opted_out])
			for line in report.describe_lines().slice(1, 12):
				print("      %s" % line)
		_check(res.ok and found == 0 and (res.value as DotCollisionAudit).examined > 0,
			"%s: nothing drawn is walked through" % case[0],
			"" if res.ok else res.error.message)
		map.free()

	_done()


## A map document's `props` and `wires` (2026-10-07): put down by the server on load, owned
## by the map, furniture frozen and loose things loose, and the wires live.
func _test_a_maps_own_props() -> void:
	_section("a map's own props")

	var changed: DotResult = await playground.change_map(&"pgc_town")
	if not changed.ok:
		_check(false, "pgc_town loads", changed.error.message)
		_done()
		return
	await get_tree().physics_frame

	var mine := playground.props.props_of(playground.MAP_OWNER)
	var count := {}
	for p: DotPropInstance in mine:
		count[p.def.id] = int(count.get(p.def.id, 0)) + 1
	_check(int(count.get(&"door", 0)) == 5 and int(count.get(&"button", 0)) == 10 and int(count.get(&"buggy", 0)) == 2,
		"the map puts down its doors, buttons and cars", str(count))
	var doors := mine.filter(func(p: DotPropInstance) -> bool: return p.def.id == &"door")
	var crates := mine.filter(func(p: DotPropInstance) -> bool: return p.def.id == &"crate")
	_check(doors.all(func(p: DotPropInstance) -> bool: return p.frozen) and crates.all(func(p: DotPropInstance) -> bool: return not p.frozen),
		"furniture frozen, and the crates loose")

	# The first house's outside button opens its door, through the wire the document names.
	var buttons := mine.filter(func(p: DotPropInstance) -> bool: return p.def.id == &"button")
	var door: DotPropInstance = doors[0] if not doors.is_empty() else null
	var button: DotPropInstance = buttons[0] if not buttons.is_empty() else null
	if button != null:
		var _pressed: Variant = playground.io.fire(button.instance_id, &"pressed")
	for i in int(playground.DOOR_SECONDS * playground.tick_rate) + 16:
		await get_tree().physics_frame
	_check(door != null and playground.door_is_open(door.instance_id), "and a button opens the door it is wired to")
	var turned := rad_to_deg((door.node as Node3D).global_basis.x.angle_to(Vector3.RIGHT)) if door != null else 0.0
	_check(absf(turned - 90.0) < 3.0, "swinging a quarter turn from where the map stood it", "%.1f degrees" % turned)

	# A document that names a prop this server lacks still loads, without it.
	var entries := [{"id": "crate", "at": [0, 5, 0]}, {"id": "no_such_prop", "at": [2, 5, 0]}]
	var placed := playground.spawn_map_props(entries, [])
	_check(placed == 1, "and a prop the catalogue lacks is left out, not the map", "%d placed" % placed)

	var back: DotResult = await playground.change_map(&"pg_lobby")
	_check(back.ok and playground.props.props_of(playground.MAP_OWNER).is_empty(), "a map change takes its props with it")
	_done()


# --- Toys ------------------------------------------------------------------------

func _toy_index(id: String) -> int:
	if playground.toys == null:
		return -1
	for t in playground.toys.toys:
		if String(t.def["id"]) == id:
			return t.index
	return -1


## dot-props' toys on the sandbox, through the game's own paths: a walk pushes a ball, a shot
## from the hit scan sends one off, the use key kicks, a trampoline throws a player, the
## roundabout carries one standing on it, a grenade's blast throws a barrel, sv_toys 0 takes
## them away and a map change takes them with it.
func _test_toys() -> void:
	_section("the sandbox's toys")

	var on_lobby: DotResult = await playground.change_map(&"pg_lobby")
	if not on_lobby.ok or playground.toys == null:
		_check(false, "the sandbox loads with its toys", on_lobby.error.message if not on_lobby.ok else "no box")
		_done()
		return
	var box := playground.toys
	var lobby := playground.current_map_node()
	_check(box.count() == (lobby.call("map_toys") as Array).size() and box.count() >= 25 and box.missing.is_empty(),
		"the lobby builds every toy it lists", "%d toys" % box.count())

	var player := playground.add_player(&"toyer", "Toyer")
	await get_tree().physics_frame

	# Walked into: the beach ball goes on ahead of the player.
	var ball := box.toy(_toy_index("beach_ball"))
	var b0 := ball.body.global_position
	player.teleport(Vector3(b0.x - 1.2, 0.05, b0.z), -90.0)
	await get_tree().physics_frame
	for _i in range(16):
		player.controller.state.velocity = Vector3(6.0, 0.0, 0.0)
		await get_tree().physics_frame
	for _i in range(30):
		await get_tree().physics_frame
	_check(ball.body.global_position.x > b0.x + 0.5, "a player walking into the beach ball sends it on ahead",
		"moved %.2f m" % (ball.body.global_position.x - b0.x))

	# Shot through the game's own hit scan (player_shots_fired → PlaygroundZee.trace_outcome):
	# the second ball flies off, and nobody's prop shove sent it at forty metres a second.
	var other := box.toy(_toy_index("beach_ball") + 1)
	var o0 := other.body.global_position
	player.teleport(o0 + Vector3(0, 0, 5.0), 0.0)
	await get_tree().physics_frame
	var outcome := DotWeaponOutcome.new()
	outcome.used = true
	var shot := DotShot.new()
	shot.origin = o0 + Vector3(0, 0.1, 4.0)
	shot.direction = Vector3(0, 0, -1)
	shot.damage = 25.0
	shot.max_range = 50.0
	outcome.shots.append(shot)
	playground.player_shots_fired(&"toyer", outcome)
	var fastest := other.body.linear_velocity.length()
	for _i in range(20):
		await get_tree().physics_frame
		fastest = maxf(fastest, other.body.linear_velocity.length())
	_check(other.body.global_position.z < o0.z - 0.5 and fastest < 12.0, "a shot beach ball bounces away along the shot, at a ball's speed",
		"moved %.2f m, at most %.1f m/s" % [o0.z - other.body.global_position.z, fastest])

	# The use key on the football (the game's F, `use_prop`): kicked along the look.
	var football := box.toy(_toy_index("football"))
	var f0 := football.body.global_position
	player.teleport(f0 + Vector3(0, 0.05, 1.3), 0.0)
	# Down at the ball at the feet: the sign of pitch read off the aim, as the lever's is.
	await _look(&"toyer", 45.0, 4)
	var at_ball := rad_to_deg(atan2(player.eye_position().y - f0.y, player.eye_position().z - f0.z))
	await _look(&"toyer", -at_ball if player.aim_direction().y > 0.0 else at_ball, 4)
	var aimed := playground.toy_aimed(player)
	var used := playground.use_prop(&"toyer")
	for _i in range(20):
		await get_tree().physics_frame
	_check(aimed == football.index and used.ok and football.body.global_position.z < f0.z - 1.0,
		"the use key kicks the football the player looks at", "aimed %d, moved %.2f m; eye %s aim %s ball %s" % [aimed, f0.z - football.body.global_position.z, player.eye_position(), player.aim_direction(), f0])

	# A trampoline under a falling player throws them back up.
	var tramp := box.toy(_toy_index("trampoline"))
	player.teleport(tramp.global_position + Vector3(0.2, 1.4, 0.0), 0.0)
	var top := 0.0
	var bounced_before := tramp.count
	for _i in range(90):
		await get_tree().physics_frame
		top = maxf(top, player.controller.state.position.y - tramp.global_position.y)
	_check(top > 2.0 and tramp.count != bounced_before, "landing on the trampoline throws a player up, and counts the bounce",
		"%.2f m above it, count %d" % [top, tramp.count])

	# Somebody standing on the turning roundabout goes round with it.
	var spinner := box.toy(_toy_index("merry_go_round"))
	var hub := spinner.body.global_position
	var _spun := box.use(spinner.index, hub + Vector3(1.6, 1.0, 0), Vector3(0, 0, 1))
	player.teleport(hub + Vector3(1.0, 0.1, 0.0), 0.0)
	for _i in range(6):
		await get_tree().physics_frame
	var start := player.controller.state.position - hub
	var start_angle := atan2(start.z, start.x)
	for _i in range(40):
		await get_tree().physics_frame
	var now := player.controller.state.position - hub
	var turned := absf(wrapf(atan2(now.z, now.x) - start_angle, -PI, PI))
	var out := Vector2(now.x, now.z).length()
	_check(turned > 0.3 and absf(out - Vector2(start.x, start.z).length()) < 0.3 and player.controller.state.is_grounded(),
		"a player standing on the turning roundabout is carried round with it, still on the deck",
		"turned %.2f rad, %.2f m out" % [turned, out])

	# A grenade's blast (through the projectiles' own detonation, which hands toys to the box).
	var barrel := box.toy(_toy_index("barrel"))
	var r0 := barrel.body.global_position
	var thrown := playground.blast_toys(r0 + Vector3(-1.5, 0.2, 0.0), 5.0)
	for _i in range(20):
		await get_tree().physics_frame
	_check(thrown >= 1 and barrel.body.global_position.distance_to(r0) > 0.2, "a blast throws the barrels beside it",
		"%d thrown, %.2f m" % [thrown, barrel.body.global_position.distance_to(r0)])

	# sv_toys 0: nothing to hit, kick or stand on; 1 brings them back.
	var _off := playground.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "0")
	await get_tree().physics_frame
	var hidden := not ball.visible and playground.toy_aimed(player) == -1
	var _on := playground.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "1")
	_check(hidden and ball.visible, "sv_toys 0 takes the toys away and 1 puts them back")

	playground.remove_player(&"toyer")
	var away: DotResult = await playground.change_map(&"pg_surf_intro")
	await get_tree().process_frame
	_check(away.ok and playground.toys != null and playground.toys.count() == 0 and not is_instance_valid(ball),
		"a map with no toys has none, and the lobby's went with it",
		"%s, %s, ball %s" % [str(away.ok), str(playground.toys.describe()) if playground.toys != null else "no box", str(is_instance_valid(ball))])
	var _back: DotResult = await playground.change_map(&"pg_lobby")
	_done()


## Every map with toys, built: each toy one dot-props has, none inside the map's geometry or
## another toy's footprint, and two seconds of physics later every loose one still where the
## map put it (not through a floor, not flung off an overlap the solver pushed apart).
func _test_every_maps_toys_stand_clear() -> void:
	_section("every map's toys stand clear")
	var ids: Array[StringName] = []
	for def: DotMapDef in playground.maps.catalogue.maps:
		ids.append(def.id)
	var with_toys := 0
	var bad: Array = []
	for id: StringName in ids:
		if String(id).begins_with("pg_generated"):
			continue
		var changed: DotResult = await playground.change_map(id)
		if not changed.ok or playground.toys == null:
			continue
		var box := playground.toys
		var listed := playground.current_map_node().call("map_toys") as Array if playground.current_map_node().has_method("map_toys") else []
		if listed.is_empty():
			continue
		with_toys += 1
		if box.count() != listed.size() or not box.missing.is_empty():
			bad.append("%s: %d of %d built, missing %s" % [id, box.count(), listed.size(), ", ".join(box.missing)])
		var own: Array[RID] = []
		for toy in box.toys:
			for part: CollisionObject3D in [toy.fixed, toy.body]:
				if part != null:
					own.append(part.get_rid())
		var layout := playground.player_stack.physics.layout
		var space := playground.get_world_3d().direct_space_state
		for toy in box.toys:
			var hit := _toy_inside(space, toy, own, layout.mask_of([&"world", &"frozen_prop", &"prop"] as Array[StringName]))
			if hit != "":
				bad.append("%s: %s %d at %s inside %s" % [id, toy.def["id"], toy.index, toy.global_position.snapped(Vector3.ONE * 0.1), hit])
		# Footprints against each other, seen from above.
		for a in box.toys:
			for b in box.toys:
				if a.index >= b.index:
					continue
				var fa := _flat(a)
				var fb := _flat(b)
				if fa.size != Vector3.ZERO and fb.size != Vector3.ZERO and fa.grow(-0.05).intersects(fb.grow(-0.05)):
					bad.append("%s: %s %d and %s %d overlap" % [id, a.def["id"], a.index, b.def["id"], b.index])
		for _i in range(240):
			await get_tree().physics_frame
		for toy in box.toys:
			if toy.body != null and toy.body.global_position.distance_to(toy.rest.origin) > 0.6:
				bad.append("%s: %s %d strayed %s to %s" % [id, toy.def["id"], toy.index, toy.rest.origin.snapped(Vector3.ONE * 0.1), toy.body.global_position.snapped(Vector3.ONE * 0.1)])
	_check(with_toys >= 1 and bad.is_empty(), "every map's toys are dot-props', stand clear and stay put",
		"%d maps with toys; %s" % [with_toys, "; ".join(bad.slice(0, 8))])
	var _back: DotResult = await playground.change_map(&"pg_lobby")
	_done()


## [param toy]'s footprint in world space, flattened to the floor, or empty for a loose one.
static func _flat(toy: DotPropToy) -> AABB:
	var f := toy.footprint()
	if f.size == Vector3.ZERO:
		return AABB()
	var world := toy.global_transform * f
	world.position.y = 0.0
	world.size.y = 1.0
	return world


## What [param toy]'s own shapes, lifted five centimetres off their floor, are inside of, or "".
func _toy_inside(space: PhysicsDirectSpaceState3D, toy: DotPropToy, own: Array[RID], mask: int) -> String:
	for part: CollisionObject3D in [toy.fixed, toy.body]:
		if part == null:
			continue
		for child in part.get_children():
			var shape := child as CollisionShape3D
			if shape == null or shape.shape == null:
				continue
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = shape.shape
			query.transform = shape.global_transform.translated(Vector3(0, 0.05, 0))
			query.collision_mask = mask
			query.exclude = own
			var hits := space.intersect_shape(query, 1)
			if not hits.is_empty():
				var other: Object = hits[0].get("collider")
				return str(other.name) if other is Node else "something"
	return ""


## What a map box is made of, on the real game (pgc_nature): ice keeps a player sliding,
## mud slows them, rubber throws them higher, lava sends them back to the spawn and melts a
## crate, and water is a volume with nothing to stand on. Measured, and printed.
func _test_map_materials() -> void:
	_section("map materials: ice, mud, rubber, lava, water")

	var changed: DotResult = await playground.change_map(&"pgc_nature")
	if not changed.ok:
		_check(false, "pgc_nature loads", changed.error.message)
		_done()
		return
	playground.props.limits.spawn_interval = 0.0
	var bot: PlaygroundPlayer = playground.players.get(&"bot")
	if bot == null:
		bot = playground.add_player(&"bot", "Bot")

	# --- A box knows what it is made of ------------------------------------------------
	var ice_box: StaticBody3D = null
	var stack: Array[Node] = [playground.current_map_node()]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is StaticBody3D and PlaygroundMaterials.material_of(n) == &"ice":
			ice_box = n
	_check(ice_box != null and ice_box.get_meta(&"dot_fps_surface") == &"ice"
		and ice_box.physics_material_override != null and ice_box.physics_material_override.friction < 0.1,
		"an ice box is ice to a player's feet and to the solver")
	_check(not playground.liquids.is_empty() and playground.liquids.any(func(l: Dictionary) -> bool: return l["material"] == &"water")
		and playground.liquids.any(func(l: Dictionary) -> bool: return l["material"] == &"lava"),
		"the map's water and lava are liquid volumes", str(playground.liquids.size()))

	# --- Ice keeps its speed; grass takes it off ----------------------------------------
	var grass_kept: float = await _coast(bot, Vector3(-30.0, 1.0, 15.0))
	var ice_kept: float = await _coast(bot, Vector3(-55.0, 1.0, -41.0))
	print("    speed kept after 24 ticks with no input: grass %.0f%%, ice %.0f%%" % [grass_kept * 100.0, ice_kept * 100.0])
	_check(ice_kept > 0.6 and ice_kept > grass_kept * 2.0, "a player lets go on ice and keeps sliding; on grass they stop",
		"grass %.2f, ice %.2f" % [grass_kept, ice_kept])

	# --- Mud slows a run --------------------------------------------------------------
	var grass_top: float = await _top_speed(bot, Vector3(-30.0, 1.0, 15.0))
	var mud_top: float = await _top_speed(bot, Vector3(0.0, 1.0, -2.0))
	print("    top speed: grass %.2f m/s, mud %.2f m/s" % [grass_top, mud_top])
	_check(mud_top < grass_top * 0.8, "mud slows a running player", "grass %.2f, mud %.2f" % [grass_top, mud_top])

	# --- Rubber throws higher -----------------------------------------------------------
	var grass_jump: float = await _jump_height(bot, Vector3(-30.0, 1.0, 15.0))
	var rubber_jump: float = await _jump_height(bot, Vector3(-15.0, 1.3, 30.0))
	print("    jump height: grass %.2f m, rubber %.2f m" % [grass_jump, rubber_jump])
	_check(rubber_jump > grass_jump * 1.4, "a jump off rubber goes higher", "grass %.2f, rubber %.2f" % [grass_jump, rubber_jump])

	# --- Lava ---------------------------------------------------------------------------
	var spawn: Vector3 = playground.current_map_node().fallback_spawn
	bot.teleport(Vector3(-50.0, 0.3, 46.0), 0.0)
	await _drive(&"bot", DotFpsCommand.new(), 4)
	_check(bot.controller.state.position.distance_to(spawn) < 5.0, "walking into lava puts a player back at the spawn, with the arena off",
		str(bot.controller.state.position))
	# South of the rock bridge, which crosses the pit at z 50.
	var crate := playground.props.spawn(&"crate", &"bot", Vector3(-46.0, 1.5, 45.0))
	await _drive(&"bot", DotFpsCommand.new(), int(playground.tick_rate * 2.0))
	_check(crate != null and not crate.is_alive(), "and a crate that falls in melts")

	# --- Water is a volume, not a floor: a crate floats on it ------------------------------
	var floater := playground.props.spawn(&"crate", &"bot", Vector3(60.0, 3.0, 50.0))
	await _drive(&"bot", DotFpsCommand.new(), int(playground.tick_rate * 3.0))
	var settled: float = (floater.node as Node3D).global_position.y if floater != null and floater.is_alive() else INF
	var pond_top := 0.0
	for liquid: Dictionary in playground.liquids:
		var box: AABB = liquid["box"]
		if liquid["material"] == &"water" and box.has_point(Vector3(60.0, box.get_center().y, 50.0)):
			pond_top = box.end.y
	_check(absf(settled - (pond_top + 0.5)) < 0.3, "a crate dropped on the pond floats on it",
		"y %.2f, surface %.2f" % [settled, pond_top])

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var _back: DotResult = await playground.change_map(&"pg_lobby")
	_done()


## Runs [param player] north (-Z) from [param at] for a second, lets go, and returns the
## share of its speed it still has 24 ticks later.
func _coast(player: PlaygroundPlayer, at: Vector3) -> float:
	player.teleport(at, 0.0)
	await _drive(player.player_id, DotFpsCommand.new(), 16)
	var run := DotFpsCommand.new()
	run.move = Vector2(0.0, 1.0)
	await _drive(player.player_id, run, 128)
	var before := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
	await _drive(player.player_id, DotFpsCommand.new(), 24)
	var after := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
	return after / maxf(before, 0.001)


func _top_speed(player: PlaygroundPlayer, at: Vector3) -> float:
	player.teleport(at, 0.0)
	await _drive(player.player_id, DotFpsCommand.new(), 16)
	var run := DotFpsCommand.new()
	run.move = Vector2(0.0, 1.0)
	await _drive(player.player_id, run, 96)
	return Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()


func _jump_height(player: PlaygroundPlayer, at: Vector3) -> float:
	player.teleport(at, 0.0)
	# Long enough to land: a teleport puts a player in the air, and 24 ticks from a metre up
	# is still falling, which the first version measured as a jump of nothing.
	await _drive(player.player_id, DotFpsCommand.new(), 96)
	var floor_y := player.controller.state.position.y
	var top := floor_y
	var airborne := 0
	for i in 200:
		# Held until it leaves the ground: one press is read on the tick the controller reads it.
		var command := DotFpsCommand.new()
		command.set_button(DotFpsCommand.BUTTON_JUMP, airborne == 0)
		await _drive(player.player_id, command, 1)
		top = maxf(top, player.controller.state.position.y)
		if not player.controller.state.is_grounded():
			airborne += 1
		elif airborne > 2:
			break
	return top - floor_y


## Glass in a map breaks (pgc_nature's greenhouse): a real pistol through the game's shot
## handling, a blast, a crate thrown into it; not a crate nudged into it, not a player running
## alongside it, and nothing at all with `pg_breakable_glass` off. Shards fly and the
## signal every client's sound hangs off fires.
func _test_glass() -> void:
	_section("glass breaks")

	var changed: DotResult = await playground.change_map(&"pgc_nature")
	if not changed.ok:
		_check(false, "pgc_nature loads", changed.error.message)
		_done()
		return
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var player: PlaygroundPlayer = playground.players[&"bot"]

	var pane_at := func(centre: Vector3) -> int:
		for index: int in playground.panes.keys():
			var node := (playground.panes[index] as Dictionary)["node"] as Node3D
			if Playground._pane_bounds(node).get_center().distance_to(centre) < 1.0:
				return index
		return -1
	var glass_panes := playground.panes.values().filter(func(p: Dictionary) -> bool: return p["material"] == &"glass")
	_check(glass_panes.size() == 6, "the greenhouse's six glass boxes are breakable", str(glass_panes.size()))
	var west: int = pane_at.call(Vector3(-7.95, 1.75, 50.0))
	var east: int = pane_at.call(Vector3(7.95, 1.75, 50.0))
	var north: int = pane_at.call(Vector3(0.0, 1.75, 45.05))

	var heard: Array = []
	var on_broken := func(index: int, _at: Vector3, material: StringName) -> void: heard.append([index, material])
	playground.pane_broken.connect(on_broken)

	# --- Running alongside a pane at full speed is not running into it ---------------------
	# Starting past the north wall's end: the first version started south of it, ran into
	# that wall's edge at full speed, and broke it, which is right and was not the question.
	player.teleport(Vector3(8.6, 1.0, 45.8), 180.0)
	var facing_south := DotFpsCommand.new()
	facing_south.yaw = 180.0
	await _drive(&"bot", facing_south, 64)
	var run := DotFpsCommand.new()
	run.move = Vector2(0.0, 1.0)
	run.yaw = 180.0
	await _drive(&"bot", run, 100)
	_check(playground.panes.has(east) and heard.is_empty(), "a player running alongside a pane does not break it",
		"%.2f m/s, at %s" % [player.controller.state.velocity.length(), str(player.controller.state.position)])

	# --- Off, nothing breaks it -----------------------------------------------------------------
	player.teleport(Vector3(-14.0, 1.0, 50.0), -90.0)
	# Facing the pane while it settles: a command carries absolute angles, so an empty one
	# turns the bot to yaw 0, which put the first version's shots into the north wall.
	var facing_west_pane := DotFpsCommand.new()
	facing_west_pane.yaw = -90.0
	await _drive(&"bot", facing_west_pane, 64)
	var rig := PlaygroundZee.arm(player, playground.weapon_def(&"zee_pistol"), ZeeWeaponRig.Role.SERVER, true,
		playground.tick_rate, playground.current_tick())
	playground.panes_break = false
	var _off := _fire_at_crates(rig, player, 160)
	_check(playground.panes.has(west), "with pg_breakable_glass off, shots break no glass")
	playground.panes_break = true

	# --- A pistol breaks it ------------------------------------------------------------------------
	var before := playground.props.all_props().size()
	# One burst: the helper counts ticks itself, and calling it a tick at a time with no frame
	# between hands the rig the same tick each time, which fires once.
	var _shots := _fire_at_crates(rig, player, 240)
	PlaygroundZee.disarm(player)
	await get_tree().physics_frame
	var shards := playground.props.all_props().filter(func(p: DotPropInstance) -> bool: return p.def.id == &"debris")
	_check(not playground.panes.has(west) and playground.broken_panes.has(west), "a pistol shoots a pane out")
	_check(shards.size() >= 3 and playground.props.all_props().size() > before, "and it leaves shards", "%d shards" % shards.size())
	_check(heard.size() == 1 and heard[0][0] == west and heard[0][1] == &"glass", "and says so, once, for the sound", str(heard))
	await get_tree().physics_frame
	var through := playground.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
		Vector3(-14.0, 1.7, 50.0), Vector3(-2.0, 1.7, 50.0)))
	_check(through.is_empty() or not ((through["collider"] as Node).get_meta(&"pg_box", -1) == west),
		"and nothing is left where it stood")

	# --- A blast ---------------------------------------------------------------------------------
	var standing := playground.panes.has(north)
	playground.hurt_panes_in(Vector3(0.0, 1.75, 43.0), 4.0, 100.0, &"bot")
	_check(standing and not playground.panes.has(north), "a blast beside a pane breaks it")

	# --- A crate thrown into it, and one nudged into it -----------------------------------------------
	var nudged := playground.props.spawn(&"crate", &"bot", Vector3(10.5, 0.6, 52.0))
	await get_tree().physics_frame
	(nudged.node as RigidBody3D).linear_velocity = Vector3(-2.0, 0.0, 0.0)
	await _drive(&"bot", DotFpsCommand.new(), 128)
	_check(playground.panes.has(east), "a crate nudged into a pane leaves it standing")
	var thrown := playground.props.spawn(&"crate", &"bot", Vector3(11.0, 1.2, 48.0))
	await get_tree().physics_frame
	(thrown.node as RigidBody3D).linear_velocity = Vector3(-12.0, 0.0, 0.0)
	await _drive(&"bot", DotFpsCommand.new(), 64)
	_check(not playground.panes.has(east), "and one thrown into it breaks it")

	playground.pane_broken.disconnect(on_broken)
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var back: DotResult = await playground.change_map(&"pgc_nature")
	_check(back.ok and playground.panes.size() == 7 and playground.broken_panes.is_empty(), "a map change puts every pane back (the glass and the lake's ice)")
	var _lobby: DotResult = await playground.change_map(&"pg_lobby")
	_done()


## Water (pgc_harbour's basin): a player in it swims, floats with the head out, swims
## forward at swim speed; a crate and a barrel float, a boulder sinks to the bed.
func _test_water() -> void:
	_section("water: swimming and floating")

	var changed: DotResult = await playground.change_map(&"pgc_harbour")
	if not changed.ok:
		_check(false, "pgc_harbour loads", changed.error.message)
		_done()
		return
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var player: PlaygroundPlayer = playground.players[&"bot"]
	var boxes := playground.water_boxes()
	_check(boxes.size() == 1 and player.swim.volumes.size() == 1, "the basin is water, and the player is told", str(boxes))
	var surface: float = boxes[0].end.y if not boxes.is_empty() else 0.0

	# Into the basin, clear of the piers.
	player.teleport(Vector3(-70.0, -1.0, -60.0), 0.0)
	var idle := DotFpsCommand.new()
	await _drive(&"bot", idle, 384)
	var head := player.controller.state.position.y + player.swim.float_depth
	print("    floating: feet %.2f, head %.2f, surface %.2f" % [player.controller.state.position.y, head, surface])
	_check(player.controller.state.mode == player.swim.mode_id, "a player who falls in swims")
	_check(absf(head - surface) < 0.3, "and floats with the head at the surface", "head %.2f, surface %.2f" % [head, surface])

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _drive(&"bot", forward, 256)
	var flat := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
	print("    swimming: %.2f m/s" % flat)
	_check(flat > 2.5 and flat <= player.swim.swim_speed + 0.01, "and swims forward, slower than a run", "%.2f m/s" % flat)

	# Props: two that float, one that sinks.
	var crate := playground.props.spawn(&"crate", &"bot", Vector3(-40.0, 1.0, -70.0))
	var barrel := playground.props.spawn(&"barrel", &"bot", Vector3(-35.0, 1.0, -70.0))
	var boulder := playground.props.spawn(&"boulder", &"bot", Vector3(-25.0, 1.0, -70.0))
	# And a beach ball let go on the bed: the lightest thing in the catalogue, and the one
	# a lift added after the damping launched out of the basin to y 2081.
	var bed_y: float = boxes[0].position.y if not boxes.is_empty() else -4.0
	var ball := playground.props.spawn(&"beach_ball", &"bot", Vector3(-30.0, bed_y + 0.6, -60.0))
	var ball_top := -INF
	for _i in range(40):
		await _drive(&"bot", idle, 16)
		ball_top = maxf(ball_top, (ball.node as Node3D).global_position.y)
	# Measured at its bottom: 2 kg in a 2.4 m ball floats on the water, not in it.
	var ball_half: float = PlaygroundProp.extent_of(ball.def).y * 0.5
	var y_ball: float = (ball.node as Node3D).global_position.y - ball_half
	ball_top -= ball_half
	print("    a beach ball from the bed: bottom highest %.2f, after 5 s %.2f (surface %.2f)" % [ball_top, y_ball, surface])
	_check(ball_top < surface + 1.0 and absf(y_ball - surface) < 0.3,
		"a beach ball let go on the bed comes up and floats, and is not launched out",
		"highest %.2f, now %.2f, surface %.2f" % [ball_top, y_ball, surface])
	var y_crate: float = (crate.node as Node3D).global_position.y
	var y_barrel: float = (barrel.node as Node3D).global_position.y
	var y_boulder: float = (boulder.node as Node3D).global_position.y
	var bed := boxes[0].position.y if not boxes.is_empty() else -4.0
	print("    after 5 s: crate %.2f, barrel %.2f, boulder %.2f (surface %.2f, bed %.2f)" % [y_crate, y_barrel, y_boulder, surface, bed])
	_check(absf(y_crate - surface) < 0.6 and absf(y_barrel - surface) < 0.8, "a crate and a barrel float at the surface")
	_check(y_boulder < bed + 2.0, "and a boulder sinks to the bed", "%.2f" % y_boulder)
	_check(absf((crate.node as RigidBody3D).linear_velocity.y) < 0.5, "and what floats has settled, not bobbing for ever",
		"%.2f m/s" % (crate.node as RigidBody3D).linear_velocity.y)

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var _lobby: DotResult = await playground.change_map(&"pg_lobby")
	_check(player.swim.volumes.is_empty() and player.controller.state.mode != player.swim.mode_id,
		"a map with no water leaves nobody swimming")
	_done()


## Nature's newer pieces: thin ice over a lake holds a walker and gives under a drop off the
## diving board (and the player swims), slime sends a player to the spawn with the arena off,
## and a bush is walked straight through.
func _test_ice_slime_foliage() -> void:
	_section("thin ice, slime and foliage")

	var changed: DotResult = await playground.change_map(&"pgc_nature")
	if not changed.ok:
		_check(false, "pgc_nature loads", changed.error.message)
		_done()
		return
	var player: PlaygroundPlayer = playground.players[&"bot"]
	var ice := -1
	for index: int in playground.panes.keys():
		if (playground.panes[index] as Dictionary)["material"] == &"thin_ice":
			ice = index
	_check(ice >= 0, "the lake's ice is breakable")

	var still := DotFpsCommand.new()
	player.teleport(Vector3(4.0, 2.6, -80.0), 0.0)
	await _drive(&"bot", still, 256)
	_check(playground.panes.has(ice) and player.controller.state.position.y > 1.8, "a walker stands on it, and it holds",
		"y %.2f" % player.controller.state.position.y)

	# Off the end of the diving board: 3 m onto the ice.
	player.teleport(Vector3(18.0, 5.1, -80.0), 0.0)
	await _drive(&"bot", still, 200)
	_check(not playground.panes.has(ice), "a drop off the diving board goes through it")
	await _drive(&"bot", still, 200)
	_check(player.controller.state.mode == player.swim.mode_id, "into the water under it, swimming",
		"mode %d at y %.2f" % [player.controller.state.mode, player.controller.state.position.y])

	var spawn: Vector3 = playground.current_map_node().fallback_spawn
	player.teleport(Vector3(-95.0, 0.3, 14.0), 0.0)
	await _drive(&"bot", still, 4)
	_check(player.controller.state.position.distance_to(spawn) < 5.0, "slime puts a player back at the spawn, with the arena off")

	player.teleport(Vector3(-38.0, 1.0, 30.0), -90.0)
	var east := DotFpsCommand.new()
	east.yaw = -90.0
	await _drive(&"bot", east, 32)
	east.move = Vector2(0.0, 1.0)
	await _drive(&"bot", east, 256)
	_check(player.controller.state.position.x > -28.0, "a bush is walked straight through", "x %.2f" % player.controller.state.position.x)

	var _lobby: DotResult = await playground.change_map(&"pg_lobby")
	_done()


## game-playground-maps' documents this suite surveys. See `_test_the_maps_are_surveyed`.
const CUSTOM_MAPS := ["pgc_plots", "pgc_quarry", "pgc_slopes", "pgc_town", "pgc_islands", "pgc_site", "pgc_warehouse", "pgc_canyon", "pgc_harbour", "pgc_bowl", "pgc_obstacle", "pgc_nature"]


## A floor with one of everything on it: a 0.5 m slot between two walls, a platform 5 m
## up, and a cellar a player drops into and cannot climb out of.
func _the_survey_sees_what_it_looks_for() -> void:
	var boxes: Array = [
		PlaygroundMapSurvey.solid(Vector3(0.0, -0.5, 0.0), Vector3(20.0, 1.0, 20.0)),
		# The slot: two walls 0.5 m apart.
		PlaygroundMapSurvey.solid(Vector3(-5.0, 1.5, -6.0), Vector3(2.0, 3.0, 1.0)),
		PlaygroundMapSurvey.solid(Vector3(-2.5, 1.5, -6.0), Vector3(2.0, 3.0, 1.0)),
		# Out of reach: 5 m up, 4 m across, nothing to climb.
		PlaygroundMapSurvey.solid(Vector3(-6.0, 5.0, 6.0), Vector3(4.0, 0.5, 4.0)),
		# The cellar: 3 m under the floor's east edge, walled in on its other three sides.
		PlaygroundMapSurvey.solid(Vector3(13.0, -3.5, 0.0), Vector3(6.0, 1.0, 6.0)),
		PlaygroundMapSurvey.solid(Vector3(16.5, 0.0, 0.0), Vector3(1.0, 8.0, 8.0)),
		PlaygroundMapSurvey.solid(Vector3(13.0, 0.0, 3.5), Vector3(6.0, 8.0, 1.0)),
		PlaygroundMapSurvey.solid(Vector3(13.0, 0.0, -3.5), Vector3(6.0, 8.0, 1.0)),
	]
	var solids: Array[PlaygroundMapSurvey.Solid] = []
	for box: Variant in boxes:
		solids.append(box)

	# The walls' own tops are out of reach too, which is right and is not what this asks
	# about, so the fixture declares them the way a map declares its walls.
	var walls: Array = []
	for i in [1, 2, 5, 6, 7]:
		var wall: PlaygroundMapSurvey.Solid = solids[i]
		walls.append({"box": wall.bounds.grow(0.1), "why": "a fixture wall's top"})

	var spawns: Array[Vector3] = [Vector3(0.0, 1.0, 0.0)]
	var none := DotTimerZoneSet.new()
	var found: Dictionary = PlaygroundMapSurvey.survey_solids(solids, none, spawns, walls)

	_check((found["slots"] as Array).size() == 1,
		"the survey finds the fixture's one slot", "; ".join(found["slots"]))
	_check((found["unreached"] as Array).size() == 1
			and str((found["unreached"] as Array)[0]).contains(", 5.2, "),
		"and the platform nobody can reach", "; ".join(found["unreached"]))
	_check((found["trapped"] as Array).size() == 1
			and str((found["trapped"] as Array)[0]).contains("-3.0"),
		"and the cellar nobody can leave", "; ".join(found["trapped"]))

	# Declared, the platform is not reported; a reset in the cellar is a way out of it.
	var declared: Array = walls.duplicate()
	declared.append({"box": AABB(Vector3(-8.0, 4.0, 4.0), Vector3(4.0, 2.0, 4.0)), "why": "fixture"})
	var reset := DotTimerZoneSet.new()
	var pit := DotTimerZone.make(DotTimerZone.Kind.RESPAWN)
	pit.set_box(Vector3(10.0, -3.5, -3.0), Vector3(16.0, 0.0, 3.0))
	reset.add(pit)
	var quiet: Dictionary = PlaygroundMapSurvey.survey_solids(solids, reset, spawns, declared)

	_check((quiet["unreached"] as Array).is_empty() and (quiet["trapped"] as Array).is_empty(),
		"and neither once the platform is declared and the cellar has a reset",
		"unreached %s; trapped %s" % [str(quiet["unreached"]), str(quiet["trapped"])])


func _the_spawn_yaw_survives_a_tick(
	player: PlaygroundPlayer, spawn: DotTimerZone
) -> void:
	var still := 8

	# A bot: nothing samples it and nothing is applied for eight ticks.
	playground.spawn_player(player.player_id)
	for _i in range(still):
		await get_tree().physics_frame

	_check(
		absf(angle_difference(
			deg_to_rad(player.controller.state.yaw), deg_to_rad(spawn.destination_yaw)
		)) < 0.01,
		"a bot's spawn yaw is still the spawn's %d ticks later" % still,
		"yaw %.1f, the spawn says %.1f"
			% [player.controller.state.yaw, spawn.destination_yaw]
	)

	# A client: a sampler that last faced somewhere else, applied every tick the way
	# `PlaygroundPlayer.simulate` applies a real one.
	var sampler := DotFpsSampler.new(player.controller.tunables)
	DotFpsSampler.register_default_actions(sampler)
	sampler.look_at_angles(spawn.destination_yaw - 90.0, 0.0)
	player.sampler = sampler

	playground.spawn_player(player.player_id)
	for _i in range(still):
		await get_tree().physics_frame

	_check(
		absf(angle_difference(
			deg_to_rad(player.controller.state.yaw), deg_to_rad(spawn.destination_yaw)
		)) < 0.01,
		"and so is a client's, whose sampler was facing 90 degrees away",
		"yaw %.1f, the spawn says %.1f"
			% [player.controller.state.yaw, spawn.destination_yaw]
	)

	player.sampler = null
	playground.spawn_player(player.player_id)
	await get_tree().physics_frame


func _test_the_client_boots() -> void:
	_section("the client boots")

	var client := PlaygroundClient.new()
	client.name = "Client"

	# Its own config, records in memory. A test must not write into the user's data
	# directory, and this is the only reason `PlaygroundClient.config` exists.
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	client.config = config

	add_child(client)

	for _i in range(4):
		await get_tree().process_frame

	_check(client.playground != null, "the client builds a playground")
	_check(
		client.playground != null and client.playground.booted,
		"which finishes booting"
	)
	_check(
		client.playground != null and client.playground.maps.current != null,
		"with a map up",
		String(client.playground.maps.current.id)
			if client.playground != null and client.playground.maps.current != null
			else "none"
	)

	# The four things that are all missing together when `_ready` stops halfway.
	_check(client.player != null, "the client has a player")
	_check(client.camera != null, "and a camera")
	_check(client.hud != null, "and a HUD")
	_check(
		client.screens != null and client.menu != null,
		"and a spawn menu registered on a stack"
	)

	_check(
		client.menu != null and client.screens != null
		and client.screens.screen(client.menu.screen_id()) == client.menu,
		"which the stack can find by id"
	)
	_check(
		client.player != null and client.player.samples_input
		and client.player.sampler != null,
		"and the player samples input, with a sampler actually built"
	)

	# [b]A death draws the server's fall from the body this client draws.[/b] Connected the
	# reaction comes on COMBAT; here it is handed over, which is the half no wire check sees.
	# Armed by spawning from the character node instead of its body (the parts check fails:
	# the capsule-and-marker node is not the figure) and by ignoring the rules (the topple).
	client._build_ragdolls()
	var other := client.playground.add_player(&"u66", "Fallen")
	other.teleport(client.player.controller.state.position + Vector3(0.0, 0.0, -4.0))
	await get_tree().process_frame
	var crumple := DotPlayerDeath.new()
	crumple.reaction = DotPlayerDeathReactions.CRUMPLE
	var body := client.fall(&"u66", crumple)
	_check(body != null and body.reaction.id == DotPlayerDeathReactions.CRUMPLE and body.part_count() > 1
			and not other.character.body().visible,
		"a death falls as the server's reaction, copied from the drawn figure, which is hidden",
		str(body.describe()) if body != null else "no body")
	client.rise(&"u66")
	_check(other.character.body().visible, "and a return draws the figure again")
	client.ragdolls.clear()
	var _off := client.playground.ragdoll_rules.set_cvar("sv_ragdoll", "0")
	var toppled := client.fall(&"u66", crumple)
	_check(toppled != null and toppled.style == DotPlayerRagdollRules.Style.TOPPLE,
		"the server's sv_ragdoll 0 is the topple fallback")
	var _on := client.playground.ragdoll_rules.set_cvar("sv_ragdoll", "1")
	client.ragdolls.clear()
	client.rise(&"u66")
	_check(client.fall(client.player.player_id, crumple) == null,
		"no ragdoll of your own body in first person")
	client.playground.remove_player(&"u66")

	# [b]The sensitivity slider reaches the sampler.[/b] It was declared, shown and saved,
	# and nothing called `bind_look`, so the view turned at DotFpsTunables' default (0.25
	# degrees per count) whatever the player chose. Read off the tunables the sampler turns
	# the view with, offline and for the connected client's own sampler, which `_adopt`
	# hands a fresh tunables object. Armed: without `_bind_look` all four fail.
	var look_settings: DotSettingsManager = (
		client.presentation.settings if client.presentation != null else null
	)
	var look: DotFpsTunables = (
		client.player.sampler.tunables
		if client.player != null and client.player.sampler != null else null
	)
	_check(
		look != null and look_settings != null and is_equal_approx(look.mouse_sensitivity,
			look_settings.get_float(&"sensitivity") * DotMenuApplier.DEGREES_PER_COUNT),
		"the saved sensitivity reaches the offline sampler, at dot-menu's degrees per count",
		"%.4f" % (look.mouse_sensitivity if look != null else -1.0)
	)
	if look_settings != null:
		look_settings.set_value(&"sensitivity", 4.0)
	_check(
		look != null and is_equal_approx(look.mouse_sensitivity, 4.0 * DotMenuApplier.DEGREES_PER_COUNT),
		"and moving the slider changes the turning speed",
		"%.4f" % (look.mouse_sensitivity if look != null else -1.0)
	)
	var net_sampler := DotFpsSampler.new(DotFpsTunables.new())
	client._sampler = net_sampler
	client._bind_look()
	if look_settings != null:
		look_settings.set_value(&"sensitivity", 3.0)
	client._sampler = null
	_check(
		is_equal_approx(net_sampler.tunables.mouse_sensitivity, 3.0 * DotMenuApplier.DEGREES_PER_COUNT),
		"and the connected client's sampler, rebound when it adopts its player, follows it too",
		"%.4f" % net_sampler.tunables.mouse_sensitivity
	)
	if look_settings != null:
		look_settings.set_value(&"invert_mouse", true)
	_check(
		look != null and look.invert_look_y and net_sampler.tunables.invert_look_y,
		"and inverting the vertical look inverts both"
	)
	if look_settings != null:
		look_settings.set_value(&"invert_mouse", false)

	# [b]The mouse, end to end.[/b] Nothing in this family had ever delivered an
	# `InputEventMouseMotion` to a client and looked at what happened, which is how a
	# dead mouse survived: `_on_mouse_motion` fed `player.sampler` and `_net_physics`
	# sampled `_sampler`, two different objects, and `DotFpsSampler.sample` polls the
	# `InputMap` for movement so everything except the view kept working.
	var before_yaw: float = (
		client.player.controller.state.yaw if client.player != null else 0.0
	)

	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(120.0, 0.0)

	# [b]Captured, because a look input is only a look input while it is.[/b] Headless
	# starts VISIBLE, which is the state a player is in after one press of Escape, and
	# the guard in `_on_mouse_motion` is what stops a free cursor from turning the view
	# under itself. Setting it here makes this check model somebody playing rather than
	# somebody with a menu key stuck down.
	client.mouse_capture_override = true
	client._unhandled_input(motion)

	# The sampler accumulates and spends it on the next simulated tick, so the view has
	# not turned yet -- that is the point of accumulating it. Let the game tick.
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(
		client.player != null
		and not is_equal_approx(client.player.controller.state.yaw, before_yaw),
		"a mouse motion turns the view",
		"yaw %.3f -> %.3f" % [
			before_yaw,
			client.player.controller.state.yaw if client.player != null else 0.0
		]
	)

	# [b]And the other half: a released cursor turns nothing.[/b] Escape frees the
	# pointer with no screen open, so `_menu_is_open` is false and every check above
	# still passes while the view spins under a cursor the player is aiming at a
	# spawn menu with. Same event, same client, one property different.
	#
	# Driven through `mouse_capture_override` because `Input.mouse_mode` is a no-op
	# under the dummy display server -- it reads VISIBLE however it is written, so a
	# suite that set it directly would prove nothing and pass anyway.
	var released_yaw: float = client.player.controller.state.yaw

	client.mouse_capture_override = false

	var free_motion := InputEventMouseMotion.new()
	free_motion.relative = Vector2(120.0, 0.0)
	client._unhandled_input(free_motion)

	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(
		is_equal_approx(client.player.controller.state.yaw, released_yaw),
		"and a motion with the cursor released turns nothing",
		"yaw %.3f -> %.3f" % [released_yaw, client.player.controller.state.yaw]
	)

	# [b]Escape releases and never captures; a click captures.[/b] game-g2gfast's
	# contract, for the browser: Escape is how a browser itself leaves pointer lock and it
	# then refuses to re-enter from a key for about a second, so an Escape that toggled
	# the capture back silently did nothing every other press on the web. `_set_captured`
	# moves the override with it, which is what these read.
	client.mouse_capture_override = true
	var escape := InputEventKey.new()
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	client._unhandled_input(escape)

	_check(
		client.mouse_capture_override == false and not client._menu_is_open(),
		"Escape releases the pointer and opens nothing on the first press"
	)

	# With no menu the second press is where the old toggle captured again.
	var kept_menu: DotMenu = client.game_menu
	client.game_menu = null
	client._unhandled_input(escape)
	client.game_menu = kept_menu

	_check(
		client.mouse_capture_override == false,
		"and a second Escape never captures it again, which a browser would refuse"
	)

	# With the menu, the second Escape opens it — dot-menu's, whose own Escape is off so
	# this game keeps its two steps — and Escape closes it again.
	client._unhandled_input(escape)
	var opened := kept_menu != null and kept_menu.is_open()
	# The menu swallows an Escape that lands within its grace of opening (a browser's own
	# pointer-lock Escape arriving late must not flash it shut), and this one lands in the
	# same millisecond, so the grace is off for this press.
	var grace := kept_menu.config.escape_grace_ms if kept_menu != null else 0
	if kept_menu != null:
		kept_menu.config.escape_grace_ms = 0
	var shut := kept_menu != null and kept_menu.handle_event(escape) and not kept_menu.is_open()
	if kept_menu != null:
		kept_menu.config.escape_grace_ms = grace
	_check(opened and shut, "the second Escape opens the menu, and Escape closes it")

	# [b]H is help, in every game of the family[/b], every key is a row of the table, and the
	# Escape menu has Help & commands and Leave (the first play test found Help hidden here).
	var keys: DotMenuBindings = client.keys
	_check(keys != null and keys.key_for(DotMenuBindings.HELP_ACTION) == "H" and keys.defaults_on("H").size() == 1,
		"help is on H, and nothing else in the key table is")
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	var helped := kept_menu != null and kept_menu.handle_event(h) and kept_menu.help.is_open()
	_check(helped and kept_menu.help.about != "" and kept_menu.help.heading() == "How to play Playground",
		"H opens the help screen, which says what the game is before the keys")
	if kept_menu != null:
		kept_menu.close_all()
		kept_menu.open()
	var leave_button := kept_menu.screen.find_child("Action_leave", true, false) as Button if kept_menu != null else null
	_check(kept_menu != null and kept_menu.screen.find_child("Action_help", true, false) != null
		and leave_button != null and leave_button.visible, "the Escape menu has Help & commands and Leave")
	if kept_menu != null:
		kept_menu.close_all()

	var menu: DotMenu = kept_menu

	# M, the family's rule since the first play test: the map list, and solo a choice
	# changes it now. The server's half (the owner's flag, the vote) is in `dedicated`.
	_check(keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table is",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	# B is the family's loadout key, the arena's loadout: nothing else here may default to it
	# (Clear checkpoints was B). Solo there is no arena, and B says where the loadouts are.
	var on_b := keys.defaults_on("B")
	_check(on_b.size() <= 1 and on_b.all(func(r: Dictionary) -> bool: return StringName(str(r["action"])) == DotMenuBindings.LOADOUT_ACTION),
		"only the loadout is on B, the family's loadout key",
		str(on_b.map(func(r: Dictionary) -> String: return str(r["label"]))))
	# The right button aims a zee gun (the family's Aim row); its quick melee is the middle one.
	_check(keys.key_for(PlaygroundBindings.AIM) == "Mouse 2" and keys.defaults_on("Mouse 2").size() == 1
		and keys.key_for(PlaygroundBindings.BASH) == "Mouse 3", "a gun aims on the right button, quick melee on the middle",
		"%s %s" % [keys.key_for(PlaygroundBindings.AIM), keys.key_for(PlaygroundBindings.BASH)])
	if client.get("loadout_menu") != null:
		menu.close_all()
		var b_key := InputEventKey.new()
		b_key.physical_keycode = KEY_B
		b_key.keycode = KEY_B
		b_key.pressed = true
		var menu_took := menu.handle_event(b_key)
		client.call("_unhandled_input", b_key)
		var said := ((client.get("hud") as Node).get("_notice") as Label).text
		_check(not menu_took and not bool(client.get("arena_on")) and said == "Loadouts are in the arena.",
			"solo B opens nothing and says the loadouts are in the arena", said)
	# Down a zee gun's sights the HUD hands dot-ui's crosshair the aim; a scope replaces it.
	var pg_hud: Node = client.get("hud")
	pg_hud.call("set_aim", 1.0, true)
	var scoped_ok := float((pg_hud.get("scope") as Control).get("fraction")) == 1.0 and not (pg_hud.get("_crosshair") as Control).visible
	pg_hud.call("set_aim", 0.0, false)
	_check(scoped_ok and (pg_hud.get("_crosshair") as Control).visible and float((pg_hud.get("scope") as Control).get("fraction")) == 0.0,
		"through a scope the HUD shows zee's scope instead of the crosshair, and puts it back at the hip")
	# Closed right before the key: an offline client with no captured pointer (headless) may
	# have put its menu back up, and while anything is open every key is the menu's.
	menu.close_all()
	var map_before: StringName = client.playground.maps.current.id
	var m_key := InputEventKey.new()
	m_key.physical_keycode = KEY_M
	m_key.keycode = KEY_M
	m_key.pressed = true
	_check(menu.handle_event(m_key) and menu.picker.is_open() and menu.picker.items.size() > 1,
		"M opens the map list, more than one to choose", str(menu.picker.items.size()))
	var wanted_map: StringName = &""
	var map_key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted_map = StringName(str((it as Dictionary)["id"]))
			map_key = KEY_0 + row
			break
	var digit_key := InputEventKey.new()
	digit_key.physical_keycode = map_key
	digit_key.keycode = map_key
	digit_key.pressed = true
	var _picked := menu.handle_event(digit_key)
	for _i in 60:
		await get_tree().physics_frame
	_check(wanted_map != &"" and client.playground.maps.current.id == wanted_map and not menu.picker.is_open(),
		"choosing one changes the map now", "%s, now %s" % [wanted_map, client.playground.maps.current.id])
	# Back where it was, for the checks after this one.
	var _back_map: Variant = await menu.maps.change_fn.call(map_before)
	for _i in 60:
		await get_tree().physics_frame
	var spawn_row := keys.row_for_action(&"pg_spawn") if keys != null else {}
	var rebound: DotResult = keys.rebind(spawn_row, "J", client.presentation.settings) if not spawn_row.is_empty() else DotResult.fail(DotError.CODE_STATE, "no row")
	var j := InputEventKey.new()
	j.physical_keycode = KEY_J
	var e := InputEventKey.new()
	e.physical_keycode = KEY_E
	_check(rebound.ok and j.is_action(&"pg_spawn") and not e.is_action(&"pg_spawn"),
		"a key rebound in the menu moves what the client reads (spawn on J, E free)")
	if keys != null:
		keys.reset_all(client.presentation.settings)
	_check(e.is_action(&"pg_spawn"), "and Reset puts it back on E")
	client.mouse_capture_override = true

	# From released, whatever the line above left, so this check stands on its own.
	client.mouse_capture_override = false
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	client._unhandled_input(click)

	_check(
		client.mouse_capture_override == true,
		"a click on the world is what takes the pointer back"
	)

	client.mouse_capture_override = true

	# And the routing rule itself, for the deployment this suite does not build. A
	# networked client's mouse must reach `_sampler`, because that is the sampler
	# `_net_physics` stamps a command from; `player.sampler` is null on one and the
	# events went there. Asserted on the accessor rather than by standing a whole
	# networked client up, because the bug was the disagreement between two lines and
	# an accessor both of them go through is what fixed it.
	_check(
		client.active_sampler() == client.player.sampler,
		"a local client's mouse feeds the player's own sampler"
	)

	# Christian's first play test: a darker HUD by default, restyled live by the menu's theme.
	var plate := client.hud.ammo.colour(&"plate")
	_check(client.game_menu.followed_huds().has(client.hud) and plate.get_luminance() < 0.1 and plate.a >= 0.7
		and client.hud.ammo.colour(&"highlight") == PlaygroundGeometry.COLOUR_BOOST,
		"the HUD is dark by default, in the menu's theme, with the boost amber as its accent", str(plate))
	var _themed: Variant = client.game_menu.settings.set_value(&"ui_theme", &"contrast")
	_check(client.hud.ammo.colour(&"plate") == client.game_menu.palette().hud_plate
		and client.hud.hit_marker.colour(&"text") == client.game_menu.palette().hud_text
		and client.hud.ammo.colour(&"highlight") == PlaygroundGeometry.COLOUR_BOOST
		and client.hud.timer_hud.panel_colour == client.game_menu.palette().hud_plate,
		"a theme picked in the menu reaches the pieces and the timer's block at once, the accent kept")
	_themed = client.game_menu.settings.set_value(&"ui_theme", &"midnight")

	# [b]Typing at the console must not walk the player.[/b] The sampler polls the keys
	# every tick and a focused line edit does not stop `Input.is_action_pressed`; the
	# console is one of dot-menu's overlays (DotConsoleKit registers it), and the menu's
	# `overlays_changed` is what suspends the sampler. W held, measured in metres.
	var console := client.presentation.console if client.presentation != null else null
	var forward: StringName = client.player.sampler.actions["forward"]
	for _i in range(60):
		await get_tree().physics_frame
	var _opened := console.open() if console != null else false
	await get_tree().process_frame
	_check(console != null and client.game_menu.any_open() and client.player.sampler.suspended,
		"the console opens as one of the menu's overlays and suspends the sampler")
	var typing_from := client.player.global_position
	Input.action_press(forward)
	for _i in range(30):
		await get_tree().physics_frame
	Input.action_release(forward)
	var typed := client.player.global_position.distance_to(typing_from)
	_check(typed < 0.001, "W held with the console open moves nobody", "%.3f m" % typed)
	if console != null:
		console.close()
	await get_tree().process_frame
	_check(not client.player.sampler.suspended and not client.game_menu.any_open(),
		"closing it gives the keys back")
	var walking_from := client.player.global_position
	Input.action_press(forward)
	for _i in range(30):
		await get_tree().physics_frame
	Input.action_release(forward)
	var walked := client.player.global_position.distance_to(walking_from)
	_check(walked > 0.1, "and the same W walks again (the control)", "%.3f m" % walked)
	# The control walk coasts; the checks below expect a player standing still.
	for _i in range(60):
		await get_tree().physics_frame
	# Closing an overlay recaptures the pointer, which moves the override; put it back.
	client.mouse_capture_override = true

	var networked := PlaygroundClient.new()
	networked.link = Node.new()
	networked._sampler = DotFpsSampler.new(DotFpsTunables.new())

	_check(
		networked.active_sampler() == networked._sampler,
		"and a networked client's feeds the one its tick stamps commands from"
	)

	networked.link.free()
	networked.free()

	# [b]A connected client's HUD holds the vote's clock.[/b] The netcode comes up before
	# the HUD in `_ready`, and the hand-over used to sit with the netcode, where it found
	# no HUD — so every connected client counted its own map session's clock through
	# every extend while `headless_net`, which checks the bridge and not the client, said
	# the clock arrived. Booted for real here, with a bare node for a link: the bridge
	# needs one and the client asks every method of it before calling.
	var connected := PlaygroundClient.new()
	connected.name = "ConnectedClient"
	connected.link = Node.new()
	add_child(connected)
	for _i in range(4):
		await get_tree().process_frame
	_check(
		connected.hud != null and connected.bridge != null
			and connected.hud.clock_view == connected.bridge.clock_view,
		"a connected client's HUD draws the clock its bridge adopts from the server",
		"hud %s, bridge %s" % [connected.hud != null, connected.bridge != null]
	)
	var stub_link: Node = connected.link
	connected.queue_free()
	stub_link.queue_free()
	await get_tree().process_frame

	# [b]The client makes a noise when something happens, through the game and not
	# through the hooks.[/b] headless_presentation calls `on_prop_spawned` itself, which
	# proved every hook correct while nothing in the game called one and the playable
	# client was silent. This goes through the client's own spawn, the spawner's own
	# refusal and a real map change.
	var sink := client.presentation.audio.sink as DotAudioSinkNull \
		if client.presentation != null and client.presentation.audio != null else null
	_check(sink != null, "the headless client's presentation has a null sink to count on")

	if sink != null:
		sink.forget()
		client.selected_prop = &"crate"
		client._spawn()
		_check(
			sink.count_of(&"prop_spawn") == 1,
			"a prop the client spawns through the game makes a noise",
			"%d" % sink.count_of(&"prop_spawn")
		)

		# The physics gun's beam, through the client's own frame: a hook nothing calls is
		# this file's oldest bug. Holding is set by hand, because a grab needs the prop in
		# the crosshair and that is dot-props' suite's question, not this one's.
		var mine := client.playground.props.props_of(client.player_id)
		var crate: DotPropInstance = mine.back() if not mine.is_empty() else null
		var crate_body := crate.node as Node3D if crate != null else null
		if crate_body != null:
			client.player.phys_gun.held = crate
			client._holding = true
			await get_tree().process_frame
			await get_tree().process_frame
			var beam: Node3D = client.presentation._beams.get(0)
			var tip := beam.global_transform * Vector3(0, 0, -1) \
				if beam != null and is_instance_valid(beam) else Vector3.INF
			_check(
				tip.distance_to(crate_body.global_position) < 0.3,
				"the client's own frame draws the physics gun's beam to what it holds",
				"tip %s, prop %s" % [tip, crate_body.global_position]
			)
			client._holding = false
			client.player.phys_gun.held = null
		else:
			_check(false, "the client's own frame draws the physics gun's beam to what it holds",
				"the crate the client spawned is not there to hold")

		sink.forget()
		client.playground.props.spawn(&"no_such_prop", client.player_id, Vector3.ZERO)
		_check(
			sink.count_of(&"refused") == 1,
			"and a spawn the spawner refuses makes the refusal noise",
			"%d" % sink.count_of(&"refused")
		)

		# An administrator's beacon and blind, through the client's OWN frame hooks rather
		# than the player's method: the marker and the ping are presentation, and a hook
		# nothing in the client calls is this file's oldest bug. Stepped by hand, a quarter
		# of a second at a time, so the count is the ripple's and not the frame rate's.
		client.player.beacon = true
		sink.forget()
		for _i in range(8):
			client._present_beacons(0.25)
		_check(
			sink.count_of(&"beacon") == 3,
			"a beacon pings as it comes on and once a second after, not once a frame",
			"%d pings in two seconds" % sink.count_of(&"beacon")
		)
		var marker := client.player.beacon_marker
		_check(
			marker != null and marker.is_inside_tree()
			and marker.global_position.is_equal_approx(client.player.controller.state.position),
			"its marker stands where the player is simulated"
		)
		_check(
			marker != null and not marker.column_shown(),
			"with no column on the player's own first-person view, which would smear the screen"
		)
		client.player.beacon = false
		client._present_beacons(0.25)
		_check(client.player.beacon_marker == null, "and it goes when the flag does")

		# And through real frames, because the checks above call the hook by hand and would
		# pass with `_process` never calling it — which is the shape every presentation hook
		# in this game once had.
		client.player.beacon = true
		await get_tree().process_frame
		await get_tree().process_frame
		_check(
			client.player.beacon_marker != null,
			"the client's own frame draws a beacon, not only a test calling the hook"
		)
		client.player.beacon = false
		await get_tree().process_frame
		await get_tree().process_frame
		_check(client.player.beacon_marker == null, "and its own frame takes it away")

		client.player.blinded = true
		client.hud.present_blind(0.5)
		var blind := client.hud.blind_overlay
		var viewport := client.hud.get_viewport_rect().size
		_check(
			blind != null and blind.visible and is_equal_approx(blind.modulate.a, 1.0),
			"a blind comes down over the HUD's player"
		)
		# The whole viewport. Headless it is 64 x 64 (docs/testing.md), which is still a
		# real size to compare against: an overlay never sized is 0 x 0 at any resolution.
		_check(
			blind != null and blind.get_global_rect().position.is_equal_approx(Vector2.ZERO)
			and blind.get_global_rect().size.is_equal_approx(viewport),
			"and covers the whole viewport",
			"%s against %s" % [str(blind.get_global_rect()) if blind != null else "-", str(viewport)]
		)
		_check(
			blind != null and blind.get_index() < client.hud.timer_hud.get_index(),
			"under the HUD's own widgets, so the clock still says the server is going on"
		)
		client.player.blinded = false
		client.hud.present_blind(0.5)
		_check(blind != null and not blind.visible, "and lifts when the flag does")

		client.presentation.fx.shake.add(1.0)
		_check(client.presentation.fx.shake.active(), "a shake is live before a map change")
		await client.playground.change_map(&"pg_bhop_intro")
		_check(
			not client.presentation.fx.shake.active(),
			"and a map change clears it, because the effects' world has gone"
		)

	# zee-dot-weapons, offline, through the client's own key handlers and its own tick.
	client._set_tool(&"zee_smg")
	await get_tree().process_frame

	var hand_rig: Variant = client.player.zee_rig if client.player != null else null
	_check(
		hand_rig is ZeeWeaponRig and client.zee_view != null
			and client.zee_view.get_parent() == client.camera,
		"a zee weapon from the menu puts hands under the camera"
	)
	_check(
		hand_rig is ZeeWeaponRig and (hand_rig as ZeeWeaponRig).authority,
		"and offline the client's rig is the one that decides"
	)
	var body_gun: Variant = client.player.zee_world if client.player != null else null
	_check(
		body_gun is ZeeWorldModel and (body_gun as ZeeWorldModel).equipped() == &"smg",
		"and the body a third-person camera shows holds it too"
	)

	# Counted through the signal into an Array: a lambda captures a scalar by value.
	var uses: Array[int] = []
	if hand_rig is ZeeWeaponRig:
		(hand_rig as ZeeWeaponRig).used.connect(func(_o: DotWeaponOutcome) -> void: uses.append(1))

	client._primary_down()
	for _i in range(120):
		await get_tree().physics_frame
	client._primary_up()

	_check(uses.size() > 1, "held fire through the client's own tick fires it, again and again",
		"%d uses in 120 ticks" % uses.size())

	client._set_tool(&"phys")
	_check(
		client.player.zee_rig == null and client.zee_view == null and client.player.zee_world == null,
		"and the physics gun takes it back out of their hands"
	)

	# Water splashes: a crate dropped into Nature's pond, heard on the client's own frames.
	var _wet_map: DotResult = await client.playground.change_map(&"pgc_nature")
	client.playground.props.limits.spawn_interval = 0.0
	var before_splash := client.presentation.splashes
	var _dropped := client.playground.props.spawn(&"crate", client.player.player_id, Vector3(60.0, 4.0, 50.0))
	# Physics ticks, not frames: a headless frame is unthrottled, and ninety of them passed
	# before the crate had fallen at all.
	for _i in range(256):
		await get_tree().physics_frame
	_check(client.presentation.splashes > before_splash, "a crate dropped into the pond splashes",
		"%d splashes" % (client.presentation.splashes - before_splash))
	var _dry_map: DotResult = await client.playground.change_map(&"pg_lobby")
	await get_tree().physics_frame

	# The tool gun's edit mode, through the client's own buttons and menu.
	var eye := client.player.eye_position()
	var edited := client.playground.props.spawn(&"crate", client.player.player_id,
		eye + client.player.aim_direction() * 2.5)
	if edited != null:
		DotPhysGun.set_frozen(edited, true)
		(edited.node as Node3D).call("set_tint", Color.html("e05252"))
	client._on_tool_mode_chosen(&"edit", {})
	client.menu.tool_mode = &"edit"
	await get_tree().physics_frame
	client._primary_down()
	client._primary_up()
	await get_tree().process_frame
	var box: Node = (edited.node as Node).get_node_or_null("EditSelection") if edited != null else null
	_check(edited != null and client.edit_target == edited.node and box is MeshInstance3D,
		"the edit mode selects what the client points at, and draws a box round it")
	_check(str((client.menu.tool_settings.get(&"edit", {}) as Dictionary).get("colour", "")) == "e05252",
		"and the Q menu's edit settings become that prop's own", str(client.menu.tool_settings.get(&"edit")))
	client.menu._set_setting("size", 2.0)
	await get_tree().process_frame
	_check(edited != null and is_equal_approx(float((edited.node as Node3D).get("size_scale")), 2.0),
		"a slider in the menu resizes it")
	_check(box is MeshInstance3D and is_instance_valid(box) and ((box as MeshInstance3D).mesh as BoxMesh).size.x > 1.9,
		"and the box grows with it",
		str(((box as MeshInstance3D).mesh as BoxMesh).size) if box is MeshInstance3D and is_instance_valid(box) else "no box")
	client._secondary_down()
	client._secondary_up()
	await get_tree().process_frame
	_check(client.edit_target == null and (edited == null or (edited.node as Node).get_node_or_null("EditSelection") == null),
		"right click lets go, and the box goes with it")
	client._set_tool(&"phys")

	client.queue_free()

	await get_tree().process_frame
	await get_tree().process_frame
	_done()



# --- The circuit -----------------------------------------------------------


## Bonus 3, the driving track.
##
## [b]This is the first thing in the family that puts a VEHICLE through the timer, and
## the first map built at a car's scale.[/b] Two halves, and the second is the one that
## could not have been written before tonight: the geometry, which is checked the same
## way the tower's is, and a real buggy driven a real lap under throttle and steering,
## through every stage, to a finish.
func _test_the_circuit(playground: Playground, zones: DotTimerZoneSet) -> void:
	var track := PgLobby.CIRCUIT_TRACK

	_check(
		zones.of_kind(DotTimerZone.Kind.START, track).size() == 1
		and zones.of_kind(DotTimerZone.Kind.END, track).size() == 1,
		"the circuit on bonus 3 has one grid and one finish line"
	)

	var stages := zones.of_kind(DotTimerZone.Kind.STAGE, track)
	_check(stages.size() == 3, "and three splits", "%d" % stages.size())

	# The trick the whole track depends on: a loop whose start and finish are the same
	# place finishes on the tick it starts. A check that only counted the zones would
	# pass for exactly that map.
	var grid: Array = zones.of_kind(DotTimerZone.Kind.START, track)
	var line: Array = zones.of_kind(DotTimerZone.Kind.END, track)
	var grid_zone: DotTimerZone = grid[0]
	var line_zone: DotTimerZone = line[0]
	var grid_box := AABB(
		grid_zone.centre() - grid_zone.size() * 0.5, grid_zone.size()
	)
	var line_box := AABB(
		line_zone.centre() - line_zone.size() * 0.5, line_zone.size()
	)

	_check(
		not grid_box.intersects(line_box),
		"and the finish line does NOT overlap the grid, which is what makes a LAP",
		"a loop timed from one box to itself finishes on the tick it starts"
	)

	# Every zone on the road, not beside it. The road is 12 m wide and the zones are
	# built from the same `circuit_point`, so a zone off the tarmac means the two
	# descriptions have come apart — which is the failure this project builds maps in
	# code to make impossible, and is worth asserting rather than assuming.
	var off := 0

	var on_road: Array[DotTimerZone] = []
	on_road.append_array(zones.of_kind(DotTimerZone.Kind.START, track))
	on_road.append_array(zones.of_kind(DotTimerZone.Kind.END, track))
	on_road.append_array(zones.of_kind(DotTimerZone.Kind.STAGE, track))

	for zone in on_road:
		var centre: Vector3 = zone.centre()
		var nearest := _nearest_circuit_distance(Vector3(centre.x, 0.0, centre.z))

		if nearest > PgLobby.CIRCUIT_WIDTH * 0.5:
			off += 1

	_check(off == 0, "and every zone sits on the road it was drawn from",
		"%d off the tarmac" % off)

	# The lap is long enough to be a lap. A circuit a car crosses in four seconds is a
	# roundabout.
	_check(
		PgLobby.circuit_length() > 350.0,
		"the lap is a lap",
		"%.0f m" % PgLobby.circuit_length()
	)

	# Clear of everything else on the plate. The jump course, the tower and the
	# staircase all live inside the inner kerb, and a circuit that clipped one of them
	# would be a car driving through a leaderboard.
	var inner := PgLobby.CIRCUIT_HALF - PgLobby.CIRCUIT_WIDTH * 0.5 \
		- PgLobby.CIRCUIT_KERB_WIDTH

	_check(
		absf(PgLobby.COURSE_X) < inner and absf(PgLobby.TOWER_X) - PgLobby.TOWER_RADIUS < inner,
		"and it runs round the jump course and the tower rather than through them",
		"inner edge %.1f m" % inner
	)


## How far [param at] is from the nearest point on the centreline.
##
## Sampled rather than solved. The centreline is four straights and four arcs and a
## closed-form nearest point is more arithmetic than this test is worth; 512 samples
## over a 611 m lap is 1.2 m apart, which is well inside the 6 m half-width being
## asserted against.
func _nearest_circuit_distance(at: Vector3) -> float:
	var length := PgLobby.circuit_length()
	var best := INF

	for i in range(512):
		var point: Array = PgLobby.circuit_point(length * float(i) / 512.0)
		best = minf(best, at.distance_to(point[0] as Vector3))

	return best


## A buggy actually drives the lap.
##
## [b]Autopiloted along the centreline rather than driven in a straight line.[/b] A
## test that held the throttle down would prove the road exists and nothing else: it is
## the CORNERS that say whether the radius is one the steering can hold, whether the
## kerbs are drivable, and whether the segments meet without a seam a wheel catches on.
## The autopilot is nine lines because [method PgLobby.circuit_point] is the same
## function the road was built from, which is the whole argument for building maps in
## code.
func _drive_the_circuit() -> void:
	var track := PgLobby.CIRCUIT_TRACK
	var driver: PlaygroundPlayer = playground.players[&"bot"]

	_check(driver.timer.set_track(track), "the circuit's track switches")

	playground.spawn_player(&"bot")

	var grid: Array = PgLobby.circuit_point(0.0)
	var at: Vector3 = grid[0]

	_check(
		driver.controller.state.position.distance_to(at) < 6.0,
		"and puts the driver on the grid",
		"%.1f m off" % driver.controller.state.position.distance_to(at)
	)

	var spawned := playground.props.spawn(
		&"buggy", &"bot", at + Vector3(0.0, 1.2, 0.0)
	)

	_check(spawned != null, "a buggy spawns on the line")

	if spawned == null:
		return

	var car := playground.vehicles.vehicle_for_node(spawned.node)

	if car == null:
		_check(false, "and is a vehicle")
		return

	# Point it down the road. A car dropped onto the grid keeps whatever rotation the
	# prop spawner gave it, and a lap that starts by reversing into the kerb measures
	# the autopilot rather than the track.
	var forward: Vector3 = grid[1]
	(car.node as Node3D).global_transform = Transform3D(
		Basis.looking_at(forward, Vector3.UP),
		at + Vector3(0.0, 1.2, 0.0)
	)

	for _i in range(30):
		await get_tree().physics_frame

	_check(playground.use_vehicle(&"bot").ok, "the bot gets in")

	# The rule this map needed: getting in must NOT cancel the run on a driven track.
	# It is asserted before the lap because a lap that never started would look
	# identical to one that was never timed.
	_check(
		playground.current_map_node().track_is_driven(track),
		"the map says bonus 3 is driven"
	)
	_check(
		not playground.current_map_node().track_is_driven(DotTimerTrack.BONUS_FIRST),
		"and that bonus 1 is not, which is what stops a jump course being driven round"
	)

	var seen: Array[int] = []
	driver.timer.stage_reached.connect(
		func(number: int, _split: float) -> void: seen.append(number)
	)

	var finished: Array[float] = []
	driver.timer.run_finished.connect(
		func(run: DotTimerRun) -> void: finished.append(run.time())
	)

	var command := DotFpsCommand.new()
	var progress := 0.0
	var stalled := 0
	# `[surf-ramp-1]` and `[bot-drive-1]`: how much of the lap was on the road, and at
	# what pace. The grid is at s = 0 and the line 12 m behind it, so a lap is that short
	# of the whole loop.
	var tally := _motion_tally()
	var lap := PgLobby.circuit_length() - PgLobby.CIRCUIT_FINISH_BACK
	var driven := 0
	var top_speed := 0.0

	# Twelve thousand ticks is roughly ninety simulated seconds, which is three times
	# what a clean lap takes. The loop exits on the finish, so the ceiling only ever
	# bounds a car that got stuck.
	for _i in range(12000):
		var here := car.position()
		progress = _circuit_progress(here, progress)

		# Aim fifteen metres up the road. Far enough that the car is not sawing at the
		# wheel on a straight, near enough that it turns in before the corner rather
		# than after it.
		var target: Array = PgLobby.circuit_point(progress + 15.0)
		var to_target: Vector3 = ((target[0] as Vector3) - here).normalized()
		var heading := -(car.node as Node3D).global_basis.z
		var right := (car.node as Node3D).global_basis.x

		# A positive `move.x` steers right, the same axis a walking player strafes on.
		command.move = Vector2(
			clampf(to_target.dot(right) * 3.0, -1.0, 1.0),
			1.0 if heading.dot(to_target) > 0.2 else 0.4
		)

		var centre: Vector3 = (PgLobby.circuit_point(progress)[0] as Vector3)
		var off_centre := Vector2(here.x - centre.x, here.z - centre.z).length()
		var where := "on" if off_centre <= PgLobby.CIRCUIT_WIDTH * 0.5 else "else"

		driver.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame

		driven += 1
		_tally_tick(tally, here, car.position(), where)
		top_speed = maxf(top_speed, car.speed())

		if not finished.is_empty():
			break

		if car.speed() < 0.5:
			stalled += 1
		else:
			stalled = 0

		if stalled > 600:
			break

	var pace := _print_pace(
		"the circuit", _tally_total(tally, "distance"), lap, driven,
		car.def.tunables.top_speed, top_speed
	)
	_check_pace("the circuit", _tally_total(tally, "distance"), lap, pace, car.def.tunables.top_speed, 0.8)
	_print_where("the circuit", "the road", tally, 0.0)
	var road := float((tally["on"] as Dictionary)["distance"])
	_check(
		road >= _tally_total(tally, "distance") * 0.95,
		"the lap is driven on the road, not across the plate beside it",
		"%.1f of %.1f m on the road" % [road, _tally_total(tally, "distance")]
	)

	_check(
		not finished.is_empty(),
		"a buggy drives the whole lap and crosses the line",
		"%.1f m round the centreline" % progress
	)
	_check(
		seen == [1, 2, 3],
		"through all three splits, in order",
		str(seen)
	)
	_check(
		not finished.is_empty() and finished[0] > 8.0,
		"and the lap took a lap's worth of time",
		"%.2f s" % (finished[0] if not finished.is_empty() else -1.0)
	)

	# Getting out mid-lap ends the run, which is the mirror of the rule above and the
	# half that would otherwise let somebody walk the last corner.
	# The bot is still sitting in the car it just finished in, so put it down first.
	# `use_vehicle` is a toggle and calling it on a rider is how a player gets out.
	if playground.vehicles.ride.is_riding(&"bot"):
		var park := DotFpsCommand.new()
		park.set_button(DotFpsCommand.BUTTON_CROUCH, true)
		await _drive(&"bot", park, 300)
		playground.use_vehicle(&"bot")
		await get_tree().physics_frame

	# Both back on the grid, stationary, pointing down the road.
	var line_up: Array = PgLobby.circuit_point(0.0)
	var start_at: Vector3 = line_up[0]
	(car.node as Node3D).global_transform = Transform3D(
		Basis.looking_at(line_up[1] as Vector3, Vector3.UP),
		start_at + Vector3(0.0, 1.2, 0.0)
	)
	car.body().linear_velocity = Vector3.ZERO
	car.body().angular_velocity = Vector3.ZERO

	driver.timer.set_track(track)
	playground.spawn_player(&"bot")

	for _i in range(30):
		await get_tree().physics_frame

	_check(playground.use_vehicle(&"bot").ok, "the bot gets back in")

	var rolling := DotFpsCommand.new()
	rolling.move = Vector2(0.0, 1.0)
	await _drive(&"bot", rolling, 200)

	_check(
		driver.timer.run != null and driver.timer.run.is_running(),
		"a second lap is under way"
	)

	var stop := DotFpsCommand.new()
	stop.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	await _drive(&"bot", stop, 300)

	# `use_vehicle` is a toggle: in when out, out when in. The same key a player presses.
	# It is refused above `max_exit_speed`, which is why the brake above is not
	# decoration.
	var got_out := playground.use_vehicle(&"bot")
	_check(got_out.ok, "the bot gets out", "%.2f m/s" % car.speed())
	await get_tree().physics_frame

	_check(
		driver.timer.run == null or not driver.timer.run.is_running(),
		"and getting out of the car ends it"
	)

	# Out of the car, upright: a ride writes the car's whole basis onto the body, and
	# facing afterwards wrote only the yaw, so whatever pitch and roll the car had at the
	# moment of getting out stayed on the rig for good. Tilted by hand here, as a car on a
	# bank would leave it.
	var body: Variant = driver.get("character")
	var upright := false
	if body != null and body.get("rig") != null and (body.get("rig") as Node3D).is_inside_tree():
		body.call("face_basis", Basis.from_euler(Vector3(0.3, 1.0, -0.2)))
		body.call("face", 0.5)
		var r: Vector3 = (body.get("rig") as Node3D).rotation
		upright = is_zero_approx(r.x) and is_zero_approx(r.z) and is_equal_approx(r.y, 0.5)
	_check(upright, "and the body stands upright again, with none of the car's tilt",
		"no body drawn for the bot" if body == null else "")


## Where [param at] is round the lap, searched forward from [param from].
##
## Forward-only, which matters: a car on the +Z straight is metres from BOTH the first
## and the last leg, and a nearest-point search over the whole lap snaps a car about to
## finish back to the grid it left. The window is generous enough to survive a spin.
func _circuit_progress(at: Vector3, from: float) -> float:
	var best := from
	var best_distance := INF

	for i in range(120):
		var s := from + float(i) * 0.5
		var point: Array = PgLobby.circuit_point(s)
		var distance := at.distance_to(point[0] as Vector3)

		if distance < best_distance:
			best_distance = distance
			best = s

	return best

