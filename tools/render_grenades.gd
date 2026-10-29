extends Node

const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Renders the offline client with a smoke cloud ahead and then a flash going off into `screenshots/grenades/`.
##
## Run: `xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_grenades.tscn`

const OUT_DIR := "res://screenshots/grenades"

var _client: PlaygroundClient = null


func _ready() -> void:
	PlaygroundPresentation.use_scratch_settings("render_grenades")
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
	var layer := _client.playground.projectiles
	var eye := _client.camera.global_position
	var ahead := -_client.camera.global_basis.z
	layer.launch(_spawn(&"aw_smoke", eye + ahead * 7.0 + Vector3.DOWN * 1.0), &"render")
	await get_tree().create_timer(1.5).timeout
	await _shot("smoke")
	layer.launch(_spawn(&"aw_flash", eye + ahead * 1.5), &"render")
	await get_tree().create_timer(0.25).timeout
	for i in 3:
		await get_tree().process_frame
	# Frames under xvfb are slow and the flash fades on wall time: freeze it at the config's cap for the shot.
	_client.hud.set_process(false)
	_client.hud.flash_overlay.color = Color(1, 1, 1, _client.presentation.fx.config.flash_cap)
	await get_tree().process_frame
	await _shot("flash")
	get_tree().quit(0)


func _spawn(id: StringName, at: Vector3) -> DotWeaponSpawn:
	var spawn := DotWeaponSpawn.new()
	spawn.id = id
	spawn.origin = at
	spawn.gravity_scale = 0.0
	spawn.radius = 0.08
	spawn.splash_radius = 4.0
	spawn.fuse_ticks = 2
	spawn.life_ticks = 128 * 3
	return spawn


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	print("%s: %s" % [shot_name, error_string(image.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name])))])
