extends "res://game/playground_module_cmds.gd"
## Binds a [Playground] to a [DotServer]: the console commands an operator and an admin type.
##
## The only file in the project that names dot-server; a game wanting a dedicated server writes
## this one file. Zone commands: stand on one corner, run the command, stand on the other, run it again.
##
## [codeblock]
## server.modules.load_module("res://game/playground_module.gd")
## [/codeblock]



func _module_version() -> String:
	return "0.1.0"


## The custom maps delivered beside this game: every pack its descriptor names, read for a `maps/` directory
## where it is mounted. Duck-typed, so a dot-server without the field offers the built-in maps.
func _add_delivered_maps() -> void:
	var games: Object = server.get("games") if server != null else null
	if games == null:
		return
	var keys := PackedStringArray()
	for method in ["current_dependencies", "current_server_dependencies"]:
		if games.has_method(method):
			keys.append_array(games.call(method))
	for key in keys:
		var parts := DotGameDescriptor.split_key(key)
		var _added := game.add_map_directory(
			DotCloudClient.mount_prefix_for(StringName(parts[0]), parts[1]).path_join("maps"))


func _module_description() -> String:
	return "A sandbox: maps, props, tools and toys."


func _module_author() -> String:
	return "dot"


func _module_load() -> DotResult:
	game = DotRegistry.get_node_service(Playground.SERVICE) as Playground

	if game == null:
		# Refuse: a module that loaded and did nothing accepts players into no game.
		return DotResult.fail(
			DotError.CODE_STATE,
			"No Playground is registered. Create one before loading this module."
		)

	game.noclip_policy = _session_may_noclip
	_add_delivered_maps()
	var netted := _build_netcode()

	if not netted.ok:
		return netted

	var extras := _build_extras()

	if not extras.ok:
		return extras

	# Who people are and what they wear. Never fatal: a server with no identity stack is a
	# server where everybody wears the stock look, which is a configuration.
	var dressed: DotResult = await _build_identity()
	if not dressed.ok:
		DotLog.result(CHANNEL, "the identity layer", dressed)

	# --- Spawn and style ---------------------------------------------------
	add_command(
		"pg_restart", _cmd_restart,
		"Put yourself back at the map's spawn", ""
	).with_chat()
	add_command(
		"pg_style", _cmd_style,
		"List the styles, or switch to one", ""
	).with_chat()
	# The run timer's commands (pg_timer, pg_track, pg_top, pg_cp, pg_tp, pg_cp_clear) belong to
	# `addons/pg_timer`, which registers them only when dot-timer is present.
	if game.run_timer != null and game.run_timer.has_method("bind_commands"):
		game.run_timer.call("bind_commands", add_command, _target)


	# `.with_chat()` makes a command typable from chat whatever `sv_chat_commands` says; these survive an
	# operator turning it off, and the map commands below rely on the flag.

	# Maps: `map`, `maps` and `mapinfo` come from dot-map. `install_with` rather than `install`, because
	# `Playground.change_map` resets the props, NPCs and run timer before it touches the session.
	# `allow_chat_change` is on: a map change destroys no ranked run here.
	var _rotation := game.load_rotation()
	add_cvar(
		"sv_map_rotation_file", game.config.map_rotation_file,
		"maps.yml: the maps that rotate, in named rotations. Unlisted maps stay installed."
	).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.map_rotation_file = new_value.strip_edges()
			var _read := game.load_rotation()
	)

	var map_commands := DotMapCommands.new()
	map_commands.session = game.maps
	map_commands.change_fn = func(id: StringName) -> DotResult:
		return await game.change_map(id)
	map_commands.allow_chat_change = true
	map_commands.player_count_fn = func() -> int:
		return game.players.size()
	map_commands.rotation_file_fn = func() -> DotMapRotationFile:
		return game.rotation_file
	map_commands.spec_fn = game.rotation_commands
	map_commands.bind(self)

	bind_map_commands(add_command)

	# --- Props -------------------------------------------------------------
	add_command("pg_prop", _cmd_prop, "Spawn a prop in front of you", "").with_chat()
	add_command("pg_undo", _cmd_undo, "Remove the last prop you spawned", "").with_chat()
	add_command("pg_save", _cmd_save, "Save everything you have built: pg_save <name>", "").with_chat()
	add_command("pg_load", _cmd_load, "Put a saved build down in front of you: pg_load <name>", "").with_chat()
	add_command("pg_builds", _cmd_builds, "List your saved builds", "").with_chat()
	add_command("pg_build_delete", _cmd_build_delete, "Delete a saved build: pg_build_delete <name>", "").with_chat()
	add_command(
		"pg_props_clear", _cmd_props_clear,
		"Remove every prop, or one player's",
		DotAdminFlags.GENERIC
	).with_chat()

	add_command("pg_status", _cmd_status, "What this server is doing", "").with_chat()

	# --- The addons an operator turns on -----------------------------------
	add_command(
		"pg_services", _cmd_services,
		"Show chat, voice and moderation", DotAdminFlags.GENERIC
	)
	add_command(
		"pg_arena", _cmd_arena,
		"pg_arena [on|off] — health, weapons that hurt, and a round",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_waves", _cmd_waves,
		"pg_waves [on|off|clear] — NPCs the server releases",
		DotAdminFlags.CHANGEMAP
	)
	# No flag: this is a player command rather than an administrative one, and
	# `_on_chat_command` routes `!pg_spec` through the console like every other.
	add_command(
		"pg_spec", _cmd_spec,
		"pg_spec [player|off|next] — watch somebody else", ""
	).with_chat()
	add_command(
		"pg_shop", _cmd_shop,
		"pg_shop [on|off|prices] — a price list over the spawn menu",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_credits", _cmd_credits,
		"pg_credits [player] [+amount] — what somebody has, and giving them some",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_give", _cmd_give,
		"pg_give <player> <prop> [count] — put something in somebody's bag",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_inv", _cmd_inv,
		"pg_inv <player> — what somebody is carrying", DotAdminFlags.GENERIC
	)
	add_command(
		"pg_achievements", _cmd_achievements,
		"pg_achievements [player] — what somebody has earned", ""
	).with_chat()
	# MUTE rather than BAN: quieting somebody and removing them are different powers, and
	# dot-server's own flags are what distinguish them.
	add_command(
		"pg_gag", _cmd_gag, "pg_gag <who> <seconds> [reason]", DotAdminFlags.MUTE
	).with_chat()
	add_command(
		"pg_mute", _cmd_mute, "pg_mute <who> <seconds> [reason]", DotAdminFlags.MUTE
	).with_chat()

	# The tick rate is dot-server's `sv_tickrate`, not duplicated: a second cvar could disagree with the engine's.
	add_cvar(
		"pg_map_seconds",
		str(int(game.maps.time_limit.duration)),
		"Seconds a map runs before the next one is chosen. 0 disables it."
	)

	# Every NPC's reaction time and how good it is, over the character its kind was given.
	# NOTIFY, because players should know the NPCs just got harder.
	game.npc_skill.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)

	# Thrown grenades: arena_weapons' sv_grenade_* set (bounce, friction, flash, smoke and fire times).
	var _grenades := game.grenade_rules.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY)
	# Dead bodies: dot-player-char's sv_ragdoll* set. The server only picks each death's
	# reaction from them; REPLICATED, because the clients draw the bodies.
	var _ragdolls := game.ragdoll_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	var _drops = game.weapon_layer.bind_cvars(add_cvar)
	# The map's toys: dot-props' sv_toys* set. REPLICATED, because a client hides the toys the
	# server took away and draws the rest.
	var _toys := game.toy_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	# dot-player-controller's mp_forceview (view mode) and mp_solidplayers (players block each other),
	# REPLICATED: the client places its camera under the first and predicts its player under the second.
	var _views := game.view_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	var _bodies := game.body_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	var _ambient := game.ambient_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED,
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)

	_bind_limits()
	_bind_slots()
	_bind_pickup()
	_bind_creative()
	_bind_props_feel()
	var blocked := _bind_noblock()
	if not blocked.ok:
		return blocked
	_bind_config()

	server.client_disconnected.connect(_on_client_disconnected)
	game.maps.map_over.connect(_on_map_over)
	game.run_filed.connect(_on_run_filed)

	hook_post("client_spawn", _on_client_spawn)

	# dot-server's own chat is cancelled here, not listened to: [DotChatRouter] has the rules, and both
	# running would leak admin chat. Only a pre-hook can cancel; handle_message broadcasts on return.
	hook_pre("player_chat", _on_player_chat)

	# dot-chat makes the join and leave notices now, so dot-server's would be a second one
	# on a second path.
	if server.chat != null:
		server.chat.announce_joins = false

	_build_query_provider()

	game.maps.changed.connect(_report_map)
	_report_map(game.maps.current)

	log_info("playground loaded", {
		"map": String(game.maps.current.id) if game.maps.current != null else "-",
		"tick_rate": game.tick_rate,
	})

	return DotResult.success(null)


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

	var voted := vote.setup(game)

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
	game.config_binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE, func(name: String) -> bool:
		return hand.has(name) or console.has_name(name))
	game.config_binder.bind_commands(add_command)


## The server's tick, which is the whole game's. Driven from here, not the game's loop: it has to run between
## dot-net applying inputs and building the snapshot. `Playground.external_tick` stands the game's loop down.
func _physics_process(_delta: float) -> void:
	if not loaded or bridge == null:
		return

	_tick += 1
	if loading != null:
		loading.poll_loading()
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
