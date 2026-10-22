extends Node

const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Renders the admin profile workbench through the real offline client into `docs/`.
##
## [codeblock]
## tools/render_workbench.sh
## [/codeblock]

const OUT_DIR := "res://docs"

var _client: PlaygroundClient = null


func _ready() -> void:
	PlaygroundPresentation.use_scratch_settings("render_workbench")
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
	_client.mouse_capture_override = false
	_client._open_profiles()
	await _frames(10)
	var screen := _client.profile_screen
	print("open: ", _client.screens.is_open(&"profiles"))
	var npcs := screen.ids("npc")
	print("npc ids: ", npcs)
	screen.open_profile("npc", "npc_hunter" if "npc_hunter" in npcs else npcs[0])
	await _frames(5)
	await _shot("workbench_npc")
	var weapons := screen.ids("weapon")
	print("weapon ids: ", weapons)
	if not weapons.is_empty():
		screen.open_profile("weapon", weapons[0])
		await _frames(5)
		var _r := screen.form.set_value("extra.damage", 99)
	await _shot("workbench_weapon")
	get_tree().quit()


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name])
	print(shot_name, " -> ", error_string(get_viewport().get_texture().get_image().save_png(path)))


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame
