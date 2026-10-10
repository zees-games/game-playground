# game-playground

**A sandbox first**, in the classic physics-sandbox shape: hold Q, pick a prop, an
NPC or a
weapon, click it and it is yours; hold a prop with a physics gun, freeze it, throw it,
undo it. With map support, and with dot-timer kept — on a jump course in the corner of
the sandbox rather than only on the surf and bhop maps, because that is what says the
timer is not a surf-and-bhop thing.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and
each addon's own `CLAUDE.md` before working in it. This file is only about the joins.

## What this project is for

**It is the only place dot-player-controller, dot-timer, dot-map, dot-props, dot-npc and
dot-leaderboard run together**, and by the family's own repeated lesson that is where
everything is found. Every one of those addons has a suite, every suite passes with
the others absent, and that proves very little: the bugs that have cost days here were
all in seams — a bridge reconciling on top of another bridge, a message keyed on the
wrong id, a value computed and consumed by nothing.

`examples/headless_playground.tscn` is the point of the repository. It boots the whole
game, drives a bot down a surf map, finishes a run, files it, ranks it, spawns props
and checks their bodies were built from their definitions, opens the spawn menu on a
real `DotScreenStack` and clicks a prop in it, runs the sandbox's own course and falls
off it, spawns NPCs and watches one walk toward the player, fires a weapon loaded from a
script path, and changes the map underneath all of it. **359 checks, and it has now
found nine real bugs — three of them in other repositories** — which undercounts it
since; the later ones are in the sections below. Three more were found by
a screenshot, which no assertion could have.

It is also playable: `game/playground.tscn` is a first-person client with a spawn
menu, a crosshair and a HUD.


## The moderator's live tools in a sandbox with a clock in the corner

dot-moderation's live tools are built in the module (`PlaygroundModTools`), because health belongs to the arena layer, which is the module's. Noclip, freeze, speed and gravity are predicted modifiers; god, buddha, hp and slay act on the arena's `DotHealth` and say "the arena is off" when `pg_arena` is — whether they mean anything is a cvar, not a build; slap shoves with or without it; respawn is the course start; teleports end the course run.

