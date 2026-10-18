extends RefCounted

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

const PlaygroundMap := preload("playground_map.gd")

## Grid spacing, metres.
const CELL := 0.25

## The family's number for a player's width. A slot narrower than this is closed.
const PLAYER_WIDTH := 0.8

## A standing player's height, and the step the controller climbs without a jump. Copied
## from `PlaygroundPlayer._tunables` for `PlaygroundMap`'s reason: a map, and a tool
## over one, must not depend on the game's player class.
const HEIGHT := 1.8
const STEP := 0.4

## Degrees. `DotFpsTunables.max_slope_angle` as the server applies it.
const MAX_SLOPE := 46.0

## Most slide steps followed down one face before the survey gives up on it.
const SLIDE_LIMIT := 4000


## One solid box, in the map's space.
class Solid:
	extends RefCounted
	var xform: Transform3D
	var inverse: Transform3D
	var size: Vector3
	var bounds: AABB
	var upright: bool


var solids: Array[Solid] = []

var _origin := Vector2.ZERO
var _nx := 0
var _nz := 0

# Per column (ix + iz * _nx), the merged spans: [bottom, top, standable, nx, nz] * n.
var _spans: Dictionary = {}

# Dense per column: the highest top and the lowest bottom of anything in it, so the hull
# test can reject a neighbour without looking its spans up. A sandbox plate is 600,000
# columns and most of them hold one slab.
var _top_max := PackedFloat32Array()
var _bottom_min := PackedFloat32Array()

# Standable cells: their column, their height, and their region.
var _node_col := PackedInt32Array()
var _node_y := PackedFloat32Array()
var _node_region := PackedInt32Array()
# Dense per column: the first of its cells (they are contiguous) and how many, lowest first.
var _col_first := PackedInt32Array()
var _col_count := PackedInt32Array()

var _parent := PackedInt32Array()

# Per region: its cells' bounds and count, and the cells on its edge.
var _region_low: Array[Vector3] = []
var _region_high: Array[Vector3] = []
var _region_count := PackedInt32Array()
var _region_edge: Array[PackedInt32Array] = []

# Directed region graph, as sets: region -> {region: true}.
var _out: Array[Dictionary] = []
var _escapes: Dictionary = {}
var _void_falls := 0


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

