extends SceneTree

const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundSpawnables := preload("../game/playground_spawnables.gd")

## Renders a playground map to PNGs so a person can look at it.
##
## [b]A map is a rendered thing, and this family has shipped a 0 x 0 Control twice and a
## black screen once.[/b] Every other check on a map here is an assertion about a list of
## boxes, and a list of boxes passes just as happily when they are all in the same place
## — or when a pillar is standing where the player spawns, which is a real bug this map
## had and which no count caught.
##
##   xvfb-run -a godot --path . --script tools/screenshot.gd -- --map pg_flatgrass
##   tools/screenshot.sh pg_flatgrass --fx     # a spawn puff and the physics gun's beam
##
## Needs a real rendering context, so it does NOT run under `--headless`; `xvfb-run` is
## how it runs on a machine with no display. It writes into `screenshots/`, which is
## gitignored — the frame is evidence for a review, not an asset.

const OUT_DIR := "screenshots"

const MAPS := {
	"pg_flatgrass": "res://maps/pg_flatgrass.tscn",
	"pg_generated": "res://maps/pg_generated.tscn",
}

var _shots: Array[Dictionary] = []
var _index := 0
var _camera: Camera3D = null


func _initialize() -> void:
	# Settings to a scratch directory emptied first (see
	# `PlaygroundPresentation.use_scratch_settings`): a render must not save into a player's
	# file, nor draw from whatever the player last saved there.
	var _scratch := PlaygroundPresentation.use_scratch_settings("screenshot")
	var args := OS.get_cmdline_user_args()
	var index := args.find("--map")
	var id := args[index + 1] if index >= 0 and index + 1 < args.size() else "pg_flatgrass"

	# A custom map (game-playground-maps, linked as maps/custom) is a document the shared
	# data-map scene builds.
	var custom := "res://maps/custom/%s.json" % id

	if not MAPS.has(id) and not FileAccess.file_exists(custom):
		push_error("no such map: %s. Known: %s and maps/custom/*.json" % [id, str(MAPS.keys())])
		quit(1)
		return

	var scene: Resource = load(MAPS[id] if MAPS.has(id) else "res://maps/pg_data.tscn")

	if not (scene is PackedScene):
		push_error("%s is not a PackedScene" % MAPS.get(id, "pg_data"))
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var map_node := (scene as PackedScene).instantiate()
	if not MAPS.has(id):
		map_node.call("configure_doc", custom)
	root.add_child(map_node)
	if map_node.has_method("map_props"):
		_draw_props(map_node.call("map_props"))
	if map_node.has_method("map_toys"):
		_draw_toys(map_node.call("map_toys"))

	# The map brings its own sun, sky and fill light (`PlaygroundGeometry.light`), the same
	# ones the client draws, so a second environment here would be the one ignored.

	_camera = Camera3D.new()
	_camera.fov = 70.0
	_camera.far = 800.0
	root.add_child(_camera)

	if args.has("--fx"):
		# Staged from the first frame, not here: during `_initialize` nothing added to the
		# root is inside the tree yet, so a global transform set on an effect is refused
		# and every effect is drawn at the origin.
		_fx_pending = true
		return

	_shots = _shots_for(id)


## A document map's props, drawn from the real prop scene and catalogue where the server
## would put them, frozen: a picture of the map without its doors and cars is not the map.
func _draw_props(entries: Array) -> void:
	var catalogue := PlaygroundSpawnables.catalogue()
	for entry: Dictionary in entries:
		var def := catalogue.get_prop(StringName(str(entry.get("id", ""))))
		if def == null:
			continue
		var scene := load(def.scene_path) as PackedScene
		if scene == null:
			continue
		var body := scene.instantiate()
		root.add_child(body)
		if body.has_method("configure"):
			body.call("configure", def)
		if body is RigidBody3D:
			(body as RigidBody3D).freeze = true
		var at: Array = entry["at"]
		(body as Node3D).position = Vector3(float(at[0]), float(at[1]), float(at[2]))
		(body as Node3D).rotation = Vector3(0.0, deg_to_rad(float(entry.get("yaw", 0.0))), 0.0)
		if entry.has("scale") and body.has_method("set_size_scale"):
			var _s: float = body.call("set_size_scale", float(entry["scale"]))
		if Color.html_is_valid(str(entry.get("tint", ""))) and body.has_method("set_tint"):
			body.call("set_tint", Color.html(str(entry["tint"])))


