extends "../game/playground_map.gd"

const PlaygroundGeometry := preload("../game/playground_geometry.gd")

## `pg_surf_intro` — four routes. A valley between two ramps, a face you fall down,
## and a staircase you jump down.
##
## [b]The main run is the shape every surf map is made of, reduced to its
## minimum[/b]: two slabs tilted past `max_slope_angle` so a player on one is never
## grounded, meeting along a centre line that is exactly the seam a naive
## collide-and-slide stops a player dead in.
##
## [b]What it is NOT is a route whose speed comes from those ramps.[/b] They are
## level along their length — every metre of descent on the main run comes from the
## stepped floor between them — so a player can ride the whole map without the ramps
## having given them anything. Measured on 2026-09-18 by instrumenting the suite's
## own bot: a scripted strafer covers 10.7 m of the 220 m route and crosses none of
## its splits, while the two checks over it ("most of the descent is spent not
## grounded", "the player reaches surf speed") both pass — of a player who is
## falling. That is the whole reason [b]the plunge[/b] below exists, and the reason
## the two checks now have a printed distance beside them.
##
## Laid out along -Z, descending. Every number here is also read by
## [method timer_zones], which is why the geometry and the zones cannot drift apart.

## Where the run begins and ends, in metres along -Z.
const START_Z := 0.0
const END_Z := -220.0

## Height of the start platform and of the finish floor.
const START_Y := 40.0
const END_Y := -30.0

## Half the width of the valley at its floor.
const VALLEY_HALF_WIDTH := 3.0

## How far out each ramp reaches from the valley.
const RAMP_WIDTH := 26.0

## Ramp angle from horizontal. Well past the 46° a player can stand on.
const RAMP_ANGLE := 58.0

## The start platform's extent, and the finish pad's.
const PAD_SIZE := Vector3(18.0, 1.0, 18.0)


# --- Bonus 1: the plunge ---------------------------------------------------
#
# The map's second route, and the one where the speed comes from the RAMP rather
# than from the fall. The main run's two ramps are level along their length — they
# are walls that fall toward a valley, and every metre of descent on that route
# comes from the stepped floor between them. So a player can ride the whole map
# without the ramps ever having given them anything, and the route never asks the
# question surf is actually about: hold a line on a face you cannot stand on while
# gravity does the work.
#
# The plunge asks it. One face, pitched past `max_slope_angle` so the player is
# never grounded on it, descending along the run so that gravity accelerates them
# ALONG the route instead of straight down. The difficulty is staying on a
# fourteen-metre-wide face while going faster every tick, and falling off it is
# what the track's own respawn volume is for.
#
# It is deliberately STRAIGHT, and that is a design decision rather than a lack of
# ambition — the same one `game-g2gfast`'s `the needle` was built on. A scripted
# bot cannot air-strafe, so a route that needs turning is a route no suite can run
# end to end, and an unrun route is one nobody finds the holes in. See
# `[bonus-run-2]` in the nightly to-do list: this family had driven exactly two
# bonus routes start to finish, and both were straight for this reason.
#
# [b]Half of that was wrong, and it is worth saying which half.[/b] A bot cannot
# air-strafe, so a route that needs speed CARRIED round a turn is still out of reach.
# A route that only needs the player to face somewhere new before the next jump is not:
# `pg_lobby`'s tower and `pg_bhop_intro`'s switchback are both driven end to end by a
# bot that steers by yaw every tick. A surf route turns by riding a bank, which is the
# first kind, so this one stays straight.

## Where the plunge sits, well clear of the main run. The main map's ramps reach
## out to x = 17, so sixty is a route beside it rather than through it.
const CHUTE_X := 60.0

## The top of the slide, level with the main start platform: the two routes begin
## at the same height, which is what makes their times worth comparing at all.
const CHUTE_TOP_Y := START_Y

## How wide the face is. Wide enough to land on, narrow enough that drifting is a
## real way to lose the run.
const CHUTE_WIDTH := 14.0

## Pitch of the face, from horizontal. Past `DotFpsConfig.max_slope_angle` (46°),
## so a player on it is sliding rather than standing — which is the whole point.
const CHUTE_PITCH := 52.0

## How many metres of Z the slide covers. Its drop follows from the pitch.
const CHUTE_RUN := 48.0

## Flat metres after the slide, before the finish pad. A player arrives at the
## bottom fast and needs somewhere to arrive: a finish line AT the foot of a 52°
## face is one crossed while still airborne, at whatever the fall made of them.
const CHUTE_RUNOUT := 30.0

## The plunge's start and finish pads, along Z.
const CHUTE_PAD_LENGTH := 20.0

## Where the splits go, as a fraction of the slide.
const CHUTE_SPLITS := [0.34, 0.68]


# --- Bonus 2: the cascade ----------------------------------------------------
#
# The map's third route and its first made of JUMPS: a staircase of floating blocks
# falling down the hillside west of the main run, each one 1.25 m under the last and
# offset to the other side of the line, so every jump is a drop AND a turn.
#
# [b]It asks the question neither other route here asks, and none on `pg_bhop_intro`
# does either.[/b] Every bhop route in this game climbs or stays level, which makes a
# jump's reach SHORTER than a flat one; a drop makes it longer — 5.8 m onto a block
# 1.25 m down against 4.75 m flat — and a player who has learned the climbing courses
# overshoots here, straight past the next block and off its far side. And a player who
# lands facing where they came from, rather than where the next block is, falls off
# the side instead: the slalom is what makes each landing a decision.
#
# Every number below is read by `_build_the_cascade`, `cascade_route` and
# `_add_the_cascade`, and nothing else describes where a block is — the rule the
# switchback follows, for its reason.

## The track it runs on.
const CASCADE_TRACK := DotTimerTrack.BONUS_FIRST + 1

## Where the route runs, west of the main run: its ramps reach out to x = -17, so the
## cascade's blocks — which sway 2.5 m either side of this line — are forty metres
## clear of them, and it mirrors the plunge on the other side of the valley.
const CASCADE_X := -60.0

## The start pad's centre in Z, and the height of its top surface: level with the main
## start and the plunge's, so all three routes begin at the same height.
const CASCADE_Z := 8.0
const CASCADE_TOP_Y := START_Y

