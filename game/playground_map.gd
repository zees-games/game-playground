extends Node3D

## Base class for the playground's built-in maps.
##
## [b]A map carries its own zones here, and a delivered map would ship a JSON
## file.[/b] Both routes are real and dot-map supports both: `DotMapDef.zones_path`
## points at a file, and a map that ships inside the game's own build can instead
## answer [method timer_zones] directly. This project uses the second for its own
## maps and keeps a written-out copy of one of them in `maps/` — with a check in the
## headless suite that the two agree, because a zone file that has drifted from the
## geometry it was drawn against is a leaderboard nobody can compare.
##
## Subclasses override [method _build] and [method timer_zones].

const PlaygroundPlayer := preload("playground_player.gd")

## Where players appear if the map has no spawn zone.
@export var fallback_spawn: Vector3 = Vector3(0.0, 2.0, 0.0)

# --- What the movement can do ----------------------------------------------
#
# [b]The three numbers every jump on every built-in map is sized against, copied from
# `PlaygroundPlayer._tunables` deliberately,[/b] as constants so a map's layout can be
# written with them. The arithmetic over them is not copied: [method jump_reach] asks
# `PlaygroundPlayer.movement_tunables()`, a static builder, so a map with no player in
# the tree still asks the movement itself. `headless_playground` asserts these three
# against the tunables the server actually applies.
#
# They lived in `pg_lobby` until a second map needed them. Here rather than a second
# copy in `pg_bhop_intro`, because two copies of one number is this tree's most
# repeated bug and the base class is the one place every built-in map already reads.

## Ground speed, m/s. `DotFpsTunables.max_speed`.
const MOVE_SPEED := 7.0

## Metres. `DotFpsTunables.jump_height`. NOT the addon's default, which is 1.1.
const JUMP_HEIGHT := 1.15

## m/s². `DotFpsTunables.gravity`. Not Godot's project default, which is 9.8.
const MOVE_GRAVITY := 20.0


## The clear air a player running at [constant MOVE_SPEED] crosses in one jump, landing
## [param rise] metres higher than they left. 0.0 for a rise the jump cannot reach.
##
## [b]Asked of the movement, not worked out here.[/b] This was a copy of the arithmetic
## until dot-player-controller answered it on `DotFpsTunables.jump_reach`; now it asks
## the tunables every player here is built with (`PlaygroundPlayer.movement_tunables`,
## static, so a map with no player in the tree can ask). The landing height is still
## the point: 4.75 m flat, 4.16 m onto a 0.5 m step.
static func jump_reach(rise: float) -> float:
	return _movement().jump_reach(rise)


## The highest top face a player on flat ground is asked to jump onto, in metres: the
## apex times `DotFpsTunables.CLIMB_MARGIN`, asked of the same tunables as
## [method jump_reach]. 1.035 m, not [constant JUMP_HEIGHT]: a ledge at the apex works
## only when the tick lands right. Above this a block is a wall.
static func climb_limit() -> float:
	return _movement().climb_limit()


## [method jump_reach]'s tunables, built once. Private and never handed out, so nothing
## can scale it the way a class scales a live player's.
static var _movement_cache: DotFpsTunables = null


static func _movement() -> DotFpsTunables:
	if _movement_cache == null:
		_movement_cache = PlaygroundPlayer.movement_tunables()

	return _movement_cache


## The clear air between two standable boxes, seen from above, in metres. 0.0 when
## they touch or overlap.
##
## [b]Box to box, not centre to centre minus a width.[/b] The second is what
## `pg_lobby`'s tower was checked with, and it is a different number in every
## direction: two axis-aligned squares 45 degrees apart round a circle are closer at
## their corners than their centres say, and a square pad beside a square platform
## diagonally off its corner is 0.2 m of air that a centre distance calls 3.8.
##
## A route on a built-in map is a list of these boxes, in the order a player lands on
## them — see `PgLobby.tower_route` — so the gap and the rise of every jump are read off
## the geometry rather than kept beside it as a table that can drift.
static func gap_between(from: AABB, to: AABB) -> float:
	var dx := maxf(
		0.0, maxf(to.position.x - from.end.x, from.position.x - to.end.x)
	)
	var dz := maxf(
		0.0, maxf(to.position.z - from.end.z, from.position.z - to.end.z)
	)

	return Vector2(dx, dz).length()


## A standable box as an [AABB], from its centre and full size — the convention
## `PlaygroundGeometry.box` takes, so a route can be written with the same arguments
## the geometry was.
static func standable(centre: Vector3, size: Vector3) -> AABB:
	return AABB(centre - size * 0.5, size)


func _ready() -> void:
	_build()
	add_contact_shade()


## dot-lighting's contact shade, loaded by path (API 4): see [method add_contact_shade].
const CONTACT_SHADE_SCRIPT := "res://addons/dot_lighting/runtime/dot_contact_shade.gd"


