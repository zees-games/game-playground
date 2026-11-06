extends "res://game/playground_map_survey_base.gd"

## A slot and reach sweep over a built-in map's boxes: what a player can stand on, what
## they can get to from a spawn, what they cannot get back out of, and where two boxes
## leave a crack narrower than a player.
##
## [b]Why a map needs this when every route on it is already driven by a bot.[/b] A route
## check asks about the boxes a route names. Nothing asked about the boxes it does not —
## the top of a backstop, the shelf a ramp leaves against a wall, a floor under a course
## that a player who falls lands on and cannot leave — and a sandbox is mostly boxes no
## route names. Every one of those is found by a player on a live server, reported as
## "stuck", and fixed with a `respawn`. This asks the geometry instead.
##
## [b]How it works.[/b] The boxes are read off the built map (every [StaticBody3D] with a
## [BoxShape3D], rotated or not) and rasterised into columns on a [constant CELL] grid:
## each column is the list of solid spans a vertical line through it passes. The top of a
## span is somewhere to stand if the face it leaves through is no steeper than
## [constant MAX_SLOPE], there is [constant HEIGHT] of air above it, and nothing in the
## neighbouring columns intrudes into the player's hull. Standable cells are joined into
## REGIONS by walking (a step of at most [constant STEP] between neighbours), and regions
## are joined into a directed graph by dropping off an edge, sliding down a face nobody can
## stand on, and jumping a gap inside `PlaygroundMap.jump_reach(rise)`.
##
## - [b]Unreached[/b]: a region no spawn's region leads to. Either a mistake, or somewhere
##   only a moderator's noclip goes, which the map says with [code]survey_declared()[/code].
## - [b]Trapped[/b]: a region a spawn leads to, which leads to none of: a spawn, a finish
##   zone, a respawn zone, or a fall into one. A player there can only type `respawn`.
## - [b]Slots[/b]: two boxes whose sides face each other across less than
##   [constant PLAYER_WIDTH] of air, over more than a step's height. A passage that looks
##   open and is not, or a crack that holds a body.
##
## [b]What it does not do, on purpose.[/b] A jump is judged box edge to box edge from above,
## as every route check here is, and not swept through the air: a wall between two
## platforms does not stop the survey's jump. Bunny-hop speed is not modelled — the reach
## is a running jump's, so a gap only a carried-speed player crosses reads as unreachable,
## which errs toward reporting. And the slot sweep uses a tilted box's world AABB rather
## than its true shape, so a ramp can only ever be over-reported. Each of these is a place
## to extend it the day a map needs it, not a bug.
##
## Reimplemented from a description of game-arena's `arena_map_survey.gd` (`[gate-sweep-2]`)
## rather than copied: separate repositories, and the family's rule is a copy per project.



## Surveys a built map. [param spawns] are the points players are put at; [param ways_out]
## says where a finish or a respawn is, as `{box: AABB, pit: bool}` (a pit is a respawn
## volume a fall can land in; see [method ways_out_of]); [param declared] is the map's list of
## `{box: AABB, why: String}` for areas it knows no spawn reaches.
##
## Returns `{cells, regions, slots, unreached, trapped, spawnless, void_falls}`, where
## `slots`, `unreached` and `trapped` are human-readable lines and `spawnless` lists the
## spawns that are not over standable ground.
static func survey(
	map: Node3D, ways_out: Array, spawns: Array[Vector3], declared: Array
) -> Dictionary:
	var s := new()
	s._collect(map)
	return s._run(ways_out, spawns, declared)


## Surveys a list of solids directly: for a fixture that is not a map.
static func survey_solids(
	boxes: Array[Solid], ways_out: Array, spawns: Array[Vector3], declared: Array
) -> Dictionary:
	var s := new()
	s.solids = boxes
	return s._run(ways_out, spawns, declared)


## The ways out a run timer's zone set declares: every box END zone, and every box RESPAWN
## zone as a pit too. [param zones] is a dot-timer `DotTimerZoneSet` or null, read by duck
## typing because the timer is an optional addon here and a script naming its classes does
## not compile without it (see `addons/pg_timer`).
static func ways_out_of(zones: Object) -> Array:
	var out: Array = []

	if zones == null:
		return out

	for zone: Object in zones.get("zones"):
		var consts: Dictionary = zone.get_script().get_script_constant_map()
		if int(zone.get("shape")) != int((consts["Shape"] as Dictionary)["BOX"]):
			continue
		var kind := int(zone.get("kind"))
		var kinds: Dictionary = consts["Kind"]
		var from: Vector3 = zone.get("from")
		var to: Vector3 = zone.get("to")
		if kind == int(kinds["END"]) or kind == int(kinds["RESPAWN"]):
			out.append({"box": AABB(from, to - from).abs(), "pit": kind == int(kinds["RESPAWN"])})

	return out


## A solid from a centre, a size and an optional basis — `PlaygroundGeometry.box`'s
## arguments.
static func solid(at: Vector3, size: Vector3, basis: Basis = Basis.IDENTITY) -> Solid:
	var out := Solid.new()
	out.xform = Transform3D(basis, at)
	out.inverse = out.xform.affine_inverse()
	out.size = size
	out.upright = basis.y.normalized().dot(Vector3.UP) > 0.9999

	var half := size * 0.5
	var low := Vector3(INF, INF, INF)
	var high := -low

	for i in range(8):
		var corner := Vector3(
			half.x * (1.0 if i & 1 else -1.0),
			half.y * (1.0 if i & 2 else -1.0),
			half.z * (1.0 if i & 4 else -1.0)
		)
		var world := out.xform * corner
		low = low.min(world)
		high = high.max(world)

	out.bounds = AABB(low, high - low)
	return out