const CASCADE_PAD := Vector3(8.0, 1.0, 8.0)

## Square, so the block is the same target from whichever diagonal a jump arrives on.
const CASCADE_BLOCK := Vector3(3.0, 0.5, 3.0)

## How far each block is under the one before. Well over `step_height`, so no block is
## a stair, and small enough that the landing does not become the whole of the jump.
const CASCADE_DROP := 1.25

## Each block's offset either side of [constant CASCADE_X], alternating. 2.5 m against a
## 3 m block puts consecutive blocks 2 m of air apart across the line as well as along
## it, so every jump is a diagonal the player has to face before taking.
const CASCADE_SWAY := 2.5

## How many blocks between the pad and the finish.
const CASCADE_BLOCKS := 10

## The clear air along Z before the first block and before the finish pad. Grows evenly.
##
## [b]Sized against [method jump_reach] for a drop.[/b] Every jump falls
## [constant CASCADE_DROP], so the reach is `jump_reach(-1.25)` = 5.80 m, and the
## tightest jump — the last block-to-block diagonal, 3.62 m along and 2 m across, 4.14 m
## of air box to box — is 71% of it: the switchback's band, past a standing jump and
## inside a running one. The finish pad sits on the line, so the jump onto it is straight.
const CASCADE_FIRST_GAP := 2.0
const CASCADE_LAST_GAP := 3.8

## The route indices of the blocks the splits are drawn across.
const CASCADE_SPLIT_BLOCKS := [4, 8]


# --- Bonus 3: the long bank --------------------------------------------------
#
# [b]The first face on this map that is SURFED.[/b] The main run's ramps are banked and
# level along their length, so they carry nobody anywhere (`[surf-ramp-1]`); the plunge
# is pitched along the route and not banked, so it is a slide a player falls down
# holding forward. Neither is the shape a surf map is made of, which is both at once: a
# face banked past what a player can stand on, so the only way to stay on it is to hold
# INTO it, and pitched down along its length, so the thing that makes a rider fast is
# the face they are holding onto. This is that face, once, 140 m long.
#
# It asks the one question neither other surf route asks: can a player hold a height on
# a face that is throwing them off its low lip the whole way down? Hold too little and
# they slide off the lip into the pit; hold too much and they climb over the top edge.
#
# Built east of the plunge, whose face is 14 m wide at x = 60: the bank's low lip is at
# x = 104, forty metres clear. One slab, one basis — [method bank_basis] — and every
# number about where its surface is comes from [method bank_surface_y], which the
# geometry, the zones and the suite all read.

## The track it runs on.
const BANK_TRACK := DotTimerTrack.BONUS_FIRST + 2

## Where the middle of the bank's near edge is: its top surface passes through this point.
const BANK_X := 110.0
const BANK_NEAR_Z := START_Z
const BANK_TOP_Y := START_Y - 3.0

## How far the bank is rolled about its own length. Past the server's 46-degree
## `max_slope_angle` by ten degrees, the main run's band, so no pitch here makes it
## standable: the face's own slope is what the suite checks, not this number.
const BANK_ROLL := 56.0

## How far it falls along its length. 7 degrees is 2.4 m/s² of gravity along the route,
## which takes a rider off the pad at a walk to about 27 m/s at the far end — the
## plunge's band, from a face a player can steer on.
const BANK_PITCH := 7.0

## The slab: across the bank, thick, and along it, measured on the slab.
const BANK_SIZE := Vector3(20.0, 1.0, 140.0)

## The pad: centred a metre down the bank from its middle line, which is the line the
## suite's bot rides, so stepping off its front lands a player on the bank 4.5 m below.
const BANK_PAD := Vector3(8.0, 1.0, 10.0)
const BANK_PAD_X := BANK_X - 1.0

## The finish pad, after a clear gap past the bank's far end and this far under the
## middle of that end. Long, because where a rider lands is a matter of how fast they
## left: 27 m/s comes down about 13 m out, and a strafer twice as fast inside 30.
const BANK_FINISH_DROP := 4.0
const BANK_FINISH_GAP := 2.0
const BANK_FINISH := Vector3(18.0, 1.0, 60.0)

## Where along the bank the splits are, as fractions of its length.
const BANK_SPLITS := [1.0 / 3.0, 2.0 / 3.0]


# --- Bonus 4: the transfer ---------------------------------------------------
#
# [b]The first route here where a rider goes from one face to another.[/b] The long bank
# is one face with its high edge on the right the whole way down, so its whole skill is
# holding right. A surf map is a succession of faces, and the moment between two of them
# is what a player has to learn: this is two faces side by side and FACING each other
# across a gap — the first high on the right, the second high on the left, lower, and
# starting a third of the way down the first. A rider holds right down the first, then
# lets go and pushes left: off the first face's low lip, across the gap, onto the second,
# where the only way to stay on is to hold LEFT. Too early and the second face is not
# there yet; too late and the first one ends under them.
#
# Not two faces in line, which is what this was first built as: a rider leaving a face
# over its far END is stopped dead by the motor at that edge (the long bank's rider is
# too, 0.1 m short of its far edge, and slides off onto the finish pad below, which is
# why nobody saw it — see docs/routes.md). Leaving over the LOW LIP keeps the speed, because
# the clip there is along the lip, which is the way the rider is going.
#
# The second face is pitched steeper than the first, so the half after the transfer is
# where the speed is. Built east of the long bank, whose high edge is at x = 116: the
# transfer spans x = 151..177. Every number below comes from the faces' bases
# ([method transfer_basis]) and near edges ([method transfer_near_centre]), which the
# geometry, the zones and the suite all read.

## The track it runs on.
const TRANSFER_TRACK := DotTimerTrack.BONUS_FIRST + 3

## The riding line on the first face: the pad's centre, and a metre down from its middle.
const TRANSFER_LINE_X := 170.0
const TRANSFER_NEAR_Z := START_Z

## Both faces' roll, the long bank's: past `max_slope_angle` by ten degrees. The first is
## rolled one way and the second the other.
const TRANSFER_ROLL := 56.0

## How far each face falls along its length, the second steeper, so the transfer is the
## gate to the fast half. Both steeper than the long bank's 7: a route of 120 m rather than
## 145 has less run to build speed in, and at 7 and 9 the bot finished at 11 m/s.
const TRANSFER_PITCHES := [10.0, 12.0]

