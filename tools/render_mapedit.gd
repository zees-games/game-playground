extends Node

const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundBindings := preload("../game/playground_bindings.gd")

## Renders the offline client placing spawn points with the tool gun, the markers showing, and a point's form open, into `screenshots/mapedit/`.
##
## Run: `xvfb-run -a godot --path . --resolution 1280x720 --rendering-method gl_compatibility --rendering-driver opengl3 res://tools/render_mapedit.tscn`

const OUT_DIR := "res://screenshots/mapedit"

var _client: PlaygroundClient = null


func _ready() -> void:
	PlaygroundPresentation.use_scratch_settings("render_mapedit")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_client = PlaygroundClient.new()
	_client.name = "Client"
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	_client.config = config
	add_child(_client)
	_run.call_deferred()


func _key(action: StringName) -> void:
	var event := InputEventKey.new()
	var code: int = {PlaygroundBindings.MAP_EDIT: KEY_F7, PlaygroundBindings.MAP_EDIT_PICK: KEY_F8}[action]
	event.physical_keycode = code as Key
	event.keycode = code as Key
	event.pressed = true
	_client._unhandled_input(event)


func _run() -> void:
	await _seconds(2.0)
	_client.mouse_capture_override = true
	_client._on_tool_mode_chosen(&"spawnpoint", {"kind": "npc"})
	_key(PlaygroundBindings.MAP_EDIT)
	var view = _client.map_edit_view
	var failed := 0

	if view == null or not view.active():
		print("map edit view did not come up")
		get_tree().quit(1)
		return

	var body: Node3D = _client.player
	var forward := -body.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP)
	var space := _client.playground.world.get_world_3d().direct_space_state
	var gun: Object = _client.weapon

	for spec in [[Vector2(5.0, -2.5), "player"], [Vector2(6.0, 0.0), "npc"], [Vector2(8.0, 2.5), "both"]]:
		var at: Vector3 = body.global_position + forward * (spec[0] as Vector2).x + right * (spec[0] as Vector2).y
		gun.call("set_mode", &"spawnpoint", {"kind": spec[1]})
		var placed: DotResult = gun.call("primary", space, at + Vector3.UP * 4.0, Vector3.DOWN)
		print("place %s: ok=%s %s" % [spec[1], placed.ok, str(placed.value) if placed.ok else placed.error.message])
		failed += 0 if placed.ok else 1
		await _seconds(0.2)

	var points: Array = _client.playground.map_edit.points.points
	print("points in the set: %d, markers: %d" % [points.size(), view.overlay.marker_count()])
	failed += 0 if points.size() == 3 and view.overlay.marker_count() == 3 else 1
	await _seconds(0.5)
	failed += await _shot("mapedit_placed")

	# The middle point was placed on the line of sight, so the crosshair is on it.
	# Tip the view down at the point's middle: the pick is a ray from the camera.
	for pitch in [-7.6, 7.6]:
		_client.active_sampler().look_at_angles(0.0, pitch)
		await _seconds(0.3)
		_key(PlaygroundBindings.MAP_EDIT_PICK)
		await _seconds(0.3)

		if view.panel_open():
			break

	print("form open: %s" % view.panel_open())
	failed += await _shot("mapedit_form")
	print("mapedit: %d failed" % failed)
	get_tree().quit(failed)


func _shot(shot_name: String) -> int:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name])
	var saved := image.save_png(path)
	print("%s -> %s" % [path, error_string(saved)])
	return 0 if saved == OK else 1


func _seconds(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