The course is timed, so the timer server's rule holds here too: **an admin's help can never make a time.** Noclip abandons the run it interrupts and `PlaygroundPlayer` taints every run while a noclip, a speed step or a gravity step is on. A slap taints the run it lands in (0f07ed3; armed 2026-09-24 — without the `taint()` dedicated's check fails). Give and strip are refused, so there is no admin's weapon to taint a run with (game-g2gfast's f147b63 taints for one because it gives): what a player holds here is the physics gun, the gravity gun and a loadout they chose.

**Blind and beacon were refused as "no client overlay" until 2026-09-24, and are two flags now**, on game-arena's pattern (0e818b3). `PlaygroundPlayer.blinded` and `.beacon` are set by the handlers on the server and replicated as per-player state in `PlaygroundPlayerNet` — `net_blind` **owner-only**, because nobody else's screen changes and with the arena on an opponent who could read it would know when somebody could not see them; `net_beacon` to everybody. State rather than an event, so a joiner and a lost snapshot are corrected by the next snapshot. **No relevance change for the beacon**: every player here is already `always_relevant` (`PlaygroundNetBridge._build_entity`), and a beacon that turned relevance off when lifted would cut the player out of everybody's world. The client draws both: `PlaygroundHud.blind_overlay` fades a near-black rect in under the HUD's widgets, sized to the whole viewport; `PlaygroundClient._present_beacons` calls `PlaygroundPlayer.present_beacon` for every player once a frame — the server calls nothing that draws, so a dedicated server builds no marker — and `PlaygroundBeacon` is the ring, a ripple once a second and a column through walls (not in your own first-person view), with each ripple played as `PlaygroundPresentation.BEACON_SOUND`, a positional BLIP an octave under the vote warning that carries 160 m. Neither touches the timer: a blinded run is harder, not assisted.

**Both outlive a respawn without being told to, and so does everything else.** A respawn here — the admin's, the course's, the arena's — is a teleport of the same body (`Playground.spawn_player`), so nothing a handler set is lost and `DotModTools.respawned` is never called. That is the right answer for blind and beacon, which are about the person; it also means a noclip and a freeze survive a respawn here where game-arena ends them with the body.

`dedicated`'s **blind and beacon** types both at a real server's console and asserts the flags, the replicated field, the timed lift, the respawn and `modtools` (armed by clearing the beacon on respawn); `headless_net`'s **who is told** adds a second player on a peer with no client in the process, so this suite's client is "somebody else" for them — never told they are blind, drawing their beacon — and is told its own blind (armed by dropping `to_owner_only()`: two fired, one of them reading `net_blind = true` off the wire); `headless_playground` drives the real client's frame hooks — one ping as it comes on and one a second, the marker at the simulated position, no column in your own eyes, the blind covering the viewport under the widgets (armed by skipping the client's call and the overlay's sizing: both fired). `tools/screenshot_views.sh` renders `admin_beacon`, `admin_beacon_wall` (a wall hides the ring and not the column) and `admin_blind`.

**What rendering them found, and it is not about the beacon.** Every first-person frame the tool took after `view_third_person` was from the third-person rig's camera — four metres behind the player, body hidden — because nothing made the first-person camera current again; it looked like first person until something stood in front of the player. And a **remote player's body is not drawn at all**: a player with no view switch is `set_shown(false)`, and forced visible, `PlaygroundCharacter`'s rig — a `Node3D` under a plain-`Node` component — stands at the world origin whatever the player's position. It went unseen because the only body ever rendered belonged to a player standing at the origin. The first is fixed in the tool; the second was fixed the same day — see "Somebody else's body, on a connected client" below — and `admin_beacon` now shows the body inside its ring.

## Layout

```
game/
  playground.gd          the simulation: maps, timers, props, boards. Headless
  playground_config.gd   what an operator configures, layered
  playground_module.gd   the DotServer bridge: every console command
  playground_client.gd   one local player, a camera, a HUD, the keys. Not headless
  playground_player.gd   the bridge: movement, timer, style, tools
  playground_spawn_menu.gd  the Q menu: five tabs (props, entities, weapons, tools, builds), categories, search, icon cards
  playground_icons.gd    icons drawn from a definition, because this ships no art
  playground_spawnables.gd  the catalogue, and what "kind" a definition is
  playground_prop.gd     one prop, built from its DotPropDef. One scene, fourteen props
  playground_weapons.gd  the arsenal, and how a script becomes a weapon
  playground_zee.gd      zee-dot-weapons beside the toys: defs, a rig per player, shots that shove
  entities/
    playground_entity.gd   a prop with a script, ticked by the simulation
    npc_*.gd               the shipped NPCs. `extends` a PATH, deliberately
  weapons/
    playground_weapon_def.gd  one weapon, as a document
    playground_weapon.gd      the base: two buttons and a tick. Extends DotPropTool
    swep_*.gd                 the shipped weapons. `extends` a PATH, deliberately
  playground_inventory.gd  the bag: an item per prop, one bag per person, give/take/may_give
  net/playground_inventory_net.gd  the bag over dot-net: ops with sequence numbers, acks, whole-bag corrections
  playground_hud.gd      the clock, the speed, the crosshair, what is in your hands, a blind
  playground_beacon.gd   an admin's beacon: a ring, a ripple and a column through walls
  playground_geometry.gd dev-textured boxes and ramps, in code
  playground_map.gd      base for the built-in maps
  playground_map_survey.gd  slots, unreached ground and traps, swept over a built map's boxes
  prop.tscn / entity.tscn  one scene for every prop, one for every entity
maps/
  pg_lobby.gd            the sandbox: the jump course, the tower, the circuit, the stepping stones and the launch on bonus 1-5
  pg_surf_intro.gd       two ramps and a valley, the plunge on bonus 1, the cascade on bonus 2, the long bank on bonus 3
  pg_bhop_intro.gd       blocks with widening gaps, the narrows on bonus 1, the switchback on bonus 2, the ascent on bonus 3, the ladder on bonus 4, the float on bonus 5, the drop on bonus 6
  *.zones.json           generated from the maps, and checked against them
tools/
  export_zones.gd        writes those files. Run it after changing a map
  screenshot_net.gd/.sh  a CONNECTED client watching another player, with a jitter probe;
                         --walk: its own player, key-to-motion ticks and eye speed
examples/
  headless_playground.gd the integration suite
  dedicated.gd           a real DotServer, the module, and its commands
```

## The joins, and what each one gets wrong first

### The game owns the tick loop

`DotFpsController.Drive.EXTERNAL`, not `LOCAL`, even in single player.

In `LOCAL` the controller accumulates frame time and ticks itself, so the timer would
be fed from a signal fired inside somebody else's loop — and a bot could not be driven
at all. `Playground._simulate_tick` owns it instead, which makes the order explicit:

1. `props.advance(step)`
2. every player: sample (if local), then `controller.simulate_tick`
3. every player: `timers.tick_player` with the position the move **just produced**

**Step 3 must come after step 2.** The timer works out whether the player crossed a
line during this tick from where they were and where they now are; ticking it first
shifts every run by exactly one tick, and by a *different* amount at each tickrate —
which is precisely the tickrate dependence dot-timer's sub-tick fractions exist to
remove.

It is also the same shape a dot-net bridge and a dedicated server use, so nothing has
to be rearranged when one arrives.

### `body_ref` must not be `of_self()`

`DotNodeRef.of_self()` on the controller resolves to the **controller**, which is a
plain `Node`. `setup()` then refuses with "the player body must be a Node3D", the
controller never starts, `motor` stays null, and the player simply never moves. Leave
it unset: it defaults to the parent, which is the `Node3D` the movement drives.

This cost the first run of the integration suite nine failures, all of which pointed
somewhere else — no movement, no run, no statistics, no style effect.

### A style has two halves and they move together

`DotFpsStyle` transforms the tunables and filters the command; `DotTimerStyle` says
whether the run counts and what it is worth. `PlaygroundPlayer.set_style` applies
both. Applying one alone gives a run timed as "normal" while the player is actually
sideways, or the reverse — and nothing errors either way.

`DotFpsController.set_style` **rebuilds the motor**, which assigning the property
alone does not; the suite checks that specifically, because it is the way this is most
likely to be used wrongly.

### The timer decides and the game acts

`DotTimer` never moves a player. `Playground._on_effect_requested` turns a
`RESPAWN`, `TELEPORT` or `SLAY` zone into something that happens, because what those
mean is different in a first-person game, a 2D game and a replay being scrubbed.

The effects that change *where the player ends up* — a prespeed clamp, a speed-limit
zone — are read straight off the timer inside `PlaygroundPlayer._on_simulated`, on the
tick, rather than from a signal. Clamping a player's velocity is part of the
simulation, and doing it when a signal happens to arrive puts it a tick late.

### Statistics land when the run ends, which is when it is no longer active

`DotTimerManager.note_stats` originally guarded on "only while the run is active",
which silently discarded the one call that matters — the natural moment to fold in a
run's statistics is the moment it finishes. The suite caught it as a record whose
`stats` dictionary was empty, with no error anywhere, because refusing to write a
statistic is a legitimate thing for a timer with no run to do. Fixed in dot-timer.

### A map change happens with everything in flight

`_on_map_changing` runs **before** anything is torn down: it stops every run, makes
every tool let go, and clears the props — all of which are parented to, or standing
on, geometry that is about to be freed. dot-map's own ordering then loads the new
scene before freeing the old one, so a failure leaves the server on a working map.

**The prespeed clamp was dead.** `PlaygroundPlayer` asked
`timer.is_inside(DotTimerZone.Kind.START)`, which answers only for *effect* zones —
speed limits, freestyle, easy-bhop — and is always false for START, so a player could
carry any speed out of the pad. `in_zone` is the membership query. game-g2gfast had the
same line, its netcode suite found it, and the fix landed in both on the same day. The
lesson is the family's usual one: a guard that never fires looks exactly like a guard
that was never needed.

## What building the sandbox found

Three, all in other repositories, and all three the family's own recurring shape. Every
one parsed cleanly and none produced an error where it was written.

- **`DotTimer.effect_requested` was emitted by nothing at all.** The signal was
  declared, `DotTimerManager` forwarded it, and both this game and game-g2gfast
  connected a handler — so `RESPAWN`, `SLAY` and `TELEPORT` zones did nothing,
  anywhere, and a player who fell off a surf map fell for ever. Nothing errored,
  because a zone kind the timer has no rule for is a legitimate thing to find and the
  whole design says the timer must not act on one itself. It is the family's commonest
  pattern with the ends swapped: not a value produced and consumed by nothing, but a
  value **consumed by two games and produced by nobody**. Fixed in dot-timer, which now
  fires it once on entry, track-filtered, after the tick is complete.

  It was found by needing a course a player could fall off. It also **quietly invalidated
  a passing test**: game-g2gfast's "most of the descent is spent not grounded, which is
  surf" counted 1500 ticks of a bot that had missed the ramps and was falling through
  the void, none of which was surfing. With the respawn working, the bot is put back
  after ~500 ticks and is airborne for 94% of them, which is what the check was always
  meant to say.

- **`DotPropDef.mass` was not put on the body.** See "One scene, fourteen props" below.
  Only visible in a project where every prop is the same scene.

- **`set_anchors_preset` does not set offsets, and dot-ui had five of them.** The
  family's own CLAUDE.md has warned about this since dot-ui was written — "a `Control`
  built in code keeps the zero size it was created with, so the whole interface lays out
  inside nothing and is invisible while being, by every property, correctly configured"
  — and `DotScreenStack` itself, plus `DotCrosshair`, `DotHud` and `DotTableView`, all
  still had it. Nothing in dot-ui's own suite measured a size. The spawn menu here was
  the first screen anybody built on a stack whose parent is a plain `Node`, and it came
  out 0 × 0. All five now use `set_anchors_and_offsets_preset`, and both suites check a
  size rather than a property.

And two here, both of which say the same thing about signals:

- **A signal is not a state.** `PlaygroundClient` waited for the playground to finish
  booting with `await playground.ready_for_players`, and `Playground.change_map` can
  complete **without ever suspending** — a built-in map is a scene already in the
  build — so the playground finished booting inside `add_child` and the signal had
  already been emitted by the time the client reached its `await`. The client then
  waited for ever. **The symptom is a black screen with no error at all**: no camera,
  no HUD, no player, no failed load, nothing in the log. It is the family's own
  GDScript fan-out trap in its smallest form, and the fix is the same one:
  `if not playground.booted: await playground.ready_for_players`. No test caught it,
  because every test drives `Playground` directly; a screenshot caught it in one look.
- **A GDScript lambda captures locals by value**, which is already in the family's
  conventions: the first version of the respawn fix above broke out of a loop on a
  `bool` set inside a signal handler and reported "468 of 1500". Capture an `Array`.

**Two of the four wanted a screenshot rather than a test.** The 0 × 0 menu and the
black screen were both invisible to every assertion available — one because every
property was right, the other because nothing had failed. `tools/screenshot.sh` in
`game-dev/` renders this project on a machine with no display; it is not optional
after touching the client.

Building the entities, the weapons and the icon cards on top of that found three more,
and **every one of the three was a screenshot again**:

- **`TabBar.clip_tabs` defaults to on**, so the bar reported a minimum width of about
  one tab, hid the other two behind scroll arrows, and let the `HBoxContainer` lay the
  heading out underneath it. Two of the three tabs were unreachable and "Spawn" was
  drawn through "Props". Every property was correct.
- **The entity icon's torso covered its head.** The torso spanned the full height at
  0.62 of the half-width and the head sat at 0.42 of it, entirely inside — so every
  NPC in the menu was a coloured bar. A head has to be wider than the body and the body
  has to start below it.
- **A bot keeps the last command it was given.** `DotFpsController.apply_command` sets
  the pending command and it stays set, so the bot arrived in the entity test still
  holding forward and jump from the bhop test several tests earlier and auto-hopped
  across the sandbox for the whole of it. "Does the chaser close the distance" was
  measuring a player running away. Not a product bug — but a test that drives a bot and
  then stops driving it is a test with a bot that is still driving.

## The sandbox half

### One scene, fourteen props

`game/prop.tscn` is the only prop scene in the project and it has no shape, no mesh and
no mass in it. What makes a plank a plank is three fields of its `DotPropDef.meta` —
`shape`, `extent`, `colour` — which `PlaygroundProp.configure` turns into a collision
shape and an unshaded box. A server with real content points `scene_path` at its own
scenes and never loads this file at all, which is the seam `DotPropDef` was designed
around: the definition is checkable without loading anything, and the scene is fetched
only when something is actually created.

**The body is built by `configure`, not by `_ready`.** `DotPropSpawner` instantiates
the scene, places it, adds it to the world and *then* emits `spawned` — so the
definition is not available until after the node is in the tree, and a `_ready` that
built a default box would build one that is immediately thrown away. A prop nobody
configured has no collision shape and no mesh: it falls through the floor, is
invisible, and cannot be grabbed, which is three symptoms all pointing somewhere else.
So `_ready` schedules a deferred check that says so, loudly, once.

**`DotPropDef.mass` used to be a number nothing simulated.** It is read in exactly one
place in dot-props — `DotPropTool.may_act_on`, against `grab_mass_limit` — and the body
kept whatever mass its scene was saved with. A catalogue that says 900 kg over a scene
saved at 20 kg gives a prop a physics gun refuses for being too heavy and a gravity gun
throws like a beach ball, with nothing erroring and the two numbers only ever compared
by a player wondering why. `DotPropSpawner` now puts it on the body before the body
enters the tree — earlier than the first physics step, because dot-props' own suite
already found that a mass set *after* an impulse divides that impulse by the old mass.
Fixed in dot-props; this repository is where it showed, because every prop here is the
same scene and the mass is the only thing distinguishing them.

### An entity is a prop with a script, and the script is named by a PATH

This is the division every sandbox of this kind makes, and it is the right one: a
crate is a shape with a
mass and needs no code, and a thing that walks about needs code. dot-props knows
nothing of the difference — it instantiates a scene, places it and counts it against a
budget — so the difference is two fields of `DotPropDef.meta`:

```json
{ "kind": "entity", "script": "res://game/entities/npc_wanderer.gd" }
```

`Playground._configure_entity` loads it and attaches it to the bare `RigidBody3D` that
`entity.tscn` is. That is the whole mechanism.

**The script is named by a path, and that is not a style choice.** A game delivered
through dot-cloud is a mounted `.pck`, and **a mounted pack's `class_name` globals are
not registered in the host** — measured, and written down in the family's own
CLAUDE.md. Every cross-file type reference inside a pack fails to compile; `preload`
and `extends` by path both work. A catalogue that named a class could therefore only
ever ship inside the build. The shipped entities are written the same way —
`extends "res://game/entities/playground_entity.gd"` — because they are the template a
pack copies, and if that path ever stopped working they would stop with it.

**`_ready` has already run by the time the script is attached.** The spawner adds the
body to the world and *then* emits `spawned`, so nothing in an entity may rely on
`_ready`; the base has `_entity_ready` and `bind` instead. This is the same ordering
`PlaygroundProp.configure` exists for.

**A failure removes the prop rather than leaving it.** A body whose script did not load
sits there being a crate, which is indistinguishable from an NPC that has nothing to
do — and "the NPC does not move" sends the next person to the movement code. Both
failure shapes are checked and both are loud: a path that is not there, and a path that
is a real script which is not an entity. The second is the one a copy-paste actually
produces.

**An entity extends `PlaygroundProp`, so it is a prop to everything else.** It counts
against a budget, it can be undone, it goes when its owner leaves, a physics gun can
pick it up and a gravity gun can punt it. An NPC you cannot pick up is the first thing
a sandbox player will try.

**A held entity stops driving itself.** Otherwise it fights the physics gun's spring —
the gun writes a velocity toward the goal, the NPC writes one toward wherever it was
walking, the prop shudders between them and the player concludes the gun is broken.

**Entities tick before players**, from `Playground._simulate_tick`, at the simulation's
fixed rate. Not `_process`, which would make an NPC's speed a function of the frame
rate; not after the players, which would leave a chaser visibly a tick behind its
target at exactly the rate the server ticks.

### Perception is dot-npc's; being a prop is still dot-props'

The entities were ported onto **dot-npc** for the half they were getting wrong, and
deliberately *not* onto its spawner.

**What moved.** The chaser called `nearest_player()` on every one of the 128 ticks a
second this game runs at. That is the classic broken NPC and both of its failures are
reachable in a sandbox in about ten seconds: two players standing a metre apart make it
turn back and forth for ever, and one who steps out of range makes it forget instantly
and walk away mid-stride. `DotNpcSenses` acquires at one threshold, drops at a weaker
one, and keeps chasing for a grace period measured from the **last sighting** rather
than from acquisition. `PlaygroundEntity.target()` is the whole interface;
`nearest_player()` is still there and still correct for what it says, which is what the
spinner wants.

The perception envelope is a catalogue field — `sight`, `sight_angle`, `hearing`,
`line_of_sight` in `meta` — for the reason `tune` exists. It replaced a `give_up_range`
the chaser applied by hand, and giving up is now what happens when a target leaves the
envelope and the grace expires.

**What did not move, and why.** An entity here is a `DotPropInstance` first: it counts
against a prop budget, it can be undone, it goes when its owner leaves, a physics gun
can pick it up and a gravity gun can punt it across the map. Spawning these through
`DotNpcSpawner` would have taken all of that away in exchange for a second population
system this game does not need. **An NPC you cannot pick up is the first thing a sandbox
player will try.** So dot-npc is installed here for its senses and its instance row, and
`dot-npc-ai` and `dot-npc-ai-director` are not installed at all — a sandbox has no
pacing to direct.

**The candidate list is built once per tick, before the entities run.** Once per tick
and not once per entity, because twenty NPCs each building their own list of eight
players is a hundred and sixty allocations a tick for a list that does not differ
between them. Before rather than after, because a list built at the end of a tick is a
list of where everybody *was*, which is the one-tick lag the entity ordering already
exists to avoid.

**A target who disconnects is dropped immediately** rather than being left to the grace
period. The grace exists so a doorway is not a perfect escape; a player who has left has
no position at all, and steering at their last one walks the NPC into an empty corner for
two and a half seconds.

### A weapon is a script too, and it is not in the prop catalogue

Same mechanism, different registry. `PlaygroundWeapons.make` loads a path, instantiates
it, and checks the result actually *is* a `PlaygroundWeapon` — because a script that is
valid GDScript but extends the wrong thing constructs perfectly and then has none of
the methods the client calls, and the first symptom is a crash inside a mouse handler.

**Weapons are deliberately not `DotPropDef`s.** dot-props' catalogue is "things you
spawn into the world" and requires a `scene_path`, because that is what a spawn needs.
A weapon is never spawned and has no body. Giving one a scene path so it would fit is
the sort of lie that becomes "why does this crate have no collision". The player sees
three tabs; underneath, one of them is a different system, and it is different for a
reason.

**`PlaygroundWeapon` extends `DotPropTool`**, which is most of the work: the spawner,
the wielder, the reach, a `target()` that resolves a ray to a prop, and a
`may_act_on()` that asks the *host* the ownership question rather than answering it.
A physics gun and a gravity gun are the two dot-props ships; these are the game's own,
and they are the same kind of object — not a node, no camera, handed an origin and a
direction so the same weapon works for a player, a bot, a replay and a headless test.

**A muzzle velocity is not an impulse, and the arsenal uses both on purpose.**
`PlaygroundWeapon.launch` writes a velocity: an impulse is divided by the mass, which
is right for a punt and exactly wrong for a launcher, whose boulder would otherwise
leave at a fortieth of the speed of its ball. `swep_impulse` does the opposite for the
opposite reason — a shockwave *should* throw a beach ball further than a boulder.

**Tuning lives in the definition, not in the script.** It is what lets one script serve
three catalogue entries — `npc_wanderer` and `npc_hopper` are the same file at
different speeds — and it is the only half of an entity an operator editing a JSON
catalogue can reach.

### The Q menu

`PlaygroundSpawnMenu` is a `DotScreen` on a `DotScreenStack`, and dot-props is right
that it belongs here: "a menu of four hundred props with icons and a search box is a
game's own design". What the addon does provide is everything the menu needs **without
loading a single scene** — `categories()`, `in_category()` and `search()` all read
fields of a `DotPropDef`.

Three behaviours come straight from the sandboxes this copies, and each is a decision:

- **Hold to browse, tap to pin.** One key, two behaviours, and not a toggle: holding
  shows the menu for as long as you hold it, which is a glance with your place kept;
  tapping leaves it up, which is what you want while building. A plain toggle loses the
  glance and a plain hold means you cannot let go of the mouse.
- **Clicking a prop spawns it**, and the menu stays open. A menu that only *selects*
  means every prop costs two actions and a wall is nine open-and-closes.
- **The menu never spawns anything itself.** It emits and the client asks the server,
  which is the same division the tools make and the reason the file works unchanged
  when a dot-net bridge arrives and a spawn becomes a message.

**Three tabs — props, entities, weapons — and switching one clears the filter.**
Carrying "containers" onto the weapons tab shows nothing and reads as the tab being
broken. The search reaches across the whole tab but not across tabs: a player typing
"barrel" wants the barrel and not "you are on the Toys tab", and a weapon turning up in
a prop search is not a result, it is a surprise.

**The grid is the single source of what is on screen.** `shown()` and `card_for()` read
the buttons' own metadata rather than re-running the filter, because a second copy of a
filter is a second thing that can disagree with the first — and the copy that would be
wrong is the one nobody is looking at.

**A card is a `Button`, not a container.** A Button is focusable and a `VBoxContainer`
is not, so Godot's own focus neighbours make the whole grid navigable with a gamepad or
the arrow keys for free — and a menu that cannot be used without a mouse is exactly the
failure dot-ui's `initial_focus` exists to prevent. Icon above text is
`vertical_icon_alignment`, which is what that property is for.

**The first card takes focus, not the search box, and `/` is what reaches the search.**
Focusing the search box on open sends W, A, S and D into it: the player stands still
typing "wasd" while the menu looks exactly as it should. This is a menu you can walk
around with, so the search needs a key that is not a movement key — and Enter puts the
keyboard back, because otherwise there is no way out of the box that is not the mouse.

**An empty grid says why it is empty.** A search with no results and a tab with nothing
on it look identical when both are blank, and the player's next move is different.

### The icons are drawn from the definition

`DotPropDef.icon_path` is honoured first and almost never set here: a server with
content points it at a thumbnail and that is what the menu shows. This project ships no
art, and a grid of forty identical grey squares is worse than a grid of names — so when
the field is empty `PlaygroundIcons` draws one from **the same three fields the body is
built from**. A barrel is a green cylinder in the world and a green cylinder in the
menu, at the right aspect ratio, because both read `meta` through
`PlaygroundProp.shape_of` / `extent_of` / `colour_of`. A second copy of "what does meta
mean" is a second thing that can disagree with the first.

**Cached by what is drawn, not by prop id.** Fourteen props share four silhouettes and
eleven colours, and a four-hundred-prop catalogue shares far more. A menu that built
four hundred images on open would hitch every time somebody pressed Q.

**An entity is drawn at a fixed, person-shaped aspect rather than its body's.** A
wanderer is a 0.8 by 1.7 box, and at that ratio the head is three pixels across and the
icon reads as a coloured bar.

### The tools are two, and they behave differently

`1` and `2`, and both mouse buttons mean something different depending on which is in
hand. That is dot-props' own division — a physics gun is a building tool with arbitrary
distance, free rotation and a soft spring; a gravity gun is a weapon with one carrying
position, a stiff hold and a punt — and shipping one and calling it both gives a
building tool that cannot throw.

**Switching tools lets go of everything first.** `DotPropInstance.held_by` allows one
holder, so a gravity gun still carrying a crate makes the physics gun's grab do
nothing — with nothing on screen to say why.

**Opening the menu lets go too.** The mouse is about to become a cursor, and a physics
gun still holding a crate would drag it round the world following a pointer the player
is aiming at buttons with.

## The timer is not a surf-and-bhop thing, and `pg_lobby` is where that is said

`pg_lobby` is a sandbox on the **main** track, a twelve-platform jump course on
**bonus 1** and a sixteen-platform spiral tower on **bonus 2**, and all three are
deliberate.

The main track has no start zone and no end zone, so a player building on the plate is
on a map with no timer — which is what `pg_lobby` has always been for, and the one
thing proving the rest of the game does not quietly require one. Putting the course on
a bonus track keeps that *and* adds a minigame, and the mixed case is a better test than
the empty one because it is the case a real sandbox server is in.

Nothing about a jump course is a movement genre. It is zones drawn round platforms, and
the same sub-tick fractions, styles, records and replays apply to it — which is the
whole claim `dot-timer` makes by depending on nothing but dot-core.

**The reset volume is on the bonus track, and that track filter is what makes it
usable.** It is the air just above the sandbox floor under the course: a player on
bonus 1 who falls off touches it and goes back to the start pad, and a player on the
main track walking through the same corner with a physics gun is not touched at all.
`DotTimer` filters zones by the run's track before it acts on any of them.

### Bonus 2 is a different skill, not a longer bonus 1

A second route through a map players already know is worth more than a fifth map nobody
has learned, and the two courses are deliberately asking different questions. Bonus 1 is
a straight line with widening gaps: **how far can you jump.** Bonus 2 is a spiral
climbing a pillar, so every jump is a turning one: **can you keep your speed round a
corner**, which in an arena-shooter controller is air-strafing and is the thing the movement
is actually about.

Three things about it that are not visible in any count, and one of them was a real bug:

- **The splits are height bands, not lines.** A vertical line across a spiral is crossed
  twice per turn, so a stage drawn the way bonus 1's is would fire on the way round as
  well as on the way up. The thing that only happens once on a tower is reaching a
  height, so that is what is measured.
- **The pillar starts at the top of the pad, not at the floor.** The first version ran it
  from `y = 0`, which put a 2.4 m column straight up through the middle of the start pad
  — so the player spawned *inside* it and could not move. Every count passed: the pad was
  there, the platforms were there, the zones were right. What found it was a bot that
  reported it had not gone anywhere.
- **The tower's start pad is smaller than the jump course's**, because an 8 m pad reaches
  5.66 m at its corners and the first platform's inner edge is at 4.9 m — so the two
  overlap and the first jump of a jumping course is a walk. Nothing about that is visible
  from above.

**The spawn yaw is derived, and the sign convention bit.** `DotFpsMotor._view_basis`
builds forward as `(-sin(yaw), 0, -cos(yaw))`, so facing a direction is
`atan2(-dx, -dz)`; the obvious `atan2(dx, dz)` is 180 degrees out *and* mirrored. A
spiral has no obvious forward, so a player spawning with their back to it has to find the
course before they can start it — the bot caught it as a dot product of exactly -1.
**And then it did not survive a tick** — see "A spawn yaw lasted no ticks" below.

### Bonus 2 is run end to end now, and "a bot cannot" was about the bot

The written reason the tower had no drive was that a spiral is finished by air-strafing
round a corner. Measured, it is not. Every gap on the tower is **2.04 m of air against a
4.02 m climbing reach** — the platforms are axis-aligned squares 45 degrees apart round a
circle, so their nearest edges are closer than the 4.59 m between their centres says — and
nobody has to carry speed round anything. They have to **face the next platform before
jumping at it**, which a scripted bot can do exactly and which no bot in this family had
ever been written to do: every one held a single yaw for its whole run, so a course that
turned was one it could only fall off.

`headless_playground::_drive_route` is that bot, and it is generic: a map declares a
route as the list of boxes a player lands on (`PgLobby.tower_route()`,
`PgLobby.course_route()`, `PgBhopIntro.switchback_route()`), read off the same functions
the geometry is built from, and the bot drives any of them. Three rules, each a thing a
player does. **Wish along the error** — the velocity it wants minus the one it has — not
along the heading: a wish along the velocity adds nothing in the air once the speed is past
`max_air_wish_speed`, and on the ground it carries the last jump's direction into this one,
which is how the first version fell off platform 4 every time. **Jump on the last grounded
tick before the edge, or once the next box is within a metre**, whichever is first: the
tower's first platform has its underside 0.2 m above the pad and 0.2 m off its corner, so a
jump taken at the lip puts the body into its side face and kills every bit of horizontal
speed. **What it stands on is decided by where it is**, so a fall onto a lower turn simply
resumes from there. It climbs all seventeen jumps through both height bands in 1,672 ticks
without once being put back on the pad.

**And the check over the tower's gaps was the jump course's bug, one corner over.**
`_test_the_tower` took its reach from a *flat* jump (airborne `2v/g`) off
`DotFpsTunables.new()` — the addon's defaults, with a jump height of 1.1 where the server
applies 1.15 — so it called 4.64 m a jump on a course that climbs 0.6 m a step, where the
real number is 4.02. It measured the pad-to-first-platform step as centre distance minus a
width, which called 0.2 m of air 3.8 m, and it stopped at the sixteenth platform, so the
inward jump onto the finish cap — the widest on the tower at 2.40 m — was measured by
nothing. The geometry happened to be fine; the check would have passed a 4.3 m gap nobody
can cross, and `_the_old_tower_rule_passes_an_unjumpable_gap` now says so. Every route is
swept box to box by `_check_route_reach` against `PlaygroundMap.jump_reach(rise)`, which
also **prints** the tightest jump on each route whether it passes or not.

`MOVE_SPEED`, `JUMP_HEIGHT`, `MOVE_GRAVITY`, `jump_reach` and `gap_between` moved from
`pg_lobby` to `PlaygroundMap`, because a second map needed them and a second copy is a
second thing to disagree with the first. `PgLobby.jump_reach` still answers, by
inheritance, and the suite still asserts the three constants against the tunables the
server applies.

Since `[reach-3]` `PlaygroundMap.jump_reach` is no longer a copy of the arithmetic: it asks `DotFpsTunables.jump_reach` on `PlaygroundPlayer.movement_tunables()`, the static builder `_tunables()` now returns, so maps with no player in the tree ask the movement itself (numbers unchanged: 4.75 m flat, 0.0 at a 2.0 m rise); the three constants stay for laying out geometry and are still asserted.

Since `[pg-climb-margin-1]` what counts as a climb is `PlaygroundMap.climb_limit()` (the same tunables' `climb_limit()`, apex × `CLIMB_MARGIN` 0.9 = 1.035 m, the family rule) in `PlaygroundMapSurvey` (jump links and `_too_tall`) and in `_jump_is_inside` / the no-step-is-a-wall check, not the 1.15 m apex; no built-in route changed, since the tallest step anywhere is 0.8 m (the jump course), and the ramp check that every ramp out-climbs a jump still uses the apex on purpose.

### A spawn yaw lasted no ticks

**`PlaygroundPlayer.teleport` wrote `controller.state.yaw` directly, and a yaw written
there lasts exactly until the next tick.** A `DotFpsCommand` carries *absolute* view
angles, so the tick after a teleport sets the view back to whatever the command says: for
a client, the player's own `sampler`, which had never been told and still faced wherever
the mouse last left it; for a bot, or anybody with no command that tick,
`DotFpsController`'s starved-tick substitute — `DotFpsCommand.new()`, facing yaw 0. So
every derived spawn yaw on every map here, the tower's and the circuit's included, each
with its paragraph about the sign convention, was true for no ticks at all.

**The one check on it passed because it read the yaw before a tick had run.** The
switchback's "facing the first block" is the one that found it, because it reads after a
physics frame: `yaw 0.0, the spawn says 90.0` in the full suite, and a pass when run on its
own — because a freshly-added bot's controller had not started ticking yet. A check whose
answer depends on how long the player has existed is the tick-400 respawn check's bug in a
new place.

`teleport` goes through `DotFpsController.teleport` now (which also drops the smoothing and
puts the player in the air, rather than leaving a ground state at a height with no ground
under it), tells `PlaygroundPlayer.sampler` the new angles, and leaves a player that nothing
samples **holding still and facing where it was put** — not the command it had, because a
bot holding forward when it fell off a course was otherwise respawned already running off
the pad. `_the_spawn_yaw_survives_a_tick` reads the yaw eight ticks later for a bot and for
a player with a sampler facing 90 degrees away; both fail with the old `teleport`.

The starved-tick substitute is the addon's half and is not fixed here: a server that loses
one packet from a player holding no buttons turns that player's view to north for the tick.
It wants `_repeat_command()` in both branches, in dot-player-controller.

**`Playground.tracks_on_this_map()` is derived from the zones, not declared.** A second
list of tracks is a second thing that can disagree with the zone file — and it is the
zone file a *delivered* map ships, so the declaration would be the half that is missing
exactly when it matters. `MAIN` is always in the result even with no zones on it,
because a sandbox is a legitimate track and a player has to be able to get back to it.

## `pg_bhop_intro`'s switchback: the first route built to be turned round by a bot

The narrows, the plunge and game-g2gfast's `the needle` are all straight, and each says so
as a design decision: a route a scripted bot cannot run is a route no suite ever finishes,
and every bot here held one yaw. The tower showed that was a limit of the bots, and **the
switchback is the first route designed after that was known**. Bonus 2 on
`pg_bhop_intro`: a hillside of 3 m floating blocks west of the main run, three legs —
west four, a turning block south, east four, a turning block south, west four onto the
finish — climbing 0.5 m a jump from 2 m to 9 m. Every leg ends in a quarter turn and every
turn is a jump, so it asks whether a player can land, face somewhere else and go: the thing
between the narrows' "hold your line" and the main run's "keep your speed".

**One description.** `PgBhopIntro.switchback_route()` is the list of boxes, walked edge to
edge from the pad through `SWITCHBACK_LEGS`; the geometry is built from it, the splits sit
on its turning blocks, and the suite reads every jump's gap and rise off it and drives a bot
along it. The gaps grow from 2.0 m to 3.3 m, which is 79% of `jump_reach(0.5)`. Blocks are
square so a turning block is the same target from whichever side a leg arrives.

**The splits are slabs, not blocks.** A turning block shares its Z with the leg it turns
onto, so a slab at that Z is the whole of the next leg and the only way into it. The legs
are 2.4 to 2.9 m of air apart — which reads like a jump, but beside anything but a turn the
next leg is 1.5 m or more higher, over the 1.15 m apex. Beside a turn it is a diagonal of
3.5 m up 1.0 against a 3.2 m reach: a corner a player carrying bhop speed can cut, landing
on the next leg without touching the turning block. A split on the block would be one that
player skips.

All five zone kinds are on its own track and walked **by name** (`[track-zone-1]`).
Driven start to finish through both splits in about 1,560 ticks with no respawns; with the
last gap pushed to 4.8 m the same bot gives up at the jump `jump_reach` says it should, so
the drive decides something. `tools/screenshot.sh pg_bhop_intro` renders it from above
(`pg_bhop_intro_switchback`) — the first angle, from the south-west at twenty degrees and
47 m out, made the whole route a smudge beside the main run's much larger blocks — and at
its first turn.

## `pg_bhop_intro`'s ascent: the first route a player has to walk part of

Bonus 3 on `pg_bhop_intro`, east of the narrows at x = 60: four sections, each a level jump onto a 4 m block and a ramp up off it to a crest 2 m higher, then a last jump onto the finish — 2 m to 10 m in 64 m. **Every ramp rises 2 m against a 1.15 m jump apex, so there is no way up but to walk it**, and the pitches go 16, 24, 32, 40 degrees against the server's `max_slope_angle` of 46. It could not exist before dot-player-controller's `[slope-1]` (803308f): until then the first tick on any walkable slope read as airborne, and a ramp was a wall.

**One description.** `PgBhopIntro.ascent_route()` is the boxes stood on, `ascent_walks()` names the ones whose next step is a ramp, and `ascent_ramps()` is each ramp's foot, crest and tilted box — dropped from the middle of its top surface along its own normal, so the top face passes through both blocks' edges exactly (the plunge's 0.8 m lip came from dropping vertically). The geometry, the zones and the suite read those three and nothing else. Splits are on the crests of ramps two to four, the one place nobody reaches but by the ramp below it.

**`_drive_route` walks now.** Its `walks` argument stops the bot jumping off a walked box and counts its grounded ticks between that box and the next — on the ramp. It also found the bot's own bug on the first drive: near a crest `_standing_on`'s 0.4 m margin calls the bot on the crest while it is still on the ramp, with the look-ahead short of the crest too, which read as "past the edge" — so it jumped from the top of every ramp over the whole crest into the gap. Off a box a ramp climbed to, it jumps only once actually over it. Driven start to finish through all three splits in ~1,210 ticks, no respawns, grounded 118, 74, 52 and 40 ticks on the four ramps; `_check_route_reach` skips walked steps and prints the tightest jump, 3.40 m level against a 4.75 m reach (72%).

**Armed, and what arming it found.** With the last ramp at 50 degrees the walkability check and the ramp-grounded check both fail (0 grounded ticks on it) — **but the drive still finishes.** An airborne player holding forward into a face past `max_slope_angle` creeps up it at a steady ~0.97 m/s vertical: air acceleration refills the wish each tick, the clip turns it up the plane, and gravity never wins, so 2 m of 50 degrees is climbed in about 1.5 s. Whether that is the genre (high air acceleration pressed into a surf face) or a bug is dot-player-controller's call (reported from the 2026-09-24 nightly run as `[steep-climb-1]`); it is why "it finished" alone proves nothing here and the grounded-ticks check exists. `tools/screenshot.sh pg_bhop_intro` renders `pg_bhop_intro_ascent` (the profile, from beside) and `pg_bhop_intro_ascent_start` (from behind the pad).

## `pg_bhop_intro`'s ladder: the first route where every jump is as high as a jump may be

Bonus 4 on `pg_bhop_intro` (`LADDER_TRACK`), west of the switchback at x = -76, starting level with the other four routes at z = 10: a 6 m pad at 2 m, ten 3 x 2.5 m columns each exactly `LADDER_RISE` (1.0 m) above the last, and a 5 m finish column at 13 m — eleven jumps, 11 m up in 60 m. pg_bhop_intro had the oldest level of the three timer maps (the ascent, 2026-09-24), and every route on it so far asked how far (the main run, the narrows) or where to (the switchback) or whether you can walk it (the ascent). **This one asks how high**: 1.0 m is 97% of `climb_limit()` (1.035 m), the tallest step on any route here (the jump course's 0.8 m was), so the reach is 3.23 m against 4.75 flat and the widest gap, 2.5 m, is 77% of it — a player who takes off a stride before the lip meets the next column's face on the way down. The gaps grow 1.8 -> 2.5 m, and the lower bound is arithmetic too: a 1.0 m climbing jump at full speed is under the next top for its first 0.22 s, 1.52 m, so a gap shorter than that is met face-first on the way UP wherever it is taken; 1.8 leaves 0.28 m.

**One description.** `PgBhopIntro.ladder_route()` is the boxes — each rung and the finish the whole column, from the pad's underside (`ladder_foot_y()`, 1 m) to its top, walked edge to edge from the pad — and the geometry (`_build_the_ladder`), the zones (`_add_the_ladder`: spawn a stride behind the pad's middle facing -Z, start on the pad, splits on rungs 4 and 8 — nothing here can be skipped, the rung after next is 2 m up — a deep finish, a reset slab 2 to 7 m under the columns' feet from x -86 to -66, clear of the switchback's) and the suite read that and nothing else. Columns rather than floating slabs for the stepping stones' reason: from beside, a row of columns each a metre taller than the last reads as the staircase it is. The survey finds pg_bhop_intro still clean with nothing new declared.

`headless_playground`'s **the ladder** (17 checks): the five zone kinds on its own track and `route_problems()`; `_check_route_reach` (tightest #11, 2.50 m of air 1.00 m up against 3.23, 77%); every rise within 95-100% of `climb_limit()` over a gap longer than the rising part of the jump; the reset under every column's foot; the spawn and its yaw; and a `_drive_route` drive with a 0.1 m look-ahead — all eleven jumps and both splits in 1,011 ticks, no respawns. **The drive prints its pace (`[bot-drive-1]`)**: `_drive_route` now returns `distance` (horizontal ground covered, respawn teleports left out) and `top_speed`, and this section prints 53.2 m covered of a 55.7 m centre-to-centre route in 7.90 s, 6.73 m/s against a 7.0 max, and asserts the drive covered at least 95% of the route at 60% of `MOVE_SPEED`. The narrows and switchback sections now expect five tracks. Armed three ways, each with the section run alone: the last gap at 3.6 m fails the reach check and the bot stalls at rung 9 with two respawns; the rise at 1.10 m — past the climb limit, still under the 1.15 m apex — fails the wall check and the shape check, and **the bot never gets past the first rung (seven respawns)**, which is the family's `CLIMB_MARGIN` measured rather than assumed; and a bot wishing for 40% of its speed fails the pace check (2.23 m/s) along with the finish. `tools/screenshot.sh pg_bhop_intro` renders `pg_bhop_intro_ladder` (the profile, from the empty west side) and `pg_bhop_intro_ladder_start` (from behind the pad at a player's height).

## `pg_bhop_intro`'s float: the first route the map does something to the player for

Bonus 5 on `pg_bhop_intro` (`FLOAT_TRACK`), east of the ascent at x = 120 (its profile camera is at x = 100, so this route is behind it), starting level with the other five at z = 10: a 6 m pad at 2 m, six 4 x 4 m columns and a 6 m finish column, seven jumps, every other one `FLOAT_STEP` (2.0 m) up, ending 6 m above the pad. **Every gap is wider than a running jump (6.0 m and up, against 4.75) and every step is nearly twice a jump's apex (2.0 m, against 1.15), so not one jump can be made on the ground.** The whole route stands inside one dot-timer GRAVITY zone at `FLOAT_GRAVITY` (0.4). Every other route here is sized against gravity; this one asks a player to re-learn a jump that rises to 2.88 m and takes two and a half times as long to come down (`float_apex()`, `float_reach(rise)`: 11.87 m level, 9.21 m onto a 2 m step).

**The GRAVITY zone is the game's, and it is new.** dot-timer has carried `Kind.GRAVITY` since it was written, and nothing applied one, as with PUSH before the launch. `PlaygroundPlayer._on_simulated` applies it beside the push and for the same reason: in the air only, it gives back `gravity * (1 - number)` of the vertical speed the motor took this tick. On the ground gravity is what holds a player to the floor and nothing is falling. It is read at the state's own position (`effect_zone_at`), the push's `[playground-push-1]` rule, so a predicting client's replay gets the gravity it got the first time. Like the push it is **not track-filtered**: a sandbox player on the main track who walks into the zone floats too. **Not yet measured over the wire**: `headless_net` drives the launch's push and not this; the same rule means it should cost no corrections, and that is a claim until a section says so.

**One description.** `PgBhopIntro.float_route()` is the boxes (each column and the finish the whole column, from the pad's underside, `float_foot_y()`, walked edge to edge from the pad through `FLOAT_RISES` and `float_gap(i)`, which grows evenly from `FLOAT_FIRST_GAP` 6.0 to `FLOAT_LAST_GAP` 8.0). The geometry (`_build_the_float`, the columns in `PlaygroundGeometry.COLOUR_FLOAT`), the zones (`_add_the_float`: spawn a stride behind the pad's middle facing -Z, start on the pad, splits on columns 2 and 4 (the first two step-ups, which nobody passes without landing), a deep finish, the GRAVITY zone over the whole route and a full float jump above it (`float_zone_box()`), and a reset slab under the columns' feet) and the suite read those and nothing else. The survey declares the columns (`float_columns_box()`): it does not model a zone's gravity, so without the declaration every column reads as unreached.

`headless_playground`'s **the float** (19 checks): the zone kinds on its own track and `route_problems()`; every jump out of reach on the ground; every jump inside 90% of the float's reach (printed per jump; tightest #6, 7.67 m of air 2.00 m up against 9.21, 83%; the last, 8.0 m level, is 67%); no step a wall even in the float; the gravity zone covering every column and a full float jump over it, with the reset under it; a **measured** jump (a bot jumping from the pad peaks 2.77 m up against `float_apex` 2.87 and lands 1.66 s later); and a `_drive_route` drive through both splits into the finish in 1,670 ticks, no respawns: 78.9 m of an 80.5 m route in 13.05 s, 6.05 m/s against 7.0, 79% of the ground covered in the air and none on anything else. **Armed** by the nightly run leaving `FLOAT_LAST_GAP` at 11.0 after exporting the zones at 8.0 (the export hash says which): five fail. The reach check fails on #4, #6 and #7. The zone file no longer matches the map. The bot is put back once, crosses the splits twice ([1, 2, 1, 2]) and covers 162.6 m at 5.40 m/s. `tools/screenshot.sh pg_bhop_intro` renders `pg_bhop_intro_float` (the profile, from the empty east side) and `pg_bhop_intro_float_start` (from behind the pad at a player's height).

## `pg_bhop_intro`'s drop: the ladder turned over

Bonus 6 on `pg_bhop_intro` (`DROP_TRACK`, 2026-10-05), west of the ladder at x = -150 (the ladder's profile camera is at x = -124, so this route is behind it), starting level with the other six at z = 10: a 6 m pad column whose top is 26 m, seven 4 x 4 m columns and a 6 m finish column at 2 m, eight jumps each landing `DROP_STEP` (3.0 m) lower. **Every gap is wider than a running jump on the level (5.0 -> 5.8 m against 4.75), and every one is inside `jump_reach(-3.0)` (6.88 m)**: the ladder asks how high a jump goes, this asks how much further one goes when the landing is lower, and it comes down to the height the other routes start at. One description: `drop_route()` (every column the whole column from `drop_foot_y()`, 1 m, pad included, walked edge to edge through `drop_gap(i)`), read by `_build_the_drop`, `_add_the_drop` (spawn a stride behind the pad's middle facing -Z, start on the pad, splits on columns 3 and 6, a deep finish, a reset slab under the feet from x -160 to -140) and the suite. The survey finds pg_bhop_intro clean with nothing new declared: it models a falling jump's reach.

`headless_playground`'s **the drop** (17 checks): the five zone kinds on its own track and `route_problems()`; `_check_route_reach` (tightest #8, 5.80 m of air 3.00 m down against 6.88, 84%); every jump the same 3 m down over a gap wider than any level jump; the reset under every column; the spawn and its yaw; and a `_drive_route` drive with a 0.1 m look-ahead through both splits into the finish in 1,423 ticks, no respawns: 75.7 m of a 78.7 m route in 11.12 s, 6.81 m/s against 7.0 (`DROP_PACE_FLOOR` 90%). The bhop map's track lists now expect seven tracks. **Armed** with `DROP_STEP` at 0.0 (the same gaps on the level) after exporting the zones at 3.0: eight fail. The zone file no longer matches, the reach check fails on #8 (122%), the bot gets to column 2 and is put back four times, never crossing a split, and the survey reports all eight level columns unreached. `tools/screenshot.sh pg_bhop_intro` renders `pg_bhop_intro_drop` (the profile, from the empty west side) and `pg_bhop_intro_drop_start` (above and behind the pad, down the line; at a player's height the pad's lip hides every column).

## Bonus 3 is a circuit, and a track now says whether it is driven

`pg_lobby` gained a **driving circuit** round the outside of the plate: a rounded
rectangle 611 m round, 12 m wide, with kerbs down both sides and its corners on a 26 m
radius, running clear of the jump course, the tower and the movement corner. It is the
first map in this family built at a **car's** scale rather than a player's, and the first
time anything here has put a vehicle through dot-timer.

**A loop whose start and finish are the same place finishes on the tick it starts**, so
the grid is at `s = 0` and the finish line is 12 m *behind* it. A car leaves the grid
driving away from the line, goes all the way round, and crosses it on the way back to
where it started. That is what a real circuit does by putting the timing loop somewhere
other than the front row, and it is the only reason a lap here is a lap.

Everything comes from one function. `PgLobby.circuit_point(s)` answers with a position
and a direction of travel, and the road, the kerbs, the grid, the finish, the three
splits and the spawn yaw are all derived from it — the same rule the two foot courses
follow, for the same reason: a start line half a metre off the tarmac is a leaderboard
nobody can compare, and on a track a car crosses at 25 m/s that half metre is two ticks.

### Getting into a car used to cancel every run

`Playground._on_seated` stopped the timer unconditionally, and that was right when every
course was a foot course: a jump course driven round in a buggy is not a time anybody can
compare with one that was jumped, and dot-timer has no idea a vehicle exists. It is
exactly wrong on a circuit, and **a rule that cannot tell the two apart is why there was
not one**.

`PlaygroundMap.track_is_driven(track)` is the seam, defaulting to false — so every map
that existed before there were cars behaves exactly as it did. The map answers because
the map is the only thing that knows. The rule is symmetric and the second half matters
as much: on a driven track, **getting out** ends the run, because the rest of the lap on
foot is not the same lap.

### What building it found

- **`Basis.looking_at(dir)` aims -Z at `dir`, and a vehicle's forward IS -Z.** Negating
  the argument — which is the natural thing to write when the vehicle notes say "a
  positive `engine_force` drives +Z" — put the car on the grid facing backwards. It
  reversed 12 m into the finish line and reported a lap of 0.36 seconds with no splits,
  which is a perfectly plausible-looking pass if the only assertion is "it finished".
- **A car parked on the road cannot be got out of.** `max_exit_speed` refuses an exit
  above walking pace, correctly, and a test that coasts to a stop is not stopped. The
  brake is `BUTTON_CROUCH`.
- **`dedicated.tscn` had been carrying state between runs for weeks.**
  `DotAchievementStoreFile` writes under `user://`, so each run added sixty prop spawns
  to whatever the last one left; after about nine runs the "fifty unlocks the first tier
  and not the second" check crossed 500 and began failing on a tree with no changes in
  it. **A suite whose result depends on how many times it has been run is not a suite.**
  It wipes the player's stored progress first now. This was not found by the circuit; it
  was found by running the suite twice, which is what this family's own notes say to do
  before blaming a change.

And one that reads as a harness artefact and is worse than that: **`headless_net` is
ORDER-SENSITIVE, and calling it flaky is what made it expensive.** Both halves are plain
nodes in one scene tree and therefore share one physics space, so the vehicle test's "it
drives forwards" reads a velocity that depends on where both cars are — and the lossy
test's distance is the same kind of reading. One new test that spawns no body, asserts
nothing about physics, and merely advances the world about twenty steps, moved three
times, five runs each:

| where the new test sits | clean runs | what failed |
| --- | --- | --- |
| not there at all | 4 / 5 | the vehicle drive, at -0.16 m/s |
| before the vehicle test | **0 / 3** | the vehicle drive, at -0.16 m/s, every time |
| between the vehicle and the timer | 3 / 5 | the lossy link's distance |
| after everything that reads physics | **5 / 5** | — |

**The two ends do not share a physics space for props, measured.** On 2026-09-24 a crate's server body and its client mirror reported different `World3D`s (two space RIDs), and forcing the mirror 0.3 m into the server's crate moved nothing. Whatever makes the ordering matter, it is not a prop's two copies touching. `[pg-net-2]` (the crate "falling" 23.99 -> 25.02 about one run in three) did not reproduce in 12 runs that night; the check now waits for the server's crate to drop a metre and then asks whether the client's copy is within 0.5 m of it, and prints both ends' heights so the next failure says which end moved. The client bridge also freezes a mirror before it enters the tree: until its first interpolated draw it was a live body falling under the client's own physics, and with drawing switched off that alone passed "it falls on the client because the server's physics moved it" at exactly the server's height.

So: **add a test here at the END of the connected-player sequence**, and treat a vehicle
or lossy failure after inserting one as a schedule change rather than a code change until
proved otherwise. The old advice in this slot was "run it again before believing it",
which is precisely the advice that hides a real regression — the second run is the one
that gets believed.

## The tick rate comes from `server.cfg`, and every link in the chain is silent

```
server.cfg:  sv_tickrate 100
      ↓      dot-server, _apply_tickrate()
Engine.physics_ticks_per_second
      ↓      Playground._resolve_tick_rate()
Playground.tick_rate  →  DotTimerConfig.tick_rate = 0 ("ask the engine")
      ↓
DotTimerManager.tick_rate  →  DotTimerRecord.tick_rate
```

A timer counting 128 a second on a server stepping 100 reports every run 28% long, and
**nothing about the run looks unusual** — it finishes, it files, and it sits on a
leaderboard shared with servers that got it right.
`examples/dedicated.gd::_test_tickrate_reaches_the_timer` walks the whole chain in one
test, with the server configured for 100 precisely because the project's own default is
128: a test using the same number at both ends would pass with the chain disconnected.

`sv_tickrate` goes in **`server.cfg`, not `autoexec.cfg`** — it is startup-only, and
dot-server execs the first before the listener and the second after.

## Chat is dot-chat's, and there is still exactly one path

`DotChatRouter` has the rules: four channels, one of them a **radius**, a backlog for
whoever just joined, a `/me`, and a gag that survives a reconnect. `PlaygroundModule` hooks
`player_chat` with `hook_pre` and **cancels** it, so dot-server's own broadcast never
happens, and its join and leave announcements are turned off in the same place.

Two paths would be two sets of rules to keep in step, and the one that skipped the filter
would be the one that leaked admin chat. `dedicated` asserts the cancel.

**An unclaimed `!command` goes into dot-server's own console with the player's
permissions.** Not a second command table — this game's console surface is the largest in
the family and a second table would be the larger half unaudited.

**The chat key is the session id, not the account uid.** dot-chat's `key_fn` and
dot-moderation's `key_for_peer` are separate seams because they answer different questions:
a punishment is against a person who will come back; a chat line is attributed to somebody
standing here now. Two guests behind one device id share a uid, which was found by running two clients in
one process, with every count matching throughout.

### `PlaygroundServices` is a `DotGameServices` now (`[services-1]`, 2026-09-27)

The sequence — moderation first because it publishes `dot_mute_source`, then chat, the website relay, voice — is dot-game's, and `playground_services.gd` went from 557 lines to the part that is this sandbox's. `addons/dot_game` is linked (and in `.gitignore`) for it; the module still does not subclass `DotGameModule` (below). What the subclass keeps that the base would have done differently, each checked:

- **The bridge is who is in the game.** `_chat_peers` is `bridge.ready_peers()`, not dot-server's playing sessions — a peer is playing before its client has built the node a CHAT event lands on. `_key_of` is the bridge's player id (which is the userid on a server, so the base's answer there) and `_subject_for_peer` falls back to `local:<player id>` with no session, where the base answers `""`. Those three are what let the real sequence run with no `DotServer`.
- **`_send_chat` stamps `x.p`**, the one meta field this wire carries, then calls the base. The bridge is passed as the link because it has `send_chat`; `_send_voice` goes through `bridge.link`, because the bridge has no voice method.
- **`_peer_can_receive` is false.** The backlog is `PlaygroundModule._welcome`'s, sent once the bridge says the peer is ready; the base would also send one from `add_peer`, and a joiner would get it twice.
- **`mod_tools_enabled` is forced off.** The live tools stay the module's (`_build_mod_tools`): `PlaygroundModTools` needs the arena's health, which is built after the services, and the module clears their return history on every map change (`[modtools-return-1]`). A second set built by the base would bind the same command names to the same console.
- The channels, rules and voice format stay **statics** a client reads. Callers type the element (`for channel: DotChatChannel in …`) rather than inferring it: a script whose base class lives in the host build cannot hand its return type to a script in a mounted pack — mg-buses-from-hell's finding. This conversion has not yet been driven by a client inside a delivered pack; the client shell already carries dot_game.
- Two differences accepted rather than kept: a moderation or voice layer that fails to build is now logged rather than fatal to the module (the base's judgement), and `describe_lines` gains a `relay` line.

`headless_net`'s **a chat line, end to end through the services** is the only check in this repository that carries a line through the real router: the client's SAY over the link, `say_requested`, the services with no `DotServer`, the CHAT event, `chat_received` — then a gag issued through the moderation the base built, and the gagged line reaching nobody. Armed: without the `x.p` stamp one check fails; with the base's `_subject_for_peer` the gagged line is delivered; with the base's `_chat_peers` four fail; with `_peer_can_receive` true the seating check sees the backlog.

**`DotGameModule` was not adopted, deliberately.** Its `game`, `bridge`, `net` and `services` are untyped fields a subclass cannot redeclare, and this module reads them typed in most of its ~75 functions; its `_build_extras` builds services, then the arena, the waves, the mod tools, the vote and progress in an order each depends on; and it keeps its own `_joined` table and spawn path rather than a `DotGameRoster`. That is a conversion of its own, not a pass on the way to this one.

## Voice is the whole server, and the near channel is text's

Three games, three answers, and each is right for what it is. A lobby is a room you can see
all of, so its voice is the room. An arena is bigger than a screen, so game-hungario's is
proximity. **A sandbox is both at once** — people build together in one corner and run the
course in another — so text has a near channel and voice does not, which is what every
sandbox server has ever shipped with: a builder shouting for a hand should be heard, and
somebody in the corner reading should be able to stop reading the shouting.

The rest is the lobby's reasoning: one `unreliable` RPC on its own channel serves a UDP
desktop client and a TCP browser one; push-to-talk closes when a screen takes the keyboard;
and playback goes into a **buffer** when there is no audio device, which is what makes the
receiving half checkable at all.

## The arena: dot-combat, dot-match and dot-loadout, off by default

**A sandbox is not a deathmatch.** `pg_arena 1` is the switch, and everything behind it is
inert until then — for the same reason `pg_waves` is: a server where somebody can shoot you
while you are building is a *different server*, and turning one into the other silently
because an addon was installed is exactly what a cvar exists to prevent.

- **dot-combat** is health, damage types, hitboxes and the resolution — and the part that
  matters is not the arithmetic. Friendly fire, self damage, falloff, hit groups and
  clamping are **policy** on a resource rather than `if`s in a file, so an operator can
  change any of them.
- **dot-match** is warmup, countdown, rounds, scoring, respawning. Counted in ticks and
  driven by one call, so it runs at whatever `sv_tickrate` says.
- **dot-loadout** is what you spawn with, as a document of **ids** validated against a
  schema and an entitlement set without loading any content.

**The loadout catalogue is built FROM `PlaygroundWeapons`**, not beside it. The arsenal is
already declared once — an id, a name, a script path — and what a `DotItem` adds is the two
things a weapon definition has no business knowing: what it costs and what unlocks it. A
second list is the bug this tree has now shipped four times.

**The required slot has a default, and dot-loadout refuses a schema without one.** That
refusal is right: a loadout missing a required slot cannot be *repaired*, so it can only be
refused — and a player who has never chosen could then never spawn. The default is derived
from the catalogue rather than written in.

### The bug the arena found on its first run

**A `DotDamage` with no `tick` is refused by spawn protection for ever.** `DotHealth.apply`
refuses anything whose `tick` is at or before `invulnerable_until_tick`, and a `DotDamage`
starts at tick 0 — so an event that was never stamped is refused on every player, with
`refused` set, and nothing erroring anywhere. Every shot on the server does nothing and the
only symptom is that combat does not work. One line; found by the suite's very first hit.

## Waves: a second population, with a different owner

`dot-npc-ai-director` releases NPCs the **server** owns, and they are deliberately *not*
prop entities.

This project's own rule — an entity is a `DotPropInstance` first, because *an NPC you
cannot pick up is the first thing a sandbox player will try* — is about NPCs a **player**
put there. A wave is not one: nobody spawned it, nobody owns it, and it is reclaimed when
the players walk away from it, none of which a prop budget can express. So there are two
populations with two owners and two reasons, and `pg_waves 1` is the only thing that makes
the second exist.

**Line of sight is ON here and off in the other two games**, which is the point of the
flag: a sandbox has walls, pillars and whatever somebody built, and an NPC that saw through
all of it would make cover meaningless. The other two are open arenas with nothing to be
occluded by.

**Spawn points come from the map's own `DotSpawnPoint`s.** A director inventing its own
would be a director putting a brute in a wall; a ring around the origin is the fallback, and
it says so in the log.

**The waves fight as a squad (2026-10-05).** Three on a player at a time, the rest shared out on a ring round them; they hear every shot the bridge resolves (`PlaygroundWaves.note_fire`, whether or not the arena is on); and they patrol where players actually go on each map, learned by `PlaygroundWaves.heat` and kept in `user://npc_heat` on a real server only — the module turns saving on, and `dedicated`, which loads the module, clears the directory before and after so no run is trained by the last. Wave NPCs reach clients through the bridge's prop path (`watch_npc_spawner`), and a live grenade is a DANGER on `waves.sounds` as well as the armed NPCs' board (the module adds it to `PlaygroundProjectiles`, on the spawner's own clock).

## Limits per kind, the tool gun, and NPCs with weapons (2026-10-05)

**Limits are a count per kind, beside the cost budget, with roles on top.** dot-props had one per-player budget in cost; it now also counts a `limit_group` per definition (`props`, `npcs`, `entities`, `vehicles`, `balloons`, `weapons`) against `DotPropLimits.group_limits`, and asks `DotPropSpawner.limit_resolver` per player. `PlaygroundLimits` is this game's answer: `pg_max_<kind>` cvars for the defaults (props 200, npcs 10, entities 20, vehicles 4, balloons 30, weapons 20, constraints 100), `pg_limit_roles "admin: npcs=40 props=600; vip: props=300"` for who gets more, and `pg_limits [player]` to see anybody's. A role is a dot-server admin group by name — `DotClientSession.groups`, which dot-server now keeps instead of dropping after merging flags — plus `admin` for any admin flag and `root` for the root flag. The most generous role wins and 0 means no limit. **The cost budget's default is now 0**: at 64 it was the limit every player met first (an NPC costs six), with a message about props, before `pg_max_npcs` could say anything. Constraints are not props, so the tool gun counts them itself. A malformed `pg_limit_roles` is refused whole at the console and the old roles kept.

**The tool gun is one weapon with a mode per tool** (`swep_toolgun.gd`, modes in `game/toolgun/`, each a script by path): inflate/deflate, colour, remover, weld, no-collide, rope, balloon, physical properties, NPC weapon. The gun traces, checks ownership (theirs, or anybody's with `touch_others_props` — NOT the physics gun's grab rules, which refuse things too heavy to carry and have nothing to do with painting), and hands the mode a hit; a mode only says what its three buttons do. Settings come from the Q menu's new Tools tab as a schema-drawn panel, travel as JSON on `ARM_PROP` (the Ask enum is four bits and full, so the tool gun's settings, the NPC weapon choice and "drop a weapon on the ground" are ARM_PROP sub-kinds after its id, which an older server reads as the plain ARM_PROP it was), and are clamped to each mode's schema on the server. R reaches a toy now — the bridge passes the reload bit's press to `PlaygroundWeapon.reload`.

- **A resize rebuilds, it never `scale`s.** A scaled RigidBody3D is unsupported by Godot's physics; `PlaygroundProp.set_size_scale` rebuilds the collision and the mesh from the definition, so ten inflates and ten deflates land exactly where they started, and mass goes with the volume. A resized or painted prop replicates `net_scale` / `net_tint`, and a mirror rebuilds only when they change.
- **A rope is impulses, not a joint.** Godot has no distance joint and a `PinJoint3D` is a rod; `PlaygroundConstraints` takes the separating velocity off and a quarter of the stretch per step, which gives slack too. A weld is a fully locked `Generic6DOFJoint3D`; a no-collide is a collision exception both ways. Up to three ropes per prop are replicated (`PlaygroundProp.ROPE_SLOTS`, slots `net_rope_*`, `net_rope1_*`, `net_rope2_*`), each described on whichever of its two props has a free slot and removed by its constraint id, and drawn on clients by `PlaygroundRopeView`, which also draws the server's own when there is a display.
- **A balloon is a hidden catalogue entry** counted against `balloons`, lifting with a force rather than negative gravity, so "enough of them lift a car" is arithmetic.

**Armed NPCs are a zee rig in a dot-npc-ai brain** (`npc_soldier.gd`, `soldier_brain.gd`). Soldiers (`hostile`) and rebels (`player`, so they never pick a player, and they follow whoever spawned them) are the same file; each player's NPCs are one squad. The brain decides when to fire through `ready_to_fire`; the body holds the trigger on a server-role zee rig, so fire rate, magazine, reload, spread and damage are the weapon's own — a shotgun NPC is a shotgun. `PlaygroundNpcWorld` is the director the brain asks (`now`, `candidate_position`, `npcs_near`) because these NPCs are props first and not dot-npc's spawner's. Armed NPCs are candidates for each other (`npc_candidates_all`); the older entities still see players only. A player's shot hurts an NPC (`player_shots_fired`); an NPC's shot hurts another NPC always and a player only through the arena (`arena_hurt`), so `pg_arena` stays the switch for anybody being killed in a sandbox. A dead NPC drops its weapon as a pickup; walking over a pickup gives the weapon exactly as the menu does. The Q menu's entities tab picks what NPCs carry; right click on a weapon drops one on the ground, counted against `weapons`. Only guns and melee are offered to NPCs: grenades fly now (below), but the brain aims along a line and has no throwing arc, so an NPC with a frag would bounce it off its own feet.

Found building it, every one by running rather than reading:

- **A player's soldiers and rebels were one squad**, so each side's fire-lane check found a squadmate standing in the lane — its own target — and nobody ever fired. They saw each other, had reacted, faced each other, and stood there. Squads are per owner AND per faction now; a probe printing every gate is what found it.
- **The turret counted as an NPC**: entities were grouped by script name, and the turret runs `npc_spinner.gd`. Grouped by the entry's id now.
- **A resize is not visible to physics queries until the next step.** The suite pressed the tool gun four times in one frame and every press after a resize traced through the crate. No player can do that, so the suite waits a step between presses; the game needs nothing.
- **dot-npc-ai's brain wiped a squad the game had chosen** with the definition's empty `squad` on bind. Fixed in the addon: the definition only sets a squad when it names one.
- **An earlier section's cost budget** refused a turret in the limits section with a message about NPCs, which is exactly the confusion the per-kind limits exist to remove.
- **The rendered Tools tab** showed every slider as a lone dot: this theme draws no track. The menu gives sliders their own track; `tools/screenshot_menus.sh` now renders the Tools and Entities tabs too.

**Grenades and rockets fly (2026-10-05).** This game used to drop a weapon outcome's `spawns`, so a thrown frag cost a grenade and never existed. `PlaygroundProjectiles` (on `Playground.projectiles`) takes them in `player_shots_fired` and `npc_shots_fired` (before the `used` test, because a release produces a spawn), flies each with a ray swept per tick against the physics world, bounces fused ones (`FLOOR_KEEP` 0.45 along a floor, 0.7 along a wall), sticks a sticky to what it hits, and on the authority sets each off on its fuse, on contact (no fuse) or at the end of its life. A blast hurts what is inside the splash and in sight of it with linear falloff (an armed NPC through `take_damage`, a player through `arena_hurt`, so only with the arena on) and throws loose props; the thrower is not spared. While live, each is a DANGER every eight ticks on every board it was given, so soldiers and waves get out from under it; a blast is a COMBAT sound. **Fuses are in the catalogue's ticks**: zee-dot-weapons counts at 64 Hz, and flown as given on a 128 Hz sandbox a three-second frag went off in a second and a half, still in the air; `accept` rescales by `authored_rate`. Over the wire it is one `Kind.PROJECTILE` event with a sub-kind: LAUNCH carries what a client flies its own copy from (velocity and fuse as full floats), and DETONATE says where. A client's copy never goes off by itself: its world holds interpolated prop mirrors, not the server's props. Not an entity per grenade, because a grenade lives three seconds and its path is a pure function of how it left. `headless_playground`'s **grenades and rockets fly** (19 checks) throws a real frag through a rig: it flies, is a DANGER while live, bounces, goes off on its fuse in front of the thrower, throws a crate, hurts a soldier beside a blast, makes a soldier beside a live grenade run, and checks a rocket going off on the floor plus the LAUNCH round trip and a mirror that waits to be told. `headless_net`'s **a grenade over the wire** checks the client's copy within 0.000 m of the server's for its whole flight and gone exactly where the server's blast was. **Every zee weapon here runs at double speed, and the fuse rescale is the only part converted.** The whole pack is authored in 64 Hz ticks (use intervals, reloads, deploys, charges, fuses), and neither `ZeeWeaponRig.tick_rate` nor `DotWeaponArsenal.tick_rate` scales anything: measured 2026-10-05, the SMG fires 13 rounds in a second of held trigger at 64 Hz and 26 at this game's 128. True since zee-dot-weapons arrived here (2026-10-03); arena, smash-copter and wipeout run at 64 and are unaffected. The fix is either tick-counted tuning scaled in dot-weapon or zee-dot-weapons (and then `PlaygroundProjectiles.accept` must stop rescaling, or fuses are halved twice), or the rigs stepped at 64 Hz here. That is a choice about the addons, and it is open. **Not yet:** a joiner is not told about grenades already in the air, and the thrower's own client sees its grenade a round trip late, because nothing predicts it.

**What is still not here.** Two ropes on a prop are drawn on clients now (`headless_net`'s tool-look section ties two and takes one off; armed with one slot, two checks fail), but more than three ropes described on both of a rope's props are still simulated and not drawn.

## `npc_hunter` is `npc_chaser` with a decision, and both are in the catalogue

The cheap one is for filling a room with and the expensive one is for the arena, and
**keeping both is the only honest way to say what dot-npc-ai actually bought**:

- a **reaction time**, so an NPC cannot commit on the tick it first perceives you — which
  is the difference between a bot and a target;
- a **character per NPC**, seeded from the instance id, so twenty of them do not react at
  the same moment (which reads as a firing squad);
- **separation**, so a pack converging on one player comes apart rather than climbing
  itself into a tower that chases perfectly at a dead stop;
- a **machine**, because there are four states and the transitions between them are the
  whole design — a tree here would be four leaves under a selector pretending to be a
  hierarchy. `wave_brain.gd` is a tree, for the opposite reason, and the two files together
  are what dot-npc-ai's "which is which" note looks like in practice.

### The bug it found in dot-npc-ai

**`has_reacted()` was false for ever.** It measured from `DotNpcInstance.engaged_at`, which
dot-npc refreshes on **every pass in which the target is perceived** — that is what the
field is for, because it is what a reclaim asks about. So the gate every "act on what you
see" branch belongs behind never opened, on any NPC that could currently see somebody,
which is every NPC that would ever act on one.

Nothing errored. **A bot that never acts on what it sees looks like a bot that is bad
rather than like one that is broken**, which is why it survived a suite that tests
`DotNpcAiCharacter.has_reacted` directly and correctly — the arithmetic was right the whole
time and the field being handed to it was the wrong one. `DotNpcInstance.target_since` was
added to dot-npc for it. This file had the same line and the same bug, which is the
confirmation that the fix belonged in the addon.

## Statistics, achievements and the vote

**dot-stats and dot-achievements sit under the boards this game already had.** The boards
held three orderings and there was nothing to put on them but times; what was missing was
the *counts*. Every stat is recorded from a signal the game already fires — a second count
of anything is a second number that can disagree with the first — and
`DotAchievementStatsLink` is a signal connection over that rather than twenty call sites.

`dedicated` checks that **every stat an achievement watches is one the game declares**. An
achievement watching a stat nothing reports never unlocks, nothing errors, and the only
symptom is a player who did the thing and was not told.

**dot-vote replaced half a rock-the-vote.** `DotMapTimeLimit` counts a fraction of the
players and fires, which is real and is half of one: it cannot offer a ballot, take
nominations, break a tie, respect a cooldown or offer an extend. The time limit is now the
clock *under* dot-vote rather than the vote itself, and the source is
`DotVoteMapSource` over the `DotMapSession` this game already drives — one engine, two
sources, and game-hungario's votes over *games* without either file naming the other.

Three of dot-vote's own five bugs are settings set **explicitly** here rather than left:
`extend_needs_majority` (two documented policies, one behaviour), `nomination_seconding`
(without it every nomination count is exactly 1 and `MOST_NOMINATED` can never do
anything), and `begin_on_apply` (both the director and the host announcing one play halves
every cooldown — the host's `DotMapSession.changed` is the one signal that fires for every
change however it happened, so it is the only connection).

**And then it ran at double speed, beside a second clock, under a second rock-the-vote.** Found finishing the map-chooser work, 2026-09-23:

- `self_advance` was on *and* the module advanced the director every tick, so every clock in the vote counted twice: a thirty-minute limit was fifteen, a thirty-second ballot fifteen, the three-minute rock-the-vote delay ninety seconds. Every number agreed with every other, which is why nothing noticed. It is off; `dedicated` asserts the director is not processing itself.
- `pg_rtv` went to the map session's `DotMapTimeLimit` while the wire's `rtv` went to the ballot — two votes under one name — and none of dot-vote's commands existed. `PlaygroundVote.install_commands` puts `DotVoteCommands` on the module (a chat `!` line reaches the console here, so that is all it takes), and `pg_rtv`, `pg_extend` and `pg_nextmap` answer from the ballot when there is one.
- The map session's clock, on a server whose `pg_map_seconds` was not 0, changed to the rotation on the old clock after the players had voted to extend. `Playground.rotation_ends_maps` is off once the module has a ballot.
- The ballot's cues go to clients as `PlaygroundEvents.Kind.VOTE` (`write_vote_cue`, because `write_vote` is a player's token going the other way) and play through `PlaygroundPresentation`'s catalogue, on voices nothing else in it uses.
- **The HUD's time left was the map session's clock, which on a client nothing extends (fixed 2026-09-24).** A client's session starts its own clock when it loads the map, so an extend never reached the screen, and the deployed `trigger: rtv_only` with `duration_sec: 0` had every client counting down thirty minutes the server did not have. `PlaygroundVote.advance` keeps a `DotVoteClockView` of what clients believe and emits `clock_due` only when it goes stale — an extend, a new map, a stopped clock — and the module sends it as `PlaygroundEvents.Kind.CLOCK` (last, after VOTE); `PlaygroundNetBridge.clock_fn` tells a joiner the current one. The client's bridge adopts every CLOCK into one `clock_view` the HUD holds and counts down between messages, and **draws no clock at all when the vote has none**; offline, where the local session is the real clock, it keeps the session's. `headless_net`'s **the vote's clock over the link** extends a real `PlaygroundVote` and asserts what the client sees moves by the extension, that quiet seconds send nothing, and that the deployed rtv-only shape leaves no clock on the HUD. `tools/screenshot_views.sh` renders `hud_clock` and `hud_no_clock`. `Playground.describe` and `describe_lines` report the vote's clock too since the same day (next entry), and the client shell needs a rebuild with this dot-vote before this pack is published, because a pack cannot load a script naming a class the shell does not have.
- **`pg_status` and `describe()` said the map session's time left after the vote owned the clock (fixed 2026-09-24).** An operator asking how long was left was told a limit an extend had already moved, and on the deployed `trigger: rtv_only` with no duration, thirty minutes the server did not have. The game does not know the vote exists, so the module sets `Playground.clock_fn = vote.clock_state` beside `rotation_ends_maps = false`, and `time_left_text()` reads it: `m:ss`, `(stopped)` while a ballot holds it, `no limit` with no clock — words here where the HUD drops the slot, because a status line is read when somebody asks. With no vote the session's clock is the real one and is kept. `dedicated`'s vote section extends a known clock and asserts `pg_status` moves by the extension while the session's does not, that `describe()` agrees, and that rtv-only says `no limit`; armed by skipping the vote's clock, three checks fired.

**The deployed sandbox runs until it is voted out, and now says so in both places.** `pg_map_seconds: "0"` stopped the map session's timer and not the vote's, so the delivered game was put to a ballot at twenty-eight minutes. Its `game.yml` sets `metadata: map_vote: {trigger: rtv_only, duration_sec: 0}`, and dot-server-deploy's selftest fails for any shipped game that stops its map clock without stopping the vote's. A sandbox has no leading score — the arena inside it is a side activity, not what a map is for — so nothing here calls `note_score`.

## Identity, and why a sandbox needs it at all

`PlaygroundPlatform` builds dot-user, dot-user-avatar and `DotPlatformHub`, and
`examples/dedicated.tscn` loads `DotPlatformModule` beside `PlaygroundModule`. It is
optional: a LAN sandbox has no accounts and that is the most common deployment there is, so
the module duck-types against it rather than naming it.

**The reason it is here is dot-stats.** A statistic has to be filed under a key, and
dot-stats refuses an account id as one before it leaves the server — so the scoped
pseudonymous id dot-user derives is what a board and an achievement are keyed by.
`PlaygroundPlatform.key_for_session` is the one function that decides, and without an
identity stack it files under something that lasts exactly as long as the session, which is
honest.

**Name changes are off here and on in the lobby.** A sandbox has a leaderboard on it: a
name that can change is a record whose owner cannot be recognised.

## The server module

`game/playground_module.gd` is the only file here that names dot-server, which is where
the family's own documentation says such a bridge belongs. It is also where the game
becomes administrable:

| | |
| --- | --- |
| `pg_timer` `pg_restart` `pg_style` `pg_track` `pg_top` | the run |
| `pg_cp` `pg_tp` `pg_cp_clear` | practice mode |
| `pg_zone` `pg_zone_mark` `pg_zone_spawn` `pg_zone_list` `pg_zone_undo` `pg_zone_save` | drawing zones, the `sm_zones` workflow |
| `pg_map` `pg_nextmap` `pg_rtv` `pg_extend` | maps |
| `pg_prop` `pg_undo` `pg_props_clear` | props |
| `pg_status` | everything at once |
| `pg_services` `pg_gag` `pg_mute` | chat, voice and moderation |
| `pg_arena` | the fight, off by default |
| `pg_waves` | the director's NPCs, off by default |
| `pg_vote` | what plays next |
| `pg_achievements` | what somebody has earned |
| `pg_give` `pg_inv` | put something in somebody's bag, and read it |

**The zone commands are `CHANGEMAP`, not `GENERIC`.** Drawing a start line is editing
the map's rules, and somebody who can do it can invalidate every record on it.

**One painter per admin.** Two admins drawing at once would otherwise share a first
corner, and the failure is a zone spanning the distance between them — saved, with
nothing to say it was not meant.

**A zone is live the moment it is drawn** (`set_zones` right after the second mark). An
admin who had to reload the map to test a start line would test it once.

**Saving a set with a problem is refused, not warned about.** A zone file with a start
and no end is playable and unfinishable, and the moment it is on disk somebody else has
a copy.

There is deliberately **no `pg_tickrate` cvar**. A second cvar for the same number is a
second number that can disagree with the first.

## `pg_surf_intro` has a second route, because its first one is not what it says

**The main run's ramps are level along their length.** They fall toward a valley, and
every metre of *descent* comes from the stepped floor between them — so a player rides
the whole map without the ramps ever having given them any speed, and the route never
asks the question surf is about: hold a line on a face you cannot stand on while
gravity does the work.

Nothing said so, because the checks over it cannot tell the difference. `_test_surf_run`
asserts "most of the descent is spent not grounded" and "the player reaches surf speed",
and **both are satisfied by a player falling off the start platform**: not grounded
because it is in mid-air, 12 m/s because that is what 1.2 seconds of gravity is worth.
Instrumenting it printed the number nobody had: **10.7 m of a 220 m route, 5%, zero
splits crossed.** The suite then finishes the run by teleporting the player into the
finish zone, which it says it is doing and which is honest — but it means the map's own
name for that section, "a surf run, start to finish", has never once described what
happened.

Two things came out of that, and the measurement is the more useful of them.

**The distance is PRINTED, not just asserted.** This is game-arena's rule from
`[bot-drive-1]` — a check's detail line shows only when it fails, so a figure that is
merely asserted is one nobody reads again the moment it starts passing, and every
question about how a map should be shaped is really a question about this number.

**And the map gained `the plunge` on bonus 1**: one face pitched 52° (past the 46° a
player can stand on) descending 61 m along its own run, so gravity accelerates the
player ALONG the route rather than straight down. Same start height as the main run,
which is what makes the two times worth comparing at all.

It is **straight**, and that is the same design decision `the narrows` and
`game-g2gfast`'s `the needle` were built on rather than a lack of ambition: a scripted
bot cannot air-strafe, so a route that needs turning is a route no suite ever runs end
to end, and an unrun route is one nobody finds the holes in. (Half of that was later found
to be wrong — a route that needs *facing* somewhere new is drivable, and the tower and the
switchback are; a route that needs speed *carried* round a turn, which a surf bank is, is
still not.) The bot holds forward and
nothing else — no jump pattern at all, because on a face nobody can stand on there is
no ground to leave — and reaches the finish through both splits at **33 m/s**, against
the main run's 12.

Its zone set is complete **for its own track**, and asked about as such. A `DotTimerZone`
carries a track, so a set that is complete for track 0 and partial for track 1 passes
`DotTimerZoneSet.problems()` — which is a per-zone check — while being an unfinishable
route, and this family has already shipped that exact hole twice. The check here walks
START, END, SPAWN and RESPAWN on the bonus track by name. (Since `[track-zone-1]` it is dot-timer's `DotTimerZoneSet.route_problems()`, which asks that of every route, and `_test_zone_file_matches_the_map` asks it of every map that builds zones and of its shipped file — which also stopped checking `pg_surf_intro` alone. `pg_lobby`'s circuit is the one route with no pit, and says so in its zones' `meta.pitless_tracks`: the road runs inside the plate's 10 m walls.)

**One number that is easy to get wrong and silent when you do.** The slab is dropped by
half its thickness measured *vertically*, not perpendicular; the two differ by
1/cos(pitch), which at 52° is 1.6. Getting it wrong leaves a 0.8 m lip where the pad
meets the face, which is over the controller's step height — so a player runs at the
slide and stops dead, with nothing in any count to say why.

## `pg_surf_intro`'s cascade: the first route that jumps down

Bonus 2 on `pg_surf_intro` (`CASCADE_TRACK`), west of the main run at x = -60, mirroring the plunge: an 8 m pad level with the other two starts at 40 m, ten 3 m blocks each 1.25 m under the last and alternating 2.5 m either side of the line, and a finish pad at 26 m. **Every other bhop route here climbs or stays level, which makes a jump's reach shorter than a flat one; a drop makes it longer** — `jump_reach(-1.25)` is 5.80 m against 4.75 flat — so a player who learned the climbing courses overshoots. Every block-to-block jump is a diagonal across the line, so each landing is also a decision about where to face.

**One description.** `PgSurfIntro.cascade_route()` is the boxes; the geometry, the zones (spawn, start on the pad, two split slabs across the whole staircase at route blocks 4 and 8, a finish, a reset 3 m under the lowest block) and the suite read it. Gaps along Z grow 2.0 -> 3.8 m; the tightest jump is the last block-to-block diagonal, 4.14 m of air against 5.80 (71%). A split slab cannot be skipped: the block after a split block is over 8 m from the one before it. The three start pads' backstops are one list now, `PgSurfIntro.backstops()`.

`headless_playground`'s **the cascade** drives it with `_drive_route`: through both splits in ~1,600 ticks, no respawns. Armed with the last gap at 6.5 m: the reach check fails and the bot stops at box 6 with two respawns. `tools/screenshot.sh pg_surf_intro` renders `pg_surf_intro_cascade` (from the west, 45 degrees down: the profile) and `pg_surf_intro_cascade_start` (over the backstop, down the staircase). **Rendering it found that the maps had no scale at all**: flat unshaded colour made a 3 m block beside a 220 m ramp two tiles, and the first profile angle showed the route as a scatter of them in front of the main run's ramp. The world-space grid fixed the first; the angle the second.

## `pg_surf_intro`'s long bank: the first face here that is surfed

Bonus 3 on `pg_surf_intro` (`BANK_TRACK`), east of the plunge at x = 110: an 8 m pad level with the other three starts at 40 m, one 20 x 140 m face **banked 56 degrees and pitched 7 degrees down its length** (its own slope, both together, 56.4 against `max_slope_angle` 46), and an 18 x 60 m finish pad 2 m past its far end and 4 m under it. pg_surf_intro had the oldest level of the three timer maps (the cascade, 2026-09-25). The main run's ramps are banked and level along their length, so they carry nobody (`[surf-ramp-1]`); the plunge is pitched and not banked, so it is a slide a player falls down holding forward. **Neither is the shape a surf map is made of, which is both at once**: a face nobody can stand on, so the only way to stay on it is to hold INTO it, pitched so that the face is what makes a rider fast. The question it asks is the one neither other surf route does: can a player hold a height on a face throwing them off its low lip on every tick? Too little and they slide off the lip into the pit; too much and they climb over the top edge.

**One description.** One slab placed by `PgSurfIntro.bank_basis()` (roll about its length first, then pitch) with its top face through `bank_near_centre()`; `bank_normal()`, `bank_surface_y(x, z)`, `bank_corners()`, `bank_far_z()`, `bank_pad()` and `bank_finish()` are all read off that, and the geometry (`_build_the_bank`), the zones (`_add_the_bank`: spawn a stride back on the pad on the riding line facing -Z, start on the pad, splits as slabs across the whole face and 6 m above and below it at a third and two thirds of its length, the whole finish pad as the finish, a reset 3 m under everything and 30 m wide of the low lip) and the suite read those and nothing else. The survey declares two new areas: the slab's high end face, which the roll tips to a standable 34 degrees over a face nobody stands on (pg_lobby's steep-ramp crest, again), and the finish pad, reached with the bank's speed, which the survey does not carry (its slide follows the fall line straight off the low lip).

`headless_playground`'s **the long bank** (21 checks): the five zone kinds on its own track and `route_problems()`, four tracks on the map, nothing thin at 30 m/s; the face's own slope over `max_slope_angle` by more than five degrees; a drop along its length (17.1 m over 139 m); the finish pad past the far edge and under it; the reset under everything; the spawn and its yaw; and a ride by `_ride_the_bank` — **the bot holds right (into the bank) while it is below the pad's line and lets go above it, and never touches forward**, game-g2gfast's single-bank rule. It rides the whole bank at x 108.9..109.0 through both splits into the finish in 1,144 ticks with no respawns: covered 143.7 m of a 145.5 m route in 8.94 s, **16.08 m/s against a 7.0 max, top 27.05 m/s**, asserted at 90% of the route and a pace floor of 2.0 x `MOVE_SPEED` (`BANK_PACE_FLOOR`; a surf route slower than running is not one). And `[surf-ramp-1]` asserted rather than printed, because this route exists to pass it: 94% of the ground and 18.0 m of the descent on the bank (of its 17.1 m drop; the rest is the 4 m fall to the finish pad), 0.2 m on anything else. The plunge and cascade sections now expect four tracks.

**Armed three ways, the section run alone**: the pitch at 0 (a level bank, the main run's shape) fails the fall check, the pace check (7.13 m/s) and the top speed (9.5 m/s) — **and the bot still finishes**, because nothing slows a rider on a face nobody stands on and it entered at a run; that is why "it finished" is not the check here. The roll at 40 degrees (standable) fails the slope check and the bot stands on the face 6 m in for the rest of the run (eight fail). Without the slab the bot drops into the reset (six fail). `tools/screenshot.sh pg_surf_intro` renders `pg_surf_intro_bank` (from the low side, above and behind the pad: the face tilted toward the camera running away downhill to its finish) and `pg_surf_intro_bank_start` (over the backstop, down the bank).

## `pg_surf_intro`'s transfer: the first route that goes from one face to another

Bonus 4 on `pg_surf_intro` (`TRANSFER_TRACK`, 2026-10-02), east of the long bank: two faces rolled 56 degrees and **facing each other across a 2 m gap** — the first (x 165..177, 70 m, pitched 10) high on the right from a pad level with the other starts, the second (x 152..163, 90 m, pitched 12) high on the left, starting a third of the way down the first with its low lip 4 m under the first's. A rider holds right down the first face, lets go and pushes left off its low lip, crosses, and holds LEFT on the second: the long bank asks one hand the whole way down, this asks for the switch, and for its timing (too early and the second face is not there yet, too late and the first ends under you). One description: `transfer_basis(face)`, `transfer_near_centre(face)` (the second placed from the first), `transfer_lip_x`, `transfer_line_x`, `transfer_surface_y`, `transfer_far_z`, `transfer_corners`, `transfer_pad`, `transfer_finish`; geometry, zones (split 1 fills the gap between the lips, split 2 across the second face, reset 30 m wide of both lips) and the suite read only those. The survey declares both high edges and the finish.

**It was first built as two faces in line, and that found a motor behaviour.** A rider leaving a pitched, rolled face over its far END is stopped dead at that edge (velocity to exactly zero, mid-air mode, on the tick it reaches it) and then slides off from rest. The long bank's rider has always done this — "rode to z -138.9 of -139.0" — and nobody saw it because its finish pad is directly under the edge and catches the slide. Leaving over the LOW LIP keeps the speed (the clip there is along the lip, the way the rider is going), so the transfer is built that way, and its finish begins `TRANSFER_FINISH_LINE` (4 m) before the second face's far edge rather than on the pad alone. The edge stop itself is the controller's and is filed for it, not worked round in the addon from here.

`headless_playground`'s **the transfer** (24 checks): five zone kinds on its own track and `route_problems()`, five tracks on the map, nothing thin at 30 m/s; both faces over `max_slope_angle` by more than five degrees and leaning opposite ways; each falling along its length, the second further; the gap and the drop between the lips; the finish pad past and under the far end; the reset under everything; and a ride by `_ride_the_transfer`, never touching forward: **first face to z -52, across, second face to the finish line in 890 ticks with no respawns, 134 m of a 120.5 m route in 6.95 s at 19.3 m/s against a 7.0 max, top 30.6**; held right on the first face (81 ticks), left on the second (245), never right on the second. Pace floor `BANK_PACE_FLOOR` (2 x `MOVE_SPEED`); at pitches 7 and 9 the bot finished at 11 m/s, which is why they are 10 and 12. `[surf-ramp-1]` asserted with this route's air in it: more descent ridden on the faces than fallen between them (the transfer and the 4 m to the finish are falls by design), nothing on anything else. Armed two ways, the section alone: both faces leaning the same way (four fail: the lean, the ride, the finish, the descent) and the second face not built (four fail: the ride, the finish, the pace, the descent). `tools/screenshot.sh pg_surf_intro` renders `pg_surf_intro_transfer` (behind and above the pair, down the valley between them) and `pg_surf_intro_transfer_start` (over the backstop, down the first face with the second across the gap).

## `pg_lobby`'s stepping stones: the first course where speed is the thing to lose

Bonus 4 on `pg_lobby` (`STONES_TRACK`), in the plate's south-east quarter at z = -56, x 9 to 58 — clear of the jump course's reset, the shallow ramp, the circuit's corner and the vehicle tests' empty corner at (-60, -60). pg_lobby was the map that had waited longest for a level (its last route work was the tower's drive on 2026-09-23). A 6 m pad at 3 m, ten stone columns standing on the plate shrinking evenly from 2.0 m to 1.0 m across, each 0.25 m above the last and alternating 1 m either side of the line, then a 4 m finish pad at 5.75 m. Gaps along the line grow 1.8 -> 2.6 m. **Every other course here rewards speed; this one asks whether a player can stop**: every jump is short (the tightest, #10, is 2.69 m of diagonal air against a 4.47 m reach, 60%) but a flat-out running jump lands past every stone (gap plus stone is at most 85% of the reach, and the suite asserts it is under 100% for every stone), so each landing means taking speed off in the air.

**One description.** `PgLobby.stone_box(i)` (the whole column, floor to top, walked edge to edge like the jump course), `stones_finish_centre()` and `stones_route()`; the geometry (`_build_stones`), the zones (`_add_stones_zones`: spawn a stride back on the pad facing the first stone, start on the pad, splits as full-width slabs centred on stones 3 and 6, a deep finish, a reset over the plate under the whole course to 1.5 m) and the suite read those and nothing else. Columns rather than floating slabs because a 1 m slab 5 m up is a speck in a frame and a column is something to aim at. The survey finds pg_lobby still clean (no slot, nothing undeclared unreached, nothing trapped) with nothing new declared.

`headless_playground`'s **the stepping stones** (17 checks) asserts the five zone kinds on its own track and `route_problems()`, sweeps reach and climb with `_check_route_reach`, asserts every stone is narrower than the last, crosses the line and is overshot flat out, puts the reset under every stone, checks the spawn and its yaw, and drives it with `_drive_route`: all eleven jumps through both splits in 1,145 ticks, no respawns. The sandbox section's track list now expects five tracks. Armed: without `_build_stones()` the bot is respawned 46 times at the pad and four drive checks fail; with the stones 3.0 -> 2.5 m wide the overshoot check fails on every stone (and the zone file drifts) while the bot still finishes — which is why "it finished" is not the check that says this is a precision course. `tools/screenshot.sh pg_lobby` renders `pg_lobby_stones` (from the north, above, square to the line) and `pg_lobby_stones_start` (behind the pad and off to one side: straight down the line the columns stand behind each other and read as one, which the first frame did).

## `pg_lobby`'s launch: the first route a player cannot get round on their own legs

Bonus 5 on `pg_lobby` (`LAUNCH_TRACK`), west of the middle at x = -50, z 2 to 44.5 — clear of the tower's reset (z 48 on) and the vehicle corner. pg_lobby had the oldest level of the three timer maps (the stepping stones, 2026-09-26). A 6 x 8 m start pad at 2 m, two 6 x 8 m decks at 5 and 8 m, and a 6 x 6 m finish at 8 m, each a column from the plate; the last 3 m of every deck but the finish is an amber booster (`PlaygroundGeometry.COLOUR_BOOST`) with a dot-timer **PUSH** zone standing on it, 1 m tall, 100 m/s² straight up. Every other route asks something of the player's movement; **this one asks them to ride something the map does to them**: the first two steps are 3 m up (2.6 times a jump's apex) and the last is level but 6 m out (past a running jump's 4.75), so no step is a jump, and every one is inside the throw.

**The PUSH is the game's, and it is new.** dot-timer has carried `Kind.PUSH` and `DotTimerRules.apply_push` since it was written, and nothing applied one. `PlaygroundPlayer._on_simulated` now does, beside the speed limit and for the same reason (it changes where the player ends up, so on the tick): the zone's acceleration times the controller's step, every tick the player is in it. Upward on the ground is a launch without touching the motor, because `DotFpsMotor._categorise_ground` puts a player moving out of the floor in AIR. So a player walking onto a booster leaves its top at `sqrt(2 (a - g) h)` = 12.6 m/s and peaks `a h / g` = 5 m above the deck (`PgLobby.launch_apex()`), and `launch_reach(rise)` is the closed-form air a player running at `MOVE_SPEED` from the booster's near edge crosses before coming down `rise` up: 5.66 m at +3, 7.48 m level. **Not track-filtered** (this said it was until 2026-10-01): dot-timer's `_rebuild_effects` takes every EFFECT zone the player is in whatever their track, so a sandbox player on the main track who walks onto a booster is thrown too. Whether effects should follow the track is a dot-timer question and Christian's call.

**Over the wire (`[playground-push-1]`, 2026-10-01).** The push is read off the timer's zone index at the state's own position (`PlaygroundPlayer.effect_zone_at`), not `timer.effect(PUSH)`. The timer's effect is where it last sampled the player, and a predicting client replays a run of ticks after every snapshot with its timer standing at the newest one, so every replay across a booster's edge pushed ticks that had been outside it. Measured before: one correction per launch, at the booster's edge, against none on the same walk with no booster. After: none. The throw on the ground moved by a tick (5.18 -> 4.81 m against `launch_apex` 5.00, still inside the 15%). `headless_net`'s **a booster throws a connected client where the server throws it** walks the launch from its pad (thrown 4.88 m by the server and 4.89 by the client's prediction, onto deck 1 in 230 ticks, 0 corrections) and the same number of ticks off the pad's back onto the plate (0), and asserts the throw costs no more corrections than the walk. Armed two ways: the old `timer.effect` (1 against 0) and a push applied on the server only (5 against 0).

**One description.** `PgLobby.launch_deck(i)` (the whole column, walked edge to edge from `LAUNCH_START_Z` through `LAUNCH_GAPS` and `LAUNCH_RISES`), `launch_boost(i)` and `launch_route()`; the geometry (`_build_launch`), the zones (`_add_launch_zones`: spawn a stride onto the pad facing +Z, start on the pad short of its booster, three pushes, splits as slabs over decks 1 and 2 from the reset to 10 m above, a deep finish, a reset over the plate under the whole line to 1.2 m) and the suite read those and nothing else. The survey declares decks 1, 2 and the finish (reached only by a launch, which it does not model).

`headless_playground`'s **the launch** (19 checks): six zone kinds on its own track (three pushes) and `route_problems()`; every step past a jump and inside `launch_reach` with a metre of deck to land on (printed per step; tightest 94%, the level 6 m throw); each push standing on its booster and straight up; the reset; a **measured throw** (a bot stood still on the first booster peaks 5.18 m up against `launch_apex` 5.00, asserted within 15%); the spawn and its yaw; and a `_drive_route` drive with every box walked, so the bot **never presses jump**: through both splits into the finish in 679 ticks, no respawns, 35.0 m of a 38.0 m route in 5.30 s, 6.60 m/s against 7.0 (`LAUNCH_PACE_FLOOR` 85%), 78% of the ground in the air and none on anything else. The sandbox section now expects six tracks. Armed, the section run alone: the last gap at 9 m fails the reach check and the bot is thrown short into the reset three times (five fail); without the push in `_on_simulated` the throw is 0.05 m and the bot walks off the pad fifteen times (five fail). `tools/screenshot.sh pg_lobby` renders `pg_lobby_launch` (the profile, from the empty east side) and `pg_lobby_launch_start` (from behind and above the pad).

## Where `pg_lobby`'s routes get their ground and their descent (`[surf-ramp-1]`, 2026-09-27)

`pg_surf_intro`'s main run was found to "surf" on ramps that are level along their length. The question that found it, how much of a route's ground and descent happens on the thing the route is named after, has now been asked of every timed route on `pg_lobby`. **`pg_lobby` has no surf route at all.** The main track is the sandbox with no start or end zone, so it is not timed. Bonus 1 (the jump course, platforms), bonus 2 (the tower, platforms) and bonus 4 (the stepping stones, stone columns) are jumping courses that all CLIMB, so their net descent is negative by design. Bonus 3 (the circuit, the road) is flat and driven. The movement corner's shallow and 55-degree ramps are on no track. So the surf form of the question does not apply here. Its jumping form does: does the bot's ground come from the route's own surface, and does any of it come from something else?

**The answer is "from the thing it is named after" on all four routes.** No route is somewhere other than its name, so nothing here waits on Christian. As printed by `headless_playground` (each tick is classified by what the player was on when the tick started, and a respawn teleport is left out):

| route | covered, of route | on its surface | in the air | anything else | descent: on surface / air / else |
|---|---|---|---|---|---|
| jump course | 76.4 of 80.4 m | 28.0 m platforms (37%) | 48.4 (63%) | 0.0 | 0.0 / 5.5 / 0.0 m (15.0 m up, route +10.4) |
| tower | 77.6 of 78.9 m | 16.7 m platforms (22%) | 60.9 (78%) | 0.0 | 0.1 / 9.3 / 0.0 m (19.1 m up, route +10.2) |
| stepping stones | 49.3 of 49.9 m | 9.8 m stones (20%) | 39.5 (80%) | 0.0 | 0.0 / 9.9 / 0.0 m (12.4 m up, route +2.8) |
| circuit (buggy) | 587.2 of 599.4 m | 587.2 m road (100%) | — | 0.0 | 0.6 m of suspension bob, flat |

The descent on the jumping routes is the second half of each jump's arc, which is right for a flat-topped box. Most of the ground is covered in the air, as a jump course's should be, and none of it on the plate or anything else. `_motion_tally`/`_tally_tick`/`_print_where` do this. `_drive_route` returns the tally as `tally`; the jump course and the circuit have their own drivers and keep one inline. **What is asserted is only the stable half**: under 1 m of ground and 0.1 m of descent on something other than the route's boxes (jump course, tower, stones), and at least 95% of the lap on the road (circuit). The split between surface and air is printed and not asserted. Armed: counting the start pad as "something else" fails all three foot checks (16.9, 24.2 and 18.8 m), and narrowing the road to 2% of its width fails the circuit's (280 of 582 m).

**Every route drive prints its pace now (`[bot-drive-1]`)**, the ladder's line through `_print_pace`: "covered X of a Y m route in T s: V m/s against a max". `_check_pace` holds each drive to 90% of the route and a pace floor set just under what it measured. The route length (`_route_length`) is centre to centre, so a bot cutting corners covers less than 100%. Measured and floored: narrows 6.85 m/s (floor 90% of 7.0), jump course 6.68 (85%), switchback 6.57 (85%), cascade 6.47 (85%), ascent 6.31 (80%), tower 5.94 (75%), stepping stones 5.51 (70%; it is the course where speed is lost on purpose), ladder 6.73 (its own 60% check), and the circuit's buggy 21.75 of 24.0 (80%). The plunge is not a route drive (it holds forward) and keeps its own top-speed print. Armed with every bot at 40% of its stick (and the buggy at 40% throttle): all eight new pace checks fail, at 1.8 to 2.7 m/s and 16.3 m/s.

**Found, not changed:** `pg_lobby.gd`'s `CIRCUIT_SEGMENTS` note says 64 chords over "a 387 m lap" leave under 9 cm of scallop. The loop is 611 m, so each chord is 9.6 m, and on the 26 m corners that leaves about 0.44 m (c²/8r) between chord and arc. The buggy still drives 100% on the road, but the comment's reasoning is wrong. More segments would change a scored track's surface, so that is Christian's call. The circuit section's "387 m" above has been corrected to 611.

## Every hand-built map is surveyed (`[gate-sweep-2]`)

`PlaygroundMapSurvey` reads a built map's boxes (every `StaticBody3D` with a `BoxShape3D`, rotated or not), rasterises them into 0.25 m columns of solid spans, and asks three things: **slots** — two boxes facing across less than 0.8 m (the family's player width) over more than a step's height; **unreached** — standable ground (face within 46 degrees, 1.8 m of headroom, nothing in the hull's neighbouring columns) that no spawn leads to by walking, dropping, sliding down a face nobody stands on, or a jump inside `jump_reach(rise)`; and **trapped** — ground a spawn leads to from which no spawn, finish zone, respawn zone or fall into one is reachable. Reimplemented from a description of game-arena's `arena_map_survey.gd`, not copied.

**Unreached is allowed only where the map says so**, in `PlaygroundMap.survey_declared()` — `{box, why}` per area: the lobby's wall tops and the crest strip of the movement corner's 55-degree ramp (its end face, tilted 35 degrees, 16 m up); the surf map's four backstop tops and the long bank's high edge and finish pad; and `pg_bhop_intro`'s main run past block 8, whose gaps outgrow a running jump and are crossed with carried bhop speed, which the survey does not model. **None of the three maps had a real problem**: no slot, no trap, nothing unreached that was not one of those.

What it does not model, on purpose, and each errs toward reporting: a jump is judged box edge to box edge from above and not swept through the air; there is no carried speed; a tilted box is its world AABB for the slot sweep. `pg_generated` is not surveyed: it is not hand-built and `PlaygroundWorldGen`'s validator floods it on every seed.

`headless_playground`'s **the hand-built maps, surveyed** first asks the survey about a fixture with one of each thing in it (a 0.5 m slot, a platform 5 m up, a cellar dropped into) and asserts each is found and that a declaration and a reset quiet them — so a clean map is known to have been looked at — then asserts four things per map and prints cells, regions and time (~4.6 s for the lobby's 640,000 cells, under a second for the others). Armed on the real maps: the lobby with no declarations and a box 0.5 m beside the surf map's backstop each fail their check.

## A client's prop mirror is on the props layer (`[prop-mirror-layer-1]`)

`PlaygroundNetBridge._apply_prop` classifies the mirror with `Playground.layer_for(def, frozen)`, the same answer the server's `_classify_spawned` uses (a crate: layer 8, mask 196719). It kept the scene's 1/1 until 2026-09-25, which made a crate world geometry to a client that now predicts its own player against its own copy of the world. **Still missing:** the PROP event carries no frozen or held state, so a mirror is classified as an unfrozen spawn, and a prop frozen or grabbed later is reclassified on the server only — `Kind.HELD` (below, "not here") is where that would travel. `headless_net`'s prop section asserts the mirror's layer and mask equal the server body's (armed: 1/1 against 8/196719).

## A map change clears `return` (`[modtools-return-1]`)

`PlaygroundModule` calls `DotModTools.clear_history()` from `DotMapSession.changed`. Every entry is a point on the map just freed, so `return Pat` after `map <id>` put Pat where they had stood on the previous map. `dedicated`'s live-tools section moves Pat, changes the map, asserts `return` has nowhere to put them, and changes it back (armed: Pat returned to a pg_surf_intro spot on pg_bhop_intro).

## Custom maps are documents (game-playground-maps, 2026-10-07)

`maps/pg_data.gd` (scene `maps/pg_data.tscn`) builds a map from a JSON document: boxes (centre, size, colour, an optional turn), a spawn and yaw, and the areas the survey may find unreached. `Playground.map_catalogue()` adds every document in `maps/custom` (game-playground-maps' `maps/`, linked by dot-bootstrap) as a `DotMapDef` with `meta.doc`; `_on_map_changed` calls `configure_doc` before anybody is spawned, `pg_generated`'s pattern. **Documents, not scripts**, because a map delivered in its own pack is mounted at another prefix and a script there that extends this game's map base by path is right in only one of the two places it runs. Delivered, the pack is a `dependencies` entry (a client builds the map too): `PlaygroundModule._add_delivered_maps` adds `<mount>/maps` from the game manager's dependency keys, and `PlaygroundClient` adds the same from `DotClientLink.content_extra`, both through `Playground.add_map_directory`, which also rebuilds the rotation. An id already in the catalogue is never replaced. `headless_playground`'s survey section surveys `CUSTOM_MAPS` (5 checks each) and its boot check counts them; `dedicated`'s map commands load `pgc_quarry` with `map`; `tools/screenshot.sh pgc_plots` / `pgc_quarry` / `pgc_slopes` renders them. The deploy wiring (a `tmc/playground_maps` pack in dot-server-deploy and the `dependencies` line) is written down in game-playground-maps' CLAUDE.md and not done.

### A map document can carry props (2026-10-07)

`props` and `wires` are optional fields of the map document (`maps/pg_data.gd`; every older document still reads): catalogue ids with a position, a yaw, frozen (the default) or loose, and optional tint, scale and physics; wires join two of them by index through `DotPropIO`, as the tool gun's Wire mode does. `Playground.spawn_map_props` puts them down on the server in `_on_map_changed`, after `configure_doc` and before anybody spawns, owned by `Playground.MAP_OWNER` (`map`, never a player id, so no player's limits, undo or "remove mine" reach them; the remover still does where `touch_others_props` allows, which is what a sandbox map's props are for, and a map reload puts them back). The spawn rate limit is lifted for the load, because a map's props arrive in one frame. A door keeps the transform the map stood it at as its shut position. **An id this server's catalogue lacks is left out with a WARN, not the map**: a map is boxes first. A client gets them through the prop path like anything else: `headless_net`'s *a map's own props over the wire* (4: the client follows the server to pgc_town, mirrors all 44, its five doors among them, and spawns none itself). That last one is held by dot-props, whose non-authoritative spawner refuses every spawn; arming Playground's own `authoritative` guard changed nothing, and the guard stays only to keep a client from logging a false "props this server does not have" WARN. `headless_playground`'s *a map's own props* (6: pgc_town's doors, buttons and buggies, furniture frozen and crates loose, a button opening its wired door a quarter turn from where the map stood it, a missing id skipped, a map change clearing them); `tools/screenshot.gd` draws them from the real prop scene and catalogue. `tools/map_props.gd` (`godot --headless --path . --script tools/map_props.gd -- [map ...]`, every custom map by default) loads maps through the real game and prints each one's prop counts and every prop that moved more than 0.5 m or fell out of the world in five seconds, exiting 1 if any did: furniture that drifts or a stack that topples is invisible to the survey, which reads boxes.

### Map materials: what a box is made of (2026-10-07)

A map document's box may name a `material` (`game/playground_materials.gd`): one of dot-physics' fifteen standard surfaces — concrete, metal, wood, glass, dirt, grass, sand, snow, ice, flesh, water, rock, mud, rubber, lava. **The numbers are dot-physics'**, read once: the solver's friction and bounce go on the box (`to_physics_material`), and the player's movement comes from the same entry through dot-player-controller's `DotFpsSurface.from_physics`, set as every player's `controller.surfaces` and found from the box's `dot_fps_surface` metadata, which a client and a server both build from the one document (so the prediction agrees). The only thing this game adds is each material's look (`LOOKS`; alpha under 1 is see-through, and `PlaygroundGeometry._material` draws those both sides). **A liquid (water, lava) has no collider at all**: it is a see-through volume the map records (`liquid_volumes()`, axis-aligned, a turned liquid is refused), and `Playground.liquids` holds them. Lava, on the authority (`_liquid_tick`): a player whose feet are in it is hurt through `hazard_hurt` (the arena's `hurt`, set by the module) and sent back to the spawn when that does nothing (the arena off), and a prop in it for `MELT_SECONDS` (1) is removed. **Water is swum in and floated on** (next section). `headless_playground`'s *map materials* on pgc_nature (7, measured and printed): an ice box is ice to feet and solver; the liquids recorded; speed kept 24 ticks after letting go 34% on grass, 91% on ice; top speed 6.68 m/s on grass, 2.30 in mud; jump 1.12 m on grass, 3.68 m off rubber; lava sends a player to the spawn and melts a crate; a crate dropped on the pond sinks to its bed. **Writing it found the suite's own mistake twice**: a jump pressed on one tick of a player still falling from a teleport measured nothing, and a crate dropped onto the lava pit's bridge did not melt.

### Glass breaks (2026-10-07)

A map box whose material has dot-physics' `break_health` (glass, 25) is a **pane**: `Playground.panes` (box index -> node, health, material), rebuilt per map by `_index_panes`, with `broken_panes` the ones gone. `hurt_pane` is the one door, as `hurt_prop` is for props. Three things call it:
- **shots**: a player's zee shot and an armed NPC's, in `player_shots_fired` / `npc_shots_fired`;
- **blasts**: `hurt_panes_in`, from `PlaygroundProjectiles._detonate`, because the blast's shape query returns no world geometry;
- **fast impacts** (`_pane_impacts`): a prop or a player moving into a pane faster than `PANE_IMPACT_SPEED` (6 m/s) **along its normal**, read from last tick's velocity because the contact has already stopped the body. Running ALONG a greenhouse wall is not running into it; running into the end of one is.

`break_pane` removes the box and emits `pane_broken`. On the authority it also throws shards: `debris` props in the pane's colour that expire like a broken prop's. The bridge broadcasts `Kind.PANE` (last) with the index, and tells a joiner every broken one. A client's `break_pane` removes its own copy and emits the same signal, which `PlaygroundClient` plays `glass_break` from. `pg_breakable_glass` (`PlaygroundConfig.breakable_glass`, on) is separate from `pg_destruction`, because glass in a map is put there to be broken.

The checks:
- `headless_playground`'s *glass breaks* on pgc_nature's greenhouse (11): the six panes; a sprint alongside one breaking nothing; off breaking nothing; a real pistol shooting one out with shards and one signal and no collider left; a blast; a crate nudged into one leaving it and one thrown into it breaking it; a map change putting them back. Armed by dropping the shot branch: four fail.
- `headless_net`'s *glass broken on the server is gone on the client* (4).

**Writing it found three mistakes in the suite, none in the game.** A settle drive's empty command turned the bot to yaw 0 and put the pistol's shots into the north wall. The first sprint path ran into the north wall's END and broke it, correctly. And firing a tick at a time with no frame between hands the rig one tick, which fires once.

### Water: swimming and floating (2026-10-07)

**Players swim** through dot-player-controller's `DotFpsSwimMode`. It is one per player, in `controller.extra_modes` so a style's rebuilt motor keeps it under the same id on every machine. Its water comes from `Playground.water_boxes()` (the map's water liquids), set on every map change and on joining (`PlaygroundPlayer.set_water`). It is entered from `_on_simulated`, which a prediction replay also runs.

**Props float** on the authority (`_float_props`, in `_liquid_tick`). Each gets buoyancy by the liquid's density over the volume submerged, drag from its `dampening`, and the bob damped critically at 2 sqrt(k). Critical damping, and applied whenever touching rather than scaled by depth: a crate the catalogue makes fifty times lighter than water first shot a metre out of the basin, and then bounced on lava half a metre high for ever. A prop's density is the catalogue's `density` meta where given (`PlaygroundSpawnables.DENSE`: boulder 2600, slab and pillar 2400, die 1200, because the catalogue's masses are tuned for a physics gun and make a 3 m boulder lighter than water) and its mass over its volume otherwise. A prop that has touched lava melts `MELT_SECONDS` later whether or not it bounced clear, because a timer reset by each bounce let a floating crate ride a lava lake.

pgc_harbour's basin is real water now (3.4 m deep, its surface 0.6 m under the quay).

**A splash** is the client's own: `PlaygroundClient._present_splashes` watches players, props and (connected) prop mirrors against this end's copy of the map's liquids and plays `PlaygroundPresentation.on_splash` (a `splash` sound and a puff on the surface) when one crosses in. Nothing travels for it, because both ends build the liquids from the document. Half a metre over the surface counts as in, because a crate floats with its centre above the water and, asked of the box alone, never splashed. `headless_playground`'s client section drops a crate into pgc_nature's pond and counts it (waiting on physics ticks: ninety unthrottled headless frames passed before the crate had fallen).

The checks:
- `headless_playground`'s *water: swimming and floating* (8): a player who falls in swims and floats with the head at the surface (-0.59 against -0.60), swims at 4.0 m/s; a crate and a barrel float and settle; a boulder sinks to the bed; no water leaves nobody swimming. *map materials*' pond check now expects a crate to float.
- `headless_net`'s *swimming, predicted by a connected client* (4): walking down a slipway into the basin and swimming, 0 corrections in 320 ticks, ends 2.8 cm apart. **It cannot see the client's own entry**: armed with entry on the server only, it still passes, because the mode travels in the snapshot and this link is short. The client's entry is what keeps a real round trip from showing a player walking on the bed.

**Release:** the client shell needs the new dot-player-controller (`DotFpsSwimMode`, `extra_modes`) and dot-physics before a playground pack using them is published.

### Thin ice, slime, foliage (2026-10-07)

Three more of dot-physics' surfaces:
- **Thin ice** (breaks at 8) is a pane like glass. An impact on a floor-like pane is now tested at the feet as well as the chest: the first version asked only the chest, which is a metre above ice a player lands on.
- **Slime** is a swimmable liquid that burns. `PlaygroundMaterials.is_swimmable` is liquid with a density at or under `SWIM_DENSITY` (1200), so water and slime, and not lava. Its hazard goes through the same `hazard_hurt`-or-spawn path as lava.
- **Foliage** is not solid. `is_volume` (liquid or not solid) builds a box with no collider, so it is drawn, walked through and hidden in; foliage is recorded nowhere else.

pgc_nature gained a frozen lake (deep water under thin ice, a diving board 3 m over it), a slime swamp with stepping stones, and bushes. `headless_playground`'s *thin ice, slime and foliage* (6): a walker stands on the ice and it holds; a drop off the board goes through into the water, swimming; slime sends a player to the spawn with the arena off; a bush is walked straight through. *glass breaks* now counts the glass panes by material, and the map has seven panes with the ice.

### Hibernation (2026-10-07)

The module follows the server's hibernation with both map clocks: `vote.director.follow_hibernation(server)` and `game.maps.follow_hibernation(server)`. An empty server idles from boot (dot-server's `sv_hibernate_when_empty`, 1) and its clocks start again from the top when somebody joins. With it off, dot-vote's `empty_choice` (random) changes the map when the limit runs out on nobody. `on_no_votes` (keep, or random / rotation) decides a ballot nobody voted in. All of it is dot-server's, dot-vote's and dot-map's; this module only wires it, because it is not on DotGameModule, which does it itself. `dedicated`'s vote section asserts both connections.

## Maps are content, not projects

Three maps, one game. See [dot-map's CLAUDE.md](../dot-map/CLAUDE.md) for why a
project per map falls apart at map forty.

**The built-in maps build their geometry and their zones from the same constants**, in
one script, so a start line cannot drift half a metre from where the ramps actually
are — which would be a leaderboard nobody can compare with anybody else's.

A **delivered** map cannot do that: it ships geometry and a zone file. So
`tools/export_zones.gd` writes those files from the same source, they are committed,
and `examples/headless_playground.gd::_test_zone_file_matches_the_map` checks that the
file still matches what the map builds. A hand-copied zone file is correct exactly
once.

**Run the tool after changing a map**, or the check fails:

```bash
godot --headless --path . --script tools/export_zones.gd
```

`pg_lobby`'s **main track** has no timer, and that is not filler: it is the one place
that proves the rest of the game does not quietly require one. Its bonus track does —
see above.

## The movement is a bhop server's, not the addon's defaults

`PlaygroundPlayer._tunables` differs from `DotFpsTunables`'s defaults in five places
and every one is the genre:

| | Default | Here | Why |
| --- | --- | --- | --- |
| `auto_hop` | off | **on** | Otherwise the skill is a keyboard-hardware contest, not an aiming one |
| `bhop_speed_cap_scale` | 0 | 0 | Kept at 0 explicitly. A cap is what those shooters added to *stop* bunny-hopping |
| `crease_slide` | on | on | Kept explicitly: a surf map is made of seams |
| `coyote_time` | 0.1 | **0** | Free speed on a timed map, and a run set with it is not comparable |
| `jump_buffer_time` | 0.1 | **0** | The same |

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . --script tools/export_zones.gd
godot --headless --path . res://examples/headless_playground.tscn   # 865 checks, 47 sections
godot --headless --path . res://examples/headless_stack.tscn        #  40 checks
godot --headless --path . res://examples/headless_presentation.tscn # 107 checks
godot --headless --path . res://examples/headless_net.tscn          # 351 checks, 42 sections
godot --headless --path . res://examples/dedicated.tscn             # 244 checks, 27 sections
```

**`dedicated` counts both now.** It had neither a section counter nor a CHECKS total until 2026-09-24, so a section a runtime error aborted part-way would have left "0 failed" and exit 0 with checks missing. Each section's last line is `_section_done()`; `SECTIONS` and `CHECKS` were armed one each way (exit 1). `headless_net` and `headless_playground` count both too, since a119ad1.

**Run the check-only pass first.** A script that fails to parse makes the scene fail
to load and the process then **hangs** rather than exiting.

**And read the suite's own stderr even when it exits 0.** A script error inside a test
aborts *that test* and not the run, so the checks after it never execute and the total
goes down rather than the suite failing. It happened here: a call to a method
`DotTimerZone` does not have took two checks out of a run that reported 201 passed and 0
failed.

**`tools/screenshot.sh <map>` renders a map so a person can look at it.** It needs
`xvfb-run` — `--headless` gives a null renderer and saves empty frames, which is worse
than no screenshot because it looks like one. Copied from `game-arena`'s rather than
shared with it, because these are separate repositories. Two of the three problems above
were found by a bot; the finish cap being invisible behind its own pillar was found by
looking at the picture.

Every addon's own suite still has to pass too — this one exercises the joins and
deliberately does not re-test what they cover.

## A vehicle is a prop with seats in it

`dot-vehicle` is installed here for the same reason `dot-npc` is: for the half this game
was going to get wrong. What it is **not** used for is spawning.

**Every vehicle arrives through `DotPropSpawner` and is handed over with
`DotVehicleSpawner.adopt()`.** That is the whole design and it is the same call the
entities make one paragraph up: a vehicle is a `DotPropInstance` first — it counts against
the prop budget, it is on the undo stack, it goes when its owner leaves, a physics gun can
pick it up and a gravity gun can punt it. `adopt()` did not exist before this; it was added
to dot-vehicle for exactly this deployment, and its CLAUDE.md says why.

The join is one field of `meta`, exactly as an entity's script path is:

```json
{ "kind": "vehicle", "vehicle": "buggy" }
```

`PlaygroundVehicles` is the second catalogue and it is deliberately not merged with the
prop one: `DotPropCatalogue` says what may be put in the world and what it costs, and
`DotVehicleCatalogue` says how a thing drives. **The prop rows are derived from the vehicle
rows**, so the mass a physics gun checks and the mass the chassis puts on the rigid body
are the same number read once — the two-hand-kept-copies shape that already gave dot-props
a prop a gun refused for being too heavy and a gravity gun threw like a beach ball.

### What building it found

- **A wheel above the chassis box is a car that does not move.** `PlaygroundProp` builds a
  collision box centred on the origin, so a 0.9 m body reaches 0.45 m down; wheels at
  `wheel_y = 0.15` with a 0.42 m radius contact at 0.27 and never reach the floor. The box
  rests on the ground, the wheels hang in the air, and a raycast vehicle with nothing in
  contact has no traction, no steering and no brakes. **Every number in the tunables reads
  correctly** and the car sits there at full throttle. `wheel_y` is negative here for that
  reason and the suite counts the wheels separately from measuring the drive, because "no
  wheels" and "wheels that touch nothing" are the same symptom.
- **`configure` must run before `adopt`.** `DotVehicleWheeled` walks the body's direct
  children for `VehicleWheel3D` once, at bind time, and caches what it finds. The other
  order gives four wheels nothing drives.
- **`continuous_cd` is turned back off for a vehicle.** `PlaygroundProp` turns it on
  because a sandbox throws things; on a body with wheel raycasts under it, it fights the
  wheel solver and the car judders at speed — which reads as bad suspension.
- **A rider's node is carried and their movement state is not.** dot-vehicle reparents the
  rider into the seat, which is what puts a client's camera on the vehicle without a line
  about cameras anywhere. But the timer, the NPC candidate list, the HUD and
  `PlaygroundPlayerNet` all read `controller.state.position`, and nothing was writing it —
  so a passenger is drawn on every **other** machine at the spot where they got in, for the
  whole journey, while being perfectly correct on their own. `Playground._carry_riders`
  copies it back, after the vehicles tick and before the timers are fed, which is the same
  ordering rule the players already follow.
- **The controller is turned off, not ignored.** `PlaygroundPlayer.riding` skips
  `simulate_tick` while still sampling, because those same keys are what the car is driven
  with — `Playground.drive_command` is the whole mapping and it is static so a test can
  reach it without a player.
- **A riding client must stop predicting.** `PlaygroundPlayerNet` has two new branches: no
  `simulate_tick` while riding, and the server's position IS written onto the node even on
  a predicted entity, because there is no replay to spoil.

### The suites, and the one thing that is a harness artefact

`headless_playground` drives it in one process; `headless_net` drives it over the socket,
which is the only place `DotVehicleNetSync` has ever been. **In `headless_net` the client's
mirror is taken out of the physics world for the drive.** Both halves are plain nodes in
one scene tree, so they share one physics space and the frozen mirror sits at exactly the
coordinates the server's car is trying to leave — the first version of that test measured a
car reversing at half a metre a second, which was the server's buggy wedged against its own
reflection. On two machines there is no such body.

**Also worth knowing before writing a test here: a car crosses this sandbox in seconds.**
The first version drove into the scenery at (24, 24) and then measured a stationary vehicle
at full throttle. The corner at (-60, -60) is the flat, empty one.

### What a driver feels (`[veh-3]`, measured 2026-09-27)

dot-vehicle does not predict a vehicle, so the driver's keys go to the server and come back as a snapshot, and the car they sit in is the client's interpolated mirror of the server's. `headless_net`'s vehicle section measures it (`_measure_round_trip`) on a loopback holding every message **3 ticks each way (23 ms, a 47 ms round trip)** with **every third snapshot dropped**, at 128 Hz with 32 Hz snapshots; the adaptive interpolation buffer settles at **8 ticks (63 ms)**. Every run prints:

| | median / p95 / max |
|---|---|
| mirror vs the server's car, driving (~4 m/s) | 0.20 / 0.35 / 0.42 m, 0.05 / 3.1 / 4.1 deg |
| how far back along the car's own path the mirror is | 9 / 11 / 11 ticks (70 ms median) |
| the mirror's per-tick step against the car's | 0.33 / 5.6 / 10.0 cm |

- **Throttle, from rest:** the server's car moves (1 cm) 16 ticks after the key; the mirror, **24 ticks, 188 ms**. With no transit the car moves at 13, so 11 of those ticks are the car's own physics and **13 (about 100 ms) are the wire**: input lead, transit both ways, the wait for a snapshot and the interpolation buffer.
- **Steer, at speed:** the car's heading leaves its line (1 deg) at 19 ticks; the mirror's at **29 ticks, 227 ms** — 14 of the car's own, **about 15 (117 ms) the wire**.
- **The mirror's heading is not interpolated.** While turning it held still on **26 of 31 ticks**. `DotVehicleNetSync` sends the rotation as four `INT` quaternion components marked interpolated, and dot-net's `DotNetInterpolator._blend_value` blends only floats, vectors, quaternions and colours — an int is discrete and switches at the midpoint. So the position slides and the body snaps round at the snapshot rate (16 Hz across a drop). `net_steering` and `net_speed` are INT/UINT too and step the same way.

Asserted, and armed: the mirror responds to throttle and to steering within 40 ticks and never before the server's car does (armed with 40 ticks of transit: both fail; the first armed run also caught the mirror "responding" at 16 ticks to a car that moved at 50, which is why the not-before-the-car half is there), and the mirror lands within 5 cm and 1 deg of the car within 64 ticks of it stopping (armed by dropping every snapshot while it brakes). The figures are printed beside the checks; the bounds are generous on purpose.

**Decision: no renderer-side smoothing of the mirror's POSITION, and do not predict.** The position is already interpolated and moves an even step a tick (0.33 cm median error at 3 cm a tick). Every smoothing filter on top of it is more latency, and latency is the one thing the driver already has too much of: about 100-120 ms of wire on a 47 ms link, of which the interpolation buffer is the largest single term. **The heading is the thing worth fixing, and at the wire rather than in the renderer**: either `DotVehicleNetSync` declares its rotation as dot-net's `QUATERNION` type (the type is a string there, so it still names no dot-net class), or dot-net blends an interpolated `INT` linearly. Both are outside this repository; that is the next item. The other lever is the driver's OWN car drawn with a smaller interpolation buffer than everybody else's — about 60 ms off key-to-visible, bought with visible stepping whenever a snapshot is lost. That trade is Christian's.

**The bus case, not measured here.** `mg-buses-from-hell`'s bus is four tonnes that take about a second to answer the throttle. The wire's share is the same ~100-120 ms whatever is being driven — it is the link, the snapshot rate and the buffer, not the vehicle — so on the buggy it more than doubles key-to-visible (11 ticks of car, 13 of wire) and on the bus it is about a tenth of a response that already takes a second. That is the argument that game's notes make, and these numbers support it. The heading snap is smaller per snapshot on a bus as well (its yaw rate is lower), and the camera behind a bus is further out, so the same snap covers fewer pixels. Measure it there before believing either sentence.

**A harness trap found on the way:** `PlaygroundClient.present_frame` interpolates only while the client's manager is RUNNING, and this suite's client is not started until "somebody else has a body". Driven through `present_frame`, the first version of this measurement drew the newest snapshot every tick and reported a mirror stepping at the snapshot rate that no real client has. The measurement calls `interpolate_frame` directly for that reason.

`F` gets in and out. Not `E`, which already spawns here — and the day this game gains a use
verb, the two want swapping together.

## A price list, a camera, and being picked up

Three addons joined in one pass, and each one is the answer to something this project had
been asking without a way to say it.

### `pg_shop`: a sandbox with prices

**Off by default, and the cvar is the whole argument.** A sandbox where everything is free
is a sandbox; a sandbox where a jeep costs four hundred credits is a *game*, and turning
one into the other because an addon was installed is exactly what this family's rule about
cvars exists to prevent.

A free spawn menu has no pacing: the first thing anybody does is fill the map with the
most expensive thing in it. A price list makes the wave mode worth playing — a wave pays,
a jeep costs, a player who spent everything on turrets has to earn the next one — and it
needs no new mechanic, because everything it wants is already here.

**The price list is derived, not authored.** `PlaygroundShop.catalogue()` walks the prop
catalogue and the weapon list and prices each entry from its mass, its size and its budget
cost. A hand-written list of fourteen props is a list that goes stale the first time
somebody adds a fifteenth, and this tree has shipped that bug four times in shell scripts
alone.

**Money is not the budget.** `DotPropLimits` still caps how much one player may have in
the world, because a filled map is a server nobody else can play on, and credits must not
be a way round that.

The charge happens through `PlaygroundNetBridge.charge_fn` — a callable, not a reference to
the shop, because the bridge is dot-net's half of this game and knows nothing about prices.
Unset, everything is free, so no call site has to branch on whether a shop exists.

**A spawn is asked, placed, and only then charged** (`_spawn_for`, with `may_charge_fn` = the shop's `may_have`). Until 2026-09-25 it charged first and spawned second, so a spawn the prop budget refused had already been paid for — the exact report `PlaygroundShop.charge`'s own comment says a shop must never produce, in the one caller that ignored it. Refunding on a refusal was the other fix and is not atomic: dot-economy's refund is a policy (off with `refund_ticks` 0, off for a non-refundable item, closed with the buy window), so it can itself be refused on precisely the servers that turned refunds off. The spawner's refusals are many and only known by trying; affordability is one read that changes nothing, and `buy` is `may_buy` plus the debit, so the two cannot disagree. A charge that still fails after the spawn — a `charge_fn` with no `may_charge_fn` beside it — takes the prop back out and says so at WARN. `headless_net`'s "a spawn the prop budget refuses costs nothing" fails on the old order (armed).

### `pg_spec`: a sandbox is where watching is not about being dead

The interesting thing on a server like this is usually what somebody else is *making*, and
the answer to "what is that noise in the corner" is a camera. So the policy is the loosest
of the three games that have one — anybody, alive or dead, may watch anybody, and roaming
is on, because a free camera is how you look at a contraption from the outside.

It tightens the moment `pg_arena` goes on. A living player watching a living one while they
are shooting at each other is a wallhack, and that is exactly the moment this stops being a
sandbox.

### `pg_waves` also turns on being picked up

**The wave mode is the only co-operative thing in this family, and this is what makes it
one.** Until now a player killed by a wave respawned on a timer, so the other players
carried on shooting and nothing about the wave was harder for having dropped somebody.
The co-operative survival shooters' answer is the one every game since has copied: at zero health
you go **down**, you bleed out over ninety seconds, and picking you up costs somebody five
seconds of not shooting.

**One place decides.** `PlaygroundArena.death_rule_fn` is asked before a death is reported,
and a downed player is not reported to dot-match at all — the scoreboard has not lost
anybody, the respawn queue must not start counting, and the kill feed would be announcing a
death that did not happen. A game that asks "are we in a mode with incapacitation" at every
damage site has as many copies of the rule as it has damage sites, and the copies drift.

It shares the `pg_waves` cvar rather than having its own, because being killed by a wave is
what being downed is *for*: a separate switch is an operator who turned the waves on and
wonders why nobody is being picked up.

### The bugs the suite found

**A weapon was never asked for, so nobody ever paid for one.** `PlaygroundShop.catalogue()`
prices every weapon at 350 credits, and `PlaygroundNetBridge._give_weapon` — the only thing
in this game that calls `charge_fn` for one — was called by nobody. `PlaygroundClient._set_tool`
sent `ask_tool` for the physics gun and the gravity gun and said **nothing at all** for a
weapon: it loaded the script, armed it, and told the server none of it. So on a networked
`pg_shop` server every weapon in the catalogue was free while the props beside them were
correctly charged, and nobody else was told what anybody was holding either.

Nothing errors, for the reason this file keeps writing down: **a client that arms itself
looks exactly like a client that was given one.** The one visible difference is a number
that did not go down, and nobody watches a credit balance for the thing that did not
happen.

The other half is the same bug pointing the other way. The server *does* broadcast what
each player is holding — `_select_tool` has sent `Kind.WEAPON` since it was written — and
the client's reader for it was a bare `pass`. `PlaygroundEvents.write_weapon` had a
`read_weapon` beside it that nothing called, which is the mechanical detector this family
uses for exactly this: **an encoder and a decoder that have never met.** `Kind.HELD` still
has that shape and is listed under "not here" below.

Arming stays local, because a weapon switch that waited a round trip is a weapon switch
that feels broken — but it is *prediction* now rather than a decision, and
`weapon_changed` is the correction: a purchase the shop refuses takes the weapon back
out of the player's hands instead of leaving them holding what the notice just denied
them.


**Two unknown players are zero metres apart.** `PlaygroundDowns._position_of` answers with a
sentinel far away for somebody it does not know — which is right — but *two* unknown ids
then sit at the **same** sentinel, so every distance check between them passes. A rescuer
who does not exist revived a casualty who did not exist, and the only symptom was a player
who should have bled out standing back up. `begin_revive` now refuses unless both are real
players. It is this family's usual shape: a guard that is correct for one argument and
wrong for two.

**And one player had two entity ids, depending on which modes an operator had switched on.** `PlaygroundArena` minted them for dot-combat out of a counter of its own, and that layer only runs when the waves mode is on — so `PlaygroundDowns`, which is a *separate* switch, fell back to `abs(String(player_id).hash())` whenever the arena was off. The comment above that fallback said what it cost, in words, and shipped anyway: *"answering differently in the two is how a player who is down in one system is up in the other."* A hash is worse than a second spelling of an id, because it is not an allocation — two names can collide, and the number it produces is stable, plausible and not the one the health and the kill feed use.

The fix is not a better fallback. `Playground.entity_table` is a `DotEntityTable` and the **game** opens a player's entity on join, before any layer exists to want one: a handle whose existence depends on a mode is not a handle. Both layers ask the table now and neither can answer differently. `admit` still opens one for an id the game itself never saw — an operator putting somebody in the waves mode who is not a `PlaygroundPlayer`, which the dedicated suite does by hand — and closes that one on release; whose entity it is is decided by whose **node** it holds, before `_forget` frees anything, because it cannot be decided afterwards.

It is called `entity_table` and not `entities` only because `Playground.entities` is already the sandbox's own list of spawned `PlaygroundEntity`s. The other three games call theirs `entities`. The day those two concepts merge — a sandbox entity *is* a world object with an id — is the day this one takes the name.

## The eight addons this game gained at once

This is the only project in the family holding **all eight** of the new ones, and the three
it has to itself are the three a sandbox is the only home for.

### `pg_generated`: the one map nobody wrote down

Every other map in this family is a `_build()` full of constants, which is the right shape
for a level somebody designed. This is the exception, and the argument is specific rather
than general: **a sandbox's content is what the players build in it**, so "somewhere new"
is worth more here than "somewhere good" — and it is the one map where a layout nobody has
memorised is a feature.

`PlaygroundWorldGen` is the pipeline: BSP rooms with big leaves (a maze of cupboards is the
failure mode of every BSP generator set for a dungeon), corridors three cells wide with
**loops on purpose** (a spanning tree has one route between any two rooms), scattered prop
points with a minimum separation, and a validator.

**The validator is why this is shippable.** It floods from the spawn, refuses a map where
anything placed cannot be reached, refuses one that is technically connected and nine
tenths wasted, fills in the sealed pockets, and the pipeline **retries on a different
seed** up to ten times. A generated sandbox nobody could cross is the failure this exists
to prevent, and it is invisible to every other kind of check — the counts are right, the
rooms are the size they should be, and a player walks in and cannot get out.

Three details that are not obvious:

- **Walls are one box per RUN of solid cells**, not one per cell. A 40 × 40 map is about
  900 solid cells; a box each is 900 static bodies and a physics broad phase sorting them
  every tick, in a game whose whole point is throwing rigid bodies around.
- **The map does not build itself in `_ready`.** A generated map needs a seed, and dot-map's
  loader instantiates a scene and adds it with no moment in between — so `Playground`
  calls `configure()` from its `map_changed` handler, **before** it spawns anybody. A
  static holding the pending seed was the alternative, and a second server in one process
  would read the first one's.
- **There is no timer course on it**, deliberately. A generated jump course is a course
  nobody can learn and a record nobody can beat. `pg_lobby` carries the timer.

`pg_seed` is the cvar, and it is not a debugging affordance: **"play the map I played" is
the single most-requested feature of every generated world**, and a seed nobody can name is
a world nobody can share. Zero takes it from dot-randomness, so the map, the scattered
props and the audio's own variation all come out of **one** number — three generators would
be three numbers and "what seed are you on" would stop meaning anything.

### The backpack, which is the thing between the menu and the shop

| | |
| --- | --- |
| `PlaygroundSpawnMenu` | what exists. A catalogue. |
| `PlaygroundShop` | what it costs. A price list and a purse. |
| `PlaygroundInventory` | **what you have paid for and not yet used.** |

Before this, the shop charged per *spawn* and nothing was ever held — so "buy three crates"
and "buy one crate three times" were the same thing. `take()` refusing when you are not
carrying one is the whole feature.

**The item catalogue is derived from the prop catalogue**, so there is one list: the
weight is the prop's own `mass` (which until now exactly one thing in this family read),
the grid size comes from its declared size band, and the tag comes from the same
`kind_of()` the spawner uses. A second table of what can be carried would go stale the
first time somebody added a prop.

Every mutation is an **op**, which is what makes client-side drag-and-drop safe: the client
applies locally, sends, and rolls back on a refusal. A server receiving *state* would have
to diff two documents, and a diff cannot tell "this crate moved" from "this crate was
destroyed and an identical one appeared".

**None of that was true of the running game until 2026-09-25.** `PlaygroundInventory` was built by nothing but `headless_presentation`: no `Playground` had an inventory, the shop charged per spawn exactly as the paragraph above says it no longer did, and "buying puts a thing in here; spawning takes it out" described a test. `Playground.inventory` is built on both ends now, authoritative exactly when the game is, and the bridge carries it. It is the first inventory in the family to cross a wire.

### The bag over the wire

`PlaygroundInventoryNet` (`game/net/`) is both halves, beside the bridge that routes `Ask.INVENTORY` and `Kind.INVENTORY` to it. Each shape below is the answer to the obvious alternative being wrong:

- **A client sends ops, never state, and only four kinds.** MOVE, SPLIT, MERGE and DROP. An ADD from a client is a client giving itself something, and a USE is what spawning does; both are refused with an ack, and the client rolls its prediction back. The op crosses field by field and **without `state`**, which is the one field a client must not write — an ADD's durability or serial stamped on a MOVE.
- **Every op has a sequence number, because two ops can be the same dictionary.** `DotInvManager.confirm` and `rollback` find an op by comparing `to_dictionary()`, and "drop one of #3" twice is two identical dictionaries. The number is also what makes an answer cumulative: acks come back in order on a reliable channel, so an ack for #6 while #5 waits means #5 never arrived — **dot-net drops a request past its per-peer message rate and tells nobody**, and without this a predicted op would sit in the client's bag for ever. An op lost at the tail has nothing after it to say so, and the client asks for the whole bag once the oldest answer is three seconds overdue.
- **A refusal rewinds everything in flight, newest first, and replays the survivors — here, not in the addon.** This began as a workaround: `DotInvManager.rollback(op)` used to undo every op predicted after `op` too. It no longer does (it undoes one op and re-applies the rest, below), and the rewind stays anyway, because an answer carries more than one refusal: an ack for #6 while #4 and #5 wait means those two never arrived, and the client must take them out and keep #6. Which to keep is a question about sequence numbers, which the manager never sees — it names an op by its dictionary, and "drop one of #3" twice is two identical dictionaries. Rewinding the whole flight newest-first undoes everything whichever identical op the manager's matching picks, and the survivors are re-applied here, where each one's number is known.
- **A change the server makes arrives as the whole bag, not as the op — by choice now, not by necessity.** dot-inventory's `apply_authoritative` can put a server's op on a predicting manager, underneath the predictions in flight, which removes both reasons this used to give (the op went straight back up as the client's own; first-fit placed it on the predicted layout). The document is still the better message: it **converges**, putting right whatever the client got wrong since the last one — a dropped op, a replay that diverged — where an op stream carries a divergence forward and nothing on the wire says so; it coalesces a tick's burst into one message; and the join and the resync need the document anyway, so ops would be a second path to the same state. It carries the newest sequence number it already includes, and the client replays whatever it has sent since on top — so a purchase landing mid-drag does not snap the drag back. Once per tick per bag, after the game ticked.
- **Only ever to the owner.** Nothing about a bag is a replicated field, so dot-net's interest management never sees it and cannot leak it; every message goes through `_tell`, which refuses peer 0 because peer 0 is the broadcast address. `PlaygroundInventoryNet` is handed a way to reach one peer and no way to reach everybody, so a later edit cannot broadcast a bag by picking the wrong helper. A bot has a bag and no peer, and is told nothing.
- **A bag belongs to a person, not to a connection.** dot-server's userid is sequential and a reconnect is a new one. `PlaygroundModule._bag_key_for` is the statistics key (`PlaygroundPlatform.key_for_session`) — the pseudonymous per-scope id with an identity stack — and the bag is kept across a disconnect under it. `local:<userid>` identifies nobody next time and is answered as empty, so on a LAN the bag goes with the session rather than one abandoned bag piling up per connection. The key a peer was admitted with is **remembered**, not recomputed on the way out, because by the time a disconnect is handled dot-server may no longer have the session.
- **Every HELLO resets the client's bag and sequence**, even one naming the same userid: ops in flight from the old connection replayed onto the new bag would land on somebody else's layout under a sequence the server has forgotten.
- **JSON for the whole bag.** `DotInvDoc` writes cells as two numbers because "a Vector2i does not survive JSON", so JSON is the format it claims and the one a saved bag will be in; the wire sends the same bytes, which puts that claim through a real round trip on every join. Too big to send is refused, not truncated: `DotNetWriter.write_string` truncates, and truncated JSON is a bag the client silently fails to adopt.
- **Buying into the bag is checked, then charged, then given — and the check includes room** (`PlaygroundInventory.may_give`, which is `DotInvManager.validate` now that that asks room). Spawning something carried is free and takes it out, and it is taken only after the spawner said yes, so a budget refusal leaves the bag as it was. Spawning something bought is charged only after it exists (above, in the shop).
- **The rate limit is the addon's, on the server, and the server's own changes are exempt.** Thirty ops a second per actor, and the actor is the session the request arrived on; `PlaygroundInventory.SERVER_ACTOR` is in every manager's `unlimited_actors`. A flood is refused by the manager and answered with an ack like any other refusal. Client managers are unlimited: a client limiting itself protects nothing, and after a whole-bag correction the client re-applies everything still in flight through `apply` in one frame.

**What building it found.** Five, and four were dot-inventory's — all four fixed there on 2026-09-25, each reproduced in its own suite first (see its CLAUDE.md, "What a real wire found"):

- **The server's own changes spent the player's rate budget.** `give` and `take` applied as the player's id, and `DotInvManager` rate-limits per actor at 30 a second: thirty beach balls into a sixty-cell bag and the thirty-first was "too many inventory operations" (measured). A separate actor only moved the cap onto the server's own changes, and `DotInvManager` had no way to exempt the authority — so for a while the managers here were built unlimited and the rule was re-implemented per peer on the wire. `DotInvManager.unlimited_actors` now exempts `SERVER_ACTOR`, the managers use their own limit again, and the wire limiter is gone (armed both ways: no exemption fails the thirty-five-ball check; no limit fails the flood).
- **`DotInvManager.validate` passed an ADD into a full bag**, and `_do_add` then logged **ERROR** "an inventory operation failed after it had been validated" for an ordinary full bag. A shop asking only `validate` charged first. `may_give` used to ask first-fit itself; `validate` asks room now and `may_give` is one line. `headless_net` asserts the addon's own `validate` refuses a crate into a full bag, which is the check that said the opposite before.
- **`DotInvManager.rollback` undid every later prediction too, and nothing applied a server op to a predicting manager.** Both fixed in the addon (`rollback` undoes one op and re-applies the rest; `apply_authoritative`). Neither workaround here was removed, for reasons that are now this file's rather than the addon's — the rewind needs sequence numbers the manager never sees, and the whole bag converges (both above).
- **A MOVE re-allocated the entry's uid**, even within one container (`_do_move` removed and re-added). Ops name entries by uid, so a client that chains a second op onto the uid its first *predicted* named whatever the server allocated that number to — the right item when nothing else happened, and the wrong one if a server-originated ADD landed in between. Measured with two managers: a ball dragged twice, a crate given by the server between the two drags, and the server moved the CRATE on the second op — validly, so nothing was refused and the next whole bag simply showed the player a crate where they had put the ball. A move keeps its uid now (within a container always; across containers unless the destination already uses it), and dot-inventory's suite runs exactly that exchange. `headless_net` still compares uids on both ends after every exchange.
- **Nothing built the inventory at all** (above).

One more, the bridge's own, found in the same review: **a spawn the prop budget refused had already been charged for** (see the shop, above).

`headless_net` has nine sections on it: the wire; a spawn the prop budget refuses, which costs nothing (and one nobody can afford, which places nothing); an op predicted and confirmed; two refusals rolled back — a client ADD with a good move behind it, and a move into a cell the server had just filled and not yet said so; ops lost in the middle and at the tail; a purchase, a refused purchase (a 900 kg boulder, and a full bag, which dot-inventory's own `validate` now refuses too) and a spawn from the bag; privacy, against a second peer, a bot on peer 0 and every event the server sent whether delivered or not; a flood past thirty a second; and a reconnect under a new userid getting the whole bag, including what an admin gave while they were away. Every one of the thirteen guards was armed (the refusal path as a plain `rollback`, a broadcast instead of `_tell`, non-cumulative acks, no poll, no room check, a limited manager, no HELLO reset, forgetting every bag, no spawn-from-bag, no flush, echoing a client's op back as a document, a truncated document, and the CHECKS total) and each fails at least one check. Re-armed on 2026-09-25 after dot-inventory's fixes, for the guards those changed: charging before the spawn (fails four), no `SERVER_ACTOR` exemption (fails four, the thirty-five-ball burst first), no limit on the server manager (fails the flood), and a limit on the client manager too (fails the flood and the HELLO reset). The room check now lives in dot-inventory and is armed there. `dedicated` runs `pg_give` and `pg_inv` at a real console and the `local:` filter (armed).

### The presentation layer

Settings, randomness, audio, effects and a console. Two decisions are this game's own:

- **`prop_sounds` is about somebody else's building.** A busy sandbox is a permanent noise
  otherwise, and your *own* prop still makes one because that is the answer to something
  you just did.
- **`refused` outranks a crate hitting the floor.** A refusal answers something the player
  did; a crate landing does not.

**Nothing in the game called any of it, and the client was silent.** Every hook — `on_prop_spawned`, `on_refused`, `on_tool_grab`, `on_tool_punt`, `on_map_changed` — was called by `headless_presentation` and by nothing else, `camera_shake()` was computed and never added to a camera, and `tools/audio_probe.sh` plays through the manager directly — so every check about sound passed while the playable client never made one. `PlaygroundClient._wire_presentation` is the producer now, and `headless_playground` drives it through the client's own spawn, the spawner's own refusal and a real map change rather than through the hooks. On a networked client only your own props make a noise, from `PlaygroundNetBridge.prop_arrived`, because a joining client is sent the whole world's props through the same PROP event and the wire cannot tell a backlog from a spawn. Still unwired: `on_prop_landed` (nothing reports a landing), `on_bought` and `on_wave_incoming` (the shop and the waves are server-side and no event carries either to the client), and every tool sound on a networked client (the server actuates the tools).

**Neither effect scene existed until 2026-09-27 (`[fx-scenes-1]`)**: `fx_catalogue()` named `scenes/fx/spawn_puff.tscn` and `tool_beam.tscn`, dot-fx refuses a missing scene at DEBUG, and every spawn puff was refused in silence. Both now exist with no script and no external resource (a CPUParticles3D puff; two additive cylinders one metre down -Z, tapering toward the gun), under `FX_DIR` through `PlaygroundPaths.rebase`, and `_build_fx` warns when `missing_scenes()` is not empty. **`tool_beam` was declared and never spawned**; `PlaygroundClient._present_tool_beam` now draws it once a frame, after `present`, from `BEAM_OFFSET` in front of and below the camera to the held prop, through `PlaygroundPresentation.on_tool_beam` — one node moved every frame and replaced in the same frame when its 100 ms ceiling retires it, not one spawned per frame. **Offline only**, like the grab and punt sounds: a connected client never sets `_holding`, and nothing replicates what anybody holds (`Kind.HELD`, below). `wave_flash` is still triggered by nothing (`on_wave_incoming`, above), and `DotFxManager.flash_colour` is drawn by nothing either: a flash would need an overlay in the HUD as well as an event. `headless_presentation`'s **the effects this game names are drawn** asserts `missing_scenes()` is empty, a puff where the prop appeared, and a beam starting in front of and below the eye, ending on the prop, moved rather than stacked, and replaced past its ceiling; `headless_playground` asserts the client's own frame draws it. Armed: the puff scene removed (3 fired), the reuse branch removed (1), the client's call removed (1). `tools/screenshot.sh pg_lobby --fx` renders `playground_fx` (first person) and `playground_fx_side`.

The randomness manager is built **before** the playground, because `Playground._ready`
loads its first map inside `add_child` and a generated map asks the registry for a seed
source at that moment. A manager registered afterwards is one the map did not use — and
nothing would error, because falling back to a fixed seed is a legitimate configuration and
therefore indistinguishable from the bug.

### A host leaving a sandbox takes the sandbox with them

`PlaygroundParty` makes the one decision no other game in the family makes: **migration is
off because the world IS the host's physics state.** Every prop somebody spawned, every
contraption they froze, lives in one process's rigid bodies — so electing a new host hands
everybody an empty room, silently, with every count still correct.

Four games, four reasons, two answers:

| | migrates | why |
| --- | --- | --- |
| game-hungario | yes | a continuous arena with no round to be in the middle of |
| game-arena | no | the host holds the match clock, the score and every hitbox |
| game-g2gfast | no | a time made of two machines' clocks is worse than no time |
| this one | no | the world does not move with the host |

The trust model is `HOST_AUTHORITATIVE` rather than sandboxed, which is the other
disagreement: a sandbox is a place where a friend hosting *should* be able to hand out
money and spawn a hundred crates, because that is the game. What must not leave is anything
persistent, and `reporting_allowed()` is the one place that is asked.

**And it meets over HTTP now, awaited end to end (`[p2p-await-games]`).** Every party check used the loopback signaller, which answers inside the call, so a caller that forgot `await` passed against it. `headless_presentation`'s **a party that meets over HTTP** stands up a four-route rendezvous on a local TCP port (`RendezvousStub`, answering four frames after each request), hosts with one `PlaygroundParty` and joins with another through `DotP2PSession` and `DotP2PSignallerHttp`, and asserts each answer is the one the stub sent and arrived only after it answered, that the joiner learns who is there and does not elect itself, and that a 403 leaves the party closed with a reason. Armed on the one link the compiler cannot see — `DotP2PSession` calls its signaller through the base type — by dropping that `await`: join returned in 0 frames and three checks fired. Dropping the `await` in `PlaygroundParty` itself is a parse error, so that link is guarded at compile time. The stub's first version lost every byte it read: a `PackedByteArray` read out of a Dictionary is a copy, so appending to it appended to nothing.

## Escape opens a menu now, and used to toggle the cursor

This client had a spawn menu, a server browser and no pause screen. Escape toggled the mouse capture and nothing else, so the only route to a setting was the console.

It now **releases the cursor on the first press and opens the menu on the second** — game-arena's two-step, and it exists for the browser rather than the desktop. Escape is how a browser itself exits pointer lock and it then refuses to re-enter for about a second, so a press that both released and opened would leave a menu up with no way to get the mouse back.

**And Escape never captures; a click does** (`[esc-1]`, 2026-09-24), which is game-g2gfast's contract (`G2GClient`'s KEY_ESCAPE: "one key that releases and one gesture that captures is the same contract on both"). The second press used to capture again when there was no pause menu — a toggle, which on the web silently does nothing every other press — and a released pointer had no way back but through the pause menu's Resume, because a click fired the gun instead. Now a click on the world with the pointer released and no screen up captures it and does nothing else, before the `player == null` guard so a click during loading is not lost; the HUD says "Click to play. Escape again for the menu." The two games still differ in one way on purpose: this one has a pause menu on the second Escape, which g2gfast has no screen for. `_set_captured` is the one write, and moves `mouse_capture_override` with it so `headless_playground`'s "the client boots" can see it: Escape releases and opens nothing, a second Escape with no pause menu leaves it released, a click takes it back (three checks; armed, the old toggle fails the second and a click that does not capture fails the third).

**The menu is dot-menu's `DotMenu` since 2026-10-09** (it was dot-ui's `DotPauseScreen` and `DotSettingsScreen`): pages of stock audio, video and interface rows declared into this game's own settings schema by `DotMenuStock.declare`, applied by `DotMenuApplier`, with `open_on_escape` and `manage_pointer` off so this client keeps the two-step and stays the one owner of the pointer. What is this game's own is the extra Servers action and what Leave means. `overlays_changed` puts the pointer back on the view when the menu closes. **Tab is the scoreboard now, held** (dot-menu's `DotMenuScoreboard`, fed by dot-server's roster while it is held), and the movement style moved from Tab to N.

**A missing settings manager greys the button out** rather than opening an empty screen. A button that does nothing is worse than one that is visibly unavailable.

**The check that matters is the round trip, not the drawing.** `DotSettingsManager.to_config()` hands out a snapshot, so a screen calling only the panel's apply would report success and change nothing — and every structural check passes either way. `headless_presentation` edits the volume, presses Apply, and reads the manager *and* the mixer.

### And the menus are rendered now

`tools/screenshot_menus.sh` renders the spawn menu, dot-menu's Escape menu (general, video and audio pages) and the Tab board. The spawn menu is the one worth the most: it is this project's own, it is the screen a player is in most often, and two of this game's interface bugs were in it — a `TabBar` that hid two of its three tabs behind scroll arrows, and an NPC silhouette that came out as a coloured bar. Both fixes hold; the picture shows three tabs, four category filters with counts and fourteen cards with icons.

It found nothing new here, which is the result worth having: every bug the first frames of this pass turned up was in dot-ui or in another game, and this game's own screens came out right.


## Third person, a body to see in it, and why the sandbox is where both belong

`DotTpsController` and `DotPlayerControllerSwitch` had been written, tested and installed
in three games and run in none of them; `DotPlayerCharVisual` — the abstract node
dot-player-char exists to fill — was subclassed nowhere in the family. Both land here, and
the argument for *here* is the same one twice:

| | third person | why |
| --- | --- | --- |
| game-g2gfast | camera only, one motor | a run set in third person must be comparable with one set in first |
| game-arena | none | analytic, lag-compensated: its server and clients agree because there is one motor to agree about |
| **this one** | **a second controller** | nothing here is ranked and nothing is rewound |

**F5 hands the player between two controllers**, and the handover carries position,
velocity and look angles while deliberately dropping the motor state — a first-person
air-strafe has no counterpart in a third-person motor and any mapping between them is a
lie. That is `DotPlayerControllerSwitch`'s whole reason to exist and this is the only
place it runs.

**A `PlaygroundPlayer` is a `CharacterBody3D` now**, because that is what
`DotTpsController` drives. It is classified onto the layout's `player` layer for the same
reason every other body here is: a body on layer 1 is a body every other sweep treats as
level geometry.

**`PlaygroundCharacter` draws a body from the character definition**, in primitives, which
is this project's own rule applied one level up — `PlaygroundIcons` already draws a menu
card from the three `meta` fields a prop's body is built from, so that a barrel is a green
cylinder in both places. A `DotPlayerCharDef` carries a height, a radius and an eye height,
and those three numbers are enough to build a body that is the right size. A server with
content points `DotPlayerModelDef.rig_scene` at real art and the same class adopts it
instead, which is what `DotPlayerModelRig.adopt` is for.

Two things that cost a frame each to find:

- **`DotPlayerCharVisual` is a `DotPlayerComponent`, which is a plain `Node`.** It has no
  `rotation` and no `visible`, because a component is a behaviour rather than a place. The
  body goes under the **rig**, which is the `Node3D` — and is also what `set_shown` hides
  and what the mounts hang off. Parenting it to the visual gives a character that cannot
  be turned or hidden, with a runtime error per tick.
- **`DotPlayerAnimDriver.auto_drive` is off.** It reads the body's transform once a frame
  and differentiates it, which is a second opinion about how fast the player is going, and
  this game already has an authoritative one on the controller. Two sources of "am I
  running" disagree exactly when a correction lands.

`tools/screenshot_views.sh` renders both views. It is not optional after touching either
controller: every check on the switch is a check on an *id*, and an id is equally happy
when the camera is inside the character's head.

## Somebody else's body, on a connected client

**Until 2026-09-24 a networked client drew nobody else.** Two bugs, either enough on its own, and invisible to every suite because each reads the simulation and none reads the screen:

- **Hidden as if it were your own.** `build_character` and `set_view_mode` showed a body only when `view_mode() == &"tp"`, and a view mode is a fact about the LOCAL player — only a player that samples input has a switch — so every remote player read "fp" and was built hidden. `PlaygroundPlayer.body_shown()` is `not samples_input or view_mode() == &"tp"`, applied by `refresh_body()` when the body is built, when the view switch is built (the moment a client learns a player is its own) and on F5.
- **Parked at the world origin.** `DotPlayerModelVisual` makes its rig its own child, and the visual is a `DotPlayerComponent` — a plain `Node`. A `Node3D` under a plain `Node` inherits no transform, so every body stood at (0, 0, 0) whatever its player did. It was never seen because the lobby's spawn IS the origin: the local third-person frame showed a body in the right place by coincidence. `PlaygroundCharacter._seat_rig` reparented the rig onto the `PlaygroundPlayer` until dot-player-char fixed it at the source (b04a9ac): a visual now seats its drawn node on the nearest `Node3D` ancestor itself, and the workaround is gone (6dbd015).

And a remote body kept whatever way it faced when built, because `drive_character` runs only where the game ticks every player. `PlaygroundClient.present_frame` — static, so `headless_net` drives exactly it — interpolates and then turns every body with `face_body()`, once a frame.

`headless_net`'s **somebody else has a body** section adds a second player on a peer of their own, does what the real client does (starts its manager, marks its own player local), and asserts a body for them and none round this client's own first-person camera, the rig on the player's node, then over 160 ticks at four frames a tick: every frame on the path the server ran them along, away from the origin, an even step per frame, and facing the server's yaw. Armed three ways: the old shown rule (two fired), no `_seat_rig` (four fired, the body drawn at `(0, 0, 0)`), and no interpolation in `present_frame` (the even-step check, 0.0000..0.2188 m against a 0.0137 mean).

`tools/screenshot_net.sh` renders a connected client — server and client in one process over the same loopback — watching another player run across its view: four consecutive frames and a probe of each frame's movement over its own delta. Measured under lavapipe at ~120 fps against 128 ticks: interpolated, 0 of 730 frames standing still and 6% more than 20% off the median; `--no-interp`, 623 of 733 standing still.

**Found by the probe, and fixed in dot-net since (2604b03): the interpolation delay was in the wrong unit.** `DotNetInterpolator._delay_ticks` is documented, adapted and reported in SNAPSHOTS (`interpolation_buffer`, `delay_ms() = _delay_ticks * snapshot_interval()`), and `sample()` subtracts it from a timeline in TICKS. At 128 ticks and 20 snapshots the render time is a sixth as far back as intended, past the newest snapshot, so every remote entity in the family is extrapolated rather than interpolated: `stalls` and `extrapolations` both read 1,684 over a six-second run. Scaling by `tick_rate / snapshot_rate` in `sample()` takes both to 0; the frame-evenness figure does not move (a straight run extrapolates perfectly), so the cost is at every change of direction rather than on a straight. dot-net converts it now, and every game's net suite passes after.

**A rider sits (6dbd015).** `PlaygroundCharacter.set_seated` drops the body by its leg height and swings the legs forward, turned to the vehicle's basis. `tools/screenshot_views.sh` renders `body_standing` and `rider_seated` side by side from the same spot.

## A connected client predicted nobody, its own player included

**Until 2026-09-25 `PlaygroundNetBridge._apply_join` built every mirrored player with owner 0** — the local one too. dot-net's `is_owner` is owner == local peer, so on a connected client the local player was not owned, `registry.predicted()` was empty, `client_tick` simulated nobody, and the player moved only when a snapshot came back. mg-buses-from-hell found the same line the same day; this is its fix, measured here first rather than assumed.

**Measured before**, in `headless_net` and in `tools/screenshot_net.sh --walk` (a rendered client strafing its own player over the loopback): owner 0, `predicted()` empty, a key moving the client's player 0.0000 m on the tick it was pressed, 3 ticks from key to motion in the suite and 3..5 (median 5) in the render — on a 1 ms loopback, so a real link adds its whole round trip — and 0 predictor corrections, because the predictor never ran. The local player was being **interpolated like a remote one** (the interpolator had two tracks, not one), which is why nobody saw it: the eye was smooth, just late.

**Why no check saw it.** "The client moves under its own prediction" and "the server agrees with it" both hold for a client that simply adopts every snapshot, and "the correction rate is low" is lowest of all — zero — for a predictor that never runs. Every one of the three passed for the wrong reason.

**The fix, and why this shape rather than game-g2gfast's and game-arena's.** Those two send the owner's peer id in JOIN. Here `_mirror_owner(session_id)` owns the mirror with `net.local_peer_id` when the session id is the one HELLO named, and 0 for everybody else, and `_claim_local_player()` on HELLO takes the mirror over through `registry.change_owner` if JOIN got there first. No wire change, so an old server and a new client (or the reverse) still talk, and the owner on the client is whatever `local_peer_id` is — `is_owner` compares the two, so they cannot disagree, where a peer id sent on the wire is right only if the client's own copy is exactly the server's number (dot-net's #16 is that bug). A client learns nothing about other people's peer ids either. Vehicles are untouched: they are not player mirrors, and a rigid body is not predicted (the family's decision).

**The claim is not belt and braces here, and that was measured too.** `add_player` broadcast JOIN to every connected peer, the joiner included, before that peer had asked to be admitted, so in this suite's handshake JOIN arrived FIRST and the claim on HELLO was the path that made the player predicted. (Since `[pg-rpc-before-scene]`, below, a broadcast reaches READY peers only and `_admit` sends HELLO before the JOINs, so the HELLO-first path is the live one; the claim still covers a JOIN that beats HELLO.) Arming the JOIN-side owner alone (owner 0 in `_apply_join`, the claim kept) fails only the HELLO-first rebuild check; arming the claim alone fails nine.

**And the camera needed a blend it had never had.** Predicted, the eye is the simulation's and moves once a tick, so on a 144 Hz screen against 128 ticks some frames advance it and some do not: 62 of 593 full-speed frames standing still, 19% more than 20% off the median. `PlaygroundPlayer.render_eye_position()` is `DotFpsController.render_state()` through the motor — the last two ticks blended by the engine's physics fraction, which the bridge makes a fraction through a tick by putting the engine on the server's rate — and `PlaygroundClient` draws its camera from it. Aim and traces still use `eye_position()`. Not while riding: the controller is not simulated in a vehicle and a blend toward a tick nothing simulated is the backward lurch mg-buses-from-hell measured at 137.9 m/s.

**Measured after**, same render: 1 of 2 players predicted, 0 ticks from key to motion on every press, 2 corrections in 9.7 s (0.9%, worst error 0.018 m), and the eye at a median 7.00 m/s — the server's speed — with 0 frames standing still and 7% more than 20% off (before: 7.00 m/s, 0 still, 9% off, and five ticks late). The remote-player probe in the same run is unchanged (0 still, 4% off).

`headless_net`'s **this client predicts its own player, and nobody else** is the section that sees it: the local mirror owned by the local peer and the one entity in `predicted()`; a second player, on a peer with no client here, mirrored as the server's and not predicted; a key moving the player — state and node — on the tick it is pressed with no server tick and no snapshot in between, while the server has not moved; key to motion over the link at zero ticks; a teleport only the server made (3 m) corrected by the predictor and converged to within 5 cm, in the state and on the node; and both arrival orders — a mirror handed back to the server and claimed again by HELLO, and a mirror forgotten and rebuilt owned by a JOIN after HELLO. Armed four ways: the old code (ten fail), the claim alone removed (nine), the owned JOIN alone removed (one, the HELLO-first rebuild), and predicting everybody (four: the second player, the count, and the remote body's even step and facing in "somebody else has a body", which a client simulating somebody it has no keys for spoils). Every other section still passes with the local player predicted — the vehicle ride included, whose `riding` branches in `PlaygroundPlayerNet` were written for a predicted entity and had never had one.

**For the deployed game:** nothing on the wire and no `@rpc` set changed, and no `class_name` was added, so the client shell does not need a rebuild; the playground pack needs republishing from dot-server-deploy for clients to get it. A shell whose dot-player-controller predates `render_state` supporting `Drive.EXTERNAL` gets the raw tick state back from it — the stepping above, not a lurch.

## A connected client was alone in a copy of the map (2026-10-03)

**Until 2026-10-03 nobody on a delivered playground server could see anybody else, because every client was playing offline.** `PlaygroundClient` became networked by having its `link` export set, and the shell sets it only on a BUILT-IN client scene (`client/shell.gd`). Since the game became a pack (2026-09-23) its scene has been instantiated by `DotClientLink._on_load_game`, which sets nothing on it, so every client connected, downloaded, mounted, and then booted `authoritative=true` with a local player of its own. The server had both players and nobody had the server. Every other game reads `DotRegistry.get_node_service(&"dot_client_link")`; this one now does too when the export is unset (the export still wins, so two shells in one process keep their own links, and `--offline` skips the lookup). It went unnoticed because every suite here builds the bridge by hand or sets `link` itself, and `tools/screenshot_net.sh` is a one-process rig with no shell in it. **It was found by running the real thing**: `./server --game playground --content-url <local dist>` and two `client/shell.tscn -- --connect` processes under one Xvfb display, read with `playground starting authoritative=…` in each client's log. Without `--content-url` a local client fetches the PRODUCTION pack from the content origin, whatever `dist/` says, which is how the first fixed run still showed the bug.

**And with that fixed, both stood inside each other.** Every start here is one point, and `Playground.spawn_player` put every player on it: two people joining the lobby both stood at (0, 1, 0) facing the same way, so each first-person camera was inside the other's head and the screen was a wall of the other player's colour. dot-spawn's occupancy only chooses between sites. `_clear_of_players` steps a spawn to the nearest free point on two rings of eight at `SPAWN_SPACING` (1.5 m), which stays on the smallest start pad; past seventeen people the centre is shared rather than anybody being thrown off a course. Rendered after both fixes: the second player 1.5 m beside the first, and drawn in front of them once the first stepped back.

## zee-dot-weapons, beside the toys (2026-10-03)

Twenty-seven real weapons in the Q menu's Weapons tab, after the launcher, remover and impulse gun, under five categories taken from the pack's slots (melee, sidearms, primaries, heavy, thrown). `PlaygroundZee.defs()` maps the pack's catalogue to `PlaygroundWeaponDef`s with `meta.zee` and no script, ids prefixed `zee_` because both lists have a `launcher`, so the menu, the shop (350 credits, like every weapon) and the arena's loadout see one list. `addons/dot_weapon` and `addons/zee_weapons` are linked and in `.gitignore`; the CC0 art is vendored in `assets/{blaster-kit,melee,arms}` as mg-smash-copter does.

**A zee weapon is not a SWEP and is not wrapped as one.** A toy is a prop tool the holder runs. A zee gun is dot-weapon's: held buttons per tick, its own cadence, reload and ammunition, and shots the game resolves. So `_give_weapon` puts a SERVER rig with the authority on the server's copy of the player, and `_drive_tools` ticks it from the same USER_0/1/2 bits the tools ride (fire, bash, reload), and returns before the physics gun sees them. The client builds a `ZeeViewModel` under its first-person camera and a LOCAL rig: no authority when connected (the gun that moves), the authority offline (the client is the server). R reloads while a zee gun is in hand and unfreezes everything otherwise. The hands are hidden in third person.

**A shot hurts only while `pg_arena` is on.** Off, it shoves the prop it hits (`PlaygroundZee.shove_props`, through the gravity gun's own ray and `may_act_on`, so a shot moves exactly what a punt could). On, the module's `_resolve_shot` hands it to the arena's dot-combat through `PlaygroundNetBridge.shot_fn`, asked per shot because `pg_arena` flips at runtime.

**`PlaygroundPlayer.component()` is load-bearing.** dot-weapon's player bridge takes a shot's origin and aim from a controller found through it, and without it every shot leaves the feet pointing north, fires, costs ammunition and hits nothing: mg-smash-copter's twenty drawn rounds. `headless_playground`'s **zee-dot-weapons** asserts the shot leaves from the eye along the aim and shoves a crate; armed by renaming `component()`, three fail (1.63 m off, dot 0.000, the crate unmoved).

**The art in a pack.** `ZeeWeaponArtTable` and `ZeeViewArms` name `res://assets/…`, and inside a mount that is the one place the art is not. zee-dot-weapons' `ZeeModelCache.set_asset_root()` (added for this) resolves those paths under a root; the client sets it to `PlaygroundPaths.root()` on `_ready` and back to `res://` on `_exit_tree`, because a static outlives the game in a shell that switches. Rendered in a real shell over a socket with the delivered pack: an SMG and the arms. **The client shell needs a rebuild with that zee-dot-weapons before this pack is published**, or the call names a method the shell's copy of the class does not have and the client script fails to compile.

The suites: `headless_playground`'s section (twelve checks) and four in "the client boots" (hands under the camera, the authority offline, held fire firing through the client's own tick, the physics gun taking it back); `headless_net`'s **a zee weapon is run by the server** (a deciding rig on the asker, fired from the client's held buttons, every shot handed to `shot_fn`, taken away by the physics gun), armed by skipping the `_drive_tools` branch: 0 uses in 256 ticks.

**Somebody else's gun (2026-10-03, nightly).** `PlaygroundPlayerNet` replicates `ZeeWeaponNet.all_specs()` (magazine and reserve owner-only, as smash's are), pulled from the rig on whichever end runs it, and `_apply_weapon` hands the counter to `ZeeWeaponNet.apply` with the player's `zee_world`. That is a `ZeeWorldModel` `PlaygroundZee.show_held` hangs on the character's `right_hand` mount, built on a client from the server's WEAPON event (the bridge's reader, before `weapon_changed`) and offline from `_arm_zee`/`_disarm_zee`; a joiner is sent everybody's current tool from `_tool_of` in `_admit`, because a WEAPON event is sent once. **The mount used to name the torso**, which hung every gun at the capsule's centre: `tools/screenshot_net.sh --zee=rifle` showed two pixels of barrel, and `PlaygroundCharacter` now builds a `RightHand` in front of the torso's right side (muzzle along the character's facing, measured). `headless_net`'s zee section asserts the SMG drawn on the client's mirror, outside the body, the counter crossing and acted on, a READY replaying it, and the physics gun taking it off the body; `headless_playground` asserts the offline body holds it. Each armed (no `show_held` in the bridge, no specs, no `_admit` loop, the torso mount, no offline call: one check fails each). **A shot is seen and heard since 2026-10-05**: zee-dot-weapons' `ZeeShotFx` draws a tracer, a flash and an impact and plays a report, from the client's own LOCAL rig (offline and connected; it predicts every tick in `_net_physics`) and from a remote player's `zee_world` when the counter moves. The local player's own `zee_world` is driven by the same counter and stays quiet by itself, because its carrier has a first-person rig with effects. The camera takes the recoil's punch through `DotFpsView.external_angles` in `_present_zee`, and is put back to zero when no zee gun is in hand. **Still not here:** the toys never run on a server: `_drive_tools` knows only the two guns, so a connected player's launcher, remover and impulse gun send buttons the physics gun answers. That one is older than this.

## A broadcast reaches READY peers only (`[pg-rpc-before-scene]`, 2026-09-30)

Every real client join logged `Failed to get path from RPC: Server/Playground` and `Invalid packet received. Requested node was not found.` once. [DotClientLink] reports LOADED the moment it has added the game scene, which is dot-server's `client_spawn`, which is `bridge.add_player`, which broadcast JOIN — and `PlaygroundNetBridge._broadcast` was `net.send(msg, 0)`, which the link turns into `rpc()` to **every socket**. `PlaygroundClient` builds `Server/Playground` only after its first map is up, so the joiner received its own JOIN before the node existed. `_broadcast` now sends peer by peer to `_ready_peers` (the set READY puts a peer in); the joiner learns everybody, itself included, from `_admit`. `remove_player` drops the peer from that set before its LEAVE, so a player removed while its socket is still up is told directly, through `PlaygroundNetLink.can_reach`, which refuses a peer the socket no longer has. `headless_net`'s **a spawned peer that has not said READY is sent nothing on the link** is the check (nothing to peer 0, nothing to the joiner before READY, HELLO and JOIN after, LEAVE peer by peer); armed against the old `_broadcast`, three of its four fail. No wire or `@rpc` change.

**Reviewed 2026-10-01, and the ready set had two more seams, both older than the fix.** (1) The module's `_welcome` (the chat backlog, the join line, the match clock) ran from `client_spawn` and returned unless the peer was READY, which at spawn it never is on a real join, so no connected player had ever been sent any of it. The bridge now emits `peer_admitted` the first time `_admit` runs for a peer, and the module welcomes from that (`_on_peer_admitted`). (2) A real disconnect goes through the module, which calls `mark_not_ready` before `bridge.remove_player`, and `remove_player` asked the ready set whether to call `net.remove_peer`: every peer that ever disconnected stayed in `net.peers()`, with a snapshot built for it every tick and its buffers kept. It asks `net.peers()` now. `dedicated`'s **a joiner is welcomed when it says READY, and not before** drives the real order (a session, `client_spawn`, READY through the bridge, a disconnect) and records what goes to that peer: nothing before READY, HELLO and five chat lines after it, nothing more for a second READY, and the peer out of `net.peers()` after leaving. Armed three ways: without the connection (0 chat), without the once-only guard (six more on the second READY), and with the old `was_ready` test (the peer stays). A map change while a peer is not ready needs nothing: it is not broadcast to, and HELLO names the current map. A reconnect is a new peer under a new userid (dot-server never reuses one), so it is a fresh join through the same gate.

**Reviewed again 2026-10-02 (run 10), and voice was the send that went round the gate.** Every EVENT goes through `_broadcast` or `_tell`, snapshots go to `net.peers()` (which `_admit` fills), chat is addressed against `ready_peers()`, and every directed `_tell` answers a request or a run, which a peer can only have once it is in; but the module adds a peer to the voice router at `client_spawn`, and `PlaygroundServices._send_voice` handed every frame the router addressed straight to `link.send_voice` — an `rpc_id` to `Server/Playground` on a client that may not have built it. Anybody talking while somebody joined was one "Failed to get path" per frame. `_send_voice` now holds a frame for a peer that is not READY (`voice_held` counts them); the router still lists the peer, so it hears the first frame after READY. `headless_net`'s ready section relays a frame before and after READY over the loopback: armed with the gate removed, two of its three new checks fail. A map change needs nothing: `Server/Playground` is the link node, and it outlives the map.

## The chat box, and the channels it offers

`PlaygroundPresentation` gives each of its seven audio ids a `DotAudioSynth` voice in `sound_recipes()`, because the catalogue named seven `.ogg` files nobody has produced and the sandbox was therefore silent while every check about its audio passed. `DotAudioSinkGodot` consults that bank only when a def's path resolves to nothing, so dropping the real files in switches the stand-ins off one id at a time. A sandbox makes noise for a different reason than a shooter does: almost nothing here is information a player has to act on, it is confirmation that the thing they just did happened — which is why `refused` gets a voice of its own rather than silence, since a buy that does nothing and a buy that was refused are otherwise indistinguishable. `wave_incoming` is the one ominous sound in the table, because it is the one thing in this game that arrives whether the player asked for it or not. `tools/audio_probe.sh` is what says a speaker actually moved; no assertion in `headless_presentation` can, because a headless run has no audio device.

`PlaygroundPresentation` builds dot-ui's `DotChatWindow` beside the console. The corner is free here: this HUD keeps its timer block at the top left and its notice below it.

**The channels come from `PlaygroundServices.chat_channels()`, not from a list in the presentation layer.** Two copies of one list is this tree's most repeated bug; the server routes with those definitions, so the composer offers exactly what it routes. The admin channel is filtered out because it is admin-only, and a channel a player cannot send on should not be in the cycle. The second key opens the **proximity** channel rather than a team one — a sandbox has no teams, and what it has is the difference between telling the server and telling whoever is standing beside your build.

| | |
| --- | --- |
| `chat_window` | `auto` / `on` / `off`. `auto` hides the box on a server already carrying chat somewhere the player can see it; `on` draws it regardless; `off` never does. |
| `chat_open_key` | `Y` by default. |
| `chat_near_key` | `U` by default. |

**dot-server's `chat_received` is connected here and its LINES are ignored**, which reads like the bug this game's own comment warns about and is the opposite of it. This game routes every line through its own wire on purpose, and connecting both would draw one line twice — so the handler takes the one payload that is *not* a line, the `{kind: "state"}` notice saying what is carrying chat, and drops everything else. There is nowhere else for that notice to arrive.

`swallows_input()` covers the box as well as the console, and `DotFpsSampler.suspended` is set beside it: movement is polled, so without it typing "sw" walks the player backwards through whatever they were building, firing whatever tool they are holding.

## The server browser had no server half

This game has shipped `PlaygroundBrowser` — a real dot-browser list with sources, filters, favourites and a join — against a server that answered nothing at all. `examples/dedicated.gd` set `config.query_enabled = false`, no `DotQueryHost` was ever attached, and `PlaygroundModule` contributed no query provider, so the only half being exercised was the half that already worked. dot-browser's own suite queries a server dot-browser built, which is why neither end had noticed.

`PlaygroundQueryProvider` is the game's half. **The interesting part of a sandbox's listing row is not the map** — it is which of `pg_arena`, `pg_waves` and `pg_shop` are on, because each of those turns this into a different server and all three default to off *precisely* because that is an operator's decision. A person reading a list of playground servers is choosing between servers that share a name and not a game, which is exactly what a query section is for. The map, the occupancy, the prop count and the tick rate go in beside them.

The prop count is the spawner's own `world_count()` and the player count is the module's own `_joined`, asserted as such: a listing row built from a second tally is a second number that can disagree, and the one that is wrong is always the one nobody is looking at.

## No message preloads itself

`playground_event.gd` and `playground_request.gd` each began by preloading themselves, for a typed `of()` factory. mg-buses-from-hell measured that line (8ed866c) as enough to leak the whole script graph at exit on Godot 4.7.2: a script that `extends DotNetMessage` and preloads ITSELF, first loaded by a module inside a running `DotServer` — which is how every deployed server loads a game. Both are built with `new(kind, body)` now, an `_init` whose arguments default because dot-net's registry decodes with a bare `new()`.

`dedicated`'s last section, **exiting clean**, reads every `DotNetMessage` script under `game/` as text and fails on a self-preload. It is on the source deliberately: the leak is printed by the engine after `quit()`, where no assertion can reach.

**Here it was not the cause, and the leak is still open.** `dedicated` exits with 351 ObjectDB instances, 268 resources and a VariantPools page, exactly as many before the change as after (2026-09-23) — the whole-script-graph shape, held up by something else.

**Closed 2026-09-24.** The something else was scripts naming their own `class_name` inside themselves (docs/gdscript-hazards.md, "A script that names itself") across twenty-odd addons, plus RefCounted cycles in dot-npc, dot-npc-ai and dot-objective. `dedicated` now runs itself once more in a fresh process and asserts it leaves no object alive at exit, which it does.

Before it was closed it stood at 358 and 274, growing by one script's worth whenever a script was added, which is what said to find what held the graph rather than to stop preloading.

## Picking players up (2026-10-06)

The physics gun picks up a PLAYER in its beam before a prop (`PlaygroundPickup`, `Playground.phys_gun_grab` / `phys_gun_release`). A held player is a rider with no vehicle: their own movement, their client's prediction and their timer stop, exactly as in a seat, and on the wire it is a SEAT with vehicle 0, which an older client already understands. They are moved by sweeping the body, so a wall stops them as it stops a held crate, and letting go keeps the beam's velocity: a throw. Immunity is by role (`pg_pickup_immune`, roles from `PlaygroundLimits`), an override role beats it (`pg_pickup_override`, `root` by default), and `pg_pickup 0` turns it off. A refusal is an answer, so the prop behind an immune player is not grabbed instead. A seat, a respawn, a map change or a holder leaving all let go. `headless_playground`'s *picking players up* (21 checks). Started by the 2026-10-06 nightly run, which ended before committing it; finished the same morning (the new file named `PlaygroundPlayer` without preloading it, so nothing parsed).

## Creative mode (2026-10-06)

`!creative` toggles it for the caller, `pg_creative` (on) allows it and turning it off ends it for everybody. A builder in creative mode is out of everybody's way and out of the fight, both ways: their props are protected in **dot-props** (`DotPropSpawner.set_protected`, which every tool's `may_act_on` and dot-props' damage ask, so no tool can forget it; the tool gun's own `may_touch` asks too), nobody can pick them up and they cannot pick anybody up (`PlaygroundPickup.may_pick_up`), and the arena refuses damage to them and from them (`PlaygroundArena._adjust_damage`; a player nobody can hurt who could still hurt everybody would be the way to win the arena, not a way to build). A fall or a pit still reaches them, or a player could stand in a kill zone for ever. Switching it on also lets go of their props anybody else is holding. `PlaygroundPlayer.creative` is replicated to everybody (`net_creative`) and the HUD says CREATIVE. Checks: `dedicated`'s *creative mode* (10: the command, the protection, another player's tool, the replicated field, arena damage refused both ways and landing again once off, the cvar ending and refusing it), `headless_playground`'s picking-up section (3), `headless_net`'s who-is-told section (2); `tools/screenshot_views.sh` renders `hud_creative`. Writing the pickup checks found that "with picking up off, nobody is held" had been aiming the beam the wrong way (yaw 180 from -36 toward -40) and passed with nobody in it.