## Each face: across, thick, along.
const TRANSFER_FACES := [Vector3(20.0, 1.0, 70.0), Vector3(20.0, 1.0, 90.0)]

## Where the second face's near edge is along Z: a third of the way down the first.
const TRANSFER_SECOND_NEAR_Z := -24.0

## The clear gap across X between the first face's low lip and the second's, and how far
## the second's lip is under the first's at the second's near edge. A rider off the
## first lip is falling steeply: a lip at the same height would be one they pass under.
const TRANSFER_GAP := 2.0
const TRANSFER_DROP := 4.0

## Where the suite's bot lets go of the first face: this far into the second face's length.
const TRANSFER_AT := 10.0

## The pad, the long bank's: stepping off its front edge lands a rider on the first face.
const TRANSFER_PAD := Vector3(8.0, 1.0, 10.0)

## The finish pad, past the second face's far end and under its riding line.
const TRANSFER_FINISH_DROP := 4.0
const TRANSFER_FINISH_GAP := 4.0
const TRANSFER_FINISH := Vector3(18.0, 1.0, 60.0)

## How far before the second face's far edge the finish begins.
const TRANSFER_FINISH_LINE := 4.0

## Where along the second face its split is, as a fraction of its length. The first
## split is the gap between the lips.
const TRANSFER_SECOND_SPLIT := 0.5


func _build() -> void:
	PlaygroundGeometry.sun(self)

	fallback_spawn = Vector3(0.0, START_Y + 1.0, START_Z + 6.0)

	# The start platform, and a lip so a player who walks backwards does not simply
	# fall off the map before starting. Every route's lip is in `backstops()`.
	PlaygroundGeometry.box(
		self,
		Vector3(0.0, START_Y - 0.5, START_Z + 6.0),
		PAD_SIZE,
		PlaygroundGeometry.COLOUR_START
	)

	for lip in backstops():
		PlaygroundGeometry.box(
			self, lip.get_center(), lip.size, PlaygroundGeometry.COLOUR_PLATFORM
		)

	# The two ramps. Each is a long slab tilted about Z so it falls toward the
	# valley, and the pair are placed so their inner edges meet along the centre
	# line — which is the seam DotFpsMotor._resolve_planes exists for.
	var length := absf(END_Z - START_Z)
	var drop := START_Y - END_Y
	var centre_z := (START_Z + END_Z) * 0.5

	# The slab is tilted about Z, so its own length runs along Z and its width runs
	# across the tilt. Its centre sits half a ramp-width out from the valley, raised
	# by the height that width gains at this angle.
	var lift := sin(deg_to_rad(RAMP_ANGLE)) * RAMP_WIDTH * 0.5
	var out := cos(deg_to_rad(RAMP_ANGLE)) * RAMP_WIDTH * 0.5

	for side in [-1.0, 1.0]:
		PlaygroundGeometry.ramp(
			self,
			Vector3(
				side * (VALLEY_HALF_WIDTH + out),
				# Descends along the run, so the whole valley falls from START_Y to
				# END_Y. The pitch is applied by placing the slab, not by a second
				# rotation: two rotations about different axes make the ramp's own
				# surface no longer a plane a player can hold a line on.
				(START_Y + END_Y) * 0.5 + lift,
				centre_z
			),
			Vector3(RAMP_WIDTH, 1.0, length),
			# Negative on the left so both ramps fall toward the middle.
			-side * RAMP_ANGLE,
			Vector3.FORWARD
		)

	# The descent. The ramps above are level along their length, so the fall comes
	# from a floor that steps down — which is what a real surf map does with a
	# succession of ramps, and keeps this one to two slabs.
	var steps := 10

	for i in range(steps):
		var t := float(i) / float(steps - 1)
		var z := lerpf(START_Z - 10.0, END_Z + 10.0, t)
		var y := lerpf(START_Y - 6.0, END_Y, t)

		PlaygroundGeometry.box(
			self,
			Vector3(0.0, y - 0.5, z),
			Vector3(VALLEY_HALF_WIDTH * 2.0, 1.0, length / float(steps) + 1.0),
			PlaygroundGeometry.COLOUR_FLOOR
		)

	# The finish pad.
	PlaygroundGeometry.box(
		self,
		Vector3(0.0, END_Y - 0.5, END_Z - 6.0),
		PAD_SIZE,
		PlaygroundGeometry.COLOUR_END
	)

	_build_the_plunge()
	_build_the_cascade()
	_build_the_bank()
	_build_the_transfer()


## Bonus 1. Built from its own constants, like the main run, and from the same
## helpers — so the zones below and the geometry here cannot drift apart.
func _build_the_plunge() -> void:
	# The start pad. Its backstop is built with the main platform's, from `backstops()`.
	PlaygroundGeometry.box(
		self,
		Vector3(CHUTE_X, CHUTE_TOP_Y - 0.5, START_Z + CHUTE_PAD_LENGTH * 0.5),
		Vector3(CHUTE_WIDTH, 1.0, CHUTE_PAD_LENGTH),
		PlaygroundGeometry.COLOUR_START
	)

	# The face itself. ONE rotation, about X, so the slab stays a plane a player
	# can hold a line on — the main run's ramps are built the same way and for the
	# same reason. Negative, because a positive rotation about +X lifts the local
	# +Z end, and this route runs toward -Z.
	#
	# The slab is then dropped by half its thickness measured VERTICALLY rather
	# than perpendicular: the two differ by a factor of 1/cos(pitch), which at 52°
	# is 1.6, and getting it wrong leaves a 0.8 m lip at the seam where the pad
	# meets the face. That is over the controller's step height, so a player would
	# run at the slide and stop dead — with nothing in any count to say why.
	var surface_drop := 0.5 / cos(deg_to_rad(CHUTE_PITCH))

	PlaygroundGeometry.ramp(
		self,
		Vector3(
			CHUTE_X,
			(CHUTE_TOP_Y + chute_bottom_y()) * 0.5 - surface_drop,
			START_Z - CHUTE_RUN * 0.5
		),
		Vector3(CHUTE_WIDTH, 1.0, chute_slope_length()),
		-CHUTE_PITCH,
		Vector3.RIGHT
	)

	# The run-out, flush with the foot of the face, and the finish pad after it.
	PlaygroundGeometry.box(
		self,
		Vector3(
			CHUTE_X,
			chute_bottom_y() - 0.5,
			chute_slide_end_z() - CHUTE_RUNOUT * 0.5
		),
		Vector3(CHUTE_WIDTH, 1.0, CHUTE_RUNOUT),
		PlaygroundGeometry.COLOUR_FLOOR
	)
	PlaygroundGeometry.box(
		self,
		Vector3(
			CHUTE_X,
			chute_bottom_y() - 0.5,
			chute_end_z() - CHUTE_PAD_LENGTH * 0.5
		),
		Vector3(CHUTE_WIDTH, 1.0, CHUTE_PAD_LENGTH),
		PlaygroundGeometry.COLOUR_END
	)


