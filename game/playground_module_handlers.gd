extends "res://game/playground_module_cmds.gd"

## The server's tick, which is the whole game's. Driven from here, not the game's loop: it has to run between
## dot-net applying inputs and building the snapshot. `Playground.external_tick` stands the game's loop down.
func _physics_process(_delta: float) -> void:
	if not loaded or bridge == null:
		return

	_tick += 1
	if loading != null:
		loading.poll_loading()
	_follow_npc_lod(waves.spawner if waves != null else null, _delta)
	var _t_bridge_server_tick := DotFrameCost.now()
	bridge.server_tick(_tick)
	DotFrameCost.add(&"mod.bridge_server_tick", _t_bridge_server_tick)

	# [b]After the world has ticked, and that is the ordering that matters.[/b] dot-combat
	# rewinds to resolve a shot and the waves read where everybody is, and both have to
	# work on positions the movement has just produced — a list built before the tick is a
	# list of where everybody WAS, which is the one-tick lag this family has documented
	# three times now.
	var step := 1.0 / float(maxi(game.tick_rate, 1))

	var _t_arena := DotFrameCost.now()
	if arena != null:
		arena.tick(_tick, step)
	DotFrameCost.add(&"mod.arena", _t_arena)

	var _t_shop := DotFrameCost.now()
	if shop != null:
		shop.tick(step)
	DotFrameCost.add(&"mod.shop", _t_shop)

	var _t_spectate := DotFrameCost.now()
	if spectate != null:
		spectate.tick(step)
	DotFrameCost.add(&"mod.spectate", _t_spectate)

	var _t_downs := DotFrameCost.now()
	if downs != null:
		downs.tick(step)
	DotFrameCost.add(&"mod.downs", _t_downs)

	var _t_waves := DotFrameCost.now()
	if waves != null:
		waves.tick(_tick, step)
	DotFrameCost.add(&"mod.waves", _t_waves)

	var _t_vote := DotFrameCost.now()
	if vote != null:
		vote.advance(step)
	DotFrameCost.add(&"mod.vote", _t_vote)


# --- Sessions --------------------------------------------------------------