## Prop surfing, and players who walked through every prop (2026-10-06)

Standing on a moving prop carries a player with it (`pg` config `prop_surfing`, on): dot-props' `DotPropCarry` beside the spawner (`Playground.carry`), asked once a tick by `PlaygroundPlayer._ride_prop` after the move, with the lift written into the state as well as the node (mg-buses-from-hell's shape: `ground_id` is a local physics handle, so riding is resolved on each machine from its own bodies). A crate somebody swings with the physics gun, a plank sliding down a ramp, and the one you hold under your own feet all carry you. `headless_playground`'s *riding a moving prop* (5 checks: carried 3 m with a deck that moved 3 m, staying on it, and with surfing off the deck slides out from under them).

**Building it found that no player here had ever collided with a prop.** `use_collision_mask` set the tunables' mask after the controller's setup, and dot-player-controller's body had copied the mask (1) when it was built, so every sweep saw the world layer only: players walked through every crate, NPC and vehicle, and a rider stood on a platform fell straight through it. Fixed in dot-player-controller (dc06578: the controller hands the tunables' mask to its body every tick), which changes the same thing in five other games. **Over the wire.** Measuring it found two more things, both fixed. (1) **Every connected client's player had mask 1**: `use_collision_mask` wrote the live tunables, a client sets the player's style straight after the join, and a style rebuilds the tunables from the controller's base copy; so on a client nobody stood on any prop, and a client standing on a still deck fell a centimetre between snapshots and was corrected every one (32 in 128 ticks). `use_collision_mask` goes through dot-player-controller's new `set_collision_mask` now. (2) **A mirror has no velocity**: it is frozen and moved by writing its position, and the client's spawner does not know it, so `DotPropCarry` found nothing to carry the rider. `PlaygroundPropNet` records each mirror's velocity from its drawn motion as `mirror_velocity` meta, and `_ride_prop` uses it when the ground is a mirror. `headless_net`'s *riding a moving prop, connected*: 0 corrections on a still deck, 8 in 128 ticks on one moving at 3 m/s (the start, while the mirror's interpolated motion catches up from rest; it was 32), never more than 6 cm from the server. On a client the switch is its own config's `prop_surfing`, which `pg_prop_surf` does not reach.