## Bonus 2, built from [method cascade_route] and nothing else. The blocks the splits
## are drawn across are the ramp colour, so a player can see where a section ends.
func _build_the_cascade() -> void:
	var route := cascade_route()

	for i in range(route.size()):
		var box: AABB = route[i]
		var colour := PlaygroundGeometry.COLOUR_PLATFORM

		if i == 0:
			colour = PlaygroundGeometry.COLOUR_START
		elif i == route.size() - 1:
			colour = PlaygroundGeometry.COLOUR_END
		elif CASCADE_SPLIT_BLOCKS.has(i):
			colour = PlaygroundGeometry.COLOUR_RAMP

		PlaygroundGeometry.box(self, box.get_center(), box.size, colour)


## Bonus 3: the pad, the bank and the finish pad. The bank is one slab placed by
## [method bank_basis] with its top face through the point the constants name; nothing
## else says where it is.
func _build_the_bank() -> void:
	PlaygroundGeometry.box(
		self, bank_pad().get_center(), BANK_PAD, PlaygroundGeometry.COLOUR_START
	)

	var basis := bank_basis()
	# The slab's centre: half its length down the bank from the near edge, and half
	# its thickness under the top face along the face's own normal.
	var centre := bank_near_centre() + basis * Vector3(0.0, -BANK_SIZE.y * 0.5, -BANK_SIZE.z * 0.5)
	PlaygroundGeometry.box(self, centre, BANK_SIZE, PlaygroundGeometry.COLOUR_RAMP, basis)

	PlaygroundGeometry.box(
		self, bank_finish().get_center(), BANK_FINISH, PlaygroundGeometry.COLOUR_END
	)


## The bank's orientation: rolled [constant BANK_ROLL] about its length first, so its
## +X edge is the high one, then pitched [constant BANK_PITCH] down toward -Z. Local +Y
## is the face's normal, local -Z runs down the bank, local +X runs up it.
static func bank_basis() -> Basis:
	return (
		Basis(Vector3.RIGHT, -deg_to_rad(BANK_PITCH))
		* Basis(Vector3.BACK, deg_to_rad(BANK_ROLL))
	)


## The middle of the top face's near edge.
static func bank_near_centre() -> Vector3:
	return Vector3(BANK_X, BANK_TOP_Y, BANK_NEAR_Z)


## The riding face's normal. Its Y is the cosine of the face's slope, which is what the
## suite holds against `max_slope_angle`.
static func bank_normal() -> Vector3:
	return bank_basis() * Vector3.UP


## Height of the riding face at ([param x], [param z]) — what a rider's feet are on.
static func bank_surface_y(x: float, z: float) -> float:
	var n := bank_normal()
	var p := bank_near_centre()
	return p.y - (n.x * (x - p.x) + n.z * (z - p.z)) / n.y


## The four corners of the riding face: near low, near high, far low, far high.
static func bank_corners() -> Array[Vector3]:
	var basis := bank_basis()
	var p := bank_near_centre()
	var half := BANK_SIZE.x * 0.5
	var along := basis * Vector3(0.0, 0.0, -BANK_SIZE.z)
	var across := basis * Vector3(half, 0.0, 0.0)
	return [p - across, p + across, p - across + along, p + across + along]


## Z of the bank's far edge, at the middle of the face.
static func bank_far_z() -> float:
	return bank_near_centre().z + (bank_basis() * Vector3(0.0, 0.0, -BANK_SIZE.z)).z


## The pad, as the box it is: its top level with the other starts, its front edge at
## the bank's near edge.
static func bank_pad() -> AABB:
	return standable(
		Vector3(BANK_PAD_X, START_Y - BANK_PAD.y * 0.5, BANK_NEAR_Z + 0.5 + BANK_PAD.z * 0.5),
		BANK_PAD
	)


## The finish pad: [constant BANK_FINISH_GAP] past the far edge, [constant
## BANK_FINISH_DROP] under the middle of it, centred on the pad's line.
static func bank_finish() -> AABB:
	var far_z := bank_far_z()
	var top := bank_surface_y(BANK_X, far_z) - BANK_FINISH_DROP
	return standable(
		Vector3(
			BANK_PAD_X,
			top - BANK_FINISH.y * 0.5,
			far_z - BANK_FINISH_GAP - BANK_FINISH.z * 0.5
		),
		BANK_FINISH
	)


func _build_the_transfer() -> void:
	PlaygroundGeometry.box(
		self, transfer_pad().get_center(), TRANSFER_PAD, PlaygroundGeometry.COLOUR_START
	)

	for face in range(2):
		var basis := transfer_basis(face)
		var size: Vector3 = TRANSFER_FACES[face]
		var centre := transfer_near_centre(face) + basis * Vector3(0.0, -size.y * 0.5, -size.z * 0.5)
		PlaygroundGeometry.box(self, centre, size, PlaygroundGeometry.COLOUR_RAMP, basis)

	PlaygroundGeometry.box(
		self, transfer_finish().get_center(), TRANSFER_FINISH, PlaygroundGeometry.COLOUR_END
	)


## Which way [param face] leans: +1 for the first, whose high edge is +X (the right of a
## rider facing -Z), and -1 for the second, whose high edge is -X — so the two face each
## other across the gap.
static func transfer_side(face: int) -> float:
	return 1.0 if face == 0 else -1.0


