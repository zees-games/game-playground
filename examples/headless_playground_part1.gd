extends DotGameCheckSuite

const PlaygroundBindings := preload("../game/playground_bindings.gd")
const Playground := preload("../game/playground.gd")
const PlaygroundBrowser := preload("../game/client/playground_browser.gd")
const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundProfileScreen := preload("../game/playground_profile_screen.gd")
const PlaygroundReadout := preload("../game/playground_profile_readout.gd")
const PlaygroundNetBridge := preload("../game/net/playground_net_bridge.gd")
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
const PlaygroundProfiles := preload("../game/playground_profiles.gd")
const PlaygroundSpawnMenu := preload("../game/playground_spawn_menu.gd")
const PlaygroundSpawnables := preload("../game/playground_spawnables.gd")
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

var _entered := 0
var _completed := 0

var playground: Playground = null


## A stand-in for the tool gun: a mode asks its gun for the game and nothing else.
class WireGun:
	extends RefCounted
	var game: Node = null


## [method _stopping]'s stand-in for a button: S held rather than a button pressed.
const BACK_KEY := -1


## game-playground-maps' documents this suite surveys. See `_test_the_maps_are_surveyed`.
const CUSTOM_MAPS := ["pgc_plots", "pgc_quarry", "pgc_slopes", "pgc_town", "pgc_islands", "pgc_site", "pgc_warehouse", "pgc_canyon", "pgc_harbour", "pgc_bowl", "pgc_obstacle", "pgc_nature", "pgc_construct_small", "pgc_smallbase"]


