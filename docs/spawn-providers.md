# Spawn providers

How an optional pack puts weapons, NPCs and bots in the Q menu without the playground naming it. The sibling of the [addons folder hook](sandbox.md#the-addons-folder-hook), for things a player gives themselves or spawns, not for actions.

## The contract

A pack ships `res://addons/<pack>/spawn_provider.gd` (a dot-cloud pack mounted under `res://addons/` counts), or registers any object in `DotRegistry` under a name starting `playground.spawn_provider` (the rest of the name is the pack). The object is duck-typed: no `class_name`, no base class, `RefCounted` or `Node` (a Node is added under the game). It needs one method:

```gdscript
func spawn_entries() -> Array[Dictionary]
```

Each entry:

| Key | Meaning |
| --- | --- |
| `id` | unique within the pack (required) |
| `kind` | `"weapon"`, `"npc"`, `"bot"`, or anything else (required; anything else needs a Callable `spawn`) |
| `name` | card label; defaults to the id |
| `category` | the chip it is grouped under on its tab; defaults to the kind, capitalised and pluralised ("Weapons", "NPCs") |
| `icon` | optional `res://` texture path for the card |
| `spawn` | a `Callable`, or a string (below) |
| `cfg_hint` | optional Dictionary. For `npc`/`bot`: `count` (1 to 8, default 1) and `weapon` (an id the NPC is armed with). Shown in the tooltip and passed to a Callable. |

An entry that is not a Dictionary, has no id or kind, or has another type of `spawn` is skipped and logged on `pg.addons`; the others from the same pack still show. At most 256 entries are read per provider. A provider without `spawn_entries`, or one that does not compile, is refused and logged. **No pack at all is the normal case**: the menu has no entries from it and nothing is logged above DEBUG.

## What choosing an entry does

The menu never spawns. It asks (`ARM_ADDON_ITEM`, the same request the Addons tab always used); the server runs the entry in `PlaygroundAddons._run_entry` for the asking player, looking at the point they aim at. A client (`authoritative` false), an unknown player, or an unknown key is refused.

- **`weapon`, string `spawn`** (the weapon id; empty means the entry's `id`): must be in the game's weapon catalogue (`Playground.weapon_def`), else refused. It is given with `Playground.pick_up_weapon`, the event a floor pickup raises, so a server's bridge charges and arms it exactly as a pickup, and offline the client equips it. There is no second way to hold a weapon.
- **`weapon`, Dictionary `spawn`** (`{weapon_id}` or `{weapon}`: what the real weapon packs hand out, with the definition behind the provider's static `weapon_defs()`): when the provider is registered, both ends add a `PlaygroundWeaponDef` named `pk_<pack>_<weapon>` to `Playground.weapons` (`meta.zee`, `meta.pack_def`, as a Workshop weapon is, kept in `PlaygroundZee` apart from the Workshop's so a sync never drops it), then the entry goes through the same pickup path. A provider with no `weapon_defs()` is listed and refused.
- **`npc` / `bot`, string `spawn`**: a catalogue prop id (for example `npc_soldier`) is spawned through the prop spawner as the player, so the NPC limit, the cost budget, the spawn interval, entitlements and creative mode apply. A `res://...tscn` path is instantiated under the world instead; it is not in the catalogue, so its only limit is 16 alive per player (`PlaygroundAddons.MAX_SCENE_SPAWNS`). A scene NPC that wants dot-bot behaviour wires it itself.
- **Callable `spawn`** (or `spawn_fn`, which wins when `spawn` is a stats Dictionary kept for other consumers; a Dictionary with no `spawn_fn` is listed but refused): called on the server with `{game, world, player_id, at, kind, cfg_hint, authoritative}` and may return a `DotResult`. The pack is then responsible for its own limits; use `game.props.spawn` to inherit them.

Props and the rest of the kinds are not built yet: a `prop` entry works today only as a Callable.

## Where they show

`weapon` entries get a **Pack Weapons** tab and `npc` / `bot` entries an **NPCs** tab, both in the Q menu beside the game's own tabs (Props, Entities, NPCs, Weapons, Pack Weapons, Tools, Builds, Addons). Each has category chips, the search box, an icon grid and the entry's hint as the tooltip. A tab exists only while at least one entry of its kind does (`PlaygroundSpawnMenu._sync_provider_tabs`; it is hidden, not removed, so the `Tab` indices stay fixed), and falls back to Props if the open one loses its entries. The weapons tab is titled "Pack Weapons" because the game's own Weapons tab already has that name. An entry without an `icon` gets a tile from `PlaygroundIcons.for_provider` (its kind's silhouette in a colour taken from the name). Clicking asks the server by key (`addon_item_chosen`), exactly as the Addons tab did. Any other kind stays on the Addons tab with the hooks' items.

## Not yet

- Entries are listed once at start; a pack mounted later by dot-cloud shows after the next boot.
- The Q menu has no phone layout yet, so neither do these tabs.

The test fixtures are `examples/fixtures/spawn_pack/` (valid, with bad entries), `spawn_pack_broken/` and `spawn_pack_none/`, used by the "spawn providers" section of `examples/headless_playground.gd` with a scratch root, so the real `addons/` is untouched. `tools/screenshot_menus.sh` renders `menu_provider_weapons.png` and `menu_provider_npcs.png`.

`examples/headless_packs_real.tscn` runs the three real packs (zz-modern-weapons, zz-medieval-weapons, zz-historical-monsters, linked into `addons/` as gitignored symlinks) through the menu and the activation path, and prints SKIP when they are not linked. `tools/screenshot_menus.sh` renders `menu_real_packs_weapons.png` and `menu_real_packs_npcs.png` from them.
