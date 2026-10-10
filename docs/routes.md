# The timed routes

Every timed route on the three hand-built maps, the question each one asks, and how the suite proves a route is what its name says. A second route through a map players know is worth more than a fifth map nobody has learned, so each route asks a **different** question.

| Map | Track | Route | The question |
| --- | --- | --- | --- |
| `pg_lobby` | main | the sandbox | none: no timer, on purpose |
| `pg_lobby` | bonus 1 | the jump course | how far can you jump (straight, widening gaps) |
| `pg_lobby` | bonus 2 | the tower | can you face the next platform before jumping at it (a spiral) |
| `pg_lobby` | bonus 3 | the circuit | a driven lap ([vehicles.md](vehicles.md#the-circuit)) |
| `pg_lobby` | bonus 4 | the stepping stones | can you **stop**: shrinking columns a flat-out jump overshoots |
| `pg_lobby` | bonus 5 | the launch | ride what the map does to you: PUSH boosters, no step is a jump |
| `pg_surf_intro` | main | the ramps | (see below: level along their length) |
| `pg_surf_intro` | bonus 1 | the plunge | a 52° face pitched along the route; hold forward |
| `pg_surf_intro` | bonus 2 | the cascade | jumping **down**: a drop makes a jump longer |
| `pg_surf_intro` | bonus 3 | the long bank | hold a height on a face that throws you off its low lip |
| `pg_surf_intro` | bonus 4 | the transfer | switch hands from one face to the facing one, on time |
| `pg_bhop_intro` | main | the blocks | keep your speed |
| `pg_bhop_intro` | bonus 1 | the narrows | hold your line |
| `pg_bhop_intro` | bonus 2 | the switchback | land, face somewhere else, go (every turn is a jump) |
| `pg_bhop_intro` | bonus 3 | the ascent | walk part of it: ramps nobody can jump up |
| `pg_bhop_intro` | bonus 4 | the ladder | how high: every step 97% of `climb_limit()` |
| `pg_bhop_intro` | bonus 5 | the float | re-learn a jump inside a 0.4 GRAVITY zone |
| `pg_bhop_intro` | bonus 6 | the drop | the ladder turned over: 3 m down every jump |

The track constants (`STONES_TRACK`, `LAUNCH_TRACK`, `CASCADE_TRACK`, `BANK_TRACK`, `TRANSFER_TRACK`, `LADDER_TRACK`, `FLOAT_TRACK`, `DROP_TRACK` …) are on the map scripts. When a route is added, the track-count expectations in other sections of `headless_playground` change with it. New routes go where nothing else is: each map's route notes in its script say what space is taken (the lobby's vehicle tests use the empty corner at (-60, -60)).

## Rules every route follows

- **One description**: a route is a list of boxes (or a basis for a face) the geometry, the zones and the suite read, and nothing else ([maps.md](maps.md#geometry-and-zones-come-from-one-description)).
- **Reach is the movement's, asked**: `PlaygroundMap.jump_reach(rise)` and `climb_limit()` (1.035 m), never arithmetic off the addon's default tunables. `_check_route_reach` sweeps every route box to box (edge to edge, not centre minus width) and **prints** the tightest jump whether it passes or not. The old tower check took its reach from a flat jump with default tunables, measured a step as centre distance minus a width, and stopped one platform short; it would have passed a 4.3 m gap nobody can cross (`_the_old_tower_rule_passes_an_unjumpable_gap` keeps that honest).
- **A split must be one nobody can skip.** On a spiral, splits are **height bands**, not lines (a vertical line across a spiral is crossed twice a turn). On the switchback they are slabs across the next leg, not on the turning block (a player with bhop speed cuts the corner). On columns, a split goes where the next-but-one column is out of reach.
- **Columns from the floor rather than floating slabs** where the route is seen from beside: a 1 m slab 5 m up is a speck in a frame, and a row of rising columns reads as the staircase it is.
- **Nothing starts inside anything.** The tower's pillar once ran from the floor through the start pad and the player spawned inside it; a start pad that overlaps the first platform makes the first jump a walk.
- **Every route gets a reset volume under it**, on its own track.
- **A slab tilted onto a face is dropped along its own normal** (from the middle of its top surface), not vertically: the two differ by 1/cos(pitch), 1.6 at 52°, and the vertical drop left a 0.8 m lip over the step height where the plunge met its pad.

## Driving a route: `_drive_route`

`headless_playground::_drive_route` drives any route given as boxes. A bot that holds one yaw can only fall off a course that turns; this one faces the next box. Its rules, each a thing a player does:

- **Wish along the error** (the velocity it wants minus the one it has), not the heading: a wish along the velocity adds nothing in the air past `max_air_wish_speed` and carries the last jump's direction into this one on the ground.
- **Jump on the last grounded tick before the edge, or once the next box is within a metre**, whichever is first. A jump at the lip can put the body into the next box's side.
- **What it stands on is decided by where it is**, so a fall onto a lower turn resumes from there.
- `walks` names boxes whose next step is a ramp: no jump off them; counts grounded ticks on the ramp. Off a box a ramp climbed to, it jumps only once actually over it (the 0.4 m margin calls the crest early).
- It returns `distance` (respawn teleports left out), `top_speed` and a `tally`, and prints its pace through `_print_pace` (`[bot-drive-1]`). `_check_pace` holds a drive to 90% of the route and a pace floor set just under what it measured (`DROP_PACE_FLOOR`, `LAUNCH_PACE_FLOOR`, `BANK_PACE_FLOOR` …).

**"It finished" is never the check on its own.** A climber presses up a face past `max_slope_angle` in the air (air acceleration refills the wish, the clip turns it up the plane), a level bank still carries a running rider to the end, and too-wide stones are still crossed. Each route asserts the thing that makes it what it is: grounded ticks on a ramp, pace on a bank, overshoot on the stones.

## Where a route's ground comes from (`[surf-ramp-1]`)

A distance or descent that is only asserted is one nobody reads once it passes, so drives **print** where the ground was covered: each tick is classified by what the player stood on when it started (`_motion_tally`, `_tally_tick`, `_print_where`). What is asserted is only the stable half: under 1 m of ground and 0.1 m of descent on anything but the route's boxes for the foot courses, at least 95% of the lap on the road for the circuit; surf routes assert more descent ridden on the face than anything else.

**Why: `pg_surf_intro`'s main run does not surf.** Its ramps are level along their length; every metre of descent comes from the stepped floor between them, and the checks over it ("mostly not grounded", "reaches surf speed") are satisfied by a player falling off the start platform. The suite finishes that run by teleporting into the finish, and says so. The plunge, the bank and the transfer are the surf routes.

## Per-route notes

**Jump course and tower (`pg_lobby` bonus 1, 2).** The tower's gaps are 2.04 m of air against a 4.02 m climbing reach: its squares sit 45 degrees apart, so the nearest edges are closer than the centres say. Nobody has to carry speed round a corner; they have to face the next platform. The tower's start pad is smaller than the course's because an 8 m pad reaches the first platform.

**Stepping stones (`pg_lobby` bonus 4).** Ten columns shrinking 2.0 → 1.0 m, each 0.25 m higher, alternating 1 m either side; every gap plus stone is under a flat-out jump's reach (the suite asserts the overshoot for every stone), so each landing means taking speed off in the air.

**The launch (`pg_lobby` bonus 5).** Amber boosters (`COLOUR_BOOST`) with a 1 m PUSH zone at 100 m/s² up: a walk-on leaves at `sqrt(2 (a - g) h)` and peaks `a h / g` = 5 m over the deck (`launch_apex()`); `launch_reach(rise)` is the closed form. The first two steps are 3 m up and the last is level but 6 m out, so no step is a jump and every one is inside the throw. The bot never presses jump.

**The plunge (`pg_surf_intro` bonus 1).** One face pitched 52° (past 46°) descending along the route, same start height as the main run so the two times compare. Straight on purpose: the bot holds forward and nothing else. A route that needs speed *carried* round a turn (a surf bank) is still not drivable by a scripted bot; one that only needs *facing* somewhere new is.

**The cascade (`pg_surf_intro` bonus 2).** Ten blocks each 1.25 m under the last, alternating either side, so every jump is a diagonal. `jump_reach(-1.25)` is 5.80 m against 4.75 flat: a player who learned the climbing courses overshoots. The three start pads' backstops are one list, `PgSurfIntro.backstops()`.

**The long bank (`pg_surf_intro` bonus 3).** One 20 × 140 m face rolled 56° and pitched 7° down its length (`bank_basis()`: roll first, then pitch), a finish pad 2 m past and 4 m under its far end. `_ride_the_bank` holds right (into the bank) below the pad's line and lets go above it, and **never touches forward**. Pace floor 2 × `MOVE_SPEED`: a surf route slower than running is not one. The roll tips the slab's high end face to a standable 34°, which the survey declares.

**The transfer (`pg_surf_intro` bonus 4).** Two 56° faces facing each other across a 2 m gap, the second starting a third of the way down the first with its low lip 4 m under: hold right, let go and push left off the low lip, hold left. Pitched 10 and 12 because at 7 and 9 the ride was slower than the floor. **Built across the low lip, not two faces in line, because of a motor behaviour**: a rider leaving a pitched, rolled face over its far END is stopped dead at that edge (velocity to zero, mid-air) and slides off from rest. Leaving over the low lip keeps the speed (the clip is along the lip). The long bank's rider has always done this and its finish pad hides it. Filed for dot-player-controller, not worked round from here; the transfer's finish begins `TRANSFER_FINISH_LINE` (4 m) before the second face's far edge for the same reason.

**The switchback (`pg_bhop_intro` bonus 2).** 3 m square floating blocks in three legs climbing 0.5 m a jump with a turning block between legs; square so a turning block is the same target from either side. The legs are 2.4-2.9 m apart but beside anything but a turn the next leg is over the jump apex higher.

**The ascent (`pg_bhop_intro` bonus 3).** Four ramps each rising 2 m (against a 1.15 m apex), pitched 16-40° against `max_slope_angle` 46: no way up but to walk. `ascent_route()`, `ascent_walks()`, `ascent_ramps()`. Needs the controller's grounding on walkable slopes (`[slope-1]`).

**The ladder (`pg_bhop_intro` bonus 4).** Ten columns each `LADDER_RISE` (1.0 m) above the last, 97% of `climb_limit()`. Gaps 1.8 → 2.5 m; the lower bound is arithmetic too: a 1.0 m climbing jump is under the next top for its first 1.52 m, so a shorter gap is met face-first on the way up. A 1.10 m rise (past the limit, still under the apex) is unclimbable by the bot, which is `CLIMB_MARGIN` measured.

**The float (`pg_bhop_intro` bonus 5).** Columns `FLOAT_STEP` (2.0 m) up every other jump with gaps 6.0 → 8.0 m, all inside one GRAVITY zone at `FLOAT_GRAVITY` (0.4): not one jump can be made at normal gravity. `float_apex()`, `float_reach(rise)`. The survey does not model a zone's gravity, so the columns are declared. Not yet measured over the wire (the launch's push is); the same at-the-state's-position rule means it should cost no corrections, which is a claim until a section says so.

**The drop (`pg_bhop_intro` bonus 6).** Columns `DROP_STEP` (3.0 m) lower each jump, gaps 5.0 → 5.8 m (wider than a level jump, inside `jump_reach(-3.0)`). The survey models a falling jump, so nothing is declared.

**The main bhop run.** Past block 8 its gaps outgrow a running jump and are crossed with carried bhop speed, which the survey declares.
