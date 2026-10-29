extends "res://examples/headless_playground_part4.gd"

const WorkshopScript := preload("res://game/playground_workshop.gd")

## An entity is a prop with a script, and the script is loaded by path.
##
## The scene is a bare `RigidBody3D`; the script comes from `meta` and is loaded by PATH, because a mounted pack's `class_name` globals are not registered in the host.
var _erts_at: Vector3
var _erts_npc: DotPropInstance
var _erts_body: PlaygroundEntity
var _erts_mirrored_ent: bool
var _erts_before_count: int
var _erts_refused: DotPropInstance

func _test_entities_run_their_scripts() -> void:
	_section("entities that run their own scripts")

		# On the sandbox, deliberately: an NPC on the bhop map's gapped blocks falls off, and the
		# test would measure the terrain rather than the script.
	var loaded: DotResult = await playground.change_map(&"pg_flatgrass")
	_check(loaded.ok, "the sandbox loads")

	playground.spawn_player(&"bot")

		# Driven with an EMPTY command: `apply_command` leaves the pending command set, so the bot
		# arrives still holding forward and jump and auto-hops away; it also needs the third of a
		# second to fall onto the floor.
	await _drive(&"bot", DotFpsCommand.new(), 60)

	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	_erts_at = Vector3(0.0, 1.2, 0.0)
	_erts_npc = playground.props.spawn(&"npc_wanderer", &"bot", _erts_at)

	_check(_erts_npc != null, "an entity spawns")

	if _erts_npc == null:
		return

	_erts_body = _erts_npc.node as PlaygroundEntity

	_check(_erts_body != null, "and its body is a PlaygroundEntity, not a plain prop")
	_check(
		_erts_body != null and _erts_body.get_script() != null
		and _erts_body.get_script().resource_path
			== PlaygroundSpawnables.script_of(_erts_npc.def),
		"running exactly the script its definition names",
		_erts_body.get_script().resource_path if _erts_body != null else "none"
	)
	_check(
		playground.entities.has(_erts_body),
		"and it is on the list the simulation ticks"
	)

	# `_ready` has already run by the time the script is attached — the spawner adds
	# the body to the world before it emits — so `bind` is what an entity gets
	# instead, and an entity whose world never arrived would sit there being a crate.
	_check(_erts_body != null and _erts_body.game == playground, "it knows its world")
	_check(_erts_body != null and _erts_body.instance == _erts_npc, "and its own row in the spawner")

	# It moves. Everything above is satisfied by an entity that does nothing at all.
	var before := _erts_body.global_position
	var ticks := 0
	var moved := 0.0

	while ticks < 240:
		await get_tree().physics_frame
		ticks += 1
		moved = maxf(moved, before.distance_to(_erts_body.global_position))

	_check(moved > 1.0, "and it walks about", "%.2f m" % moved)
	_check(_erts_body.age > 0.0, "counting simulated time, not wall time",
		"%.2f s" % _erts_body.age)
	await _test_entities_run_their_scripts_2()
	await _test_entities_run_their_scripts_3()

func _test_entities_run_their_scripts_2() -> void:

	# A held entity is furniture. Without that, the NPC fights the physics gun's
	# spring — the gun writes a velocity toward the goal and the NPC writes one
	# toward wherever it was walking — and the prop shudders between them.
	_erts_npc.held_by = &"bot"

	var held_at := _erts_body.global_position
	_erts_body.linear_velocity = Vector3.ZERO

	for _i in range(30):
		await get_tree().physics_frame

	_check(
		held_at.distance_to(_erts_body.global_position) < 0.6,
		"a held entity stops driving itself",
		"%.2f m" % held_at.distance_to(_erts_body.global_position)
	)

	_erts_npc.held_by = &""

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

		# A definition whose script is missing must not leave a body: it would sit there as a crate,
		# indistinguishable from an NPC with nothing to do.
	var broken := DotPropDef.make(&"npc_broken", PlaygroundSpawnables.SCENE_ENTITY)
	broken.meta = {"kind": "entity", "script": "res://game/entities/nope.gd"}
	playground.props.catalogue.add(broken)

	# Both refusals below log at ERROR on purpose.
	_erts_mirrored_ent = DotLog.mirror_to_engine
	DotLog.mirror_to_engine = false
	_erts_before_count = playground.props.world_count()
	_erts_refused = playground.props.spawn(&"npc_broken", &"bot", _erts_at)

	await get_tree().process_frame