## [param face]'s orientation, built as [method bank_basis] is: rolled about its length so
## the [method transfer_side] edge is the high one, then pitched down toward -Z. Local +Y
## is the riding face's normal and local -Z runs down it.
static func transfer_basis(face: int) -> Basis:
	return (
		Basis(Vector3.RIGHT, -deg_to_rad(float(TRANSFER_PITCHES[face])))
		* Basis(Vector3.BACK, transfer_side(face) * deg_to_rad(TRANSFER_ROLL))
	)


static func transfer_normal(face: int) -> Vector3:
	return transfer_basis(face) * Vector3.UP


## Half a face's width, across X, as built.
static func _transfer_half_x() -> float:
	return cos(deg_to_rad(TRANSFER_ROLL)) * TRANSFER_FACES[0].x * 0.5


## The X of [param face]'s low lip: the first's is on its -X side and the second's on +X,
## [constant TRANSFER_GAP] apart.
static func transfer_lip_x(face: int) -> float:
	var first_lip := TRANSFER_LINE_X + 1.0 - _transfer_half_x()
	return first_lip if face == 0 else first_lip - TRANSFER_GAP


## The riding line on [param face]: a metre down it from its middle.
static func transfer_line_x(face: int) -> float:
	return TRANSFER_LINE_X if face == 0 else transfer_lip_x(1) - _transfer_half_x() + 1.0


## The middle of [param face]'s near edge on its top surface. The second's is placed from
## the first: its low lip [constant TRANSFER_DROP] under the first's, at its near edge.
static func transfer_near_centre(face: int) -> Vector3:
	var first := Vector3(TRANSFER_LINE_X + 1.0, START_Y - 3.0, TRANSFER_NEAR_Z)
	if face == 0:
		return first
	var z := TRANSFER_SECOND_NEAR_Z
	var lip_y := _face_surface_y(transfer_basis(0), first, transfer_lip_x(0), z) - TRANSFER_DROP
	var x := transfer_lip_x(1) - _transfer_half_x()
	var n := transfer_normal(1)
	# On the second face at its near edge: y(lip) = p.y - n.x * (lip - p.x) / n.y.
	return Vector3(x, lip_y + n.x * (transfer_lip_x(1) - x) / n.y, z)


## Height of [param face]'s riding surface at ([param x], [param z]).
static func transfer_surface_y(face: int, x: float, z: float) -> float:
	return _face_surface_y(transfer_basis(face), transfer_near_centre(face), x, z)


## Z of [param face]'s far edge, at its middle.
static func transfer_far_z(face: int) -> float:
	var length: float = TRANSFER_FACES[face].z
	return transfer_near_centre(face).z + (transfer_basis(face) * Vector3(0.0, 0.0, -length)).z


## [param face]'s four top corners: near, near, far, far. Which of each pair is the high
## one is not the same index on both faces.
static func transfer_corners(face: int) -> Array[Vector3]:
	var basis := transfer_basis(face)
	var p := transfer_near_centre(face)
	var size: Vector3 = TRANSFER_FACES[face]
	var along := basis * Vector3(0.0, 0.0, -size.z)
	var across := basis * Vector3(size.x * 0.5, 0.0, 0.0)
	return [p - across, p + across, p - across + along, p + across + along]


static func transfer_pad() -> AABB:
	return standable(
		Vector3(
			TRANSFER_LINE_X, START_Y - TRANSFER_PAD.y * 0.5,
			TRANSFER_NEAR_Z + 0.5 + TRANSFER_PAD.z * 0.5
		),
		TRANSFER_PAD
	)


static func transfer_finish() -> AABB:
	var far_z := transfer_far_z(1)
	var line := transfer_line_x(1)
	var top := transfer_surface_y(1, line, far_z) - TRANSFER_FINISH_DROP
	return standable(
		Vector3(
			line,
			top - TRANSFER_FINISH.y * 0.5,
			far_z - TRANSFER_FINISH_GAP - TRANSFER_FINISH.z * 0.5
		),
		TRANSFER_FINISH
	)


static func _face_surface_y(basis: Basis, p: Vector3, x: float, z: float) -> float:
	var n := basis * Vector3.UP
	return p.y - (n.x * (x - p.x) + n.z * (z - p.z)) / n.y


## Every start pad's backstop — the main run's, the plunge's and the cascade's — as a
## box: a 4 m wall behind the back edge, 3 m above the pad, so a player who walks
## backwards does not fall off the map before starting.
static func backstops() -> Array[AABB]:
	var cascade_pad: AABB = cascade_route()[0]
	return [
		standable(Vector3(0.0, START_Y + 1.0, START_Z + 15.0), Vector3(18.0, 4.0, 1.0)),
		standable(
			Vector3(CHUTE_X, CHUTE_TOP_Y + 1.0, START_Z + CHUTE_PAD_LENGTH + 0.5),
			Vector3(CHUTE_WIDTH, 4.0, 1.0)
		),
		standable(
			Vector3(CASCADE_X, CASCADE_TOP_Y + 1.0, cascade_pad.end.z + 0.5),
			Vector3(CASCADE_PAD.x, 4.0, 1.0)
		),
		standable(
			Vector3(BANK_PAD_X, START_Y + 1.0, bank_pad().end.z + 0.5),
			Vector3(BANK_PAD.x, 4.0, 1.0)
		),
		standable(
			Vector3(TRANSFER_LINE_X, START_Y + 1.0, transfer_pad().end.z + 0.5),
			Vector3(TRANSFER_PAD.x, 4.0, 1.0)
		),
	]


