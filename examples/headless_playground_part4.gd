extends "res://examples/headless_playground_part3.gd"

## The chaser goes through dot-npc's perception, not "the nearest player this tick".
##
## Every check fails on the old chaser, which called `nearest_player()` every tick and so turned back and forth between two close players and forgot one mid-stride. Driven by hand, because the decision is under test and not the walking.
var _acc_spawned
var _acc_chaser

func _test_a_chaser_commits(playground: Playground) -> void:
	var at := Vector3(0.0, 2.0, 0.0)
	_acc_spawned = playground.props.spawn(&"npc_chaser", &"bot", at)

	if _acc_spawned == null:
		_check(false, "a chaser spawns for the commitment check")
		return

	_acc_chaser = _acc_spawned.node as PlaygroundEntity

	_check(_acc_chaser.npc != null, "an entity has a dot-npc row")
	_check(
		_acc_chaser.npc.def.sight_range == 40.0,
		"whose perception comes from the catalogue rather than from the script",
		"%.0f m" % _acc_chaser.npc.def.sight_range
	)

	# Two candidates a fraction of a metre apart, swapping which is marginally nearer
	# every tick. This is the shape the old chaser flickered on.
	var near := DotNpcSenses.Candidate.new(&"one", Vector3(0, 2, -10), &"player")
	var also := DotNpcSenses.Candidate.new(&"two", Vector3(0, 2, -10.4), &"player")

	playground.npc_candidates = [near, also]

	var first := playground.npc_senses.update_target(
		_acc_chaser.npc, playground.npc_candidates, 0.0, 8
	)
	var switches := 0
	var last := first

	for tick in 40:
		near.position = Vector3(0, 2, -10.0 - (0.5 if tick % 2 == 0 else 0.0))
		also.position = Vector3(0, 2, -10.0 - (0.0 if tick % 2 == 0 else 0.5))

		var now := playground.npc_senses.update_target(
			_acc_chaser.npc, playground.npc_candidates, float(tick) * 0.1, 8
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
		playground.npc_senses.update_target(_acc_chaser.npc, [], 5.0, 8) != &"",
		"and keeps chasing one that stepped out of sight",
		"a doorway would otherwise be a perfect escape"
	)
	_check(
		playground.npc_senses.update_target(_acc_chaser.npc, [], 20.0, 8) == &"",
		"and gives up once the grace has expired"
	)

	# A target that disconnects. The grace would otherwise walk the NPC to an empty
	# corner for two and a half seconds, steering at a position nobody is at.
	playground.npc_candidates = [
		DotNpcSenses.Candidate.new(&"ghost", Vector3(0, 2, -6), &"player")
	]
	_test_a_chaser_commits_2(playground)
	_acc_spawned = null
	_acc_chaser = null

func _test_a_chaser_commits_2(playground: Playground) -> void:
	playground.npc_senses.update_target(_acc_chaser.npc, playground.npc_candidates, 21.0, 8)

	_check(_acc_chaser.npc.target_id == &"ghost", "a chaser can commit to anybody it sees")
	_check(
		_acc_chaser.target() == null and _acc_chaser.npc.target_id == &"",
		"and drops one that is not a player in this game any more",
		"or it walks to an empty corner for the whole grace period"
	)

	playground.props.remove(_acc_spawned.instance_id)
	playground.npc_candidates = []

	_test_a_hunter_decides(playground)


## The same NPC with a **decision** instead of an `if`: dot-npc-ai's state machine and characteristics table.
##
## `npc_chaser` stays in the catalogue; this one adds a reaction time, a character per NPC and a machine whose transitions are the design.
var _ahd_spawned
var _ahd_hunter
var _ahd_machine: DotNpcAiMachine

func _test_a_hunter_decides(playground: Playground) -> void:
	_ahd_spawned = playground.props.spawn(&"npc_hunter", &"bot", Vector3(0.0, 2.0, 0.0))

	if _ahd_spawned == null:
		_check(false, "a hunter spawns")
		return

	_ahd_hunter = _ahd_spawned.node as PlaygroundEntity

	_check(_ahd_hunter.npc != null, "a hunter has a dot-npc row too")
	_check(
		_ahd_hunter.get("machine") != null,
		"and a state machine rather than a hand-written if"
	)
	_check(
		_ahd_hunter.get("character") != null,
		"and a character, which is what a difficulty setting is instead of"
	)

	var character: DotNpcAiCharacter = _ahd_hunter.get("character")

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
	_ahd_machine = _ahd_hunter.get("machine")
	_check(
		_ahd_machine.current() == &"patrol",
		"a hunter starts on patrol (%s)" % String(_ahd_machine.current())
	)

	# Somebody walks into view. It must NOT go straight to chasing: the reaction time is spent in ALERT.
	# A REAL player, not incidental: `PlaygroundEntity.target` resolves a candidate through
	# `game.players` and clears it when it finds none, so a bare candidate tests that clearing.
	var seen := playground.add_player(&"seen", "Seen")
	seen.teleport(Vector3(0.0, 2.0, -8.0))

	playground.npc_candidates = [
		DotNpcSenses.Candidate.new(&"seen", Vector3(0, 2, -8), &"player")
	]
	playground.npc_senses.update_target(
		_ahd_hunter.npc, playground.npc_candidates, 0.0, 8
	)
	_ahd_hunter.entity_tick(1.0 / 128.0)

	_check(
		_ahd_machine.current() == &"alert",
		"and turns to look before it commits (%s)" % String(_ahd_machine.current()),
		"reaction time is what makes it an opponent rather than a target"
	)
	_test_a_hunter_decides_2(playground)
	_ahd_spawned = null
	_ahd_hunter = null
	_ahd_machine = null