func _rasterise() -> void:
	var low := Vector2(INF, INF)
	var high := -low

	for s in solids:
		low = low.min(Vector2(s.bounds.position.x, s.bounds.position.z))
		high = high.max(Vector2(s.bounds.end.x, s.bounds.end.z))

	_origin = low
	_nx = int(ceil((high.x - low.x) / CELL)) + 1
	_nz = int(ceil((high.y - low.y) / CELL)) + 1

	var raw: Dictionary = {}
	var cos_limit := cos(deg_to_rad(MAX_SLOPE))

	for s in solids:
		var ix0 := maxi(0, int(floor((s.bounds.position.x - _origin.x) / CELL)))
		var ix1 := mini(_nx - 1, int(floor((s.bounds.end.x - _origin.x) / CELL)))
		var iz0 := maxi(0, int(floor((s.bounds.position.z - _origin.y) / CELL)))
		var iz1 := mini(_nz - 1, int(floor((s.bounds.end.z - _origin.y) / CELL)))
		var up := s.inverse.basis.y
		var half := s.size * 0.5

		# Axis-aligned, which is nearly every box: the span is the box's own bottom and
		# top wherever the column is inside it, and the top is level.
		if s.xform.basis.is_equal_approx(Basis.IDENTITY):
			var span := [s.bounds.position.y, s.bounds.end.y, true, 0.0, 0.0]
			var ax0 := maxi(ix0, int(ceil((s.bounds.position.x - _origin.x) / CELL - 0.5)))
			var ax1 := mini(ix1, int(floor((s.bounds.end.x - _origin.x) / CELL - 0.5)))
			var az0 := maxi(iz0, int(ceil((s.bounds.position.z - _origin.y) / CELL - 0.5)))
			var az1 := mini(iz1, int(floor((s.bounds.end.z - _origin.y) / CELL - 0.5)))
			for iz in range(az0, az1 + 1):
				for ix in range(ax0, ax1 + 1):
					var col := ix + iz * _nx
					var list: Array = raw.get(col, [])
					list.append(span)
					raw[col] = list
			continue

		for iz in range(iz0, iz1 + 1):
			for ix in range(ix0, ix1 + 1):
				var x := _origin.x + (float(ix) + 0.5) * CELL
				var z := _origin.y + (float(iz) + 0.5) * CELL
				var a := s.inverse * Vector3(x, 0.0, z)

				# A vertical line through the box, in the box's own space: a + y * up.
				var t_in := -INF
				var t_out := INF
				var exit_axis := -1
				var missed := false

				for axis in range(3):
					if absf(up[axis]) < 1e-9:
						if absf(a[axis]) > half[axis]:
							missed = true
							break
						continue

					var t1 := (-half[axis] - a[axis]) / up[axis]
					var t2 := (half[axis] - a[axis]) / up[axis]
					t_in = maxf(t_in, minf(t1, t2))

					if maxf(t1, t2) < t_out:
						t_out = maxf(t1, t2)
						exit_axis = axis

				if missed or t_in >= t_out or exit_axis < 0:
					continue

				var local_normal := Vector3.ZERO
				local_normal[exit_axis] = signf(up[exit_axis])
				var normal := (s.xform.basis * local_normal).normalized()
				var standable := normal.y >= cos_limit

				var col := ix + iz * _nx
				var list: Array = raw.get(col, [])
				list.append([t_in, t_out, standable, normal.x, normal.z])
				raw[col] = list

	_top_max.resize(_nx * _nz)
	_top_max.fill(-INF)
	_bottom_min.resize(_nx * _nz)
	_bottom_min.fill(INF)

	# Merge overlapping spans. The top of a merged span is the top of whichever span
	# reached highest, and so is its standability.
	for col: int in raw:
		var list: Array = raw[col]

		if list.size() == 1:
			var only := PackedFloat32Array()
			_push_span(only, list[0])
			_spans[col] = only
			_bottom_min[col] = only[0]
			_top_max[col] = only[1]
			continue

		list.sort_custom(func(p: Array, q: Array) -> bool: return float(p[0]) < float(q[0]))

		var merged := PackedFloat32Array()
		var current: Array = (list[0] as Array).duplicate()

		for k in range(1, list.size()):
			var next: Array = list[k]
			if float(next[0]) <= float(current[1]) + 0.01:
				if float(next[1]) > float(current[1]) + 1e-4:
					current[1] = next[1]
					current[2] = next[2]
					current[3] = next[3]
					current[4] = next[4]
				elif absf(float(next[1]) - float(current[1])) <= 1e-4 and bool(next[2]):
					current[2] = true
			else:
				_push_span(merged, current)
				current = next.duplicate()

		_push_span(merged, current)
		_spans[col] = merged
		_bottom_min[col] = merged[0]
		_top_max[col] = merged[merged.size() - 4]


static func _push_span(out: PackedFloat32Array, span: Array) -> void:
	out.append(float(span[0]))
	out.append(float(span[1]))
	out.append(1.0 if bool(span[2]) else 0.0)
	out.append(float(span[3]))
	out.append(float(span[4]))


const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

const SIDES: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]


## Whether any solid in column [param col] overlaps the air between [param y0] and
## [param y1].
func _solid_between(col: int, y0: float, y1: float) -> bool:
	if _top_max[col] <= y0 or _bottom_min[col] >= y1:
		return false
	var spans: PackedFloat32Array = _spans.get(col, PackedFloat32Array())
	for k in range(0, spans.size(), 5):
		if spans[k] < y1 and spans[k + 1] > y0:
			return true
	return false


## Whether what stands in column [param col] is over the climb limit above [param y].
func _too_tall(col: int, y: float) -> bool:
	return _top_max[col] > y + PlaygroundMap.climb_limit()


## Whether column [param col] has STANDABLE floor within a step of [param y]. A face
## nobody can stand on within a step is not floor: walking onto it is a slide.
func _floor_near(col: int, y: float) -> bool:
	if _top_max[col] < y - STEP:
		return false
	var spans: PackedFloat32Array = _spans.get(col, PackedFloat32Array())
	for k in range(0, spans.size(), 5):
		if spans[k + 2] > 0.5 and absf(spans[k + 1] - y) <= STEP:
			return true
	return false


