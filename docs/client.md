# The client

`game/playground.tscn` / `PlaygroundClient`: one local player, a camera, a HUD, the keys. Not headless. Keys: Q spawn menu (hold or tap), 1 and 2 the two prop guns, F use / vehicle, R reload or unfreeze, N movement style, F5 first/third person, Y and U chat (all and near), Tab scoreboard (held), Escape release then menu.

## Booting

**Wait on a state, not a signal**: `if not playground.booted: await playground.ready_for_players`. `Playground.change_map` can complete without suspending (a built-in map is already in the build), so the playground can finish booting inside `add_child` before the client reaches its `await`, and the client then waits for ever: a black screen with no error. No test drives the client's boot that way; a screenshot caught it.

## Escape, the pointer and the menu

- **First Escape releases the cursor, the second opens the menu.** Escape is how a browser exits pointer lock and it refuses to re-enter for about a second, so a press that released and opened at once would leave a menu with no way back to the mouse.
- **Escape never captures; a click does.** A click on the world with the pointer released and no screen up captures and does nothing else, handled before the `player == null` guard so a click during loading is not lost. The HUD says "Click to play. Escape again for the menu." `_set_captured` is the one write and moves `mouse_capture_override` with it.
- **The menu is dot-menu's `DotMenu`**: stock audio, video and interface rows declared into this game's settings schema by `DotMenuStock.declare`, applied by `DotMenuApplier`, with `open_on_escape` and `manage_pointer` **off** so this client keeps the two-step and stays the one owner of the pointer. This game adds the Servers action and what Leave means. `overlays_changed` gives the pointer back when the menu closes. A missing settings manager greys the button out.
- **Tab is dot-menu's scoreboard, held** (fed by dot-server's roster while held); the movement style moved from Tab to N.
- **The check that matters is the settings round trip**: `DotSettingsManager.to_config()` hands out a snapshot, so a screen calling only the panel's apply reports success and changes nothing. `headless_presentation` edits the volume, presses Apply, and reads the manager **and** the mixer.

## Third person and the body

**F5 hands the player between two controllers** (`DotPlayerControllerSwitch`, carrying position, velocity and look, deliberately dropping motor state: a first-person air-strafe has no third-person counterpart). This is the only game where the switch runs: nothing here is ranked and nothing is rewound, where the timer game must keep runs comparable (camera only) and the arena game's lag compensation needs one motor.

- **A `PlaygroundPlayer` is a `CharacterBody3D`** (what `DotTpsController` drives), classified onto the layout's `player` layer like every other body.
- **`DotPlayerCharVisual` is a `DotPlayerComponent`, a plain `Node`.** The body goes under the **rig** (the `Node3D`, which `set_shown` hides and the mounts hang off).
- **`DotPlayerAnimDriver.auto_drive` is off**: it differentiates the body's transform, a second opinion about speed that disagrees with the controller exactly when a correction lands.
- After `view_third_person`, make the first-person camera current again when switching back (the render tool once kept rendering from the third-person rig).
- Who is shown and how remote bodies are placed and turned: [netcode.md](netcode.md#somebody-elses-body).

## People are drawn as people

- **The figure** (`game/playground_figure.gd`): the character kit's model (`assets/kenney/characters/`, CC0; one body, eighteen atlases) scaled to the character's height, **turned half a turn because the kit faces +Z**, and painted per part (head from the face skin, torso and arms from the top, legs from the legs). Loaded by rebased path so it works from a mount. `PlaygroundCharacter.build_for` draws it whenever given skins or a key, keeping `Head`/`Torso` markers for the mounts and the `RightHand` mount in front of the torso's right side; a build without the art draws capsules.
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

## The chat box

dot-ui's `DotChatWindow` beside the console. **The channels come from `PlaygroundServices.chat_channels()`**, not a list here, so the composer offers exactly what the server routes; the admin channel is filtered out. The second key opens the **near** channel (a sandbox has no teams).

| Setting | |
| --- | --- |
| `chat_window` | `auto` (hide on a server already carrying chat where the player can see it) / `on` / `off` |
| `chat_open_key` | `Y` |
| `chat_near_key` | `U` |

- **dot-server's `chat_received` is connected and its lines are ignored**: this game routes every line through its own wire, so the handler takes only the `{kind: "state"}` notice saying what is carrying chat.
- **`swallows_input()` covers the box as well as the console, and `DotFpsSampler.suspended` is set beside it**: movement is polled, so typing "sw" otherwise walks the player backwards through their build.
- **The console is dot-console's `DotConsoleKit`, built by `PlaygroundPresentation.build_console(menu)` after the client's `DotMenu`**, so it is one of the menu's overlays; `_refresh_suspended` runs on `overlays_changed` and on the chat box, and suspends while the box, the console or the menu is open (`headless_playground`'s boot section holds W to prove it).

## Looking at it

Every UI change wants a frame rendered and looked at; no assertion sees a 0 × 0 menu, a hidden tab or a body at the origin. These need `xvfb-run` (`--headless` gives a null renderer and saves empty frames).

| Tool | Renders |
| --- | --- |
| `tools/screenshot.sh <map>` | a map and its routes (`--fx` for the effects) |
| `tools/screenshot_menus.sh` | the spawn menu's tabs (Tools, Entities, Machines, Builds, the edit panel), dot-menu's pages, the Tab board, the console open |
| `tools/screenshot_views.sh` | first and third person, bodies, a rider, the HUD clock, creative, blind and beacon, the edit outline |
| `tools/screenshot_net.sh` | a connected client watching another player, with a per-frame movement probe |
| `tools/audio_probe.sh` | whether the client makes a sound |