func _test_a_hunter_decides_2(playground: Playground) -> void:

	# And then it does commit, once the reaction time has passed.
	for _step in range(int(128.0 * 1.5)):
		_ahd_hunter.entity_tick(1.0 / 128.0)

	_check(
		_ahd_machine.current() == &"chase",
		"and chases once its reaction time has passed (%s)" % String(_ahd_machine.current())
	)

	# The target leaves. It searches where they were rather than stopping dead — an NPC
	# you escape by stepping behind a crate is one nobody has to run from.
	playground.npc_candidates = []
	_ahd_hunter.npc.target_id = &""

	_ahd_hunter.entity_tick(1.0 / 128.0)
	_check(
		_ahd_machine.current() == &"lost",
		"and goes looking when it loses them (%s)" % String(_ahd_machine.current())
	)

	playground.props.remove(_ahd_spawned.instance_id)
	playground.npc_candidates = []
	playground.remove_player(&"seen")


# Limits per kind, the tool gun, armed NPCs

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

	# The hook, against a scratch folder shaped like res://addons
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
	var mirrored_add := DotLog.mirror_to_engine
	DotLog.mirror_to_engine = false
	var count := addons.scan(host, true, root)
	DotLog.mirror_to_engine = mirrored_add
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

	# The real folder: dot_core has no hook, natural-disasters has an adapter
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
		_check(hook.manager.get("players_fn").is_valid() and hook.manager.get("player_push_fn").is_valid(),
			"and players are wired to be pushed by it")
		hook.manager.call("stop")

		# Undo takes a disaster away like a prop, in spawn order, with a cue.
		var heard: Array = []
		playground.undone.connect(func(who: StringName, _at: Vector3) -> void: heard.append(who))
		var announced: Array = []
		playground.addon_message.connect(func(a: String, b: Dictionary) -> void: announced.append(a))
		playground.props.spawn(&"barrel", &"bot", Vector3(0, 2, 0))
		for kind in ["tornado", "blizzard"]:
			var begun := playground.activate_addon_item("pg_natural_disasters/" + kind, 0, Vector3(30, 0, 30), &"bot")
			_check(begun.ok and bool(hook.manager.call("is_active", StringName(kind))), "%s runs" % kind)
			heard.clear()
			announced.clear()
			_check(playground.undo(&"bot") and not bool(hook.manager.call("is_active", StringName(kind))),
				"undo stops the %s" % kind)
			_check(heard == [&"bot"] and announced.has(PlaygroundAddons.UNDO_ADDON),
				"and the cue is asked for and announced to the clients")
		var count_before: int = playground.props.world_count()
		_check(playground.undo(&"bot") and playground.props.world_count() == count_before - 1,
			"and the prop spawned before them is the next to go")
		_check(not playground.undo(&"bot"), "then nothing is left to undo")
		var told_heard: Array = []
		playground.undone.connect(func(who: StringName, at: Vector3) -> void: told_heard.append([who, at]))
		_check(playground.addons.deliver(PlaygroundAddons.UNDO_ADDON, {"undo": "me", "at": [1.0, 2.0, 3.0]})
			and told_heard == [[&"me", Vector3(1, 2, 3)]], "a client hears who undid, and where")

	# The waypoint tool
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

	# A route is walked
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

	# The NPC spawner tool
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

	# A spawn point
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


## Spawn providers: a pack's `spawn_provider.gd` fills the Addons tab; server-side gives and spawns.
var _sp_fixtures: String
var _sp_pack_script: GDScript
var _sp_none: PlaygroundAddons
var _sp_addons: PlaygroundAddons
var _sp_pmenu: PlaygroundSpawnMenu
var _sp_pstack: DotScreenStack
var _sp_ptabs: TabBar
var _sp_npc_tab
var _sp_via: PlaygroundAddons
var _sp_at
var _sp_prior_addons

