# Profiles: the menu and live edits

The Q menu's NPCs and pack weapons come from dot-core profiles (`docs/profiles.md` in dot-core), added to the built-in catalogue, never replacing it. Code: `game/playground_profiles.gd`; built by `Playground._build_addons` as `Playground.profiles`.

## NPCs

`cfg/game/game-playground/npc/<id>.yml` (game tier; the game key is the repository name) over `cfg/addons/dot-npc/npc/` and under `cfg/server/npc/`.

- A profile named like a catalogue entry (`npc_chaser.yml`) overrides **only the keys it states**: `name`, `health`, `speed`, `sight`, `sight_angle`, `hearing`, `faction`, `los`, `cost`, `extra:` (copied to the entry's `meta`, where `tune` reads them). A key counts as stated when it differs from the schema default or was edited at runtime.
- `menu: {category, sort, hidden}` regroups, orders and hides. `enabled: false` hides too. The Entities tab sorts by `menu.sort`, catalogue order breaks ties.
- A new id needs `extra: {base: npc_hunter}`: it is a clone of that entry with the profile on top. An id with neither a catalogue entry nor a base is skipped with a warning.
- Removing the file restores the entry (a clone is removed) on the next `apply_npcs`.

## Pack weapons

For each spawn provider (`pack` = its folder), `DotWeaponProfiles` reads `cfg/addons/<pack>/weapon` plus the game tier. A row `zz_m4` matches the profile `m4` (the row id ends with `_<profile id>`). `menu.category` regroups, `menu.sort` orders, `menu.hidden` / `enabled: false` drops the row, `menu.icon` sets an icon. Rows without a profile stay. A pack's `cfg/` has to be reachable under a config root: in development link it as `cfg/addons/<pack>` (gitignored), a delivered pack ships it.

## Live edits: `profile_edit`

`profile_edit set npc <id> <key> <value> | reset_key | reset | save` (dot-console's `DotConsoleProfileEdit`). On a client it goes through `DotNetProfileLink` to the server; the server checks the admin flag by account uid (`DotAdminManager.uid_has_permission`: `cvar` to edit, `root` to save), validates against the schema, replicates the row to everyone and replays the edited profiles to a joiner when it is admitted. The server console edits as the process itself; offline play edits its own runtime. The link attaches before the net types seal, and a peer without the types still plays.

`profile_changed` makes new spawns use the new numbers (the catalogue entry is rewritten) and calls `PlaygroundEntity.re_apply` on live NPCs of that id: perception (`sight`, `sight_angle`, `hearing`) and the copy of `meta` change at once, a spawned NPC keeps its health.

**Weapons are not editable yet**: the packs build their numbers once from their own profile set, outside the runtime layer, so a weapon edit has nothing to reach. The runtime registers kind `npc` only.
