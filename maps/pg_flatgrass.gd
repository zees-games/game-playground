extends "../game/playground_map.gd"

const PlaygroundGeometry := preload("../game/playground_geometry.gd")
const PlaygroundMaterials := preload("../game/playground_materials.gd")

## `pg_flatgrass` — the default map: a big flat field of grass under an open sky.
##
## [b]This is where a server is when it is not anywhere in particular[/b], and on a
## sandbox that is most of the time: a 200 m plate to build on, walls so props stay in and
## players do not walk off into nothing, a staircase and two ramps so stair stepping and
## surfing are visible without loading anything, the park of map toys round the spawn, and
## room for a hundred props between them.
##
## [b]Nothing here is timed.[/b] The game ships no run timer, and this map is the proof that
## nothing in it needs one; a server that adds dot-timer times the maps that carry zones.
## Grass rather than the grey grid, because a sandbox's default is the map people see first
## and a field reads as somewhere to play: the grass is dot-physics' `grass`, so it also
## sounds and grips like grass.

## The floor plate, and the walls round it.
const SIZE := 200.0
const WALL_HEIGHT := 10.0


func _build() -> void:
	PlaygroundGeometry.light(self)

	fallback_spawn = Vector3(0.0, 1.0, 0.0)

	var ground := PlaygroundGeometry.box(
		self,
		Vector3(0.0, -0.5, 0.0),
		Vector3(SIZE, 1.0, SIZE),
		PlaygroundMaterials.look("grass", PlaygroundGeometry.COLOUR_FLOOR)
	)
	PlaygroundMaterials.apply(ground, "grass")

	# Walls, so props stay in and players do not walk off into nothing.
	for side in [-1.0, 1.0]:
		PlaygroundGeometry.box(
			self,
			Vector3(side * SIZE * 0.5, WALL_HEIGHT * 0.4, 0.0),
			Vector3(1.0, WALL_HEIGHT, SIZE),
			PlaygroundGeometry.COLOUR_PLATFORM
		)
		PlaygroundGeometry.box(
			self,
			Vector3(0.0, WALL_HEIGHT * 0.4, side * SIZE * 0.5),
			Vector3(SIZE, WALL_HEIGHT, 1.0),
			PlaygroundGeometry.COLOUR_PLATFORM
		)

	_build_movement_corner()


## The movement corner's steep ramp: past `max_slope_angle`, so it is only ever surfed.
const STEEP_RAMP_AT := Vector3(24.0, 8.0, 20.0)
const STEEP_RAMP_SIZE := Vector3(20.0, 0.8, 30.0)
const STEEP_RAMP_ANGLE := 55.0


## What `PlaygroundMapSurvey` may find unreached here, and why.
##
## - [b]The tops of the four walls.[/b] 9 m up, 1 m wide: they keep props in.
## - [b]The crest of the steep ramp.[/b] A 55-degree slab's upper edge is a strip of its
##   0.8 m end face tilted 35 degrees from level — standable, 16 m up, at the top of a face
##   nobody can climb. Only a noclip gets there.
func survey_declared() -> Array:
	var top := WALL_HEIGHT * 0.4 + WALL_HEIGHT * 0.5
	var half := SIZE * 0.5
	var out: Array = []

	for side in [-1.0, 1.0]:
		out.append({
			"box": AABB(Vector3(side * half - 0.5, top - 0.5, -half - 0.5), Vector3(1.0, 1.0, SIZE + 1.0)),
			"why": "the top of the plate's wall, 9 m up: it keeps props in",
		})
		out.append({
			"box": AABB(Vector3(-half - 0.5, top - 0.5, side * half - 0.5), Vector3(SIZE + 1.0, 1.0, 1.0)),
			"why": "the top of the plate's wall, 9 m up: it keeps props in",
		})

	var ramp := Transform3D(
		Basis(Vector3.FORWARD, deg_to_rad(STEEP_RAMP_ANGLE)), STEEP_RAMP_AT
	)
	var bounds := ramp * AABB(-STEEP_RAMP_SIZE * 0.5, STEEP_RAMP_SIZE)
	out.append({
		"box": AABB(Vector3(bounds.position.x, bounds.end.y - 1.0, bounds.position.z),
			Vector3(bounds.size.x, 1.0, bounds.size.z)),
		"why": "the crest of the movement corner's steep ramp, 16 m up a face nobody can climb",
	})

	return out