## The map's toys (dot-props'), as a client draws them: frozen where the map puts them.
func _draw_toys(placements: Array) -> void:
	if placements.is_empty():
		return
	var box := DotPropToyBox.new()
	box.name = "Toys"
	box.authoritative = false
	root.add_child(box)
	_toy_box = box
	_toy_placements = placements


var _toy_box: DotPropToyBox = null
var _toy_placements: Array = []


## Maps converted from a community .bsp (game-playground-maps' tools/import_bsp.py): they have no
## hand-picked angles, so these are worked out from the document, an oblique view over the
## whole thing, a high view straight down and the player's eye at the spawn facing the middle.
const IMPORTED := ["pgc_construct_small", "pgc_smallbase"]


func _imported_shots(id: String) -> Array[Dictionary]:
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://maps/custom/%s.json" % id))
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for b: Dictionary in doc["boxes"]:
		if str(b.get("material", "")) == "water":
			continue
		var at := Vector3(b["at"][0], b["at"][1], b["at"][2])
		var half := Vector3(b["size"][0], b["size"][1], b["size"][2]) / 2.0
		lo = lo.min(at - half)
		hi = hi.max(at + half)
	var centre := (lo + hi) / 2.0
	var ext := hi - lo
	var sp: Array = doc["spawn"]
	var spawn := Vector3(sp[0], sp[1] + 0.7, sp[2])
	var reach := maxf(ext.x, ext.z)
	return [
		{"name": id, "from": centre + Vector3(0.0, reach * 0.9, reach * 0.55), "at": centre},
		{"name": id + "_top", "from": centre + Vector3(0.0, reach * 1.1, 0.1), "at": centre},
		{"name": id + "_spawn", "from": spawn, "at": Vector3(centre.x, spawn.y - 0.3, centre.z)},
		{"name": id + "_side", "from": Vector3(lo.x + ext.x * 0.15, lo.y + minf(ext.y, 12.0), hi.z - ext.z * 0.15), "at": Vector3(centre.x, lo.y + 1.0, centre.z)},
	]


