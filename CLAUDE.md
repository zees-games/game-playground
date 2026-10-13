# game-playground

A physics sandbox first: hold Q, pick a prop, an NPC or a weapon, click it and it is yours; hold it with a physics gun, freeze it, throw it, wire it, weld it, undo it. With map support, and with dot-timer kept on courses in the corner of the sandbox as well as on the surf and bhop maps, because that is what says the timer is not a surf-and-bhop thing. Networked over dot-net and delivered as a signed dot-cloud pack.

It is the only place dot-player-controller, dot-timer, dot-map, dot-props, dot-npc and dot-leaderboard run together, and the bugs that cost days here were all in the seams between them. `examples/headless_playground.tscn` is the point of the repository.

Read the family [CLAUDE.md](../../CLAUDE.md) first, and each addon's own `CLAUDE.md` before working in it. **The detail is in [docs/](docs/README.md)**: open the file for what you are touching.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/simulation.md](docs/simulation.md) | the tick loop, the player, styles, timer effects, teleports and spawns, tunables, the tick rate, the module and its commands |
| [docs/sandbox.md](docs/sandbox.md) | props, entities, NPCs, weapons, zee, projectiles, the Q menu, tools, the tool gun, limits, machines, breaking, pickup, creative, prop surfing, builds |
| [docs/maps.md](docs/maps.md) | a map, the zone export, the survey, custom map documents, materials, liquids, panes, `pg_generated` |
| [docs/routes.md](docs/routes.md) | a timed route, the drive bot, reach and pace checks |
| [docs/vehicles.md](docs/vehicles.md) | vehicles, seats, the circuit, driving over the wire |
| [docs/netcode.md](docs/netcode.md) | `game/net/`, prediction, remote bodies, the READY gate, mirrors, event and request kinds |
| [docs/inventory.md](docs/inventory.md) | the bag and its wire |
| [docs/modes.md](docs/modes.md) | arena, waves and downs, the shop, spectating, hosting |
| [docs/services.md](docs/services.md) | chat, voice, moderator tools, stats, the vote, hibernation, identity, the browser listing |
| [docs/client.md](docs/client.md) | the client, menus, third person, bodies and avatars, presentation, chat box, render tools |
| [docs/testing.md](docs/testing.md) | adding a check, or believing a green run |
| [docs/history.md](docs/history.md) | a bug that "cannot be happening"; what this game found and how it looked |

## Layout

