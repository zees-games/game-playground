extends DotGameNetchaosServer

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPlatform := preload("../game/playground_platform.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Playground's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosServer): the flat sandbox, the platform layer and the module.

var _game: Playground = null
var _platform: PlaygroundPlatform = null


func _configure() -> void:
	map_id = "pg_flatgrass"


func _prepare(label: String) -> Variant:
	return PlaygroundPresentation.use_scratch_settings(label)


func _boot_world() -> void:
	if not (await boot_server()).ok:
		return
	var pg_config := PlaygroundConfig.new()
	pg_config.records_directory = ""
	pg_config.initial_map = StringName(map_id)
	pg_config.map_seconds = 0.0
	_game = Playground.new()
	_game.name = "Playground"
	_game.config = pg_config
	add_child(_game)
	await get_tree().process_frame
	await get_tree().process_frame
	_platform = PlaygroundPlatform.new()
	_platform.name = "Identity"
	_platform.directory = "%s/identity" % data_dir
	add_child(_platform)
	var _identity: DotResult = await _platform.setup()
	var _p: DotResult = await server.modules.load_module("res://addons/dot_platform/dot_platform_module.gd")
	(load("res://game/playground_module.gd") as GDScript).set("punishments_path", "%s/punishments.json" % data_dir)
	var loaded: DotResult = await server.modules.load_module("res://game/playground_module.gd")
	if not loaded.ok:
		printerr("netchaos server: ", loaded.error)
		return
	for n in server.modules.loaded_names():
		var m: Object = server.modules.get_module(n)
		if m != null and m.get("net") != null:
			module = m
	if module != null and solid != "":
		var cv: DotConVar = server.console.find_cvar("mp_solidplayers")
		if cv != null:
			cv.force_set(solid)


func _players() -> Array:
	return _game.players.values() if _game != null else []
