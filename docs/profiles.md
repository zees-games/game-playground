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

Weapons: `profile_edit set weapon <id> <key> <value>`, where `<id>` is the profile id (`m4`, `mace`) and a pack's own numbers sit under `extra.` (`extra.damage`). Every pack's weapon set is one kind through dot-weapon's `DotWeaponProfileGroup` (`Playground.profiles.weapons`), whose runtime layer is handed to the pack: a provider that offers `weapon_defs_with(layer, types := {})` is rebuilt over it, and on `profile_changed` the game copies the rebuilt definition onto the one rigs already hold (`PlaygroundAddons.reapply_weapons`), so the next shot reads the new damage, rate or spread. A provider without that method keeps its file numbers. Two packs share one id space (the game and server tiers already did): the same id in both is edited together. The weapon needs a profile file, so link a pack's `cfg/` as above to edit it in development.