`headless_playground` takes `-- --only=<method>` to run the boot and one section, for working on it; the totals are not checked when it is used.

## Breaking props (2026-10-06)

`pg_destruction` (off, `PlaygroundConfig.destruction`) lets shots and blasts break props that have health: `PlaygroundSpawnables.BREAKABLE` gives the plank, beam, panel, crates, barrel, can and die a `max_health` (always declared, so the switch is all it takes), and the slab, pillar and platform none, because a floor shot out from under a build is not the fun kind. dot-props' `DotPropDamage` (`Playground.prop_damage`) keeps the health; `Playground.hurt_prop` is the one door, called by a player's zee shot (`player_shots_fired`), an armed NPC's (`npc_shots_fired`, before the shove) and a grenade's blast (`PlaygroundProjectiles._blast`). A broken prop leaves `debris_pieces` (4) hidden, ownerless `debris` props in its colour, cleaned up after `debris_seconds` (6) by `_expire_debris`, spawned through the spawner so every client draws them. A barrel shot open explodes (5 m): players through the arena (so only with it on), armed NPCs through their health, other breakables through `hurt_prop`. **A blast reaches the barrel that made it**, still in the spawner while it explodes, and the first version recursed until the stack ran out; `_breaking` skips whatever is mid-break until the outermost blast is done, so a chain of barrels still goes up, once each. A creative builder's props do not break (dot-props refuses a protected owner's). `headless_playground`'s *breaking props* (9: off breaks nothing, a real pistol through `player_shots_fired` shoots a crate apart, debris owned by nobody and gone in six seconds, a barrel taking the crate a metre away and not the one ten off, a creative builder's crate, a slab). `pg_prop_surf` is the cvar for the surfing above.

