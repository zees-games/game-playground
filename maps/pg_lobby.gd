extends "../game/playground_map.gd"

const PlaygroundGeometry := preload("../game/playground_geometry.gd")

## `pg_lobby` — the sandbox, and a small timed course in the corner of it.
##
## [b]This is the map the server is on when it is not on a course[/b], and on a
## sandbox-first server that is most of the time: a big flat plate to build on, walls
## so props stay in and players do not walk off into nothing, a staircase and two
## ramps to prove stair-stepping and surfing still work, and room for a hundred props
## between them.
##
## [b]The course is on a bonus track, and the main track deliberately has no start
## and no end.[/b] That is the part worth reading twice. `pg_lobby` used to have no
## zones at all, which was the one thing proving the rest of the game does not quietly
## require a timer — and a sandbox with a minigame in it would have thrown that away.
## Putting the course on [constant DotTimerTrack.BONUS_FIRST] keeps both: a player on
## the main track is on a map with no timer for them, exactly as before, and a player
## who switches to bonus 1 gets a run. The mixed case is also a better test than the
## empty one, because it is the case a real sandbox server is in.
##
## It is also what answers "does this timer only do surf and bhop?". Nothing about a
## jump course is a movement genre: it is zones drawn round platforms, and the same
## sub-tick fractions, styles, records and replays apply to it.
##
## [b]There are two courses now, and the second is a different SKILL rather than a
## longer version of the first.[/b] Bonus 1 is a straight line with widening gaps: it
## asks how far a player can jump. Bonus 2 is a spiral climbing a tower: every jump is
## a turning one, so it asks whether they can keep their speed round a corner, which in
## an arena-shooter controller is air-strafing and is the thing the movement is actually
## about. A second route through a map players already know is worth more than a fifth
## map nobody has learned, and this is what that means in practice: the walk to it is
## the same walk, and everything they learned about the jump distance still applies.

## The floor plate, and the walls round it.
const SIZE := 200.0
const WALL_HEIGHT := 10.0

# --- The course ------------------------------------------------------------
#
# Every number below is read by both `_build` and `build_zones`, which is the whole
# reason the maps here are code: a start line half a metre from where the platforms
# actually are is a leaderboard that cannot be compared with anybody else's.

## Where the course runs, out in one corner and clear of the ramps.
const COURSE_X := 60.0

## The centre of the start pad, which is also where the first platform is measured
## from.
const COURSE_START_Z := 60.0

## Height of the start pad's top surface.
const COURSE_BASE_Y := 6.0

## Platforms after the start pad. Twelve since the course was first RUN — see
## [method jump_reach].
const COURSE_STEPS := 12

const PLATFORM := Vector3(3.0, 0.5, 3.0)

## The first gap, and how much longer each one is than the last.
##
## [b]Both sized against the movement, and the first version of this arithmetic was
## wrong in the one way nothing reports.[/b] It read: a jump lasts about 0.68 s, so a
## player at 7 m/s covers 4.8 m, so a last gap of 4.95 m needs a hop's worth of carried
## speed. Two things were wrong with it and the course was unfinishable because of both.
##
## The 0.68 s is the time to fall back to the height you left at, and **every platform
## here is 0.8 m higher than the one before it**: landing 0.8 m up happens at 0.53 s, so
## the real reach is 3.7 m and not 4.8. And the last gap was not 4.95 either — the gaps
## grow by [constant COURSE_GAP_GROWTH] per step and there are nine of them plus the
## finish, so they ran to 5.65 m. The course was walkable to platform 3 of 9 and no
## further, which is exactly what a bot found the first time one was asked to run it: it
## stood on the fourth platform for eight hundred ticks trying the 3.9 m gap.
##
## So they are derived now. [method jump_reach] is the arithmetic, [method gap_at] is
## the ramp, and `headless_playground` asserts that the widest gap on the course is
## inside the reach — which is the check that would have caught this, and the same shape
## as the rule every other map in this family grew after somebody drove it.
##
## [b]The course is still faster for somebody who can move, and now for a better
## reason.[/b] Every gap being walkable does not make it a walk: a player carrying
## bhop speed clears two platforms at once, and the back half is where that starts to
## pay. "Finishable by anybody, faster for somebody who can move" is what it says, and
## it is true of this version.
const COURSE_GAP := 2.2

## Sized so the LAST gap — the one onto the finish pad, index [constant COURSE_STEPS] —
## lands at about 92% of [method jump_reach]. Tight enough that the back half is a
## course rather than a corridor, inside the reach at every step.
const COURSE_GAP_GROWTH := 0.1

## How much each platform rises. Under `jump_height`, so a gap is never also a wall.
const COURSE_RISE := 0.8

# What the movement can do — `MOVE_SPEED`, `JUMP_HEIGHT`, `MOVE_GRAVITY` and
# `jump_reach(rise)` — is on `PlaygroundMap` now, because `pg_bhop_intro`'s switchback
# needed the same arithmetic and a second copy is a second thing to disagree with the
# first. `PgLobby.jump_reach` still answers, by inheritance.


## The clear air before platform [param index], counted from 0. [constant COURSE_STEPS]
## is the gap onto the finish pad.
##
## One description: [method platform_centre], [method finish_centre] and the check that
## no gap is wider than [method jump_reach] all read it, so a course somebody re-tunes
## cannot have its geometry and its rule disagree.
static func gap_at(index: int) -> float:
	return COURSE_GAP + COURSE_GAP_GROWTH * float(index)


## The widest gap anywhere on the course, in metres.
static func widest_gap() -> float:
	return gap_at(COURSE_STEPS)

## The pads at each end.
const PAD := Vector3(8.0, 1.0, 8.0)

## Where the reset volume reaches. Anything below this over the course's footprint is
## a player who fell off, and they go back to the start.
const COURSE_FLOOR_Y := 3.5

# --- The tower -------------------------------------------------------------
#
# Bonus 2. The same rule as above: every number here is read by both `_build_tower`
# and `build_zones`, because a stage line half a metre off the platform it belongs to
# is a split nobody can compare.

## Where the tower stands, in the corner opposite the jump course.
const TOWER_X := -60.0
const TOWER_Z := 60.0

## The radius the platforms are arranged on.
##
## [b]Sized against the movement, and the sentence that used to be here sized it
## against the wrong jump.[/b] It said a jump lasts 0.68 s and so covers 4.8 m — which
## is the FLAT jump, the exact error `[reach-1]` found on the jump course one corner
## over. Every step here is [constant TOWER_RISE] up, so the reach is
## `jump_reach(0.6)` = 4.0 m. Sixteen platforms over two turns at radius 6 puts their
## centres 4.59 m apart, and because the platforms are axis-aligned squares 45 degrees
## apart round a circle, the air between their nearest edges is 2.04 m rather than the
## 2.4 m the centre distance suggests. Half a reach: a turning jump nobody has to
## carry speed into, which is what made the spiral drivable by a bot at all — see
## `headless_playground::_walk_the_tower`, and [method tower_route] for the boxes the
## gaps are measured between.
const TOWER_RADIUS := 6.0

## Platforms in the spiral, not counting the start pad.
const TOWER_STEPS := 16

## How many full turns those platforms are spread over.
const TOWER_TURNS := 2.0

## How much each platform rises.
##
## Under `jump_height`, so a step is never also a wall — the same rule the jump
## course's `COURSE_RISE` follows, and for the same reason: a gap a player cannot
## jump UP is a course that ends there with no explanation.
const TOWER_RISE := 0.6

## The top surface of the start pad, at the foot of the tower.
const TOWER_BASE_Y := 2.0

## How tall the two split bands are, measured up from the platform that ends each
## third of the climb.
##
## [b]1.5 m rather than the 60 cm that reads right, and the difference is a warning
## nobody should have to learn to ignore.[/b] dot-timer samples a point per tick, so
## its thin-zone advisory flags any zone shorter than one tick of travel — and at the
## 67 m/s a bunny-hop server assumes, one tick at 60 Hz is 1.12 m. A 60 cm band is
## flagged on every map change, backtrace and all, on a server that carries this map.
## The zone was never actually at risk: it is entered going UP at about 6.8 m/s, which
## is 11 cm a tick. But an advisory that cries wolf on a stock map is one that gets
## ignored on the imported map where it is right, so the band is made taller than the
## check's worst case instead. Its LOWER face is what fires, and that has not moved:
## the split is recorded at the same height and the same instant as before. 1.5 m also
## keeps 1.5 m of air below the next band, five steps of `TOWER_RISE` above.
const TOWER_STAGE_BAND := 1.5

const TOWER_PLATFORM := Vector3(2.2, 0.4, 2.2)

