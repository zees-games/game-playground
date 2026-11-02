extends Node

const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Renders a crate and a pane breaking in front of the offline client into `screenshots/break/`.
##
## Run: `xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_break.tscn`

const OUT_DIR := "res://screenshots/break"

var _client: PlaygroundClient = null


func _ready() -> void:
	PlaygroundPresentation.use_scratch_settings("render_break")
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
	await get_tree().create_timer(2.5).timeout
	var cam := _client.camera.global_transform
	var ahead := cam.origin - cam.basis.z * 3.0
	_client.playground.prop_shattered.emit(ahead + cam.basis.x * -0.8, 1)
	_client.presentation.on_pane_broken(ahead + cam.basis.x * 0.8)
	await get_tree().create_timer(0.25).timeout
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	print("break: %s, bursts %d" % [error_string(image.save_png(ProjectSettings.globalize_path(OUT_DIR + "/break.png"))),
		_client.presentation.break_fx.break_fx.spawned])
	get_tree().quit()