## Buttons, levers and doors (2026-10-06)

The **Machines** category (`PlaygroundSpawnables._machines`): a button (says `pressed`), a lever (says `switched`, with its new state) and a door (hears `toggle`, `open`, `close`; says `opened` and `closed`). The wiring is dot-props' `DotPropIO` (`Playground.io`), added for this and for any other game that wants it; the tool gun's **Wire** mode (`tools/tool_wire.gd`) wires what you click first to what you click second, into the input its setting names (`toggle` by default), and right click takes a prop's wires off. **F presses what you look at**, within `USE_REACH` (2.6 m), before it gets you into a vehicle (`Playground.use_vehicle` asks `use_prop` first): F was already the "use" request on the wire, so a button over the network needed no new message. A button flips a door, a lever sets it (on is open), and F on a door swings it directly. **A door is a frozen body the server swings** a quarter turn about the hinge on its left edge in `DOOR_SECONDS` (0.6), by writing its transform each tick (`_swing_doors`); frozen so physics never moves it, so it reaches clients through the prop path like any other transform, and it swings from wherever it stood shut. Levers show their state as a tint (green on, red off), which replicates as the tool gun's paint does.

`headless_playground`'s *buttons, levers and doors* (11) and `headless_net`'s *a button pressed over the wire opens a door* (3: the server's door turns 90°, the client's mirror within 2° of it and in the same place). `tools/screenshot_menus.sh` shows the Machines category and the Wire tool. **Writing it found** that a section run by itself (`--only`) is on whatever map the boot left: the prop sections assumed the lobby the section before them loaded, and a button placed at a falling player's eye height was pressed once by luck; each now loads `pg_lobby` and lands its player first.