## The tower's start pad. Smaller than the jump course's [constant PAD], and that is
## not cosmetic.
##
## [b]An 8 m pad reaches 5.66 m at its corners, and the first platform's inner edge is
## at `TOWER_RADIUS - TOWER_PLATFORM.x / 2` = 4.9 m — so the two OVERLAP, and the first
## jump of the course is not a jump.[/b] Nothing about that is visible in a count or in
## a screenshot from above: the pad is there, the platform is there, and a player simply
## walks the first step of a jumping course. A 6 m pad's corner is at (3, 3) from the
## middle and the first platform's nearest corner at (3.14, 3.14) — the "4.9 m" above is
## its inner edge's MIDDLE, and a square 45 degrees round points a corner inward — so
## what is left is 0.2 m of air, diagonally. Still a jump, because the platform is
## [constant TOWER_RISE] up; and a tricky one, because its underside is 0.2 m above the
## pad, so a jump taken at the lip puts a body into its side face. The suite's bot jumps
## it from a stride back for that reason (`headless_playground::_drive_route`).
const TOWER_PAD := Vector3(6.0, 1.0, 6.0)

## The finish cap on top of the pillar. See [method _build_tower] for why it is this
## much wider than the pillar.
const TOWER_FINISH := 5.0

## The pillar the spiral climbs. Its only job is to make the tower read as a tower
## rather than as slabs hanging in the air, and to be something to fall past.
const TOWER_PILLAR := 2.4

## Where the tower's reset volume reaches.
##
## Higher than the jump course's, because the tower starts lower: anything under this
## inside the tower's footprint is a player who came off the spiral.
const TOWER_FLOOR_Y := 1.2

# --- The circuit -----------------------------------------------------------

# Bonus 3, and the first thing in this family built at a CAR's scale rather than a
# player's. Same rule as the two courses above: every number here is read by both
# `_build_circuit` and `build_zones`, through one shared `circuit_point`, because a
# start line half a metre off the tarmac it belongs to is a leaderboard nobody can
# compare — and on a track a car crosses at 25 m/s that half metre is two ticks.

## The centreline's half-extents, and the radius its corners are rounded on.
##
## [b]Sized against the vehicle, exactly as the jump course was sized against the
## jump.[/b] `dot-vehicle`'s buggy tunables put it somewhere around 25 m/s flat out,
## and a corner taken at speed needs a radius the steering can actually hold. At
## r = 26 m a 25 m/s car needs 24 m/s² of lateral grip, which is more than it has — so
## the corners here are ones a driver has to brake for, which is what makes a lap
## something to get better at instead of a wall to hold the throttle against.
##
## The inner edge sits at 82 - 6 = 76 m from the middle of the plate. The jump course
## (x 60), the tower (x -60, radius 6, so -66 at worst) and the movement corner all
## live inside that, so the circuit runs round every one of them without touching any.
const CIRCUIT_HALF := 82.0
const CIRCUIT_CORNER := 26.0

## The width of the road surface. Three buggies abreast, which is what makes a corner
## a choice of line rather than a corridor.
const CIRCUIT_WIDTH := 12.0

## The road surface's thickness. It stands PROUD of the plate rather than being flush
## with it.
##
## [b]Flush is not an option and the reason is not cosmetic.[/b] Two coplanar surfaces
## at the same height z-fight, and the resulting shimmer is the single most obvious
## "this is untextured dev geometry" tell there is. 10 cm of box with its centre on
## y = 0 puts the tarmac 5 cm above the plate, which no wheel and no step height
## notices, and which a screenshot reads as a road.
const CIRCUIT_THICKNESS := 0.1

## The kerbs down either side.
##
## Low enough to drive over, because a kerb a car cannot cross is a wall, and half the
## point of a kerb is that a driver can put two wheels on it and regret it.
const CIRCUIT_KERB_HEIGHT := 0.5
const CIRCUIT_KERB_WIDTH := 1.5

## How many boxes the lap is cut into.
##
## The corners are arcs and a box is straight, so this is the chord count: 64 segments
## over the ~611 m lap ([method circuit_length]) is a ~9.6 m chord, and on a 26 m corner
## radius that leaves ~0.44 m of scallop between the chord and the true arc: more than a
## wheel radius, so the corners read as facets. Whether to cut more is an open call.
const CIRCUIT_SEGMENTS := 64

## Where the timing line sits, measured backwards along the lap from the grid.
##
## [b]This is the whole trick that makes a LOOP timeable.[/b] A start and a finish in
## the same place is a run that finishes on the tick it starts. So the grid is at
## s = 0 and the finish line is 12 m before it: a car leaves the grid heading away
## from the line, drives the entire lap, and crosses the line on the way back to the
## grid it started on. It is the same thing a real circuit does by putting the timing
## loop somewhere other than the front row, and it means a lap here is a lap rather
## than a lap minus a few metres.
const CIRCUIT_FINISH_BACK := 12.0

## The track bonus 3 runs on.
const CIRCUIT_TRACK := DotTimerTrack.BONUS_FIRST + 2

# --- The stepping stones ---------------------------------------------------
#
# Bonus 4, in the one corner of the plate nothing else uses that is not the vehicle
# tests' empty one: x 9 to 58 at z = -56, south of the shallow ramp and west of where the
# jump course's reset ends. Same rule as every course above: `_build_stones`,
# `build_zones` and the suite read these and nothing else.
#
# [b]A different question again.[/b] Bonus 1 asks how far a player can jump, the tower
# whether they can face somewhere new, the circuit whether they can drive. This asks
# whether they can STOP: ten stone columns shrinking from 2 m across to 1 m, every jump
# a diagonal across the line, and every one short enough that a flat-out running jump
# lands past the stone (`stones_route` and the suite's overshoot check). Speed, which
# every other course here rewards, is the thing to get rid of in the air.

## The track bonus 4 runs on.
const STONES_TRACK := DotTimerTrack.BONUS_FIRST + 3

## The line the stones sway either side of, and the start pad's centre on it.
const STONES_Z := -56.0
const STONES_START_X := 12.0

## The start pad and its top surface.
const STONES_PAD := Vector3(6.0, 1.0, 6.0)
const STONES_BASE_Y := 3.0

## Stones after the pad, and how wide the first and the last are. A 1 m stone is a
## player and a quarter across.
const STONES_COUNT := 10
const STONE_FIRST := 2.0
const STONE_LAST := 1.0

## The clear air along the line before stone [i]i[/i] is `STONE_GAP + STONE_GAP_GROWTH * i`;
## [constant STONES_COUNT] is the gap onto the finish. Long enough to need a jump, and
## every one shorter than `jump_reach` by more than the stone it lands on.
const STONE_GAP := 1.8
const STONE_GAP_GROWTH := 0.08

## How much each stone is higher than the last. A quarter of a metre: enough that the
## finish reads as up from the pad, nowhere near the climb limit.
const STONE_RISE := 0.25

## How far either side of [constant STONES_Z] the stones alternate, so each jump is a
## diagonal and a player lands facing the wrong way for the next one.
const STONE_SWAY := 1.0

## The finish pad, on the line.
const STONES_FINISH := Vector3(4.0, 1.0, 4.0)

## The reset: the air just above the floor under the stones. A player who misses one
## lands on the plate, inside it, and goes back to the pad.
const STONES_FLOOR_Y := 1.5

# --- Bonus 5: the launch -----------------------------------------------------
#
# [b]The first route here a player cannot get round on their own legs.[/b] Every other
# course asks something of the movement: how far, where to, whether you can stop. This
# one asks whether a player can ride something the MAP does to them. Three decks, each
# a column whose last [constant LAUNCH_BOOST_LENGTH] m is an amber booster with a
# dot-timer PUSH zone standing on it; the first two decks are [constant LAUNCH_RISES]
# (3 m, 2.6 times a jump's apex) above the one before and the last is level but
# [constant LAUNCH_GAPS] (6 m) out, past a running jump's 4.75. No gap on it can be
# jumped (`launch_route` and the suite's check) and every one is inside
# [method launch_reach]. It is the only PUSH zone in the game, and
# `PlaygroundPlayer._on_simulated` is the only thing that applies one.

## The track bonus 5 runs on.
const LAUNCH_TRACK := DotTimerTrack.BONUS_FIRST + 4

## The line the decks stand on (running +Z), the start pad's near edge, and its top.
## West of the middle, clear of the tower's reset (z 48 on) and of the vehicle corner.
const LAUNCH_X := -50.0
const LAUNCH_START_Z := 2.0
const LAUNCH_BASE_Y := 2.0

## Every deck, the start pad included: width across the line, length along it.
const LAUNCH_DECK := Vector2(6.0, 8.0)

## The booster at the far end of each deck, and the PUSH zone standing on it: how far
## up from the deck it reaches, and its acceleration. An acceleration rather than a
## velocity (`DotTimerRules.apply_push`), so a player entering it at walking height
## leaves its top at `sqrt(2 (a - g) h)` = 12.6 m/s and peaks `a h / g` = 5 m above the
## deck, whichever way they came in.
const LAUNCH_BOOST_LENGTH := 3.0
const LAUNCH_BOOST_HEIGHT := 1.0
const LAUNCH_BOOST_ACCEL := 100.0

