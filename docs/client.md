# The client

`game/playground.tscn` / `PlaygroundClient`: one local player, a camera, a HUD, the keys. Not headless. Keys: `PlaygroundBindings` (see [keys, help and Leave](#keys-help-and-leave)); Escape releases, then opens the menu.

## Booting

**Wait on a state, not a signal**: `if not playground.booted: await playground.ready_for_players`. `Playground.change_map` can complete without suspending (a built-in map is already in the build), so the playground can finish booting inside `add_child` before the client reaches its `await`, and the client then waits for ever: a black screen with no error. No test drives the client's boot that way; a screenshot caught it.

## Keys, help and Leave

- **Every key the client reads is a row of `PlaygroundBindings`**, matched by its action (`event.is_action`), never a keycode; Escape alone is a keycode, because no row may hold it. The table is declared into the settings schema (`PlaygroundPresentation.schema`), applied before the menu is built, and drawn on the Controls page and the help screen. Until 2026-10-11 every key was a keycode and the Controls page could move none of them. A sentence that names a key asks `PlaygroundClient.key_for` (the HUD's line, the spawn menu's footer, the notices).
- **H opens help** (dot-menu's stock key; `PlaygroundClient.fill_help` writes the goal, building, running and modes), so nothing in the table may default to H. `headless_playground`'s client section checks it, the buttons, and that a rebound key moves what the client reads.
- **Leave is dot-menu's stock one** (`leave_on_its_own`): it disconnects when connected and quits solo on a desktop. `leave_requested` is still emitted; until 2026-10-11 it was all Leave did and nothing listened.

## Escape, the pointer and the menu

- **First Escape releases the cursor, the second opens the menu.** Escape is how a browser exits pointer lock and it refuses to re-enter for about a second, so a press that released and opened at once would leave a menu with no way back to the mouse.
- **Escape never captures; a click does.** A click on the world with the pointer released and no screen up captures and does nothing else, handled before the `player == null` guard so a click during loading is not lost. The HUD says "Click to play. Escape again for the menu." `_set_captured` is the one write and moves `mouse_capture_override` with it.
- **The menu is dot-menu's `DotMenu`**: stock audio, video and interface rows declared into this game's settings schema by `DotMenuStock.declare`, applied by `DotMenuApplier`, with `open_on_escape` and `manage_pointer` **off** so this client keeps the two-step and stays the one owner of the pointer. This game adds the Servers action and what Leave means. `overlays_changed` gives the pointer back when the menu closes. A missing settings manager greys the button out.
- **Tab is dot-menu's scoreboard, held** (fed by dot-server's roster while held); the movement style moved from Tab to N.
- **`sensitivity` reaches the sampler through `PlaygroundClient._bind_look`** (the applier's `bind_look`, dot-menu's degrees per count), called when the applier is built and again in `_adopt`, which hands the connected sampler a fresh tunables object at the addon's default. Until 2026-10-11 nothing called it and the slider moved nothing; `headless_playground`'s "the client boots" reads the sampler's tunables. `invert_mouse` (dot-menu's stock controls group) goes the same way.
- **The check that matters is the settings round trip**: `DotSettingsManager.to_config()` hands out a snapshot, so a screen calling only the panel's apply reports success and changes nothing. `headless_presentation` edits the volume, presses Apply, and reads the manager **and** the mixer.

## The first-person camera

**`PlaygroundPlayer.present_camera` is the one place the camera is written**, once a frame from `PlaygroundClient._process`: the interpolated eye (`render_eye_position`), the view's angles, then the camera motion, the effects' shake, the zee recoil's punch and the player's `field_of_view` on top. There is no `DotFpsView` (one stood here unrun; [history](history.md#the-client)).

**Camera motion is dot-player-controller's `DotFpsViewMotion`** at `PlaygroundPlayer.camera_motion_picks()`, chosen for a bunny-hop and surf movement (1.15 m jumps at 20 m/s², a 7 m/s run):

| Cue | Pick | Why |
| --- | --- | --- |
| Landing dip | 6 cm and a 1° nod, from 8 m/s, full at 16 m/s | a hop lands at 6.8 m/s and must never bob the view; a drop off a ledge does |
| Strafe lean | 1° at 9 m/s sideways, bounded at 2° | a surfer looks across the ramp for seconds at a time |
| Speed widening | up to 5°, from 8 to 25 m/s | a player walking about building never sees the lens move; a bhop or a ramp does |

**Down a zee gun's sights** (`PlaygroundBindings.AIM`, right mouse, the family's Aim row): zee's `ZeeViewModel.aim` while held with the pointer on the view and in first person, the lens multiplied by `aim_fov_scale` in `present_camera` (`zoom`, after the speed widening, from the player's own field of view), dot-ui's `DotCrosshair.set_aim` fading the crosshair and zee's `ZeeScopeOverlay` (the HUD's first child, so the timer reads over it) through a scope. Presentation only, as in game-arena. With a tool or a toy in hand the right button is still its secondary (freeze, pull, a mode's second button); a zee gun's quick melee moved to the middle button (`PlaygroundBindings.BASH`). `tools/render_loadout.tscn` frames hip and aimed for an iron sight and a scope.

The landing is kicked when the drawn eye reaches the floor, not on the `landed` tick (game-arena's finding: the dip otherwise adds to the last of the fall). A teleport and a seat snap everything. Three ACCOUNT settings scale the picks 0 to 2 (`camera_landing_dip`, `camera_strafe_roll`, `camera_speed_fov`; no wall lean, nothing here wall-runs), on General > Camera motion and at the console. `tools/render_feel.sh` renders a drop, a run of hops, a strafe and flight at 22 m/s at 144 frames a second (`--off` is the control); judged 2026-10-11 as gentle and right, with no change to the picks.

## Third person and the body

**F5 hands the player between two controllers** (`DotPlayerControllerSwitch`, carrying position, velocity and look, deliberately dropping motor state: a first-person air-strafe has no third-person counterpart). This is the only game where the switch runs: nothing here is ranked and nothing is rewound, where the timer game must keep runs comparable (camera only) and the arena game's lag compensation needs one motor.

- **A `PlaygroundPlayer` is a `CharacterBody3D`** (what `DotTpsController` drives), classified onto the layout's `player` layer like every other body.
- **`DotPlayerCharVisual` is a `DotPlayerComponent`, a plain `Node`.** The body goes under the **rig** (the `Node3D`, which `set_shown` hides and the mounts hang off).
- **`DotPlayerAnimDriver.auto_drive` is off**: it differentiates the body's transform, a second opinion about speed that disagrees with the controller exactly when a correction lands.
- After `view_third_person`, make the first-person camera current again when switching back (the render tool once kept rendering from the third-person rig).
- Who is shown and how remote bodies are placed and turned: [netcode.md](netcode.md#somebody-elses-body).
- **The server decides whether F5 may** (`mp_forceview`, dot-player-controller's `DotPlayerViewRules`: 0 the player's choice, 1 first person only, 2 third person only), bound REPLICATED by the module and followed through the link; `_toggle_view` asks it and `_on_view_rules_changed` moves a player the server no longer allows.
- **The rig's arm is dot-core's `DotCameraBoom`** (it was a spring arm): `_guard_rig` sets it to stop at the `world` and `prop` layers, never people, and hands its fade the other players; a `DotCameraFade` on the first-person camera hides somebody at the lens. `tools/camera_check.gd` flies the rig round the walls of the lobby (armed) and walks two players into each other.
- **Players are solid to each other** (`mp_solidplayers` 1): `Playground._apply_body_mask` puts the player layer in the motor mask through `DotPlayerBodyRules.apply_to` and gives each body a standing `SolidHull`; set 0 for the genre's pass-through.

## People are drawn as people

- **The figure** (`game/playground_figure.gd`): one of the family's animated people (dot-player-char's `DotHumanoidFigure`), coloured per part from the site's three skins (skin, hair and which body from the face; the top from the top; trousers from the legs, `DotHumanoidLook.SITE_SKINS`), at the character's height. `PlaygroundCharacter.build_for` draws it whenever given skins or a key, keeping `Head`/`Torso` markers for the mounts and the `RightHand` mount in front of the torso's right side; `PlaygroundPlayer.face_body` hands it the movement every frame (`move_person`: speed, vertical, floor, crouch, and the view's pitch as `aim`), a seated rider plays the made sitting pose (`seated`) with the figure `seat_height()` under the seat, and an NPC or prop dressed with `dress_body` animates from how far it moves (`auto_animate`). A build without the art draws capsules.
- **What somebody wears** (`game/playground_avatars.gd`): schema `pg_people`, slots face/top/legs; `from_site` reads the site's `builtin` document, filling an empty slot from the top; the stock look is one skin picked by hashing the player id, the same on every machine.
- **NPCs**: a prop entity whose id begins `npc_` and every wave NPC wear the figure keyed by kind, so every soldier matches and a rebel does not. Collision is unchanged.
- Server side and the wire: [services.md](services.md#identity-dot-platform), [netcode.md](netcode.md#wire-compatibility).
- **Not here: a wardrobe.** The schema, entitlement check and storage exist and a player cannot choose: `DotAvatarSchema.choices_for` is the call.

## The presentation layer

`PlaygroundPresentation`: settings, randomness, audio, effects, the console and the chat box. `PlaygroundClient._wire_presentation` is the producer of every hook. Two decisions are this game's:

- **`prop_sounds` is about somebody else's building**; your own prop still makes a noise, because it answers something you did.
- **`refused` outranks a crate hitting the floor.** A refusal answers the player; a landing does not.

**Sound.** Each audio id has a `DotAudioSynth` voice in `sound_recipes()`, used only when a def's path resolves to nothing, so real files switch the stand-ins off one id at a time. Almost nothing a sandbox makes is information to act on; it is confirmation the thing you did happened, which is why `refused` has a voice (a refused buy and a buy that did nothing are otherwise identical). `wave_incoming` is the one ominous sound, because it is the one thing that arrives unasked. `tools/audio_probe.sh` is what says a speaker moved; a headless run has no audio device.

**Effects.** `scenes/fx/spawn_puff.tscn` and `tool_beam.tscn` have no script and no external resource, loaded under `FX_DIR` through `PlaygroundPaths.rebase`; `_build_fx` warns when `missing_scenes()` is not empty (dot-fx refuses a missing scene at DEBUG, silently). Beams are drawn by `PlaygroundClient.present_beams` once a frame per holder, one node moved every frame and replaced when its 100 ms ceiling retires it, not one spawned per frame.

**Still unwired:** `on_prop_landed` (nothing reports a landing), `on_bought` and `on_wave_incoming` (the shop and waves are server-side and no event carries either), `wave_flash` (triggered by nothing) and `DotFxManager.flash_colour` (needs a HUD overlay as well as an event). Tool sounds are offline only.

## The HUD

`PlaygroundHud`: a run timer's block top left when a server has one (`set_timer_hud`, placed by `addons/pg_timer`), the notice, status and tool lines under it, a crosshair, and three of dot-ui's glance pieces (API level 4), coloured by `PlaygroundHud.piece_theme()` (the timer's translucent black plate, the boost pads' amber for a kill or a head, the start pads' green, the timer's red for a low magazine):

- **`DotAmmoCounter` bottom right**: the zee weapon in hand, magazine and reserve (endless when the weapon says so; the reserve alone for one that feeds straight from it; the name alone for a blade). Nothing with a toy or empty hands, which the tool line names. It reads the client's own rig, which on a connected client is the predicting one. Bottom right because the chat box is bottom left and a shell's ballot top right; it dims under a ballot that reaches it.
- **`DotHitMarker` and `DotDamageNumbers`**, from `confirm_hit`, which the client calls for each `Kind.HIT` the server sends it (offline, for its own world's `hit_landed`): never from the local prediction ([netcode.md](netcode.md#weapons-over-the-wire)).
- `headless_presentation` checks the numbers, the counter against the chat box (here and at 854 wide) and under a ballot (armed), and that the pack asks a shell for dot-ui 4. `screenshot_views`' `hud_hits` frame shows them.

- **The theme.** The HUD follows the menu's theme and HUD size (`PlaygroundClient._follow_hud`: dot-menu's `follow_hud` by name, plus `PlaygroundHud.apply_theme` on `theme_changed` for dot-timer's block); `PlaygroundHud.piece_theme()` is the accent only (boost amber, start green), never plate, text or ink. `headless_playground` checks a theme change reaches the pieces and the timer.
- **What a hit draws.** The hit marker, damage numbers and zee's red burst on the body (`PlaygroundClient._draw_body_hit`, `ZeeShotFx.play_body_hit` by `has_method`) come from the server's `Kind.HIT` (`Playground.confirm_hit`, fed by all four damage paths), never the local rig; the glance pieces need a shell with dot-ui 4.

**A pack naming these classes does not parse on a client shell whose dot-ui predates them**, and no `DotAddonApi` level check can guard a class name: a release of this game waits for a shell built with dot-ui 4.

## The chat box

dot-ui's `DotChatWindow` beside the console. **The channels come from `PlaygroundServices.chat_channels()`**, not a list here, so the composer offers exactly what the server routes; the admin channel is filtered out. The second key opens the **near** channel (a sandbox has no teams).

| Setting | |
| --- | --- |
| `chat_window` | `auto` (hide on a server already carrying chat where the player can see it) / `on` / `off` |
| `chat_open_key` | `Y` |
| `chat_near_key` | `U` |

- **Every chat line goes to the box, and to the HUD's notice line only when there is no box** (`PlaygroundClient._on_chat_message`). Both drew every line, so a map vote's ballot was printed at the notice line in the middle left and again in the box, beside the drawn ballot panel. The notice line keeps the game's own messages (budget reached, a tool's refusal), which never come through chat. `headless_presentation` checks it; `screenshot_views`' `chat_ballot` frame shows it.
- **dot-server's `chat_received` is connected and its lines are ignored**: this game routes every line through its own wire, so the handler takes only the `{kind: "state"}` notice saying what is carrying chat.
- **`swallows_input()` covers the box as well as the console, and `DotFpsSampler.suspended` is set beside it**: movement is polled, so typing "sw" otherwise walks the player backwards through their build.
- **The console is dot-console's `DotConsoleKit`, built by `platform.add_console(settings)` after `platform.adopt_menu(game_menu)` and handed to `PlaygroundPresentation.adopt_console`**, so it is one of the menu's overlays; `platform.refresh_blocked()` runs on `overlays_changed` and on the chat box (the sampler follows `input_blocked_changed`), and suspends while the box, the console or the menu is open (`headless_playground`'s boot section holds W to prove it).

## Footsteps and the bed

- **Footsteps and a bed per map are dot-audio's stock** (`PlaygroundPresentation.keep_walkers`; a step's surface is the box's `dot_fps_surface`, the one the movement reads; `bed_for` by map prefix). Levels are measured with `addons/dot_audio/tools/loudness.sh --warmup=6` (−17 LUFS band, `loudness_trim_db`), which drives the local player through `tools/loudness_pilot.gd` (walks, spawns props, punts them); a run whose `capture pilot:` line shows no walking or spawning measured an empty room. Stock ids have files, so the stand-in check skips them.

## Looking at it

Every UI change wants a frame rendered and looked at; no assertion sees a 0 × 0 menu, a hidden tab or a body at the origin. These need `xvfb-run` (`--headless` gives a null renderer and saves empty frames).

| Tool | Renders |
| --- | --- |
| `tools/screenshot.sh <map>` | a map's set shots (`--fx` for the effects) |
| `tools/screenshot_menus.sh` | the spawn menu's tabs (Tools, Entities, Machines, Builds, Addons, a zee pack tab, the waypoint and NPC spawner panels, the edit panel), dot-menu's pages (General twice, the second scrolled to the camera motion), the Tab board, the console open |
| `tools/screenshot_views.sh` | first and third person, bodies, a rider, the HUD clock, creative, blind and beacon, the edit outline, a weapon's ammunition and two confirmed hits (`hud_hits`), a map ballot's chat line beside the drawn panel |
| `tools/render_feel.sh` | the first-person camera's motion: a drop, hops, a strafe, flight at speed; frames, a per-frame CSV and contact sheets in `screenshots/feel/` |
| `tools/screenshot_net.sh` | a connected client watching another player, with a per-frame movement probe |
| `xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_loadout.tscn` | a zee gun hip and aimed (carbine, bullpup's scope), solo B outside the arena, and the arena's B menu, into `screenshots/loadout/` with a line per frame |
| `tools/audio_probe.sh` | whether the client makes a sound |

## M, the map menu

M is dot-menu's map menu (`PlaygroundBindings.MAP` is `dot_menu_maps`, still stored as `bind_map`): solo `PlaygroundClient.map_menu_rows()` lists the catalogue (custom and delivered maps included) and `change_from_menu()` changes through `Playground.change_map`; on a server dot-vote's map menu changes through `game.change_map` for the owner's `sv_map_menu_flag` and gives anybody else a vote. No other row may default to M; `headless_playground` and `dedicated` check it.

## The load gate

`PlaygroundClient.gate` is dot-core's `DotLoadGate` (API level 10), built first in `_ready` by `PlaygroundClient.platform`, a dot-game `DotGameClient` (API level 8) that also answers the link and offline, flushes the browser's filesystem and emits `input_blocked_changed` (the sampler suspends on it; `busy_fn` covers the chat box, console and menus). Its settings, console, pointer and Tab board are off: the menu is built round `PlaygroundPresentation`'s manager, the console must follow it, Escape releases then opens, and the board is the roster's. It holds `map` (released once the first level is in, held again on each `maps.changing`, released on `maps.changed`) and requires `spawned` (the local player and a camera in the tree). The local body is `freeze`d, which `Playground._simulate_tick` honours (`can_process`), and the client's own keys, tool tick and netcode sampling check `_covered()`. Before it, solo drew the body falling onto the floor in the first seven frames with no cover, and a connected client drew a HUD with no player. `tools/load_probe.gd` (xvfb-run, not `--headless`) prints per frame whether the map, player, camera and cover exist and where the body is, and saves frames 3, 15 and the last to `screenshots/`.
