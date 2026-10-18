# History: bugs worth recognising again

Every one of these parsed cleanly and most produced no error. Each is kept because the shape could come back; where the lesson is still a rule, the rule is also in [CLAUDE.md](../CLAUDE.md) or a topic file. The family-wide list is [bugs-found.md](../../../docs/bugs-found.md).

The maps named below (`pg_lobby`, `pg_surf_intro`, `pg_bhop_intro`) and their timed routes were removed with the run timer on 2026-10-18 ([timer.md](timer.md)); what they found stays here.

## Found here, in other repositories

One line each; the detail is in [bugs-found.md](../../../docs/bugs-found.md) or the addon's own docs.

- **dot-timer: `DotTimer.effect_requested` was emitted by nothing**, so RESPAWN, SLAY and TELEPORT zones did nothing anywhere and a player who fell off a surf map fell for ever. A value consumed by two games and produced by nobody. It also quietly invalidated a passing timer-game check that had counted a bot falling through the void as "surfing".
- **dot-timer: `note_stats` guarded on "only while the run is active"** and discarded the one call that matters, at the finish.
- **dot-props: `DotPropDef.mass` was never put on the body.** Visible only here, where every prop is the same scene.
- **dot-ui: `set_anchors_preset` does not set offsets**, in `DotScreenStack`, `DotCrosshair`, `DotHud` and `DotTableView`. The spawn menu, the first screen on a stack whose parent is a plain `Node`, came out 0 × 0.
- **The prespeed clamp was dead in this game and the timer game alike**: `is_inside(START)` answers only for effect zones. Use `in_zone`.
- **dot-npc-ai: `has_reacted()` was false for ever**, measured from `engaged_at`, which dot-npc refreshes on every pass the target is perceived. A bot that never acts on what it sees looks bad rather than broken. `DotNpcInstance.target_since` was added for it.
- **dot-npc-ai's brain wiped a squad the game had chosen** with the definition's empty `squad` on bind.
- **dot-inventory, four at once** (fixed there; see its docs, "What a real wire found"): the server's own changes spent the player's rate budget; `validate` passed an ADD into a full bag and `_do_add` then logged ERROR; `rollback` undid every later prediction and nothing applied a server op to a predicting manager; a MOVE re-allocated the entry's uid, so a chained op named whatever the server had since allocated that number to.
- **dot-net: the interpolation delay was in the wrong unit** (snapshots subtracted from ticks), so every remote entity in the family was extrapolated. Found by `tools/screenshot_net.sh`'s per-frame probe.
- **dot-player-char: a visual's rig stood at the world origin** (a `Node3D` under a plain `Node`). Unseen because the lobby's spawn is the origin.
- **dot-player-controller: no player had ever collided with a prop.** The body copied the mask once at build, before the game set it. Fixed in the controller, which changed five other games.
- **dot-player-controller: a starved tick handed a player with nothing held a fresh command facing north.** Fixed (`_repeat_command` in both branches).
- **dot-vehicle: the heading snapped at the snapshot rate**, because the rotation went as four INTs and dot-net does not blend ints. Now a QUATERNION.
- **Scripts naming their own `class_name` leaked the whole script graph at exit** across twenty-odd addons ([gdscript-hazards.md](../../../docs/gdscript-hazards.md)). The message scripts' self-preloads were removed here first and were not the cause here; the leak count grew by one script's worth whenever a script was added, which said to find what held the graph.

## The client

**A black screen with no error.** The client awaited `ready_for_players`, which had already fired inside `add_child` because a built-in map loads without suspending. A signal is not a state.

**Two of three tabs unreachable** (`TabBar.clip_tabs` defaults on) and **every NPC icon a coloured bar** (the torso covered the head). Both found by a screenshot; every property was correct.

**The client was silent while every sound check passed.** Every presentation hook was called by the presentation suite and by nothing in the game; `camera_shake()` was computed and never applied. Then: **neither effect scene existed** (dot-fx refuses a missing scene at DEBUG) and `tool_beam` was declared and never spawned.

**Escape was a toggle**, which on the web silently does nothing every other press, and a released pointer had no way back but the pause menu's Resume, because a click fired the gun.

**A networked client drew nobody else**, for two independent reasons: remote bodies were hidden by the local player's view rule, and a body forced visible stood at the origin. Invisible to every suite, because each reads the simulation.

**The sliders were lone dots**: this theme draws no slider track.

**Edit mode's outline was a translucent fill**, which showed a red crate as pink in the one mode whose sliders include colour.

