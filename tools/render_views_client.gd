extends Node

const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Renders the real offline client with a zee gun in hand, through every F5 view, into `screenshots/views/`, and prints one line a
## frame about the first-person hands: whether they exist, are visible in the tree, and have a mesh inside the camera's frustum.
##
## [codeblock]
## xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_views_client.tscn
## [/codeblock]

const OUT_DIR := "res://screenshots/views"

var _client: PlaygroundClient = null


func _ready() -> void:
	PlaygroundPresentation.use_scratch_settings("render_views_client")
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
	await _seconds(2.0)
	_client.mouse_capture_override = true
	_client._set_tool(&"zee_carbine")
	await _seconds(1.2)
	var order: Array[StringName] = [&"tp", &"selfie", &"fp", &"tp", &"selfie", &"fp"]
	var failed := 0
	failed += await _shot("hands_view_first", &"fp")
	for i in range(order.size()):
		var key := InputEventKey.new()
		key.physical_keycode = KEY_F5
		key.keycode = KEY_F5
		key.pressed = true
		_client._unhandled_input(key)
		await _seconds(1.0)
		failed += await _shot("hands_view_f5_%d_%s" % [i + 1, order[i]], order[i])
		if order[i] == &"selfie":
			var stood := _client.selfie_camera.global_position
			_client.player.teleport(_client.player.global_position + Vector3(4, 0, 0))
			await _seconds(0.5)
			var still := _client.selfie_camera.global_position.is_equal_approx(stood)
			print("selfie camera stays put while the player moves: %s" % still)
			failed += 0 if still else 1
	print("views: %d failed" % failed)
	get_tree().quit(failed)


func _shot(shot_name: String, expected: StringName) -> int:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name])
	var cam := get_viewport().get_camera_3d()
	var hands_ok := _hands_ok(cam, expected)
	print("%s: expect %s ok=%s, view %s, camera %s (client camera current %s), hands %s -> %s" % [shot_name,
		_client.player.view_mode(), cam.get_path() if cam != null else "none", _client.camera.current,
		_describe_hands(cam), error_string(image.save_png(path))])
	return 0 if hands_ok else 1


## fp: this client's camera is the one drawing, and the hands are visible inside its frustum. tp and selfie: the hands are hidden and the camera is not the first-person one.
func _hands_ok(cam: Camera3D, expected: StringName) -> bool:
	if cam == null or _client.view_id() != expected:
		return false
	var hands := _client.zee_view
	if expected == &"fp":
		return cam == _client.camera and hands.is_visible_in_tree() and _in_frustum(hands, cam) > 0
	if expected == &"selfie":
		return cam == _client.selfie_camera and not hands.is_visible_in_tree() and _client.player.body_shown()
	return cam != _client.camera and not hands.is_visible_in_tree()


func _in_frustum(hands: Node, cam: Camera3D) -> int:
	var inside := 0
	var planes := cam.get_frustum()
	for mesh: MeshInstance3D in hands.find_children("*", "MeshInstance3D", true, false):
		if not mesh.is_visible_in_tree():
			continue
		var centre := mesh.global_transform * mesh.get_aabb().get_center()
		var ok := true
		for plane: Plane in planes:
			if plane.distance_to(centre) > 0.0:
				ok = false
		if ok:
			inside += 1
	return inside


func _describe_hands(cam: Camera3D) -> String:
	var hands := _client.zee_view
	if hands == null or not is_instance_valid(hands):
		return "missing"
	var inside := 0
	var total := 0
	var planes := cam.get_frustum() if cam != null else []
	for mesh: MeshInstance3D in hands.find_children("*", "MeshInstance3D", true, false):
		if not mesh.is_visible_in_tree():
			continue
		total += 1
		var centre := mesh.global_transform * mesh.get_aabb().get_center()
		var ok := cam != null
		for plane: Plane in planes:
			if plane.distance_to(centre) > 0.0:
				ok = false
		if ok:
			inside += 1
	return "visible %s, %d/%d meshes in frustum, parent %s" % [hands.is_visible_in_tree(), inside, total, hands.get_parent().name]


func _seconds(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