## Saved builds (2026-10-06)

`pg_save <name>`, `pg_load <name>`, `pg_builds` and `pg_build_delete <name>` (chat or console, as a player). `PlaygroundBuilds` captures everything the player owns relative to where they stand and the way they face, and puts a build down around whoever loads it, the way they face. **A document of catalogue ids**, because what it must survive is the catalogue changing: each prop's id, position and turn, frozen, the tool gun's size and paint, its gravity, weight, friction and bounce when changed; the welds, ropes and no-collides between them (a weld to the world as a point in the build's frame); and the wires between them. A build that names a prop the server lacks is refused, naming every missing id. **Whole or not at all**: the player's per-kind limits are asked first, so a build that will not fit puts nothing down, and a spawn the spawner refuses mid-way takes back what this load placed. At most 200 props. Kept as JSON in `user://builds/<statistics key>/<name>.json` (a name is letters, digits, `-`, `_`, up to 32; a key is made safe for a folder). `headless_playground`'s *saved builds* (15: capture, save, a path refused as a name, loaded back where they stood to the centimetre, painted/resized/frozen, edited physics kept and untouched props writing none, the weld and the wire, loaded elsewhere and turned, a missing prop refused by name, a limit putting nothing down, the summaries the menu is sent, custom-prop detection, the list's wire round trip; armed by not re-making welds), `dedicated`'s *saved builds* (7, through a real console as a player, plus the module answering the menu's ask).

