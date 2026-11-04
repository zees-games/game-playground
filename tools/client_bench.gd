extends DotGameClientBench

const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPlatform := preload("../game/playground_platform.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Client prediction bench (dot-game's DotGameClientBench): see that class for the flags.
## Playground has no server bots, so `--bots` is ignored; `--play` supplies the movement.


func _configure() -> void:
	client_scene = "res://game/playground.tscn"
	forward_action = &"dot_fps_forward"


func _prepare(label: String) -> Variant:
	return PlaygroundPresentation.use_scratch_settings(label)


func _boot_server(_bots_wanted: int, data_dir: String) -> DotNetManager:
	var dir := ProjectSettings.globalize_path(data_dir)
	var config := make_server_config(data_dir)
	config.max_players = 8
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)
	for _i in 60:
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	var pg_config := PlaygroundConfig.new()
	pg_config.records_directory = ""
	pg_config.initial_map = &"pg_flatgrass"
	pg_config.map_seconds = 0.0
	var game: Node = (load("res://game/playground.gd") as GDScript).new()
	game.name = "Playground"
	game.config = pg_config
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var platform := PlaygroundPlatform.new()
	platform.name = "Identity"
	platform.directory = "%s/identity" % dir
	add_child(platform)
	var _identity: DotResult = await platform.setup()
	var _p: DotResult = await server.modules.load_module("res://addons/dot_platform/dot_platform_module.gd")
	(load("res://game/playground_module.gd") as GDScript).set("punishments_path", "%s/punishments.json" % dir)
	var loaded: DotResult = await server.modules.load_module("res://game/playground_module.gd")
	if not loaded.ok:
		printerr("client_bench server: ", loaded.error)
		return null
	for n in server.modules.loaded_names():
		var m: Object = server.modules.get_module(n)
		if m != null and m.get("net") != null:
			return m.get("net")
	return null
