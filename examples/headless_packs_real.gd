extends Node

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")
const PlaygroundZee := preload("../game/playground_zee.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundSpawnMenu := preload("../game/playground_spawn_menu.gd")

## The three real optional packs (zz-modern-weapons, zz-medieval-weapons, zz-historical-monsters) in
## the Q menu, not the fixture the main suite uses.
##
## [codeblock]
## godot --headless --path . res://examples/headless_packs_real.tscn
## [/codeblock]
##
## [b]Skips, visibly, when a pack is not linked[/b] (`addons/zz_*` is a gitignored symlink, see
## docs/development-setup.md): exit 0 with a SKIP line and no checks. Why it exists: a fixture's
## weapon spawn is a string; the real weapon packs hand a Dictionary and the definition behind a
## static `weapon_defs()`, and nothing but running them showed the playground refused every one.

const PACKS: Array[String] = ["zz_modern_weapons", "zz_medieval_weapons", "zz_historical_monsters"]
const MONSTERS: Array[String] = ["trex", "tiger", "bear"]
const CHECKS := 16
const SECTIONS := 4

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _game: Playground = null
var _weapon_rows: Array = []
var _npc_rows: Array = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := PlaygroundPresentation.use_scratch_settings("headless_packs_real")
	_run.call_deferred()


func _run() -> void:
	print("playground - the real spawn packs")
	var missing: Array[String] = []
	for pack in PACKS:
		if not FileAccess.file_exists("res://addons/%s/spawn_provider.gd" % pack):
			missing.append(pack)
	if not missing.is_empty():
		print("  SKIP  not linked under res://addons: %s" % ", ".join(missing))
		get_tree().quit(0)
		return

	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.initial_map = &"pg_flatgrass"
	config.map_seconds = 0.0
	_game = Playground.new()
	_game.config = config
	add_child(_game)
	for _i in 120:
		await get_tree().process_frame
		if _game.maps != null and _game.maps.current != null:
			break

	_game.add_player(&"bot", "Bot")
	await get_tree().physics_frame
	await _test_menu()
	await _test_weapons()
	await _test_monsters()
	_test_override()

	print("")
	print("%d sections, %d passed, %d failed" % [_completed, _passed, _failed])
	if _completed != SECTIONS or _passed + _failed != CHECKS:
		print("ERROR: %d of %d sections, %d of %d checks ran." % [_completed, SECTIONS, _passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _test_menu() -> void:
	_section("the Q menu lists every real entry")
	var rows := _game.addons.describe_items()
	for row in rows:
		match str(row["kind"]):
			"weapon": _weapon_rows.append(row)
			"npc": _npc_rows.append(row)
	_check(_weapon_rows.size() == 7 + 8, "seven modern and eight medieval weapon rows", str(_weapon_rows.size()))
	_check(_npc_rows.size() == 3, "three monsters", str(_npc_rows.size()))

	var menu := PlaygroundSpawnMenu.new()
	menu.catalogue = _game.props.catalogue
	menu.weapons = _game.weapons
	add_child(menu)
	var stack := DotScreenStack.new()
	add_child(stack)
	stack.setup()
	stack.register(menu)
	stack.push(menu.screen_id())
	await get_tree().process_frame
	menu.addon_items = rows
	menu.show_tab(PlaygroundSpawnMenu.Tab.PACK_WEAPONS)
	await get_tree().process_frame
	var shown := menu.shown()
	_check(shown.size() == _weapon_rows.size(), "Pack Weapons shows all of them", str(shown.size()))
	var all_cards := true
	for row in _weapon_rows:
		all_cards = all_cards and menu.card_for(StringName(row["key"])) != null
	_check(all_cards, "each has a card")
	menu.show_tab(PlaygroundSpawnMenu.Tab.NPCS)
	await get_tree().process_frame
	_check(menu.shown().size() == 3, "NPCs shows the three monsters", str(menu.shown()))
	for row in _npc_rows:
		_check(menu.card_for(StringName(row["key"])) != null, "a card for %s" % row["key"])
	menu.queue_free()
	stack.queue_free()
	_done()


func _test_weapons() -> void:
	_section("every weapon entry gives the player that weapon")
	var bot: PlaygroundPlayer = _game.players[&"bot"]
	bot.teleport(Vector3(0, 1, 0), 0.0)
	await get_tree().physics_frame
	var at := bot.global_position + Vector3(0, 0, -3)
	var picked: Array = []
	_game.weapon_picked_up.connect(func(who: StringName, w: StringName) -> void: picked.append([who, w]))
	var gave_all := true
	var defined := true
	var rigs := true
	for row in _weapon_rows:
		picked.clear()
		var res: DotResult = _game.activate_addon_item(str(row["key"]), 0, at, &"bot")
		var ok: bool = res.ok and picked.size() == 1 and picked[0][0] == &"bot"
		gave_all = gave_all and ok
		if not ok:
			print("    refused %s: %s" % [row["key"], res.error.message if not res.ok else "no pickup"])
			continue
		var def := _game.weapon_def(picked[0][1])
		defined = defined and def != null and PlaygroundZee.is_zee(def)
		if def != null:
			var rig := PlaygroundZee.arm(bot, def, ZeeWeaponRig.Role.SERVER, true, 64, 0)
			var held: bool = rig != null and rig.arsenal.catalogue.has(PlaygroundZee.zee_id(def))
			rigs = rigs and held
			if not held:
				print("    no rig for %s" % row["key"])
	_check(gave_all, "all %d activations go through the pickup path" % _weapon_rows.size())
	_check(defined, "and the id picked up is one the game's catalogue defines")
	_check(rigs, "and a rig built over it holds the real definition")
	PlaygroundZee.disarm(bot)
	_check(not _game.activate_addon_item("zz_medieval_weapons/nope", 0, at, &"bot").ok, "an unknown entry is still refused")
	_done()


func _test_monsters() -> void:
	_section("every monster spawns in front of the player")
	var bot: PlaygroundPlayer = _game.players[&"bot"]
	var at := bot.global_position + Vector3(0, 0, -6)
	var spawned_all := true
	var near := true
	for row in _npc_rows:
		var before := _bodies()
		var res: DotResult = _game.activate_addon_item(str(row["key"]), 0, at, &"bot")
		await get_tree().physics_frame
		var fresh := _bodies().filter(func(n: Node) -> bool: return not before.has(n))
		var ok: bool = res.ok and not fresh.is_empty()
		spawned_all = spawned_all and ok
		if not ok:
			print("    %s: %s" % [row["key"], res.error.message if not res.ok else "nothing new in the world"])
			continue
		var closest := 1e9
		for n in fresh:
			closest = minf(closest, (n as Node3D).global_position.distance_to(at))
		near = near and closest < 4.0
	_check(spawned_all, "each of the three activations puts a body in the world")
	_check(near, "within four metres of where the player aimed")
	await get_tree().create_timer(0.5).timeout
	_done()


## Every 3D node under the world, flattened: a monster's runtime makes its own bodies.
func _bodies() -> Array:
	var out: Array = []
	var stack: Array = [_game.world]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			if c is CharacterBody3D or c is RigidBody3D or c.is_in_group("zhm_monster"):
				out.append(c)
			stack.append(c)
	return out


func _test_override() -> void:
	_section("a cfg/addons/<pack>/*.yml changes a value")
	var dir := "user://cfg/addons/zz_modern_weapons"
	DirAccess.make_dir_recursive_absolute(dir)
	var script: GDScript = load("res://addons/zz_modern_weapons/spawn_provider.gd")
	var before := _damage(script, "zz_m4")
	var file := FileAccess.open(dir + "/99-test.yml", FileAccess.WRITE)
	file.store_string("m4:\n  damage: 51\n")
	file.close()
	var after := _damage(script, "zz_m4")
	DirAccess.remove_absolute(dir + "/99-test.yml")
	var restored := _damage(script, "zz_m4")
	_check(before != 51.0 and after == 51.0, "a one-key file overrides the M4's damage in weapon_defs()", "%s -> %s" % [before, after])
	_check(restored == before, "and removing it restores the shipped value")

	# Known pack bug (zz-medieval-weapons): its provider builds from defaults(), not load_all(),
	# so its yml never reaches the definitions a game is handed. Printed, not asserted.
	var med_dir := "user://cfg/addons/zz_medieval_weapons"
	DirAccess.make_dir_recursive_absolute(med_dir)
	var mscript: GDScript = load("res://addons/zz_medieval_weapons/spawn_provider.gd")
	var mfile := FileAccess.open(med_dir + "/99-test.yml", FileAccess.WRITE)
	mfile.store_string("mace:\n  damage: 123.0\n")
	mfile.close()
	var med := _damage(mscript, "mace")
	DirAccess.remove_absolute(med_dir + "/99-test.yml")
	print("  note  medieval mace damage with a 123 override: %s (%s)" % [med, "honoured" if med == 123.0 else "IGNORED: pack bug"])
	_done()


func _damage(script: GDScript, id: String) -> float:
	for def: DotWeaponDef in script.weapon_defs():
		if String(def.id) == id:
			return (def.tuning as DotWeaponBallistics).damage
	return -2.0


func _section(title: String) -> void:
	_entered += 1
	print(title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % (what if detail == "" else "%s (%s)" % [what, detail]))