**A first-person view that was built and never ran** (found 2026-10-11, looking at dot-player-controller's new landing dip in this game). `_build_view` added a `DotFpsView` after the controller had looked for one, so `controller.view` was null: no landing dip, no strafe lean, no widening, no step smoothing, and the zee recoil handed to `view.external_angles` went nowhere, for as long as the client had existed. Every check passed, because the client writes the camera itself and nothing asked what the view did. The `field_of_view` setting was applied by nothing either. Camera motion is now `DotFpsViewMotion` in `PlaygroundPlayer.present_camera`, the one place the camera is written; `headless_playground` drops, hops, strafes and flies a player through it.

## Netcode

### A connected client predicted nobody

`_apply_join` built every mirrored player with owner 0, the local one too, so `predicted()` was empty, `client_tick` simulated nobody, and the player moved only when a snapshot came back (3-5 ticks from key to motion on a 1 ms loopback; a real link adds its round trip). The local player was **interpolated like a remote one**, so the eye was smooth, just late, and nobody saw it. "The client moves under its own prediction", "the server agrees" and "the correction rate is low" all held for the wrong reason; the last read zero because the predictor never ran. The same line was in two other games ([bugs-found.md](../../../docs/bugs-found.md)). In this game's handshake JOIN used to arrive before HELLO, so the claim on HELLO was the path that made the player predicted, not a belt-and-braces extra.

**Every client was playing offline.** `PlaygroundClient` became networked only through its `link` export, which the shell sets only on a built-in client scene; a delivered pack's scene is instantiated with nothing set. The server had both players and nobody had the server. Found only by running the real shell twice against a local server; every suite builds the bridge by hand. **And then both players stood inside each other** on the one-point spawn.

**Every join logged "Failed to get path from RPC"** once: JOIN was broadcast to every socket at `client_spawn`, before the joiner had built `Server/Playground`. Reviewing the ready set then found that **nobody had ever been welcomed** (`_welcome` ran at spawn and returned unless READY, which it never is there), **a disconnected peer was never removed from dot-net** (`remove_peer` was gated on the ready set the disconnect had just cleared), and **voice went round the gate** (one error per frame while somebody joined).

**A prop mirror was world geometry** (the scene's 1/1 layer) to a client predicting against it. **A mirror fell under the client's own physics** until its first draw, which passed "it falls because the server's physics moved it" at exactly the server's height.

**Every connected player had collision mask 1**: the mask was written into the live tunables, and a client sets the style straight after joining, which rebuilds them. A client on a still deck was corrected every snapshot. **A mirror has no velocity**, so prop surfing found nothing to carry the rider on a client.

**The client's weapon was never asked for**: the client armed itself and told the server nothing, so on a `pg_shop` server every weapon was free and nobody saw what anybody held; the server's WEAPON broadcast was read by a bare `pass`. **An encoder and a decoder that have never met** is the family's detector for it. A client that arms itself looks exactly like one that was given the weapon.

**The bag was built by nothing but the presentation suite** (no `Playground` had an inventory, and the shop charged per spawn), and **a spawn the prop budget refused had already been charged for.**

**The push mispredicted at every booster edge** because it read the timer's last sample instead of the state's position: one correction per launch.

**A zee gun hung at the capsule's centre**: the held-weapon mount named the torso. `--zee=rifle` showed two pixels of barrel.

**Without `PlaygroundPlayer.component()`** every zee shot left the feet pointing north and hit nothing.

## The world

**Players walked through every prop** (see the controller line above); a rider fell through the platform they stood on.

**A barrel's blast reached the barrel**, still in the spawner while it exploded, and recursed until the stack ran out.

**A grenade fuse flown as given went off in half the time**: the pack counts at 64 Hz and this server runs 128. `PlaygroundProjectiles.accept` rescaled fuses by hand, and nothing else in the pack was: every zee weapon fired, reloaded and deployed twice as fast here. Fixed 2026-10-11 at the source: dot-weapon scales a row by its `authored_tick_rate` (the pack sets 64), spawns arrive in this server's ticks, and the hand rescale is gone, because keeping it would halve every fuse again. The zee section of `headless_playground` counts a second of SMG fire against 64 Hz.

**A player's soldiers and rebels were one squad**, so each side's fire-lane check found its own target in the lane and nobody fired. A probe printing every gate found it. **The turret counted as an NPC** because entities were grouped by script name. **A cost budget left over from an earlier section** refused a turret with a message about NPCs: the confusion per-kind limits remove.

**Two unknown players were zero metres apart** (one sentinel position), so a rescuer who did not exist revived a casualty who did not exist. **One player had two entity ids** depending on which modes were on: a fallback hash, with a comment above it describing exactly that cost.

**A `DotDamage` with no tick is refused by spawn protection for ever**: every shot did nothing, found by the arena's very first hit.

**A wheel above the chassis box**: a car at full throttle that did not move, every tunable correct. **A car placed with a negated `looking_at`** reversed 12 m into the finish and reported a 0.36 s lap with no splits, a plausible pass if the only assertion is "it finished". **A passenger was drawn on every other machine where they got in**, because the seat moved the node and nothing wrote the movement state.

**The tower's pillar ran through the start pad** and the player spawned inside it; every count passed, a bot that had not moved found it. **The tower check would have passed an unjumpable gap.** **Every derived spawn yaw lasted no ticks**: the next command's absolute angles turned the player back; the one check read before a tick ran.

**`pg_surf_intro`'s main run does not surf**: instrumented, 10.7 m of a 220 m route on the ramps, no splits crossed, and both surf checks satisfied by falling off the start platform.

**The drive bot jumped from the top of every ramp into the gap**: near a crest its margin called it on the crest while still on the ramp.

**A rider leaving a pitched, rolled face over its far end is stopped dead** and slides off from rest; the long bank's finish pad had always caught it. Filed for dot-player-controller.

**An airborne player pressing into a face past `max_slope_angle` creeps up it** (about 1 m/s vertical: air acceleration refills the wish, the clip turns it up the plane). Whether that is the genre or a bug is dot-player-controller's call (`[steep-climb-1]`); it is why "it finished" is never the check alone.

**The maps had no scale**: flat colour made a 3 m block beside a 220 m ramp two tiles. Fixed with the world-space grid.

**A crate fifty times lighter than water shot a metre out of the basin, then bounced on lava for ever**: buoyancy scaled by depth and under-damped. **A crate dropped on the lava pit's bridge did not melt**, and a melt timer reset by each bounce let a floating crate ride the lake.

## Services

**The vote ran at double speed** (`self_advance` on and the module advancing it), **beside a second clock** (the map session's, which changed the map after an extend) **under a second rock-the-vote** (`pg_rtv` went to the session's time limit while the wire's `rtv` went to the ballot). Every number agreed with every other, which is why nothing noticed.

**The HUD's time left was the map session's clock**, which on a client nothing extends, and the deployed rtv-only server had every client counting down thirty minutes the server did not have. **`pg_status` said the same.** **The deployed sandbox was put to a ballot at twenty-eight minutes** because `pg_map_seconds: 0` stopped the map clock and not the vote's.

**The server browser shipped against a server that answered nothing**: `dedicated` had `query_enabled = false`, no query host was attached and the module contributed no provider. dot-browser's own suite queries a server it built.

**Nobody in the sandbox had an avatar**: `PlaygroundPlatform` was built only by `examples/dedicated.tscn`, and a module that is not a `DotGameModule` loads no dot-platform by itself.

## The suites

**`dedicated` carried state between runs for weeks**: achievement progress under `user://` grew each run until "fifty unlocks the first tier and not the second" crossed 500 and failed on an unchanged tree.

**`headless_net` order-sensitivity, measured**: one new test that spawns no body and only advances the world, moved through the sequence, five runs each. Not there: 4/5 clean. Before the vehicle test: 0/3. Between the vehicle and the timer: 3/5. After everything that reads physics: 5/5. Hence: add new tests at the end.

**`headless_net`'s moving deck failed once at 14 corrections against 12, and it was not load sharing a physics space.** `PlaygroundPropNet` measured a mirror's velocity as its drawn position over `Time.get_ticks_usec()` between draws, and `_ride_prop` feeds that into the client's PREDICTED tick, so the same ticks predicted differently depending on how far apart in wall time two snapshots were handled. Fifteen runs idle gave 7 to 12, fifteen loaded (three suites in parallel beside ten busy loops) 8 to 16 with one failure; measured from the server's position at each snapshot tick instead, 4 in all thirty, idle and loaded, and the worst gap fell from 0.058-0.155 m to 0.049 m. The limit went down to 6, not up.

**`dedicated` printed "Attempt to call RPC with unknown peer ID: 8101" on every green run.** 8101 is a session the saved-builds section adopts with no socket behind it, and the Builds tab's click is answered with a NOTICE to the clicker, which went to the link as a real `rpc_id`. The section now catches that one call on the link's loopback and checks the clicker alone was told, so the line in its stderr would now be a real one.

**A method `DotTimerZone` does not have took two checks out of a run that reported "0 failed".** `dedicated` had no section counter or CHECKS total until then.

**"With picking up off, nobody is held" was aiming the beam the wrong way** and passed with nobody in it. **The glass sprint path ran into the end of a wall** and broke it, correctly. **A button at a falling player's eye height** was pressed once by luck.

- **A READY that overtook the seat was dropped (2026-10-12).** A client sends READY when its link says PLAYING, which the link decides itself after sending `loaded` on another ENet channel. Through a lossy link the READY can reach the server first; `_admit` found no player for the peer and returned, and nothing asked again, so that client never got a world. Loopback and WebSocket order the two, so no suite could see it until `headless_net` sent the READY before the seat.