## Angles per map, because a 200 m sandbox with a park at one end and a movement corner at
## the other has nothing useful to say from one camera.
func _shots_for(id: String) -> Array[Dictionary]:
	if id in IMPORTED:
		return _imported_shots(id)
	if id == "pgc_plots":
		return [
			{"name": "pgc_plots", "from": Vector3(0.0, 70.0, 95.0), "at": Vector3(0.0, 0.0, -5.0)},
			{"name": "pgc_plots_deck", "from": Vector3(-66.0, 5.7, -66.0), "at": Vector3(0.0, 0.0, 0.0)},
			{"name": "pgc_plots_depot", "from": Vector3(-2.0, 2.5, -6.0), "at": Vector3(7.0, 0.5, 0.0)},
			{"name": "pgc_plots_pond", "from": Vector3(48.0, 6.0, 48.0), "at": Vector3(66.0, -1.5, 66.0)},
		]
	if id == "pgc_quarry":
		return [
			{"name": "pgc_quarry", "from": Vector3(55.0, 38.0, 85.0), "at": Vector3(0.0, -10.0, 0.0)},
			{"name": "pgc_quarry_spawn", "from": Vector3(0.0, 1.7, 62.0), "at": Vector3(0.0, -10.0, 10.0)},
			{"name": "pgc_quarry_hut", "from": Vector3(-26.0, -3.0, 6.0), "at": Vector3(-40.0, -5.0, 0.0)},
			{"name": "pgc_quarry_sump", "from": Vector3(-2.0, -7.0, 2.0), "at": Vector3(18.0, -13.0, -18.0)},
		]
	if id == "pgc_town":
		return [
			{"name": "pgc_town", "from": Vector3(-95.0, 60.0, 95.0), "at": Vector3(0.0, 0.0, 0.0)},
			{"name": "pgc_town_street", "from": Vector3(-3.0, 1.7, 75.0), "at": Vector3(-30.0, 2.0, 35.0)},
			{"name": "pgc_town_door", "from": Vector3(-45.0, 1.8, 12.0), "at": Vector3(-45.0, 1.5, 22.0)},
			{"name": "pgc_town_plaza", "from": Vector3(25.0, 6.0, 20.0), "at": Vector3(45.0, 0.0, 45.0)},
			{"name": "pgc_town_windows", "from": Vector3(-24.0, 3.0, 40.0), "at": Vector3(-40.0, 2.0, 28.0)},
			{"name": "pgc_town_inside", "from": Vector3(-52.0, 1.7, 31.0), "at": Vector3(-34.0, 1.7, 34.0)},
			{"name": "pgc_town_fountain", "from": Vector3(55.0, 3.0, 33.0), "at": Vector3(45.0, 0.3, 45.0)},
		]
	if id == "pgc_islands":
		return [
			{"name": "pgc_islands", "from": Vector3(0.0, 85.0, 110.0), "at": Vector3(0.0, 10.0, 0.0)},
			{"name": "pgc_islands_bridge", "from": Vector3(62.0, 9.7, 8.0), "at": Vector3(27.5, 13.0, 47.6)},
			{"name": "pgc_islands_slide", "from": Vector3(22.0, 37.5, -56.0), "at": Vector3(52.0, 6.0, -6.0)},
			{"name": "pgc_islands_lava", "from": Vector3(48.0, 14.0, 48.0), "at": Vector3(0.0, 0.0, 0.0)},
		]
	if id == "pgc_site":
		return [
			{"name": "pgc_site", "from": Vector3(70.0, 45.0, 80.0), "at": Vector3(-5.0, 5.0, -10.0)},
			{"name": "pgc_site_ramps", "from": Vector3(12.0, 8.0, -12.0), "at": Vector3(-8.0, 6.0, -28.0)},
			{"name": "pgc_site_top", "from": Vector3(-36.0, 15.2, -14.0), "at": Vector3(-10.0, 12.0, -28.0)},
			{"name": "pgc_site_dig", "from": Vector3(40.0, 5.0, -33.0), "at": Vector3(40.0, -1.5, -52.0)},
			{"name": "pgc_site_office", "from": Vector3(-14.0, 3.0, 50.0), "at": Vector3(-35.0, 1.2, 40.0)},
		]
	if id == "pgc_warehouse":
		return [
			{"name": "pgc_warehouse", "from": Vector3(60.0, 30.0, 75.0), "at": Vector3(0.0, 3.0, -10.0)},
			{"name": "pgc_warehouse_dock", "from": Vector3(0.0, 3.0, 22.0), "at": Vector3(0.0, 2.0, 0.0)},
			{"name": "pgc_warehouse_aisle", "from": Vector3(8.0, 2.9, -24.0), "at": Vector3(-25.0, 3.5, -24.0)},
			{"name": "pgc_warehouse_catwalk", "from": Vector3(-22.0, 8.9, -42.0), "at": Vector3(10.0, 5.0, -30.0)},
			{"name": "pgc_warehouse_cold", "from": Vector3(22.0, 3.2, -16.0), "at": Vector3(22.0, 1.4, -30.0)},
			{"name": "pgc_warehouse_office", "from": Vector3(-17.0, 3.2, -9.5), "at": Vector3(-30.0, 2.2, -4.0)},
		]
	if id == "pgc_canyon":
		return [
			{"name": "pgc_canyon", "from": Vector3(-30.0, 60.0, 120.0), "at": Vector3(0.0, 5.0, 0.0)},
			{"name": "pgc_canyon_floor", "from": Vector3(0.0, 1.7, 100.0), "at": Vector3(0.0, 12.0, 0.0)},
			{"name": "pgc_canyon_jump", "from": Vector3(-40.0, 23.0, 60.0), "at": Vector3(15.0, 20.0, 60.0)},
			{"name": "pgc_canyon_river", "from": Vector3(3.0, 3.0, -48.0), "at": Vector3(0.0, -1.5, -15.0)},
		]
	if id == "pgc_harbour":
		return [
			{"name": "pgc_harbour", "from": Vector3(-60.0, 55.0, 95.0), "at": Vector3(10.0, -4.0, -25.0)},
			{"name": "pgc_harbour_piers", "from": Vector3(-30.0, 1.7, 14.0), "at": Vector3(-50.0, -2.0, -30.0)},
			{"name": "pgc_harbour_lighthouse", "from": Vector3(55.0, 14.0, -50.0), "at": Vector3(80.0, 10.0, -80.0)},
			{"name": "pgc_harbour_gallery", "from": Vector3(84.5, 22.7, -75.5), "at": Vector3(20.0, -2.0, -20.0)},
			{"name": "pgc_harbour_office", "from": Vector3(-56.0, 2.5, 28.0), "at": Vector3(-70.0, 2.0, 40.0)},
		]
	if id == "pgc_bowl":
		return [
			{"name": "pgc_bowl", "from": Vector3(0.0, 60.0, 75.0), "at": Vector3(0.0, 0.0, -5.0)},
			{"name": "pgc_bowl_rim", "from": Vector3(0.0, 16.7, 44.0), "at": Vector3(0.0, 2.0, 0.0)},
			{"name": "pgc_bowl_floor", "from": Vector3(-12.0, 1.7, 12.0), "at": Vector3(20.0, 8.0, -25.0)},
			{"name": "pgc_bowl_chute", "from": Vector3(-6.0, 3.0, 8.0), "at": Vector3(30.0, 8.0, 0.0)},
		]
	if id == "pgc_obstacle":
		return [
			{"name": "pgc_obstacle", "from": Vector3(35.0, 35.0, 70.0), "at": Vector3(-20.0, 4.0, 5.0)},
			{"name": "pgc_obstacle_start", "from": Vector3(4.0, 2.5, 66.0), "at": Vector3(0.0, 3.0, 30.0)},
			{"name": "pgc_obstacle_gate", "from": Vector3(-26.5, 9.7, 1.0), "at": Vector3(-35.5, 9.0, -3.0)},
			{"name": "pgc_obstacle_tower", "from": Vector3(-27.0, 16.0, 20.0), "at": Vector3(-50.0, 13.0, -3.0)},
			{"name": "pgc_obstacle_pool", "from": Vector3(10.0, 5.0, 20.0), "at": Vector3(1.5, -0.5, 6.0)},
		]
	if id == "pgc_nature":
		return [
			{"name": "pgc_nature", "from": Vector3(-20.0, 70.0, 120.0), "at": Vector3(0.0, 0.0, 0.0)},
			{"name": "pgc_nature_lava", "from": Vector3(-34.0, 6.0, 64.0), "at": Vector3(-50.0, 0.3, 50.0)},
			{"name": "pgc_nature_pond", "from": Vector3(60.0, 4.0, 30.0), "at": Vector3(60.0, 0.5, 50.0)},
			{"name": "pgc_nature_greenhouse", "from": Vector3(6.0, 2.5, 38.0), "at": Vector3(0.0, 1.5, 50.0)},
			{"name": "pgc_nature_rink", "from": Vector3(-40.0, 4.0, -30.0), "at": Vector3(-55.0, 0.0, -50.0)},
			{"name": "pgc_nature_lake", "from": Vector3(-6.0, 7.0, -62.0), "at": Vector3(12.0, 1.5, -80.0)},
			{"name": "pgc_nature_swamp", "from": Vector3(-80.0, 4.0, 26.0), "at": Vector3(-95.0, 0.3, 10.0)},
		]
	if id == "pgc_slopes":
		return [
			{"name": "pgc_slopes", "from": Vector3(95.0, 55.0, 85.0), "at": Vector3(10.0, 5.0, -10.0)},
			{"name": "pgc_slopes_deck", "from": Vector3(9.0, 26.0, -3.0), "at": Vector3(0.0, 20.0, -24.0)},
			{"name": "pgc_slopes_halfpipe", "from": Vector3(55.0, 9.0, 40.0), "at": Vector3(55.0, 0.0, -10.0)},
			{"name": "pgc_slopes_pond", "from": Vector3(-34.0, 5.0, 46.0), "at": Vector3(-50.0, -0.5, 28.0)},
			{"name": "pgc_slopes_runout", "from": Vector3(22.0, 7.0, -66.0), "at": Vector3(0.0, 0.0, -82.0)},
		]
	if id != "pg_flatgrass":
		return [
			{"name": "%s_overview" % id, "from": Vector3(-90, 70, 90), "at": Vector3(0, 8, 0)},
			{"name": "%s_eye" % id, "from": Vector3(-20, 4, 30), "at": Vector3(0, 6, 0)},
		]

	return [
		# The whole field, so the middle can be seen to be empty, which is what a sandbox is for.
		{"name": "pg_flatgrass_overview", "from": Vector3(-150, 130, 150), "at": Vector3(0, 4, 0)},
		# Eye level in the middle, which is where a player actually stands.
		{"name": "pg_flatgrass_eye", "from": Vector3(-10, 2.0, 20), "at": Vector3(20, 6, -10)},
		# The toys: the park in the south-west, and the balls, barrels and lane by the spawn.
		{"name": "pg_flatgrass_park", "from": Vector3(-2.0, 5.0, 31.0), "at": Vector3(-13.0, 0.5, 14.0)},
		{"name": "pg_flatgrass_toys_spawn", "from": Vector3(-4.0, 3.0, 6.0), "at": Vector3(6.0, 0.3, 4.0)},
		# The movement corner: the staircase and both ramps.
		{"name": "pg_flatgrass_corner", "from": Vector3(0.0, 8.0, 10.0), "at": Vector3(10.0, 3.0, -22.0)},
	]


