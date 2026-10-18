# Services: chat, voice, moderation, stats, the vote, identity, the browser

## Chat: dot-chat's, and exactly one path

`DotChatRouter` has the rules: four channels, one a **radius** (near), a backlog for a joiner, `/me`, and a gag that survives a reconnect. `PlaygroundModule` hooks `player_chat` with `hook_pre` and **cancels** it, so dot-server's own broadcast never happens, and turns off dot-server's join and leave lines in the same place. Two paths would be two rule sets, and the one that skipped the filter would leak admin chat. `dedicated` asserts the cancel.

- **An unclaimed `!command` goes into dot-server's console with the player's permissions**, not a second command table (this console surface is the largest in the family; a second table would be the unaudited half).
- **The chat key is the session id, not the account uid.** dot-chat's `key_fn` and dot-moderation's `key_for_peer` answer different questions: a punishment is against a person who will come back; a chat line is attributed to somebody standing here now. Two guests behind one device id share a uid.

## `PlaygroundServices` is a `DotGameServices` subclass

The sequence (moderation first because it publishes `dot_mute_source`, then chat, the website relay, voice) is dot-game's. What the subclass keeps that the base would do differently:

- **The bridge is who is in the game.** `_chat_peers` is `bridge.ready_peers()`, not dot-server's playing sessions (a peer is playing before its client has built the node a CHAT event lands on). `_key_of` is the bridge's player id; `_subject_for_peer` falls back to `local:<player id>` with no session. Those three let the real sequence run with no `DotServer`.
- **`_send_chat` stamps `x.p`**, the one meta field this wire carries. `_send_voice` goes through `bridge.link`, because the bridge has no voice method, and holds frames for peers not yet READY ([netcode.md](netcode.md#a-broadcast-reaches-ready-peers-only-pg-rpc-before-scene)).
- **`_peer_can_receive` is false.** The backlog is `PlaygroundModule._welcome`'s, sent once the peer is admitted; the base would also send one from `add_peer`, and a joiner would get it twice.
- **`mod_tools_enabled` is forced off.** The live tools stay the module's (`PlaygroundModTools` needs the arena's health, built after the services); a second set would bind the same command names.
- The channels, rules and voice format are **statics** a client reads. Callers type the element (`for channel: DotChatChannel in …`): a script whose base class lives in the host build cannot hand its return type to a script in a mounted pack.
- A moderation or voice layer that fails to build is logged rather than fatal (the base's judgement).

## Voice is the whole server; the near channel is text's

A sandbox is a room and an arena at once (people build in one corner and run the course in another), so text has a near channel and voice does not: a builder shouting for a hand should be heard, and somebody reading should be able to stop reading the shouting. One `unreliable` RPC on its own channel serves a UDP desktop client and a TCP browser one; push-to-talk closes when a screen takes the keyboard; playback goes into a **buffer** when there is no audio device, which makes the receiving half checkable.

## The moderator's live tools

`PlaygroundModTools` is built in the module, because health belongs to the arena layer. Noclip, freeze, speed and gravity are predicted modifiers; god, buddha, hp and slay act on the arena's `DotHealth` and say "the arena is off" when it is; slap shoves either way; respawn is the spawn; teleports end a run when there is a run timer.

**An admin's help can never make a time.** Noclip abandons the run it interrupts, `PlaygroundPlayer` taints every run while noclip, a speed step or a gravity step is on, and a slap taints the run it lands in. Give and strip are refused, so there is no admin's weapon to taint a run with.

**Blind and beacon are per-player state, not events**: `PlaygroundPlayer.blinded` and `.beacon`, replicated by `PlaygroundPlayerNet`, so a joiner and a lost snapshot are corrected by the next snapshot. `net_blind` is **owner-only** (with the arena on, an opponent who could read it would know when somebody cannot see); `net_beacon` goes to everybody. **No relevance change for the beacon**: every player is already `always_relevant` (`PlaygroundNetBridge._build_entity`), and a beacon that turned relevance off when lifted would cut the player out of everybody's world. The client draws both: `PlaygroundHud.blind_overlay` (a near-black rect under the HUD's widgets, sized to the viewport) and `DotFxBeacon` (dot-fx) via `PlaygroundClient._present_beacons` (a ring, a ripple a second with `PlaygroundPresentation.BEACON_SOUND`, a column through walls, not in your own first-person view). The server calls nothing that draws. Neither taints a run: a blinded run is harder, not assisted. Both survive a respawn ([simulation.md](simulation.md#teleport-and-the-spawn-yaw)).

## Statistics and achievements

dot-stats and dot-achievements sit beside the leaderboards (whose run boards are the timer's, when a server has one). Every stat is recorded from a signal the game already fires (a second count is a second number that can disagree), and `DotAchievementStatsLink` is a signal connection, not twenty call sites. `dedicated` checks that **every stat an achievement watches is declared**: one watching an unreported stat never unlocks and nothing errors. `dedicated` wipes the player's stored achievement progress (`user://`) before it runs, because a suite whose result depends on how many times it has been run is not a suite.

## The vote

dot-vote replaced half a rock-the-vote: `DotMapTimeLimit` counts and fires but cannot offer a ballot, take nominations, break a tie, respect a cooldown or extend. The time limit is the clock under dot-vote, and the source is `DotVoteMapSource` over the game's `DotMapSession`.

- Set **explicitly**, not left: `extend_needs_majority`, `nomination_seconding` (without it every nomination count is 1 and `MOST_NOMINATED` does nothing), and `begin_on_apply` (the host's `DotMapSession.changed` fires for every change however it happened, so it is the only connection; both announcing halves every cooldown).
- **`self_advance` is off; the module advances the director once a tick.** With both, every vote clock ran at double speed and every number agreed with every other. `dedicated` asserts the director is not processing itself.
- `PlaygroundVote.install_commands` puts `DotVoteCommands` on the module, and `pg_rtv`, `pg_extend` and `pg_nextmap` answer from the ballot when there is one (they once went to the map session's own rock-the-vote: two votes under one name).
- **`Playground.rotation_ends_maps` is off once the module has a ballot**, or the session's clock changes the map after players voted to extend.
- **The clock clients see is the vote's.** `PlaygroundVote.advance` keeps a `DotVoteClockView` and emits `clock_due` only when it goes stale (extend, new map, stopped); the module sends `PlaygroundEvents.Kind.CLOCK`, `PlaygroundNetBridge.clock_fn` tells a joiner. The HUD counts down between messages and **draws no clock when the vote has none**; offline the local session is the real clock.
- **`pg_status` and `describe()` read the vote's clock too** (`Playground.clock_fn = vote.clock_state`): `m:ss`, `(stopped)` while a ballot holds it, `no limit` with none. Words where the HUD drops the slot, because a status line is read when somebody asks.
- Ballot cues go to clients as `Kind.VOTE` (`write_vote_cue`; `write_vote` is a player's token going the other way) and play on voices nothing else uses.
- **The ballot is drawn by the client shell.** The vote wrapper owns a `DotVoteBallotFeed` and polls it every `advance`; the module points `ballot_fn` at `server.send_notice`, one copy per playing session with that session's voter id, topic `map_ballot`. dot-server-deploy's shell draws it (`DotBallotPanel`); a click goes back as a `!vote`-style command. Standalone, chat carries the ballot.
- **The deployed sandbox runs until it is voted out**: its `game.yml` sets `map_vote: {trigger: rtv_only, duration_sec: 0}` beside `pg_map_seconds: "0"`. Stopping only the map clock once put the game to a ballot at twenty-eight minutes; dot-server-deploy's selftest now fails a game that stops one and not the other.

## Hibernation

The module follows the server's hibernation with both map clocks (`vote.director.follow_hibernation(server)`, `game.maps.follow_hibernation(server)`): an empty server idles from boot and its clocks restart when somebody joins. With hibernation off, dot-vote's `empty_choice` changes the map when the limit runs out on nobody; `on_no_votes` decides a ballot nobody voted in. The module wires this only because it is not a `DotGameModule`, which does it itself.

## Identity: dot-platform

`PlaygroundModule._build_identity` builds `DotPlatformIdentity` with this game's avatar schema (`pg_people`, [client.md](client.md#people-are-drawn-as-people)) and loads dot-platform's module, unless a platform module is already loaded (the dedicated example loads `DotPlatformModule` itself), and unloads it again if it loaded it. `DotGameModule` would do this; this module is not one. `PlaygroundNetBridge.skin_fn` is asked as a player is added, before their JOIN, and `refresh_skins` re-sends JOIN when `player_admitted` or `player_avatar_changed` says the avatar arrived later.

**The reason a sandbox needs identity is dot-stats.** A statistic is filed under a key and dot-stats refuses an account id, so the scoped pseudonymous id dot-user derives keys boards, achievements, bags and saved builds. `PlaygroundPlatform.key_for_session` is the one function that decides; without an identity stack it files under something that lasts as long as the session, which is honest. **Name changes are off** here: a name that can change is a record whose owner cannot be recognised.

## The server browser's server half

`PlaygroundQueryProvider` (an inner class of `playground_module.gd`) contributes to the query host. **The interesting part of a sandbox's listing row is which of `pg_arena`, `pg_waves` and `pg_shop` are on**, because each turns this into a different server; the map, occupancy, prop count and tick rate go beside them. The prop count is the spawner's own `world_count()` and the player count the module's `_joined`, asserted as such: a row built from a second tally is a second number that can disagree. (The browser shipped for a while against a server that answered nothing: `dedicated` had `query_enabled = false`.)

`PlaygroundBrowser`, the client half, starts from history and typed addresses. With a site configured (`--browser-backbone-url=<origin>` or `DOT_BROWSER_BACKBONE_URL`) it also reads the site's listing of this game's servers (`DotBrowserSourceBackbone`, app `playground`, website-city's `/api/content/server/list`), addresses only; without one nothing reaches out to a website.

**Timer records (with dot-timer linked, [timer.md](timer.md)) are keyed by the account, not the connection.** The in-match id stays `u<userid>`, but dot-server's userid is a sequential counter that restarts with the server, so keying records by it split one player into several runners and handed a stranger an old record. `PlaygroundModule._record_key_for` gives `session.uid()` (a guest's is per device); `Playground.record_key(id)` and `match_id(key)` translate at the timer boundary, and the timer store, the `fastest`, `top_speed` and `points` boards and the checkpoints use the account uid. A seat with no identity, or a second concurrent connection of one account, keeps `u<N>` and is unranked. Legacy `u<N>` rows are retired at start (`retire_legacy_records()`): appended to `legacy_records.jsonl` beside the records store (or in `user://`), then wiped; nothing can say which account owned one, so they cannot be migrated. `dedicated` covers it.