## The Q menu's NPCs and pack weapons come from profiles, a game profile overrides an entry, and an
## admin's edit reaches the next spawn, a live NPC and a late joiner; a player's is refused.
func _test_profiles() -> void:
	_section("profiles drive the menu and edit live")

	var fixture := PackedStringArray(["res://examples/fixtures/profiles"])
	var profiles: PlaygroundProfiles = playground.profiles
	_check(profiles != null and profiles.runtime != null, "the playground builds its profiles and runtime")
	if profiles == null:
		return

	# The menu, derived: a scratch catalogue so nothing leaks into the sections after.
	var scratch := PlaygroundProfiles.new()
	scratch.setup(fixture)
	var cat: DotPropCatalogue = playground._prop_catalogue()
	var before := cat.props.size()
	var touched := scratch.apply_npcs(cat)
	_check(touched == 3, "three npc profiles touch the catalogue", str(touched))
	var chaser := cat.get_prop(&"npc_chaser")
	_check(chaser.display_name == "Fast Chaser", "a game-tier profile renames the entry it names")
	_check(float(chaser.meta["speed"]) == 9.0, "and changes the key it states")
	_check(float(chaser.meta["sight"]) == 40.0, "while a key it does not state keeps the catalogue's value")
	_check(chaser.category == &"pursuers", "menu.category regroups it")
	_check(bool(cat.get_prop(&"npc_hopper").meta.get("hidden", false)), "menu.hidden hides an entry")
	var mini := cat.get_prop(&"mini_hunter")
	_check(mini != null and cat.props.size() == before + 1, "a new id with extra.base adds an entry")
	_check(
		mini != null and PlaygroundSpawnables.script_of(mini) == PlaygroundSpawnables.script_of(cat.get_prop(&"npc_hunter")),
		"cloned from its base's script"
	)
	_check(cat.get_prop(&"npc_soldier") != null and float(cat.get_prop(&"npc_soldier").meta["health"]) == 100.0, "entries without a profile are unchanged")

	var menu := PlaygroundSpawnMenu.new()
	menu.catalogue = cat
	add_child(menu)
	var names: Array = menu._catalogue_defs(PlaygroundSpawnables.Kind.ENTITY).map(func(d: DotPropDef) -> String: return String(d.id))
	menu.free()
	_check(names.slice(0, 2) == ["mini_hunter", "npc_chaser"], "menu.sort orders the entities", str(names.slice(0, 3)))
	_check(not names.has("npc_hopper"), "and the hidden one is not listed")

	var rows := [{"id": "zz_fx_a", "category": "Weapons"}, {"id": "zz_fx_b", "category": "Weapons"}, {"id": "zz_fx_c", "category": "Weapons"}, {"id": "plain", "category": "Weapons"}]
	var refined := scratch.refine_weapon_entries("zz_fixture", rows)
	_check(refined.map(func(r: Dictionary) -> String: return r["id"]) == ["zz_fx_b", "plain", "zz_fx_a"], "pack weapon rows are sorted by menu.sort and the hidden one dropped")
	_check(refined[0]["category"] == "Heavy" and refined[1]["category"] == "Weapons", "and regrouped by menu.category")
	scratch.release()

	# Live editing, through the playground's own runtime and the console command's request.
	profiles.npcs.roots = fixture
	profiles.npcs.clear_cache()
	profiles.apply_npcs(playground.props.catalogue)
	var rt := profiles.runtime
	var old_permit := rt.permit
	rt.permit = func(actor: Variant, _flag: String) -> bool: return actor == "uid-admin"

	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var live := playground.props.spawn(&"npc_chaser", &"bot", Vector3(0.0, 1.2, 0.0))
	var live_body := live.node as PlaygroundEntity if live != null else null
	_check(live_body != null and live_body.tune(&"speed", 0.0) == 9.0, "a spawn reads the profile's speed")

	var req := DotConsoleProfileEdit.parse(PackedStringArray(["set", "npc", "npc_chaser", "speed", "12"]))
	var denied := rt.handle_request("uid-player", req.value)
	_check(not denied.ok and denied.error.code == DotError.CODE_FORBIDDEN, "a non-admin's edit is refused")
	_check(float(playground.props.catalogue.get_prop(&"npc_chaser").meta["speed"]) == 9.0, "and changes nothing")

	var done := rt.handle_request("uid-admin", req.value)
	_check(done.ok, "an admin's profile_edit is accepted", "" if done.ok else done.error.message)
	var next := playground.props.spawn(&"npc_chaser", &"bot", Vector3(3.0, 1.2, 0.0))
	var next_body := next.node as PlaygroundEntity if next != null else null
	_check(next_body != null and next_body.tune(&"speed", 0.0) == 12.0, "the next spawn has the edited speed")

	var sight := DotConsoleProfileEdit.parse(PackedStringArray(["set", "npc", "npc_chaser", "sight", "77"]))
	_check(rt.handle_request("uid-admin", sight.value).ok, "a second edit applies")
	_check(live_body != null and live_body.npc.def.sight_range == 77.0, "and re_apply gives the live NPC the new perception")
	var bad := DotConsoleProfileEdit.parse(PackedStringArray(["set", "npc", "npc_chaser", "health", "-5"]))
	_check(not rt.handle_request("uid-admin", bad.value).ok, "an out-of-range edit is refused by the schema")

	# A late joiner: the snapshot, through the link's own encoding.
	var late := DotProfileRuntime.new()
	var late_set := DotNpcProfiles.make_set(PlaygroundProfiles.GAME, fixture)
	late.add_set(late_set)
	var old_send := rt.send_to
	rt.send_to = func(_peer: Variant, row: Dictionary) -> void:
		late.apply_row(DotNetProfileLink.decode_body(DotNetProfileLink.encode_body(row)).value)
	rt.send_snapshot(7)
	rt.send_to = old_send
	var seen := late_set.load_profile("npc_chaser")
	_check(seen.ok and float(seen.value.get_value("speed")) == 12.0 and float(seen.value.get_value("sight")) == 77.0, "a late joiner's snapshot carries both edited values")

	# Pack weapons are one kind behind one runtime layer.
	var fx := profiles.weapons.add_pack("zz_fixture")
	fx.roots = fixture
	var wreq := DotConsoleProfileEdit.parse(PackedStringArray(["set", "weapon", "fx_a", "slot", "4"]))
	var wdenied := rt.handle_request("uid-player", wreq.value)
	_check(not wdenied.ok and wdenied.error.code == DotError.CODE_FORBIDDEN, "a non-admin's weapon edit is refused")
	_check(profiles.weapon_layer().is_empty(), "and the weapon layer stays empty")
	var audit: Array = []
	var sink := func(rec: Dictionary) -> void: audit.append(rec)
	var old_level := DotLog.get_level()
	DotLog.set_level(DotLog.Level.INFO)
	DotLog.add_sink(sink)
	_check(rt.handle_request("uid-admin", wreq.value).ok, "an admin's weapon edit is accepted")
	DotLog.remove_sink(sink)
	DotLog.set_level(old_level)
	var line: Dictionary = {}
	for rec: Dictionary in audit:
		if rec["message"] == "profile edited":
			line = rec["fields"]
	_check(not line.is_empty() and line.get("kind") == "weapon" and line.get("id") == "fx_a" and line.get("key") == "slot" and str(line.get("new")) == "4" and str(line.get("who")) != "", "and writes one audit line: who, kind, id, key, new value")
	_check(int(profiles.weapon_layer().get("fx_a", {}).get("slot", 0)) == 4, "and lands in the layer the packs rebuild from")
	var packset := DotWeaponProfiles.make_set("zz_fixture", PlaygroundProfiles.GAME, fixture, profiles.weapon_layer())
	_check(int(packset.load_profile("fx_a").value.get_value("slot")) == 4, "a pack's own set reads it")
	rt.handle_request("uid-admin", DotProfileRuntime.make_request("reset", "weapon", "fx_a"))
	_check(profiles.weapon_layer().is_empty(), "and a reset empties it")
	fx.roots = PackedStringArray()
	fx.clear_cache()
	packset.clear_cache()

	# Put the shared playground back for the sections after this one.
	rt.handle_request("uid-admin", DotProfileRuntime.make_request("reset", "npc", "npc_chaser"))
	rt.permit = old_permit
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	profiles.npcs.roots = PackedStringArray()
	profiles.npcs.clear_cache()
	profiles.apply_npcs(playground.props.catalogue)
	_check(float(playground.props.catalogue.get_prop(&"npc_chaser").meta["speed"]) == 5.0, "with the file gone the entry returns to the catalogue's own")
	_done()


