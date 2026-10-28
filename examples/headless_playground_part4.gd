extends "res://examples/headless_playground_part3.gd"

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


## Spawn providers: a pack's `spawn_provider.gd` fills the Addons tab; server-side gives and spawns.
func _test_spawn_providers() -> void:
	_section("spawn providers")
	await _sandbox_floor()
	var fixtures := "res://examples/fixtures"
	var pack_script: GDScript = load(fixtures + "/spawn_pack/spawn_provider.gd")
	pack_script.set("weapon_id", String(playground.weapons[0].id))
	pack_script.set("custom_calls", [])

	# No pack installed: nothing found, nothing breaks.
	var none := PlaygroundAddons.new()
	_check(none.scan_providers(playground, "res://examples/fixtures/spawn_pack_none") == 0
		and none.items().is_empty(), "with no provider anywhere the menu is simply empty")

	var addons := PlaygroundAddons.new()
	var found := addons.scan_providers(playground, fixtures)
	_check(found == 1 and addons.provider_count() == 1,
		"one valid provider is found, the one without spawn_entries is refused", str(found))
	_check(addons.items().size() == 7, "bad entries (no id, bad spawn, not a dictionary) are skipped",
		str(addons.items().size()))
	var rows := addons.describe_items()
	var cats := {}
	for row in rows:
		cats[row["category"]] = true
	_check(cats.has("Weapons") and cats.has("NPCs") and cats.has("Bots"),
		"the menu rows carry the pack's categories", str(cats.keys()))
	_check(addons.find("spawn_pack/test_guard").kind == "npc", "and the kind")

	# The menu: own tabs, shown only while a provider has entries of that kind.
	var pmenu := PlaygroundSpawnMenu.new()
	pmenu.catalogue = playground.props.catalogue
	pmenu.weapons = playground.weapons
	add_child(pmenu)
	var pstack := DotScreenStack.new()
	add_child(pstack)
	pstack.setup()
	pstack.register(pmenu)
	pstack.push(pmenu.screen_id())
	await get_tree().process_frame
	var ptabs: TabBar = pmenu.find_child("Tabs", true, false)
	var npc_tab := int(PlaygroundSpawnMenu.Tab.NPCS)
	var gun_tab := int(PlaygroundSpawnMenu.Tab.PACK_WEAPONS)
	_check(ptabs.is_tab_hidden(npc_tab) and ptabs.is_tab_hidden(gun_tab),
		"with no provider entries the NPCs and Pack Weapons tabs are hidden")
	pmenu.addon_items = rows
	_check(not ptabs.is_tab_hidden(npc_tab) and not ptabs.is_tab_hidden(gun_tab),
		"with provider entries both tabs appear")
	pmenu.show_tab(PlaygroundSpawnMenu.Tab.PACK_WEAPONS)
	await get_tree().process_frame
	_check(pmenu.shown().size() == 2 and pmenu.card_for(&"spawn_pack/test_gun") != null,
		"Pack Weapons lists the weapon entries only", str(pmenu.shown()))
	_check(pmenu.card_for(&"spawn_pack/test_gun").icon != null, "an entry without an icon gets a generated tile")
	var asked: Array = []
	pmenu.addon_item_chosen.connect(func(key: String) -> void: asked.append(key))
	pmenu.card_for(&"spawn_pack/test_gun").pressed.emit()
	_check(asked == ["spawn_pack/test_gun"], "clicking a card asks for the entry by key (the authority path)")
	pmenu.show_tab(PlaygroundSpawnMenu.Tab.NPCS)
	await get_tree().process_frame
	_check(pmenu.shown().size() == 5 and pmenu.card_for(&"spawn_pack/test_bot") != null,
		"NPCs lists npc and bot entries", str(pmenu.shown()))
	pmenu._search = "guard"
	pmenu._rebuild_grid()
	await get_tree().process_frame
	_check(pmenu.shown() == [&"spawn_pack/test_guard"], "and the search box filters them", str(pmenu.shown()))
	pmenu._search = ""
	pmenu.show_tab(PlaygroundSpawnMenu.Tab.ADDONS)
	await get_tree().process_frame
	_check(pmenu.shown().is_empty(), "the Addons tab no longer repeats them")
	pmenu.show_tab(PlaygroundSpawnMenu.Tab.NPCS)
	await get_tree().process_frame
	pmenu.addon_items = []
	_check(ptabs.is_tab_hidden(npc_tab) and ptabs.current_tab == int(PlaygroundSpawnMenu.Tab.PROPS),
		"losing the entries hides the tab and falls back to Props")
	pmenu.queue_free()
	pstack.queue_free()

	# Registry discovery.
	var reg: Object = pack_script.new()
	DotRegistry.register(&"playground.spawn_provider.reg_pack", reg)
	var via := PlaygroundAddons.new()
	via.scan_providers(playground, fixtures + "/spawn_pack_none")
	DotRegistry.unregister(&"playground.spawn_provider.reg_pack")
	_check(via.find("reg_pack/test_gun") != null, "a provider registered in DotRegistry is found too")

	# Activation: server-authoritative.
	var bot: PlaygroundPlayer = playground.players[&"bot"]
	var at := bot.global_position + Vector3(0, 0, -6)
	var prior_addons := playground.addons
	playground.addons = addons
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var picked: Array = []
	var on_pick := func(who: StringName, w: StringName) -> void: picked.append([who, w])
	playground.weapon_picked_up.connect(on_pick)
	var gave := playground.activate_addon_item("spawn_pack/test_gun", 0, at, &"bot")
	_check(gave.ok and picked.size() == 1 and picked[0][1] == playground.weapons[0].id,
		"a weapon entry goes through the pickup path (the bridge charges and arms it)")
	_check(not playground.activate_addon_item("spawn_pack/unknown_gun", 0, at, &"bot").ok,
		"a weapon the catalogue does not know is refused")
	_check(not playground.activate_addon_item("spawn_pack/test_gun", 0, at, &"nobody").ok
		and picked.size() == 1, "an unknown player is refused")
	playground.weapon_picked_up.disconnect(on_pick)

	var guards := playground.activate_addon_item("spawn_pack/test_guard", 0, at, &"bot")
	var soldiers := 0
	for prop in playground.props.all_props():
		if prop.def != null and String(prop.def.id) == "npc_soldier":
			soldiers += 1
	_check(guards.ok and soldiers == 2, "an npc entry spawns through the prop spawner, count 2", str(soldiers))

	var called := playground.activate_addon_item("spawn_pack/test_bot", 0, at, &"bot")
	var calls: Array = pack_script.get("custom_calls")
	_check(called.ok and calls.size() == 1 and calls[0]["kind"] == "bot" and calls[0]["player_id"] == &"bot",
		"a Callable entry is called with the context dictionary")

	calls.clear()
	var viafn := playground.activate_addon_item("spawn_pack/stat_npc", 0, at, &"bot")
	_check(viafn.ok and calls.size() == 1 and calls[0]["kind"] == "npc",
		"spawn_fn is the action when spawn is a stats Dictionary")
	_check(not playground.activate_addon_item("spawn_pack/stat_only", 0, at, &"bot").ok,
		"a Dictionary spawn with no spawn_fn is listed but refused")

	for i in PlaygroundAddons.MAX_SCENE_SPAWNS + 2:
		playground.activate_addon_item("spawn_pack/scene_npc", 0, at, &"bot")
	var scene_made := 0
	for child in playground.world.get_children():
		if child.has_meta(&"spawn_provider_owner"):
			scene_made += 1
	_check(scene_made == PlaygroundAddons.MAX_SCENE_SPAWNS, "scene spawns are capped per player", str(scene_made))
	for child in playground.world.get_children():
		if child.has_meta(&"spawn_provider_owner"):
			child.free()

	var client_side := playground.authoritative
	playground.authoritative = false
	_check(not playground.activate_addon_item("spawn_pack/test_guard", 0, at, &"bot").ok,
		"a client never runs an entry")
	playground.authoritative = client_side
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	# A static on the fixture's script outlives the suite; what it recorded points back into the game.
	pack_script.set("custom_calls", [])
	# Each scan builds lambdas that capture their item and the scanner: release() breaks that cycle.
	playground.addons = prior_addons
	for scanner: PlaygroundAddons in [none, addons, via]:
		scanner.release()
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