## What `PlaygroundMapSurvey` may find unreached here: the tops of the four backstops,
## 3 m over their pads (a lip is there to be run into, not stood on), and the long bank's high edge and finish.
func survey_declared() -> Array:
	var out: Array = []
	for lip in backstops():
		out.append({
			"box": AABB(Vector3(lip.position.x, lip.end.y - 0.5, lip.position.z),
				Vector3(lip.size.x, 1.0, lip.size.z)),
			"why": "a start pad's backstop, 3 m over the pad: run into, never stood on",
		})

	# The long bank's high edge: the slab's 1 m end face, which the roll tips to 34
	# degrees — standable, and reached only by climbing over the top of a face nobody
	# stands on. The same shape as pg_lobby's steep-ramp crest.
	var corners := bank_corners()
	var edge := AABB(corners[1], Vector3.ZERO).expand(corners[3])
	out.append({
		"box": edge.grow(1.5),
		"why": "the long bank's high edge, the slab's 34-degree end face over a face nobody stands on",
	})

	# Its finish pad, which a rider reaches with the speed the bank gave them. The survey
	# slides a player down a face's fall line — here straight off the low lip — and
	# models no carried speed, as with pg_bhop_intro's main run past block 8.
	var finish := bank_finish()
	out.append({
		"box": AABB(Vector3(finish.position.x, finish.end.y - 0.5, finish.position.z),
			Vector3(finish.size.x, 1.0, finish.size.z)),
		"why": "the long bank's finish, reached with the bank's speed, which the survey does not carry",
	})

	# The transfer: each face's high edge, for the long bank's reason, and its finish.
	for face in range(2):
		var c := transfer_corners(face)
		var high_near: Vector3 = c[0] if c[0].y > c[1].y else c[1]
		var high_far: Vector3 = c[2] if c[2].y > c[3].y else c[3]
		out.append({
			"box": AABB(high_near, Vector3.ZERO).expand(high_far).grow(1.5),
			"why": "a transfer face's high edge, the slab's end face over a face nobody stands on",
		})
	var transfer_end := transfer_finish()
	out.append({
		"box": AABB(Vector3(transfer_end.position.x, transfer_end.end.y - 0.5, transfer_end.position.z),
			Vector3(transfer_end.size.x, 1.0, transfer_end.size.z)),
		"why": "the transfer's finish, reached with the second face's speed",
	})
	return out


## The clear air along Z before the box jump [param index] lands on, counted from 0.
static func cascade_gap(index: int) -> float:
	return lerpf(
		CASCADE_FIRST_GAP, CASCADE_LAST_GAP, float(index) / float(CASCADE_BLOCKS)
	)


## Bonus 2 as the boxes a player lands on, start pad to finish pad, in order.
##
## [b]This is the whole description of the route.[/b] The geometry is built from it, the
## splits are drawn across two of its blocks, and `headless_playground` reads every
## jump's gap and drop off it and drives a bot along it. The pad and the finish sit on
## the line; the blocks between alternate sides of it, west first.
static func cascade_route() -> Array[AABB]:
	var route: Array[AABB] = []
	var z := CASCADE_Z

	route.append(standable(
		Vector3(CASCADE_X, CASCADE_TOP_Y - CASCADE_PAD.y * 0.5, z), CASCADE_PAD
	))

	var size := CASCADE_PAD

	for i in range(CASCADE_BLOCKS + 1):
		var last := i == CASCADE_BLOCKS
		var next := CASCADE_PAD if last else CASCADE_BLOCK
		var x := CASCADE_X if last else CASCADE_X + CASCADE_SWAY * (-1.0 if i % 2 == 0 else 1.0)
		var top := CASCADE_TOP_Y - CASCADE_DROP * float(i + 1)

		# Walked edge to edge along -Z, like the switchback: spacing by centres would make
		# the clear air a player jumps differ from the number written above.
		z -= size.z * 0.5 + cascade_gap(i) + next.z * 0.5
		size = next
		route.append(standable(Vector3(x, top - next.y * 0.5, z), next))

	return route


## How far the plunge falls, in metres. Follows from the pitch and the run, so
## changing either moves the geometry and the zones together.
static func chute_drop() -> float:
	return CHUTE_RUN * tan(deg_to_rad(CHUTE_PITCH))


## The height of the foot of the slide.
static func chute_bottom_y() -> float:
	return CHUTE_TOP_Y - chute_drop()


## The length of the face along its own surface, which is what the slab measures.
static func chute_slope_length() -> float:
	return CHUTE_RUN / cos(deg_to_rad(CHUTE_PITCH))


## Where the face meets the run-out, in Z.
static func chute_slide_end_z() -> float:
	return START_Z - CHUTE_RUN


## Where the run-out ends and the finish pad begins, in Z.
static func chute_end_z() -> float:
	return chute_slide_end_z() - CHUTE_RUNOUT


## The height of the face at [param z], for anything that needs to place something
## against it — the splits below, and a check that wants to know where the surface
## is without rediscovering the trigonometry.
static func chute_surface_y(z: float) -> float:
	var t := clampf((START_Z - z) / CHUTE_RUN, 0.0, 1.0)
	return CHUTE_TOP_Y - t * chute_drop()


## The map's zones, built from the same constants as the geometry.
func timer_zones() -> DotTimerZoneSet:
	return build_zones()


## Buildable without a scene, so a tool can write the JSON copy in `maps/`.
static func build_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = &"pg_surf_intro"
	zones.meta["tier"] = 2
	zones.meta["author"] = "playground"

	# The start volume sits ON the start platform: the run begins when the player
	# LEAVES it, which is when they step off the front edge onto the ramps.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
	start.set_box(
		Vector3(-9.0, START_Y, START_Z - 1.0),
		Vector3(9.0, START_Y + 6.0, START_Z + 15.0)
	)
	zones.add(start)

	# The finish spans the whole width of the pad and is six metres deep. Deep,
	# because at 128 Hz a player at 30 m/s crosses 23 cm in a tick and a thin finish
	# line is one the fastest players pass straight through — see
	# DotTimerZoneSet.thin_zones.
	var finish := DotTimerZone.make(DotTimerZone.Kind.END, DotTimerTrack.MAIN)
	finish.set_box(
		Vector3(-9.0, END_Y, END_Z - 12.0),
		Vector3(9.0, END_Y + 8.0, END_Z - 3.0)
	)
	zones.add(finish)

	# Two stages, so the map has splits.
	for i in range(1, 3):
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, DotTimerTrack.MAIN)
		stage.number = float(i)

		var z := lerpf(START_Z, END_Z, float(i) / 3.0)
		var y := lerpf(START_Y, END_Y, float(i) / 3.0)

		stage.set_box(
			Vector3(-30.0, y - 20.0, z - 2.0),
			Vector3(30.0, y + 20.0, z + 2.0)
		)
		zones.add(stage)

	# Below the map: anything that gets here has fallen off, and putting them back
	# at the spawn is much better than watching them descend for ever.
	var pit := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, DotTimerTrack.MAIN)
	pit.set_box(
		Vector3(-400.0, END_Y - 120.0, END_Z - 400.0),
		Vector3(400.0, END_Y - 40.0, START_Z + 400.0)
	)
	zones.add(pit)

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, DotTimerTrack.MAIN)
	spawn.destination = Vector3(0.0, START_Y + 1.0, START_Z + 6.0)
	spawn.destination_yaw = 0.0
	zones.add(spawn)

	_add_plunge_zones(zones)
	_add_the_cascade(zones)
	_add_the_bank(zones)
	_add_the_transfer(zones)

	return zones