func _test_entities_run_their_scripts_3() -> void:

	_check(
		playground.props.world_count() == _erts_before_count,
		"an entity whose script is missing leaves nothing in the world",
		"%d -> %d" % [_erts_before_count, playground.props.world_count()]
	)
	_check(
		_erts_refused == null or not _erts_refused.is_alive(),
		"and its row is dead rather than counted against a budget"
	)

	# One that points at a real script which is not an entity is the same failure by
	# a different route, and it is the one a copy-paste actually produces.
	var wrong := DotPropDef.make(&"npc_wrong", PlaygroundSpawnables.SCENE_ENTITY)
	wrong.meta = {"kind": "entity", "script": "res://game/playground_config.gd"}
	playground.props.catalogue.add(wrong)

	_erts_before_count = playground.props.world_count()
	playground.props.spawn(&"npc_wrong", &"bot", _erts_at)

	await get_tree().process_frame

	_check(
		playground.props.world_count() == _erts_before_count,
		"and so does one whose script is not an entity"
	)
	DotLog.mirror_to_engine = _erts_mirrored_ent

	playground.props.catalogue.remove(&"npc_broken")
	playground.props.catalogue.remove(&"npc_wrong")
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	await get_tree().process_frame

	_check(playground.entities.is_empty(), "clearing the world empties the tick list")
	_done()


## zee-dot-weapons: the pack in the menu, a server's rig firing from the eye, and a shot that shoves a crate.
##
## The aim is the check that matters: without `PlaygroundPlayer.component()` a shot leaves northwards from the feet and every other number is still right.
var _zw_player: PlaygroundPlayer
var _zw_eye: Vector3
var _zw_aim: Vector3
var _zw_crate: DotPropInstance
var _zw_shots: Array[DotShot]
var _zw_moved: int
var _zw_state

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

	_zw_player = playground.players[&"bot"]
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_zw_player.teleport(Vector3(-60.0, 1.0, -60.0), 90.0)
	await get_tree().physics_frame

	var rig := PlaygroundZee.arm(
		_zw_player, playground.weapon_def(&"zee_pistol"), ZeeWeaponRig.Role.SERVER, true,
		playground.tick_rate, playground.current_tick()
	)
	_check(rig != null and _zw_player.zee_rig == rig, "a server's rig goes on the player")
	_check(_zw_player.component(&"DotFpsController") == _zw_player.controller,
		"and the player answers dot-weapon's controller lookup")

	# A crate four metres along the way the player faces.
	_zw_eye = _zw_player.eye_position()
	_zw_aim = _zw_player.aim_direction()
	_zw_crate = playground.props.spawn(&"crate", &"bot", _zw_eye + _zw_aim * 4.0)
	await get_tree().physics_frame

	_zw_shots = []
	_zw_moved = 0
	_zw_state = _zw_player.controller.state

	for i in range(200):
		var held := DotFpsCommand.BUTTON_USER_0 if (i / 20) % 2 == 0 else 0
		var outcome := rig.simulate_tick(
			PlaygroundZee.command_for(held, _zw_state.yaw, _zw_state.pitch, PlaygroundZee.slot_of(rig)),
			playground.current_tick() + i
		) if rig != null else null
		if outcome != null:
			_zw_shots.append_array(outcome.shots)
			_zw_moved += PlaygroundZee.shove_props(_zw_player, outcome, true)
		if _zw_moved > 0:
			break

	_check(not _zw_shots.is_empty(), "it fires", "%d shots" % _zw_shots.size())
	await _test_zee_weapons_2()

