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
##   xvfb-run -a godot --path . --script tools/screenshot.gd -- --map pg_lobby
##   tools/screenshot.sh pg_lobby --fx     # a spawn puff and the physics gun's beam
##
## Needs a real rendering context, so it does NOT run under `--headless`; `xvfb-run` is
## how it runs on a machine with no display. It writes into `screenshots/`, which is
## gitignored — the frame is evidence for a review, not an asset.

const OUT_DIR := "screenshots"

const MAPS := {
	"pg_lobby": "res://maps/pg_lobby.tscn",
	"pg_surf_intro": "res://maps/pg_surf_intro.tscn",
	"pg_bhop_intro": "res://maps/pg_bhop_intro.tscn",
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
	var id := args[index + 1] if index >= 0 and index + 1 < args.size() else "pg_lobby"

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


## Angles per map, because a 200 m sandbox with two courses in opposite corners has
## nothing useful to say from one camera.
func _shots_for(id: String) -> Array[Dictionary]:
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
	if id == "pg_bhop_intro":
		# Two routes, and the frames have to show they ARE two: the main run down x = 0
		# and the narrows six metres up at x = 28. An overview from straight above shows
		# neither the height between them nor the narrowing, so both of these are shot
		# from off to one side and low.
		return [
			# Both routes at once, from beside and above the start. The one angle that
			# shows the narrows to be a separate course rather than a wider shoulder of
			# the main one.
			{
				"name": "pg_bhop_intro_overview",
				"from": Vector3(108.0, 54.0, 52.0),
				"at": Vector3(14.0, -2.0, -62.0),
			},
			# Down the narrows from behind its start pad, at a player's height. This is
			# the frame that says whether the narrowing reads: ten blocks going away
			# from the camera, each one a little less wide than the last.
			{
				"name": "pg_bhop_intro_narrows",
				"from": Vector3(28.0, 9.5, 26.0),
				"at": Vector3(28.0, 5.0, -46.0),
			},
			# Square across both routes, from just above the narrows' height. Nearly
			# perpendicular on purpose: from any angle down the length the two courses
			# overlap in the frame and the higher one reads as the far side of the
			# lower. This is the frame that shows there are six metres between them.
			{
				"name": "pg_bhop_intro_both",
				"from": Vector3(86.0, 11.0, -34.0),
				"at": Vector3(0.0, 3.0, -38.0),
			},
			# Bonus 2, the switchback: three legs climbing west-east-west up to the
			# finish at 9 m. From the south and well above, looking down at forty
			# degrees. [b]The first attempt was from the south-west at twenty
			# degrees and 47 m out[/b], and a 3 m block at that range and angle is a
			# sliver on the horizon: the route was a smudge beside the main run's
			# much bigger blocks. Down at it is the only angle where the three legs
			# and both turns are separate things.
			{
				"name": "pg_bhop_intro_switchback",
				"from": Vector3(-36.0, 27.0, -12.0),
				"at": Vector3(-36.5, 4.0, 4.0),
			},
			# The first turn from beside it, at the height of the leg it turns onto:
			# the frame that says whether a turning block reads as a turn rather than
			# as one more block in a line.
			{
				"name": "pg_bhop_intro_switchback_turn",
				"from": Vector3(-58.0, 9.0, 18.0),
				"at": Vector3(-42.0, 4.0, 4.0),
			},
			# Bonus 3, the ascent: four jumps onto blocks and four ramps up off them,
			# climbing from 2 m to 10 m along z at x = 60. From square beside it and a
			# little above the top, because the thing the frame has to show is the
			# PROFILE — each ramp steeper than the last — and from any angle down the
			# route the ramps foreshorten into the blocks.
			{
				"name": "pg_bhop_intro_ascent",
				"from": Vector3(100.0, 8.0, -22.0),
				"at": Vector3(60.0, 6.0, -22.0),
			},
			# And from behind the pad at a player's height: what a player sees before
			# the first jump, a green pad, a gap, and the first ramp going up.
			{
				"name": "pg_bhop_intro_ascent_start",
				"from": Vector3(60.0, 5.5, 17.0),
				"at": Vector3(60.0, 4.0, -20.0),
			},
			# Bonus 4, the ladder: eleven jumps a metre up each, along z at x = -76.
			# From square beside it on the west, where nothing stands behind it, for
			# the ascent's reason: the frame has to show the PROFILE, a staircase of
			# columns each a metre taller than the last.
			{
				"name": "pg_bhop_intro_ladder",
				"from": Vector3(-124.0, 12.0, -20.0),
				"at": Vector3(-76.0, 7.0, -20.0),
			},
			# And from behind the pad at a player's height: the first rung a metre
			# over the pad, and the climb going away up the line.
			{
				"name": "pg_bhop_intro_ladder_start",
				"from": Vector3(-78.5, 4.5, 16.0),
				"at": Vector3(-76.0, 7.0, -20.0),
			},
			# Bonus 5, the float: seven jumps too far for the ground, along z at x = 120.
			# From the east, where nothing stands behind it (the ascent's profile camera
			# is at x = 100, on the other side), so the frame is the gaps: columns far
			# further apart than anywhere else on the map, every other one 2 m up.
			{
				"name": "pg_bhop_intro_float",
				"from": Vector3(176.0, 12.0, -30.0),
				"at": Vector3(120.0, 5.0, -30.0),
			},
			# And from behind the pad at a player's height: the first gap, which reads
			# as one nobody can jump, because outside the zone nobody can.
			{
				"name": "pg_bhop_intro_float_start",
				"from": Vector3(122.5, 4.5, 16.0),
				"at": Vector3(120.0, 4.0, -20.0),
			},
			# Bonus 6, the drop: eight jumps down, 3 m each, along z at x = -150. From the
			# west, where nothing stands behind it (the ladder's profile camera is at
			# x = -124, on the other side), so the frame is the staircase: a 25 m pad tower
			# and columns stepping down to the finish at the other starts' height.
			{
				"name": "pg_bhop_intro_drop",
				"from": Vector3(-212.0, 20.0, -28.0),
				"at": Vector3(-150.0, 12.0, -28.0),
			},
			# And from above and behind the pad, down the line: the columns stepping away
			# below the pad's lip. At a player's height the lip hides every one of them,
			# which is the drop's point and makes a frame of nothing but pad.
			{
				"name": "pg_bhop_intro_drop_start",
				"from": Vector3(-147.0, 36.0, 22.0),
				"at": Vector3(-150.0, 10.0, -40.0),
			},
		]

	if id == "pg_surf_intro":
		# Two routes, and they are at right angles to each other in what they ask for:
		# the main valley runs 220 m down x = 0 with its descent in the floor between
		# the ramps, and the plunge is one 48 m face at x = 60 that drops 61 m. An
		# overview from above shows the valley and makes the plunge read as a wall, so
		# two of these three are shot from beside it and low.
		return [
			# Both routes at once, from beside and above the start pads.
			{
				"name": "pg_surf_intro_overview",
				"from": Vector3(148.0, 78.0, 84.0),
				"at": Vector3(20.0, -6.0, -78.0),
			},
			# Square across the plunge, from the height of its middle. The frame that
			# says whether a 52° face reads as something you fall DOWN rather than
			# something you fall OFF — from any angle along the run it is a line.
			{
				"name": "pg_surf_intro_plunge",
				"from": Vector3(138.0, 44.0, -20.0),
				"at": Vector3(60.0, 2.0, -30.0),
			},
			# Over the shoulder of somebody on the pad, looking down the route. NOT
			# from eye height ON the pad: a face that falls away in front of you is
			# invisible from standing on the lip, so that frame is a green rectangle
			# and says nothing about the map. Raised and set back instead, which is
			# the angle that shows the pad, the lip and the whole descent at once.
			{
				"name": "pg_surf_intro_plunge_eye",
				"from": Vector3(96.0, 50.0, 30.0),
				"at": Vector3(60.0, 9.0, -30.0),
			},
			# Bonus 2, the cascade: eleven jumps down a slalom of blocks at x = -60,
			# from 40 m to 26 m over 70 m of Z. Square beside it from the west, a little
			# above its middle, because the thing this frame has to show is the PROFILE
			# — every block lower than the last — from above at forty-five degrees, so the
			# block tops read too. [b]The first angle was from above and
			# behind the pad[/b], which put the main run's 220 m ramp across the whole
			# background and made the staircase a scatter of tiles in front of it.
			{
				"name": "pg_surf_intro_cascade",
				"from": Vector3(-94.0, 62.0, -28.0),
				"at": Vector3(-60.0, 30.0, -28.0),
			},
			# From over the backstop and above a player's head: the staircase falling
			# away in front of them, which is the first thing a player on bonus 2 sees.
			# Over the backstop, not behind it — from behind it the frame is a wall.
			{
				"name": "pg_surf_intro_cascade_start",
				"from": Vector3(-60.0, 48.0, 16.0),
				"at": Vector3(-60.0, 30.0, -30.0),
			},
			# Bonus 3, the long bank: one face at x = 110, banked 56 degrees and falling
			# 17 m over 140 m of Z. From the low side, above and behind the pad, looking
			# along and across its face, so the frame shows the thing it is: a face tilted toward the
			# camera that runs away downhill, with the finish pad past its far end.
			{
				"name": "pg_surf_intro_bank",
				"from": Vector3(66.0, 66.0, 28.0),
				"at": Vector3(110.0, 22.0, -70.0),
			},
			# Over the backstop, down the bank: what a rider on the pad is about to drop on.
			{
				"name": "pg_surf_intro_bank_start",
				"from": Vector3(104.0, 47.0, 16.0),
				"at": Vector3(110.0, 26.0, -60.0),
			},
			# Bonus 4, the transfer: two faces facing each other across a gap, the first
			# (right, x 165..177) from the pad and the second (left, x 152..163) lower and
			# starting a third of the way down it. From behind and above the pair, down the
			# valley between them, so the frame shows the gap a rider crosses.
			{
				"name": "pg_surf_intro_transfer",
				"from": Vector3(163.0, 66.0, 34.0),
				"at": Vector3(161.0, 14.0, -80.0),
			},
			# Over the backstop, down the first face, with the second face across the gap.
			{
				"name": "pg_surf_intro_transfer_start",
				"from": Vector3(170.0, 47.0, 16.0),
				"at": Vector3(164.0, 24.0, -60.0),
			},
		]

	if id != "pg_lobby":
		return [
			{"name": "%s_overview" % id, "from": Vector3(-90, 70, 90), "at": Vector3(0, 8, 0)},
			{"name": "%s_eye" % id, "from": Vector3(-20, 4, 30), "at": Vector3(0, 6, 0)},
		]

	# The middle of the jump course, which moved when the course grew from nine
	# platforms to twelve: it now runs from z = 56 to z = -20 and climbs to 16 m, so a
	# camera aimed at the old midpoint looked at the first third of it and cut the
	# climb off at the top of the frame.
	var course := Vector3(60.0, 11.0, 14.0)
	var tower := Vector3(-60.0, 7.0, 60.0)

	return [
		# The whole plate, so the two courses can be seen to be in opposite corners and
		# the middle can be seen to be empty, which is what a sandbox is for.
		{"name": "pg_lobby_overview", "from": Vector3(-150, 130, 150), "at": Vector3(0, 4, 0)},
		# Eye level in the middle, which is where a player actually stands.
		{"name": "pg_lobby_eye", "from": Vector3(-10, 2.0, 20), "at": Vector3(20, 6, -10)},
		# The toys: the park in the south-west, and the balls, barrels and lane by the spawn.
		{"name": "pg_lobby_park", "from": Vector3(-2.0, 5.0, 31.0), "at": Vector3(-13.0, 0.5, 14.0)},
		{"name": "pg_lobby_toys_spawn", "from": Vector3(-4.0, 3.0, 6.0), "at": Vector3(6.0, 0.3, 4.0)},
		# Bonus 1: the jump course, along its length.
		{"name": "pg_lobby_course", "from": Vector3(86, 26, 72), "at": course},
		# Bonus 2: the tower, from above its top and well out from it.
		#
		# [b]Both parts matter and the first attempt got both wrong.[/b] From below, the
		# spiral's far side is hidden behind the pillar and the sandbox wall cuts the
		# frame in half at exactly the height the platforms are; from close in, a 70
		# degree lens puts the top of the tower off the top of the picture. Looking
		# DOWN at it from outside is the only angle that shows a spiral to be a spiral
		# rather than a scattering of slabs.
		{"name": "pg_lobby_tower", "from": Vector3(-36, 21, 84), "at": tower},
		# The tower's base at eye height, from just off the pad.
		#
		# Shot from BESIDE it rather than from the spawn point looking along the course.
		# From the spawn, a dev-textured spiral is a few identical slabs against the sky
		# with nothing to give them a scale — which is honestly what a player sees and
		# is useless as evidence. From the side, the pad, the pillar and the first turn
		# are all in one frame and a person can tell whether the first jump is a jump.
		{"name": "pg_lobby_tower_eye", "from": Vector3(-72, 5.0, 48), "at": Vector3(-59, 6.0, 61)},

		# Bonus 3, the circuit. Two angles, because the two things worth looking at are
		# opposite: whether the lap reads as a closed loop round the whole plate (from
		# high above the corner), and whether the road reads as a road at a driver's
		# height (down the start/finish straight, from the grid).
		{"name": "pg_lobby_circuit", "from": Vector3(-120, 105, 130), "at": Vector3(0, 0, 30)},
		{"name": "pg_lobby_circuit_grid", "from": Vector3(-26, 3.0, 82), "at": Vector3(40, 2.0, 82)},

		# Bonus 4, the stepping stones: ten columns at z = -56 from x 15 to 54, shrinking
		# from 2 m across to 1 m. From the north and above, square to the line, so the
		# shrinking and the sway either side of the line both read; and from behind the
		# pad and off to one side at a little over head height: straight down the line the
		# columns stand behind each other and read as one.
		{"name": "pg_lobby_stones", "from": Vector3(34, 16, -34), "at": Vector3(34, 3.0, -56)},
		{"name": "pg_lobby_stones_start", "from": Vector3(5, 9.0, -49), "at": Vector3(30, 4.0, -57)},

		# Bonus 5, the launch: three decks and a finish at x = -50 from z 2 to 44.5, tops 2,
		# 5, 8 and 8 m, each deck's far end an amber booster. From the empty east side, level
		# with the middle deck, so the steps up read as more than a jump; and from behind the
		# pad, where the boosters read as the way on.
		{"name": "pg_lobby_launch", "from": Vector3(-24, 11.0, 23), "at": Vector3(-50, 5.0, 23)},
		{"name": "pg_lobby_launch_start", "from": Vector3(-40, 13.0, -8), "at": Vector3(-50, 4.0, 22)},

		# Bonus 6, the relay: three legs at z 46, 56 and 66 between x 10 and 38, pads at 2,
		# 6 and 10 m, the first two ending in a violet gate hanging in the air. From the
		# south-east and above, so the three tiers and both gates are in one frame; and from
		# behind the first pad and north of the line at a little over head height, looking up
		# the first leg at its gate, which is what a player sees before the first teleport
		# (from the south the movement corner's steep ramp fills half the frame).
		{"name": "pg_lobby_relay", "from": Vector3(52, 22.0, 24), "at": Vector3(24, 6.0, 56)},
		{"name": "pg_lobby_relay_start", "from": Vector3(5, 7.0, 51), "at": Vector3(32, 3.0, 45)},
	]


var _wait := 0
var _armed := false
var _fx_pending := false


# --- --fx -------------------------------------------------------------------

## A prop spawning and a prop on the end of the physics gun, drawn by the real presentation
## layer: [method PlaygroundPresentation.on_prop_spawned] and
## [method PlaygroundPresentation.on_tool_beam], from a player's eye on the lobby's plate.
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
