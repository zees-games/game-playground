extends DotGameCheckSuite

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundWeapons := preload("../game/playground_weapons.gd")

## The spawn-point tool gun mode: it sends dot-game's map-edit commands and decides nothing itself.
## Run: godot --headless --path . res://examples/headless_spawntool.tscn

const SECTIONS := 3
const CHECKS := 15

var _entered := 0
var _completed := 0
var _game: Playground = null


## The navigation half of the command contract, recorded.
class Nav extends RefCounted:
	var links: Array = []

	func add_link(link: Dictionary) -> DotResult:
		links.append(link)
		return DotResult.success(true)

	func remove_link(_id: String) -> DotResult:
		return DotResult.success(true)


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-playground: spawn point tool")
	_game = await _make_game()
	var gun := _gun()
	await _test_refusals(gun)
	await _test_spawns(gun)
	await _test_links(gun)
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _make_game() -> Playground:
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"pg_flatgrass"
	config.authoritative = true
	config.prop_spawn_interval = 0.0
	var game := Playground.new()
	game.config = config
	game.service_scope = &"spawntool"
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	return game


func _gun() -> Object:
	var def := _game.weapon_def(&"toolgun")
	var gun := PlaygroundWeapons.make(def)
	gun.equip(_game, def)
	gun.wielder = &"admin"
	return gun


func _at_ground(gun: Object, x: float, z: float, button: StringName) -> DotResult:
	await get_tree().physics_frame
	var space := _game.world.get_world_3d().direct_space_state
	return gun.call(button, space, Vector3(x, 4.0, z), Vector3.DOWN)


func _test_refusals(gun: Object) -> void:
	_entered += 1
	_check(gun.call("set_mode", &"spawnpoint", {}).ok, "the tool gun has a spawn point mode")
	var none: DotResult = await _at_ground(gun, 20.0, 20.0, &"primary")
	_check(not none.ok and none.error.code == DotError.CODE_UNSUPPORTED, "with no map editing installed it refuses")

	var edit := DotGameMapEdit.new()
	edit.points = DotSpawnPointSet.new()
	edit.nav = Nav.new()
	_game.map_edit = edit
	var denied: DotResult = await _at_ground(gun, 20.0, 20.0, &"primary")
	_check(not denied.ok and denied.error.code == DotError.CODE_FORBIDDEN, "and a player who is not staff is refused")
	_check(edit.points.points.is_empty(), "so nothing was placed")
	_completed += 1


func _test_spawns(gun: Object) -> void:
	_entered += 1
	var edit: DotGameMapEdit = _game.map_edit
	_game.map_edit_allowed_fn = func(who: StringName) -> bool: return who == &"admin"
	gun.call("set_mode", &"spawnpoint", {"kind": "npc"})
	var placed: DotResult = await _at_ground(gun, 24.0, 20.0, &"primary")
	_check(placed.ok and edit.points.points.size() == 1, "staff place a spawn point", str(placed.value))
	var def: DotSpawnPointDef = edit.points.points[0]
	_check(def.kind == &"npc" and def.source == &"authored", "of the chosen kind, authored")
	_check(absf(def.position.x - 24.0) < 0.01 and absf(def.position.z - 20.0) < 0.01,
		"where the gun points, not where the player stands", str(def.position))
	_check(edit.dirty, "through the commands, which mark the set unsaved")

	var miss: DotResult = await _at_ground(gun, 30.0, 30.0, &"secondary")
	_check(not miss.ok and edit.points.points.size() == 1, "removing away from any point does nothing")
	var removed: DotResult = await _at_ground(gun, 24.5, 20.0, &"secondary")
	_check(removed.ok and edit.points.points.is_empty(), "removing beside the point removes it")
	_completed += 1


func _test_links(gun: Object) -> void:
	_entered += 1
	var edit: DotGameMapEdit = _game.map_edit
	var nav: Nav = edit.nav
	gun.call("set_mode", &"spawnpoint", {"action": "link", "link": "drop"})
	var first: DotResult = await _at_ground(gun, 20.0, 20.0, &"primary")
	_check(first.ok and nav.links.is_empty(), "the first click in link mode only marks the start", str(first.value))
	var second: DotResult = await _at_ground(gun, 26.0, 20.0, &"primary")
	_check(second.ok and nav.links.size() == 1, "the second adds the link")
	var link: Dictionary = nav.links[0] if nav.links.size() == 1 else {}
	_check(link.get("kind") == "drop" and absf(float(link.get("a", [0])[0]) - 20.0) < 0.01
		and absf(float(link.get("b", [0])[0]) - 26.0) < 0.01, "from the marked point to the second", str(link))
	var again: DotResult = await _at_ground(gun, 22.0, 20.0, &"primary")
	_check(again.ok and nav.links.size() == 1, "and the next click starts a new link")
	var save: DotResult = await _at_ground(gun, 0.0, 0.0, &"reload")
	_check(save.ok, "reload sends the save, which says why it cannot here", str(save.value))
	_completed += 1
