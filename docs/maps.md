# Maps

Maps are content, not projects (see dot-map's [docs/content.md](../../dot-map/docs/content.md) for why a project per map falls apart). The built-in maps are `pg_lobby`, `pg_surf_intro`, `pg_bhop_intro` (hand-built scripts), `pg_generated` (seeded) and `pg_data` (builds any JSON map document). The custom maps are documents from game-playground-maps, linked in as `maps/custom`. Every timed route on the hand-built maps is in [routes.md](routes.md).

## Geometry and zones come from one description

Each hand-built map builds its geometry **and** its zones from the same constants and functions, so a start line cannot drift half a metre from the ramps (a leaderboard nobody can compare). A route is one function (`PgLobby.tower_route()`, `PgBhopIntro.ladder_route()`, `PgSurfIntro.bank_basis()` …) that the geometry, the zones and the suite all read and nothing else does.

A **delivered** map ships geometry and a zone file, so `tools/export_zones.gd` writes the `*.zones.json` files from the same source, they are committed, and `headless_playground`'s `_test_zone_file_matches_the_map` fails when the file no longer matches. **Run it after changing a map:**

```bash
godot --headless --path . --script tools/export_zones.gd
```

Every route's zone set is checked **for its own track** by dot-timer's `DotTimerZoneSet.route_problems()` (`[track-zone-1]`): `problems()` is per zone, and a set complete for track 0 and partial for track 1 passes it while being unfinishable. `pg_lobby`'s circuit is the one route with no pit and says so in its zones' `meta.pitless_tracks` (the road runs inside the plate's walls).

## The timer is not a surf-and-bhop thing

`pg_lobby` is a sandbox on the **main** track with no start or end zone (the one place proving the rest of the game does not quietly require a timer), and timed courses on bonus tracks beside it. Nothing about a jump course is a movement genre: it is zones round platforms with the same sub-tick fractions, styles, records and replays. The mixed case is a better test than the empty one because it is the case a real sandbox server is in.

`pg_generated` deliberately has **no timer course**: a generated course is one nobody can learn and a record nobody can beat.

## The look

A sunny afternoon over pastel prototype blocks, the same family look as game-arena's built-in maps: a light tiled floor, sky-blue ramps, a mint start, a pink end, lavender platforms and walls, yellow boosters, a blue sky, a warm sun with soft shadows, a pale cool fill in the shade, mild glow and a filmic tone map.

- **The palette is `PlaygroundGeometry.COLOUR_*`**, one constant per kind of surface, and every built-in map and every custom document that names a colour (`"ramp"`, `"start"`) takes them; a document's own hex colours and the material looks stay its own. A repaint is a change to those constants and nothing else: no geometry, no zones, no zone-file export. Start and end keep their old green-ish and red-ish meaning so a route still reads.
- **The texture is Kenney's Prototype Textures (CC0, `assets/kenney/prototype/`)**: the grid on every surface and the tiles on the floor colour, tinted per material and laid world-triplanar at 2 m a copy, so a major line is a metre (what a gap is counted in) and a faint one 25 cm. World space rather than UV, because a box's own UVs stretch one texture over a whole face and a 3 m block beside a 220 m ramp read as two tiles; that is why the grid exists (2026-09-25). One material per colour, shared, because the Compatibility renderer pays per material change. An unimported checkout falls back to a generated one-metre grid.
- **The materials are lit.** They were unshaded while the maps had a bare sun and no sky; with a fill light a face turned from the sun is a shade darker and box edges show without a line drawn on them. Props, figures and vehicles are still unshaded (their own look; not part of this pass).
- **Light is a dot-lighting document the map carries** (`game/playground_lighting.gd`, `PlaygroundGeometry.light`, called once from each map's build). A built-in map takes `PlaygroundLighting.DAYLIGHT`; a custom document may give its own under `lighting` (dot-lighting's keys plus `sky_top`). The sun and the `WorldEnvironment` are children of the map node, so they come and go with the map and there is never a second environment (the renderer silently ignores one); the render tools add none of their own. `headless_playground`'s survey section checks each hand-built map carries one of each.
- **What this game adds to `DotLightRig`:** `sky_top` (the rig draws the zenith in the ambient colour, which here is the shade's pale grey, so the blue is painted after the rig, as arena does); the sky continued under the horizon (`sky_below_horizon`, since the surf and bhop maps float in the air and the default dark lower half was a brown void beneath them); shadows to 140 m with a softened edge.
- **Turned down under Compatibility**, which the project and the client shell use: it has no headroom above white and clipped every sunlit pastel to flat white at Forward+'s numbers. Under `gl_compatibility` the sun is divided by 700 instead of 200 and the fill drops to 0.62 (arena's numbers, rendered side by side here too). Check a look change in both: `tools/screenshot.sh <map>` is Compatibility, `RENDERER=forward_plus tools/screenshot.sh <map>` the other.
- **The browser keeps dot-lighting's `web()` profile, shadows off**, unlike arena: these maps are large (the sandbox is 200 m with whatever the players spawned on it) and the shadow pass draws all of it again.

## Every hand-built map is surveyed

`PlaygroundMapSurvey` (`[gate-sweep-2]`) reads a built map's boxes (every `StaticBody3D` with a `BoxShape3D`, rotated or not), rasterises them into 0.25 m columns of solid spans, and asks:

- **slots**: two boxes facing across less than 0.8 m (the family's player width) over more than a step's height;
- **unreached**: standable ground (face within 46 degrees, 1.8 m headroom, nothing in the hull's neighbouring columns) that no spawn (a SPAWN zone's or a TELEPORT zone's destination, or the fallback) leads to by walking, dropping, sliding down an unstandable face, or a jump inside `jump_reach(rise)`;
- **trapped**: ground a spawn leads to from which no spawn, finish, respawn zone or fall into one is reachable.

What counts as a climb is `PlaygroundMap.climb_limit()` (apex × 0.9), not the 1.15 m apex. **Unreached is allowed only where the map says so**, in `PlaygroundMap.survey_declared()` (`{box, why}` per area): wall tops, a steep ramp's tilted crest, backstop tops, areas reached only by a launch, a zone's gravity or carried speed, none of which the survey models. It errs toward reporting: a jump is judged edge to edge from above, not swept; no carried speed; a tilted box is its world AABB for the slot sweep. The suite first runs it over a fixture with one of each problem, so a clean map is known to have been looked at. `pg_generated` is not surveyed: `PlaygroundWorldGen`'s validator floods it on every seed. Custom maps are (`CUSTOM_MAPS`).

## Custom maps are documents

`maps/pg_data.gd` builds a map from a JSON document: boxes (centre, size, colour, optional turn, optional `material`), a spawn and yaw, survey declarations, and optional `props` and `wires`. `Playground.map_catalogue()` adds every document in `maps/custom` as a `DotMapDef` with `meta.doc`; `_on_map_changed` calls `configure_doc` before anybody spawns.

- **Documents, not scripts**: a map delivered in its own pack is mounted at another prefix, and a script there extending this game's map base by path is right in only one of the two places it runs.
- **Delivered**, the map pack is a dependency (a client builds the map too): `PlaygroundModule._add_delivered_maps` adds `<mount>/maps` from the game manager's dependency keys, `PlaygroundClient` adds the same from `DotClientLink.content_extra`, both through `Playground.add_map_directory`, which rebuilds the rotation. An id already in the catalogue is never replaced. `game.yml` sets `maps_delivery: client`.

### Map props

`Playground.spawn_map_props` puts a document's props down on the server after `configure_doc` and before anybody spawns, owned by `Playground.MAP_OWNER` (`map`, never a player id, so no player's limits, undo or "remove mine" reach them; the remover still does where `touch_others_props` allows, and a reload restores them). Frozen by default; wires through `DotPropIO`. The spawn rate limit is lifted for the load. A door keeps the transform the map gave it as its shut position. **An id this server lacks is left out with a WARN, not the map**: a map is boxes first. Clients get them through the prop path; dot-props' non-authoritative spawner refuses every client spawn, and `Playground`'s own `authoritative` guard stays only to stop a false "props this server does not have" WARN.

`tools/map_props.gd` (`godot --headless --path . --script tools/map_props.gd -- [map ...]`) loads maps through the real game and reports every prop that moved more than 0.5 m or fell out of the world in five seconds (exit 1): drifting furniture or a toppling stack is invisible to the survey, which reads boxes.

## Map materials

A box may name one of dot-physics' fifteen surfaces (`game/playground_materials.gd`). **The numbers are dot-physics'**: friction and bounce go on the box (`to_physics_material`), and movement comes from the same entry through `DotFpsSurface.from_physics`, set as every player's `controller.surfaces` and found from the box's `dot_fps_surface` metadata. Client and server build it from one document, so prediction agrees. This game adds only each material's look (`LOOKS`; alpha under 1 is see-through, drawn both sides).

- **A volume has no collider**: liquids (water, slime, lava) and non-solid surfaces (foliage, drawn and walked through). `PlaygroundMaterials.is_volume`. Liquids are recorded (`liquid_volumes()`, axis-aligned; a turned liquid is refused) in `Playground.liquids`.
- **Lava and slime hurt** on the authority (`_liquid_tick`): through `hazard_hurt` (the arena's `hurt`, set by the module), and when that does nothing (arena off) the player is sent to the spawn. A prop that has touched lava melts `MELT_SECONDS` (1) later whether or not it bounced clear (a timer reset by each bounce let a crate ride a lava lake).
- **Swimmable** is liquid with density at or under `SWIM_DENSITY` (1200): water and slime, not lava.

### Water: swimming and floating

**Players swim** through dot-player-controller's `DotFpsSwimMode`, one per player in `controller.extra_modes` (so a style's rebuilt motor keeps it under the same id on every machine). Its water is `Playground.water_boxes()`, set on every map change and on joining (`PlaygroundPlayer.set_water`), entered from `_on_simulated`, which a prediction replay also runs. The client's own entry matters even though a short link hides its absence: the mode travels in the snapshot, but on a real round trip a client without it walks on the bed.

**Props float** on the authority (`_float_props`): buoyancy by the liquid's density over the submerged volume, drag from `dampening`, the bob **critically damped** (2√k) and applied whenever touching, not scaled by depth (anything else shot a light crate a metre out of the basin and bounced it on lava for ever). A prop's density is the catalogue's `density` meta where given (`PlaygroundSpawnables.DENSE`: the catalogue's masses are tuned for a physics gun and make a boulder lighter than water), else mass over volume.

**A splash is the client's own** (`PlaygroundClient._present_splashes`): both ends build the liquids from the document, so nothing travels. Half a metre over the surface counts as in, because a floating crate's centre is above the water.

### Glass and thin ice break

A box whose material has dot-physics' `break_health` (glass 25, thin ice 8) is a **pane**: `Playground.panes`, rebuilt per map by `_index_panes`, `broken_panes` the ones gone. `hurt_pane` is the one door: shots (`player_shots_fired` / `npc_shots_fired`), blasts (`hurt_panes_in`) and **fast impacts** (`_pane_impacts`): a prop or player moving into a pane faster than `PANE_IMPACT_SPEED` (6 m/s) **along its normal**, read from last tick's velocity because the contact has already stopped the body. Running along a wall is not running into it. A floor-like pane is tested at the feet as well as the chest. `break_pane` removes the box, emits `pane_broken`, throws `debris` shards on the authority, and the bridge broadcasts `Kind.PANE` and tells a joiner every broken one. `pg_breakable_glass` (on) is separate from `pg_destruction`: glass in a map is put there to be broken.

## `pg_generated`: the one map nobody wrote down

A sandbox's content is what players build, so "somewhere new" is worth more than "somewhere good" here. `PlaygroundWorldGen`: BSP rooms with big leaves (a maze of cupboards is every dungeon-tuned BSP's failure), three-cell corridors with **loops on purpose**, prop points with minimum separation, and a validator.

- **The validator is why it ships.** It floods from the spawn, refuses a map where anything placed is unreachable or that is nine tenths wasted, fills sealed pockets, and retries on a new seed up to ten times.
- **Walls are one box per run of solid cells**, not per cell (900 static bodies in a physics sandbox).
- **The map does not build in `_ready`**: dot-map adds the scene with no moment between, so `Playground` calls `configure()` from `map_changed` before spawning anybody. A static pending seed would be read by a second server in the same process.
- **`PlaygroundConfig.map_seed`** is the seed ("play the map I played" is the most-requested feature of any generated world), and the seed actually used is logged. Zero takes it from the registry's `dot_random_source` (dot-core's randomness), so the map, scattered props and audio variation all come from **one** number.