## For each launch: how much higher the next deck (or the finish) is, and the clear air
## before it.
const LAUNCH_RISES: Array[float] = [3.0, 3.0, 0.0]
const LAUNCH_GAPS: Array[float] = [3.0, 3.5, 6.0]

## The finish deck: width, length.
const LAUNCH_FINISH := Vector2(6.0, 6.0)

## The reset: the air just above the plate under the decks.
const LAUNCH_FLOOR_Y := 1.2

# --- Bonus 6: the relay ------------------------------------------------------
#
# [b]The first route here that is three places rather than one.[/b] Three short legs of
# columns stand side by side north of the middle, each 4 m higher than the last and
# running the other way, and nothing joins them but a gate: a frame hanging in the air
# [constant RELAY_GATE_GAP] past a leg's last deck, holding a dot-timer TELEPORT zone
# that puts the player on the next leg's pad, stopped dead (the controller's teleport
# zeroes the velocity) and turned round to face along it (the zone's destination yaw).
# So it asks what no other course does: start again from standing, facing somewhere
# you were not, twice in one run. The legs are 10 m apart and 2.5 m apart in height, so
# no jump joins them; and a gate is entered by jumping at it, because a player who walks
# off the deck falls under its sill before reaching it. They are the first TELEPORT
# zones on any map here; `Playground._on_effect_requested` has applied the kind since
# it was written.

## The track bonus 6 runs on.
const RELAY_TRACK := DotTimerTrack.BONUS_FIRST + 5

## The west end every leg starts or finishes at, each leg's line (z), and the top of
## each leg's pad. Leg 0 and leg 2 run east (+X), leg 1 west. North of the middle, clear
## of the movement corner's steep ramp (z 35 and under), the jump course (x 56 on) and
## the circuit's inner kerb (z 74 on).
const RELAY_WEST_X := 10.0
const RELAY_Z: Array[float] = [46.0, 56.0, 66.0]
const RELAY_BASE_Y: Array[float] = [2.0, 6.0, 10.0]

## A pad (where a leg starts, or a gate lands you) and a deck: length along the leg,
## width across it.
const RELAY_PAD := Vector2(4.0, 4.0)
const RELAY_DECK := Vector2(3.0, 3.0)

## The clear air before each deck of a leg, and how much higher each deck is than the
## one before it.
const RELAY_GAPS: Array[float] = [2.4, 2.7, 3.0]
const RELAY_RISE := 0.5

## The gate past a leg's last deck: the air before it, its depth along the leg, the
## opening's height above the deck's top, and how far under the deck's top its sill is.
## A walk-off at `MOVE_SPEED` has fallen `0.5 g (gap / v)^2` = 1.28 m by the gate, past
## the sill; a jump is 0.6 m or more over the deck there.
const RELAY_GATE_GAP := 2.5
const RELAY_GATE_DEPTH := 1.0
const RELAY_GATE_HEIGHT := 3.0
const RELAY_GATE_SILL := 0.5

## The last leg's finish: the air before it (and RELAY_RISE up), its length and width.
const RELAY_FINISH_GAP := 3.0
const RELAY_FINISH := Vector2(4.0, 4.0)

## The reset: the air just above the plate under all three legs.
const RELAY_FLOOR_Y := 1.2


func _build() -> void:
	PlaygroundGeometry.light(self)

	fallback_spawn = Vector3(0.0, 1.0, 0.0)

	PlaygroundGeometry.box(
		self,
		Vector3(0.0, -0.5, 0.0),
		Vector3(SIZE, 1.0, SIZE),
		PlaygroundGeometry.COLOUR_FLOOR
	)

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
	_build_course()
	_build_tower()
	_build_circuit()
	_build_stones()
	_build_launch()
	_build_relay()


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

	# Bonus 5's decks after the pad: every one is reached by a launch, which the survey
	# does not model (it walks, drops, slides and jumps).
	var launch := launch_route()
	for i in range(1, launch.size()):
		var deck: AABB = launch[i]
		out.append({
			"box": AABB(Vector3(deck.position.x, deck.end.y - 0.5, deck.position.z),
				Vector3(deck.size.x, 1.0, deck.size.z)),
			"why": "bonus 5's deck %d, reached only by the booster before it" % i,
		})

	return out


## A staircase and two ramps, so the movement is visible without leaving the sandbox.
##
## Kept from when this map was only a lobby. The staircase is what makes stair
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


## The minigame: a start pad, twelve platforms with widening gaps, and a finish pad.
func _build_course() -> void:
	_pad(
		Vector3(COURSE_X, COURSE_BASE_Y - PAD.y * 0.5, COURSE_START_Z),
		PlaygroundGeometry.COLOUR_START
	)

	for i in range(COURSE_STEPS):
		var at := platform_centre(i)

		PlaygroundGeometry.box(
			self, at, PLATFORM, PlaygroundGeometry.COLOUR_PLATFORM
		)

	var finish := finish_centre()

	_pad(
		Vector3(finish.x, finish.y - PAD.y * 0.5, finish.z),
		PlaygroundGeometry.COLOUR_END
	)


## A pad plus the pillar holding it up, so the course reads as a structure rather
## than as slabs floating in the air.
func _pad(at: Vector3, colour: Color, size: Vector3 = PAD) -> void:
	PlaygroundGeometry.box(self, at, size, colour)

	# From the floor to the underside of the pad. Its centre is halfway up that.
	var height := at.y - size.y * 0.5

	if height <= 0.0:
		return

	PlaygroundGeometry.box(
		self,
		Vector3(at.x, height * 0.5, at.z),
		Vector3(1.6, height, 1.6),
		PlaygroundGeometry.COLOUR_PLATFORM
	)


## The centre of platform [param index], counted from 0.
##
## [b]Static, so [method build_zones] can call it without a scene.[/b] The zones and
## the geometry are the same arithmetic, which is what stops a stage line drifting off
## the platform it is supposed to be on.
static func platform_centre(index: int) -> Vector3:
	# Walked forward edge by edge rather than computed in closed form. The gap grows
	# with each step, so "centre to centre" and "clear air between them" are two
	# different numbers — and it is the second one a player has to jump. Spacing by
	# centres makes the real gap quietly shrink as the platforms get further apart,
	# which is the opposite of what this course is for.
	var edge := COURSE_START_Z - PAD.z * 0.5

	for i in range(index + 1):
		edge -= gap_at(i)
		edge -= PLATFORM.z

	return Vector3(
		COURSE_X,
		COURSE_BASE_Y + COURSE_RISE * float(index + 1) - PLATFORM.y * 0.5,
		edge + PLATFORM.z * 0.5
	)


## The top surface of the finish pad, one gap past the last platform.
static func finish_centre() -> Vector3:
	var last := platform_centre(COURSE_STEPS - 1)

	var edge := last.z - PLATFORM.z * 0.5
	edge -= gap_at(COURSE_STEPS)

	return Vector3(
		COURSE_X,
		last.y + PLATFORM.y * 0.5 + COURSE_RISE,
		edge - PAD.z * 0.5
	)


## Bonus 2: a start pad, a pillar, and sixteen platforms spiralling up around it.
func _build_tower() -> void:
	_pad(
		Vector3(TOWER_X, TOWER_BASE_Y - TOWER_PAD.y * 0.5, TOWER_Z),
		PlaygroundGeometry.COLOUR_START,
		TOWER_PAD
	)

	# The pillar runs from the TOP OF THE PAD to just under the last platform. It is
	# not structural — nothing here is — but a spiral with nothing in the middle of it
	# reads as debris, and a player who cannot see the shape of a course cannot plan a
	# route through it.
	#
	# [b]From the pad's surface, not from the floor.[/b] The first version ran it from
	# y = 0, which put a 2.4 m column straight up through the middle of an 8 m pad —
	# so the player spawned INSIDE it and could not move. Every count passed: the pad
	# was there, the platforms were there, the zones were right, and the bot walking
	# the course reported that it had not gone anywhere. The pad has its own support
	# under it, built by `_pad`, which is why the two do not have to meet.
	var top := tower_platform_centre(TOWER_STEPS - 1).y
	var height := top - TOWER_BASE_Y

	PlaygroundGeometry.box(
		self,
		Vector3(TOWER_X, TOWER_BASE_Y + height * 0.5, TOWER_Z),
		Vector3(TOWER_PILLAR, height, TOWER_PILLAR),
		PlaygroundGeometry.COLOUR_PLATFORM
	)

	for i in range(TOWER_STEPS):
		PlaygroundGeometry.box(
			self,
			tower_platform_centre(i),
			TOWER_PLATFORM,
			PlaygroundGeometry.COLOUR_PLATFORM
		)

	var finish := tower_finish_centre()

	# Wider than the pillar by a clear margin, and that is a visibility decision rather
	# than a gameplay one. At 4 m over a 2.4 m pillar the red cap is almost entirely
	# hidden behind it from ground level — a course whose finish a player cannot see is
	# a course they cannot plan a route up. At 5 m it reads as a cap from the pad.
	PlaygroundGeometry.box(
		self,
		Vector3(finish.x, finish.y - TOWER_PLATFORM.y * 0.5, finish.z),
		Vector3(TOWER_FINISH, TOWER_PLATFORM.y, TOWER_FINISH),
		PlaygroundGeometry.COLOUR_END
	)


