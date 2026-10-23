# Testing

The family rules on suites (both counters, read stderr, cap every run, re-import after a new `class_name`) are in the family [testing.md](../../../docs/testing.md); this file is what is specific here.

## The suites

| Suite | What it is |
| --- | --- |
| `headless_playground` | **the point of the repository**: boots the whole game, spawns props and entities, clicks a real spawn menu, fires weapons, changes the map under all of it, and drives the real client's frame hooks; includes the model props (every stock prop spawns with a shape and stays above the floor, a dropped-in model appears and spawns) and the addons hook (against a scratch folder and the real natural-disasters adapter) and the waypoint and NPC spawner tools |
| `headless_net` | a server and a client in one process over a real link: prediction, mirrors, the bag, vehicles, weapons, chat through the real router, and no engine error over the whole run (an `EngineErrors` logger: two minigames' suites printed `!is_inside_tree()` from a toy pulled after a mid-tick rebuild, green) |
| `dedicated` | a real `DotServer`, the module and its console commands; exits clean |
| `headless_presentation` | the presentation layer, settings round trip, effects, the HTTP party |
| `headless_stack` | the player stack (`PlaygroundPlayerStack`: roster, sides, classes, collision layout, spawn director, view switch, character) against a real sandbox |

`./game.sh test` parses everything and runs all five; `./game.sh test headless_net` runs one. By hand: `--import`, the `--check-only` pass, then each `examples/<suite>.tscn` under `timeout`. Every suite counts sections and a CHECKS total; each section's last line is `_section_done()`.

- `headless_playground -- --only=<method>` runs the boot and one section; the totals are not checked. **A section run alone is on whatever map the boot left**: a section that needs a map loads it (most load `pg_flatgrass`) and lands its player first.
- **The suites run without dot-timer**, which is how the game ships. Linked, `headless_playground` and `dedicated` add their `TIMER_SECTIONS` and `TIMER_CHECKS` and run the timer's sections; absent they print a SKIP line ([timer.md](timer.md#testing-it)). Run both ways after touching `addons/pg_timer`.
- `tools/map_props.gd` checks a custom map's props stay put ([maps.md](maps.md#map-props)).
- Every addon's own suite still has to pass; these exercise the joins and do not re-test what the addons cover.

## Arm a new check

Every check here was armed (the guard removed or the old code put back, and the check seen to fail) before it was believed. A check that passes with the mechanism off proves nothing: "the correction rate is low" is lowest of all for a predictor that never runs.

## Traps the suites have hit

- **A suite that leaves objects alive fails.** `game.sh` rejects a log with "resources still in use at exit", "ObjectDB instances were leaked" or leaked RIDs. Name the culprit with `godot --headless --verbose --path . res://examples/headless_playground.tscn -- --only=<section>` (the "Leaked instance" ids match the ids of nodes you print from a frame loop). It found a `Control` built per sidebar caption and added only for some, and `PlaygroundAddons` scanners whose callback lambdas capture their own item, which need `release()`.
- **`headless_net` is order-sensitive, not flaky.** Both halves are plain nodes in one scene tree and share one physics space, so the vehicle test's velocity and the lossy test's distance depend on where every body is. **Add a test at the END of the connected-player sequence**, and treat a vehicle or lossy failure after inserting one as a schedule change until proved otherwise. "Run it again" is the advice that hides a real regression: the second run is the one that gets believed. (A prop's server body and client mirror are in different `World3D`s, so it is not the two copies touching.)
- **A bot keeps the last command it was given.** `DotFpsController.apply_command` stays set, so a bot from an earlier section keeps running and hopping. A test that stops driving a bot still has a bot that is driving.
- **A settle drive's empty command turns the bot to yaw 0.** Aim after settling.
- **A check whose answer depends on how long the player has existed is broken.** Read a yaw or position after ticks have run; a freshly added bot's controller has not started ticking.
- **A GDScript lambda captures locals by value.** Break out of a loop from a signal handler through an `Array`, not a `bool`.
- **Firing a tick at a time with no frame between hands the rig one tick**, which fires once.
- **A jump pressed while still falling from a teleport measures nothing.** Land the player first.
- **Pressing a tool several times in one frame** traces through a just-resized prop (physics sees the resize next step); wait a step.
- **Unthrottled headless frames are not physics ticks**: wait on physics ticks, not frames, for anything that falls.
- **A suite or render tool never writes the player's settings.** `headless_presentation`'s Escape-menu section dragged the volume to 0.15 through the real `user://playground_settings` on every run, so the next real session started nearly silent. `PlaygroundPresentation.use_scratch_settings(<tag>)` points every presentation built after it at an emptied `user://scratch/<tag>/`; `headless_presentation`, `headless_playground` (its real clients) and the four tools that build a presentation call it first, and `headless_presentation` checks the player's files were not touched. That check waits two frames first: the settings manager writes on a debounce and in `_exit_tree`, so a check made in the same frame looks before the write and passes on the bug.
- **`dedicated`'s players are adopted sessions with no socket** (`adopt_session`, peer ids like 8101): anything the section triggers that sends to that peer is an `rpc_id` to a peer the multiplayer API does not know, logged as "Attempt to call RPC with unknown peer ID". Catch it on the bridge link's `loopback` for that call and check it (`_test_saved_builds`), so the line never appears in a green run.
- **Nothing a predicted tick reads may come from a clock.** A wall-clock value in prediction makes a correction count depend on frame pacing, which is a flake that only load shows (the moving deck, [history](history.md#the-suites)).
- **`dedicated` writes under `user://`** (achievements, heat maps): it wipes them first, or the result depends on how many times it has run.
- **The loopback signaller answers inside the call**, so it passes a caller that forgot `await`. Use the HTTP stub ([modes.md](modes.md#hosting-a-sandbox-playgroundparty)).
- **`present_frame` interpolates only while the client's manager is RUNNING** ([vehicles.md](vehicles.md#harness-notes)).
- **Do not measure reach with `DotFpsTunables.new()`**: the addon's defaults are not the server's ([simulation.md](simulation.md#the-movement-is-a-bhop-servers-not-the-addons-defaults)).
- **What no suite sees**: the screen, motion between ticks, sound. Render it ([client.md](client.md#looking-at-it)); four of this game's interface bugs and the remote-body bugs were found by a picture.
