extends DotGameCheckSuite

## Solo in the client shell: the map packs it mounted are in the catalogue before the first map, and its `start_map`
## (`--solo-map`, a hotspot "Play map" link) is that first map. With no host, an older shell or a map nobody has, the
## first map is `initial_map` as before.
##
## [codeblock]
## godot --headless --path . res://examples/headless_solomap.tscn
## [/codeblock]

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")

const CHECKS := 9
const SECTIONS := 1

## A map document in a directory standing in for a mounted pack's `maps/`.
const PACK_MAPS := "res://examples/fixtures/maps"
const PACK_MAP := &"pg_brushes"


## The shell's solo host as the game sees it, before `start_map` existed.
class FakeSolo:
	extends RefCounted
	var dirs := PackedStringArray()

	func map_dirs(_subdir: String) -> PackedStringArray:
		return dirs


## And with it.
class FakeSoloStart:
	extends FakeSolo
	var start_map: StringName = &""


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-playground: the shell's start map")
	_check(Playground.solo_start_map() == &"" and Playground.solo_map_dirs("maps").is_empty(),
		"with no solo host there is no start map and no mounted pack")
	_check(await _first_map(null) == "pg_flatgrass", "and the first map is initial_map")

	var old := FakeSolo.new()
	old.dirs = PackedStringArray([PACK_MAPS])
	var got := await _boot(old)
	_check(got[0] == "pg_flatgrass", "a shell with no start_map: initial_map", got[0])
	_check(got[1], "and the mounted pack's map is in the catalogue before it")

	var asked := FakeSoloStart.new()
	asked.dirs = PackedStringArray([PACK_MAPS])
	asked.start_map = PACK_MAP
	got = await _boot(asked)
	_check(got[0] == String(PACK_MAP), "a start map from the mounted pack is the first map", got[0])
	_check(got[1], "and it is in the catalogue")

	asked.start_map = &"pgc_not_a_map"
	_check(await _first_map(asked) == "pg_flatgrass", "a start map nobody has: initial_map")
	asked.start_map = &""
	_check(await _first_map(asked) == "pg_flatgrass", "an empty one: initial_map")
	asked.start_map = &"pg_generated"
	asked.dirs = PackedStringArray()
	_check(await _first_map(asked) == "pg_generated", "a built-in map can be the start map too")

	_report_sections(1, 1, SECTIONS, CHECKS)


func _first_map(host: Object) -> String:
	return (await _boot(host))[0]


## Boots a playground with [param host] as the `dot_solo` service (none when null) and returns
## [first map id, whether the pack map is in its catalogue].
func _boot(host: Object) -> Array:
	if host != null:
		DotRegistry.register(Playground.SOLO_SERVICE, host)
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"pg_flatgrass"
	config.authoritative = true
	var game := Playground.new()
	game.config = config
	game.service_scope = &"solomap"
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.booted:
			break
	var first := String(game.maps.current.id) if game.maps != null and game.maps.current != null else ""
	var listed := game.maps != null and game.maps.catalogue.has(PACK_MAP)
	remove_child(game)
	game.free()
	if host != null:
		DotRegistry.unregister_instance(Playground.SOLO_SERVICE, host)
	await get_tree().process_frame
	return [first, listed]
