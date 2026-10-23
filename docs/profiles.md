# Profiles: the menu and live edits

The Q menu's NPCs and pack weapons come from dot-core profiles (`docs/profiles.md` in dot-core), added to the built-in catalogue, never replacing it. Code: `game/playground_profiles.gd`; built by `Playground._build_addons` as `Playground.profiles`.

## NPCs

`cfg/game/game-playground/npc/<id>.yml` (game tier; the game key is the repository name) over `cfg/addons/dot-npc/npc/` and under `cfg/server/game/game-playground/npc/` and `cfg/server/addons/dot-npc/npc/`.

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

## The admin workbench (web page and API)

dot-workbench's `DotWorkbenchHttp` edits the same `Playground.profiles.runtime` over HTTP; `game/playground_workbench.gd` wires it into the server module. It is **off unless** `cfg/server.yml` has a `workbench:` block with `enabled: true` (`bind` defaults to loopback, `port` 8790, `token_file` is a path, never a value; see dot-workbench `docs/design.md`). Link it for development with `ln -s ../../dot-workbench/addons/dot_workbench addons/dot_workbench` (gitignored).

- The module builds it after the console's permit is set, so a bearer token acts as the workbench token actor (`cvar` and `root`) and every other actor goes through the same admin-flag check `profile_edit` uses. An edit reaches the next shot exactly as a console edit does.
- **Accounts**: with dot-auth running a ticket key, a connect ticket is also accepted as the bearer (`PlaygroundWorkbench.ticket_resolver`, verified offline, audience-checked, not burned). Only `admin_uids` and `admin_groups` in the `workbench:` block are let in, and `server.admins.uid_has_permission` still decides `cvar` and `root`. With neither listed nobody is admitted. `token_file` becomes optional when an account resolver exists. Checked by "the workbench admits a dot-auth account".
- The module polls it from `_process` and stops it on unload. `workbench` (admin `cvar`) prints its state, from `describe()`.
- An export that ships the page needs `*.html` in its include filter (this repository keeps no `export_presets.cfg`).
- Checked by `headless_packs_real` ("the workbench edits a weapon over HTTP": list, authorised set, 401, 429, next shot) and `dedicated` (off by default).

## The in-game workbench (F6)

`game/playground_profile_screen.gd` is an admin-only screen on the client's screen stack: the `pg_profiles` action (default F6, rebindable under General) or the Escape menu's "Profile workbench" entry. The sidebar lists NPC and weapon profiles in the Q menu's grouping (a dot marks an edited profile); the card shows `kind / id`, an "EDITED LIVE" chip with the key count, the revision, and the buttons Spawn in front of me / Give me this weapon (the Q menu's own paths), Reset all and Save to server. The body is a `DotUiForm` over the profile schema; a weapon's `extra.*` numbers are synthesised as sliders and toggles.

- Edits are debounced (0.12 s) and sent as requests through `DotNetProfileLink` (`PlaygroundPresentation.profile_submit`), never applied locally, so everyone sees them. Offline the process is the server and edits its own runtime. A per-key Reset is `reset_key`; Save is the `save` op (admin `root`).
- The form follows `profile_changed`, so another admin's edit shows here; the refresh waits while the mouse is held or edits are pending, so a slider drag is not fought.
- Admin gating: there is no "am I an admin" message, so the client probes once per connection with a harmless `reset_key` on an empty id. An answer starting "profile edits need" means a player (the entry is hidden and a notice shown), anything else an admin. The probe costs one WARN line on the server per non-admin who presses F6.
- `docs/workbench_npc.png` and `docs/workbench_weapon.png` are rendered by `tools/render_workbench.sh` (xvfb, 1280x720).
- A readout line under the card gives DPS (burst, and sustained with reloads) of the weapon last opened and the shots and seconds to kill the NPC last opened (100 hp until one is opened). `game/playground_profile_readout.gd` computes it from the flattened rows (`extra.damage` times `extra.pellets` or `extra.splash_damage`, `extra.rpm` or `use_interval_ticks`, `magazine`, `extra.reload_seconds` or `reload_ticks`), so it follows live edits.
- Checked by `headless_playground` ("the profile workbench edits live through requests", DPS and TTK arithmetic included).