**The Q menu's Builds tab (2026-10-07).** Opening it asks the server (`ARM_PROP` sub-kind `ARM_BUILDS`; the Ask enum is full) and the server answers with `Kind.BUILDS` to that peer only: each build's name, size and whether it is a **custom prop** — `PlaygroundBuilds.is_custom_prop`, two or more props all welded into one piece (union-find over the welds) and nothing welded to the world. Asked every time the tab opens, so a build saved with `pg_save` a minute ago is there. A click sends `ARM_LOAD_BUILD` with the name and the module does exactly what `pg_load` does, answering with a HUD notice. Custom props are a category of their own on the tab ("Custom props"), loaded like any build. Builds are the server's, so offline the tab says to join one. `headless_playground`'s spawn-menu section (4 more: the tab asks, shows each build, a click asks by name, the custom-prop category), `headless_net`'s *saved builds over the wire* (3), `tools/screenshot_menus.sh` renders `menu_builds.png`. Cards have no icon yet: a build has no single shape to draw.

## Editing a selected prop (2026-10-07)

The tool gun's **Edit properties** mode (`game/toolgun/tool_edit.gd`, last in `SwepToolgun.MODES`): left click selects a prop, and from then on the mode's settings ARE that prop — size, colour, frozen, gravity, weight, friction, bounce. Right click lets go; reload puts size, paint, gravity, weight, friction and bounce back to the catalogue's and leaves a frozen prop frozen. **Every other mode's settings say what the next click will do; this one's say what the selected prop is**, so it overrides `apply_settings` and writes each change as it arrives, and only what differs (a resize rebuilds the shape). **The selection is read off the prop and sent back to the client** (`selection_report`), because the Q menu sends the whole settings dictionary on every change, and a menu still holding the last prop's numbers would write all of them over the new prop the first time any slider moved; armed by not reading on select, four checks fail, that one among them. Ownership is asked again on every change (creative mode, or `touch_others_props` going off, drops the selection); freezing asks `can_freeze` and the spawner's frozen limit as the physics gun does, unfreezing asks neither, and a refusal springs the setting back with the reason. Switching to another mode lets go (`cancel`), so settings sent while switching back never land on a prop picked minutes ago. Picking the catalogue's own colour takes the paint off rather than painting it on.