## The centre of tower platform [param index], counted from 0.
##
## [b]Static, for the reason [method platform_centre] is.[/b] The zones and the
## geometry are the same arithmetic, which is what stops a stage line drifting off the
## platform it is supposed to be on.
##
## The first platform is one step round from the start pad rather than above it, so
## the run begins with a jump instead of with standing up.
static func tower_platform_centre(index: int) -> Vector3:
	var angle := TAU * TOWER_TURNS * float(index + 1) / float(TOWER_STEPS)

	return Vector3(
		TOWER_X + sin(angle) * TOWER_RADIUS,
		TOWER_BASE_Y + TOWER_RISE * float(index + 1) - TOWER_PLATFORM.y * 0.5,
		TOWER_Z + cos(angle) * TOWER_RADIUS
	)


## The top surface of the tower's finish platform, above the middle of the pillar.
##
## Above the pillar rather than one more step round, because a run that ends in the
## middle is a run a player can see the end of from the bottom — and the last jump
## being INWARD is a different jump from the fifteen before it, which is the right way
## for a course to end.
static func tower_finish_centre() -> Vector3:
	var last := tower_platform_centre(TOWER_STEPS - 1)

	return Vector3(
		TOWER_X,
		last.y + TOWER_PLATFORM.y * 0.5 + TOWER_RISE,
		TOWER_Z
	)


## Bonus 1 as the boxes a player lands on, start pad to finish pad, in order.
##
## Built from the same functions the geometry is, so a route cannot describe a course
## that is not there. `headless_playground` reads the gap and the rise of every jump off
## it and asserts each one is inside [method jump_reach] — which asks the question of
## the pad and the finish pad as well as of [method gap_at]'s ramp.
static func course_route() -> Array[AABB]:
	var route: Array[AABB] = [
		standable(
			Vector3(COURSE_X, COURSE_BASE_Y - PAD.y * 0.5, COURSE_START_Z), PAD
		),
	]

	for i in range(COURSE_STEPS):
		route.append(standable(platform_centre(i), PLATFORM))

	var finish := finish_centre()
	route.append(
		standable(Vector3(finish.x, finish.y - PAD.y * 0.5, finish.z), PAD)
	)

	return route


## Bonus 2 as the boxes a player lands on: the pad, sixteen platforms round the pillar,
## and the cap on top of it.
##
## [b]The last jump is in this list, and it had never been measured.[/b] The check this
## replaced walked the sixteen platforms and stopped, so the inward jump onto the finish
## cap — 2.4 m of air, the widest on the tower — was the one gap on the course nothing
## asked about.
static func tower_route() -> Array[AABB]:
	var route: Array[AABB] = [
		standable(
			Vector3(TOWER_X, TOWER_BASE_Y - TOWER_PAD.y * 0.5, TOWER_Z), TOWER_PAD
		),
	]

	for i in range(TOWER_STEPS):
		route.append(standable(tower_platform_centre(i), TOWER_PLATFORM))

	var finish := tower_finish_centre()
	route.append(
		standable(
			Vector3(finish.x, finish.y - TOWER_PLATFORM.y * 0.5, finish.z),
			Vector3(TOWER_FINISH, TOWER_PLATFORM.y, TOWER_FINISH)
		)
	)

	return route


## Bonus 4: a start pad, ten stone columns standing on the plate, and a finish pad.
##
## Columns from the floor rather than slabs in the air, because what makes a stepping
## stone read as one is that there is nothing round it: a 1 m slab floating 5 m up is a
## speck, and a 1 m column is a thing a player can see the top of and aim at.
func _build_stones() -> void:
	_pad(
		Vector3(STONES_START_X, STONES_BASE_Y - STONES_PAD.y * 0.5, STONES_Z),
		PlaygroundGeometry.COLOUR_START,
		STONES_PAD
	)

	for i in range(STONES_COUNT):
		var stone := stone_box(i)
		PlaygroundGeometry.box(
			self, stone.get_center(), stone.size, PlaygroundGeometry.COLOUR_PLATFORM
		)

	var finish := stones_finish_centre()
	_pad(
		Vector3(finish.x, finish.y - STONES_FINISH.y * 0.5, finish.z),
		PlaygroundGeometry.COLOUR_END,
		STONES_FINISH
	)


## How wide stone [param index] is, shrinking evenly from [constant STONE_FIRST] to
## [constant STONE_LAST].
static func stone_size(index: int) -> float:
	return lerpf(STONE_FIRST, STONE_LAST, float(index) / float(STONES_COUNT - 1))


## The clear air along the line before stone [param index]; [constant STONES_COUNT] is
## the gap onto the finish pad.
static func stone_gap(index: int) -> float:
	return STONE_GAP + STONE_GAP_GROWTH * float(index)


## Stone [param index] as the whole column, floor to top. Static, for `platform_centre`'s
## reason: the zones and the suite read the same arithmetic the geometry is built from.
##
## Walked edge to edge along the line, as the jump course is, so the gap a player jumps
## is the number [method stone_gap] says rather than a centre distance minus a guess.
static func stone_box(index: int) -> AABB:
	var edge := STONES_START_X + STONES_PAD.x * 0.5

	for i in range(index):
		edge += stone_gap(i) + stone_size(i)

	edge += stone_gap(index)

	var size := stone_size(index)
	var top := STONES_BASE_Y + STONE_RISE * float(index + 1)
	var sway := STONE_SWAY if index % 2 == 0 else -STONE_SWAY

	return AABB(
		Vector3(edge, 0.0, STONES_Z + sway - size * 0.5),
		Vector3(size, top, size)
	)


## The top surface of the finish pad, one gap past the last stone and a rise above it.
static func stones_finish_centre() -> Vector3:
	var last := stone_box(STONES_COUNT - 1)

	return Vector3(
		last.end.x + stone_gap(STONES_COUNT) + STONES_FINISH.x * 0.5,
		last.end.y + STONE_RISE,
		STONES_Z
	)


## Bonus 4 as the boxes a player lands on: the pad, ten stones, the finish pad.
static func stones_route() -> Array[AABB]:
	var route: Array[AABB] = [
		standable(
			Vector3(STONES_START_X, STONES_BASE_Y - STONES_PAD.y * 0.5, STONES_Z),
			STONES_PAD
		),
	]

	for i in range(STONES_COUNT):
		route.append(stone_box(i))

	var finish := stones_finish_centre()
	route.append(
		standable(
			Vector3(finish.x, finish.y - STONES_FINISH.y * 0.5, finish.z), STONES_FINISH
		)
	)

	return route


## The sandbox's toys (dot-props'): balls and barrels round the spawn, a bowling lane north of
## it, and a park to the south-west with a roundabout, a see-saw, a swing, trampolines, a
## fountain, lamps on a switch, a bell and a horn. Everything clear of the movement corner, the
## courses and the circuit. Indices matter: the switch names the lamps by theirs.
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


func timer_zones() -> DotTimerZoneSet:
	return build_zones()


