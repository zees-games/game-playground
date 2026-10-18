extends SceneTree

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")

## Frame sequences of the first-person camera's motion, to look at: the landing dip, the strafe
## lean and the widening past a run, written by the client's own `PlaygroundPlayer.present_camera`
## at 144 frames a second against the game's tick.
##
## [codeblock]
## tools/render_feel.sh                  # landing, strafe and speed
## tools/render_feel.sh landing          # some
## tools/render_feel.sh --off            # every camera motion setting at 0: the control
## [/codeblock]
##
## - `landing`: a drop from 7 m onto the lobby's open floor (about 16.7 m/s, a full dip), every
##   second frame from just before the touch; the eye should go on down a little and come back.
## - `hop`: three bunny hops in a row (6.8 m/s each); the view should not bob at all.
## - `strafe`: strafing right, then left, every third frame; the horizon should lean about a
##   degree into it and back, gently.
## - `speed`: in the air at 22 m/s, every third frame; the lens should widen a few degrees.
##
## Writes `screenshots/feel/<scenario>_NNN.png` and `<scenario>.csv` (every frame);
## `render_feel.sh` prints the ranges and the largest change of step, and makes contact sheets.

const OUT_DIR := "screenshots/feel"
const BASE_FOV := 100.0

var _game: Playground = null
var _player: PlaygroundPlayer = null
var _camera: Camera3D = null
var _home := Vector3.ZERO
var _home_yaw := 0.0
var _scenarios: Array[String] = []
var _scenario := ""
var _frame := 0
var _recorded := 0
var _save_every := 1
var _log: PackedStringArray = []
var _settle := 0
var _hops := 0
var _was_grounded := true


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for name in ["landing", "hop", "strafe", "speed"]:
		if args.is_empty() or args.has(name) or (args.size() == 1 and args.has("--off")):
			_scenarios.append(name)

	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.initial_map = &"pg_flatgrass"
	config.map_seconds = 0.0

	_game = Playground.new()
	_game.name = "Playground"
	_game.config = config
	root.add_child(_game)


func _process(delta: float) -> bool:
	if _player == null:
		if _game.maps == null or _game.maps.current == null:
			return false
		Engine.physics_ticks_per_second = _game.tick_rate
		_player = _game.add_player(&"local", "gamemann")
		_player.samples_input = true
		_player.sampler = null
		_camera = Camera3D.new()
		_camera.name = "Camera"
		_camera.current = true
		_player.add_child(_camera)
		_player.enable_camera_motion()
		if OS.get_cmdline_user_args().has("--off"):
			_player.set_camera_motion_scales(0.0, 0.0, 0.0)
		_settle = 30
		return false

	if _settle > 0:
		_settle -= 1
		if _settle == 0 and _home == Vector3.ZERO:
			_home = _player.controller.state.position
			_home_yaw = _player.controller.state.yaw
		_player.present_camera(_camera, delta, BASE_FOV)
		return false

	if _scenario == "":
		if _scenarios.is_empty():
			print("[feel] done")
			return true
		_scenario = _scenarios.pop_front()
		_start(_scenario)
		return false

	_drive()
	_player.present_camera(_camera, delta, BASE_FOV)
	var m := _player.camera_motion
	var state := _player.controller.state
	_log.append("%d,%.5f,%.5f,%.4f,%.4f,%.3f,%.3f,%d" % [
		_frame, _camera.global_position.y, m.eye_drop(), m.roll(), _camera.fov,
		Vector2(state.velocity.x, state.velocity.z).length(), state.velocity.y, int(state.is_grounded()),
	])
	if _frame % _save_every == 0 and (_scenario != "landing" or _frame >= 104):
		var _saved := root.get_texture().get_image().save_png("%s/%s_%03d.png" % [OUT_DIR, _scenario, _recorded])
		_recorded += 1
	_frame += 1
	if _finished():
		var file := FileAccess.open("%s/%s.csv" % [OUT_DIR, _scenario], FileAccess.WRITE)
		file.store_string("frame,eye_y,dip,roll,fov,speed,vy,grounded\n" + "\n".join(_log) + "\n")
		file.close()
		print("[feel] %s: %d frames, %d saved" % [_scenario, _frame, _recorded])
		_scenario = ""
		_player.teleport(_home, _home_yaw)
		_player.controller.apply_command(_command(Vector2.ZERO))
		_settle = 40
	return false


func _start(name: String) -> void:
	_frame = 0
	_recorded = 0
	_log = PackedStringArray()
	_hops = 0
	_was_grounded = true
	match name:
		"landing":
			_save_every = 2
			_player.teleport(_home + Vector3(0.0, 7.0, 0.0), _home_yaw)
			_player.controller.apply_command(_command(Vector2.ZERO))
		"hop":
			_save_every = 3
			_player.controller.apply_command(_command(Vector2(0.0, 1.0), true))
		"strafe":
			_save_every = 3
			_player.controller.apply_command(_command(Vector2(1.0, 0.0)))
		"speed":
			_save_every = 3
			_player.teleport(_home + Vector3(0.0, 40.0, 0.0), _home_yaw)
			_player.controller.state.velocity = DotFpsMotor.forward_for(_home_yaw) * 22.0
			_player.controller.apply_command(_command(Vector2.ZERO))


## What the scenario holds this frame. The strafe changes hands at 0.7 s.
func _drive() -> void:
	match _scenario:
		"strafe":
			if _frame == 100:
				_player.controller.apply_command(_command(Vector2(-1.0, 0.0)))
			elif _frame == 200:
				_player.controller.apply_command(_command(Vector2.ZERO))
		"landing":
			# Recording starts on the way down; frames above a metre are not interesting.
			pass
		"hop":
			var grounded := _player.controller.state.is_grounded()
			if grounded and not _was_grounded:
				_hops += 1
			_was_grounded = grounded


func _finished() -> bool:
	match _scenario:
		"landing":
			return _frame >= 176
		"hop":
			return _hops >= 3 or _frame >= 400
		"strafe":
			return _frame >= 260
		"speed":
			return _frame >= 150
	return true


func _command(move: Vector2, jump: bool = false) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = move
	c.yaw = _home_yaw
	c.pitch = 0.0
	if jump:
		c.set_button(DotFpsCommand.BUTTON_JUMP, true)
	return c