func _test_spawn_providers() -> void:
	_section("spawn providers")
	await _sandbox_floor()
	_sp_fixtures = "res://examples/fixtures"
	_sp_pack_script = load(_sp_fixtures + "/spawn_pack/spawn_provider.gd")
	_sp_pack_script.set("weapon_id", String(playground.weapons[0].id))
	_sp_pack_script.set("custom_calls", [])

	# No pack installed: nothing found, nothing breaks.
	_sp_none = PlaygroundAddons.new()
	_check(_sp_none.scan_providers(playground, "res://examples/fixtures/spawn_pack_none") == 0
		and _sp_none.items().is_empty(), "with no provider anywhere the menu is simply empty")

	_sp_addons = PlaygroundAddons.new()
	var found := _sp_addons.scan_providers(playground, _sp_fixtures)
	_check(found == 1 and _sp_addons.provider_count() == 1,
		"one valid provider is found, the one without spawn_entries is refused", str(found))
	_check(_sp_addons.items().size() == 7, "bad entries (no id, bad spawn, not a dictionary) are skipped",
		str(_sp_addons.items().size()))
	var rows := _sp_addons.describe_items()
	var cats := {}
	for row in rows:
		cats[row["category"]] = true
	_check(cats.has("Weapons") and cats.has("NPCs") and cats.has("Bots"),
		"the menu rows carry the pack's categories", str(cats.keys()))
	_check(_sp_addons.find("spawn_pack/test_guard").kind == "npc", "and the kind")

	# The menu: own tabs, shown only while a provider has entries of that kind.
	_sp_pmenu = PlaygroundSpawnMenu.new()
	_sp_pmenu.catalogue = playground.props.catalogue
	_sp_pmenu.weapons = playground.weapons
	add_child(_sp_pmenu)
	_sp_pstack = DotScreenStack.new()
	add_child(_sp_pstack)
	_sp_pstack.setup()
	_sp_pstack.register(_sp_pmenu)
	_sp_pstack.push(_sp_pmenu.screen_id())
	await get_tree().process_frame
	_sp_ptabs = _sp_pmenu.find_child("Tabs", true, false)
	_sp_npc_tab = int(PlaygroundSpawnMenu.Tab.NPCS)
	var gun_tab := int(PlaygroundSpawnMenu.Tab.PACK_WEAPONS)
	_check(_sp_ptabs.is_tab_hidden(_sp_npc_tab) and _sp_ptabs.is_tab_hidden(gun_tab),
		"with no provider entries the NPCs and Pack Weapons tabs are hidden")
	_sp_pmenu.addon_items = rows
	_check(not _sp_ptabs.is_tab_hidden(_sp_npc_tab) and not _sp_ptabs.is_tab_hidden(gun_tab),
		"with provider entries both tabs appear")
	_sp_pmenu.show_tab(PlaygroundSpawnMenu.Tab.PACK_WEAPONS)
	await get_tree().process_frame
	_check(_sp_pmenu.shown().size() == 2 and _sp_pmenu.card_for(&"spawn_pack/test_gun") != null,
		"Pack Weapons lists the weapon entries only", str(_sp_pmenu.shown()))
	_check(_sp_pmenu.card_for(&"spawn_pack/test_gun").icon != null, "an entry without an icon gets a generated tile")
	var asked: Array = []
	_sp_pmenu.addon_item_chosen.connect(func(key: String) -> void: asked.append(key))
	_sp_pmenu.card_for(&"spawn_pack/test_gun").pressed.emit()
	_check(asked == ["spawn_pack/test_gun"], "clicking a card asks for the entry by key (the authority path)")
	_sp_pmenu.show_tab(PlaygroundSpawnMenu.Tab.NPCS)
	await get_tree().process_frame
	_check(_sp_pmenu.shown().size() == 5 and _sp_pmenu.card_for(&"spawn_pack/test_bot") != null,
		"NPCs lists npc and bot entries", str(_sp_pmenu.shown()))
	_sp_pmenu._search = "guard"
	_sp_pmenu._rebuild_grid()
	await get_tree().process_frame
	_check(_sp_pmenu.shown() == [&"spawn_pack/test_guard"], "and the search box filters them", str(_sp_pmenu.shown()))
	_sp_pmenu._search = ""
	_sp_pmenu.show_tab(PlaygroundSpawnMenu.Tab.ADDONS)
	await _test_spawn_providers_2()
	_test_spawn_providers_3()
	_sp_pack_script = null
	_sp_none = null
	_sp_addons = null
	_sp_pmenu = null
	_sp_pstack = null
	_sp_ptabs = null
	_sp_npc_tab = null
	_sp_via = null
	_sp_at = null
	_sp_prior_addons = null

