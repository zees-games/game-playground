# The simulation and its joins

This game is the only place dot-player-controller, dot-map, dot-props, dot-npc and dot-leaderboard run together (and dot-timer, when a server links it: [timer.md](timer.md)), and every bug that cost days here was in a seam between them: a bridge reconciling on top of another bridge, a message keyed on the wrong id, a value computed and consumed by nothing. This file is those seams.

## The game owns the tick loop

`DotFpsController.Drive.EXTERNAL`, not `LOCAL`, even in single player. In `LOCAL` the controller accumulates frame time and ticks itself, so a run timer would be fed from a signal fired inside somebody else's loop, and a bot could not be driven at all. `Playground._simulate_tick` owns it, which makes the order explicit:

1. `props.advance`, `maps.advance`, then the vehicles are driven and ticked
2. the NPC candidate list is rebuilt once, then the NPC world and every entity tick (see [sandbox.md](sandbox.md#perception-is-dot-npcs-being-a-prop-is-still-dot-props))
3. every player: sample (if local), then `controller.simulate_tick` (`PlaygroundPlayer.simulate`)
4. pickup, projectiles, debris, doors, liquids, pane impacts
5. `Playground._carry_riders` copies each rider's seat position into `controller.state.position` (a run timer, the NPC list, the HUD and `PlaygroundPlayerNet` all read it, and nothing else writes it while seated)
6. the run timer, if a server has one (`Playground.run_timer.tick`), with the position the move **just produced**

**A run timer must come after the move.** The timer works out whether the player crossed a line during this tick from where they were and where they now are; ticking it first shifts every run by exactly one tick, and by a different amount at each tick rate, which is the tick-rate dependence dot-timer's sub-tick fractions exist to remove. It is also the shape a dot-net bridge and a dedicated server use.

**Entities tick before players**, at the fixed rate. Not `_process`, which makes an NPC's speed a function of the frame rate; not after the players, which leaves a chaser visibly a tick behind its target.

## `body_ref` must not be `of_self()`

`DotNodeRef.of_self()` on the controller resolves to the controller, a plain `Node`. `setup()` refuses ("the player body must be a Node3D"), `motor` stays null, and the player never moves. Leave it unset: it defaults to the parent. Its first appearance cost nine failures that all pointed somewhere else.

## A style is movement, and a timer's ranking half follows it

`DotFpsStyle` transforms the tunables and filters the command. `PlaygroundPlayer.set_style` applies it and emits `style_changed`, which is how `addons/pg_timer` puts the matching `DotTimerStyle` (whether a run counts and what it is worth) on the player's timer when a server has one ([timer.md](timer.md)). `DotFpsController.set_style` **rebuilds the motor**, which assigning the property does not; the suite checks that specifically.

A style rebuilds the tunables from the controller's base copy, so anything written into the live tunables (a collision mask) is lost on the next style change. Go through the controller's setters (`set_collision_mask`).

## After the move: `post_move_fn`

`PlaygroundPlayer._on_simulated` calls `post_move_fn` (unset by default) on every simulated tick, a prediction replay's included, after the move and before toys and riding. It is the one place an addon can change where the player ends up on the same tick on every end; `addons/pg_timer` uses it for the timer's zone effects (prespeed clamp, speed limit, PUSH, GRAVITY), read at the state's own position. A signal would put it a tick late.

## Teleport and the spawn yaw

`PlaygroundPlayer.teleport` goes through `DotFpsController.teleport` (drops the smoothing and puts the player in the air), tells `PlaygroundPlayer.sampler` the new angles, and leaves a player that nothing samples **holding still and facing where it was put**. A `DotFpsCommand` carries **absolute** view angles, so writing `controller.state.yaw` directly lasts until the next tick: the client's sampler, or a bot's last command, turns it straight back. A bot holding forward when it fell off a course was otherwise respawned already running off the pad.

Facing a direction is `atan2(-dx, -dz)`: `DotFpsMotor._view_basis` builds forward as `(-sin(yaw), 0, -cos(yaw))`. The obvious `atan2(dx, dz)` is 180 degrees out and mirrored.

**A teleport stops a run, if there is one** (`PlaygroundPlayer.stop_run`, a no-op without a timer). A teleport that kept the clock running is the simplest cheat on a timed map; only a map's own TELEPORT zone keeps it, and that is the adapter's.

**A respawn here is a teleport of the same body** (`Playground.spawn_player`), so nothing a handler set is lost and `DotModTools.respawned` is never called: blind, beacon, noclip and freeze all survive a respawn (game-arena ends the last two with the body).

`Playground.spawn_player` steps a spawn to the nearest free point on two rings of eight at `SPAWN_SPACING` (1.5 m) (`_clear_of_players`), which stays on the smallest start pad; past seventeen people the centre is shared. Every start here is one point, and without this two players joining stood inside each other's heads.

## A map change happens with everything in flight

`_on_map_changing` runs before anything is torn down: it tells the run timer (which stops every run), makes every tool let go, and clears the props, all of which stand on geometry about to be freed. dot-map then loads the new scene before freeing the old, so a failure leaves the server on a working map. The module also clears dot-moderation's `return` history on every map change (`[modtools-return-1]`): every entry is a point on the map just freed.

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
  -> (with dot-timer linked) the run timer's manager -> every record it files
```

A timer counting 128 a second on a server stepping 100 reports every run 28% long, and nothing about the run looks unusual. `dedicated`'s `_test_tickrate_reaches_the_timer` walks the chain with the server at 100 precisely because the project default is 128 (the timer's links only when dot-timer is linked). `sv_tickrate` goes in **`server.cfg`, not `autoexec.cfg`**: it is startup-only, and dot-server execs the first before the listener and the second after. There is deliberately **no `pg_tickrate` cvar**: a second cvar for the same number can disagree with the first.

## The server module

`game/playground_module.gd` is the only file that names dot-server. It extends `DotModule`, **not `DotGameModule`, deliberately for now**: `DotGameModule`'s `game`, `bridge`, `net` and `services` are untyped fields a subclass cannot redeclare and this module reads them typed throughout; its `_build_extras` builds services, the arena, the waves, the mod tools, the vote and progress in an order each depends on; and it keeps its own `_joined` table and spawn path rather than a `DotGameRoster`. That is a conversion of its own. Consequences: the module wires things `DotGameModule` would do itself (identity and dot-platform, hibernation; see [services.md](services.md)).

| Commands | |
| --- | --- |
| `pg_restart` `pg_style` | back to the spawn; the movement style |
| `pg_timer` `pg_track` `pg_top` `pg_cp` `pg_tp` `pg_cp_clear` | the run and practice checkpoints: `addons/pg_timer`'s, only when a server links dot-timer ([timer.md](timer.md)) |
| `pg_map` `pg_nextmap` `pg_rtv` `pg_extend` | maps (with `pg_vote`, renameable from maps.yml's `commands: names:`, see `bind_map_commands`; a name must be lowercase letters, digits and underscores, so `!`-forms are dropped by dot-core) |
| `pg_prop` `pg_undo` `pg_props_clear` `pg_limits` | props |
| `pg_save` `pg_load` `pg_builds` `pg_build_delete` | saved builds |
| `pg_status` | everything at once |
| `pg_services` `pg_gag` `pg_mute` | chat, voice and moderation |
| `pg_arena` `pg_waves` `pg_shop` `pg_spec` | the modes, all off by default ([modes.md](modes.md)) |
| `pg_creative` `pg_pickup*` `pg_destruction` `pg_breakable_glass` `pg_prop_surf` `pg_limit_roles` | sandbox switches ([sandbox.md](sandbox.md)) |
| `pg_vote` `pg_achievements` | what plays next, what somebody has earned |
| `pg_give` `pg_inv` | put something in somebody's bag, and read it |

