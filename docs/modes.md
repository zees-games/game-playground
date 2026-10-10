# The modes: arena, waves, shop, spectating, hosting

**Every mode is off by default, and the cvar is the argument.** A server where somebody can shoot you while you build, where a wave arrives, or where a jeep costs credits is a *different server*; turning one into the other because an addon is installed is exactly what a cvar exists to prevent. The browser listing shows which are on ([services.md](services.md#the-server-browsers-server-half)).

## The arena: `pg_arena`

dot-combat (health, damage types, hitboxes; friendly fire, self damage, falloff, hit groups and clamping are **policy on a resource**, not `if`s), dot-match (warmup, rounds, scoring, respawning, counted in ticks so it runs at whatever `sv_tickrate` says), and dot-loadout (what you spawn with, as ids validated against a schema and entitlements).

- **The loadout catalogue is built from `PlaygroundWeapons`**, not beside it; a `DotItem` adds only cost and unlock.
- **The required slot has a default derived from the catalogue.** dot-loadout refuses a schema without one, rightly: a loadout missing a required slot cannot be repaired, only refused, and a player who never chose could never spawn.
- **Stamp every `DotDamage` with a tick.** `DotHealth.apply` refuses anything at or before `invulnerable_until_tick`, and an unstamped event is tick 0, so it is refused on every player with nothing erroring.
- The moderator's god/buddha/hp/slay act on the arena's `DotHealth` and say "the arena is off" when it is ([services.md](services.md#the-moderators-live-tools)).
- A sandbox has no leading score, so nothing here calls the vote's `note_score`.

## Waves: `pg_waves`

dot-npc-ai-director releases NPCs the **server** owns, deliberately not prop entities. "An NPC you cannot pick up is the first thing a sandbox player will try" is about NPCs a **player** put there; a wave was spawned by nobody, owned by nobody, and reclaimed when players walk away, none of which a prop budget expresses. Two populations, two owners, and `pg_waves 1` is the only thing that makes the second exist. Wave NPCs reach clients through the bridge's prop path (`watch_npc_spawner`) and wear the people figure (`PlaygroundWaves.dress`).

- **Line of sight is on here** and off in the open-arena games: a sandbox has walls and whatever somebody built.
- **Spawn points come from the map's `DotSpawnPoint`s**; a ring round the origin is the fallback, and it says so in the log.
- **They fight as a squad**: three on a player at a time, the rest on a ring round them; they hear every shot the bridge resolves (`PlaygroundWaves.note_fire`, arena on or not); a live grenade is a DANGER on `waves.sounds`. They patrol where players actually go, learned by `PlaygroundWaves.heat` and saved in `user://npc_heat` **on a real server only** (the module turns saving on; `dedicated` clears the directory before and after so no run is trained by the last).

### Downed, not dead (shares `pg_waves`)

At zero health you go **down**, bleed out over ninety seconds, and picking you up costs somebody five seconds of not shooting: the co-operative survival shooters' answer, and what makes the wave mode co-operative. It shares the waves cvar because being killed by a wave is what being downed is for.

- **One place decides**: `PlaygroundArena.death_rule_fn` is asked before a death is reported, and a downed player is not reported to dot-match at all (no score change, no respawn queue, no kill feed). Asking "is incapacitation on" at every damage site makes as many copies of the rule as there are damage sites.
- **`begin_revive` refuses unless both rescuer and casualty are real players.** `PlaygroundDowns._position_of` answers unknown ids with a far sentinel, so two unknown ids sit at the same point and pass every distance check.
- **One player, one entity id: `Playground.entity_table`** (a `DotEntityTable`). The game opens a player's entity on join, before any layer wants one; arena and downs both ask the table. A fallback hash once gave a player two ids depending on which modes were on. `admit` still opens one for an id the game never saw (an operator adding somebody by hand) and closes it on release; whose entity it is is decided by which **node** it holds, before `_forget` frees anything. It is `entity_table` only because `Playground.entities` is already the sandbox's spawned-entity list; when those concepts merge it takes the name.

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