| Path | What |
| --- | --- |
| `game/` | `playground.gd` (the simulation, headless), the player, the server module and services, props, `entities/`, `weapons/` and `toolgun/`, the modes, the bag, the client (not headless), `net/`, the maps' base, geometry and lighting. File by file: [docs](docs/README.md#where-the-code-is) |
| `maps/` | `pg_lobby`, `pg_surf_intro`, `pg_bhop_intro` (hand-built), `pg_generated`, `pg_data` (a JSON map), `*.zones.json` (generated), `custom/` (game-playground-maps, linked) |
| `examples/` | the five suites |
| `tools/` | `export_zones.gd`, `map_props.gd`, `screenshot*.sh`, `render_feel.sh`, `audio_probe.sh`, `loudness_pilot.gd` |
| `assets/`, `scenes/fx/` | vendored CC0 art (zee weapons and arms, the character kit, Kenney's grid); the two effect scenes |
| `game.yml` | the descriptor that travels in the published pack |

## Running and testing

- `./game.sh` plays offline (`godot --path .` also works); `./game.sh online` runs a local server and client; `./game.sh test` parses everything and runs all five suites; `./game.sh help` lists the rest.
- **Run `godot --headless --path . --script tools/export_zones.gd` after changing a map**, or the zone-file check fails. [maps](docs/maps.md#geometry-and-zones-come-from-one-description)
- `headless_playground -- --only=<method>` runs one section; it is then on whatever map the boot left. [testing](docs/testing.md#the-suites)
- **Add a `headless_net` test at the end of the connected-player sequence**: both halves share one physics space and the suite is order-sensitive. [testing](docs/testing.md#traps-the-suites-have-hit)
- A suite or tool that builds a presentation or client calls `PlaygroundPresentation.use_scratch_settings` first: never the player's file. [testing](docs/testing.md#traps-the-suites-have-hit)
- After touching a camera, the view key or player collision: `godot --headless --path . --script tools/camera_check.gd` (the rig round the lobby's walls, armed; `mp_solidplayers` both ways). [client](docs/client.md#third-person-and-the-body)
- **Render after touching the client, a menu or a map** (`tools/screenshot*.sh`, under `xvfb-run`). No assertion sees the screen. [client](docs/client.md#looking-at-it)

## Rules that bite

Short forms; the reasoning is in the linked file.

**Simulation**

- Footsteps and per-map beds are dot-audio's stock (a step's surface is the box's `dot_fps_surface`); measure levels with its `loudness.sh`, and check the pilot walked and spawned. [client](docs/client.md#footsteps-and-the-bed)
- `Drive.EXTERNAL` always; the game ticks the controllers and **feeds the timer after the move**. [simulation](docs/simulation.md#the-game-owns-the-tick-loop)
- Leave the controller's `body_ref` unset; `of_self()` is the controller, a plain `Node`, and the player never moves. [simulation](docs/simulation.md#body_ref-must-not-be-of_self)
- Apply the movement style and the timer style together (`PlaygroundPlayer.set_style`); never write the live tunables (a style rebuild drops it). [simulation](docs/simulation.md#a-style-has-two-halves-and-they-move-together)
- The timer decides and the game acts. Effects that move a player are applied on the tick, read at the state's own position (`effect_zone_at`), never from `timer.effect()`. [simulation](docs/simulation.md#the-timer-decides-and-the-game-acts)
- Effect zones (PUSH, GRAVITY) are not track-filtered; that is dot-timer's and an open question. [simulation](docs/simulation.md#the-timer-decides-and-the-game-acts)
- Teleport through `PlaygroundPlayer.teleport`; a yaw written into the state lasts until the next command. Facing is `atan2(-dx, -dz)`. It stops the run; only a map's TELEPORT zone passes `keep_run`. [simulation](docs/simulation.md#teleport-and-the-spawn-yaw)
- Reach comes from `PlaygroundMap.jump_reach` / `climb_limit`, never from `DotFpsTunables.new()`. [simulation](docs/simulation.md#the-movement-is-a-bhop-servers-not-the-addons-defaults)
- `sv_tickrate` goes in `server.cfg`; no `pg_tickrate`. [simulation](docs/simulation.md#the-tick-rate-comes-from-servercfg-and-every-link-is-silent)
- Zone commands are `CHANGEMAP`; saving a set with a problem is refused. [simulation](docs/simulation.md#the-server-module)

**Sandbox**

- One prop scene; the body is built by `configure`, never `_ready`; a resize rebuilds, never `scale`s. [sandbox](docs/sandbox.md#one-scene-every-prop)
- Entity and weapon scripts are named by **path**, never `class_name` (pack delivery). [sandbox](docs/sandbox.md#an-entity-is-a-prop-with-a-script-named-by-a-path)
- An entity is a prop first (budget, undo, liftable); a wave NPC is the server's and is not. [sandbox](docs/sandbox.md#perception-is-dot-npcs-being-a-prop-is-still-dot-props), [modes](docs/modes.md#waves-pg_waves)
- An NPC brain and debris seed from `npc.seed` / `Playground.next_seed`, never `instance_id` (an object id moves with every allocation). dot-npc `docs/runtime.md`
- Weapons are not `DotPropDef`s. The toys and zee guns run on the server; client arming is prediction. [sandbox](docs/sandbox.md#a-weapon-is-a-script-too-and-not-in-the-prop-catalogue)
- Connected, the drawn zee gun takes the server's count only after `SETTLE_SEC` quiet; the gun in hand picked again is a refill. [sandbox](docs/sandbox.md#zee-dot-weapons-beside-the-toys)
- A zee shot hurts only with `pg_arena` on; NPC shots reach players only through `arena_hurt`. `PlaygroundPlayer.component()` is load-bearing. [sandbox](docs/sandbox.md#zee-dot-weapons-beside-the-toys)
- One catalogue: icons, items, prices, the loadout and vehicle prop rows are all **derived**, never a second list. [sandbox](docs/sandbox.md#the-icons-are-drawn-from-the-definition)
- The menu never spawns; it emits. The first card takes focus, not the search. `TabBar.clip_tabs` off. [sandbox](docs/sandbox.md#the-q-menu)
- Switching tools or opening the menu lets go of everything. F is use, then vehicle. [sandbox](docs/sandbox.md#the-tools)
- Creative mode is protection **both ways**, and lives in dot-props so no tool can forget it. [sandbox](docs/sandbox.md#creative-mode)
- **Map toys** come from a map's `map_toys()`, built on both ends in that order under the playground, never the map; a hit scan asks `shoot_toy` first; the bounce is after the move on every end. [sandbox](docs/sandbox.md#the-maps-toys), [netcode](docs/netcode.md#the-maps-toys)
- Saved builds are catalogue ids, whole or nothing. [sandbox](docs/sandbox.md#saved-builds)

**Maps and routes**

- Geometry, zones and the suite read one description per route. [maps](docs/maps.md#geometry-and-zones-come-from-one-description)
- Unreached ground is allowed only where `survey_declared()` says why. [maps](docs/maps.md#every-hand-built-map-is-surveyed)
- Custom maps are JSON documents, never scripts; a map prop's missing id is skipped, not the map. [maps](docs/maps.md#custom-maps-are-documents)
- Material numbers are dot-physics'; liquids and foliage have no collider. [maps](docs/maps.md#map-materials)
- The palette is `PlaygroundGeometry.COLOUR_*`; a map's light is its dot-lighting document, a child of the map node, never a second `WorldEnvironment`. Render a look change with `RENDERER=forward_plus` too. [maps](docs/maps.md#the-look)
- A split must be one nobody can skip; a tilted slab drops along its normal; "it finished" is never the only check. [routes](docs/routes.md#rules-every-route-follows)

**Vehicles**

- A vehicle arrives through the prop spawner and is `adopt()`ed; `configure` before `adopt`; wheels below the chassis box; `continuous_cd` off. [vehicles](docs/vehicles.md#traps)
- Vehicles are not predicted, and the mirror's position is not smoothed. [vehicles](docs/vehicles.md#what-a-driver-feels-and-the-decisions-taken-on-it-veh-3)

**Netcode**

- A client predicts only its own player (owned by `local_peer_id`, claimed on HELLO). [netcode](docs/netcode.md#a-client-predicts-its-own-player-and-nobody-else)
- Nothing goes to a peer before READY: `_broadcast` is peer by peer, greet from `peer_admitted`, voice is held. `remove_player` asks `net.peers()`. [netcode](docs/netcode.md#a-broadcast-reaches-ready-peers-only-pg-rpc-before-scene)
- **A READY before the player is seated is kept** (`_ready_unseated`) and answered by `add_player`; a dropped one left the client waiting for ever. [netcode](docs/netcode.md#a-ready-before-the-seat)
- `Ask` is full: new requests are ARM_PROP sub-kinds. New event kinds and message fields are appended. [netcode](docs/netcode.md#the-request-enum-is-full)
- No message script preloads itself. [netcode](docs/netcode.md#no-message-preloads-itself)
- A bag goes only to its owner, as ops up and whole documents down. [inventory](docs/inventory.md#over-the-wire-playgroundinventorynet)

**Modes and services**

- Every mode is off by default and a cvar. Stamp every `DotDamage` with a tick. [modes](docs/modes.md)
- A death's fall is the server's pick (`PlaygroundArena.decide_death`, `Playground.decide_npc_death`), riding COMBAT or PROP_GONE last and optional; a bleed-out emits `arena.player_killed` too. [modes](docs/modes.md#the-dead-fall)
- A spawn is asked, placed, then charged. [modes](docs/modes.md#pg_shop-a-sandbox-with-prices)
- One entity id per player, from `Playground.entity_table`. [modes](docs/modes.md#downed-not-dead-shares-pg_waves)
- One chat path (dot-server's cancelled in `hook_pre`); the chat key is the session id. [services](docs/services.md#chat-dot-chats-and-exactly-one-path)
- An admin's help never makes a time. Blind is owner-only state. [services](docs/services.md#the-moderators-live-tools)
- The module advances the vote once a tick (`self_advance` off); the vote's clock is the one shown. [services](docs/services.md#the-vote)

**Client**

- Wait on `playground.booted`, not only the signal. [client](docs/client.md#booting)
- Every key is a `PlaygroundBindings` row read through its action, never a keycode (Escape excepted); H is help, so no row may default to H. [client](docs/client.md#keys-help-and-leave)
- M is dot-menu's map menu: solo through `Playground.change_map`, on a server dot-vote's menu (the owner's flag changes, anybody else votes). No other row may default to M. [client](docs/client.md#m-the-map-menu)
- Escape releases then opens dot-menu; only a click captures. This client owns the pointer. [client](docs/client.md#escape-the-pointer-and-the-menu)
- The character body goes under the rig, not the visual; `auto_drive` off. [client](docs/client.md#third-person-and-the-body)
- Chat lines go to the chat box, and to the HUD notice line only when there is no box (a ballot was drawn twice). [client](docs/client.md#the-chat-box)
- The first-person camera is written only in `PlaygroundPlayer.present_camera`; there is no `DotFpsView`. Right mouse aims a zee gun (a tool's secondary otherwise); its quick melee is Mouse 3. [client](docs/client.md#the-first-person-camera)
- The hit marker, damage numbers and the red burst come from the server's `Kind.HIT`, never the local rig; the glance pieces need a shell with dot-ui 4. [client](docs/client.md#the-hud)
- The HUD follows the menu's theme and HUD size; `PlaygroundHud.piece_theme()` is the accent only, never plate, text or ink. [client](docs/client.md#the-hud)
- B is the arena's loadout (dot-loadout's, bound by the module), enabled only while the replicated `pg_arena_on` says so. [modes](docs/modes.md#b-the-arenas-loadout)
- Typing suspends the sampler as well as swallowing input; the console does it as a menu overlay, so it is built after the menu (`build_console(menu)`). [client](docs/client.md#the-chat-box)

## Not here yet

The unbuilt pieces (the `DotGameModule` conversion, restart and checkpoint keys, the bag screen, a wardrobe, grenades for joiners, frozen state on PROP, replay playback) are listed with their reasons in [docs/not-yet.md](docs/not-yet.md).