func _collect(map: Node3D) -> void:
	for child in map.get_children():
		var body := child as StaticBody3D

		if body == null:
			continue

		for part in body.get_children():
			var shape := part as CollisionShape3D

			if shape == null or not (shape.shape is BoxShape3D):
				continue

			var xform := body.transform * shape.transform
			solids.append(solid(xform.origin, (shape.shape as BoxShape3D).size, xform.basis))


func _run(ways_out: Array, spawns: Array[Vector3], declared: Array) -> Dictionary:
	var slots := _slots()

	_rasterise()
	_find_cells()
	_join_regions()
	_link_regions(ways_out)

	# Forward from every spawn.
	var starts: Dictionary = {}
	var spawnless: Array[String] = []

	for spawn in spawns:
		var node := _cell_under(spawn)

		if node < 0:
			spawnless.append("(%.1f, %.1f, %.1f)" % [spawn.x, spawn.y, spawn.z])
		else:
			starts[_node_region[node]] = true
			_escapes[_node_region[node]] = true

	var reached := _flood(starts.keys(), _out)

	# Backward from every way out.
	var back: Array[Dictionary] = []
	for _i in range(_out.size()):
		back.append({})
	for from in range(_out.size()):
		for to: int in _out[from]:
			back[to][from] = true

	var safe := _flood(_escapes.keys(), back)

	var unreached: Array[String] = []
	var trapped: Array[String] = []

	for region in range(_region_count.size()):
		var low := _region_low[region]
		var high := _region_high[region]
		var what := "%d cells from (%.1f, %.1f, %.1f) to (%.1f, %.1f, %.1f)" % [
			_region_count[region], low.x, low.y, low.z, high.x, high.y, high.z,
		]

		if not reached.has(region):
			if not _is_declared(region, declared):
				unreached.append(what)
		elif not safe.has(region):
			trapped.append(what)

	return {
		"cells": _node_col.size(),
		"regions": _region_count.size(),
		"slots": slots,
		"unreached": unreached,
		"trapped": trapped,
		"spawnless": spawnless,
		"void_falls": _void_falls,
	}


# --- Slots -------------------------------------------------------------------

func _slots() -> Array[String]:
	var found: Array[String] = []

	for i in range(solids.size()):
		var a := solids[i]

		for j in range(i + 1, solids.size()):
			var b := solids[j]

			# Near each other at all, from above.
			var grown := a.bounds.grow(PLAYER_WIDTH)
			if not grown.intersects(b.bounds):
				continue

			# Side by side over more than a step: a crack between two floors a player
			# steps over is not a passage.
			var band := minf(a.bounds.end.y, b.bounds.end.y) \
				- maxf(a.bounds.position.y, b.bounds.position.y)
			if band <= STEP:
				continue

			var gap := _footprint_gap(a, b)

			if gap > 0.001 and gap < PLAYER_WIDTH:
				var at := (a.xform.origin + b.xform.origin) * 0.5
				found.append("%.2f m between the boxes at (%.1f, %.1f, %.1f) and (%.1f, %.1f, %.1f), near (%.1f, %.1f, %.1f)" % [
					gap, a.xform.origin.x, a.xform.origin.y, a.xform.origin.z,
					b.xform.origin.x, b.xform.origin.y, b.xform.origin.z, at.x, at.y, at.z,
				])

	return found


## The clear air between two boxes seen from above. Exact for boxes turned only about
## the vertical; a tilted box is its world AABB.
static func _footprint_gap(a: Solid, b: Solid) -> float:
	if not (a.upright and b.upright):
		return PlaygroundMap.gap_between(a.bounds, b.bounds)

	var pa := _footprint(a)
	var pb := _footprint(b)

	if _polygons_overlap(pa, pb):
		return 0.0

	var best := INF
	for k in range(4):
		for p in pb:
			best = minf(best, _point_segment(p, pa[k], pa[(k + 1) % 4]))
		for p in pa:
			best = minf(best, _point_segment(p, pb[k], pb[(k + 1) % 4]))
	return best


static func _footprint(s: Solid) -> PackedVector2Array:
	var x := s.xform.basis.x * s.size.x * 0.5
	var z := s.xform.basis.z * s.size.z * 0.5
	var c := s.xform.origin
	var out := PackedVector2Array()
	for corner in [c - x - z, c + x - z, c + x + z, c - x + z]:
		out.append(Vector2((corner as Vector3).x, (corner as Vector3).z))
	return out


static func _polygons_overlap(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for poly in [a, b]:
		var p := poly as PackedVector2Array
		for k in range(p.size()):
			var edge := p[(k + 1) % p.size()] - p[k]
			var axis := Vector2(-edge.y, edge.x)
			var a_lo := INF
			var a_hi := -INF
			var b_lo := INF
			var b_hi := -INF
			for v in a:
				a_lo = minf(a_lo, v.dot(axis))
				a_hi = maxf(a_hi, v.dot(axis))
			for v in b:
				b_lo = minf(b_lo, v.dot(axis))
				b_hi = maxf(b_hi, v.dot(axis))
			if a_hi < b_lo - 1e-6 or b_hi < a_lo - 1e-6:
				return false
	return true


static func _point_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-12), 0.0, 1.0)
	return p.distance_to(a + ab * t)


# --- Columns -----------------------------------------------------------------