## Bonus 1's zones. A track carries its own, and every kind the main route has —
## see `[track-zone-1]`: a RESPAWN on track 0 catches nobody running track 1, and
## `DotTimerZoneSet.problems()` is a per-zone check that says nothing about a track
## being COMPLETE. A route with a start and a finish and no reset is one a player
## falls out of the world on, which is what this family found by running one.
static func _add_plunge_zones(zones: DotTimerZoneSet) -> void:
	var track := DotTimerTrack.BONUS_FIRST
	var half := CHUTE_WIDTH * 0.5

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = Vector3(
		CHUTE_X, CHUTE_TOP_Y + 1.0, START_Z + CHUTE_PAD_LENGTH - 3.0
	)
	# Zero is -Z, which is the way this route runs — written rather than defaulted,
	# for the reason `pg_bhop_intro` writes it: a player who arrives facing the
	# backstop has to find the course before they can start it.
	spawn.destination_yaw = 0.0
	zones.add(spawn)

	# On the pad. The run begins when the player LEAVES it, which is the moment they
	# commit to the face — timing from arrival would time their run-up.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(CHUTE_X - half, CHUTE_TOP_Y - 0.5, START_Z + 0.5),
		Vector3(CHUTE_X + half, CHUTE_TOP_Y + 6.0, START_Z + CHUTE_PAD_LENGTH - 0.5)
	)
	zones.add(start)

	# Splits across the face, each placed at the height the face actually is there
	# rather than at a height written down twice. Generous in Y because a player who
	# has left the surface is still on the route until the reset volume says
	# otherwise, and a split they jump over is a split that never fires.
	for number in range(CHUTE_SPLITS.size()):
		var t: float = CHUTE_SPLITS[number]
		var z: float = START_Z - CHUTE_RUN * t
		var y := chute_surface_y(z)

		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
		stage.number = float(number + 1)
		stage.set_box(
			Vector3(CHUTE_X - half, y - 10.0, z - 1.5),
			Vector3(CHUTE_X + half, y + 10.0, z + 1.5)
		)
		zones.add(stage)

	# Deep, and for a sharper version of the usual reason: this route exists to make
	# the player fast, so it is the one place on the map where a thin line is certain
	# to be passed through rather than merely likely.
	var finish := DotTimerZone.make(DotTimerZone.Kind.END, track)
	finish.set_box(
		Vector3(CHUTE_X - half, chute_bottom_y() - 0.5, chute_end_z() - 14.0),
		Vector3(CHUTE_X + half, chute_bottom_y() + 7.0, chute_end_z() - 1.0)
	)
	zones.add(finish)

	# Under the whole route, twelve metres below its lowest floor and twenty-eight
	# thick: a player who drifts off the side of the face is doing 30 m/s downward
	# by the time they reach it, which is 23 cm a tick, so the depth is what stops
	# it being tunnelled. Wider than the face by ten metres either side, because
	# leaving the face sideways is the ordinary way to lose this run.
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(CHUTE_X - half - 10.0, chute_bottom_y() - 40.0, chute_end_z() - 40.0),
		Vector3(CHUTE_X + half + 10.0, chute_bottom_y() - 12.0, START_Z + 40.0)
	)
	zones.add(reset)


## Bonus 2's zones: a spawn, a start, a split across each of [constant
## CASCADE_SPLIT_BLOCKS], a finish, and a reset under the whole staircase.
##
## [b]The splits are slabs across the route, not boxes on a block.[/b] The route only
## ever descends along -Z, so a slab the full width of the staircase at a block's Z is
## crossed by every way down it — and the block after it is over 8 m of air from the
## block before it, past any jump, so nobody reaches the next section without passing through it.
static func _add_the_cascade(zones: DotTimerZoneSet) -> void:
	var track := CASCADE_TRACK
	var route := cascade_route()
	var pad: AABB = route[0]

	# On the pad, a stride back from its leading edge, facing down the route. Yaw 0 is
	# -Z, which is the way it runs; see `_add_plunge_zones` for why it is written.
	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = Vector3(pad.get_center().x, pad.end.y + 1.0, pad.position.z + 2.0)
	spawn.destination_yaw = 0.0
	zones.add(spawn)

	# The whole pad and the air above it: the run begins at the first jump.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(pad.position.x, pad.end.y - 0.5, pad.position.z),
		Vector3(pad.end.x, pad.end.y + 5.0, pad.end.z)
	)
	zones.add(start)

	var low := pad.position
	var high := pad.end

	for box in route:
		low = low.min(box.position)
		high = high.max(box.end)

	for n in range(CASCADE_SPLIT_BLOCKS.size()):
		var block: AABB = route[int(CASCADE_SPLIT_BLOCKS[n])]
		var z := block.get_center().z
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
		stage.number = float(n + 1)
		stage.set_box(
			Vector3(low.x - 2.0, block.end.y - 3.0, z - 1.0),
			Vector3(high.x + 2.0, block.end.y + 6.0, z + 1.0)
		)
		zones.add(stage)

	# The finish pad and the air above it, deep for `thin_zones`' reason.
	var last: AABB = route[route.size() - 1]
	var finish := DotTimerZone.make(DotTimerZone.Kind.END, track)
	finish.set_box(
		Vector3(last.position.x, last.end.y - 1.0, last.position.z),
		Vector3(last.end.x, last.end.y + 5.0, last.end.z)
	)
	zones.add(finish)

	# Under the lowest block by three metres, five thick, the whole staircase wide and
	# ten metres beyond it on every side. Everything on the route is above it, so every
	# fall passes through it; a player falling from the top block reaches it at about
	# 20 m/s, 16 cm a tick, well inside five metres.
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(low.x - 10.0, low.y - 8.0, low.z - 10.0),
		Vector3(high.x + 10.0, low.y - 3.0, high.z + 10.0)
	)
	zones.add(reset)