func _find_cells() -> void:
	_col_first.resize(_nx * _nz)
	_col_first.fill(-1)
	_col_count.resize(_nx * _nz)
	_col_count.fill(0)

	for col: int in _spans:
		var spans: PackedFloat32Array = _spans[col]
		var ix := col % _nx
		var iz := col / _nx
		for k in range(0, spans.size(), 5):
			if spans[k + 2] < 0.5:
				continue

			var y := spans[k + 1]

			# Headroom in this column.
			if k + 5 < spans.size() and spans[k + 5] - y < HEIGHT:
				continue

			# And the hull, in the columns round it: a wall beside this cell, over a step's
			# height, is a wall the player's body is inside.
			var clear := true
			for d in NEIGHBOURS:
				var jx := ix + d.x
				var jz := iz + d.y
				if jx < 0 or jz < 0 or jx >= _nx or jz >= _nz:
					continue
				if _solid_between(jx + jz * _nx, y + STEP, y + HEIGHT):
					clear = false
					break

			if not clear:
				continue

			if _col_count[col] == 0:
				_col_first[col] = _node_col.size()
			_col_count[col] += 1
			_node_col.append(col)
			_node_y.append(y)


# --- Regions ------------------------------------------------------------------

func _find(n: int) -> int:
	while _parent[n] != n:
		_parent[n] = _parent[_parent[n]]
		n = _parent[n]
	return n


func _join_regions() -> void:
	_parent.resize(_node_col.size())
	for n in range(_node_col.size()):
		_parent[n] = n

	for n in range(_node_col.size()):
		var col := _node_col[n]
		var ix := col % _nx
		var iz := col / _nx

		for d in SIDES:
			var jx := ix + d.x
			var jz := iz + d.y
			if jx < 0 or jz < 0 or jx >= _nx or jz >= _nz:
				continue
			var jcol := jx + jz * _nx
			for m in range(_col_first[jcol], _col_first[jcol] + _col_count[jcol]):
				if absf(_node_y[m] - _node_y[n]) <= STEP:
					var ra := _find(n)
					var rb := _find(m)
					if ra != rb:
						_parent[ra] = rb

	var index: Dictionary = {}
	_node_region.resize(_node_col.size())

	for n in range(_node_col.size()):
		var root := _find(n)
		if not index.has(root):
			index[root] = index.size()
			_region_low.append(Vector3(INF, INF, INF))
			_region_high.append(Vector3(-INF, -INF, -INF))
			_region_count.append(0)
			_region_edge.append(PackedInt32Array())
			_out.append({})

		var r: int = index[root]
		_node_region[n] = r
		var at := _node_at(n)
		_region_low[r] = _region_low[r].min(at)
		_region_high[r] = _region_high[r].max(at)
		_region_count[r] += 1


func _node_at(n: int) -> Vector3:
	var col := _node_col[n]
	return Vector3(
		_origin.x + (float(col % _nx) + 0.5) * CELL,
		_node_y[n],
		_origin.y + (float(col / _nx) + 0.5) * CELL
	)