## The zones, built from the same constants as the geometry.
##
## [b]The main track has no start and no end, and that is deliberate.[/b] See the
## class documentation: it is what keeps "a map with no timer" a case this project
## still runs, on the map an ordinary sandbox player is standing on.
static func build_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = &"pg_lobby"
	zones.meta["tier"] = 1
	zones.meta["author"] = "playground"

	# The circuit is the one route here with no pit, and says so rather than being
	# excused by a test: the road runs inside the plate's walls (82 m out plus half its
	# width and a kerb, against walls at 100 m and 10 m tall), so there is nothing a car
	# can leave it by. See `DotTimerZoneSet.route_problems`.
	zones.meta[DotTimerZoneSet.PITLESS_TRACKS_KEY] = [CIRCUIT_TRACK]

	# Where an ordinary sandbox player appears: the middle of the plate, on the main
	# track, with nothing to time them.
	var lobby_spawn := DotTimerZone.make(
		DotTimerZone.Kind.SPAWN, DotTimerTrack.MAIN
	)
	lobby_spawn.destination = Vector3(0.0, 1.0, 0.0)
	lobby_spawn.destination_yaw = 0.0
	zones.add(lobby_spawn)

	var track := DotTimerTrack.BONUS_FIRST

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = Vector3(COURSE_X, COURSE_BASE_Y + 1.0, COURSE_START_Z)
	spawn.destination_yaw = 0.0
	zones.add(spawn)

	# The start volume sits ON the pad: timing begins when the player LEAVES it,
	# which is the jump onto the first platform. Timing from the moment they entered
	# would time their run-up along the pad.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(
			COURSE_X - PAD.x * 0.5,
			COURSE_BASE_Y - 0.5,
			COURSE_START_Z - PAD.z * 0.5
		),
		Vector3(
			COURSE_X + PAD.x * 0.5,
			COURSE_BASE_Y + 5.0,
			COURSE_START_Z + PAD.z * 0.5
		)
	)
	zones.add(start)

	var finish := finish_centre()

	# Deep, for the reason dot-timer's `thin_zones` check exists: at 128 Hz a player
	# arriving at 12 m/s covers 9 cm in a tick, and a finish line thinner than that
	# is one the fastest players pass straight through without ever being inside it.
	var end := DotTimerZone.make(DotTimerZone.Kind.END, track)
	end.set_box(
		Vector3(finish.x - PAD.x * 0.5, finish.y - 1.0, finish.z - PAD.z * 0.5),
		Vector3(finish.x + PAD.x * 0.5, finish.y + 5.0, finish.z + PAD.z * 0.5)
	)
	zones.add(end)

	# Two splits, at a third and two thirds, so the course has something to compare
	# against itself on each half. Spanning the whole width of the course rather than
	# sitting on one platform: a player who jumps past the platform still passed the
	# line — and on twelve platforms with every gap inside the jump reach, a player
	# carrying speed skips platforms routinely.
	#
	# There was one split here while there were nine platforms. A second is what makes
	# the back half of the course comparable on its own, which is the half a player
	# carrying bhop speed is actually racing.
	for split in range(2):
		var at := platform_centre(COURSE_STEPS * (split + 1) / 3)
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
		stage.number = float(split + 1)
		stage.set_box(
			Vector3(at.x - 12.0, at.y - 6.0, at.z - 1.0),
			Vector3(at.x + 12.0, at.y + 12.0, at.z + 1.0)
		)
		zones.add(stage)

	# Falling off. The course is six metres above a floor that goes on for another
	# ninety, so there is nothing to fall INTO — the reset volume is the air just
	# above the sandbox floor under the whole course, and touching it puts the player
	# back on the start pad.
	#
	# On the bonus track, so it is invisible to somebody walking through the same
	# corner of the sandbox with a physics gun. That track filter is the reason
	# [constant DotTimerZone.Kind.RESPAWN] can be used at all in a map that is also
	# somewhere people build.
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(COURSE_X - 20.0, 0.0, finish.z - 16.0),
		Vector3(COURSE_X + 20.0, COURSE_FLOOR_Y, COURSE_START_Z + 16.0)
	)
	zones.add(reset)

	_add_tower_zones(zones)
	_add_circuit_zones(zones)
	_add_stones_zones(zones)
	_add_launch_zones(zones)
	_add_relay_zones(zones)

	return zones


## Bonus 2's zones. Split out because `build_zones` was already long enough to hide
## something in, and two courses on one map is exactly when that starts to matter.
static func _add_tower_zones(zones: DotTimerZoneSet) -> void:
	var track := DotTimerTrack.BONUS_FIRST + 1

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)

	# On the pad but OFF its centre, toward the first platform.
	#
	# The centre is where the pillar stands, and a spawn inside a pillar is a player
	# who cannot move — see `_build_tower`. Off-centre also gives the run-up the first
	# jump needs, which a spawn on the far edge would not.
	var toward := tower_platform_centre(0)
	var out := Vector3(toward.x - TOWER_X, 0.0, toward.z - TOWER_Z).normalized()

	spawn.destination = Vector3(TOWER_X, TOWER_BASE_Y + 1.0, TOWER_Z) \
		+ out * (TOWER_PILLAR * 0.5 + 0.8)

	# Facing the first platform rather than facing north.
	#
	# A spiral has no obvious forward, and a player who spawns pointing at the pillar
	# has to find the course before they can start it — which on a timed run is a
	# second nobody meant to give them. Derived from the same arithmetic the platform
	# is, so it stays right if the spiral is ever re-tuned.
	# `atan2(-dx, -dz)`, and the signs are not decoration.
	#
	# `DotFpsMotor._view_basis` builds forward as `(-sin(yaw), 0, -cos(yaw))` — Godot is
	# Y-up, right-handed, -Z forward — so a yaw of 0 faces -Z and the inverse carries
	# both minus signs. The obvious `atan2(dx, dz)` is 180 degrees out AND mirrored, and
	# a player spawning with their back to a spiral has to find the course before they
	# can start it. The suite's bot caught it: dot(-1.00) with the first platform
	# directly behind them.
	spawn.destination_yaw = rad_to_deg(atan2(-out.x, -out.z))
	zones.add(spawn)

	# On the pad, so timing starts when the player LEAVES it — the jump onto the first
	# platform — rather than when they walked onto it.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(
			TOWER_X - TOWER_PAD.x * 0.5,
			TOWER_BASE_Y - 0.5,
			TOWER_Z - TOWER_PAD.z * 0.5
		),
		Vector3(
			TOWER_X + TOWER_PAD.x * 0.5,
			TOWER_BASE_Y + 5.0,
			TOWER_Z + TOWER_PAD.z * 0.5
		)
	)
	zones.add(start)

	var finish := tower_finish_centre()

	# Deep, for `thin_zones`' reason: at 128 Hz a player arriving at 12 m/s covers
	# 9 cm in a tick, and a finish thinner than that is one the fastest players pass
	# straight through without ever being inside it.
	var end := DotTimerZone.make(DotTimerZone.Kind.END, track)
	end.set_box(
		Vector3(
			finish.x - TOWER_FINISH * 0.5,
			finish.y - 1.0,
			finish.z - TOWER_FINISH * 0.5
		),
		Vector3(
			finish.x + TOWER_FINISH * 0.5,
			finish.y + 5.0,
			finish.z + TOWER_FINISH * 0.5
		)
	)
	zones.add(end)

	# Two splits rather than one, and they are HEIGHT bands rather than lines.
	#
	# A vertical line across a spiral is crossed twice per turn, so a stage drawn the
	# way bonus 1's is would fire on the way round as well as on the way up. The thing
	# that only happens once here is reaching a height, so that is what is measured:
	# a slab over the whole tower, at the height of the platform that ends each third
	# of the climb, `TOWER_STAGE_BAND` tall for the reason given there.
	for split in [1, 2]:
		var at := tower_platform_centre(TOWER_STEPS * split / 3 - 1)
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
		stage.number = float(split)
		stage.set_box(
			Vector3(
				TOWER_X - TOWER_RADIUS - 3.0,
				at.y + TOWER_PLATFORM.y * 0.5,
				TOWER_Z - TOWER_RADIUS - 3.0
			),
			Vector3(
				TOWER_X + TOWER_RADIUS + 3.0,
				at.y + TOWER_PLATFORM.y * 0.5 + TOWER_STAGE_BAND,
				TOWER_Z + TOWER_RADIUS + 3.0
			)
		)
		zones.add(stage)

	# Falling off, put back on the pad. On bonus 2's track, so it is invisible to a
	# sandbox player walking past the tower with a physics gun — the same track filter
	# that lets bonus 1 have one.
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(TOWER_X - TOWER_RADIUS - 6.0, 0.0, TOWER_Z - TOWER_RADIUS - 6.0),
		Vector3(
			TOWER_X + TOWER_RADIUS + 6.0,
			TOWER_FLOOR_Y,
			TOWER_Z + TOWER_RADIUS + 6.0
		)
	)
	zones.add(reset)


# --- The circuit -----------------------------------------------------------


## The length of one lap, in metres.
##
## A rounded rectangle: four straights of `2 * (HALF - CORNER)` between four quarter
## turns that add up to one full circle.
static func circuit_length() -> float:
	return 8.0 * (CIRCUIT_HALF - CIRCUIT_CORNER) + TAU * CIRCUIT_CORNER


