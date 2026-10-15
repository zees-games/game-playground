extends SceneTree
## A frame of a dozen model props on a floor, built from the real prop scene and catalogue.
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/screenshot_props.gd
## Written to screenshots/props_models.png.

const PlaygroundSpawnables := preload("../game/playground_spawnables.gd")

const IDS: Array[StringName] = [
	&"sofa", &"table_coffee", &"bookcase", &"fridge", &"lamp_floor", &"potted_plant",
	&"barrel_wood", &"crate_long", &"tent", &"pumpkin", &"shopping_cart", &"rock_a",
]

var _frames := 0


func _initialize() -> void:
	var floor_body := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	floor_body.mesh = plane
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.42, 0.46, 0.5)
	floor_body.material_override = floor_mat
	root.add_child(floor_body)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.74, 0.86)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.8)
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	root.add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	root.add_child(sun)

	var catalogue := PlaygroundSpawnables.with_models(PlaygroundSpawnables.catalogue(), "")
	for i in range(IDS.size()):
		var def := catalogue.get_prop(IDS[i])
		if def == null:
			push_error("no prop %s" % IDS[i])
			continue
		var body := (load(def.scene_path) as PackedScene).instantiate() as RigidBody3D
		root.add_child(body)
		body.call("configure", def)
		body.freeze = true
		var ext: Array = def.meta["extent"]
		body.position = Vector3((i % 6 - 2.5) * 3.2, float(ext[1]) * 0.5, float(i / 6) * -3.6 + 1.0)
		body.rotation.y = deg_to_rad(20.0 * float(i % 3) - 20.0)

	var cam := Camera3D.new()
	cam.fov = 55.0
	root.add_child(cam)
	cam.look_at_from_position(Vector3(0, 6.5, 9.5), Vector3(0, 0.8, -1.0))


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 6:
		root.get_viewport().get_texture().get_image().save_png(
			ProjectSettings.globalize_path("res://screenshots/props_models.png")
		)
		quit(0)
	return false