var _wait := 0
var _armed := false
var _fx_pending := false


# --- --fx -------------------------------------------------------------------

## A prop spawning and a prop on the end of the physics gun, drawn by the real presentation
## layer: [method PlaygroundPresentation.on_prop_spawned] and
## [method PlaygroundPresentation.on_tool_beam], from a player's eye on the field.
##
## [b]The puff is slowed to a twentieth of real speed and restarted once spawned[/b], for
## game-arena's reason: it lives 420 ms and a software frame under xvfb is long enough that
## the frame saved at full speed is the one after it went out. The beam is a mesh and is
## not affected. `present` is not called again, so dot-fx retires nothing while the
## frames are taken.
func _stage_fx() -> Array[Dictionary]:
	var presentation := PlaygroundPresentation.new()
	presentation.name = "Presentation"
	root.add_child(presentation)
	var built := presentation.setup()
	if not built.ok:
		push_error("the presentation layer: %s" % built.error.message)

	var eye := Vector3(0, 1.7, 8)
	var aim := Vector3(0, -0.05, -1).normalized()
	var puff_at := Vector3(1.6, 1.0, 3.5)
	var held_at := Vector3(-1.4, 1.6, 2.5)

	# A crate on the end of the gun, as `PlaygroundProp` draws one: an unshaded box.
	var crate := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.9, 0.9, 0.9)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.7, 0.5, 0.25)
	box.material = mat
	crate.mesh = box
	root.add_child(crate)
	crate.global_position = held_at

	presentation.present(0.016, eye, aim)
	presentation.fx.spawned.connect(func(fx_id: StringName, node: Node, why: StringName) -> void:
		print("fx: %s %s" % [fx_id, "drawn" if node != null else "refused (%s)" % why])
	)
	presentation.on_prop_spawned(puff_at, true)
	presentation.on_tool_beam(eye, aim, held_at)
	var missing := presentation.fx.catalogue.missing_scenes()
	print("fx: missing scenes: %s" % (", ".join(missing) if not missing.is_empty() else "none"))

	for particles in presentation.fx.find_children("*", "CPUParticles3D", true, false):
		(particles as CPUParticles3D).speed_scale = 0.05
		(particles as CPUParticles3D).restart()

	return [
		# What the player sees: the beam from low right of the view to the crate.
		{"name": "playground_fx", "from": eye, "at": eye + aim * 10.0},
		# From beside, which is the frame that says the beam ends on the crate and starts
		# in front of the eye rather than in it.
		{"name": "playground_fx_side", "from": Vector3(5.5, 2.6, 5.0), "at": Vector3(-0.5, 1.4, 4.0)},
	]