## Bonus 3's zones: a spawn and a start on the pad, a split across the whole bank at
## each of [constant BANK_SPLITS], a finish over the finish pad, and a reset under all of
## it.
##
## [b]The splits are slabs across the whole face and far above and below it.[/b] The
## bank is the only way from the pad to the finish, and a rider anywhere on it — at its
## low lip or its high edge, or in the air off it — crosses each one.
static func _add_the_bank(zones: DotTimerZoneSet) -> void:
	var track := BANK_TRACK
	var pad := bank_pad()
	var corners := bank_corners()

	var low := corners[0]
	var high := corners[0]
	for corner in corners:
		low = low.min(corner)
		high = high.max(corner)

	# On the pad, a stride back from its front edge, on the riding line and facing
	# down the bank; yaw 0 is -Z. See `_add_plunge_zones` for why it is written.
	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = Vector3(BANK_PAD_X, pad.end.y + 1.0, pad.position.z + 2.0)
	spawn.destination_yaw = 0.0
	zones.add(spawn)

	# The pad and the air above it: the run begins when the rider drops onto the bank.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(pad.position.x, pad.end.y - 0.5, pad.position.z),
		Vector3(pad.end.x, pad.end.y + 5.0, pad.end.z)
	)
	zones.add(start)

	var along := bank_basis() * Vector3(0.0, 0.0, -BANK_SIZE.z)
	for n in range(BANK_SPLITS.size()):
		var z: float = bank_near_centre().z + along.z * float(BANK_SPLITS[n])
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
		stage.number = float(n + 1)
		stage.set_box(
			Vector3(low.x - 4.0, bank_surface_y(low.x, z) - 6.0, z - 1.5),
			Vector3(high.x + 4.0, bank_surface_y(high.x, z) + 6.0, z + 1.5)
		)
		zones.add(stage)

	# The finish pad and the air over it, its whole length: a faster rider lands
	# further out, and every landing on it is a finish.
	var finish_pad := bank_finish()
	var finish := DotTimerZone.make(DotTimerZone.Kind.END, track)
	finish.set_box(
		Vector3(finish_pad.position.x, finish_pad.end.y - 0.5, finish_pad.position.z),
		Vector3(finish_pad.end.x, finish_pad.end.y + 6.0, finish_pad.end.z)
	)
	zones.add(finish)

	# Under everything by three metres and eight thick, and thirty metres wide of the
	# low lip, which is where a rider who holds too little goes: off it at up to
	# 20 m/s sideways, and falling 25 m before arriving here at 0.27 m a tick.
	var bottom := minf(low.y, finish_pad.position.y)
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(low.x - 30.0, bottom - 11.0, finish_pad.position.z - 10.0),
		Vector3(high.x + 20.0, bottom - 3.0, pad.end.z + 10.0)
	)
	zones.add(reset)


## Bonus 4's zones: a spawn and a start on the pad, a split across the whole gap between
## the faces (crossing it IS the transfer) and one across the second face, a finish over the
## finish pad, and a reset under all of it and wide of both low lips.
static func _add_the_transfer(zones: DotTimerZoneSet) -> void:
	var track := TRANSFER_TRACK
	var pad := transfer_pad()

	var low := transfer_corners(0)[0]
	var high := low
	for face in range(2):
		for corner in transfer_corners(face):
			low = low.min(corner)
			high = high.max(corner)

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = Vector3(TRANSFER_LINE_X, pad.end.y + 1.0, pad.position.z + 2.0)
	spawn.destination_yaw = 0.0
	zones.add(spawn)

	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(pad.position.x, pad.end.y - 0.5, pad.position.z),
		Vector3(pad.end.x, pad.end.y + 5.0, pad.end.z)
	)
	zones.add(start)

	# Split 1 fills the gap between the two low lips, from the second face's near edge to
	# the first's far one, and from under both to far over both: nobody reaches the second
	# face without crossing it.
	var second_near := transfer_near_centre(1).z
	var gap_split := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
	gap_split.number = 1.0
	gap_split.set_box(
		Vector3(transfer_lip_x(1) + 0.2, low.y - 6.0, transfer_far_z(0)),
		Vector3(transfer_lip_x(0) - 0.2, high.y + 6.0, second_near)
	)
	zones.add(gap_split)

	var z := second_near + (transfer_far_z(1) - second_near) * TRANSFER_SECOND_SPLIT
	var side := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
	side.number = 2.0
	var y_a := transfer_surface_y(1, low.x, z)
	var y_b := transfer_surface_y(1, high.x, z)
	side.set_box(
		Vector3(low.x - 4.0, minf(y_a, y_b) - 6.0, z - 1.5),
		Vector3(high.x + 4.0, maxf(y_a, y_b) + 6.0, z + 1.5)
	)
	zones.add(side)

	# The finish is the last few metres of the second face as well as the pad and the air
	# over it. [b]Not the pad alone, as the long bank's is[/b]: the motor stops a rider dead
	# at a face's far edge, and a finish that waited for them to slide off it and fall onto
	# the pad timed a second and more of standing still. Reaching the end of the face is
	# finishing; the pad is where they come down.
	var finish_pad := transfer_finish()
	var c1 := transfer_corners(1)
	var finish := DotTimerZone.make(DotTimerZone.Kind.END, track)
	finish.set_box(
		Vector3(
			minf(finish_pad.position.x, minf(c1[2].x, c1[3].x)) - 1.0,
			finish_pad.end.y - 0.5,
			finish_pad.position.z
		),
		Vector3(
			maxf(finish_pad.end.x, maxf(c1[2].x, c1[3].x)) + 1.0,
			maxf(c1[2].y, c1[3].y) + 6.0,
			transfer_far_z(1) + TRANSFER_FINISH_LINE
		)
	)
	zones.add(finish)

	# Thirty metres wide of either low lip: the first face's is on the left and the second's
	# on the right, and a rider who lands the transfer holding the wrong way goes off the
	# second one sideways.
	var bottom := minf(low.y, finish_pad.position.y)
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(low.x - 30.0, bottom - 11.0, finish_pad.position.z - 10.0),
		Vector3(high.x + 30.0, bottom - 3.0, pad.end.z + 10.0)
	)
	zones.add(reset)