**Over the wire** the answer is `Kind.SELECTION` (last; an older client refuses it as unknown) to the asker only: the prop's net id (0 for none), its name, the settings as JSON, and a refusal. The bridge sends it after a click (`_toy_result`) and after every settings change (`_set_tool_mode`), so a clamped or refused value comes back. The client puts it into the menu with `PlaygroundSpawnMenu.set_tool_settings`, which redraws the panel only when a value differs — the server answers every slider step, and a redraw mid-drag would take the slider out from under the mouse — and `set_edit_target` puts "Selected: <name>" (or "Nothing selected") above the sliders. The selected prop gets an outline (`PlaygroundClient.selection_box`, static so the render tool draws the same): **back faces of a box 8% larger, not a translucent fill**, because the fill's first render showed a crate painted red as pink, in the one mode whose sliders include the colour. Offline the same report comes straight from the gun. The mode's HUD help is said once per mode switch now rather than on every setting, so dragging a slider does not repeat it.

Checks: `headless_playground`'s *editing a selected prop with the tool gun* (29), five in *the client boots* (the outline, the menu adopting the prop's values, a menu slider resizing it, the box growing with it, right click clearing both); `headless_net`'s *editing a selected prop over the wire* (6: the net id told to the asker, the mirror it names, the values, a menu change resizing the server's crate, the answer, the mirror rebuilt). Rendered: `tools/screenshot_menus.sh` → `menu_tool_edit.png`, `tools/screenshot_views.sh` → `edit_selection.png`. Saved builds keep an edited prop's physics too since the same day: an optional `physics` entry per prop (gravity, weight, friction, bounce), written only when it differs from the catalogue's and applied after the size, because the weight multiplies the mass the size gives.

## People are drawn as people, and a member as they dressed (2026-10-10)

**Until 2026-10-10 nobody in the sandbox had an avatar.** Players were capsules, NPCs were capsules, and nothing on a deployed server resolved who anybody was: `PlaygroundPlatform` is built only by `examples/dedicated.tscn`, and this module is not a `DotGameModule`, so nothing loaded dot-platform for it. Now:

- **The figure** (`game/playground_figure.gd`): the character kit's model (`assets/kenney/characters/`, CC0, character-a plus all eighteen atlases), scaled to the character's height, turned half a turn because the kit faces +Z (game-g2gfast and game-arena shipped their faces on the backs of their heads), and painted per part: head from the face skin, torso and arms from the top, legs from the legs. By rebased path, so it loads from a mount. `PlaygroundCharacter.build_for` draws it instead of the capsules whenever it is given skins or a key, keeps `Head`/`Torso` as markers for the rig's mounts and the `RightHand` as before, and sits it down with the legs swung forward from the hip. A build without the art still draws the capsules.
- **What somebody wears** (`game/playground_avatars.gd`): schema `pg_people`, slots face/top/legs, eighteen free parts each; `from_site` reads the site's `builtin` document (`top.skin-k`), filling a slot the site left empty from the top; the stock look is one skin picked by hashing the player id, the same on every machine.
- **The server** (`PlaygroundModule._build_identity`): builds `DotPlatformIdentity` with that schema and loads dot-platform's module, unless a platform module is already loaded (the dedicated example's), and unloads it again if it loaded it. `PlaygroundNetBridge.skin_fn` is asked as a player is added, before their JOIN, and `refresh_skins` re-sends JOIN when `player_admitted` or `player_avatar_changed` says the avatar arrived later.
- **The wire**: JOIN carries three bytes after the style, each kit index + 1 (0 = stock). Appended, so a JOIN without them reads with none.
- **NPCs**: a prop entity whose id begins `npc_` (`PlaygroundProp._build_body`) and every wave NPC (`PlaygroundWaves.dress`, on the authority and on a client's mirror) wear the figure, their look keyed by kind, so every soldier matches and a rebel does not. The collision is unchanged.

`headless_net`'s **what a member wears reaches every client** (6): the translation, the JOIN with and without skins, and a server re-dressing a player with the client's figure wearing the new face; armed by dropping the client's `set_skins` (both client checks fail; the face is chosen so it cannot be the stock one, because the first version passed on a stock face). Its zee section measures the figure's own torso now. `tools/screenshot_views.sh` renders the figure in third person, another player and a rider. **Release**: the playground pack carries the art and the code; nothing here needs a new client shell (dot-platform and dot-user-avatar are already in it).

## Things deliberately not here

- **A screen for the bag, and a key that buys into it.** The wire, the server's rules and the client's copy are all here (`PlaygroundNetBridge.inventory_manager()`, `ask_buy`); `DotInvPanel` is the grid, and its `_can_drop_data` asks the same `validate` the server does. A pickup — pocketing a prop you own back into the bag — is the other missing producer, and wants a use verb this game does not have yet (see `F` above). Weapons are not items: they are not in the prop catalogue and `weapon_changed` already carries them.
- **Saving a bag.** Bags outlive a reconnect and not a restart. The document is already the JSON a save would be.

- **`Kind.HELD` is sent now (2026-10-07); the three `ask_*` with no caller are not.** The server's `_on_held_changed` broadcasts who holds which prop (from `Playground.held_changed`, emitted by every physics gun's grab and release) and tells a joiner in `_admit`; a client keeps `held_props` and `holders()` resolves it to its own mirrors, and `PlaygroundClient.present_beams` draws a beam per holder (its own from in front of the camera, everybody else's from their eye; presentation beams are keyed per holder). Before, a connected player saw no beam at all, their own included. `headless_net`'s *who holds what on the physics gun reaches the client* (4, through held fire on the server's real tools; armed by dropping the broadcast, two fail); `tools/screenshot_net.sh --hold` renders another player carrying a crate. `ask_restart`, `ask_checkpoint`
  and `publish_loadout` are the same shape one level up: the bridge has them, the server
  handles them, and no key or menu reaches any of the three, so a networked client cannot
  restart a run, use a practice checkpoint, or publish what it is carrying. These are
  listed rather than fixed because each one is a decision about the client's bindings
  rather than a missing line — but they are **not** deliberate omissions in the way the
  rest of this list is, and the encoder/decoder pair is exactly the detector that caught
  the weapon bug above.

- **A vehicle a client predicts, and a smoothing pass in the renderer.** dot-vehicle's
  reasoning is that a rigid body is not reproducible across machines, so a predicted
  vehicle is a corrected one and a correction on something a player is steering reads
  worse than the latency. Interpolation is asked for on every positional spec; whether a
  driver still feels the round trip is a thing to MEASURE on a real link before writing
  anything, which has not been done.
- **Old note, kept because the shape is still true — networking.** dot-net's bridge is the next piece, and it is now the only thing
  between this and a server people can join: `examples/dedicated.tscn` boots a real
  `DotServer` with a listener, a console and the module, and what is missing is the
  per-player replication. The shape is ready — the timer and the prop spawner are
  authoritative in one place, the game owns the tick, and every controller is already
  `EXTERNAL`. **Props will not be predicted when it arrives** — rigid-body simulation is
  not reproducible across machines, so the bridge replicates transforms rather than
  replaying inputs. The sandbox half is already shaped for that: the spawn menu emits
  rather than spawning, and the tools send intent.
- **A vote UI in the game itself.** The ballot is drawn by the client shell (below); the Tab scoreboard is dot-menu's since 2026-10-09.
- **A wardrobe screen.** The avatar schema, the entitlement check and the storage are all
  here and a player cannot yet *choose*: `DotAvatarSchema.choices_for` is the call.
- **Art.** `DotPropDef.icon_path` is read and nothing here sets it: the icons are drawn
  from the definition, which is honest for a project with no models. A server with
  content sets the field and gets its own thumbnails with no code change.
- **NPCs that fight.** They walk, chase, shove and are chased; dot-combat is installed and
  the arena gives *players* health, and giving it to an NPC as well is a `DotHealth` on a
  `DotNpcInstance` and a decision about what a wave is worth. Deliberate, because "the
  hunters can hurt you" is a different game from "the hunters are in the way", and this
  server has a cvar for turning the first one on and nothing yet for the second.
- **Welding, ropes, thrusters, duplicators.** dot-props says why: constraints are a much
  larger surface than spawning, they interact with each other, and a half-built
  constraint system is worse than none. `DotPropTool` is the hook.
- **Real maps.** These three are test fixtures that happen to be playable. A real map
  is authored in the editor and zoned with `DotTimerZonePainter`.
- **Sound, art, animation.** The maps are unshaded boxes on purpose, drawn with a generated world-space one-metre grid (`PlaygroundGeometry._material`, 2026-09-25) so a gap can be counted in squares — flat colour gave a rendered map no scale at all.
- **Replay playback.** dot-timer records and stores them; drawing a ghost is a game's
  own decision and every game's is different.

## The map vote is drawn on the client shell (2026-10-04)

The vote wrapper owns a `DotVoteBallotFeed` and polls it every `advance`; the module points its `ballot_fn` at `server.send_notice`, one copy per playing session with that session's voter id as `you`, under the topic `map_ballot`. dot-server-deploy's shell draws it as a dot-ui `DotBallotPanel` beside the server's own `game_ballot` — number keys, F3 and a click, or both, and every voter's avatar on their choice — and a click goes back as the same `!vote`-style command a player could type. Standalone, with no shell, nothing draws it and chat still carries the ballot. Defaults moved with dot-vote's: the vote's own clock is 2700 s with a 150 s lead (`map_seconds` 2700 too). The deployed sandbox stays around the clock with `duration_sec: 0` in its game.yml.

**The toys run on the server (2026-10-04, `[game-playground-1]` part 2).** A connected player's launcher, remover and impulse gun used to send their buttons to the physics gun, because the toys only ever ran on the client that held them. `_give_weapon` now builds the toy on the server (`PlaygroundWeapons.make`, equipped on the game, wielder = the player) and `_drive_tools` runs it: primary/secondary on the pressed edge, `tick` every tick. A prop it spawns is charged like a menu spawn, after the spawn, and removed if the purse refuses; a refusal with a reason goes to the player as a notice. What the launcher throws travels as `Ask.ARM_PROP` -- **the sixteenth request kind and the last that four bits hold**; anything after it must be a sub-kind, as INVENTORY is. The client sends it on a prop choice and before asking for any weapon. `headless_net` "the toys are run by the server" (armed: skipping the toy branch throws nothing).