## The point on the centreline [param s] metres along the lap, and the direction of
## travel there.
##
## [b]One function, and both the road and the zones are drawn from it.[/b] That is the
## same reason `platform_centre` is static: a second description of where the tarmac is
## drifts from the first, and the drift is invisible until somebody's lap is invalidated
## by a finish line sitting in the grass.
##
## Returns `[position, forward]`, both [Vector3]. The lap starts at the middle of the
## +Z straight travelling toward +X and turns right, so a driver leaving the grid has
## the plate on their left the whole way round.
static func circuit_point(s: float) -> Array:
	var straight_x := 2.0 * (CIRCUIT_HALF - CIRCUIT_CORNER)
	var straight_z := straight_x
	var arc := TAU * CIRCUIT_CORNER * 0.25
	var inner := CIRCUIT_HALF - CIRCUIT_CORNER

	var d := fposmod(s, circuit_length())

	# Leg 1: the second half of the +Z straight, from the grid out to the first corner.
	if d < straight_x * 0.5:
		return [Vector3(d, 0.0, CIRCUIT_HALF), Vector3(1.0, 0.0, 0.0)]

	d -= straight_x * 0.5

	# Corner 1, into the +X straight.
	if d < arc:
		return _circuit_arc(Vector3(inner, 0.0, inner), PI * 0.5, -d / CIRCUIT_CORNER)

	d -= arc

	# Leg 2: the whole +X straight, travelling toward -Z.
	if d < straight_z:
		return [
			Vector3(CIRCUIT_HALF, 0.0, inner - d), Vector3(0.0, 0.0, -1.0)
		]

	d -= straight_z

	# Corner 2, into the -Z straight.
	if d < arc:
		return _circuit_arc(Vector3(inner, 0.0, -inner), 0.0, -d / CIRCUIT_CORNER)

	d -= arc

	# Leg 3: the whole -Z straight, travelling toward -X.
	if d < straight_x:
		return [
			Vector3(inner - d, 0.0, -CIRCUIT_HALF), Vector3(-1.0, 0.0, 0.0)
		]

	d -= straight_x

	# Corner 3, into the -X straight.
	if d < arc:
		return _circuit_arc(
			Vector3(-inner, 0.0, -inner), -PI * 0.5, -d / CIRCUIT_CORNER
		)

	d -= arc

	# Leg 4: the whole -X straight, travelling toward +Z.
	if d < straight_z:
		return [
			Vector3(-CIRCUIT_HALF, 0.0, d - inner), Vector3(0.0, 0.0, 1.0)
		]

	d -= straight_z

	# Corner 4, back onto the +Z straight.
	if d < arc:
		return _circuit_arc(Vector3(-inner, 0.0, inner), PI, -d / CIRCUIT_CORNER)

	d -= arc

	# Leg 5: the first half of the +Z straight, running back up to the grid. The lap
	# is closed here rather than at the corner, which is what lets the finish line sit
	# behind the grid on a straight the driver is already committed to.
	return [Vector3(d - inner, 0.0, CIRCUIT_HALF), Vector3(1.0, 0.0, 0.0)]


## A point on one of the four corner arcs.
##
## [param centre] is the centre of the quarter circle, [param from] the angle the arc
## starts at, and [param turn] how far round it has gone, both in radians. The turn is
## negative because the lap goes clockwise seen from above, and the tangent is the
## radius rotated a quarter turn the same way.
static func _circuit_arc(centre: Vector3, from: float, turn: float) -> Array:
	var angle := from + turn
	var out := Vector3(cos(angle), 0.0, sin(angle))

	return [centre + out * CIRCUIT_CORNER, Vector3(out.z, 0.0, -out.x)]


## Builds the road and its kerbs.
##
## Cut into [constant CIRCUIT_SEGMENTS] boxes rather than drawn as a curve, because
## everything else in this project is a box with a [BoxShape3D] under it and a
## [ConcavePolygonShape3D] here would be the one surface in the sandbox that behaves
## differently under a wheel.
func _build_circuit() -> void:
	var length := circuit_length()
	var step := length / float(CIRCUIT_SEGMENTS)
	var half := CIRCUIT_WIDTH * 0.5

	for i in range(CIRCUIT_SEGMENTS):
		var here: Array = circuit_point(float(i) * step)
		var next: Array = circuit_point(float(i + 1) * step)
		var a: Vector3 = here[0]
		var b: Vector3 = next[0]
		var mid := (a + b) * 0.5
		var forward: Vector3 = (b - a).normalized()

		# A hair longer than the chord, so consecutive segments overlap rather than
		# meeting exactly. Two boxes that share a face leave a seam a wheel can catch
		# on at speed, and a car that loses its front axle once a lap on a corner
		# nobody built is a bug that reads as bad handling.
		var run := a.distance_to(b) + 0.2
		var basis := Basis.looking_at(forward, Vector3.UP)

		# The start/finish stretch is painted, so the line a lap is measured at is
		# visible from a car rather than being a number in a JSON file.
		var painted := i == 0 or float(i) * step > length - CIRCUIT_FINISH_BACK - step
		var surface := PlaygroundGeometry.COLOUR_START if i == 0 else (
			PlaygroundGeometry.COLOUR_END if painted
			else PlaygroundGeometry.COLOUR_FLOOR
		)

		PlaygroundGeometry.box(
			self,
			mid,
			Vector3(CIRCUIT_WIDTH, CIRCUIT_THICKNESS, run),
			surface,
			basis
		)

		# Kerbs, one either side, alternating colour so the road reads as a road from
		# above instead of as a grey ribbon on a grey plate.
		var side := basis.x * (half + CIRCUIT_KERB_WIDTH * 0.5)
		var kerb := PlaygroundGeometry.COLOUR_PLATFORM if i % 2 == 0 \
			else PlaygroundGeometry.COLOUR_RAMP

		for direction in [1.0, -1.0]:
			PlaygroundGeometry.box(
				self,
				mid + side * direction
					+ Vector3(0.0, CIRCUIT_KERB_HEIGHT * 0.5, 0.0),
				Vector3(CIRCUIT_KERB_WIDTH, CIRCUIT_KERB_HEIGHT, run),
				kerb,
				basis
			)


## A zone box spanning the road at [param s], [param depth] metres deep along the lap.
##
## Built from `circuit_point` like everything else, and deliberately axis-aligned:
## [DotTimerZone] boxes are AABBs, so a zone across a corner would have to be a
## rectangle big enough to contain the rotated one. Every zone this map places is on a
## straight for exactly that reason.
static func _circuit_zone(
	kind: int, s: float, depth: float, height: float = 6.0
) -> DotTimerZone:
	var point: Array = circuit_point(s)
	var at: Vector3 = point[0]
	var forward: Vector3 = point[1]
	var across := Vector3(forward.z, 0.0, -forward.x).abs() * CIRCUIT_WIDTH * 0.5
	var along := forward.abs() * depth * 0.5
	var extent := across + along + Vector3(0.6, 0.0, 0.6)

	var zone := DotTimerZone.make(kind, CIRCUIT_TRACK)
	zone.set_box(
		Vector3(at.x - extent.x, -1.0, at.z - extent.z),
		Vector3(at.x + extent.x, height, at.z + extent.z)
	)

	return zone


static func _add_circuit_zones(zones: DotTimerZoneSet) -> void:
	var length := circuit_length()
	var grid: Array = circuit_point(0.0)
	var at: Vector3 = grid[0]
	var forward: Vector3 = grid[1]

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, CIRCUIT_TRACK)

	# On the grid, a whisker above the tarmac. Not the plate: a car spawned at plate
	# height with a 5 cm road under it starts the lap with its wheels through the
	# surface, and a raycast vehicle with no contact has no traction at all — which is
	# the exact failure `[veh-2]` spent an hour on.
	spawn.destination = at + Vector3(0.0, CIRCUIT_THICKNESS * 0.5 + 1.0, 0.0)

	# Facing the way the lap goes, derived from the same tangent the road is. The two
	# minus signs are `_add_tower_zones`' — `DotFpsMotor._view_basis` builds forward as
	# `(-sin(yaw), 0, -cos(yaw))`, so the inverse carries both, and the obvious
	# `atan2(dx, dz)` spawns a driver pointing at the finish line they have not reached.
	spawn.destination_yaw = rad_to_deg(atan2(-forward.x, -forward.z))
	zones.add(spawn)

	# The grid box. Timing begins when the car LEAVES it, which is the moment it rolls
	# off the line, rather than when it was placed there.
	zones.add(_circuit_zone(DotTimerZone.Kind.START, 0.0, 10.0))

	# The finish, `CIRCUIT_FINISH_BACK` metres before the grid, so the car meets it at
	# the END of a full lap and never at the start of one. See the constant.
	#
	# Deep for `thin_zones`' reason and then some: at 128 Hz a car arriving at 25 m/s
	# covers 20 cm in a tick, which is over twice what a sprinting player does, and a
	# finish line thinner than that is one the fastest laps pass straight through.
	zones.add(
		_circuit_zone(
			DotTimerZone.Kind.END, length - CIRCUIT_FINISH_BACK, 8.0
		)
	)

	# Three splits, one at each of the far three straights, so a lap can be compared
	# with itself corner by corner rather than only at the end.
	for i in range(3):
		var stage := _circuit_zone(
			DotTimerZone.Kind.STAGE, length * float(i + 1) * 0.25, 3.0
		)
		stage.number = float(i + 1)
		zones.add(stage)


