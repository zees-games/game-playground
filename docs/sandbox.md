# The sandbox half

Props, entities, weapons, the Q menu, the tools and everything a builder touches. The modes that turn the sandbox into a game (arena, waves, shop) are in [modes.md](modes.md); the bag is in [inventory.md](inventory.md).

## One scene, every prop

`game/prop.tscn` is the only prop scene and has no shape, mesh or mass in it. Three fields of `DotPropDef.meta` (`shape`, `extent`, `colour`) are turned by `PlaygroundProp.configure` into a collision shape and a box. A server with real content points `scene_path` at its own scenes and never loads this file: the definition is checkable without loading anything, and the scene is fetched only on creation.

- **The body is built by `configure`, not `_ready`.** `DotPropSpawner` instantiates, places, adds to the world and *then* emits `spawned`, so the definition arrives after the node is in the tree. A prop nobody configured has no shape and no mesh: it falls through the floor, is invisible and cannot be grabbed. `_ready` schedules a deferred check that says so, once.
- **`DotPropDef.mass` is put on the body by `DotPropSpawner` before it enters the tree** (earlier than the first physics step, because a mass set after an impulse divides that impulse by the old mass). It once never was: here every prop is the same scene, so mass is the only thing distinguishing them.
- **A resize rebuilds, it never `scale`s.** A scaled `RigidBody3D` is unsupported by Godot physics. `PlaygroundProp.set_size_scale` rebuilds collision and mesh from the definition (ten inflates and ten deflates land where they started) and mass goes with the volume. Size and paint replicate as `net_scale` / `net_tint`; a mirror rebuilds only when they change.
- `Playground.layer_for(def, frozen)` classifies every prop body, server and client mirror alike ([netcode.md](netcode.md#a-prop-mirror-is-on-the-props-layer)).

## An entity is a prop with a script, named by a PATH

A crate is a shape with a mass; a thing that walks needs code. dot-props knows nothing of the difference, so it is two fields of `meta`: `{ "kind": "entity", "script": "res://game/entities/npc_wanderer.gd" }`. `Playground._configure_entity` attaches the script to the bare `RigidBody3D` that `entity.tscn` is.

- **By path, not `class_name`**, because a mounted pack's `class_name` globals are not registered in the host (dot-cloud's [mounting.md](../../dot-cloud/docs/mounting.md)). The shipped entities `extends "res://game/entities/playground_entity.gd"` because they are the template a pack copies.
- **`_ready` has already run when the script is attached.** Entities use `_entity_ready` and `bind`.
- **A failure removes the prop rather than leaving it.** A body whose script did not load sits there being a crate, indistinguishable from an idle NPC. Both shapes are loud: a missing path, and a real script that is not an entity (what copy-paste produces).
- **An entity extends `PlaygroundProp`, so it is a prop to everything else**: budget, undo, removed when its owner leaves, a physics gun can lift it, a gravity gun can punt it. An NPC you cannot pick up is the first thing a sandbox player will try.
- **A held entity stops driving itself**, or it fights the physics gun's spring and the player concludes the gun is broken.
- **Tuning lives in the definition, not the script**: `npc_wanderer` and `npc_hopper` are one file at two speeds, and the definition is the half an operator editing JSON can reach.
- NPC catalogue entries are grouped for limits by the entry's id, not the script name (the turret runs `npc_spinner.gd`).

## Perception is dot-npc's; being a prop is still dot-props'

The entities use **dot-npc** for senses and not its spawner. `DotNpcSenses` acquires at one threshold, drops at a weaker one, and keeps chasing for a grace period measured from the **last sighting**; calling `nearest_player()` every tick turns back and forth between two players a metre apart and forgets instantly when one steps out of range. `PlaygroundEntity.target()` is the interface; `nearest_player()` remains for the spinner. The envelope (`sight`, `sight_angle`, `hearing`, `line_of_sight`) is a catalogue field. Spawning through `DotNpcSpawner` would take away everything that makes an entity a prop.

- **The candidate list is built once per tick, before the entities run**: not per entity (twenty NPCs each building a list of eight players), not after (a list of where everybody *was*).
- **A target who disconnects is dropped immediately**, not left to the grace period.
- Armed NPCs (soldiers, rebels) are candidates for each other (`npc_candidates_all`); the older entities see players only.

## `npc_hunter` is `npc_chaser` with a decision, and both are kept

The cheap one fills a room, the expensive one is for the arena, and keeping both shows what dot-npc-ai bought: a **reaction time** (an NPC cannot commit on the tick it first perceives you), a **character** seeded from the instance id (twenty do not react at once), **separation** (a pack comes apart rather than stacking into a tower), and a **state machine**, because there are four states and the transitions are the design. `wave_brain.gd` is a tree, for the opposite reason. `has_reacted()` measures from `DotNpcInstance.target_since`, not `engaged_at` (which dot-npc refreshes on every pass in which the target is perceived).

## Armed NPCs

A zee rig in a dot-npc-ai brain (`npc_soldier.gd`, `soldier_brain.gd`). Soldiers (`hostile`) and rebels (`player`: never pick a player, follow whoever spawned them) are one file. `PlaygroundNpcWorld` is the director the brain asks (`now`, `candidate_position`, `npcs_near`), because these NPCs are props first.

- **Squads are per owner AND per faction.** One squad per player made each side's fire-lane check find a squadmate (its own target) in the lane, and nobody fired.
- The brain decides when (`ready_to_fire`); the body holds the trigger on a server-role zee rig, so fire rate, magazine, reload, spread and damage are the weapon's.
- A player's shot hurts an NPC (`player_shots_fired`); an NPC's shot hurts another NPC always and a player only through the arena (`arena_hurt`), so `pg_arena` stays the switch for anybody being killed.
- A dead NPC drops its weapon as a pickup; walking over it gives the weapon as the menu does.
- **Only guns and melee are offered to NPCs**: the brain aims along a line and has no throwing arc, so an NPC with a frag bounces it off its own feet.

## A weapon is a script too, and not in the prop catalogue

`PlaygroundWeapons.make` loads a path, instantiates it, and checks the result **is** a `PlaygroundWeapon`: a valid script extending the wrong thing constructs fine and then crashes inside a mouse handler.

- **Weapons are deliberately not `DotPropDef`s.** dot-props' catalogue is things you spawn and requires a `scene_path`; a weapon has no body, and giving one a fake scene path is the lie that becomes "why does this crate have no collision".
- **`PlaygroundWeapon` extends `DotPropTool`**: spawner, wielder, reach, `target()`, and `may_act_on()` asking the host. Not a node, no camera, handed an origin and a direction, so the same weapon works for a player, a bot, a replay and a test.
- **A muzzle velocity is not an impulse, and the arsenal uses both on purpose.** `PlaygroundWeapon.launch` writes a velocity (an impulse is divided by mass, wrong for a launcher); `swep_impulse` uses an impulse (a shockwave *should* throw a beach ball further than a boulder).
- **The toys run on the server.** `_give_weapon` builds the toy on the server (`PlaygroundWeapons.make`, wielder = the player) and `_drive_tools` runs it: primary/secondary on the pressed edge, `tick` every tick. A prop it spawns is charged like a menu spawn, after the spawn. Arming locally on the client is **prediction**; `weapon_changed` is the correction (a refused purchase takes the weapon back out of the player's hands).

## zee-dot-weapons beside the toys

Twenty-seven pack weapons in the Weapons tab under five categories from the pack's slots. `PlaygroundZee.defs()` maps the pack's catalogue to `PlaygroundWeaponDef`s with `meta.zee` and no script, ids prefixed `zee_` (both lists have a `launcher`), so menu, shop and loadout see one list. The CC0 art is vendored in `assets/{blaster-kit,melee,arms}`.

- **A zee weapon is not wrapped as a toy.** It is dot-weapon's: held buttons per tick, its own cadence, reload and ammunition. `_give_weapon` puts a SERVER rig with the authority on the server's player and `_drive_tools` ticks it from the USER_0/1/2 bits (fire, bash, reload), returning before the physics gun sees them. The client builds a `ZeeViewModel` and a LOCAL rig (no authority when connected, the authority offline). R reloads with a zee gun in hand and unfreezes everything otherwise.
- **A shot hurts only while `pg_arena` is on.** Off, it shoves the prop it hits (`PlaygroundZee.shove_props`, through the gravity gun's ray and `may_act_on`). On, the module's `_resolve_shot` hands it to dot-combat through `PlaygroundNetBridge.shot_fn`, asked per shot because `pg_arena` flips at runtime.
- **`PlaygroundPlayer.component()` is load-bearing.** dot-weapon's player bridge finds the controller through it; without it every shot leaves the feet pointing north and hits nothing.
- **Art in a pack**: `ZeeModelCache.set_asset_root(PlaygroundPaths.root())` on the client's `_ready`, back to `res://` on `_exit_tree`, because a static outlives the game in a shell that switches.
- **Connected, the drawn gun is corrected from the server's count once quiet.** The client's LOCAL rig simulates from the same buttons, so it agrees with the server until a shot is refused or the server refills it, and nothing used to write the server's count back: the HUD (which counts the drawn rig) kept the client's own sum for good. `PlaygroundPlayerNet._correct_drawn` hands the owner-only `net_magazine` / `net_reserve` to `PlaygroundZee.correct`, which writes them only when the drawn rig has gone `SETTLE_SEC` (0.6 s, longer than a shot's round trip) without a trigger, reload or switch (`PlaygroundPlayer.zee_quiet`, counted by `PlaygroundZee.note_drawn` per tick in `_net_physics`) and neither side is reloading or switching; on every snapshot it would undo shots in flight. game-zombie-zone's `ZzPlayer.correct_view_rig` is the same rule. `headless_net`'s "the drawn gun takes the server's ammunition count" is armed.
- **Picking the gun already in hand again is ammunition** (the Q menu, or walking over its pickup): `PlaygroundZee.refill` fills the magazine and the reserve back to a fresh rig's on the server (`_give_weapon`, no new rig, no WEAPON event, a notice), offline on the client's own rig. The drawn gun is not told; the correction above brings it the count.
- **A zee weapon keeps its 64 Hz timing on this 128 Hz server.** The pack's rows say they were written at 64 (`DotWeaponDef.authored_tick_rate`) and the rig's arsenal runs at `playground.tick_rate`, so dot-weapon scales cadence, reload, deploy, charge and bloom recovery, and a spawn's fuse and life arrive in this server's ticks. `PlaygroundProjectiles.accept` flies a spawn as given; a rescale there would halve every fuse a second time. Arm every rig with `playground.tick_rate` on both ends, or a client predicts a different reload end than its server.

## Grenades and rockets

`PlaygroundProjectiles` (`Playground.projectiles`) takes a weapon outcome's `spawns` in `player_shots_fired` and `npc_shots_fired` (**before** the `used` test, because a release produces a spawn), flies each with a ray swept per tick, bounces fused ones (`FLOOR_KEEP` 0.45 along a floor, 0.7 along a wall), sticks a sticky, and on the authority sets each off on its fuse, on contact or at end of life. A blast hurts what is in the splash and in sight with linear falloff (NPCs through `take_damage`, players through `arena_hurt`), throws loose props, breaks panes (`hurt_panes_in`, because the blast's shape query returns no world geometry), and spares nobody, the thrower included. While live, a grenade is a DANGER every eight ticks on every board it was given.

**Not an entity per grenade**: it lives three seconds and its path is a pure function of how it left. Over the wire it is one `Kind.PROJECTILE` event: LAUNCH (velocity and fuse as full floats) and DETONATE (where). A client's copy never goes off by itself, because its world holds interpolated mirrors, not the server's props. **Not yet**: a joiner is not told about grenades already in the air, and the thrower sees its own grenade a round trip late (nothing predicts it).

## Model props and the drop-in folder

Beside the fourteen built-in block props the catalogue carries 120-odd real objects (furniture, food, camping and nature pieces, a few shop fittings). They are the same `game/prop.tscn`: a definition whose `meta.model` names a `.glb` makes `PlaygroundProp._build_model` load it through dot-props' `DotPropModel`, scaled in metres on a holder node (never on the body) with one convex hull and a mass from the manifest. Resizing and tinting work on them like any prop; a tint is a material override on every mesh.

- **Stock packs** are `assets/props/<kit>/` (`furniture`, `food`, `survival`, `nature`, `market`), each with a `props.json` that gives the credit, the scale to metres, and per prop an id, name, category, mass, shape and baked extent, plus `thumbs/<stem>.png` for the menu card. Ids avoid the built-in ones (`barrel_wood`, not `barrel`). The glb files and their `Textures/colormap.png` are vendored; `PlaygroundSpawnables.with_models` reads them through `PlaygroundPaths.rebase`, so they survive pack delivery.
- **To change the pack**, edit `tools/props_pack.tsv` (kit, file stem, id, name, category, mass in kg, shape), run `python3 tools/build_props_pack.py <the Kenney 3D assets folder>` and then `xvfb-run -a godot --path . --script res://tools/bake_props_pack.gd`, which measures every model into `props.json` and renders the thumbnails.
- **Drop-in**: any `.glb` or `.gltf` put in `user://props/` (or `props_dir` / `PLAYGROUND_PROPS_DIR`, which a server points at its content directory) is a prop in the next menu, with no code. An optional `name.json` beside it sets `name`, `category`, `mass`, `scale` or `size_m`; with none, the name comes from the file and the category is `custom`. A `props.json` in the folder does the same for many. `Playground.rescan_props()` reads it again at run time. A file can never replace a built-in id.
- **The server validates by id only.** A client asks for a catalogue id; `_spawn_for` refuses anything not in the server's catalogue, so a path or `..` is never loaded on a client's say-so (the headless_net suite sends three).
- **A client draws a prop from its own catalogue**, so a drop-in model that only the server has is invisible to a connected client. Models everyone should see belong in `assets/props/`.
- The menu tooltip shows the credit (author and licence) for a model prop.

## The Q menu

`PlaygroundSpawnMenu` is a `DotScreen` on a `DotScreenStack`. dot-props provides `categories()`, `in_category()` and `search()` without loading a scene; the menu is the game's.

- **Hold to browse, tap to pin.** One key, not a toggle: a hold is a glance with your place kept; a tap leaves it up while building.
- **Clicking a prop spawns it and the menu stays open.** A menu that only selects makes a wall nine open-and-closes.
- **The menu never spawns anything itself.** It emits; the client asks the server.
- **Six tabs** (props, entities, weapons, tools, builds, addons); **switching clears the filter**, and the search reaches across a tab, not across tabs.
- **The grid is the single source of what is on screen.** `shown()` and `card_for()` read the buttons' metadata rather than re-running the filter.
- **A card is a `Button`**, focusable, so the grid is navigable by gamepad and arrow keys for free.
- **The first card takes focus, not the search box; `/` reaches the search and Enter leaves it.** Focusing the search on open sends WASD into it.
- **An empty grid says why it is empty** (no results vs nothing on this tab).
- **`TabBar.clip_tabs` must be off**: it defaults on, reports a minimum width of about one tab, and hides the others behind scroll arrows.
- The tool gun's settings are a schema-drawn panel; this theme draws no slider track, so the menu gives sliders their own.
- The **Builds** tab asks the server each time it opens ([below](#saved-builds)); offline it says to join one. Build cards have no icon (a build has no single shape).

- **The look is one `DotUiTheme` palette** (`_palette`, rounder than the default) built onto the menu: rounded plate cards with the thumbnail on them, pill tabs and category chips filled with the accent, a rounded search field. The helpers `_box`, `_style_card`, `_style_pill` and `_style_tabs` are the only places a `StyleBoxFlat` is made. Node names and the `shown()`/`card_for()` metadata did not change.
- The **Addons** tab lists what addon hooks registered ([below](#the-addons-folder-hook)); clicking an entry emits `addon_item_chosen("addon/item")`.

## The addons folder hook

An addon dropped into `addons/` that has a file `playground_hook.gd` can add entries to the Addons tab. `PlaygroundAddons` (`game/playground_addons.gd`) scans `res://addons/*/playground_hook.gd` when `Playground` boots, on both ends. **An addon without that file is never loaded or called**: its folder is only listed as skipped.

The hook is a script (a `Node` is added under the game, so it can own nodes) with:

```gdscript
func playground_register(menu) -> void:
    menu.add_item("tornado", "Tornado", _start, "Disasters", "tooltip")   # id, label, callback, category, hint

func playground_receive(msg: Dictionary) -> void: ...   # optional: a client's half
```

`menu` also has `host` (the game node), `authoritative` and `send(dict)`. The callback receives a `PlaygroundAddons.Context` (`authoritative`, `world`, `player_id`, `at` = where the player looks, `send(dict)`) and may return a `DotResult`. **The menu never runs a callback**: connected, the client asks with `ARM_ADDON_ITEM` (an `ARM_PROP` sub-kind, id `addon/item`, payload the aim point) and the server runs it through `Playground.activate_addon_item`; offline the client calls that itself. Whatever a callback `send`s is broadcast as `Kind.ADDON` (addon name and a JSON body, 900 bytes at most) and handed to the hook's `playground_receive` on every client. A hook that does not compile or has no `playground_register` is refused and logged; the game carries on.

`addons/pg_natural_disasters/playground_hook.gd` is the adapter for natural-disasters (which knows nothing of the playground): one entry per registered kind, started where the player looks. It loads the manager by path, so a checkout without `addons/natural_disasters` (an optional symlink) simply has no entries. Not yet: a late joiner is not told about a disaster already running (the addon offers `snapshot()`; the hook does not send it).

A pack that offers weapons, NPCs or bots rather than actions ships `spawn_provider.gd` instead: see [spawn-providers.md](spawn-providers.md).

## NPC tools

Two tool-gun modes and two entities, all inside this repository.

- **Waypoints** (`toolgun/tool_waypoint.gd`, entity `entities/waypoint.gd`): left click lays a frozen point and, with "link each new point" on, links it to the last one; clicking an existing point picks it as the next link's start. Links are `waypoint.links` (authoritative, both ways, dropped when either point is freed); the visible link is a rope in `PlaygroundConstraints` between the two bodies, so it replicates and draws like any rope. Right click removes, reload clears yours. Points are the `waypoints` limit group. `soldier_brain.gd` has a `route` leaf ahead of the heat-map patrol: an NPC with a route of its owner's walks to the nearest point and on along the links, never straight back; with none it behaves as before.
- **NPC spawner** (`toolgun/tool_npc_spawn.gd`, entity `entities/spawn_point.gd`): left click spawns a kind with a chosen weapon (any a NPC can use, "none", or the catalogue's), one to eight in a ring; "lay a spawn point" instead leaves a frozen point that makes one every N seconds up to a limit alive at once. NPCs it spawns are the ordinary armed NPCs, so they shoot (the suite has two tool-spawned NPCs fight).

## The icons are drawn from the definition

`DotPropDef.icon_path` is honoured first; this project ships no prop thumbnails, so `PlaygroundIcons` draws one from **the same three fields the body is built from** (`PlaygroundProp.shape_of` / `extent_of` / `colour_of`): one reading of `meta`, not two. **Cached by what is drawn, not prop id**, so a large catalogue does not build hundreds of images on every Q. **An entity is drawn at a fixed person-shaped aspect**, with the head wider than the body and the body starting below it; at a wanderer's real 0.8 × 1.7 the icon is a coloured bar.

## The tools

`1` and `2`, and each mouse button means something different per tool. dot-props' division: a physics gun builds (arbitrary distance, free rotation, soft spring), a gravity gun is a weapon (one carry position, stiff hold, punt). **Switching tools lets go of everything first** (`DotPropInstance.held_by` allows one holder). **Opening the menu lets go too**, or the held crate follows the cursor round the world.

**F is use.** F presses what you look at within `USE_REACH` (2.6 m) before it gets you into a vehicle (`Playground.use_vehicle` asks `use_prop` first). Not E, which spawns; if E ever becomes a use verb, the two swap together.

## Limits per kind

dot-props counts a `limit_group` per definition (`props`, `npcs`, `entities`, `vehicles`, `balloons`, `weapons`) against `DotPropLimits.group_limits` and asks `DotPropSpawner.limit_resolver` per player. `PlaygroundLimits` is this game's answer: `pg_max_<kind>` cvars (props 200, npcs 10, entities 20, vehicles 4, balloons 30, weapons 20, constraints 100), `pg_limit_roles "admin: npcs=40 props=600; vip: props=300"`, and `pg_limits [player]`. A role is a dot-server admin group (`DotClientSession.groups`) plus `admin` for any admin flag and `root` for the root flag; the most generous role wins, 0 means no limit. **The cost budget's default is 0**: at 64 it was the limit every player met first, with a message about props, before `pg_max_npcs` could say anything. Constraints are not props; the tool gun counts them. A malformed `pg_limit_roles` is refused whole and the old roles kept.

## The tool gun

One weapon with a mode per tool (`swep_toolgun.gd`, modes in `game/toolgun/`, each a script by path): resize, colour, remover, weld, no-collide, rope, balloon, physical properties, NPC weapon, wire, edit. The gun traces, checks ownership (theirs, or anybody's with `touch_others_props`; **not** the physics gun's grab rules, which refuse heavy things and have nothing to do with painting), and hands the mode a hit. Settings travel as JSON on an `ARM_PROP` sub-kind and are clamped to each mode's schema on the server ([netcode.md](netcode.md#the-request-enum-is-full)). R reaches a toy (the reload bit's press goes to `PlaygroundWeapon.reload`).

- **A rope is impulses, not a joint.** Godot has no distance joint and a `PinJoint3D` is a rod; `PlaygroundConstraints` removes the separating velocity and a quarter of the stretch per step, which gives slack. A weld is a fully locked `Generic6DOFJoint3D`; a no-collide is a collision exception both ways. Up to three ropes per prop replicate (`ROPE_SLOTS`, `net_rope_*`, `net_rope1_*`, `net_rope2_*`), drawn by `PlaygroundRopeView`; more than three on both of a rope's props are simulated and not drawn.
- **A balloon is a hidden catalogue entry** counted against `balloons`, lifting with a force rather than negative gravity, so "enough of them lift a car" is arithmetic.
- **A resize is not visible to physics queries until the next step.** A test pressing four times in one frame traces through the crate; wait a step between presses.

### Editing a selected prop

Edit properties (`tool_edit.gd`, last in `SwepToolgun.MODES`): left click selects; from then on the mode's settings **are** that prop (size, colour, frozen, gravity, weight, friction, bounce). Right click lets go; reload restores the catalogue's values except frozen.

- Every other mode's settings say what the next click does; this one's say what the prop is, so it overrides `apply_settings` and writes only what differs.
- **The selection is read off the prop and sent back** (`selection_report`, `Kind.SELECTION` to the asker), because the menu sends the whole settings dictionary on every change, and a menu still holding the last prop's numbers would overwrite the new one on the first slider move.
- `PlaygroundSpawnMenu.set_tool_settings` redraws only when a value differs, or a redraw mid-drag takes the slider from under the mouse.
- Ownership is asked on every change; freezing asks `can_freeze` and the frozen limit, unfreezing neither; a refusal springs the setting back with the reason. Switching mode lets go (`cancel`). Picking the catalogue's own colour removes the paint.
- The outline (`PlaygroundClient.selection_box`, static so the render tool draws the same) is **back faces of a box 8% larger, not a translucent fill**: a fill turned a red crate pink in the one mode whose sliders include colour.

## Buttons, levers and doors

The **Machines** category: a button (says `pressed`), a lever (says `switched`) and a door (hears `toggle`, `open`, `close`; says `opened`, `closed`), wired with dot-props' `DotPropIO` (`Playground.io`) by the tool gun's Wire mode (first click to second, into the input its setting names; right click removes a prop's wires). F was already the use request on the wire, so buttons needed no new message. **A door is a frozen body the server swings** a quarter turn about its left-edge hinge in `DOOR_SECONDS` (0.6) by writing its transform (`_swing_doors`), so it replicates through the prop path. Lever state is a tint, replicated as paint.

## Breaking props and glass

`pg_destruction` (off) lets shots and blasts break props that have health. `PlaygroundSpawnables.BREAKABLE` always declares `max_health` (so the switch is all it takes) for planks, beams, panels, crates, barrels, cans and dice; slabs, pillars and platforms none, because a floor shot from under a build is not the fun kind. `Playground.hurt_prop` is the one door (zee shots, armed NPCs' shots, blasts). A broken prop leaves `debris_pieces` ownerless `debris` props cleaned up after `debris_seconds`, spawned through the spawner so clients draw them. A barrel explodes. **`_breaking` skips whatever is mid-break**: a blast reaches the barrel that made it, and without the guard the first version recursed until the stack ran out. A creative builder's props do not break.

Glass panes in a map are separate (`pg_breakable_glass`, on): see [maps.md](maps.md#glass-and-thin-ice-break).

## Picking players up

The physics gun picks up a PLAYER in its beam before a prop (`PlaygroundPickup`). A held player is a rider with no vehicle: their movement, prediction and any run stop as in a seat, and on the wire it is a SEAT with vehicle 0, which an older client understands. Moved by sweeping the body (a wall stops them); letting go keeps the beam's velocity. Immunity is by role (`pg_pickup_immune`), an override role beats it (`pg_pickup_override`, `root`), `pg_pickup 0` turns it off. **A refusal is an answer**: the prop behind an immune player is not grabbed instead. A seat, respawn, map change or the holder leaving let go.

## Creative mode

`!creative` toggles it; `pg_creative` (on) allows it, and turning it off ends it for everybody. A creative builder is out of the way and out of the fight, **both ways**: their props are protected in dot-props (`DotPropSpawner.set_protected`, which every tool's `may_act_on` and dot-props' damage ask), nobody picks them up and they pick nobody up, and the arena refuses damage to and from them (`PlaygroundArena._adjust_damage`; invulnerable but able to hurt would be the way to win). A fall or pit still reaches them. Switching on releases their props anybody else is holding. Replicated as `net_creative`.

## Prop surfing

Standing on a moving prop carries a player (`prop_surfing`, on; `pg_prop_surf`): dot-props' `DotPropCarry` (`Playground.carry`), asked by `PlaygroundPlayer._ride_prop` after the move, the lift written into the state as well as the node. Riding is resolved on each machine from its own bodies (`ground_id` is a local physics handle). A client mirror has no velocity (frozen, moved by writing position), so `PlaygroundPropNet` records each mirror's velocity as `mirror_velocity` meta and `_ride_prop` uses it. **It is measured from the server's positions per snapshot tick, never from a clock**: the rider feeds it into a predicted tick, and a wall-clock measure made the prediction depend on frame pacing ([history](history.md#the-suites)). A client's switch is its own config's `prop_surfing`, which the cvar does not reach.

**Players must collide with props**: the controller hands the tunables' mask to its body every tick (dot-player-controller), and the mask is set through `set_collision_mask`, never written into the live tunables (a style rebuild drops it). Both were once wrong and every player walked through every prop.

## Saved builds

`pg_save`, `pg_load`, `pg_builds`, `pg_build_delete` (chat or console, as a player). `PlaygroundBuilds` captures everything the player owns relative to where they stand and face, and loads around whoever loads it.

- **A document of catalogue ids**, because it must survive the catalogue changing: id, position, turn, frozen, size and paint, physics only where it differs from the catalogue (applied after the size, because weight multiplies the mass the size gives), welds (a weld to the world as a point in the build's frame), ropes, no-collides and wires.
- A build naming a prop the server lacks is refused, naming every missing id.
- **Whole or not at all**: per-kind limits asked first; a mid-way spawner refusal takes back what this load placed. At most 200 props.
- Kept as JSON in `user://builds/<statistics key>/<name>.json`; a name is letters, digits, `-`, `_`, up to 32; the key is made folder-safe.
- **A custom prop** (`is_custom_prop`) is two or more props all welded into one piece (union-find) and nothing welded to the world; its own category on the Builds tab.

## The map's toys

Separate from props: a toy is part of the map, placed by its author, from dot-props' `toys/` catalogue (a beach ball, a football, a bowling set, barrels, tyres, a punching bag, a swing, a see-saw, a roundabout, a wobbly platform, trampolines, a bounce pad, lamps on a switch, a fountain, a horn, a bell). A map lists them in `map_toys()` (a built-in map's code, or a document's `toys`), and `Playground._build_toys` builds a `DotPropToyBox` from that list on both ends in the same order, as a child of the playground rather than the map: the map's tree is put on the `world` layer when it is ready, which would take the toys with it. The lobby has 27: balls and barrels round its spawn, a bowling lane and a park in its south-west; each of game-playground-maps' twelve has a themed set the builder settles onto clear floor; the two course maps and the generated map have none, so nothing a run could bounce off is on a course.

- **Layers**: a loose toy is on `toy` (added to `sandbox_3d` in `PlaygroundPlayerStack`), which the world, props, vehicles, grenades and other toys stop and a person never does; a toy somebody stands on is on `frozen_prop`; the footprints are on `footprint`. A person is not a rigid body, so `_advance_toys` pushes what each player walks into and puts their weight on a see-saw after everybody moved, on the server.
- **Shots and blasts**: `player_shots_fired` and `npc_shots_fired` ask `shoot_toy` first (dot-props' `shot`, a push reckoned from the damage), and a toy is never also given the prop shove, whose damage-sized impulse sent a beach ball off at 40 m/s. A grenade's detonation and a breaking barrel's blast call `blast_toys`; `PlaygroundProjectiles._blast` skips toys for the same reason.
- **F** takes a toy looked at (2.6 m) before any prop: a kick, a push, a switch, a honk.
- **The trampolines and pads** are `PlaygroundPlayer._launch_from_toy`, after the move, on every end that simulates the player, so a predicting client is thrown on the tick the server is; the server counts the bounce. **The roundabout** carries whoever stands on it through `_ride_prop`: `DotPropCarry.toys` is the box, so prop surfing's own call does it, and with `pg_prop_surfing` off the box is asked directly, because the roundabout is part of the map and not a prop somebody spawned to ride.
- `sv_toys`, `sv_toys_awake` and `sv_toys_push` are dot-props' cvars, bound by the module REPLICATED and followed by the client. The awake cap is 24, or 8 in a browser build.
- Toys stay where they are kicked for the life of the map; a map change builds them again. A toy below -60 m goes home.


## Subscribed packs in the Q menu (solo only)

`provides.json` declares what the game `accepts` from the content index: kinds weapon, prop, npc, entity, tool and map (map kinds sandbox, surf, bhop, kz, race). `tool` is declared but nothing consumes it yet. `PlaygroundWorkshop` (`game/playground_workshop.gd`) is the one adapter: it follows a `DotContentIndex`, turns weapon listings (via `DotWeaponCatalogue.follow_content`) into `PlaygroundWeaponDef`s and prop, npc and entity rows into `DotPropDef`s (ids prefixed `ws_`, `meta.pack` set), and hands the menu `rows()` grouped by pack title and category. The spawn menu adds one tab per pack after Addons and keeps pack defs out of its built-in Props, Entities and Weapons tabs. Maps follow content through `DotMapCatalogue.follow_content`.

Only the offline client follows (`link == null and bridge == null`): a dedicated server and a connected client never do, so in an online session the pack entries disappear and the pack tab goes. Pack rigs use `PlaygroundZee.catalogue_for(def)`, a copy, so a subscription never leaks into the table a server reads.

dot-props and dot-npc have no `follow_content` yet; when they gain one, `_prop_def` leaves this file. Pack weapons that are not zee ids have no world model or art, and there is no right-click drop for them.