## Drops, slides, jumps, and which regions are ways out.
func _link_regions(ways_out: Array) -> void:
	var exits: Array[AABB] = []
	var pits: Array[AABB] = []

	for way: Dictionary in ways_out:
		exits.append(way["box"] as AABB)
		if bool(way.get("pit", false)):
			pits.append(way["box"] as AABB)

	# Standing in a finish or a reset is a way out. Driven from the zones rather than the
	# cells: a sandbox plate is 600,000 cells and a map has a handful of zones.
	for zone in exits:
		var ix0 := maxi(0, int(floor((zone.position.x - _origin.x) / CELL)))
		var ix1 := mini(_nx - 1, int(floor((zone.end.x - _origin.x) / CELL)))
		var iz0 := maxi(0, int(floor((zone.position.z - _origin.y) / CELL)))
		var iz1 := mini(_nz - 1, int(floor((zone.end.z - _origin.y) / CELL)))

		for iz in range(iz0, iz1 + 1):
			for ix in range(ix0, ix1 + 1):
				var zcol := ix + iz * _nx
				for n in range(_col_first[zcol], _col_first[zcol] + _col_count[zcol]):
					if _inside(zone, _node_at(n) + Vector3(0.0, 0.5, 0.0)):
						_escapes[_node_region[n]] = true

	for n in range(_node_col.size()):
		var region := _node_region[n]
		var at := _node_at(n)
		var col := _node_col[n]
		var ix := col % _nx
		var iz := col / _nx
		var edge := false

		for d in SIDES:
			var jx := ix + d.x
			var jz := iz + d.y
			var level := false

			if jx >= 0 and jz >= 0 and jx < _nx and jz < _nz:
				var ncol := jx + jz * _nx
				for m in range(_col_first[ncol], _col_first[ncol] + _col_count[ncol]):
					if absf(_node_y[m] - _node_y[n]) <= STEP:
						level = true
						break

			if level:
				continue

			# Off the edge: what is below, if the way over it is open.
			var jcol := jx + jz * _nx
			var inside_grid := jx >= 0 and jz >= 0 and jx < _nx and jz < _nz

			# Not a ledge: a wall too tall to jump onto, or floor at this level the hull
			# cannot stand on because such a wall is beside it (the hull test leaves a cell
			# of floor against every wall). Neither is somewhere to jump or drop from, and
			# on a walled sandbox plate they are most of the cells with no level neighbour.
			# Something LOW — a kerb, a stair — is still a place to jump from, with
			# nothing to drop to.
			if inside_grid and _solid_between(jcol, at.y + STEP, at.y + HEIGHT):
				if not _too_tall(jcol, at.y):
					edge = true
				continue

			if inside_grid and _floor_near(jcol, at.y):
				var kx := jx + d.x
				var kz := jz + d.y
				var beyond := kx >= 0 and kz >= 0 and kx < _nx and kz < _nz
				if not (beyond and _solid_between(kx + kz * _nx, at.y + STEP, at.y + HEIGHT)
						and _too_tall(kx + kz * _nx, at.y)):
					edge = true
				continue

			edge = true

			var x := _origin.x + (float(jx) + 0.5) * CELL
			var z := _origin.y + (float(jz) + 0.5) * CELL
			var landed := _fall(x, z, at.y, pits)

			if landed >= 0 and _node_region[landed] != region:
				_out[region][_node_region[landed]] = true
			elif landed == -2:
				_escapes[region] = true

		if edge:
			_region_edge[region].append(n)

	_link_jumps()


## Where a player who leaves the ground over (x, z) at [param y] comes to rest: a cell,
## -2 for a fall into a respawn volume, or -1 for a fall into nothing.
func _fall(x: float, z: float, y: float, pits: Array[AABB]) -> int:
	var cx := x
	var cz := z
	var top := y

	for _i in range(SLIDE_LIMIT):
		var ix := int(floor((cx - _origin.x) / CELL))
		var iz := int(floor((cz - _origin.y) / CELL))
		var col := ix + iz * _nx
		var spans: PackedFloat32Array = PackedFloat32Array()

		if ix >= 0 and iz >= 0 and ix < _nx and iz < _nz:
			spans = _spans.get(col, PackedFloat32Array())

		# The highest span top at or below where the player is.
		var best := -1
		for k in range(0, spans.size(), 5):
			if spans[k + 1] <= top + 0.05 and (best < 0 or spans[k + 1] > spans[best + 1]):
				best = k

		if best < 0:
			for pit in pits:
				if cx >= pit.position.x and cx <= pit.end.x and cz >= pit.position.z \
						and cz <= pit.end.z and pit.position.y < top:
					return -2
			_void_falls += 1
			return -1

		if spans[best + 2] > 0.5:
			for n in range(_col_first[col], _col_first[col] + _col_count[col]):
				if absf(_node_y[n] - spans[best + 1]) < 0.01:
					return n
			# Standable but no room: a hull's width from something. Stop here.
			return -1

		# A face nobody stands on: slide down it, one cell at a time along its fall line.
		var down := Vector2(spans[best + 3], spans[best + 4])
		if down.length() < 1e-4:
			return -1
		down = down.normalized() * CELL
		top = spans[best + 1]
		cx += down.x
		cz += down.y

	return -1


func _link_jumps() -> void:
	var regions := _region_count.size()

	for a in range(regions):
		for b in range(regions):
			if a == b or _out[a].has(b):
				continue

			# The most favourable rise between the two, and the reach it allows.
			var rise := _region_low[b].y - _region_high[a].y
			if rise > PlaygroundMap.climb_limit():
				continue

			var reach := PlaygroundMap.jump_reach(rise)
			var bounds_a := AABB(_region_low[a], _region_high[a] - _region_low[a])
			var bounds_b := AABB(_region_low[b], _region_high[b] - _region_low[b])

			if PlaygroundMap.gap_between(bounds_a, bounds_b) - CELL > reach:
				continue

			if _can_jump(a, b):
				_out[a][b] = true


