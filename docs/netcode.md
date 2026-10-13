# Netcode

`game/net/`: `PlaygroundNetBridge` (the dot-net bridge), `PlaygroundNetLink` (the RPC node `Server/Playground`), `PlaygroundPlayerNet`, `PlaygroundPropNet`, `PlaygroundNpcNet`, `PlaygroundVehicleNet`, `PlaygroundInventoryNet` ([inventory.md](inventory.md)), and the message types `PlaygroundEvents` (`Kind`, events to clients) and `PlaygroundRequest` / `Ask` (requests to the server).

The shape: the game owns the tick and every controller is `EXTERNAL`; players are predicted by their owner; **props and vehicles are never predicted** (rigid-body simulation is not reproducible across machines, so transforms are replicated); the spawn menu and the tools send intent and the server acts.

## A connected client finds its link

When the scene's `link` export is unset, `PlaygroundClient` reads `DotRegistry.get_node_service(&"dot_client_link")` like every other game. The export still wins (two shells in one process keep their own links), and `--offline` skips the lookup. A delivered pack's scene is instantiated by `DotClientLink._on_load_game`, which sets nothing on it, and before the lookup every connected client booted `authoritative=true` with a private copy of the map. Check with `playground starting authoritative=…` in each client's log. Without `--content-url`, a local client fetches the **production** pack whatever `dist/` says.

## A client predicts its own player, and nobody else

`_mirror_owner(session_id)` owns the mirror with `net.local_peer_id` when the session id is the one HELLO named, and 0 for everybody else; `_claim_local_player()` on HELLO takes a mirror over through `registry.change_owner` if JOIN got there first. No wire change, and the owner is whatever `local_peer_id` is, so `is_owner` cannot disagree with it (a peer id sent on the wire is right only if the client's copy matches the server's number). Vehicles are untouched. The story of the bug this replaced, and why no quiet-mechanism check saw it, is in [history.md](history.md#a-connected-client-predicted-nobody).

**The camera draws from a blend**: predicted, the eye moves once a tick and steps on a high-refresh screen. `PlaygroundPlayer.render_eye_position()` is `DotFpsController.render_state()` through the motor (the last two ticks blended by the physics fraction). Aim and traces still use `eye_position()`. Not while riding.

## Somebody else's body

- **Shown when it is not yours**: `PlaygroundPlayer.body_shown()` is `not samples_input or view_mode() == &"tp"`, applied by `refresh_body()` when the body is built, when the view switch is built (the moment a client learns a player is its own) and on F5. A view mode is a fact about the **local** player.
- **Seated on its player**: a visual seats its drawn node on the nearest `Node3D` ancestor (dot-player-char). A `Node3D` under a plain `Node` inherits no transform and stands at the origin.
- **Turned every frame**: `PlaygroundClient.present_frame` (static, so `headless_net` drives exactly it) interpolates and then turns every body with `face_body()`, because `drive_character` runs only where the game ticks every player.

## A broadcast reaches READY peers only (`[pg-rpc-before-scene]`)

`DotClientLink` reports LOADED the moment it has added the game scene, which is dot-server's `client_spawn`, but the client builds `Server/Playground` only after its first map is up. So:

- `_broadcast` goes **peer by peer to `_ready_peers`**, never `net.send(msg, 0)` (which is `rpc()` to every socket). A joiner learns everybody, itself included, from `_admit`, which sends HELLO before the JOINs.
- **Greet from `peer_admitted`**, emitted the first time `_admit` runs for a peer, not from `client_spawn` (where the peer is never ready). The module's `_welcome` (chat backlog, join line, clock) runs from `_on_peer_admitted`.
- `remove_player` drops the peer from the ready set before its LEAVE (told directly through `PlaygroundNetLink.can_reach`), and asks **`net.peers()`**, not the ready set, whether to `net.remove_peer`, or a disconnected peer keeps getting snapshots for ever.
- **Voice is gated too**: `PlaygroundServices._send_voice` holds frames for a peer that is not READY (`voice_held`); the router still lists the peer so it hears the first frame after READY.
- Every directed `_tell` answers a request or a run, which a peer can only have once it is in. A map change needs nothing: `Server/Playground` outlives the map, and HELLO names the current map. A reconnect is a new peer under a new userid.

## A prop mirror is on the props layer

`PlaygroundNetBridge._apply_prop` classifies a mirror with `Playground.layer_for(def, frozen)`, the server's own answer (`[prop-mirror-layer-1]`); a mirror on the scene's 1/1 is world geometry to a client predicting its own player against it. **Still missing:** the PROP event carries no frozen state, so a mirror is classified as an unfrozen spawn and a prop frozen later is reclassified on the server only. The client bridge freezes a mirror before it enters the tree; until its first interpolated draw it would otherwise fall under the client's own physics.

On a networked client only your own props make a spawn noise (`PlaygroundNetBridge.prop_arrived`), because a joiner is sent the whole world's props through the same PROP event and the wire cannot tell a backlog from a spawn.

## Who holds what

`Kind.HELD`: the server's `_on_held_changed` broadcasts who holds which prop (from `Playground.held_changed`, every physics gun's grab and release) and tells a joiner in `_admit`; a client keeps `held_props`, `holders()` resolves to its mirrors, and `PlaygroundClient.present_beams` draws a beam per holder. A held **player** travels as a SEAT with vehicle 0.

