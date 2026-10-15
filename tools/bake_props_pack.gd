extends SceneTree
## Measures every model in assets/props/<kit>/props.json, writes the extent back into the
## manifest (so the game reads no model at start) and renders thumbs/<stem>.png for each.
##
## Needs a renderer, so run it under a virtual display, after `--import`:
##   xvfb-run -a godot --path . --script res://tools/bake_props_pack.gd
## Re-run after changing a kit's scale or shape in props.json.

const KITS: Array[String] = ["furniture", "food", "survival", "nature", "market"]
const THUMB := 160


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failed := 0

	for kit in KITS:
		var dir := "res://assets/props/%s" % kit
		var manifest_path := ProjectSettings.globalize_path(dir.path_join("props.json"))
		var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		var defaults: Dictionary = doc.get("defaults", {})
		var props: Dictionary = doc["props"]

		for stem in props:
			var entry: Dictionary = props[stem]
			var path := dir.path_join("%s.glb" % stem)
			var scale := float(entry.get("scale", defaults.get("scale", 1.0)))
			var measured := DotPropModel.measure(path, scale, str(entry.get("shape", "convex")))

			if not measured.ok:
				printerr("%s/%s: %s" % [kit, stem, measured.error.message])
				failed += 1
				continue

			var value := measured.value as Dictionary
			var extent: Vector3 = value["extent"]
			entry["extent"] = [snappedf(extent.x, 0.001), snappedf(extent.y, 0.001), snappedf(extent.z, 0.001)]
			DirAccess.make_dir_recursive_absolute(
				ProjectSettings.globalize_path(dir.path_join("thumbs"))
			)
			await _thumb(path, scale, value, ProjectSettings.globalize_path(dir.path_join("thumbs/%s.png" % stem)))

		var out := FileAccess.open(manifest_path, FileAccess.WRITE)
		out.store_string(JSON.stringify(doc, " "))
		out.close()
		print("%s: %d props" % [kit, props.size()])

	print("bake done, %d failed" % failed)
	quit(1 if failed > 0 else 0)


func _thumb(path: String, scale: float, value: Dictionary, png: String) -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(THUMB, THUMB)
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.ambient_light_energy = 0.9
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	vp.add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.1
	vp.add_child(sun)

	var node := DotPropModel.visual(path, scale, value["offset"])
	vp.add_child(node)

	var extent: Vector3 = value["extent"]
	var radius := maxf(extent.length() * 0.5, 0.05)
	var cam := Camera3D.new()
	cam.fov = 30.0
	vp.add_child(cam)
	var target := Vector3.ZERO
	var dir := Vector3(0.7, 0.55, 1.0).normalized()
	cam.position = target + dir * radius / sin(deg_to_rad(15.0)) * 1.05
	cam.look_at(target)

	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png(png)
	vp.queue_free()
