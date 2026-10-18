extends SceneTree

const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Boots the solo client and prints, per rendered frame, what a player would see: whether the
## map, the player and the camera exist, where the body is and whether the load gate (if any)
## still covers the screen. A frame with a body that moves or falls while the cover is down
## (or there is no cover) is the glitch. Needs xvfb-run, never --headless:
##   xvfb-run -a godot --path . --script tools/load_probe.gd -- [--frames=90] [--shot=N]
var _client: PlaygroundClient = null
var _frame := 0
var _frames := 90
var _shot := -1
var _last := Vector3.ZERO
var _out := "res://screenshots/load_probe"


func _initialize() -> void:
	var _scratch := PlaygroundPresentation.use_scratch_settings("load_probe")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			_frames = int(a.get_slice("=", 1))
		if a.begins_with("--shot="):
			_shot = int(a.get_slice("=", 1))
	DirAccess.make_dir_recursive_absolute("res://screenshots")
	_client = PlaygroundClient.new()
	_client.link = null
	root.add_child(_client)


func _process(_delta: float) -> bool:
	_frame += 1
	var gate: Object = _client.get("gate") if _client != null else null
	var covered: bool = gate != null and not gate.is_open()
	var map_up: bool = _client.playground != null and _client.playground.maps.current != null
	var pos := Vector3.ZERO
	var has_player: bool = _client.player != null
	if has_player:
		pos = _client.player.global_position
	var cam: bool = _client.camera != null and _client.camera.is_inside_tree()
	var moved := pos.distance_to(_last)
	_last = pos
	print("frame %3d gate=%s covered=%s map=%s player=%s cam=%s hud=%s pos=%s moved=%.3f" % [
		_frame, gate != null, covered, map_up, has_player, cam, _client.hud != null, pos, moved])
	if _frame == _shot or (_shot < 0 and _frame in [3, 15, _frames - 1]):
		get_root().get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("%s_%d.png" % [_out, _frame]))
	if _frame >= _frames:
		quit(0)
	return false
