# The modes: arena, waves, shop, spectating, hosting

**Every mode is off by default, and the cvar is the argument.** A server where somebody can shoot you while you build, where a wave arrives, or where a jeep costs credits is a *different server*; turning one into the other because an addon is installed is exactly what a cvar exists to prevent. The browser listing shows which are on ([services.md](services.md#the-server-browsers-server-half)).

## The arena: `pg_arena`

dot-combat (health, damage types, hitboxes; friendly fire, self damage, falloff, hit groups and clamping are **policy on a resource**, not `if`s), dot-match (warmup, rounds, scoring, respawning, counted in ticks so it runs at whatever `sv_tickrate` says), and dot-loadout (what you spawn with, as ids validated against a schema and entitlements).

- **The loadout catalogue is built from `PlaygroundWeapons`**, not beside it; a `DotItem` adds only cost and unlock.
- **The required slot has a default derived from the catalogue.** dot-loadout refuses a schema without one, rightly: a loadout missing a required slot cannot be repaired, only refused, and a player who never chose could never spawn.
- **Stamp every `DotDamage` with a tick.** `DotHealth.apply` refuses anything at or before `invulnerable_until_tick`, and an unstamped event is tick 0, so it is refused on every player with nothing erroring.
- The moderator's god/buddha/hp/slay act on the arena's `DotHealth` and say "the arena is off" when it is ([services.md](services.md#the-moderators-live-tools)).
- A sandbox has no leading score, so nothing here calls the vote's `note_score`.

### Nobody is harmed behind a loading cover

This module is not a `DotGameModule`, so it borrows dot-game's `DotGameRoster` for the still-loading bookkeeping alone (`PlaygroundModule.loading`: seated on the spawn event, loading until the client's `game.cover` report, again after a map change, released by the roster's timeouts). `PlaygroundArena.loading_fn` asks it by player key, and `PlaygroundArena.hurt`, the one function a shot, an NPC shot, a blast and lava all end at, returns a refused `DotDamage` (reason `loading`) for a loading seat; refused rather than null, because null reads as "arena off" and lava would send the player to the spawn instead. The moderator's slay and slap pass `admin = true`. A bot is never seated, so offline play and every bot suite are unchanged. `dedicated`'s `_test_loading_cover` joins a real client over the socket; `tools/render_cover.sh` renders the cover and the frames after it lifts.

### B, the arena's loadout

**B opens the loadout only inside the arena** (the lead's call, 2026-10-12): the dot-loadout manager lives in `PlaygroundArena`, which is the server's and only while `pg_arena` is on, so outside it, and always solo, B says "Loadouts are in the arena." instead of doing nothing. The client knows from `pg_arena_on`, a REPLICATED cvar the module keeps in step with the arena (`PlaygroundModule.set_arena`; setting the cvar is also the switch), and turns dot-menu's loadout on and off with it (`PlaygroundClient._set_arena_on`); the server's `closed_fn` says the same words to anybody who asks anyway.

- The server half is dot-loadout's `DotLoadoutCommand` over `arena.loadouts`, bound by the module (`/loadout`, the `loadout_menu` notice, the owner's `mp_loadout_menu`, `mp_loadout_allow`, `mp_loadout_fixed`), copied from game-arena. Keys are `PlaygroundModule.loadout_key` (`pg-player-%08d`): a player key such as `u7` is shorter than dot-loadout's eight.
- **One slot, the weapon.** The schema had a `tool` slot (physics or gravity gun) until 2026-10-12; a player holds one thing and the two tools are always on 1 and 2, so it was a choice nothing read, and it went when B made the loadout something a player chooses.
- **An arena spawn hands the weapon** (`PlaygroundArena.respawned` → `PlaygroundModule._arm_from_loadout` → the bridge's `_give_weapon`, which the shop charges as for any weapon and the client adopts from the WEAPON event). A choice made inside spawn protection is in the hands at once (`rearm_if_allowed`, `PlaygroundArena.is_protected`); later it waits for the next spawn, so no choice is a free reload mid-fight.
- The choice is remembered on the device and sent again when the arena comes on (`DotMenuLoadout.restore`); never under scratch settings.
- Cards are the spawn menu's weapon icons and, for a zee gun, zee's numbers. `tools/render_loadout.tscn` renders B outside and inside the arena (the latter on the arena's own `offer_for`, since solo there is no arena).

## Waves: `pg_waves`

dot-npc-ai-director releases NPCs the **server** owns, deliberately not prop entities. "An NPC you cannot pick up is the first thing a sandbox player will try" is about NPCs a **player** put there; a wave was spawned by nobody, owned by nobody, and reclaimed when players walk away, none of which a prop budget expresses. Two populations, two owners, and `pg_waves 1` is the only thing that makes the second exist. Wave NPCs reach clients through the bridge's prop path (`watch_npc_spawner`) and wear the people figure (`PlaygroundWaves.dress`).

- **Line of sight is on here** and off in the open-arena games: a sandbox has walls and whatever somebody built.
- **Spawn points come from the map's `DotSpawnPoint`s**; a ring round the origin is the fallback, and it says so in the log.
- **They fight as a squad**: three on a player at a time, the rest on a ring round them; they hear every shot the bridge resolves (`PlaygroundWaves.note_fire`, arena on or not); a live grenade is a DANGER on `waves.sounds`. They patrol where players actually go, learned by `PlaygroundWaves.heat` and saved in `user://npc_heat` **on a real server only** (the module turns saving on; `dedicated` clears the directory before and after so no run is trained by the last).

### Downed, not dead (shares `pg_waves`)

At zero health you go **down**, bleed out over ninety seconds, and picking you up costs somebody five seconds of not shooting: the co-operative survival shooters' answer, and what makes the wave mode co-operative. It shares the waves cvar because being killed by a wave is what being downed is for.

- **One place decides**: `PlaygroundArena.death_rule_fn` is asked before a death is reported, and a downed player is not reported to dot-match at all (no score change, no respawn queue, no kill feed). Asking "is incapacitation on" at every damage site makes as many copies of the rule as there are damage sites.
- **Down is drawn from replicated state.** `PlaygroundDowns.tick` writes `PlaygroundPlayer.downed` on every player every tick (a revive, a bleed-out, a stand-up and the mode switched off all clear it the same way), `PlaygroundPlayerNet.net_downed` carries it (appended, everybody's), and `face_body` hands it to the person, who crawls. Until 2026-10-13 the downs were server-only and a downed player stood on every client for the ninety seconds. `tools/screenshot_net.sh --downed` renders it, and `--died` then lets the client copy the bleed-out ragdoll from the crawling figure (looked at 2026-10-18: it starts on all fours and falls from there); `headless_net` checks it.
- **`begin_revive` refuses unless both rescuer and casualty are real players.** `PlaygroundDowns._position_of` answers unknown ids with a far sentinel, so two unknown ids sit at the same point and pass every distance check.
- **One player, one entity id: `Playground.entity_table`** (a `DotEntityTable`). The game opens a player's entity on join, before any layer wants one; arena and downs both ask the table. A fallback hash once gave a player two ids depending on which modes were on. `admit` still opens one for an id the game never saw (an operator adding somebody by hand) and closes it on release; whose entity it is is decided by which **node** it holds, before `_forget` frees anything. It is `entity_table` only because `Playground.entities` is already the sandbox's spawned-entity list; when those concepts merge it takes the name.

### The dead fall

A player killed in the arena, a downed player who bleeds out, and a killed NPC (a wave, a sandbox soldier) fall as dot-player-char's ragdolls (its `docs/ragdolls.md` has the reasoning).

- **Both player paths carry the fall.** `PlaygroundArena.decide_death` runs in `_on_killed` (the shot's direction or away from the killer, the zee weapon's def) and for a bleed-out (named `crumple`), and the death rides COMBAT last and optional. Going down is not a death and draws nothing yet: the downed state has no look on a client at all (not converted yet).
- **A bleed-out is announced like any death.** It only reached dot-match before: no COMBAT, no kill-feed line, nothing a client could draw. The module's `downs.died` handler now emits `arena.player_killed` as well.
- **A killed NPC's fall rides its PROP_GONE** (`Playground.decide_npc_death` leaves it on the body as `pg_death`; the bridge sends it when the reason is `killed`), and the client copies the mirror's `Figure` before freeing it (`body_fell`).
- **Connected only.** A solo sandbox has no arena and nobody dies; the client's `fall` and `rise` are what a COMBAT drives (`rise` on the respawn's COMBAT with health). Bodies land on `world`, `prop` and `frozen_prop`, never on a player. No ragdoll of your own body in first person.
- The `sv_ragdoll*` cvars are the module's, REPLICATED, followed by the client.

## `pg_shop`: a sandbox with prices

A free spawn menu has no pacing; a price list makes the wave mode worth playing (a wave pays, a jeep costs) without a new mechanic.

- **The price list is derived**: `PlaygroundShop.catalogue()` prices every prop from mass, size and budget cost, and every weapon (350 credits). A hand-written list goes stale on the fifteenth prop.
- **Money is not the budget.** `DotPropLimits` still caps what one player may have in the world; credits must not be a way round it.
- **The bridge charges through `charge_fn`**, a callable, because the bridge is dot-net's half and knows nothing of prices. Unset, everything is free, so no call site branches on whether a shop exists.
- **A spawn is asked, placed, and only then charged** (`_spawn_for`, with `may_charge_fn` = the shop's `may_have`). Charging first and refunding on a refusal is not atomic: dot-economy's refund is a policy that can itself be refused on servers that turned refunds off. Affordability is one read that changes nothing, and `buy` is `may_buy` plus the debit. A charge that still fails after the spawn takes the prop back out and says so at WARN.
- Weapons are charged when the client asks for one (`ask_tool` → `_give_weapon`); see [netcode.md](netcode.md#weapons-over-the-wire).

## `pg_spec`: watching is not about being dead

The interesting thing on a sandbox is what somebody else is making, so the policy is the loosest in the family: anybody, alive or dead, may watch anybody, and roaming is on. **It tightens the moment `pg_arena` goes on**: a living player watching a living one they are fighting is a wallhack.

## Hosting a sandbox: `PlaygroundParty`

**Host migration is off because the world IS the host's physics state.** Every prop and contraption lives in one process's rigid bodies, so electing a new host hands everybody an empty room with every count still correct. (The continuous arena game migrates; the round-based and timer games do not, each for its own reason.) The trust model is `HOST_AUTHORITATIVE`: a friend hosting *should* be able to hand out money and spawn a hundred crates. What must not leave is anything persistent, and `reporting_allowed()` is the one place asked.

Meeting goes over HTTP awaited end to end (`[p2p-await-games]`): `headless_presentation`'s **a party that meets over HTTP** uses a local four-route rendezvous stub that answers frames after each request, because the loopback signaller answers inside the call and passes a caller that forgot `await`. A `PackedByteArray` read out of a Dictionary is a copy (the stub's first version appended to nothing).
