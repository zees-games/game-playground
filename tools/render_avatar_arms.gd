extends Node

const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundZee := preload("../game/playground_zee.gd")

## Renders the offline client in first person holding each listed weapon, then in third person,
## and prints what draws for the local player: arms rigs, weapon models, meshes in view.
##
## Run: `xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_avatar_arms.tscn -- <out dir> [ids...]`

const DEFAULT_IDS: Array[StringName] = [&"pistol", &"sniper", &"smg", &"lmg", &"shotgun", &"crowbar"]

var _client: PlaygroundClient = null


func _ready() -> void:
	PlaygroundPresentation.use_scratch_settings("render_avatar_arms")
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
	var ids: Array[StringName] = []
	for i in range(1, args.size()):
		ids.append(StringName(args[i]))
	if ids.is_empty():
		ids = DEFAULT_IDS
	if ids == [&"all"]:
		ids = []
		for def in _client.playground.weapons:
			if PlaygroundZee.is_zee(def):
				ids.append(def.id)
	DirAccess.make_dir_recursive_absolute(out)
	await get_tree().create_timer(2.0).timeout
	_client.mouse_capture_override = true
	for third: bool in [false, true]:
		_client.player.set_view_mode(third)
		var view := "tp" if third else "fp"
		for id in ids:
			var full := id if _client.playground.weapon_def(id) != null else StringName("zee_%s" % id)
			_client._set_tool(full)
			await get_tree().create_timer(1.2).timeout
			await RenderingServer.frame_post_draw
			print("[%s %s] %s" % [view, id, JSON.stringify(_census())])
			print("[%s %s] %s" % [view, id, JSON.stringify(_arms_state())])
			get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [out, view, id])
			if not third and OS.get_environment("AVATAR_ARMS_ISOLATE") == "1":
				for root: Node in [_client.arms_pivot, _client.zee_view]:
					for mi in root.find_children("*", "GeometryInstance3D", true, false):
						(mi as GeometryInstance3D).visible = false
				for i in 3:
					await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png("%s/%s_%s_body.png" % [out, view, id])
	get_tree().quit(0)


## Every scripted node under the player, by class, "(hidden)" when not visible in the tree.
func _census() -> Dictionary:
	var counts := {}
	var stack: Array[Node] = [_client.player]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var s: Script = n.get_script()
		if s != null and s.get_global_name() != &"":
			var key := String(s.get_global_name())
			if n is Node3D and not (n as Node3D).is_visible_in_tree():
				key += "(hidden)"
			counts[key] = int(counts.get(key, 0)) + 1
		for c in n.get_children(true):
			stack.append(c)
	return counts


## Where the avatar's arms are and how well the hands sit on the weapon.
func _arms_state() -> Dictionary:
	var out := {}
	var arms: Node3D = _client.view_arms.call("arms") if _client.view_arms != null else null
	if arms != null:
		out["arms_at"] = arms.transform.origin
		out["arms_scale"] = arms.transform.basis.get_scale()
	if _client.held_grip != null:
		out["hand_error"] = _client.view_arms.call("hand_error", _client.held_grip)
		out["grip_cam"] = _client.camera.global_transform.affine_inverse() * _client.held_grip.grip_world()
	out["seat"] = _client.hand_seat_offset
	var hands: Node3D = _client.zee_view as Node3D
	if hands != null and is_instance_valid(hands):
		var meshes := 0
		for mi in hands.find_children("*", "MeshInstance3D", true, false):
			if (mi as MeshInstance3D).is_visible_in_tree() and (mi as MeshInstance3D).mesh != null:
				meshes += 1
		out["view_meshes"] = meshes
		out["equipped"] = (hands as ZeeViewModel).equipped()
	return out