## Bonus 3 is driven, and nothing else here is.
##
## [b]This is the only place in the project that answers the question, and it is
## answered by the MAP.[/b] `Playground._on_seated` used to cancel every run the
## moment a player got into a car, which was right when every course was a foot
## course: a jump course driven round in a buggy is not a time anybody can compare
## with one that was jumped. It is exactly wrong on a circuit, where the car is the
## point, and a rule that cannot tell those apart makes the second one impossible to
## build.
func track_is_driven(track: int) -> bool:
	return track == CIRCUIT_TRACK


## Bonus 4's zones, from the same `stone_box` the columns are built from.
static func _add_stones_zones(zones: DotTimerZoneSet) -> void:
	var track := STONES_TRACK
	var first := stone_box(0).get_center()

	# On the pad, a stride back from its middle, facing the first stone. The yaw is
	# `_add_tower_zones`' `atan2(-dx, -dz)`, for the reason written there.
	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = Vector3(STONES_START_X - 1.0, STONES_BASE_Y + 1.0, STONES_Z)
	var toward := Vector3(
		first.x - spawn.destination.x, 0.0, first.z - spawn.destination.z
	).normalized()
	spawn.destination_yaw = rad_to_deg(atan2(-toward.x, -toward.z))
	zones.add(spawn)

	# On the pad, so the clock starts on the jump off it.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(
			STONES_START_X - STONES_PAD.x * 0.5,
			STONES_BASE_Y - 0.5,
			STONES_Z - STONES_PAD.z * 0.5
		),
		Vector3(
			STONES_START_X + STONES_PAD.x * 0.5,
			STONES_BASE_Y + 5.0,
			STONES_Z + STONES_PAD.z * 0.5
		)
	)
	zones.add(start)

	# Deep, for `thin_zones`' reason, like every finish here.
	var finish := stones_finish_centre()
	var end := DotTimerZone.make(DotTimerZone.Kind.END, track)
	end.set_box(
		Vector3(
			finish.x - STONES_FINISH.x * 0.5, finish.y - 1.0,
			finish.z - STONES_FINISH.z * 0.5
		),
		Vector3(
			finish.x + STONES_FINISH.x * 0.5, finish.y + 5.0,
			finish.z + STONES_FINISH.z * 0.5
		)
	)
	zones.add(end)

	# Two splits, on stones 3 and 6 of 10: slabs across the whole course and the whole
	# height above the reset, 2 m deep along the line and centred on the stone. A player
	# who clears a stone in one jump still passes through its slab — bonus 1's rule —
	# and one who misses it falls into the reset before reaching the next.
	for split in [1, 2]:
		var stone := stone_box(STONES_COUNT * split / 3 - 1).get_center()
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
		stage.number = float(split)
		stage.set_box(
			Vector3(stone.x - 1.0, STONES_FLOOR_Y, STONES_Z - 6.0),
			Vector3(stone.x + 1.0, finish.y + 10.0, STONES_Z + 6.0)
		)
		zones.add(stage)

	# The plate under the whole course, on bonus 4's track only: a sandbox player
	# walking between the columns is left alone, as under every course here.
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(STONES_START_X - STONES_PAD.x, 0.0, STONES_Z - 8.0),
		Vector3(finish.x + STONES_FINISH.x * 2.0, STONES_FLOOR_Y, STONES_Z + 8.0)
	)
	zones.add(reset)


# --- Bonus 5: the launch -----------------------------------------------------

## Builds the decks: each a column from the plate to its top, split into a plain part
## and the amber booster at its far end, so a player can see where the throw is.
func _build_launch() -> void:
	var route := launch_route()

	for i in range(route.size()):
		var deck: AABB = route[i]
		var last := i == route.size() - 1
		var colour := PlaygroundGeometry.COLOUR_PLATFORM
		if i == 0:
			colour = PlaygroundGeometry.COLOUR_START
		elif last:
			colour = PlaygroundGeometry.COLOUR_END

		var plain := deck
		if not last:
			plain.size.z -= LAUNCH_BOOST_LENGTH
			var boost := launch_boost(i)
			PlaygroundGeometry.box(
				self, boost.get_center(), boost.size, PlaygroundGeometry.COLOUR_BOOST
			)

		PlaygroundGeometry.box(self, plain.get_center(), plain.size, colour)


## Deck [param index] as the whole column, plate to top: 0 is the start pad, the last
## is the finish. Walked edge to edge along the line from [constant LAUNCH_START_Z], so
## a gap is the number in [constant LAUNCH_GAPS] rather than a centre distance.
static func launch_deck(index: int) -> AABB:
	var near := LAUNCH_START_Z
	var top := LAUNCH_BASE_Y

	for i in range(index):
		near += LAUNCH_DECK.y + LAUNCH_GAPS[i]
		top += LAUNCH_RISES[i]

	var size := LAUNCH_FINISH if index == LAUNCH_GAPS.size() else LAUNCH_DECK

	return AABB(
		Vector3(LAUNCH_X - size.x * 0.5, 0.0, near), Vector3(size.x, top, size.y)
	)


## The booster at the far end of deck [param index], as a column like the deck.
static func launch_boost(index: int) -> AABB:
	var deck := launch_deck(index)
	return AABB(
		Vector3(deck.position.x, 0.0, deck.end.z - LAUNCH_BOOST_LENGTH),
		Vector3(deck.size.x, deck.size.y, LAUNCH_BOOST_LENGTH)
	)


## Bonus 5 as the boxes a player lands on: the pad, two decks, the finish.
static func launch_route() -> Array[AABB]:
	var route: Array[AABB] = []

	for i in range(LAUNCH_GAPS.size() + 1):
		route.append(launch_deck(i))

	return route


## The clear air a player running at [constant MOVE_SPEED] into a booster from its near
## edge crosses before coming down [param rise] above the deck they left.
##
## Closed form over the same constants the zone is built from: pushed through
## [constant LAUNCH_BOOST_HEIGHT] at `a - g`, then a ballistic arc from its top. The
## suite asserts every gap is past a jump and inside this, and measures the arc.
static func launch_reach(rise: float) -> float:
	var net := LAUNCH_BOOST_ACCEL - MOVE_GRAVITY
	var exit_speed := sqrt(2.0 * net * LAUNCH_BOOST_HEIGHT)
	var fall := launch_apex() - rise
	var airborne := exit_speed / net + exit_speed / MOVE_GRAVITY + sqrt(2.0 * fall / MOVE_GRAVITY)

	return MOVE_SPEED * airborne - LAUNCH_BOOST_LENGTH


## How far above the deck a booster throws a player who walked onto it: `a h / g`.
static func launch_apex() -> float:
	return LAUNCH_BOOST_ACCEL * LAUNCH_BOOST_HEIGHT / MOVE_GRAVITY


## Bonus 5's zones, from the same `launch_deck` the columns are built from.
static func _add_launch_zones(zones: DotTimerZoneSet) -> void:
	var track := LAUNCH_TRACK
	var route := launch_route()
	var pad := route[0]
	var finish := route[route.size() - 1]

	# A stride onto the pad from its near edge, facing up the line (+Z: yaw 180, by
	# `_add_tower_zones`' `atan2(-dx, -dz)`).
	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = Vector3(LAUNCH_X, pad.end.y + 1.0, pad.position.z + 1.5)
	spawn.destination_yaw = rad_to_deg(atan2(-0.0, -1.0))
	zones.add(spawn)

	# The pad short of its booster, so the clock starts on the walk onto the booster
	# and a start zone never shares a volume with a push.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(pad.position.x, pad.end.y - 0.5, pad.position.z),
		Vector3(pad.end.x, pad.end.y + 5.0, pad.end.z - LAUNCH_BOOST_LENGTH)
	)
	zones.add(start)

	# One PUSH per booster, straight up, standing on it.
	for i in range(route.size() - 1):
		var boost := launch_boost(i)
		var push := DotTimerZone.make(DotTimerZone.Kind.PUSH, track)
		push.direction = Vector3(0.0, LAUNCH_BOOST_ACCEL, 0.0)
		push.set_box(
			Vector3(boost.position.x, boost.end.y - 0.5, boost.position.z),
			Vector3(boost.end.x, boost.end.y + LAUNCH_BOOST_HEIGHT, boost.end.z)
		)
		zones.add(push)

	# A split on each deck between the pad and the finish: a slab the deck's length,
	# across the whole line and from the reset to far above the arc. A deck is only
	# reached by the launch before it, and the next one only from this one.
	for i in range(1, route.size() - 1):
		var deck := route[i]
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
		stage.number = float(i)
		stage.set_box(
			Vector3(LAUNCH_X - 8.0, LAUNCH_FLOOR_Y, deck.position.z),
			Vector3(LAUNCH_X + 8.0, deck.end.y + 10.0, deck.end.z)
		)
		zones.add(stage)

	# Deep, for `thin_zones`' reason, like every finish here.
	var end := DotTimerZone.make(DotTimerZone.Kind.END, track)
	end.set_box(
		Vector3(finish.position.x, finish.end.y - 1.0, finish.position.z),
		Vector3(finish.end.x, finish.end.y + 5.0, finish.end.z)
	)
	zones.add(end)

	# The plate under the whole line, on bonus 5's track only.
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(LAUNCH_X - 10.0, 0.0, pad.position.z - 4.0),
		Vector3(LAUNCH_X + 10.0, LAUNCH_FLOOR_Y, finish.end.z + 4.0)
	)
	zones.add(reset)


