extends Node

const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Renders the offline client holding one weapon at the hip and then with the Aim key held (hip_<id>.png, aim_<id>.png), and prints what the command said and what the rig made of it.
##
## Run: `xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_aim.tscn -- <out dir> [weapon ids, default zee_smg zee_rifle zee_marksman]`

var _client: PlaygroundClient = null


func _ready() -> void:
	PlaygroundPresentation.use_scratch_settings("render_aim")
	_client = PlaygroundClient.new()
	_client.name = "Client"
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	_client.config = config
	add_child(_client)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "/tmp"
	var guns: Array = Array(args.slice(1)) if args.size() > 1 else ["zee_smg", "zee_rifle", "zee_marksman"]
	DirAccess.make_dir_recursive_absolute(out)
	await get_tree().create_timer(2.0).timeout
	_client.mouse_capture_override = true
	var failed := 0
	for gun: String in guns:
		_client._aiming = false
		_client._set_tool(StringName(gun))
		await get_tree().create_timer(1.5).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/hip_%s.png" % [out, gun])
		var rig: ZeeWeaponRig = _client._zee_rig()
		var sent_hip: bool = _client._aim_sent()
		_client._aiming = true
		await get_tree().create_timer(1.5).timeout
		await RenderingServer.frame_post_draw
		var sent: bool = _client._aim_sent()
		print("%s: hip sends %s, aimed sends %s, rig pace %.2f, fov %.1f" % [gun, sent_hip, sent,
			rig.ads_move_scale() if rig != null else -1.0, _client.camera.fov])
		failed += 0 if rig != null and sent and not sent_hip else 1
		get_viewport().get_texture().get_image().save_png("%s/aim_%s.png" % [out, gun])
	print("aim: %d failed" % failed)
	get_tree().quit(failed)
