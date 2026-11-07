extends "res://game/playground_module_build.gd"
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
	# Aim down sights: the numbers the simulation reads cross as one JSON cvar, `zee_ads_rules`.
	var _ads := game.ads_rules.bind_cvars(
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