## Weapons over the wire

- The client sends `ask_tool` for every tool and weapon, and arms locally as prediction; the server's `Kind.WEAPON` (from `_select_tool`) is the correction, read by the client (`weapon_changed`). A joiner is sent everybody's current tool from `_tool_of` in `_admit`, because a WEAPON event is sent once.
- Zee: `PlaygroundPlayerNet` replicates `ZeeWeaponNet.all_specs()` (magazine and reserve owner-only); `_apply_weapon` hands the counter to `ZeeWeaponNet.apply` with the player's `zee_world`, a `ZeeWorldModel` that `PlaygroundZee.show_held` hangs on the character's `RightHand` mount (in front of the torso's right side; on the torso the gun hung at the capsule's centre). Shot effects come from the client's own LOCAL rig and from a remote player's `zee_world` when the counter moves; the local player's `zee_world` stays quiet because its first-person rig makes the effects. Recoil goes to the camera through `DotFpsView.external_angles` in `_present_zee`, reset when no zee gun is in hand.
- Projectiles: one `Kind.PROJECTILE` event, LAUNCH and DETONATE ([sandbox.md](sandbox.md#grenades-and-rockets)).
- Confirmed hits: `Kind.HIT`, to the shooter's peer alone, from `Playground.hit_landed`. The game emits it through `Playground.confirm_hit` from all four places damage is applied: the arena's `_on_damage` (a player hit by a player, never their own blast), an NPC's `take_damage`, `hurt_prop` and `hurt_pane`; only for a player, on the authority, for health actually taken (capped at what was left). The victim travels as its `DotEntity` kind and the low 32 bits of a serial, which only groups numbers on one body. Offline the client hears `hit_landed` from its own world. The HUD's marker and numbers are drawn from this, never from the local rig's prediction ([client.md](client.md#the-hud)).

## The request enum is full

`Ask` is four bits and `ARM_PROP` is the sixteenth and last kind. Anything new is a **sub-kind after ARM_PROP's id** (the tool gun's settings, the NPC weapon choice, dropping a weapon, `ARM_BUILDS`, `ARM_LOAD_BUILD`), the way INVENTORY carries its own; a body with nothing after the id is the plain ARM_PROP an older server reads.

## Wire compatibility

- New event kinds are **appended** (`PANE`, `HIT` … last; 24 of the 32 the 5-bit field holds, which `headless_net` checks); an older client refuses an unknown kind.
- New fields are **appended** to a message body and read only if present (JOIN's three avatar bytes after the style, each kit index + 1, 0 = stock).
- Nothing on the wire or in an `@rpc` set changes without saying whether the client shell needs a rebuild; a pack cannot load a script naming a class the shell does not have.

## No message preloads itself

`playground_event.gd` and `playground_request.gd` are built with `new(kind, body)` (an `_init` whose arguments default, because dot-net's registry decodes with a bare `new()`), never a typed `of()` factory that preloads its own script. A script naming itself is the family's exit-leak hazard ([gdscript-hazards.md](../../../docs/gdscript-hazards.md)). `dedicated`'s **exiting clean** reads every `DotNetMessage` script under `game/` as text and fails on a self-preload, and runs itself in a fresh process to assert nothing is alive at exit: the leak is printed after `quit()`, where no assertion reaches.

## Interpolation

dot-net's interpolator converts its delay from snapshots to ticks; it once subtracted a buffer counted in snapshots from a tick timeline, so every remote entity in the family was extrapolated. `tools/screenshot_net.sh` (a connected client watching another player, with a per-frame movement probe) is what found it; `--walk` probes the local player's key-to-motion and eye speed, `--hold` and `--zee=<id>` render a carried crate and a held gun.

## The map's toys

Each toy is an entity (`PlaygroundToyNet`: `state_transform`, `on`, `count`), registered by the server when the map is ready and named in a TOYS event (the map's id, then the net ids in toy order), which a joiner is told after HELLO. Both ends build the toys in the same order from the map, so a client pairs them by index alone. **A client registers a mirror for every id the moment TOYS arrives** (under `ToyMirrors`) and hands each its toy by index once its own toys for that map exist (`Playground.toys_built`): dot-net stops reading a snapshot at the first entity a client does not know, so a mirror missing while the client loads the map froze every entity after it. Released entities are taken out of the tree at once, not at the frame's end: a new identity on the same toy collects every behaviour under it in its `_ready`, and found the old one freed in the middle of the next snapshot. A client's toys are frozen and posed; the roundabout's spin is measured from the poses (dot-props), which is what carries the client's own predicted player standing on it.

## A READY before the seat

**A READY before the player is seated is kept** (`_ready_unseated` in the bridge; `_on_request` hands READY to `_admit` before its seat check) and answered by `add_player`: over ENet with loss it overtakes the link's `loaded`, and a dropped READY left the client waiting for ever. `headless_net` sends it first (armed). [history](history.md)