func _test_spawn_providers_2() -> void:
	await get_tree().process_frame
	_check(_sp_pmenu.shown().is_empty(), "the Addons tab no longer repeats them")
	_sp_pmenu.show_tab(PlaygroundSpawnMenu.Tab.NPCS)
	await get_tree().process_frame
	_sp_pmenu.addon_items = []
	_check(_sp_ptabs.is_tab_hidden(_sp_npc_tab) and _sp_ptabs.current_tab == int(PlaygroundSpawnMenu.Tab.PROPS),
		"losing the entries hides the tab and falls back to Props")
	_sp_pmenu.queue_free()
	_sp_pstack.queue_free()

	# Registry discovery.
	var reg: Object = _sp_pack_script.new()
	DotRegistry.register(&"playground.spawn_provider.reg_pack", reg)
	_sp_via = PlaygroundAddons.new()
	_sp_via.scan_providers(playground, _sp_fixtures + "/spawn_pack_none")
	DotRegistry.unregister(&"playground.spawn_provider.reg_pack")
	_check(_sp_via.find("reg_pack/test_gun") != null, "a provider registered in DotRegistry is found too")

	# Activation: server-authoritative.
	var bot: PlaygroundPlayer = playground.players[&"bot"]
	_sp_at = bot.global_position + Vector3(0, 0, -6)
	_sp_prior_addons = playground.addons
	playground.addons = _sp_addons
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var picked: Array = []
	var on_pick := func(who: StringName, w: StringName) -> void: picked.append([who, w])
	playground.weapon_picked_up.connect(on_pick)
	var gave := playground.activate_addon_item("spawn_pack/test_gun", 0, _sp_at, &"bot")
	_check(gave.ok and picked.size() == 1 and picked[0][1] == playground.weapons[0].id,
		"a weapon entry goes through the pickup path (the bridge charges and arms it)")
	_check(not playground.activate_addon_item("spawn_pack/unknown_gun", 0, _sp_at, &"bot").ok,
		"a weapon the catalogue does not know is refused")
	_check(not playground.activate_addon_item("spawn_pack/test_gun", 0, _sp_at, &"nobody").ok
		and picked.size() == 1, "an unknown player is refused")
	playground.weapon_picked_up.disconnect(on_pick)

	var guards := playground.activate_addon_item("spawn_pack/test_guard", 0, _sp_at, &"bot")
	var soldiers := 0
	for prop in playground.props.all_props():
		if prop.def != null and String(prop.def.id) == "npc_soldier":
			soldiers += 1
	_check(guards.ok and soldiers == 2, "an npc entry spawns through the prop spawner, count 2", str(soldiers))

	var called := playground.activate_addon_item("spawn_pack/test_bot", 0, _sp_at, &"bot")
	var calls: Array = _sp_pack_script.get("custom_calls")
	_check(called.ok and calls.size() == 1 and calls[0]["kind"] == "bot" and calls[0]["player_id"] == &"bot",
		"a Callable entry is called with the context dictionary")

	calls.clear()
	var viafn := playground.activate_addon_item("spawn_pack/stat_npc", 0, _sp_at, &"bot")
	_check(viafn.ok and calls.size() == 1 and calls[0]["kind"] == "npc",
		"spawn_fn is the action when spawn is a stats Dictionary")
	_check(not playground.activate_addon_item("spawn_pack/stat_only", 0, _sp_at, &"bot").ok,
		"a Dictionary spawn with no spawn_fn is listed but refused")

	for i in PlaygroundAddons.MAX_SCENE_SPAWNS + 2:
		playground.activate_addon_item("spawn_pack/scene_npc", 0, _sp_at, &"bot")
	var scene_made := 0
	for child in playground.world.get_children():
		if child.has_meta(&"spawn_provider_owner"):
			scene_made += 1
	_check(scene_made == PlaygroundAddons.MAX_SCENE_SPAWNS, "scene spawns are capped per player", str(scene_made))

func _test_spawn_providers_3() -> void:
	for child in playground.world.get_children():
		if child.has_meta(&"spawn_provider_owner"):
			child.free()

	var client_side := playground.authoritative
	playground.authoritative = false
	_check(not playground.activate_addon_item("spawn_pack/test_guard", 0, _sp_at, &"bot").ok,
		"a client never runs an entry")
	playground.authoritative = client_side
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	# A static on the fixture's script outlives the suite; what it recorded points back into the game.
	_sp_pack_script.set("custom_calls", [])
	# Each scan builds lambdas that capture their item and the scanner: release() breaks that cycle.
	playground.addons = _sp_prior_addons
	for scanner: PlaygroundAddons in [_sp_none, _sp_addons, _sp_via]:
		scanner.release()
	_done()


## A zee grenade is thrown, flies, bounces, goes off, and NPCs get out from under it.
##
## Every check goes through the real path: a rig, its outcome, and `player_shots_fired`, which the server's bridge and the offline client both call.