# --- Bonus 6: the relay ------------------------------------------------------

## Builds the three legs, each box a column from the plate, and a gate past the end of the
## first two: a frame and a see-through pane, drawn and nothing else (no body), so the
## survey never sees one and a player passes through the frame.
func _build_relay() -> void:
	for leg in range(RELAY_Z.size()):
		var boxes := relay_leg(leg)
		var last := leg == RELAY_Z.size() - 1

		for i in range(boxes.size()):
			var box: AABB = boxes[i]
			if i == boxes.size() - 1 and not last:
				_build_relay_gate(box)
				continue

			var colour := PlaygroundGeometry.COLOUR_PLATFORM
			if i == 0:
				colour = PlaygroundGeometry.COLOUR_START
			elif i == boxes.size() - 1:
				colour = PlaygroundGeometry.COLOUR_END
			PlaygroundGeometry.box(self, box.get_center(), box.size, colour)


## A gate standing over [param gate]'s footprint (the opening the zone fills): two posts,
## a lintel, a sill and the pane between them.
func _build_relay_gate(gate: AABB) -> void:
	var zone := relay_gate_zone(gate)
	var bar := 0.3
	var mid := zone.get_center()
	var across := zone.size.z
	var along := zone.size.x

	for side in [-1.0, 1.0]:
		PlaygroundGeometry.panel(
			self, Vector3(mid.x, mid.y, mid.z + side * (across + bar) * 0.5),
			Vector3(along * 0.4, zone.size.y + bar * 2.0, bar), PlaygroundGeometry.COLOUR_GATE
		)
	for end_y in [zone.position.y - bar * 0.5, zone.end.y + bar * 0.5]:
		PlaygroundGeometry.panel(
			self, Vector3(mid.x, end_y, mid.z),
			Vector3(along * 0.4, bar, across + bar * 2.0), PlaygroundGeometry.COLOUR_GATE
		)
	PlaygroundGeometry.panel(
		self, mid, Vector3(0.08, zone.size.y, across), PlaygroundGeometry.COLOUR_GATE_PANE
	)


## +1 for a leg that runs east, -1 for one that runs west.
static func relay_direction(leg: int) -> float:
	return 1.0 if leg % 2 == 0 else -1.0


## Leg [param leg] as the boxes a player lands on, in order: its pad, its decks, and then
## either the gate (legs 0 and 1: a column whose top is level with the last deck, standing
## for the opening, so a jump into it is measured like any other jump) or the finish.
## Walked edge to edge from the leg's start end, so a gap is the number in the constants.
static func relay_leg(leg: int) -> Array[AABB]:
	var lengths: Array[float] = [RELAY_PAD.x]
	var widths: Array[float] = [RELAY_PAD.y]
	var gaps: Array[float] = [0.0]
	var tops: Array[float] = [RELAY_BASE_Y[leg]]

	for i in range(RELAY_GAPS.size()):
		lengths.append(RELAY_DECK.x)
		widths.append(RELAY_DECK.y)
		gaps.append(RELAY_GAPS[i])
		tops.append(tops[tops.size() - 1] + RELAY_RISE)

	if leg == RELAY_Z.size() - 1:
		lengths.append(RELAY_FINISH.x)
		widths.append(RELAY_FINISH.y)
		gaps.append(RELAY_FINISH_GAP)
		tops.append(tops[tops.size() - 1] + RELAY_RISE)
	else:
		lengths.append(RELAY_GATE_DEPTH)
		widths.append(RELAY_DECK.y)
		gaps.append(RELAY_GATE_GAP)
		tops.append(tops[tops.size() - 1])

	var total := 0.0
	for i in range(lengths.size()):
		total += gaps[i] + lengths[i]

	var dir := relay_direction(leg)
	var origin := RELAY_WEST_X if dir > 0.0 else RELAY_WEST_X + total
	var near := 0.0
	var out: Array[AABB] = []

	for i in range(lengths.size()):
		near += gaps[i]
		var x0 := origin + near if dir > 0.0 else origin - near - lengths[i]
		out.append(AABB(
			Vector3(x0, 0.0, RELAY_Z[leg] - widths[i] * 0.5),
			Vector3(lengths[i], tops[i], widths[i])
		))
		near += lengths[i]

	return out


## Bonus 6 as one list, leg after leg: what the drive bot walks. The gate of leg 0 is
## followed by leg 1's pad, which no jump reaches; the gate is what joins them.
static func relay_route() -> Array[AABB]:
	var route: Array[AABB] = []
	for leg in range(RELAY_Z.size()):
		route.append_array(relay_leg(leg))
	return route


## The indexes in [method relay_route] of the two gates.
static func relay_gates() -> Array[int]:
	var out: Array[int] = []
	var at := -1
	for leg in range(RELAY_Z.size() - 1):
		at += relay_leg(leg).size()
		out.append(at)
	return out


## The volume a gate's TELEPORT zone fills: the gate column's footprint, from
## [constant RELAY_GATE_SILL] under its top to [constant RELAY_GATE_HEIGHT] over it.
static func relay_gate_zone(gate: AABB) -> AABB:
	return AABB(
		Vector3(gate.position.x, gate.end.y - RELAY_GATE_SILL, gate.position.z),
		Vector3(gate.size.x, RELAY_GATE_SILL + RELAY_GATE_HEIGHT, gate.size.z)
	)


## Where a player is put on leg [param leg]'s pad: a metre and a half in from its start
## end, over the middle.
static func relay_arrival(leg: int) -> Vector3:
	var pad: AABB = relay_leg(leg)[0]
	var dir := relay_direction(leg)
	var x := pad.position.x + 1.5 if dir > 0.0 else pad.end.x - 1.5
	return Vector3(x, pad.end.y + 1.0, RELAY_Z[leg])


## The yaw facing along leg [param leg] (`atan2(-dx, -dz)`): -90 east, 90 west.
static func relay_yaw(leg: int) -> float:
	return rad_to_deg(atan2(-relay_direction(leg), -0.0))


## Bonus 6's zones, from the same `relay_leg` the columns are built from.
static func _add_relay_zones(zones: DotTimerZoneSet) -> void:
	var track := RELAY_TRACK
	var legs := RELAY_Z.size()

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = relay_arrival(0)
	spawn.destination_yaw = relay_yaw(0)
	zones.add(spawn)

	# The whole first pad: the clock starts on leaving it.
	var pad: AABB = relay_leg(0)[0]
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(pad.position.x, pad.end.y - 0.5, pad.position.z),
		Vector3(pad.end.x, pad.end.y + 5.0, pad.end.z)
	)
	zones.add(start)

	for leg in range(1, legs):
		var before := relay_leg(leg - 1)
		var gate := relay_gate_zone(before[before.size() - 1])

		# The gate: into the opening, onto the next leg's pad, facing along it.
		var teleport := DotTimerZone.make(DotTimerZone.Kind.TELEPORT, track)
		teleport.destination = relay_arrival(leg)
		teleport.destination_yaw = relay_yaw(leg)
		teleport.set_box(gate.position, gate.end)
		zones.add(teleport)

		# A split on the pad the gate lands on, which nothing else reaches: a slab over
		# the pad from under its top to well over the arrival point.
		var arrival: AABB = relay_leg(leg)[0]
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
		stage.number = float(leg)
		stage.set_box(
			Vector3(arrival.position.x, arrival.end.y - 0.5, arrival.position.z),
			Vector3(arrival.end.x, arrival.end.y + 4.0, arrival.end.z)
		)
		zones.add(stage)

	# Deep, for `thin_zones`' reason, like every finish here.
	var last := relay_leg(legs - 1)
	var finish: AABB = last[last.size() - 1]
	var end := DotTimerZone.make(DotTimerZone.Kind.END, track)
	end.set_box(
		Vector3(finish.position.x, finish.end.y - 1.0, finish.position.z),
		Vector3(finish.end.x, finish.end.y + 5.0, finish.end.z)
	)
	zones.add(end)

	# The plate under all three legs, on bonus 6's track only.
	var under := AABB(pad.position, Vector3.ZERO)
	for box in relay_route():
		under = under.merge(box)
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(under.position.x - 4.0, 0.0, under.position.z - 4.0),
		Vector3(under.end.x + 4.0, RELAY_FLOOR_Y, under.end.z + 4.0)
	)
	zones.add(reset)