## [b]Frame-counted rather than awaited.[/b] `SceneTree._process` is expected to return a
## bool synchronously; making it a coroutine returns a signal object instead, which is
## truthy, so the tree quits on the first frame and writes nothing. That is what
## game-arena's first version of this file did and the reason its comment says so.
func _process(_delta: float) -> bool:
	# The toys build in the tree, which the root's children are not during `_initialize`.
	if _toy_box != null and _toy_box.count() == 0 and not _toy_placements.is_empty():
		var _built := _toy_box.build(_toy_placements)
		_toy_placements = []
		_wait = maxi(_wait, 2)

	if _fx_pending:
		_fx_pending = false
		_shots = _stage_fx()
		return false

	if _index >= _shots.size():
		return true

	if _wait > 0:
		_wait -= 1
		return false

	if not _armed:
		var shot: Dictionary = _shots[_index]
		_camera.position = shot["from"]
		_camera.look_at(shot["at"], Vector3.UP)
		_armed = true
		# Three frames before grabbing. The viewport's texture is the last COMPLETED
		# frame, so grabbing in the same frame the camera moved saves the previous shot
		# under the new shot's name — which looks exactly like a camera that did not
		# move.
		_wait = 3
		return false

	var image := root.get_texture().get_image()
	var path := OUT_DIR.path_join("%s.png" % _shots[_index]["name"])
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_index += 1
	_armed = false
	return false