## A client finished the signon and is in the world. `client_spawn`, not `client_connected` (a socket and
## nothing else); it carries `userid`, NOT `peer_id` (which read as 0 and nobody joined).
func _on_client_spawn(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null or _joined.has(session.userid):
		return

	var id := _player_id(session)

	if game.players.has(id):
		return

	# Through the bridge, not through the game: the bridge is what builds the entity
	# that replicates them and announces the join. game.add_player alone would put a
	# player in the world that no client is ever told about.
	var added := bridge.add_player(
		session.peer_id, session.userid, session.label(), _record_key_for(session)
	)

	if not added.ok:
		log_warn("could not add a player", {
			"userid": session.userid, "error": str(added.error)
		})
		return

	_joined[session.userid] = true

	var loadouts := DotGameAvatarActionRelay.loadouts_of(net)
	if loadouts != null:
		loadouts.add_peer(session.peer_id)

	if loading != null:
		var _seated := loading.add(session)

	# Voice and chat learn about them before anything is sent, so a frame or a line that
	# lands in the same flush as the admission has somewhere to go.
	if services != null:
		services.add_peer(session.peer_id)

	if progress != null:
		progress.begin(_stats_key(session))

	if arena != null and arena.enabled:
		arena.admit(id, session.label())

	# Not welcomed here: on a real join the peer is not ready yet, so [method _welcome]
	# would find nobody to send to. [method _on_peer_admitted] does it when READY lands.

	log_info("player joined the game", {"player": String(id)})


## The bridge has admitted a peer: now they can be told what they missed. `_welcome` must not wait for READY, which a real join never reaches.
func _on_peer_admitted(peer_id: int) -> void:
	var session := server.session_of(peer_id) if server != null else null
	if session == null or not _joined.has(session.userid):
		return
	if profile_link != null:
		profile_link.peer_joined(peer_id)
	_welcome(session)


## What somebody is told once they are in: the backlog, and the clock. After the admission only: earlier lands on a node that does not exist.
func _welcome(session: DotClientSession) -> void:
	if bridge == null or not bridge.peer_is_ready(session.peer_id):
		return

	if services != null:
		# The backlog is computed per peer: a channel with `backlog = 0` (proximity) must not replay a quiet line.
		for line in services.chat.backlog_for(session.peer_id):
			bridge.send_chat(session.peer_id, line)

		services.chat.join_notice(session.peer_id, PlaygroundServices.CHANNEL_ALL)

	# The match clock, once, so a client that joined mid-round is not told `IDLE` until
	# the next second ticks over.
	if arena != null and arena.enabled:
		arena._announce_clock()


## `client_disconnected` emits TWO arguments, the session and a reason: a handler taking one is
## refused by Godot and never runs, so nobody was ever removed. The default keeps it callable
## from anything that emits only the session.
func _build_mod_tools() -> void:
	mod_tools = DotModTools.new()
	mod_tools.name = "ModTools"
	mod_tools.register_service = false
	mod_tools.manager = services.moderation if services != null else null
	mod_tools.immunity_fn = func(id: StringName) -> int:
		var session := server.session_by_userid(String(id).to_int()) if String(id).is_valid_int() else null
		return session.immunity if session != null else 0
	mod_tools.position_fn = func(id: StringName) -> Variant:
		return PlaygroundModTools.position_of(game, id)
	mod_tools.teleport_fn = func(id: StringName, to: Variant) -> void:
		PlaygroundModTools.teleport(game, id, to)

	var table := PlaygroundModTools.handlers(game, arena)
	for action: Variant in table:
		mod_tools.handlers[action] = table[action]

	var refusals := PlaygroundModTools.unsupported()
	for action: Variant in refusals:
		mod_tools.unsupported_reasons[action] = refusals[action]

	add_child(mod_tools)

	# A map change clears everybody's return history (its points are on a freed map); a respawn keeps it.
	game.maps.changed.connect(_on_map_changed_for_mod_tools)

	mod_commands = DotModToolCommands.install(self, mod_tools, server)
	mod_commands.alive_fn = func(id: StringName) -> bool:
		var health := arena.health_of(PlaygroundModTools.key_of(id)) if arena != null else null
		return health == null or health.alive


## Installs the map-edit commands behind the `config` flag and lets the same sessions use the spawn-point tool.
func _build_map_edit() -> void:
	map_edit = PlaygroundMapEdit.make(game) as DotGameMapEdit

	if map_edit == null:
		return

	map_edit.server = server
	DotLog.result(CHANNEL, "binding the map-edit commands", map_edit.bind(self))
	game.map_edit = map_edit
	game.map_edit_allowed_fn = _session_may_edit_map
	game.maps.changed.connect(_on_map_changed_for_map_edit)
	PlaygroundMapEdit.reload_saved(map_edit)


## The working points belong to the map that was running; the new map's saved ones replace them.
func _on_map_changed_for_map_edit(_map: DotMapDef, _world: Node = null) -> void:
	PlaygroundMapEdit.reload_saved(map_edit)


func _on_map_changed_for_mod_tools(_map: DotMapDef, _world: Node) -> void:
	# Every client covers for the new map and says so when it lifts; until it does nobody is
	# harmed, and one that never re-covers is released after the roster's grace.
	if loading != null:
		loading.mark_reloading()

	if mod_tools != null:
		mod_tools.clear_history()


func _on_client_disconnected(session: DotClientSession, _reason: String = "") -> void:
	var id := _player_id(session)

	if loading != null:
		loading.remove(session)

	if mod_tools != null:
		mod_tools.forget(StringName(str(session.userid)))

	# [b]Off the broadcast set first.[/b] Everything below announces something about this
	# person to everybody ELSE, and their socket has already gone.
	if bridge != null:
		bridge.mark_not_ready(session.peer_id)

	if services != null:
		services.chat.leave_notice(session.peer_id, PlaygroundServices.CHANNEL_ALL)
		services.remove_peer(session.peer_id)

	if vote != null and vote.director != null:
		# The vote forgets them, or a rock-the-vote threshold counts a ballot from
		# somebody who has left — which is how a server ends up unable to change at all.
		vote.director.forget_voter(id)

	if arena != null:
		arena.release(id)

	if progress != null:
		progress.end(_stats_key(session))
		_stats_feed.forget(session.userid)

	_joined.erase(session.userid)

	var loadouts := DotGameAvatarActionRelay.loadouts_of(net)
	if loadouts != null:
		loadouts.remove_peer(session.peer_id)

	# The bridge releases the entity, tells every other client, and forgets the peer.
	# Removing them from the game alone would leave a replicated entity pointing at a
	# freed player.
	if bridge != null:
		bridge.remove_player(session.userid)
	else:
		game.remove_player(id)


## The key this seat's records and board rows are filed under: the account's uid, never the session's
## userid (a server-local counter). Without an identity the seat is known by its userid, read as unranked.
func _record_key_for(session: DotClientSession) -> StringName:
	var uid := session.uid()
	if uid == "":
		log_warn("a session has no identity; its runs are not ranked", {"userid": session.userid})
		return &""
	return StringName(uid)


# --- Helpers ---------------------------------------------------------------

func _on_map_over(_map: DotMapDef, reason: StringName) -> void:
	log_info("the map is over", {"reason": String(reason)})


func _on_run_filed(
	player_id: StringName, time: float, rank: int, reason: String
) -> void:
	if reason != "":
		log_info("a run was not recorded", {
			"player": String(player_id), "why": reason
		})
		return

	log_info("a run was recorded", {
		"player": String(player_id), "time": Playground.format_time(time), "rank": rank
	})


## Disconnects a peer whose message schema this server cannot play with, with dot-net's
## sentence as the reason. See `peer_schema_refused` above.
func _refuse_peer(peer_id: int, error: DotError) -> void:
	var session: DotClientSession = server.session_of(peer_id) if server != null else null
	if session != null:
		server.kick(session, error.message, error)


## One zee weapon's shot, on this server. Hurts only while the arena is on.
##
## [b]Asked per shot rather than wired when the arena turns on[/b], because `pg_arena` is a
## cvar flipped at runtime and a callable set at the switch is one more thing the switch
## has to remember to unset. Off, the shot has already shoved whatever prop it hit and
## that is all a gun does in a sandbox.
func _resolve_shot(player_id: StringName, shot: DotShot) -> void:
	# Heard by the wave NPCs first, and whether or not the arena is on.
	if waves != null:
		waves.note_fire(player_id, shot.origin)

	if arena == null or not arena.enabled or arena.combat == null:
		return

	shot.attacker = arena.entity_id_of(player_id)
	shot.tick = game.current_tick()
	var _resolved := arena.combat.resolve_shot(shot)


## The NPC level of detail and sense workers follow the `npc_lod*` cvars (dot-game's DotGameNpcLod; all off by default). This module is a DotModule, so it holds the attachment itself.
var _npc_lod: DotGameNpcLod = null


func _follow_npc_lod(spawner: Object, delta: float) -> void:
	if spawner == null or (server.console if server != null else null) == null:
		return
	if _npc_lod == null or _npc_lod.spawner != spawner:
		if _npc_lod != null:
			_npc_lod.release()
		_npc_lod = DotGameNpcLod.attach(self, (server.console if server != null else null), spawner, server.config if server != null else null)
	if _npc_lod != null:
		_npc_lod.follow(delta)
