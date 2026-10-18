extends Node

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPlatform := preload("../game/playground_platform.gd")

## A headless dedicated playground for tools/render_cover.gd to join: the same boot
## examples/dedicated.gd does (DotServer, the game, the platform layer, the module), left
## running. `pg_arena` is on so the damage path the cover guards is live.
##
## [codeblock]
## godot --headless --path . res://tools/cover_server.tscn -- --port 27299
## [/codeblock]

var server: DotServer = null
var game: Playground = null
var platform: PlaygroundPlatform = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _run() -> void:
	var dir := ProjectSettings.globalize_path("user://cover_server")
	DotPaths.remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)

	var config := DotServerConfig.new()
	config.autoexec_config = ""
	config.hostname = "cover test"
	config.max_players = 4
	config.hibernate_when_empty = false
	config.rcon_password = ""
	config.query_enabled = false
	config.port = int(_arg("--port", "27299"))
	config.admins_path = "%s/admins.json" % dir
	config.bans_path = "%s/bans.json" % dir
	config.audit_log_path = "%s/audit.jsonl" % dir
	config.stdin_console_enabled = false

	server = DotServer.new()
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
	game = Playground.new()
	game.name = "Playground"
	game.config = pg_config
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame

	platform = PlaygroundPlatform.new()
	platform.name = "Identity"
	platform.directory = "%s/identity" % dir
	add_child(platform)
	var _identity: DotResult = await platform.setup()
	var _p: DotResult = await server.modules.load_module("res://addons/dot_platform/dot_platform_module.gd")
	(load("res://game/playground_module.gd") as GDScript).set("punishments_path", "%s/punishments.json" % dir)
	var loaded: DotResult = await server.modules.load_module("res://game/playground_module.gd")
	print("cover_server: module loaded=%s port=%d" % [loaded.ok, config.port])