func _test_zee_weapons_2() -> void:

	if not _zw_shots.is_empty():
		var first := _zw_shots[0]
		_check(first.origin.distance_to(_zw_eye) < 0.5, "from the eye, not the feet",
			"%.2f m off" % first.origin.distance_to(_zw_eye))
		_check(first.direction.normalized().dot(_zw_aim) > 0.98, "the way the player is facing",
			"dot %.3f" % first.direction.normalized().dot(_zw_aim))

	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(_zw_moved > 0 and _zw_crate != null and _zw_crate.body().linear_velocity.dot(_zw_aim) > 0.5,
		"and with the arena off it shoves the crate it hits, away from the shooter",
		"%.2f m/s along the aim" % (_zw_crate.body().linear_velocity.dot(_zw_aim) if _zw_crate != null else 0.0))

	PlaygroundZee.disarm(_zw_player)
	_check(_zw_player.zee_rig == null, "disarmed, the rig is gone")

	# [b]The pack is written at 64 Hz and this server runs 128[/b]; until dot-weapon scaled
	# a row by its authored_tick_rate every zee weapon here fired, reloaded and deployed
	# twice as fast. A second on an SMG's trigger is as many shots as at 64 Hz.
	var smg := PlaygroundZee.arm(
		_zw_player, playground.weapon_def(&"zee_smg"), ZeeWeaponRig.Role.SERVER, true,
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
				PlaygroundZee.command_for(held, _zw_state.yaw, _zw_state.pitch, PlaygroundZee.slot_of(smg)),
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
	PlaygroundZee.disarm(_zw_player)

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


## The Workshop in solo play: packs a player subscribed to land on the Q menu, only in solo.
var _wx_index: DotContentIndex
var _wx_own_weapons: int
var _wx_own_props: int
var _wx_changes: Array
var _wx_shop: WorkshopScript
var _wx_sidearm_def: PlaygroundWeaponDef
var _wx_menu: PlaygroundSpawnMenu
var _wx_stack: DotScreenStack
var _wx_player: PlaygroundPlayer
var _wx_before: int

func _test_workshop() -> void:
	_section("the workshop")

	# The pack's files, written where a pack would be mounted: user://, which is not res://.
	var root := "user://workshop_fixture"
	DirAccess.make_dir_recursive_absolute(root.path_join("defs"))
	var sidearm := PlaygroundZee.catalogue().get_def(&"pistol").duplicate() as DotWeaponDef
	sidearm.id = &"fixture_sidearm"
	sidearm.display_name = "Fixture Sidearm"
	var crate := DotPropDef.make(&"fixture_crate", "res://game/prop.tscn")
	crate.display_name = "Fixture Crate"
	var npc := DotNpcDef.make(&"fixture_guard", "")
	_check(ResourceSaver.save(sidearm, root + "/defs/sidearm.tres") == OK
		and ResourceSaver.save(crate, root + "/defs/crate.tres") == OK
		and ResourceSaver.save(npc, root + "/defs/guard.tres") == OK, "the fixture pack's definitions are written")

	var provides := {
		"schema": 1, "title": "Fixture Pack", "kinds": ["weapon", "prop", "npc"],
		"categories": [{"id": "sidearm", "name": "Sidearms"}, {"id": "stuff", "name": "Stuff"}],
		"entries": [
			{"kind": "weapon", "id": "fixture_sidearm", "name": "Fixture Sidearm", "def": "defs/sidearm.tres", "slot": 2, "category": "sidearm"},
			{"kind": "prop", "id": "fixture_crate", "name": "Fixture Crate", "def": "defs/crate.tres", "category": "stuff"},
			{"kind": "npc", "id": "fixture_guard", "name": "Fixture Guard", "def": "defs/guard.tres", "category": "stuff"},
		],
	}
	_wx_index = DotContentIndex.new()
	_wx_index.set_session(DotContentIndex.SESSION_SOLO)
	var added := _wx_index.add_pack({
		"content_id": "tmc/fixture-pack", "version": "1.0.0", "prefix": root,
		"session": "solo", "source": "subscription", "provides": provides,
	})
	_check(added.ok, "the pack is in the index", "" if added.ok else added.error.message)

	_wx_own_weapons = playground.weapons.size()
	_wx_own_props = playground.props.catalogue.size()
	_wx_changes = [0]
	playground.workshop_changed.connect(func() -> void: _wx_changes[0] += 1)
	_wx_shop = playground.follow_workshop(_wx_index)
	_check(_wx_changes[0] == 1, "following announces what is already mounted", str(_wx_changes[0]))

	_wx_sidearm_def = playground.weapon_def(&"ws_fixture_sidearm")
	_check(_wx_sidearm_def != null and _wx_sidearm_def.meta.get("pack_title") == "Fixture Pack",
		"solo: the pack weapon is one of the game's weapons, labelled with its pack")
	_check(playground.weapons.size() == _wx_own_weapons + 1, "and the game's own are untouched",
		"%d -> %d" % [_wx_own_weapons, playground.weapons.size()])
	_check(playground.props.catalogue.has(&"ws_fixture_crate"), "solo: the pack prop is in the prop catalogue")
	var guard := playground.props.catalogue.get_prop(&"ws_fixture_guard")
	_check(guard != null and PlaygroundSpawnables.kind_of(guard) == PlaygroundSpawnables.Kind.ENTITY
		and guard.limit_group == &"npcs", "solo: the pack npc is an entity counted as an NPC")
	_check(playground.props.catalogue.size() == _wx_own_props + 2, "and the game's own props are untouched")
	_check(_wx_shop.rows().size() == 3, "three rows for the menu", str(_wx_shop.rows().size()))

	# The menu: a tab per pack, the pack's items grouped by its categories, none on the built-in tabs.
	_wx_menu = PlaygroundSpawnMenu.new()
	_wx_menu.catalogue = playground.props.catalogue
	_wx_menu.weapons = playground.weapons
	_wx_menu.set_pack_rows(_wx_shop.rows())
	add_child(_wx_menu)
	_wx_stack = DotScreenStack.new()
	add_child(_wx_stack)
	var _ready_result := _wx_stack.setup()
	var _registered := _wx_stack.register(_wx_menu)
	var _pushed := _wx_stack.push(_wx_menu.screen_id())
	await get_tree().process_frame

	var pack_tab := PlaygroundSpawnMenu.Tab.size() as PlaygroundSpawnMenu.Tab
	_wx_menu.show_tab(pack_tab)
	await get_tree().process_frame
	await _test_workshop_2()
	await _test_workshop_3()
	_wx_changes = []

func _test_workshop_2() -> void:
	_check(_wx_menu.describe()["pack_tabs"] == ["Fixture Pack"] and _wx_menu.describe()["tab"] == "Fixture Pack",
		"the menu has a tab for the pack", str(_wx_menu.describe()["pack_tabs"]))
	_check(_wx_menu.shown().size() == 3 and _wx_menu.shown().has(&"ws_fixture_sidearm")
		and _wx_menu.shown().has(&"ws_fixture_crate") and _wx_menu.shown().has(&"ws_fixture_guard"),
		"holding its weapon, prop and npc", str(_wx_menu.shown()))
	_check(_wx_menu.card_for(&"ws_fixture_sidearm") != null and _wx_menu.card_for(&"ws_fixture_sidearm").tooltip_text.contains("Fixture Pack"),
		"each card says which pack it is from")
	_wx_menu.show_tab(PlaygroundSpawnMenu.Tab.WEAPONS)
	await get_tree().process_frame
	_check(not _wx_menu.shown().has(&"ws_fixture_sidearm") and _wx_menu.shown().has(&"launcher"),
		"the Weapons tab keeps only the game's own")
	_wx_menu.show_tab(PlaygroundSpawnMenu.Tab.PROPS)
	await get_tree().process_frame
	_check(not _wx_menu.shown().has(&"ws_fixture_crate"), "and so does the Props tab")
	_wx_menu.show_tab(PlaygroundSpawnMenu.Tab.ENTITIES)
	await get_tree().process_frame
	_check(not _wx_menu.shown().has(&"ws_fixture_guard"), "and the Entities tab")

	# Spawning: the prop and the npc through the spawner, the weapon through a rig that fires.
	_wx_player = playground.players[&"bot"]
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_wx_player.teleport(Vector3(-60.0, 1.0, -60.0), 90.0)
	await get_tree().physics_frame
	var spawned_crate := playground.props.spawn(&"ws_fixture_crate", &"bot", _wx_player.eye_position() + _wx_player.aim_direction() * 3.0)
	var spawned_guard := playground.props.spawn(&"ws_fixture_guard", &"bot", _wx_player.eye_position() + _wx_player.aim_direction() * 6.0)
	await get_tree().physics_frame
	_check(spawned_crate != null and spawned_crate.node != null, "the pack prop spawns")
	_check(spawned_guard != null and spawned_guard.node != null
		and str(spawned_guard.node.get_script().resource_path).ends_with("npc_wanderer.gd"),
		"and the pack npc spawns running a script")

	var rig := PlaygroundZee.arm(_wx_player, _wx_sidearm_def, ZeeWeaponRig.Role.SERVER, true,
		playground.tick_rate, playground.current_tick())
	_check(rig != null and rig.arsenal.catalogue.has(&"fixture_sidearm"),
		"the pack weapon arms: the rig holds an id the built-in pack does not have")
	var shots := 0
	var state := _wx_player.controller.state
	for i in range(120):
		var held := DotFpsCommand.BUTTON_USER_0 if (i / 10) % 2 == 0 else 0
		var outcome := rig.simulate_tick(
			PlaygroundZee.command_for(held, state.yaw, state.pitch, PlaygroundZee.slot_of(rig)),
			playground.current_tick() + i
		) if rig != null else null
		if outcome != null:
			shots += outcome.shots.size()
	_check(shots > 0, "and it fires", str(shots))
	_check(PlaygroundZee.catalogue().has(&"fixture_sidearm") == false,
		"without leaking into the table a server reads")
	PlaygroundZee.disarm(_wx_player)
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	# A pack mounted later arrives; a map pack lists on the map menu.
	_wx_before = _wx_changes[0]
	var _late := _wx_index.add_pack({
		"content_id": "tmc/fixture-maps", "version": "1.0.0", "prefix": "res://",
		"session": "solo", "source": "subscription",
		"provides": {"schema": 1, "title": "Fixture Maps", "kinds": ["map"], "entries": [
			{"kind": "map", "id": "ws_lobby", "name": "Fixture Lobby", "scene": "maps/pg_flatgrass.tscn", "map_kind": "sandbox"},
			{"kind": "map", "id": "ws_arena", "name": "Fixture Arena", "scene": "maps/pg_flatgrass.tscn", "map_kind": "arena"},
		]},
	})
	_check(not playground.maps.catalogue.available().filter(func(m: DotMapDef) -> bool: return m.id == &"ws_lobby").is_empty(),
		"solo: a sandbox map pack is on the map list")
	_check(playground.maps.catalogue.available().filter(func(m: DotMapDef) -> bool: return m.id == &"ws_arena").is_empty(),
		"and a map of a kind the game does not accept is not")
	_check(_wx_changes[0] == _wx_before, "a pack with nothing for the menu does not redraw it")

func _test_workshop_3() -> void:

	# Online: all of it is gone, from every list, and comes back with solo. The pack's tab is
	# the open one, so the fall back to Props is what is being checked.
	_wx_menu.show_tab(PlaygroundSpawnMenu.Tab.size() as PlaygroundSpawnMenu.Tab)
	_wx_index.set_session(DotContentIndex.SESSION_ONLINE)
	_check(playground.weapon_def(&"ws_fixture_sidearm") == null and playground.weapons.size() == _wx_own_weapons,
		"online: the pack weapon is not on the menu")
	_check(not playground.props.catalogue.has(&"ws_fixture_crate") and not playground.props.catalogue.has(&"ws_fixture_guard")
		and playground.props.catalogue.size() == _wx_own_props, "online: the pack props and npcs are gone")
	_check(_wx_shop.rows().is_empty(), "online: no rows")
	_check(playground.maps.catalogue.available().filter(func(m: DotMapDef) -> bool: return m.id == &"ws_lobby").is_empty(),
		"online: the pack map is gone")
	_wx_menu.set_pack_rows(_wx_shop.rows())
	await get_tree().process_frame
	_check(_wx_menu.describe()["pack_tabs"] == [] and _wx_menu.describe()["tab"] == "PROPS",
		"online: the menu has no pack tab, and the one that was open fell back")
	_check(_wx_changes[0] > _wx_before, "and the session change was announced")
	_wx_index.set_session(DotContentIndex.SESSION_SOLO)
	_check(playground.weapon_def(&"ws_fixture_sidearm") != null and playground.props.catalogue.has(&"ws_fixture_crate"),
		"back in solo they return")

	# The real zee pack, as a fixture of its own: all 27 weapons, grouped by its categories.
	# Found through addons/zee_weapons rather than as ../zee-dot-weapons: the link points
	# at the sibling checkout on a dev box and into .deps/ under CI, which clones no siblings.
	var zee_link := ProjectSettings.globalize_path("res://addons/zee_weapons")
	var zee_dir := ProjectSettings.globalize_path("res://").path_join("../zee-dot-weapons").simplify_path()
	var addons_dir := DirAccess.open(zee_link.get_base_dir())
	if addons_dir != null and addons_dir.is_link(zee_link):
		var target := addons_dir.read_link(zee_link)
		if target.is_relative_path():
			target = zee_link.get_base_dir().path_join(target)
		zee_dir = target.simplify_path().get_base_dir().get_base_dir()
	if FileAccess.file_exists(zee_dir.path_join("provides.json")):
		var zee_provides: Variant = JSON.parse_string(FileAccess.get_file_as_string(zee_dir.path_join("provides.json")))
		var _zee := _wx_index.add_pack({
			"content_id": "gamemann/zee-dot-weapons", "version": "1.0.0", "prefix": zee_dir,
			"session": "solo", "source": "subscription", "provides": zee_provides,
		})
		var zee_rows := _wx_shop.rows().filter(func(r: Dictionary) -> bool: return r["pack_title"] == "Zee Weapons")
		_check(zee_rows.size() == 27, "zee-dot-weapons' own provides.json lists 27 weapons", str(zee_rows.size()))
		_check(zee_rows.all(func(r: Dictionary) -> bool: return playground.weapon_def(r["id"]) != null),
			"each a weapon the game can arm")
		var smg := playground.weapon_def(&"ws_smg")
		var smg_rig := PlaygroundZee.arm(_wx_player, smg, ZeeWeaponRig.Role.SERVER, true,
			playground.tick_rate, playground.current_tick())
		_check(smg_rig != null and smg_rig.arsenal.catalogue.has(&"smg"), "and a pack weapon that shares a built-in id arms with the built-in's art and rules")
		PlaygroundZee.disarm(_wx_player)
	else:
		_check(false, "zee-dot-weapons is next to this game", zee_dir)

	_wx_menu.queue_free()
	_wx_stack.queue_free()
	playground.unfollow_workshop()
	_check(playground.weapon_def(&"ws_fixture_sidearm") == null and not playground.props.catalogue.has(&"ws_fixture_crate")
		and playground.weapons.size() == _wx_own_weapons and playground.props.catalogue.size() == _wx_own_props,
		"unfollowing leaves the game's lists as they were")
	_done()


## Weapons: a script loaded by path, held rather than spawned.
var _w_defs: Array[PlaygroundWeaponDef]
var _w_launcher: WeaponScript
var _w_fired: DotResult
var _w_stuck: DotPropInstance

func _test_weapons() -> void:
	_section("weapons")

	_w_defs = PlaygroundWeapons.built_in()

	_check(_w_defs.size() >= 3, "the build ships an arsenal", "%d" % _w_defs.size())
	_check(
		# Not the weapons a linked spawn provider taught the game (`meta.provider`).
		playground.weapons.filter(func(d: Variant) -> bool: return not d.meta.has("provider")).size()
			== _w_defs.size() + PlaygroundZee.defs().size(),
		"and the game offers it, with zee-dot-weapons after it"
	)

	for def in _w_defs:
		_check(def.validate().ok, "'%s' is a usable definition" % def.id)

	_w_launcher = PlaygroundWeapons.make(
		PlaygroundWeapons.find(_w_defs, &"launcher")
	)

	_check(_w_launcher != null, "a weapon is built from its definition")
	_check(
		_w_launcher != null and _w_launcher.get_script().resource_path
			== PlaygroundWeapons.find(_w_defs, &"launcher").script_path,
		"running exactly the script it names"
	)

	# The two ways a catalogue entry is wrong, and neither may hand back a working-
	# looking weapon: a base `PlaygroundWeapon` whose buttons do nothing is
	# indistinguishable from a weapon that is fine and pointed at nothing.
	var mirrored_wpn := DotLog.mirror_to_engine
	DotLog.mirror_to_engine = false
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
	DotLog.mirror_to_engine = mirrored_wpn

	# The launcher fires whatever the menu armed, which is what saves it having a
	# second list of ammunition and a second way to choose from it.
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	_w_launcher.equip(playground, PlaygroundWeapons.find(_w_defs, &"launcher"))
	_w_launcher.wielder = &"bot"
	_w_launcher.armed = &"beach_ball"

	_w_fired = _w_launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

	_check(_w_fired.ok, "the launcher fires")
	await _test_weapons_2()
	_test_weapons_3()

func _test_weapons_2() -> void:

	if _w_fired.ok:
		var shot := _w_fired.value as DotPropInstance

		_check(shot.def.id == &"beach_ball", "the prop the menu armed")
		_check(
			shot.body().linear_velocity.length() > 10.0,
			"at a muzzle velocity",
			"%.1f m/s" % shot.body().linear_velocity.length()
		)

		# A muzzle velocity, not an impulse. An impulse is divided by the mass, which
		# is right for a punt and exactly wrong here: a launcher whose boulder leaves
		# at a fortieth of the speed of its ball is one nobody can aim.
		_w_launcher.armed = &"boulder"

		var heavy := _w_launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

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
	_w_launcher.armed = &"nothing_like_this"

	var fallback := _w_launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

	_check(fallback.ok, "an armed prop that no longer exists falls back")

	# The impulse gun shoves what is near it, and leaves frozen props alone: freezing
	# is how a builder says "this is finished", and a blast that undid it would make
	# the two tools fight.
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	var loose := playground.props.spawn(&"crate", &"bot", Vector3(2.0, 1.0, 0.0))
	_w_stuck = playground.props.spawn(&"crate", &"bot", Vector3(-2.0, 1.0, 0.0))

	DotPhysGun.set_frozen(_w_stuck, true)

	var impulse := PlaygroundWeapons.make(PlaygroundWeapons.find(_w_defs, &"impulse"))
	impulse.equip(playground, PlaygroundWeapons.find(_w_defs, &"impulse"))
	impulse.wielder = &"bot"

	loose.body().linear_velocity = Vector3.ZERO

	var blast := impulse.primary(null, Vector3.ZERO, Vector3.FORWARD)

		# Two steps, not one: an impulse is not readable in `linear_velocity` until the step that
		# consumes it has run, and one physics frame lands before that step.
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(blast.ok and int(blast.value) >= 1, "the impulse gun moves something")
	_check(
		loose.body().linear_velocity.length() > 1.0,
		"a loose prop is shoved",
		"%.1f m/s" % loose.body().linear_velocity.length()
	)

func _test_weapons_3() -> void:
	_check(
		_w_stuck.body().linear_velocity.length() < 0.5,
		"and a frozen one is left alone",
		"%.1f m/s" % _w_stuck.body().linear_velocity.length()
	)

	# The remover's right click clears what you own, and goes through the spawner so
	# the budget it frees is real.
	var remover := PlaygroundWeapons.make(PlaygroundWeapons.find(_w_defs, &"remover"))
	remover.equip(playground, PlaygroundWeapons.find(_w_defs, &"remover"))
	remover.wielder = &"bot"

	var cleared := remover.secondary(null, Vector3.ZERO, Vector3.FORWARD)

	_check(cleared.ok and int(cleared.value) >= 2, "the remover clears your props")
	_check(playground.props.player_count(&"bot") == 0, "and the budget goes with them")

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()