## Metres per bucket of a region's edge cells, for [method _can_jump].
const BUCKET := 2.0

# Per region, lazily: Vector2i bucket -> PackedInt32Array of its edge cells.
var _edge_buckets: Dictionary = {}


func _buckets_of(region: int) -> Dictionary:
	if _edge_buckets.has(region):
		return _edge_buckets[region]

	var out: Dictionary = {}
	for n in _region_edge[region]:
		var at := _node_at(n)
		var key := Vector2i(floori(at.x / BUCKET), floori(at.z / BUCKET))
		var list: PackedInt32Array = out.get(key, PackedInt32Array())
		list.append(n)
		out[key] = list

	_edge_buckets[region] = out
	return out


func _can_jump(a: int, b: int) -> bool:
	var target := AABB(_region_low[b], _region_high[b] - _region_low[b])
	var buckets := _buckets_of(b)

	for n in _region_edge[a]:
		var from := _node_at(n)
		var best_reach := PlaygroundMap.jump_reach(_region_low[b].y - from.y)

		if PlaygroundMap.gap_between(AABB(from, Vector3.ZERO), target) - CELL > best_reach:
			continue

		var r := int(ceil((best_reach + CELL) / BUCKET))
		var bx := floori(from.x / BUCKET)
		var bz := floori(from.z / BUCKET)

		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var list: PackedInt32Array = buckets.get(Vector2i(bx + dx, bz + dz), PackedInt32Array())
				for m in list:
					var to := _node_at(m)
					var rise := to.y - from.y
					if rise > PlaygroundMap.climb_limit():
						continue
					var gap := Vector2(to.x - from.x, to.z - from.z).length() - CELL
					if gap <= PlaygroundMap.jump_reach(rise):
						return true

	return false


# --- Reading the graph ----------------------------------------------------------

static func _flood(starts: Array, edges: Array[Dictionary]) -> Dictionary:
	var seen: Dictionary = {}
	var queue: Array = starts.duplicate()

	for s: int in starts:
		seen[s] = true

	while not queue.is_empty():
		var r: int = queue.pop_back()
		for next: int in edges[r]:
			if not seen.has(next):
				seen[next] = true
				queue.append(next)

	return seen


## The standable cell a player put at [param at] lands on: in its column or one close
## by, at or under their feet.
func _cell_under(at: Vector3) -> int:
	var ix := int(floor((at.x - _origin.x) / CELL))
	var iz := int(floor((at.z - _origin.y) / CELL))
	var best := -1

	for ring in range(0, 5):
		for dz in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dz)) != ring:
					continue
				var jx := ix + dx
				var jz := iz + dz
				if jx < 0 or jz < 0 or jx >= _nx or jz >= _nz:
					continue
				var col := jx + jz * _nx
				for n in range(_col_first[col], _col_first[col] + _col_count[col]):
					if _node_y[n] <= at.y + 0.5 and _node_y[n] >= at.y - 4.0:
						if best < 0 or _node_y[n] > _node_y[best]:
							best = n
		if best >= 0:
			return best

	return -1


static func _inside(zone: AABB, at: Vector3) -> bool:
	var to := zone.end
	return (
		at.x >= zone.position.x and at.x <= to.x
		and at.y >= zone.position.y and at.y <= to.y
		and at.z >= zone.position.z and at.z <= to.z
	)


## Whether every cell of [param region] is inside one of the map's declared boxes. Per
## cell rather than by the region's bounds, because a region can be a ring — four wall
## tops joined at the corners — whose bounds are the whole map.
func _is_declared(region: int, declared: Array) -> bool:
	if declared.is_empty():
		return false

	var boxes: Array[AABB] = []
	for entry: Variant in declared:
		boxes.append(((entry as Dictionary)["box"] as AABB).grow(CELL))

	for n in range(_node_col.size()):
		if _node_region[n] != region:
			continue
		var at := _node_at(n)
		var inside := false
		for box in boxes:
			if box.has_point(at):
				inside = true
				break
		if not inside:
			return false

	return true
