# The simulation and its joins

This game is the only place dot-player-controller, dot-timer, dot-map, dot-props, dot-npc and dot-leaderboard run together, and every bug that cost days here was in a seam between them: a bridge reconciling on top of another bridge, a message keyed on the wrong id, a value computed and consumed by nothing. This file is those seams.

## The game owns the tick loop

`DotFpsController.Drive.EXTERNAL`, not `LOCAL`, even in single player. In `LOCAL` the controller accumulates frame time and ticks itself, so the timer would be fed from a signal fired inside somebody else's loop, and a bot could not be driven at all. `Playground._simulate_tick` owns it, which makes the order explicit:

1. `props.advance`, `maps.advance`, then the vehicles are driven and ticked
2. the NPC candidate list is rebuilt once, then the NPC world and every entity tick (see [sandbox.md](sandbox.md#perception-is-dot-npcs-being-a-prop-is-still-dot-props))
3. every player: sample (if local), then `controller.simulate_tick` (`PlaygroundPlayer.simulate`)
4. pickup, projectiles, debris, doors, liquids, pane impacts
5. `Playground._carry_riders` copies each rider's seat position into `controller.state.position` (the timer, the NPC list, the HUD and `PlaygroundPlayerNet` all read it, and nothing else writes it while seated)
6. every player: `timers.tick_player` with the position the move **just produced**

**The timer must come after the move.** The timer works out whether the player crossed a line during this tick from where they were and where they now are; ticking it first shifts every run by exactly one tick, and by a different amount at each tick rate, which is the tick-rate dependence dot-timer's sub-tick fractions exist to remove. It is also the shape a dot-net bridge and a dedicated server use.

**Entities tick before players**, at the fixed rate. Not `_process`, which makes an NPC's speed a function of the frame rate; not after the players, which leaves a chaser visibly a tick behind its target.

## `body_ref` must not be `of_self()`

`DotNodeRef.of_self()` on the controller resolves to the controller, a plain `Node`. `setup()` refuses ("the player body must be a Node3D"), `motor` stays null, and the player never moves. Leave it unset: it defaults to the parent. Its first appearance cost nine failures that all pointed somewhere else.

## A style has two halves and they move together

`DotFpsStyle` transforms the tunables and filters the command; `DotTimerStyle` says whether the run counts and what it is worth. `PlaygroundPlayer.set_style` applies both. One alone gives a run timed as "normal" while the player is sideways, and nothing errors. `DotFpsController.set_style` **rebuilds the motor**, which assigning the property does not; the suite checks that specifically.

A style rebuilds the tunables from the controller's base copy, so anything written into the live tunables (a collision mask) is lost on the next style change. Go through the controller's setters (`set_collision_mask`).

## The timer decides and the game acts

`DotTimer` never moves a player. `Playground._on_effect_requested` turns a `RESPAWN`, `TELEPORT` or `SLAY` zone into something that happens, because what those mean differs between a first-person game, a 2D game and a replay being scrubbed.

Effects that change **where the player ends up** are read straight off the timer inside `PlaygroundPlayer._on_simulated`, on the tick, not from a signal (a signal puts it a tick late):

- **Prespeed clamp and speed limits.** Ask `timer.in_zone(...)` for membership. `is_inside(Kind.START)` answers only for effect zones and is always false for START; using it once made the prespeed clamp dead.
- **PUSH** (the launch's boosters): the zone's acceleration times the step, every tick in it. Upward on the ground is a launch without touching the motor, because `DotFpsMotor._categorise_ground` puts a player moving out of the floor in AIR.
- **GRAVITY** (the float): in the air only, gives back `gravity * (1 - number)` of the vertical speed the motor took this tick. On the ground gravity is what holds a player to the floor.
- **Read at the state's own position** (`PlaygroundPlayer.effect_zone_at`), not `timer.effect(...)` (`[playground-push-1]`). The timer's effect is where it last sampled the player, and a predicting client replays ticks with its timer at the newest one, so a replay across a booster's edge pushed ticks that had been outside it: one correction per launch.
- **Effect zones are not track-filtered.** dot-timer's `_rebuild_effects` takes every EFFECT zone the player is in whatever their track, so a sandbox player on the main track who walks onto a booster or into the float is thrown or floats too. Whether effects should follow the track is a dot-timer question and Christian's call. RESPAWN/TELEPORT/SLAY are track-filtered, which is what makes a reset volume under a bonus course usable beside people building on the main track.

## Statistics land when the run ends

The natural moment to fold a run's statistics in is the moment it finishes, when it is no longer active. `DotTimerManager.note_stats` once guarded on "only while active" and discarded exactly that call (fixed in dot-timer).

## Getting into a vehicle and the timer

`Playground._on_seated` stops the run unless `PlaygroundMap.track_is_driven(track)` says the track is driven (default false, so foot courses are unchanged: a jump course driven in a buggy is not comparable). On a driven track, **getting out** ends the run, because the rest of the lap on foot is not the same lap. The map answers because the map is the only thing that knows.

## Teleport and the spawn yaw

`PlaygroundPlayer.teleport` goes through `DotFpsController.teleport` (drops the smoothing and puts the player in the air), tells `PlaygroundPlayer.sampler` the new angles, and leaves a player that nothing samples **holding still and facing where it was put**. A `DotFpsCommand` carries **absolute** view angles, so writing `controller.state.yaw` directly lasts until the next tick: the client's sampler, or a bot's last command, turns it straight back. A bot holding forward when it fell off a course was otherwise respawned already running off the pad.

Facing a direction is `atan2(-dx, -dz)`: `DotFpsMotor._view_basis` builds forward as `(-sin(yaw), 0, -cos(yaw))`. The obvious `atan2(dx, dz)` is 180 degrees out and mirrored.

**A teleport stops the run, except a map's own TELEPORT zone.** A teleport that kept the clock running is the simplest cheat on a timed map, so `PlaygroundPlayer.teleport` stops it; `Playground._on_effect_requested` passes `keep_run` for a TELEPORT zone, which the timer only asks for on the player's own track and already expects (`DotTimer.MOVING_KINDS`). That is what lets `pg_lobby`'s relay gates be part of a route.

**A respawn here is a teleport of the same body** (`Playground.spawn_player`), so nothing a handler set is lost and `DotModTools.respawned` is never called: blind, beacon, noclip and freeze all survive a respawn (game-arena ends the last two with the body).

`Playground.spawn_player` steps a spawn to the nearest free point on two rings of eight at `SPAWN_SPACING` (1.5 m) (`_clear_of_players`), which stays on the smallest start pad; past seventeen people the centre is shared. Every start here is one point, and without this two players joining stood inside each other's heads.

## Tracks on a map are derived

`Playground.tracks_on_this_map()` is derived from the zones, not declared: the zone file is what a delivered map ships, so a declaration would be the half missing exactly when it matters. `MAIN` is always in the result, because a sandbox is a legitimate track.

## A map change happens with everything in flight

`_on_map_changing` runs before anything is torn down: it stops every run, makes every tool let go, and clears the props, all of which stand on geometry about to be freed. dot-map then loads the new scene before freeing the old, so a failure leaves the server on a working map. The module also clears dot-moderation's `return` history on every map change (`[modtools-return-1]`): every entry is a point on the map just freed.

A generated or document map needs configuring before anybody spawns: `_on_map_changed` calls `configure()` / `configure_doc()` first, then map props, then spawns.

## The randomness manager is built before the playground

`Playground._ready` loads its first map inside `add_child`, and a generated map asks the registry for a seed source at that moment. A manager registered afterwards is one the map did not use, and nothing errors, because a fixed-seed fallback is a legitimate configuration.

## The movement is a bhop server's, not the addon's defaults

`PlaygroundPlayer._tunables` (the static builder behind `movement_tunables()`) differs from `DotFpsTunables` in the genre's direction:

| | Default | Here | Why |
| --- | --- | --- | --- |
| `auto_hop` | off | **on** | otherwise the skill is a keyboard-hardware contest, not an aiming one |
| `bhop_speed_cap_scale` | 0 | 0 | kept explicitly; a cap is what shooters added to stop bunny-hopping |
| `crease_slide` | on | on | kept explicitly: a surf map is made of seams |
| `coyote_time` | 0.1 | **0** | free speed on a timed map; a run set with it is not comparable |
| `jump_buffer_time` | 0.1 | **0** | the same |

`PlaygroundMap.jump_reach(rise)` and `climb_limit()` ask the same tunables (`DotFpsTunables.jump_reach` / `climb_limit`, apex × `CLIMB_MARGIN` 0.9 = 1.035 m) so maps with no player in the tree ask the movement itself. `MOVE_SPEED`, `JUMP_HEIGHT` and `MOVE_GRAVITY` stay on `PlaygroundMap` for laying out geometry and are asserted against the tunables the server applies. Never measure a reach off `DotFpsTunables.new()`: the addon's defaults are not this server's.

## The tick rate comes from `server.cfg`, and every link is silent

```
server.cfg: sv_tickrate 100 -> dot-server _apply_tickrate() -> Engine.physics_ticks_per_second
  -> Playground._resolve_tick_rate() -> Playground.tick_rate
  -> DotTimerConfig.tick_rate = 0 ("ask the engine") -> DotTimerManager.tick_rate -> DotTimerRecord.tick_rate
```

A timer counting 128 a second on a server stepping 100 reports every run 28% long, and nothing about the run looks unusual. `dedicated`'s `_test_tickrate_reaches_the_timer` walks the chain with the server at 100 precisely because the project default is 128. `sv_tickrate` goes in **`server.cfg`, not `autoexec.cfg`**: it is startup-only, and dot-server execs the first before the listener and the second after. There is deliberately **no `pg_tickrate` cvar**: a second cvar for the same number can disagree with the first.

## The server module

`game/playground_module.gd` is the only file that names dot-server. It extends `DotModule`, **not `DotGameModule`, deliberately for now**: `DotGameModule`'s `game`, `bridge`, `net` and `services` are untyped fields a subclass cannot redeclare and this module reads them typed throughout; its `_build_extras` builds services, the arena, the waves, the mod tools, the vote and progress in an order each depends on; and it keeps its own `_joined` table and spawn path rather than a `DotGameRoster`. That is a conversion of its own. Consequences: the module wires things `DotGameModule` would do itself (identity and dot-platform, hibernation; see [services.md](services.md)).

| Commands | |
| --- | --- |
| `pg_timer` `pg_restart` `pg_style` `pg_track` `pg_top` | the run |
| `pg_cp` `pg_tp` `pg_cp_clear` | practice mode |
| `pg_zone` `pg_zone_mark` `pg_zone_spawn` `pg_zone_list` `pg_zone_undo` `pg_zone_save` | drawing zones |
| `pg_map` `pg_nextmap` `pg_rtv` `pg_extend` | maps |
| `pg_prop` `pg_undo` `pg_props_clear` `pg_limits` | props |
| `pg_save` `pg_load` `pg_builds` `pg_build_delete` | saved builds |
| `pg_status` | everything at once |
| `pg_services` `pg_gag` `pg_mute` | chat, voice and moderation |
| `pg_arena` `pg_waves` `pg_shop` `pg_spec` | the modes, all off by default ([modes.md](modes.md)) |
| `pg_creative` `pg_pickup*` `pg_destruction` `pg_breakable_glass` `pg_prop_surf` `pg_limit_roles` | sandbox switches ([sandbox.md](sandbox.md)) |
| `pg_vote` `pg_achievements` | what plays next, what somebody has earned |
| `pg_give` `pg_inv` | put something in somebody's bag, and read it |

- **The zone commands are `CHANGEMAP`, not `GENERIC`.** Drawing a start line edits the map's rules and can invalidate every record on it.
- **One painter per admin.** Two admins drawing at once would otherwise share a first corner and save a zone spanning the distance between them.
- **A zone is live the moment it is drawn** (`set_zones` after the second mark). An admin who had to reload to test a start line would test it once.
- **Saving a set with a problem is refused, not warned about.** A zone file with a start and no end is playable and unfinishable, and once on disk somebody else has a copy.