## A staircase and two ramps, so the movement is visible without leaving the sandbox.
##
## The staircase is what makes stair
## stepping visible, the shallow ramp is one a player walks up, and the steep one is
## past `max_slope_angle` and can only be surfed — which is somewhere to learn it
## without loading a surf map.
func _build_movement_corner() -> void:
	for i in range(6):
		PlaygroundGeometry.box(
			self,
			Vector3(-24.0 + float(i) * 2.0, float(i) * 0.35 - 0.175, -24.0),
			Vector3(2.0, 0.35 + float(i) * 0.7, 8.0),
			PlaygroundGeometry.COLOUR_PLATFORM
		)

	PlaygroundGeometry.ramp(
		self,
		Vector3(24.0, 2.0, -20.0),
		Vector3(14.0, 0.8, 20.0),
		30.0,
		Vector3.FORWARD
	)

	PlaygroundGeometry.ramp(
		self, STEEP_RAMP_AT, STEEP_RAMP_SIZE, STEEP_RAMP_ANGLE, Vector3.FORWARD
	)


## The sandbox's toys (dot-props'): balls and barrels round the spawn, a bowling lane north of
## it, and a park to the south-west with a roundabout, a see-saw, a swing, trampolines, a
## fountain, lamps on a switch, a bell and a horn. Everything clear of the movement corner. Indices matter: the switch names the lamps by theirs.
func map_toys() -> Array:
	var out: Array = [
		# Round the spawn: what somebody shoots at first.
		{"toy": "beach_ball", "at": [3.0, 0.0, -5.0]},
		{"toy": "beach_ball", "at": [-3.5, 0.0, -7.0]},
		{"toy": "football", "at": [5.0, 0.0, -9.0]},
		{"toy": "barrel", "at": [9.0, 0.0, 3.0]},
		{"toy": "barrel", "at": [9.8, 0.0, 3.6], "yaw": 40.0},
		{"toy": "barrel", "at": [9.2, 0.0, 4.4], "yaw": 75.0},
		{"toy": "tyre", "at": [7.0, 0.0, 8.0], "yaw": 20.0},
		# A bowling lane, ball at the near end and six pins at the far.
		{"toy": "bowling_ball", "at": [5.0, 0.0, 13.0]},
	]
	for row in range(3):
		for i in range(row + 1):
			out.append({"toy": "bowling_pin", "at": [5.0 + (float(i) - float(row) * 0.5) * 0.45, 0.0, 22.0 + float(row) * 0.4]})
	var lamps := out.size()
	out.append_array([
		# The park, in three rows of three, four metres apart and more.
		{"toy": "lamp_post", "at": [-21.0, 0.0, 6.0]},
		{"toy": "lamp_post", "at": [-3.0, 0.0, 25.0]},
		{"toy": "light_switch", "at": [-3.0, 0.0, 6.0], "links": [lamps, lamps + 1]},
		{"toy": "seesaw", "at": [-18.0, 0.0, 10.0]},
		{"toy": "merry_go_round", "at": [-12.0, 0.0, 10.0]},
		{"toy": "wobbly_platform", "at": [-6.5, 0.0, 10.0]},
		{"toy": "swing", "at": [-18.0, 0.0, 16.0]},
		{"toy": "fountain", "at": [-12.0, 0.0, 16.0]},
		{"toy": "trampoline", "at": [-6.5, 0.0, 16.0]},
		{"toy": "punching_bag", "at": [-18.0, 0.0, 22.0]},
		{"toy": "bell", "at": [-12.0, 0.0, 22.5]},
		{"toy": "bounce_pad", "at": [-6.5, 0.0, 22.0]},
		{"toy": "horn", "at": [-21.0, 0.0, 25.0]},
	])
	return out
