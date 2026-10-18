# The run timer is optional

The playground does not ship dot-timer. A sandbox has no use for a run timer until somebody builds a course, so the game, its suites and its pack run without it, and nothing outside `addons/pg_timer/` names a dot-timer class. A server owner (or a subscriber who delivers it) adds the timer, and `addons/pg_timer` turns it on.

## Turning it on for a server

1. Put dot-timer's addon at `addons/dot_timer` in the project: a link to a checkout (`ln -sfn /path/to/dot-timer/addons/dot_timer addons/dot_timer`) or a copy. `addons/dot_timer` is not in `.gitignore`'s link list, so a link shows as untracked: leave it uncommitted.
2. Run `godot --headless --path . --import` once, so dot-timer's own `class_name` globals are registered (its scripts name each other).
3. Start the server. `game/playground_addons.gd` finds `addons/pg_timer/playground_hook.gd` as it finds every addon hook, and the hook checks for `res://addons/dot_timer/plugin.cfg`. Absent, it logs once on `pg.timer` and does nothing. Present, it builds the timer manager and attaches itself as `Playground.run_timer`. Enabling the editor plugin is not needed.

Nothing else is configured: the tick rate comes from `sv_tickrate` as before ([simulation.md](simulation.md#the-tick-rate-comes-from-servercfg-and-every-link-is-silent)), records go to `pg_records_directory` (empty keeps them in memory), and replays follow `record_replays`. A client gets the same hook through the pack, so a client with the addon times its own predicted run for the HUD.

## What the adapter does

`addons/pg_timer/playground_hook.gd` loads every dot-timer script by path and calls through `Object.call`, because a script naming `DotTimerManager` does not compile in a checkout without the addon, and the parse pass checks every tracked script. The playground calls only the duck-typed surface on `run_timer` (`tick`, `set_tick_rate`, `add_player`, `remove_player`, `on_seated`, `on_unseated`, `on_map_changing`, `on_map_changed`, `tracks`, `track_of`, `start_for`, `retire_legacy_records`, `describe`, and for the client and module `attach_hud`, `on_key`, `checkpoint`, `bind_commands`), and each is a no-op when it is null.

- **Ticks after the move**, from `Playground._simulate_tick`, with the position the move produced.
- **Zones** come from the map: its own `timer_zones()` if it has one, otherwise the `<map>.zones.json` dot-map read beside the scene. Neither built-in map has any; a server's own maps bring theirs.
- **Effects on the tick**: the hook sets each player's `post_move_fn`, which applies the prespeed clamp, speed limits, PUSH and GRAVITY at the state's own position, and taints a run made under an admin's help. RESPAWN, TELEPORT and SLAY zones arrive as `effect_requested` and are applied by the hook.
- **Styles**: `PlaygroundPlayer.style_changed` puts the matching timer style on the player's timer.
- **Vehicles**: getting in stops the run unless the map says the track is driven (`track_is_driven`); getting out of a driven track ends it.
- **Records** file on the authority, keyed by the account (`Playground.record_key`), onto the `fastest`, `top_speed` and `points` boards the hook defines; the verdict is emitted as `Playground.run_filed` and sent to the client as an addon message.
- **Commands** `pg_timer`, `pg_track`, `pg_top`, `pg_cp`, `pg_tp`, `pg_cp_clear`, and the keys T (track) and C V X G (checkpoints). Without the timer the commands are not registered and the keys say "No run timer on this server."
- **The HUD block** is dot-timer's `DotTimerHud`, top left, placed by the hook.

## What did not come back

When the timer moved out (2026-10-18) these were dropped rather than carried into the adapter, to keep it small:

- the zone painting commands (`pg_zone`, `pg_zone_mark`, `pg_zone_spawn`, `pg_zone_list`, `pg_zone_undo`, `pg_zone_save`); a map's zones come from its file or script
- the server-to-client run replication (the `TIMER` event); a client times its own predicted run, and the server's verdict arrives as a notice
- the HUD's personal-best and record comparison
- the timed maps and courses: `pg_lobby` (and its bonus courses and driving circuit), `pg_surf_intro`, `pg_bhop_intro`, `tools/export_zones.gd`, and the route suites that drove them ([history.md](history.md) keeps what they found)

## Testing it

`./game.sh test` runs without the addon, which is the default. With it linked, `headless_playground` adds `_test_the_run_timer` (the hook attached, the manager on the engine's rate, a style, a checkpoint, and a run walked from a START to an END filed back through `run_filed`) and `_test_leaderboards`, and `dedicated` adds the records section and the timer halves of three others. Each suite adds its `TIMER_SECTIONS` and `TIMER_CHECKS` only when `res://addons/dot_timer/plugin.cfg` exists, and prints a SKIP line when it does not.