## The admin workbench: opens and closes on the screen stack, edits go out as requests and come
## back through the runtime, another admin's edit refreshes the open form, and only an admin gets in.
func _test_profile_workbench() -> void:
	_section("the profile workbench edits live through requests")
	var fixture := PackedStringArray(["res://examples/fixtures/profiles"])
	var profiles: PlaygroundProfiles = playground.profiles
	var rt := profiles.runtime
	var old_permit := rt.permit
	rt.permit = func(actor: Variant, _flag: String) -> bool: return actor == "uid-admin"
	profiles.npcs.roots = fixture
	profiles.npcs.clear_cache()

	var stack := DotScreenStack.new()
	stack.register_service = false
	stack.manage_mouse = false
	add_child(stack)
	stack.setup()
	var screen := PlaygroundProfileScreen.new()
	screen.profiles = profiles
	var sent: Array[Dictionary] = []
	screen.submit = func(req: Dictionary) -> DotResult:
		sent.append(req)
		var wire := DotNetProfileLink.decode_body(DotNetProfileLink.encode_body(req))
		if not wire.ok:
			return wire
		return rt.handle_request("uid-admin", wire.value)
	var targets: Array[String] = []
	screen.target_requested.connect(func(kind: String, id: String) -> void: targets.append(kind + "/" + id))
	_check(stack.register(screen).ok, "the screen registers")
	_check(stack.push(&"profiles").ok and stack.is_open(&"profiles"), "it opens")
	_check(screen.ids("npc").has("npc_chaser"), "it lists the NPC profiles the runtime can edit", str(screen.ids("npc")))

	screen.open_profile("npc", "npc_chaser")
	_check(screen.form != null and screen.form.row("speed") != null, "an NPC opens as a schema form")

	var spawn_at := rt.revision("npc", "npc_chaser")
	var _r := screen.form.set_value("speed", 12.0)
	screen.flush()
	_check(sent.size() == 1 and sent[0]["op"] == "set" and sent[0]["key"] == "speed", "a form edit is sent as a set request", str(sent))
	var seen := profiles.npcs.load_profile("npc_chaser")
	_check(seen.ok and float(seen.value.get_value("speed")) == 12.0, "and the runtime layer holds the new value")
	_check(rt.revision("npc", "npc_chaser") > spawn_at, "the revision moves")
	_check(screen._edited_count("npc", "npc_chaser") == 1, "the profile is marked edited live")

	var other := DotProfileRuntime.make_request("set", "npc", "npc_chaser", "sight", 55.0)
	_check(rt.handle_request("uid-admin", other).ok, "another admin edits the same profile")
	screen._process(0.0)
	_check(float(screen.form.values().get("sight", 0.0)) == 55.0, "the open form follows it", str(screen.form.values().get("sight")))
	_check(float(screen.form.values().get("speed", 0.0)) == 12.0, "and keeps the edit already there")

	screen.form.reset_key("speed")
	screen.flush()
	_check(sent.back()["op"] == "reset_key" and float(profiles.npcs.load_profile("npc_chaser").value.get_value("speed")) == 9.0, "a per-key reset goes back to the file's number")
	screen.reset_all()
	_check(screen._edited_count("npc", "npc_chaser") == 0, "reset all clears every live edit")
	var count := sent.size()
	screen.save()
	_check(sent.size() == count + 1 and sent.back()["op"] == "save", "save is its own request to the server layer")
	screen.request_target()
	_check(targets == ["npc/npc_chaser"], "the test-target button asks the client to spawn it", str(targets))

	var weapons := screen.ids("weapon")
	if not weapons.is_empty():
		screen.open_profile("weapon", weapons[0])
		_check(screen.form != null and screen.current_kind() == "weapon", "a weapon opens in the same form")
	else:
		_check(true, "no weapon profiles are loaded here, so none to open")

	var m4 := {"extra.damage": 29.0, "extra.rpm": 800.0, "extra.reload_seconds": 2.1, "magazine": 30}
	var st := PlaygroundReadout.weapon_stats(m4, 64.0)
	_check(is_equal_approx(float(st["burst_dps"]), 29.0 * 800.0 / 60.0), "burst DPS is damage times rounds per second", str(st))
	_check(float(st["sustained_dps"]) < float(st["burst_dps"]), "reloading lowers sustained DPS")
	var kill := PlaygroundReadout.ttk(st, 100.0)
	_check(int(kill["shots"]) == 4 and is_equal_approx(float(kill["seconds"]), 3.0 * 60.0 / 800.0), "100 hp takes 4 shots, 3 intervals", str(kill))
	_check(float(PlaygroundReadout.ttk(st, 1000.0)["seconds"]) > 34.0 * 60.0 / 800.0 + 2.0, "a kill longer than a magazine pays the reload")
	_check(PlaygroundReadout.weapon_stats({}, 64.0).is_empty(), "a weapon with no damage has no readout")
	_check(screen._readout != null and screen._readout.text != "", "the workbench card carries a readout line")

	stack.pop(&"profiles")
	_check(not stack.is_open(&"profiles"), "it closes")

	var client := PlaygroundClient.new()
	_check(client._may_edit_profiles(), "offline the player is the server and may edit")
	var bridge := PlaygroundNetBridge.new()
	client.bridge = bridge
	_check(not client._may_edit_profiles(), "connected, nobody may edit until the server says so")
	client._profile_probing = true
	client._on_profile_reply(false, "profile edits need 'cvar'")
	_check(not client._may_edit_profiles(), "a refusal keeps a player out")
	client._profile_probing = true
	client._on_profile_reply(false, "no such profile")
	_check(client._may_edit_profiles(), "any other answer means an admin asked")
	client.bridge = null
	if bridge is Node:
		bridge.free()
	client.free()

	rt.permit = old_permit
	rt.handle_request("uid-admin", DotProfileRuntime.make_request("reset", "npc", "npc_chaser"))
	profiles.npcs.roots = PackedStringArray()
	profiles.npcs.clear_cache()
	stack.queue_free()
	_done()


## The first-person camera's motion, through the client's own `PlaygroundPlayer.present_camera`
## once a physics tick: a drop dips and comes back, a hop does not, a strafe leans each way,
## speed widens the lens, a teleport drops it all, and with every setting at 0 nothing moves.
## Before 2026-10-11 none of it reached the screen (the DotFpsView nothing ran).
func _test_camera_motion() -> void:
	_section("the camera dips, leans and widens, and only when it should")

	var _lobby: DotResult = await playground.change_map(&"pg_flatgrass")
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

	var changed: DotResult = await playground.change_map(&"pg_flatgrass")
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
	var on_lobby: DotResult = await playground.change_map(&"pg_flatgrass")
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
	var on_lobby: DotResult = await playground.change_map(&"pg_flatgrass")
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
