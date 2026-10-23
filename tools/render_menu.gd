extends Node

const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Renders the Escape menu and the console through the real offline client (the platform owns
## the menu, the pointer and the console) into `screenshots/menu/`.
##
## [codeblock]
## xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_menu.tscn
## [/codeblock]

const OUT_DIR := "res://screenshots/menu"

var _client: PlaygroundClient = null


func _ready() -> void:
	PlaygroundPresentation.use_scratch_settings("render_menu")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_client = PlaygroundClient.new()
	_client.name = "Client"
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	_client.config = config
	add_child(_client)
	_run.call_deferred()


func _run() -> void:
	await _frames(60)
	await _shot("play")
	# The pointer is free (the first Escape), so this Escape is the second press.
	var escape := InputEventKey.new()
	escape.physical_keycode = KEY_ESCAPE
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	_client.mouse_capture_override = false
	_client._unhandled_input(escape)
	await _frames(10)
	print("menu open: ", _client.game_menu.is_open(), " blocked: ", _client.platform.is_input_blocked())
	await _shot("escape_menu")
	print("mods action: ", _client.game_menu.mods_screen != null)
	if _client.game_menu.mods_screen != null:
		_client.game_menu.open_mods()
		await _frames(5)
		await _shot("mods")
	_client.game_menu.close_all()
	await _frames(5)
	var _opened := _client.presentation.console.open()
	await _frames(10)
	print("console open, blocked: ", _client.platform.is_input_blocked())
	await _shot("console")
	get_tree().quit()


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name])
	print(shot_name, " -> ", error_string(get_viewport().get_texture().get_image().save_png(path)))


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame
