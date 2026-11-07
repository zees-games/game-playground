extends "res://game/playground_module_handlers.gd"

## What a server browser is told about this sandbox: the GAME part of a DQP/A2S query.
##
## `pg_arena`, `pg_waves` and `pg_shop` each make a different server and default to off (an
## operator's decision), so a list row must say which, not just that the game is Playground.
func _build_query_provider() -> void:
	var provider := PlaygroundQueryProvider.new()
	provider.module = self

	# DEBUG, not ERROR: a server with neither query protocol enabled is a legitimate
	# deployment and this game's own suite runs one.
	DotLog.result(
		CHANNEL, "the query provider", add_query_provider(provider), DotLog.Level.DEBUG
	)


## Tells dot-server which map is running, so A2S, DQP and the backbone report print it rather than the
## game's content id. On every change, through the session's own signal.
func _report_map(map: DotMapDef, _world: Node = null) -> void:
	if map_config == null and console != null:
		map_config = PlaygroundMapConfig.build(console)
	if map_config != null and map != null:
		var _applied := map_config.apply(String(map.id))
	if server != null and server.games != null:
		server.games.set_current_map(String(map.id) if map != null else "")


## The loading roster and the handler for the client's cover report, a kind on dot-server's envelope
## (the RPC set is frozen). An older client is released by the roster's timeout.
func _build_loading() -> void:
	loading = DotGameRoster.new()
	loading.server = server

	if arena != null:
		arena.loading_fn = func(key: StringName) -> bool:
			return loading != null and loading.is_loading(String(key).trim_prefix("u").to_int())

	if server == null or not ("envelope" in server):
		return

	var env: Object = server.get(&"envelope")

	if env != null and env.has_method("register"):
		env.call("register", DotGameRoster.COVER_KIND, Callable(self, "_on_cover_report"), false)
		_handles_cover = true


func _on_cover_report(peer_id: int, payload: Dictionary) -> void:
	var covered: Variant = payload.get("covered")

	if loading != null and covered is bool:
		loading.report_cover(peer_id, covered)


## Resolves who a session is and what they wear, through dot-platform. Does what DotGameModule does:
## build `DotPlatformIdentity` with the avatar schema, a stock look and the site translation, then
## load dot-platform's module (an already-loaded one is used as is).
func _build_identity() -> DotResult:
	if bridge != null:
		bridge.skin_fn = _skins_for
		hook_post("player_admitted", _on_profile)
		hook_post("player_avatar_changed", _on_profile)

	if server == null or server.modules == null or server.modules.has_module("platform"):
		return DotResult.success(null)

	_identity = DotPlatformIdentity.new()
	_identity.name = "Identity"
	_identity.avatar_schema = PlaygroundAvatars.schema()
	_identity.stock_avatar_fn = PlaygroundAvatars.stock_avatar
	_identity.avatar_translate_fn = PlaygroundAvatars.from_site
	add_child(_identity)

	var ready: Variant = await _identity.setup()

	if not (ready is DotResult) or not (ready as DotResult).ok:
		_identity.queue_free()
		_identity = null
		return ready if ready is DotResult else DotResult.fail(DotError.CODE_INTERNAL, "no result from setup()")

	var loaded: DotResult = await server.modules.load_module("res://addons/dot_platform/dot_platform_module.gd")
	_loaded_platform = loaded.ok
	return loaded


## What a session wears: their avatar's skins, or empty for the stock look.
func _skins_for(session_id: int) -> PackedInt32Array:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session == null or platform == null or not platform.has_method("player_for"):
		return PackedInt32Array()

	var player: Variant = platform.call("player_for", session)
	var avatar: Variant = (player as Object).get("avatar") if player is Object else null
	var skins := PlaygroundAvatars.skins_of(avatar as DotAvatar if avatar is DotAvatar else null)

	return PackedInt32Array() if skins == PackedInt32Array([-1, -1, -1]) else skins


## A profile resolved or an avatar changed after the join: dress them and say so.
func _on_profile(event: DotEvent) -> void:
	if bridge != null and event != null:
		bridge.refresh_skins(event.get_int("userid"))


## The Tab board's stats columns from this game's own tracker. Not on DotGameModule, so the
## feed and board are built here and handed to dot-server by hand; the client wires itself.
func _attach_stats_board() -> void:
	if server == null or not ("scoreboard_fields" in server) or DotAddonApi.build_level("dot_game") < 38:
		return
	_board_feed = DotGameStatsFeed.new()
	_board_feed.tracker = progress.stats
	_board_feed.open_sessions = false
	_board_feed.player_key_fn = func(session: DotClientSession) -> String:
		return PlaygroundPlatform.key_for_session(server, session)
	# An unfollowed roster: no store, so no lifetime baseline to wait for.
	var board := DotGameStatsBoard.attach(_board_feed, DotGameRoster.new())
	server.set(&"scoreboard_fields", func(session: Object) -> Dictionary:
		return board.fields(session as DotClientSession) if session is DotClientSession else {})
	server.set(&"scoreboard_extra", func() -> Dictionary: return board.extra())


func _module_unload() -> void:
	if progress != null:
		DotRegistry.unregister_instance(DotGameStatsFeed.SERVICE, progress.stats)
	if _board_feed != null and server != null and "scoreboard_fields" in server:
		server.set(&"scoreboard_fields", Callable())
		server.set(&"scoreboard_extra", Callable())
	_board_feed = null
	if map_config != null:
		map_config.restore()
		map_config = null
	if workbench != null:
		workbench.queue_free()
		workbench = null
	if game != null:
		game.block_rules = null
	noblock = null
	if _handles_cover and server != null:
		var env: Object = server.get(&"envelope")

		if env != null and env.has_method("handle"):
			env.call("handle", DotGameRoster.COVER_KIND, Callable())

		_handles_cover = false

	if arena != null:
		arena.loading_fn = Callable()

	if loading != null:
		loading.clear()
		loading = null

	if _loaded_platform and server != null and server.modules != null and server.modules.has_module("platform"):
		server.modules.unload_module("platform")
	_loaded_platform = false

	if server != null and server.client_disconnected.is_connected(_on_client_disconnected):
		server.client_disconnected.disconnect(_on_client_disconnected)

	if game != null and is_instance_valid(game):
		if game.maps.map_over.is_connected(_on_map_over):
			game.maps.map_over.disconnect(_on_map_over)
		if game.run_filed.is_connected(_on_run_filed):
			game.run_filed.disconnect(_on_run_filed)
		if game.maps.changed.is_connected(_on_map_changed_for_mod_tools):
			game.maps.changed.disconnect(_on_map_changed_for_mod_tools)
		if game.maps.changed.is_connected(_on_map_changed_for_map_edit):
			game.maps.changed.disconnect(_on_map_changed_for_map_edit)
		if game.map_edit == map_edit:
			game.map_edit = null
			game.map_edit_allowed_fn = Callable()
		if game.maps.changed.is_connected(_report_map):
			game.maps.changed.disconnect(_report_map)

		# Every player this module put in comes back out, or a later record is attributed to a ghost.
		for id in game.players.keys():
			game.remove_player(id)



## An armed NPC's shot and lava hurt through the arena, which refuses while it is off (`pg_arena 1`
## makes the soldiers dangerous; off, lava sends the player to the spawn). A kill pays the shop.
func _wire_arena_hooks() -> void:
	game.arena_hurt = func(attacker: StringName, victim: StringName, amount: float, distance: float) -> void:
		var _hurt := arena.hurt(attacker, victim, amount, distance)
	game.hazard_hurt = func(victim: StringName, amount: float) -> bool:
		return arena.enabled and arena.hurt(&"", victim, amount, 0.0) != null
	arena.player_killed.connect(func(victim: StringName, killer: StringName) -> void:
		shop.on_arena_kill(killer, victim)
		var player: PlaygroundPlayer = game.players.get(victim, null)
		var at := player.controller.state.position if player != null else Vector3.ZERO
		spectate.on_death(victim, at, killer)
	)


## Everything that is not the netcode, in the order each needs the last (the services register a mute
## source the chat router wants). Nothing suspends: load_module does not await `_module_load`.
func _build_extras() -> DotResult:
	services = PlaygroundServices.new()
	services.name = "Services"
	services.bridge = bridge
	services.punishments_path = punishments_path
	add_child(services)

	# [DotGameServices]' sequence: moderation, chat, the relay, voice. The bridge is the
	# link, because it is what carries a CHAT event; voice rides the bridge's own link.
	var serviced: DotResult = services.setup(server, game, bridge)

	if not serviced.ok:
		return serviced.wrap("The services could not be set up")

	# sv_voice_enable and sv_voice_mode: enforced on the router, replicated so a client hides
	# its key. On this module, so they go when it unloads.
	if services.voice != null and services.voice.has_method(&"bind_cvars"):
		var _voice_cvars: Variant = services.voice.call(&"bind_cvars", add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

	bridge.say_requested.connect(_on_say_requested)
	bridge.voice_requested.connect(_on_voice_requested)
	bridge.vote_requested.connect(_on_vote_requested)
	bridge.loadout_requested.connect(_on_loadout_requested)
	bridge.builds_requested.connect(_on_builds_requested)
	bridge.build_load_requested.connect(_on_build_load_requested)
	bridge.peer_admitted.connect(_on_peer_admitted)
	services.command_entered.connect(_on_chat_command)
	services.chat.message_accepted.connect(_on_chat_accepted)

	arena = PlaygroundArena.new()
	arena.name = "Arena"
	add_child(arena)

	var fought := arena.setup(game)

	if not fought.ok:
		return fought.wrap("The arena could not be set up")

	_build_loading()

	arena.health_changed.connect(_on_health_changed)
	arena.player_killed.connect(_on_player_killed)
	arena.damage_landed.connect(func(attacker: StringName, victim: StringName, damage: DotDamage) -> void:
		if progress != null:
			progress.report_hit(attacker, victim, damage)
	)

	_wire_arena_hooks()
	arena.clock_changed.connect(bridge.broadcast_match)
	_build_loadout_command()

	_build_mod_tools()
	_build_map_edit()

	waves = PlaygroundWaves.new()
	waves.name = "Waves"
	add_child(waves)

	# A real server keeps what its wave NPCs learn of each map across restarts. Set here
	# and not in the waves, because every suite builds waves and only a server loads this.
	waves.heat.persist = true

	var waved := waves.setup(game)

	if not waved.ok:
		return waved.wrap("The waves could not be set up")

	# Every wave NPC to every client. They were never replicated: a connected player was
	# hunted by a wave they could not see.
	if bridge != null:
		bridge.watch_npc_spawner(waves.spawner, PlaygroundWaves.shared_catalogue())

	# A grenade in the air is a danger the waves get out from under, on their own clock.
	if game.projectiles != null:
		game.projectiles.add_board(waves.sounds, waves.spawner.now)

	# The director paces against real health when the arena is on, and against proximity
	# alone when it is not. One callable rather than two code paths.
	# Something the director sent has died, and somebody killed it. The wave mode is
	# what makes a price list worth having: a wave pays, a jeep costs, and a player who
	# spent everything on turrets has to earn the next one.
	waves.spawner.died.connect(func(_npc: DotNpcInstance, by: StringName) -> void:
		shop.on_wave_kill(by))

	waves.health_fn = func(id: StringName) -> float:
		var health := arena.health_of(id)
		return health.fraction() if health != null else 1.0

	shop = PlaygroundShop.new()
	shop.name = "Shop"
	add_child(shop)

	var priced := shop.setup(game)

	if not priced.ok:
		return priced.wrap("The shop could not be set up")

	# The bridge charges through this and knows nothing about prices. Unset it and
	# everything is free, which is what this game was before there was a price list.
	bridge.charge_fn = shop.charge
	# Asked before a spawn, which is charged only once it exists. See _spawn_for.
	bridge.may_charge_fn = shop.may_have
	# A zee weapon's shot reaches dot-combat through this and nothing else.
	bridge.shot_fn = _resolve_shot

	spectate = PlaygroundSpectate.new()
	spectate.name = "Spectate"
	add_child(spectate)

	var watching := spectate.bind(game)

	if not watching.ok:
		return watching.wrap("Spectating could not be set up")

	spectate.arena = arena

	# And the spawn director, which needs it for the protection window: a sandbox has
	# nothing to be protected from and the arena's own match rules carry how long.
	if game.player_stack != null:
		game.player_stack.arena = arena
		game.player_stack.refresh_spawn_rules()

	downs = PlaygroundDowns.new()
	downs.name = "Downs"
	add_child(downs)

	var dropped := downs.setup(game)

	if not dropped.ok:
		return dropped.wrap("Incapacitation could not be set up")

	downs.arena = arena

	# The arena asks and the downs layer answers, so the rule lives in one place. Unset
	# it and everybody dies, which is what a deathmatch is.
	arena.death_rule_fn = downs.report_zero_health

	# A downed player who bleeds out is a death the scoreboard and respawn queue still have to hear about.
	downs.died.connect(func(player_id: StringName, _reason: StringName) -> void:
		if arena.enabled and player_id != &"":
			arena.match_node.report_kill("", String(player_id), &"bleed_out", game.current_tick())
			# A death like any other from here on, which it was not: nothing told a client a
			# downed player had bled out. They crumple where they lay.
			var fallen: PlaygroundPlayer = game.players.get(player_id, null)
			if fallen != null:
				fallen.death = arena.decide_death(player_id, null, DotPlayerDeathReactions.CRUMPLE)
			arena.player_killed.emit(player_id, &"")
	)

	downs.revived.connect(func(player_id: StringName, _by: StringName, health: float) -> void:
		var record := arena.health_of(player_id)
		if record != null:
			record.revive(clampf(health / game.config.arena_health, 0.05, 1.0))
	)

	# Being killed by a wave is what being downed is for, so the two switch together (no separate cvar).
	downs.set_enabled(waves.is_enabled())

	progress = PlaygroundProgress.new()
	progress.name = "Progress"
	progress.backbone = null
	progress.key_for = _stats_key_for
	add_child(progress)

	var earned := progress.setup(game)

	if not earned.ok:
		return earned.wrap("Progress could not be set up")

	progress.earned.connect(_on_earned)
	_attach_stats_board()
	# The registered tracker is what DotGameStatsReport's default apply flips.
	DotRegistry.register(DotGameStatsFeed.SERVICE, progress.stats)
	var _report := DotGameStatsReport.bind(self)

	vote = PlaygroundVote.new()
	vote.name = "Vote"
	vote.player_count_fn = func() -> int: return game.players.size()
	vote.commands_spec_fn = game.rotation_commands
	vote.is_admin_fn = _voter_is_admin

	# The drawn ballot, to each playing session with its own voter id (`u<userid>`), so the
	# client shell marks the player's own choice. Topic `map_ballot`, beside a server's
	# `game_ballot` when both votes are open at once.
	vote.ballot_fn = func(state: Dictionary) -> void:
		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = "u%d" % session.userid
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), MAP_BALLOT_TOPIC, data
			))

	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).trim_prefix("u").to_int())

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}

	add_child(vote)

	vote.game = game
	var voted := vote.setup()

	if not voted.ok:
		return voted.wrap("The vote could not be set up")

	vote.change_due.connect(_on_vote_change_due)

	# Both map clocks follow the server's hibernation: they wait while nobody is here and restart when
	# somebody joins. With `sv_hibernate_when_empty 0`, dot-vote's `empty_choice` changes the map instead.
	if vote.director != null:
		vote.director.follow_hibernation(server)
	if game.maps != null:
		game.maps.follow_hibernation(server)
	vote.announced.connect(_on_vote_announced)

	# The cues and the countdown, to every client. The ballot goes out as chat through
	# `announced`; a sound and a number a HUD counts are what chat cannot carry.
	vote.cue_due.connect(func(cue: StringName, seconds_left: int, runoff: bool) -> void:
		if bridge != null:
			bridge.broadcast_vote_cue(cue, seconds_left, runoff)
	)

	# The time left, from the clock that ends the map. The HUD drew the map session's,
	# which on a client is a clock nobody extends; see `DotVoteClockView`.
	vote.clock_due.connect(func(state: Dictionary) -> void:
		if bridge != null:
			bridge.broadcast_clock(state)
	)

	if bridge != null:
		bridge.clock_fn = vote.clock_state

	# [b]One clock that ends a map, and it is the vote's.[/b] See
	# `Playground.rotation_ends_maps`.
	game.rotation_ends_maps = false

	# And the clock `pg_status` reports, for the same reason: the session's is no longer
	# the one that ends the map.
	game.clock_fn = vote.clock_state

	var commanded := vote.install_commands(self)
	DotLog.result(CHANNEL, "the vote's commands", commanded)

	# The map menu (M), dot-vote's: a holder of `sv_map_menu_flag` changes the map now through the game's
	# own change, anybody else gets a vote. Read by name: an older dot-vote has no `map_menu`.
	var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
	if menu_half is Object:
		(menu_half as Object).set(&"change_fn", game.change_map)

	# The one signal that fires for every change however it happened (a console `pg_map`, the time
	# limit, the vote), so the only connection: two would double the play history entries.
	game.maps.changed.connect(func(map: DotMapDef, _world: Node) -> void:
		vote.note_playing(map.id)
	)

	if game.maps.current != null:
		vote.note_playing(game.maps.current.id)

	return DotResult.success(null)


# --- Chat, voice and votes -------------------------------------------------

func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = Playground.snapshot_rate_for(game.tick_rate)
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 0
	config.world_extent = 512.0
	net.config = config
	add_child(net)

	var ready_result := net.setup()

	if not ready_result.ok:
		return ready_result.wrap("The netcode could not start")

	bridge = PlaygroundNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	# `server` is the node the link mirrors: a client's DotClientLink is named to match,
	# and the name IS the RPC routing.
	var attached := bridge.attach(game, net, server)

	if not attached.ok:
		return attached

	# A bag belongs to the person, and dot-server's userid is a new number every time
	# somebody connects. See `_bag_key_for`.
	bridge.inventory_key_fn = _bag_key_for
	_bind_profile_edit()

	# Avatar actions: the relay, and the loadouts the join/leave handlers below tell.
	var avatar := DotGameAvatarActionRelay.serve(net, self, server)
	if not avatar.ok:
		log_warn("avatar actions not served", {"why": avatar.error.message})
	# The remote workbench's frame, after the avatar one on both ends.
	DotLog.result(CHANNEL, "remote workbench message", DotGameWorkbenchRemote.serve(net))

	net.messages.seal()
	# Off until the owner sets sv_workbench_remote 1; then flagged admins edit from a client.
	if workbench != null and workbench.api != null:
		var _served := workbench.serve_remote(net)
	# [b]A client whose game messages cannot work with this server's is dropped, in words.[/b]
	# dot-net compares the two schema tables and refuses a pair where either lacks a type
	# the other REQUIRES, but it owns no socket and can only say so; this is the socket.
	# The same line DotGameNetcode.refuse_peer is for games built on dot-game.
	net.peer_schema_refused.connect(_refuse_peer)
	return net.start()


## Admins edit profiles live: the permission is dot-server's admin flags by account uid, the server
## console edits as the process itself. Before the types seal.
func _bind_profile_edit() -> void:
	var rt := game.profiles.runtime
	rt.permit = func(actor: Variant, flag: String) -> bool:
		if typeof(actor) == TYPE_STRING_NAME and actor == PlaygroundProfiles.LOCAL_ACTOR:
			return true
		return server != null and server.admins != null and actor is String \
			and server.admins.uid_has_permission(actor, flag)
	rt.actor_name = func(actor: Variant) -> String:
		return String(actor) if actor is StringName else str(actor)
	_start_workbench(rt)
	add_command("workbench", func(ctx: DotCmdContext) -> void: ctx.reply_lines(_workbench_lines()),
		"Show the admin workbench's state", DotAdminFlags.CVAR)
	profile_link = DotNetProfileLink.attach(net, rt)
	if profile_link == null:
		return
	profile_link.local_actor = PlaygroundProfiles.LOCAL_ACTOR
	profile_link.actor_of = func(peer: int) -> Variant:
		var session := server.session_of(peer) if server != null else null
		return session.uid() if session != null else ""
	add_command("profile_edit", func(ctx: DotCmdContext) -> void:
		var req := DotConsoleProfileEdit.parse(ctx.args)
		if not req.ok:
			ctx.reply(req.error.message)
			return
		var res := profile_link.submit(req.value)
		ctx.reply("ok" if res.ok else "refused: " + res.error.message),
		"Edit an NPC or weapon profile live: " + DotConsoleProfileEdit.USAGE, DotAdminFlags.CVAR)


## dot-workbench over the profiles and the config: the F9 panel off a dedicated server, the HTTP page only with `workbench.enabled` in cfg/server.yml.
func _start_workbench(rt: DotProfileRuntime) -> void:
	workbench = DotGameWorkbench.new()
	workbench.name = "Workbench"
	workbench.dedicated = DisplayServer.get_name() == "headless"
	workbench.listen_host_fn = func() -> bool: return DisplayServer.get_name() != "headless"
	var admin_permit := Callable()
	if server != null and server.admins != null:
		admin_permit = server.admins.uid_has_permission
	workbench.permit_fn = func(actor: Variant, flag: String) -> bool:
		return admin_permit.is_valid() and actor is String and bool(admin_permit.call(actor, flag))
	workbench.add_set(game.profiles.npcs, "NPCs")
	workbench.add_set(game.profiles.weapons, "Weapons")
	for set: DotProfileSet in game.config_binder.profile_sets():
		workbench.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var ambient_set := DotGameWorkbench.cvar_set(console, PlaygroundAmbience.cvar_types(), AMBIENT_KIND)
	if ambient_set != null:
		workbench.add_set(ambient_set, "Ambience (pg_ambient*)")
	add_child(workbench)
	var started := workbench.start(rt)
	if not started.ok:
		DotLog.result(CHANNEL, "the workbench", started)
		return
	game.config_binder.attach(rt)
	if ambient_set != null:
		var _applied := DotGameWorkbench.bind_cvar_set(ambient_set, rt, console)


func _workbench_lines() -> PackedStringArray:
	if workbench == null:
		return PackedStringArray(["workbench    off"])
	if workbench.running_http:
		return PackedStringArray(["workbench    http " + JSON.stringify(workbench.http.call("describe"))])
	return PackedStringArray(["workbench    off (workbench.enabled in cfg/server.yml)"])


## dot-team's block rules through dot-game's [DotGameNoblock]: `mp_teamblock` (0) and `mp_enemyblock` (1), `!block` and `!noblock`. A sandbox has no sides, so everybody is an enemy and blocks until they ask to pass.
func _bind_noblock() -> DotResult:
	if not DotGameNoblock.available():
		DotLog.warn(CHANNEL, "dot-team is not in this build: players block each other")
		return DotResult.success(null)
	var made := DotGameNoblock.create("game-playground", Callable(game, "team_of_side"))
	if not made.ok:
		return made
	var built: DotGameNoblock = made.value
	var bound := built.bind(add_cvar, self, game.profiles.runtime)
	if not bound.ok:
		return bound.wrap("noblock")
	built.feed(game.body_rules)
	game.block_rules = built.rules
	if built.commands != null:
		built.commands.set(&"key_fn", func(ctx: Object) -> Variant:
			var session: Variant = ctx.get("session")
			return StringName("u%d" % int(session.get("userid"))) if session is Object else null)
	noblock = built
	return DotResult.success(built)


## Every [PlaygroundConfig] field as a `pg_<field>` cvar, for the ones with no hand-written cvar.
func _bind_config() -> void:
	# pg_creative and pg_prop_surf are the hand-written cvars of these two fields.
	var hand := PackedStringArray(["pg_allow_creative", "pg_prop_surfing"])
	_mirror_hand_cvars()
	game.config_binder.field_changed.connect(func(key: String, _value: Variant, _source: String) -> void:
		if key in ["move_speed", "jump_height", "move_gravity"]:
			game.apply_movement())
	game.config_binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE, func(name: String) -> bool:
		return hand.has(name) or console.has_name(name))
	game.config_binder.bind_commands(add_command)


## Config field -> the hand-written cvar that carries it. The binder skips these (its own `pg_<field>` name is
## either taken or reserved), so a workbench edit reached the field and never the cvar, and a handler with
## a side effect (`pg_creative` ending everybody's creative mode) never ran.
const HAND_CVARS := {
	"allow_creative": "pg_creative",
	"prop_surfing": "pg_prop_surf",
	"destruction": "pg_destruction",
	"breakable_glass": "pg_breakable_glass",
}


## Pushes a workbench edit of a [constant HAND_CVARS] field into its cvar, whose change handler writes the field and does the rest.
func _mirror_hand_cvars() -> void:
	game.config_binder.field_changed.connect(func(key: String, value: Variant, source: String) -> void:
		if source != "workbench" or not HAND_CVARS.has(key):
			return
		var c: DotConVar = console.find_cvar(HAND_CVARS[key]) if console != null else null
		if c != null:
			c.force_set("1" if value else "0"))