## Adds dot-lighting's contact shade (API 4) where this map's boxes meet: a wall's foot, a
## block on the floor, every step of a stair. The Compatibility renderer the client draws has
## no ambient occlusion, and every box stood on the floor with no shade at its foot. Called
## once the geometry is built ([method _ready], and the maps that build later on their own).
##
## Only what `PlaygroundGeometry.box` made, read off the built map (a [StaticBody3D] holding
## a [BoxMesh]): a panel or a liquid has no body, so a gate's pane and water neither cast nor
## take a shade; a see-through material is skipped; so is a box turned off upright (a surf
## ramp), whose creases the helper does not follow. Nothing a map builds moves, and props are
## the server's, put down later and not under this node. By path, behind the level, so a
## shell older than the helper draws the map without it.
func add_contact_shade() -> void:
	if DotAddonApi.build_level("dot_lighting") < 4 or not ResourceLoader.exists(CONTACT_SHADE_SCRIPT):
		return
	var old := get_node_or_null(^"ContactShade")
	if old != null:
		remove_child(old)
		old.queue_free()
	var boxes: Array = []
	_gather_shade_boxes(self, Transform3D.IDENTITY, boxes)
	if boxes.is_empty():
		return
	var shade: Variant = (load(CONTACT_SHADE_SCRIPT) as GDScript).call(&"node", boxes)
	if shade is MeshInstance3D and (shade as MeshInstance3D).mesh != null:
		(shade as Node).name = "ContactShade"
		add_child(shade)
	elif shade is Node:
		(shade as Node).free()


## Every solid, opaque, upright box under [param node], in this map's frame ([param frame] is
## [param node]'s), into [param into]. By transform chain, not `global_transform`: a map built by
## `configure_doc` may not be in the tree yet.
func _gather_shade_boxes(node: Node, frame: Transform3D, into: Array) -> void:
	for child in node.get_children():
		if not (child is Node3D):
			continue
		var at := frame * (child as Node3D).transform
		if child is MeshInstance3D and node is StaticBody3D and (child as MeshInstance3D).mesh is BoxMesh:
			var mesh := child as MeshInstance3D
			var material := mesh.material_override as BaseMaterial3D
			var upright := absf(at.basis.y.normalized().dot(Vector3.UP)) > 0.999
			if upright and mesh.visible and (material == null or material.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED):
				into.append({"transform": at.orthonormalized(), "size": (mesh.mesh as BoxMesh).size * at.basis.get_scale()})
		_gather_shade_boxes(child, at, into)


## Builds the geometry. Called once, from [method Node._ready].
func _build() -> void:
	pass


## The map's timer zones, or null for a map with no timer.
func timer_zones() -> DotTimerZoneSet:
	return null


## Where a player on [param track] starts.
func spawn_for(track: int) -> Vector3:
	var zones := timer_zones()

	if zones != null:
		var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)

		if spawn != null:
			return spawn.destination

	return fallback_spawn


## The yaw a player faces when they spawn on [param track], in degrees.
func spawn_yaw_for(track: int) -> float:
	var zones := timer_zones()

	if zones != null:
		var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)

		if spawn != null:
			return spawn.destination_yaw

	return 0.0


## Standable places on this map that no spawn is MEANT to reach, each as
## `{box: AABB, why: String}`.
##
## Read by `PlaygroundMapSurvey` (`headless_playground`'s survey section), which fails on
## any standable area it cannot reach from a spawn unless it is declared here. The top of
## a wall, a backstop, the crest of a face nobody can climb: places only a noclip goes,
## said once where the geometry is rather than discovered by a player who got there some
## other way. [b]A declaration is a claim, and the reason is the part worth reading[/b] —
## "the survey complained" is not one.
func survey_declared() -> Array:
	return []


## The toys this map puts down (dot-props' placements, `{toy, at, yaw, links?, on?}`), which
## [Playground] builds on both ends in this order, so the order is how a client pairs each with
## the server's entity. None by default: a course map has nothing to play with in a runner's
## way, and nothing a run could bounce off.
func map_toys() -> Array:
	return []


## Whether [param track] is meant to be driven rather than run.
##
## [b]Default false, which is every map that existed before there were cars.[/b]
## [code]Playground._on_seated[/code] cancels a run when a player gets into a vehicle,
## because a foot course driven round in a buggy is not a time anybody can compare with
## one that was jumped — and dot-timer has no idea a vehicle exists, so nothing below
## this can tell the difference.
##
## A circuit inverts that: the car is the point, and getting OUT of it mid-lap is the
## thing that should end the run. A map says which of its tracks are which, because the
## map is the only thing that knows. See `pg_lobby`'s bonus 3.
func track_is_driven(_track: int) -> bool:
	return false
