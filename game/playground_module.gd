extends DotModule

const PlaygroundPaths := preload("playground_paths.gd")
const PlaygroundMapConfig := preload("playground_map_config.gd")

const Playground := preload("playground.gd")
const PlaygroundWorkbench := preload("playground_workbench.gd")
const PlaygroundProfiles := preload("playground_profiles.gd")
const PlaygroundArena := preload("playground_arena.gd")
const PlaygroundDowns := preload("playground_downs.gd")
const PlaygroundModTools := preload("playground_mod_tools.gd")
const PlaygroundLimits := preload("playground_limits.gd")
const PlaygroundPickup := preload("playground_pickup.gd")
const PlaygroundBuilds := preload("playground_builds.gd")
const PlaygroundNetBridge := preload("net/playground_net_bridge.gd")
const PlaygroundPlatform := preload("playground_platform.gd")
const PlaygroundAvatars := preload("playground_avatars.gd")
const PlaygroundPlayer := preload("playground_player.gd")
const PlaygroundProgress := preload("playground_progress.gd")
const PlaygroundServices := preload("playground_services.gd")
const PlaygroundShop := preload("playground_shop.gd")
const PlaygroundSpectate := preload("playground_spectate.gd")
const PlaygroundVote := preload("playground_vote.gd")
const PlaygroundWaves := preload("playground_waves.gd")

## Binds a [Playground] to a [DotServer]: the console commands an operator and an
## admin actually type.
##
## [b]This is the only file in the project that names dot-server[/b], which is where
## the family's own documentation says such a bridge belongs — dot-timer does not
## import dot-server, dot-map does not, and dot-props does not, so a game that wants
## a dedicated server writes one file and it is this one.
##
## [codeblock]
## server.modules.load_module("res://game/playground_module.gd")
## [/codeblock]
##
## [b]The commands are the point of the module, not a garnish.[/b] A surf or bhop
## server is administered from a console: maps are changed, zones are drawn on maps
## whose authors never used this engine, styles are switched, and props are cleared
## when somebody has built a wall across the start. Without a console, every one of
## those needs a code change — which is exactly the position community servers were
## in before their admin plugins, and the reason console zone tools exist.
##
## The zone commands reproduce that workflow deliberately: stand on one corner, run
## the command, stand on the other, run it again.

const CHANNEL := "playground.module"

## The drawn map ballot's notice topic. The client shell draws one menu per topic, and a
## server running several games sends its own `game_ballot` beside this one.
const MAP_BALLOT_TOPIC := &"map_ballot"

var game: Playground = null

## The netcode, and the seam that joins it to the game. Built here because a module is
## what a dedicated server loads and unloads, so the netcode goes away with the game
## rather than outliving it.
var net: DotNetManager = null
## Carries admins' profile edits up and the edited values down. Null if the types would not register.
var profile_link: DotNetProfileLink = null
## The admin web page and API over the same profiles; closed unless `workbench.enabled` in cfg/server.yml.
var workbench := PlaygroundWorkbench.new()
var bridge: PlaygroundNetBridge = null

## Chat, moderation and voice. Built here rather than in the game, because they are about
## the people connected rather than about the world.
var services: PlaygroundServices = null

## Where the services write punishments. [constant PlaygroundServices.PUNISHMENTS_PATH] —
## the store a real server enforces — unless a host says otherwise before this loads.
##
## [b]Static, because nothing holds this module before it exists[/b]: dot-server constructs
## it from a path inside `load_module`, so there is no instance for a host to set a field on
## first. `examples/dedicated.tscn` points it at a directory of its own; before it could,
## every run wrote its test gag and the live tools' warnings to the real store, 352 records
## by the time anybody counted.
static var punishments_path: String = PlaygroundServices.PUNISHMENTS_PATH

## Health, weapons that hurt, and a round. Off unless an operator turns it on.
var arena: PlaygroundArena = null

## dot-moderation's live tools, with this game's verbs (`PlaygroundModTools`), and their
## commands. Built in the module rather than the services layer because health lives in
## the arena layer, which is the module's.
var mod_tools: DotModTools = null
var mod_commands: DotModToolCommands = null

## NPCs the server releases, paced by a director. Also off by default.
var waves: PlaygroundWaves = null

## A price list over the spawn menu, when an operator has turned one on. `pg_shop`.
var shop: PlaygroundShop = null

## Watching somebody else build, fight, or drive into a wall.
var spectate: PlaygroundSpectate = null

## Down rather than dead, while the waves are on. The co-operative half.
var downs: PlaygroundDowns = null

## Per-player statistics, and what they are worth.
var progress: PlaygroundProgress = null

## What plays next, decided by the players.
var vote: PlaygroundVote = null

## Which userids have already been given a player, so a re-fired spawn does not add a
## second one.
var _joined: Dictionary = {}

var _tick: int = 0

## Who last said something. What `pg_status` reports, off the accepted line.
var _last_spoke: String = ""


func _module_name() -> String:
	return "playground"


func _module_version() -> String:
	return "0.1.0"


## The custom maps delivered beside this game: every pack its descriptor names, read for a
## `maps/` directory where it is mounted (game-playground-maps is one). A client builds the
## map too, so such a pack is a `dependencies` entry and every client fetches it (game.yml's
## `maps_delivery: client` asks the host to put the server owner's map packs there); the client
## adds the same directories from what the server told it to fetch. Duck-typed through the
## manager, so a dot-server without the field simply offers the built-in maps.
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
		# Refusing to load is right. A module that loaded and did nothing would leave
		# a server that accepts players into a game that does not exist, and the
		# symptom is players who connect and never spawn.
		return DotResult.fail(
			DotError.CODE_STATE,
			"No Playground is registered. Create one before loading this module."
		)

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
	# --- A run timer's, when a server added one -----------------------------
	#
	# pg_timer, pg_track, pg_top and the practice checkpoints (pg_cp, pg_tp, pg_cp_clear)
	# belong to `addons/pg_timer`, which registers them only when dot-timer is present: a
	# command for a timer the server does not have would answer every player with an error.
	if game.run_timer != null and game.run_timer.has_method("bind_commands"):
		game.run_timer.call("bind_commands", add_command, _target)


	# **`.with_chat()` says a command is typable whatever the server's default is.**
	# The default used to be "no": `chat_allowed` was false, `DotConsole._run_command`
	# refused a `Source.CHAT` context without it, and dot-server's chat manager dispatches
	# with exactly that source — so this module registered thirty-two commands and not one
	# could be reached from chat. `!pg_rtv`, on a server whose whole point is rocking the
	# vote, answered "'pg_rtv' cannot be run from chat." `sv_chat_commands` is that default
	# turned around, and it ships on.
	#
	# Marking still means something: these survive an operator turning it off, because they
	# are what a player is expected to type. The map commands below carry CHANGEMAP and
	# rely on it: what plays is a question about the flag rather than about the prefix.
	# --- Maps --------------------------------------------------------------
	#
	# `map`, `maps` and `mapinfo` come from dot-map itself now. They used to be dot-server's
	# `map`, which changed the GAME -- so on this server, which runs one game and several
	# maps, the plain name an operator reached for did the one thing they did not mean.
	#
	# `install_with` rather than `install`, because `Playground.change_map` resets the
	# props, the NPCs and any run timer before it touches the session: handing the session
	# straight to the command would change the world out from under all three.
	#
	# `allow_chat_change` is ON, which is now also the default -- it was off, and the
	# sandbox was the first place the old default read as an obstruction rather than a
	# policy. What a map change destroys on a records server is a run, and there are no
	# ranked runs here; `pg_map` beside it has been `.with_chat()` since it was written.
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

	# The tick rate is dot-server's `sv_tickrate` and is deliberately not duplicated
	# here. A second cvar for the same number is a second number that can disagree
	# with the first, and a run timer reads the engine's.
	add_cvar(
		"pg_map_seconds",
		str(int(game.maps.time_limit.duration)),
		"Seconds a map runs before the next one is chosen. 0 disables it."
	)

	# Every NPC's reaction time and how good it is, over the character its kind was given.
	# NOTIFY, because players should know the NPCs just got harder.
	game.npc_skill.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)

	# Dead bodies: dot-player-char's sv_ragdoll* set. The server only picks each death's
	# reaction from them; REPLICATED, because the clients draw the bodies.
	var _ragdolls := game.ragdoll_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	# The map's toys: dot-props' sv_toys* set. REPLICATED, because a client hides the toys the
	# server took away and draws the rest.
	var _toys := game.toy_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	# dot-player-controller's mp_forceview (first or third person: the player's choice, or one
	# held) and mp_solidplayers (players block each other, 1 by default). REPLICATED: the
	# client places its own camera under the first and predicts its own player under the
	# second.
	var _views := game.view_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	var _bodies := game.body_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	_bind_limits()
	_bind_pickup()
	_bind_creative()
	_bind_props_feel()

	server.client_disconnected.connect(_on_client_disconnected)
	game.maps.map_over.connect(_on_map_over)
	game.run_filed.connect(_on_run_filed)

	hook_post("client_spawn", _on_client_spawn)

	# [b]dot-server's own chat is cancelled here rather than listened to.[/b]
	# [DotChatRouter] has the rules now, and the one thing that must not happen is both
	# running: two sets of rules to keep in step, and the one that skipped the filter would
	# be the one that leaked admin chat. A pre-hook is what can cancel;
	# [method DotChatManager.handle_message] broadcasts the moment the event returns.
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


## What a server browser is told about this sandbox.
##
## [b]This game ships `PlaygroundBrowser` and answered no query at all.[/b] The list half
## was written, the screen was drawn and the address bar worked; there was nothing at the
## other end. dot-server answers A2S and DQP once a query host is plugged in, and what a
## query says about the GAME comes from a provider like this one — without it a listing
## row says only that the game is called Playground.
##
## **The three cvars are the point of the row.** `pg_arena`, `pg_waves` and `pg_shop` each
## turn this into a different server, and all three default to off precisely because that
## is an operator's decision — so a person reading a list is choosing between servers that
## share a name and not a game. That is exactly what a query section is for.
func _build_query_provider() -> void:
	var provider := PlaygroundQueryProvider.new()
	provider.module = self

	# DEBUG, not ERROR: a server with neither query protocol enabled is a legitimate
	# deployment and this game's own suite runs one.
	DotLog.result(
		CHANNEL, "the query provider", add_query_provider(provider), DotLog.Level.DEBUG
	)


## A [DotQueryProvider] over this module. An inner class because it is one method and a
## reference, which is game-arena's pattern for the same thing.
class PlaygroundQueryProvider extends DotQueryProvider:
	## Held as an [Object]: this script has no [code]class_name[/code] and an inner class
	## cannot name the outer script it lives in.
	var module: Object = null

	func _provider_name() -> String:
		return "playground"

	func _contribute(snapshot: DotQuerySnapshot) -> void:
		if module == null or module.game == null:
			return

		var game: Playground = module.game
		var values := {
			"map": String(game.maps.current.id) if game.maps != null
				and game.maps.current != null else "",
			"map_name": game.maps.current.display_name if game.maps != null
				and game.maps.current != null else "",
			"players": module._joined.size(),
			"props": game.props.world_count() if game.props != null else 0,
			"tick_rate": game.tick_rate,
			# The three that decide what kind of server this is.
			"arena": module.arena != null and module.arena.enabled,
			"waves": module.waves != null and module.waves.is_enabled(),
			"shop": module.shop != null and module.shop.enabled,
		}

		if module.waves != null and module.waves.is_enabled():
			values["npcs"] = module.waves.count()

		for key: String in values:
			snapshot.game[key] = values[key]


## The running map's per-map cvars (dot-game's [DotGameMapConfig]); the previous map's values return on each change and on unload.
var map_config: DotGameMapConfig = null


## Tells dot-server which map is running, so A2S and DQP print it in their map field (and
## the backbone report does too) rather than this game's content id. On every change
## through the session's own signal, which every route to a new map ends at.
func _report_map(map: DotMapDef, _world: Node = null) -> void:
	if map_config == null and console != null:
		map_config = PlaygroundMapConfig.build(console)
	if map_config != null and map != null:
		var _applied := map_config.apply(String(map.id))
	if server != null and server.games != null:
		server.games.set_current_map(String(map.id) if map != null else "")


## Who is still behind their loading cover, from dot-game's roster used for that alone: this
## module is not on DotGameModule, so it seats people itself and only borrows the bookkeeping
## (loading from the spawn event until the client says its cover lifted, again from a map
## change). The arena asks it by player key (`u<userid>`). A bot is never seated, so never loading.
var loading: DotGameRoster = null
var _handles_cover: bool = false


## The loading roster and the handler for the client's cover report on dot-server's envelope.
## A kind on the existing envelope because the RPC set is frozen; a client that predates it is
## released by the roster's timeout. Duck-typed so an older dot-server still loads this.
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


## The identity layer this module built, or null when it found one already running.
var _identity: DotPlatformIdentity = null
var _loaded_platform := false


## Resolves who a session is and what they wear, through dot-platform.
##
## [b]This game's module is not a DotGameModule[/b] (see docs/simulation.md, "The server module"), so it
## does here what that base does for the games on it: build `DotPlatformIdentity` with this
## game's avatar schema, a stock look and the site translation, then load dot-platform's
## module. Without it nothing on a deployed server ever resolved a member's avatar, and every
## player in the sandbox was a coloured capsule. A platform module already loaded (the
## dedicated example builds `PlaygroundPlatform` and loads one) is used as it is.
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


func _module_unload() -> void:
	if map_config != null:
		map_config.restore()
		map_config = null
	workbench.stop()
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

		# Every player this module put in the game comes back out. A module that
		# unloaded and left them would leave the game holding players whose sessions
		# no longer exist — and the next record filed would be attributed to a ghost.
		for id in game.players.keys():
			game.remove_player(id)



## Everything that is not the netcode.
##
## [b]Built in this order because each one needs the last.[/b] The services register a mute
## source the chat router warns about the absence of; the progress layer watches the prop
## spawner and the timer; the arena and the waves both act on the world. None of it
## suspends, because [method DotModuleHost.load_module] does not await `_module_load` and a
## module whose load suspends returns null to it.
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

	# How an armed NPC's shot hurts a player: through the arena, which refuses while it is
	# off — so a sandbox where nobody dies stays one, and `pg_arena 1` is the switch that
	# makes the soldiers dangerous as well as the players.
	game.arena_hurt = func(attacker: StringName, victim: StringName, amount: float, distance: float) -> void:
		var _hurt := arena.hurt(attacker, victim, amount, distance)
	# Lava through the arena too, and only while it is on: off, the game sends the player
	# back to the spawn instead (see Playground.hazard_hurt).
	game.hazard_hurt = func(victim: StringName, amount: float) -> bool:
		return arena.enabled and arena.hurt(&"", victim, amount, 0.0) != null
	arena.player_killed.connect(func(victim: StringName, killer: StringName) -> void:
		shop.on_arena_kill(killer, victim)
		var player: PlaygroundPlayer = game.players.get(victim, null)
		var at := player.controller.state.position if player != null else Vector3.ZERO
		spectate.on_death(victim, at, killer)
	)
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

	var watching := spectate.setup(game)

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

	# A downed player who bleeds out is a death the scoreboard and the respawn queue
	# still have to hear about, and the arena's own path was skipped when they went
	# down. This is the other end of that decision.
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
			record.revive(clampf(health / PlaygroundArena.MAX_HEALTH, 0.05, 1.0))
	)

	# Being killed by a wave is what being downed is FOR, so the two switch together.
	# The alternative — a separate cvar — is an operator who turned the waves on and
	# wonders why nobody is being picked up.
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

	# Both map clocks follow the server's hibernation: they wait while nobody is here and start
	# again from the top when somebody joins. With it off (`sv_hibernate_when_empty 0`),
	# dot-vote's `empty_choice` changes the map when the limit runs out on nobody. This module
	# is not on DotGameModule, which does it itself.
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

	# The map menu (M), dot-vote's: a player holding the owner's `sv_map_menu_flag` changes the
	# map now through the game's own change (props, NPCs and course reset with it, as for the
	# vote and `pg_map`), anybody else gets a vote. Read by name, because a server on a dot-vote
	# older than the menu has no `map_menu`.
	var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
	if menu_half is Object:
		(menu_half as Object).set(&"change_fn", game.change_map)

	# [b]The one signal that fires for every change however it happened.[/b] An operator
	# typing `pg_map`, the time limit expiring and the vote applying all end at
	# `DotMapSession.changed` — which is why the director does not announce its own change
	# and why this is the only connection. Two of them is two entries in the play history
	# for one play, and a "played in the last N" cooldown that is quietly half what it
	# says: dot-vote's fifth bug, from the other side.
	game.maps.changed.connect(func(map: DotMapDef, _world: Node) -> void:
		vote.note_playing(map.id)
	)

	if game.maps.current != null:
		vote.note_playing(game.maps.current.id)

	return DotResult.success(null)


# --- Chat, voice and votes -------------------------------------------------

## Somebody said something through dot-server's own chat path.
##
## Taken and cancelled, not watched: this game's rules are [DotChatRouter]'s now, and
## cancelling is what makes there be exactly one path.
func _on_player_chat(event: DotEvent) -> void:
	event.cancel("routed by the sandbox's chat", _module_name())

	var session := event.get_session()

	if session == null or services == null or services.chat == null:
		return

	_on_say_requested(
		session.peer_id, PlaygroundServices.CHANNEL_ALL, event.get_string("text")
	)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.chat.submit(peer_id, channel_id, text)

	if not said.ok and said.error != null:
		# Back to the sender and nowhere else: dot-chat is deliberate that a rate-limited
		# or gagged player must not be able to measure the difference from outside.
		services.chat.notice(peer_id, said.error.message, channel_id)


func _on_voice_requested(peer_id: int, payload: PackedByteArray) -> void:
	services.voice.relay(peer_id, payload)


func _on_chat_accepted(message: DotChatMessage, _to: PackedInt32Array) -> void:
	if message.sender_peer > 0:
		_last_spoke = message.sender_name


## An unclaimed `!command` from chat, routed into dot-server's own console with the
## player's permissions.
##
## [b]Not a second command table.[/b] dot-server already decides what a session may run,
## logs it to the audit log and answers it — and this game's console surface is the largest
## in the family, so a second table would be the larger half unaudited.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	var session := server.session_of(peer_id)

	if session == null:
		return

	if server.console.find_command(command) == null:
		DotLog.debug(CHANNEL, "an unknown chat command was ignored", {
			"peer": peer_id, "command": command,
		})
		return

	var ctx := session.make_context(
		command,
		args,
		DotCmdContext.Source.CHAT,
		func(line: String) -> void:
			services.chat.notice(peer_id, line, PlaygroundServices.CHANNEL_ALL)
	)

	var line := command

	for arg in args:
		line += " " + arg

	server.console.execute(line, ctx)


func _on_vote_requested(peer_id: int, token: String) -> void:
	var session_id := bridge.player_for_peer(peer_id)

	if session_id == 0:
		return

	var result := vote.submit(StringName("u%d" % session_id), token)

	if not result.ok and services != null:
		services.chat.notice(
			peer_id, result.error.message, PlaygroundServices.CHANNEL_ALL
		)


func _voter_is_admin(voter: StringName) -> bool:
	var text := String(voter)

	if not text.begins_with("u"):
		return false

	var session := server.session_by_userid(text.substr(1).to_int())
	# CHANGEMAP, not any flag: `is_admin()` is "holds a flag at all", which a reserved slot
	# or admin chat satisfies, and this gates extending the map, an instant rtv and the
	# nomination bypasses. The console's own extend asks for CHANGEMAP; the wire must too.
	return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)


func _on_vote_announced(line: String) -> void:
	if services != null and services.chat != null:
		services.chat.announce(line, PlaygroundServices.CHANNEL_ALL)


## The vote picked a map. The game is what changes to it.
func _on_vote_change_due(map_id: StringName) -> void:
	game.change_map(map_id)


# --- Loadouts, combat and progress ----------------------------------------

func _on_loadout_requested(peer_id: int, pairs: Array) -> void:
	var session_id := bridge.player_for_peer(peer_id)

	if session_id == 0 or arena == null or arena.loadouts == null:
		return

	var loadout := DotLoadout.new()

	for pair in pairs:
		var row: Array = pair
		loadout.set_item(StringName(str(row[0])), StringName(str(row[1])))

	# [b]Validated on the way in, conformed on the way out.[/b] A client that can make the
	# server repair its way to a legal loadout can put anything in any slot and have the
	# server pick the nearest legal thing — so this direction refuses, and
	# `conform_on_load` is on for the other one, where refusing would mean a player who
	# has not played since a weapon changed cannot spawn.
	# [b]Awaited, and this handler is therefore a coroutine.[/b] The store write is the
	# suspension: a publish that reported success before the write returned would be a
	# loadout a player believes they have and a server that has not kept it. Nothing after
	# this line depends on anything else, so suspending here costs nothing — which is the
	# only reason it is safe to do it inside a signal handler.
	var published: DotResult = await arena.loadouts.publish(
		loadout_key(session_id), loadout, 0
	)

	if not published.ok and services != null:
		services.chat.notice(
			peer_id, published.error.message, PlaygroundServices.CHANNEL_ALL
		)


func _on_health_changed(
	player_id: StringName, health: float, armour: float, by: StringName
) -> void:
	bridge.broadcast_combat(
		_session_of(player_id), int(health), int(armour), _session_of(by), false
	)


func _on_player_killed(victim: StringName, killer: StringName) -> void:
	var fallen: PlaygroundPlayer = game.players.get(victim, null)
	bridge.broadcast_combat(
		_session_of(victim), 0, 0, _session_of(killer), true,
		fallen.death if fallen != null else null
	)

	if progress != null:
		progress.note(victim, &"deaths", 1.0)

		if killer != &"" and killer != victim:
			progress.note(killer, &"kills", 1.0)


func _on_earned(player_key: String, id: StringName, title: String, points: int) -> void:
	# The session the key belongs to, so a client can colour the line. Linear over at most
	# a few dozen players, a few times a session.
	for userid in _joined.keys():
		var session := server.session_by_userid(int(userid))

		if session == null:
			continue

		if PlaygroundPlatform.key_for_session(server, session) != player_key:
			continue

		bridge.broadcast_progress(session.userid, id, title, points)
		return


## The key a statistic is filed under.
##
## [b]The scoped pseudonymous one when there is a dot-platform, and the session id when
## there is not.[/b] dot-stats refuses an account id as a player key before it leaves the
## server, and this is the one function that decides — a LAN sandbox files under something
## that lasts as long as the session, which is honest.
func _stats_key_for(player_id: StringName) -> String:
	var text := String(player_id)

	if not text.begins_with("u"):
		return text

	var session := server.session_by_userid(text.substr(1).to_int())

	if session == null:
		return text

	return PlaygroundPlatform.key_for_session(server, session)


## Who a session is, for a bag that outlasts the connection — or empty for nobody.
##
## [b]The same key the statistics are filed under, and for the same reason:[/b] dot-server's
## userid is sequential and a reconnect is a new one, so a bag keyed on it would be emptied
## by every dropped connection. With no identity stack the key is `local:<userid>`, which
## identifies nobody next time; that is answered as empty, and the bag goes with the session
## rather than piling up one abandoned bag per connection for the life of the server.
func _bag_key_for(session_id: int) -> String:
	if server == null:
		return ""
	var session := server.session_by_userid(session_id)
	if session == null:
		return ""
	var key := PlaygroundPlatform.key_for_session(server, session)
	return "" if key == "" or key.begins_with("local:") else "bag:" + key


## A world player id back to a dot-server session id, or zero.
func _session_of(player_id: StringName) -> int:
	var text := String(player_id)
	return text.substr(1).to_int() if text.begins_with("u") else 0


# --- The netcode -----------------------------------------------------------

func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = 32
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 64
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

	net.messages.seal()
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
	workbench.resolver = PlaygroundWorkbench.ticket_resolver(DotRegistry.get_node_service(DotAuthServer.SERVICE) as DotAuthServer)
	if server != null and server.admins != null:
		workbench.admin_permit = server.admins.uid_has_permission
	var wb := workbench.start(game.profiles, DotWorkbenchHttp.read_config())
	if not wb.ok:
		DotLog.result(CHANNEL, "the workbench", wb)
	add_command("workbench", func(ctx: DotCmdContext) -> void: ctx.reply_lines(workbench.describe_lines()),
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


## The server's tick, which is the whole game's.
##
## Driven from here rather than by the game's own loop, because it has to happen between
## dot-net applying the inputs that arrived and building the snapshot that goes back out.
## `Playground.external_tick` is what stands the game's loop down.
func _process(_delta: float) -> void:
	workbench.poll()


func _physics_process(_delta: float) -> void:
	if not loaded or bridge == null:
		return

	_tick += 1
	if loading != null:
		loading.poll_loading()
	bridge.server_tick(_tick)

	# [b]After the world has ticked, and that is the ordering that matters.[/b] dot-combat
	# rewinds to resolve a shot and the waves read where everybody is, and both have to
	# work on positions the movement has just produced — a list built before the tick is a
	# list of where everybody WAS, which is the one-tick lag this family has documented
	# three times now.
	var step := 1.0 / float(maxi(game.tick_rate, 1))

	if arena != null:
		arena.tick(_tick, step)

	if shop != null:
		shop.tick(step)

	if spectate != null:
		spectate.tick(step)

	if downs != null:
		downs.tick(step)

	if waves != null:
		waves.tick(_tick, step)

	if vote != null:
		vote.advance(step)


# --- Sessions --------------------------------------------------------------

## A client finished the signon and is in the world.
##
## `client_spawn`, not `client_connected`: a connected client has a socket and
## nothing else — no identity, no content, no confirmation it can load the map.
## [b]`client_spawn` carries `userid`, and it does NOT carry `peer_id`.[/b] This handler
## asked for one, got 0, looked a session up by it and found null — and a null session is
## a legitimate thing to find, so it returned quietly and NOBODY EVER JOINED. Nothing
## errored, in every configuration, for as long as this module has existed; it survived
## because the only thing that had ever loaded it was a headless test that adds its
## players directly. game-dev/docs/bugs-found.md has carried this exact warning since
## game-hungario hit it.
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

	if loading != null:
		var _seated := loading.add(session)

	# Voice and chat learn about them before anything is sent, so a frame or a line that
	# lands in the same flush as the admission has somewhere to go.
	if services != null:
		services.add_peer(session.peer_id)

	if progress != null:
		progress.begin(PlaygroundPlatform.key_for_session(server, session))

	if arena != null and arena.enabled:
		arena.admit(id, session.label())

	# Not welcomed here: on a real join the peer is not ready yet, so [method _welcome]
	# would find nobody to send to. [method _on_peer_admitted] does it when READY lands.

	log_info("player joined the game", {"player": String(id)})


## The bridge has admitted a peer: now they can be told what they missed.
##
## [b]Found 2026-10-01 reviewing `[pg-rpc-before-scene]`:[/b] `_welcome` was called from
## `client_spawn` and returned at once unless the peer was READY, which on a real join it
## never is yet, so no connected player had ever been sent the chat backlog, the join line
## or the match clock.
func _on_peer_admitted(peer_id: int) -> void:
	var session := server.session_of(peer_id) if server != null else null
	if session == null or not _joined.has(session.userid):
		return
	if profile_link != null:
		profile_link.peer_joined(peer_id)
	_welcome(session)


## What somebody is told once they are in: the backlog, and the clock.
##
## [b]After the admission, never before it.[/b] Nothing may be sent to a peer before it has
## said it can receive — dot-server's signon finishes and *then* the client builds its
## scene, and everything sent in between lands on a node that does not exist and is lost,
## one "Node not found" per call.
func _welcome(session: DotClientSession) -> void:
	if bridge == null or not bridge.peer_is_ready(session.peer_id):
		return

	if services != null:
		# The backlog: what was said before they walked in. dot-chat computes it per peer,
		# because a channel with `backlog = 0` — the proximity one — must not replay a
		# line somebody said quietly beside their build to a stranger who was not there.
		for line in services.chat.backlog_for(session.peer_id):
			bridge.send_chat(session.peer_id, line)

		services.chat.join_notice(session.peer_id, PlaygroundServices.CHANNEL_ALL)

	# The match clock, once, so a client that joined mid-round is not told `IDLE` until
	# the next second ticks over.
	if arena != null and arena.enabled:
		arena._announce_clock()


## [b]`client_disconnected` emits TWO arguments — the session and a reason — and this
## took one.[/b] Godot then refuses the call outright ("Method expected 1 argument(s), but
## called with 2") and the handler NEVER RUNS: no player was ever removed, no peer was
## ever released, and the server went on building a snapshot for every client that had
## ever connected and sending it to a socket that was gone. One engine error per
## disconnect and three per tick after that.
##
## It survived because nothing had ever disconnected from this module: `dedicated.tscn`
## adds its players directly and tears the module down at the end. The default keeps it
## callable from anything that emits only the session.
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

	# [b]A map change clears the return history, for everybody.[/b] Every position in it
	# is a point in the map that was just freed, so `return <player>` after a change put
	# them where they had stood on a different map — in mid-air over a sandbox plate, or
	# a hundred metres under a surf start. A respawn keeps the history on purpose (a
	# teleport of the same body on the same map leaves a return meaningful); a map change
	# is the one case where none of it can be, which game-hungario (6462f79) and the lobby
	# (cb822cd) each found for themselves. `DotMapSession.changed` because it is the one
	# signal every change ends at, whoever asked for it — see the vote's connection.
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
		progress.end(PlaygroundPlatform.key_for_session(server, session))

	_joined.erase(session.userid)

	# The bridge releases the entity, tells every other client, and forgets the peer.
	# Removing them from the game alone would leave a replicated entity pointing at a
	# freed player.
	if bridge != null:
		bridge.remove_player(session.userid)
	else:
		game.remove_player(id)


## The id the game files records under.
##
## [b]The session's own scoped id, not a site account.[/b] The identity layer hands a
## server a per-scope pseudonymous id precisely so operators cannot correlate their
## players across servers, and a records table keyed on anything global would undo
## that for every server running this.
func _player_id(session: DotClientSession) -> StringName:
	return StringName("u%d" % session.userid)


## The key this seat's records and board rows are filed under: the account's uid (a guest's
## is per device), never the session's userid, which is a server-local counter that restarts
## at 1. Empty when the session has no identity, and then the seat is known by its userid, a
## key [method Playground.is_legacy_key] reads as unranked.
func _record_key_for(session: DotClientSession) -> StringName:
	var uid := session.uid()
	if uid == "":
		log_warn("a session has no identity; its runs are not ranked", {"userid": session.userid})
		return &""
	return StringName(uid)


# --- Helpers ---------------------------------------------------------------

## The player a command is about: a named one for an admin, otherwise the caller.
func _target(ctx: DotCmdContext, allow_named: bool = true) -> StringName:
	if allow_named and ctx.args.size() > 0 and ctx.session == null:
		# Only from the server console: letting a player name somebody else would be
		# letting them restart a stranger's run.
		return StringName(ctx.args[0])

	if ctx.session == null:
		return &""

	return _player_id(ctx.session)


func _caller(ctx: DotCmdContext) -> PlaygroundPlayer:
	var id := _target(ctx, false)

	if id == &"":
		return null

	var found: Variant = game.players.get(id)
	return found if found is PlaygroundPlayer else null


# --- Spawn and style -------------------------------------------------------

func _cmd_restart(ctx: DotCmdContext) -> void:
	var id := _target(ctx)

	if not game.players.has(id):
		ctx.reply("You are not in the game.")
		return

	game.spawn_player(id)
	ctx.reply("Back at the start.")


func _cmd_style(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var lines := PackedStringArray(["Styles:"])

		for style_id in game.style_order:
			var style: DotFpsStyle = game.movement_styles[style_id]
			lines.append("  %-16s %s" % [String(style.id), style.display_name])

		ctx.reply_lines(lines)
		return

	var id := _target(ctx, false)

	if id == &"" or not game.players.has(id):
		ctx.reply("Only a player can switch style.")
		return

	var wanted := StringName(ctx.args[0])

	if not game.set_player_style(id, wanted):
		ctx.reply("No such style: %s" % ctx.args[0])
		return

	ctx.reply("Style: %s" % String(wanted))


func _cmd_map(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var lines := PackedStringArray(["Maps:"])

		for map in game.maps.catalogue.maps:
			lines.append("  %-24s tier %d  %s%s%s" % [
				String(map.id), map.tier, String(map.kind),
				"" if map.enabled else "  (disabled)",
				"" if map.in_rotation else "  (not in rotation)",
			])

		ctx.reply_lines(lines)
		return

	var found := game.maps.catalogue.search(ctx.args[0])

	if found.is_empty():
		ctx.reply("No map matches '%s'." % ctx.args[0])
		return

	if found.size() > 1:
		var names := PackedStringArray()
		for map in found:
			names.append(String(map.id))
		ctx.reply("Which one? %s" % ", ".join(names))
		return

	ctx.reply("Changing to %s." % found[0].name_or_id())

	var changed: DotResult = await game.change_map(found[0].id)

	if not changed.ok:
		ctx.reply_error(changed)


func _cmd_nextmap(ctx: DotCmdContext) -> void:
	# With a ballot, the ballot's answer: its clock, its rock-the-vote and what it would
	# play. The map session's are the ones that decide nothing then.
	if vote != null and vote.director != null:
		var director := vote.director
		var pending := director.pending_id()
		ctx.reply("Next: %s   ·   %s   ·   %d rocked the vote (%d needed)" % [
			String(pending) if pending != &"" else String(director.next_in_rotation()),
			director.clock.timeleft_line(),
			director.clock.rtv_votes(),
			director.clock.rtv_needed(director.player_count()),
		])
		return

	var next := game.maps.rotation.choose(game.players.size())

	ctx.reply("Next: %s   ·   %s left   ·   %d rocked the vote (%d needed)" % [
		next.name_or_id() if next != null else "-",
		game.maps.time_limit.formatted_remaining(),
		game.maps.time_limit.rtv_votes(),
		game.maps.time_limit.rtv_needed(game.players.size()),
	])


## The game's own map and vote commands (`pg_map`, `pg_nextmap`, `pg_rtv`, `pg_extend`,
## `pg_vote`), each registered under every name maps.yml's `commands: names:` gives its role,
## the role's own name with no file. Takes the registrar as a Callable so a check can bind them
## on a console of its own: the live one already holds the defaults.
func bind_map_commands(register: Callable) -> void:
	var table := [
		["pg_map", _cmd_map, "Change map, or list what there is", DotAdminFlags.CHANGEMAP],
		["pg_nextmap", _cmd_nextmap, "What plays next, and how long is left", ""],
		["pg_rtv", _cmd_rtv, "Rock the vote", ""],
		["pg_extend", _cmd_extend, "Extend the current map", DotAdminFlags.CHANGEMAP],
	]

	for row: Array in table:
		for name in game.command_names(row[0]):
			var cmd: Variant = register.call(name, row[1], row[2], row[3])
			if cmd != null:
				cmd.with_chat()

	# Not chat-typable by default: it is the operator's (CHANGEMAP), as it always was.
	for name in game.command_names("pg_vote"):
		var _cmd: Variant = register.call(
			name, _cmd_vote, "pg_vote [open|next|status] — what plays next", DotAdminFlags.CHANGEMAP)


func _cmd_rtv(ctx: DotCmdContext) -> void:
	var id := _target(ctx, false)

	if id == &"":
		ctx.reply("Only a player can rock the vote.")
		return

	# With a ballot, `pg_rtv` is the ballot's rock-the-vote — the one `rtv` and the wire
	# reach. It went to the map session's tally, which on a server with a vote is a vote
	# that decides nothing. The voter id is the ballot's, `u<userid>`.
	if vote != null and vote.director != null:
		var voter := StringName("u%d" % ctx.session.userid) if ctx.session != null else id
		var res := vote.director.rock_the_vote(voter)
		ctx.reply("Rocked the vote." if res.ok else res.error.message)
		return

	if game.maps.time_limit.has_rocked(id):
		# Said rather than silently ignored: typing it twice is what somebody does
		# when nothing visible happened, and "nothing happened again" is the worst
		# possible answer.
		ctx.reply("You have already rocked the vote. %d of %d." % [
			game.maps.time_limit.rtv_votes(),
			game.maps.time_limit.rtv_needed(game.players.size()),
		])
		return

	if game.rock_the_vote(id):
		ctx.reply("The vote passed.")
		return

	ctx.reply("%d of %d." % [
		game.maps.time_limit.rtv_votes(),
		game.maps.time_limit.rtv_needed(game.players.size()),
	])


func _cmd_extend(ctx: DotCmdContext) -> void:
	var seconds := -1.0

	if ctx.args.size() > 0 and ctx.args[0].is_valid_float():
		seconds = ctx.args[0].to_float()

	# The ballot's clock is the one that ends a map when there is a ballot.
	if vote != null and vote.director != null:
		var extended := vote.director.extend(seconds)
		ctx.reply(
			("Extended. %s." % vote.director.clock.timeleft_line()) if extended.ok
			else extended.error.message
		)
		return

	if not game.maps.extend_map(seconds):
		ctx.reply("This map has been extended as often as it may be.")
		return

	ctx.reply("Extended. %s left." % game.maps.time_limit.formatted_remaining())


# --- Prop commands ---------------------------------------------------------

func _cmd_prop(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)

	if player == null:
		ctx.reply("Only a player can spawn props.")
		return

	if ctx.args.is_empty():
		# Grouped, because a flat list of fourteen ids in a console window is
		# unreadable and a delivered catalogue is four hundred. The categories are
		# the same ones the spawn menu tabs on, so what an admin sees here and what
		# a player sees in the menu cannot drift apart.
		for category in game.props.catalogue.categories():
			var names := PackedStringArray()

			for prop in game.props.catalogue.in_category(StringName(category)):
				names.append(String(prop.id))

			ctx.reply("%s: %s" % [category.capitalize(), ", ".join(names)])

		return

	var found := game.props.catalogue.search(ctx.args[0])

	if found.is_empty():
		ctx.reply("No prop matches '%s'." % ctx.args[0])
		return

	var at := player.eye_position() + player.aim_direction() * 3.0
	var spawned := game.props.spawn(found[0].id, player.player_id, at)

	# The refusal reason reaches the player through the spawner's own signal, which
	# the HUD is already listening to — so this says nothing on failure rather than
	# saying it twice.
	if spawned != null:
		ctx.reply("Spawned %s." % found[0].name_or_id())


# --- Saved builds -------------------------------------------------------------
#
# Relative to the player both ways: a build is saved around where its builder stands and the
# way they face, and put down around whoever loads it, the way they face. Kept under the
# player's statistics key, so a build outlives a reconnect wherever there are accounts.

## Where saved builds are kept. The suites point it somewhere of their own.
var builds := PlaygroundBuilds.new()


func _build_key(ctx: DotCmdContext) -> String:
	return PlaygroundPlatform.key_for_session(server, ctx.session) if server != null and ctx.session != null else ""


## The Q menu's Builds tab opened: send this player what they have saved.
func _on_builds_requested(peer_id: int) -> void:
	var session := server.session_of(peer_id) if server != null else null
	if session == null:
		return
	bridge.send_builds(peer_id, builds.summaries(PlaygroundPlatform.key_for_session(server, session)))


## A card on the Builds tab was clicked: the same as `pg_load <name>`, asked over the wire.
func _on_build_load_requested(peer_id: int, build_name: String) -> void:
	var session := server.session_of(peer_id) if server != null else null
	if session == null:
		return
	var found: Variant = game.players.get(StringName("u%d" % session.userid))
	if not (found is PlaygroundPlayer):
		return
	var player: PlaygroundPlayer = found
	var doc := builds.load_build(PlaygroundPlatform.key_for_session(server, session), build_name)
	if not doc.ok:
		bridge.tell_notice(peer_id, doc.error.message)
		return
	var state := player.controller.state
	var placed := builds.place(game, player.player_id, doc.value, state.position, state.yaw)
	if not placed.ok:
		bridge.tell_notice(peer_id, placed.error.message)
		return
	bridge.tell_notice(peer_id, "Put down \"%s\": %d props." % [build_name, int(placed.value)])


func _cmd_save(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)
	if player == null or ctx.args.is_empty():
		ctx.reply("Usage: pg_save <name>, as a player.")
		return
	var state := player.controller.state
	var doc := builds.capture(game, player.player_id, state.position, state.yaw)
	if not doc.ok:
		ctx.reply_error(doc)
		return
	var saved := builds.save(_build_key(ctx), ctx.args[0], doc.value)
	if not saved.ok:
		ctx.reply_error(saved)
		return
	ctx.reply("Saved \"%s\": %d props." % [ctx.args[0], (doc.value["props"] as Array).size()])


func _cmd_load(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)
	if player == null or ctx.args.is_empty():
		ctx.reply("Usage: pg_load <name>, as a player.")
		return
	var doc := builds.load_build(_build_key(ctx), ctx.args[0])
	if not doc.ok:
		ctx.reply_error(doc)
		return
	var state := player.controller.state
	var placed := builds.place(game, player.player_id, doc.value, state.position, state.yaw)
	if not placed.ok:
		ctx.reply_error(placed)
		return
	ctx.reply("Put down \"%s\": %d props." % [ctx.args[0], int(placed.value)])


func _cmd_builds(ctx: DotCmdContext) -> void:
	if ctx.session == null:
		ctx.reply("Only a player has builds.")
		return
	var listed := builds.names(_build_key(ctx))
	ctx.reply("Your builds: %s" % (", ".join(listed) if not listed.is_empty() else "none yet (pg_save <name>)"))


func _cmd_build_delete(ctx: DotCmdContext) -> void:
	if ctx.session == null or ctx.args.is_empty():
		ctx.reply("Usage: pg_build_delete <name>, as a player.")
		return
	var gone := builds.delete(_build_key(ctx), ctx.args[0])
	if not gone.ok:
		ctx.reply_error(gone)
		return
	ctx.reply("Deleted \"%s\"." % ctx.args[0])


func _cmd_undo(ctx: DotCmdContext) -> void:
	var id := _target(ctx, false)

	if id == &"" or not game.props.undo(id):
		ctx.reply("Nothing to undo.")
		return

	ctx.reply("Removed.")


func _cmd_props_clear(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var count := game.props.clear_all(DotPropSpawner.REASON_ADMIN)
		ctx.reply("Removed %d props." % count)
		return

	var count := game.props.clear_player(
		StringName(ctx.args[0]), DotPropSpawner.REASON_ADMIN
	)
	ctx.reply("Removed %d of %s's props." % [count, ctx.args[0]])


# --- Status ----------------------------------------------------------------

# --- Limits ------------------------------------------------------------------

## `pg_max_<group>` per kind, `pg_limit_roles` for who gets more, and `pg_limits` to see
## anybody's. A role is a dot-server admin group by name, plus `admin` (any admin flag)
## and `root` (the root flag) — so an operator who already has an admin file has roles.
func _bind_limits() -> void:
	var limits := game.spawn_limits

	for group in PlaygroundLimits.DEFAULTS.keys():
		var key: StringName = group
		var cvar := add_cvar(
			"pg_max_%s" % String(key),
			str(int(limits.defaults[key])),
			"Most %s one player may have at once. 0 is no limit." % String(key)
		)
		cvar.with_min(0.0)
		cvar.changed.connect(func(_old: String, value: String) -> void:
			limits.defaults[key] = maxi(value.to_int(), 0)
			limits.apply_to(game.props.limits)
		)

	var roles := add_cvar(
		"pg_limit_roles", "",
		"Per-role limits: 'admin: npcs=40 props=600; vip: props=300'. A role is an admin group, admin or root."
	)
	# Refused at the console rather than half-applied: a typo in one role must not leave
	# the others changed and this one silently ignored.
	roles.with_validator(func(text: String) -> DotResult: return PlaygroundLimits.new().set_roles_from(text))
	roles.changed.connect(func(_old: String, value: String) -> void:
		var _set := limits.set_roles_from(value)
	)

	limits.roles_fn = _roles_of

	add_command(
		"pg_limits", _cmd_limits, "pg_limits [player] — what somebody has against their limits", ""
	).with_chat()


## `pg_pickup` turns picking players up with the physics gun on and off; `pg_pickup_immune`
## names the roles nobody may pick up, and `pg_pickup_override` the roles that may anyway.
## The roles are the limits' roles, so one admin file answers both.
func _bind_pickup() -> void:
	var pickup := game.pickup
	pickup.roles_fn = _roles_of

	var on := add_cvar("pg_pickup", "1" if pickup.enabled else "0",
		"1 lets the physics gun pick up players; 0 refuses it.", DotConVar.FLAG_NOTIFY)
	on.changed.connect(func(_old: String, value: String) -> void:
		pickup.enabled = value.to_int() != 0
		if not pickup.enabled:
			pickup.release_all(game.players)
	)

	var immune := add_cvar("pg_pickup_immune", ",".join(pickup.immune_roles),
		"Roles nobody may pick up, e.g. 'admin, vip'. A role is an admin group, admin or root.")
	immune.changed.connect(func(_old: String, value: String) -> void:
		pickup.immune_roles = PlaygroundPickup.parse_roles(value)
	)

	var override := add_cvar("pg_pickup_override", ",".join(pickup.override_roles),
		"Roles that may pick up anybody, immune or not.")
	override.changed.connect(func(_old: String, value: String) -> void:
		pickup.override_roles = PlaygroundPickup.parse_roles(value)
	)


## `pg_creative` allows creative mode (on by default) and `!creative` toggles it for the
## caller. Turning the cvar off takes everybody out of it at once, because an operator who
## switched it off mid-match meant now.
func _bind_creative() -> void:
	var allowed := add_cvar("pg_creative", "1" if game.config.allow_creative else "0",
		"1 lets players switch on creative mode (!creative); 0 refuses it and ends it for everybody.",
		DotConVar.FLAG_NOTIFY)
	allowed.changed.connect(func(_old: String, value: String) -> void:
		game.config.allow_creative = value.to_int() != 0
		if not game.config.allow_creative:
			for id in game.players.keys():
				var _off := game.set_creative(id, false)
	)

	add_command("creative", _cmd_creative,
		"Creative mode: your props and you cannot be touched, and you cannot hurt anybody", "").with_chat()


## `pg_destruction` (off) lets shots and blasts break props with health; `pg_prop_surf`
## (on) lets a moving prop carry whoever stands on it. Both live: the next shot, the next tick.
func _bind_props_feel() -> void:
	var destruction := add_cvar("pg_destruction", "1" if game.config.destruction else "0",
		"1 lets shots and blasts break crates, planks and barrels into debris; 0 makes props unbreakable.",
		DotConVar.FLAG_NOTIFY)
	destruction.changed.connect(func(_old: String, value: String) -> void:
		game.config.destruction = value.to_int() != 0
	)

	game.panes_break = game.config.breakable_glass
	var glass := add_cvar("pg_breakable_glass", "1" if game.config.breakable_glass else "0",
		"1 lets shots, blasts and fast impacts break a map's glass; 0 makes it as hard as the walls.",
		DotConVar.FLAG_NOTIFY)
	glass.changed.connect(func(_old: String, value: String) -> void:
		game.config.breakable_glass = value.to_int() != 0
		game.panes_break = game.config.breakable_glass
	)

	var surf := add_cvar("pg_prop_surf", "1" if game.config.prop_surfing else "0",
		"1 lets a moving prop carry whoever stands on it; 0 leaves props still under your feet.",
		DotConVar.FLAG_NOTIFY)
	surf.changed.connect(func(_old: String, value: String) -> void:
		game.config.prop_surfing = value.to_int() != 0
	)


func _cmd_creative(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)

	if player == null:
		ctx.reply("Only a player has a creative mode.")
		return

	var turned := game.set_creative(player.player_id, not player.creative)

	if not turned.ok:
		ctx.reply_error(turned)
		return

	ctx.reply("Creative mode %s." % ("on: your props and you cannot be touched" if player.creative else "off"))


## The roles a world player holds: their admin groups by name, and `admin` / `root`.
func _roles_of(player_id: StringName) -> PackedStringArray:
	var out := PackedStringArray()

	if server == null:
		return out

	var session := server.session_by_userid(_session_of(player_id))

	if session == null:
		return out

	out.append_array(session.groups)

	if not session.permissions.is_empty():
		out.append("admin")

	if session.permissions.has(DotAdminFlags.ROOT):
		out.append("root")

	return out


func _cmd_limits(ctx: DotCmdContext) -> void:
	var who := StringName(ctx.arg(0)) if ctx.arg(0) != "" else &""

	if who == &"" and ctx.session != null:
		who = StringName("u%d" % ctx.session.userid)

	if who == &"" or not game.players.has(who):
		ctx.reply("Usage: pg_limits <player id, e.g. u3>. Players: %s" % ", ".join(
			PackedStringArray(game.players.keys())
		))
		return

	ctx.reply_lines(game.spawn_limits.describe_for(
		who, game.props.group_usage(who), game.constraint_count(who)
	))


func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines(game.describe_lines())

	if _last_spoke != "":
		ctx.reply("last spoke   %s" % _last_spoke)

	for layer in [arena, waves, vote]:
		if layer != null:
			ctx.reply_lines(layer.describe_lines())


func _cmd_services(ctx: DotCmdContext) -> void:
	ctx.reply_lines(services.describe_lines())


func _cmd_arena(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"on":
			set_arena(true)
			ctx.reply("The arena is on: %d fighting." % game.players.size())
		"off":
			set_arena(false)
			ctx.reply("The arena is off. This is a sandbox again.")
		_:
			ctx.reply_lines(arena.describe_lines())


## Turns the arena on or off, and says so to every client through `pg_arena_on`.
func set_arena(on: bool) -> void:
	if arena == null:
		return
	if arena.enabled != on:
		arena.set_enabled(on)
		# A living player watching a living one while they are shooting at each other is a
		# wallhack, and this is the moment it stops being a sandbox.
		spectate.set_fighting(on)
		if on:
			# Everybody already here joins the fight. A match that only admitted people who
			# connected *after* it started would be a match the server's existing players are
			# spectators in, with nothing saying so.
			for id in game.players.keys():
				arena.admit(id, String(id))
	if _arena_on != null and _arena_on.get_bool() != on:
		_arena_on.force_set("1" if on else "0")


# --- The loadout (B) ----------------------------------------------------------

const LOADOUT_COMMAND_SCRIPT := "res://addons/dot_loadout/integrations/dot_loadout_command.gd"

## The B menu's server half (dot-loadout's `DotLoadoutCommand` over the arena's manager), or
## null on a host whose dot-loadout predates it (API 2).
var loadout_command: Object = null

## `pg_arena_on`: whether the arena is on, REPLICATED so a client's B knows whether there is a
## loadout to open (the lead's call: B opens it only in the arena, and says so outside). Also a
## switch: setting it is `pg_arena on/off`.
var _arena_on: DotConVar = null


## The loadout key of session [param session_id]: dot-loadout keys are at least eight long, so
## the player key ("u7") is not one.
static func loadout_key(session_id: int) -> String:
	return "pg-player-%08d" % session_id


func _build_loadout_command() -> void:
	_arena_on = add_cvar("pg_arena_on", "1" if arena.enabled else "0",
		"Whether the arena is on (pg_arena); clients read it to know B has a loadout to open",
		DotConVar.FLAG_REPLICATED)
	if _arena_on != null:
		# A method, never a lambda: a lambda captures this module and the cvar would keep it alive.
		_arena_on.changed.connect(_on_arena_on_changed)
	arena.respawned.connect(func(id: StringName) -> void:
		var _armed: Variant = await _arm_from_loadout(PlaygroundNetBridge.session_of(id)))

	if DotAddonApi.build_level("dot_loadout") < 2 or not ResourceLoader.exists(LOADOUT_COMMAND_SCRIPT) \
			or arena.loadouts == null:
		return
	loadout_command = (load(LOADOUT_COMMAND_SCRIPT) as GDScript).new()
	loadout_command.set(&"manager", arena.loadouts)
	loadout_command.set(&"key_fn", func(ctx: Object) -> String:
		var session: Variant = ctx.get(&"session") if ctx != null else null
		return loadout_key(int((session as Object).get(&"userid"))) if session is Object else "")
	loadout_command.set(&"closed_fn", func(_key: String) -> String:
		return "" if arena.enabled else LOADOUT_ARENA_ONLY)
	loadout_command.set(&"applied_fn", func(_ctx: Object, key: String) -> bool:
		return await rearm_if_allowed(key.trim_prefix("pg-player-").to_int()))
	loadout_command.call(&"bind", self)


func _on_arena_on_changed(_old: String, value: String) -> void:
	set_arena(value.strip_edges() == "1")


## What B says outside the arena, on both ends.
const LOADOUT_ARENA_ONLY := "Loadouts are in the arena."


## Puts the loadout's weapon in [param session_id]'s hands now when they are inside their
## arena spawn protection; otherwise it waits for their next arena spawn. True when it did.
func rearm_if_allowed(session_id: int) -> bool:
	if arena == null or not arena.is_protected(PlaygroundNetBridge._player_key(session_id)):
		return false
	return await _arm_from_loadout(session_id)


## Hands [param session_id] the weapon their loadout names, through the bridge (the shop
## charges as for any weapon; the client adopts it from the WEAPON event). False when there is
## nothing to hand.
func _arm_from_loadout(session_id: int) -> bool:
	if arena == null or arena.loadouts == null or bridge == null or session_id <= 0:
		return false
	var res: DotResult = await arena.loadouts.active_for(loadout_key(session_id))
	if not res.ok:
		return false
	var weapon := (res.value as DotLoadout).item_in(&"primary")
	var id := PlaygroundNetBridge._player_key(session_id)
	if weapon == &"" or not game.players.has(id):
		return false
	bridge._give_weapon(session_id, id, weapon)
	return true


func _cmd_waves(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"on":
			waves.set_enabled(true)
			# Being killed by a wave is what being downed is for, so the two switch
			# together. A separate cvar is an operator who turned the waves on and
			# wonders why nobody is being picked up.
			downs.set_enabled(true)
			ctx.reply("Waves are on, and a player at zero health goes down rather than dying.")
		"off":
			waves.set_enabled(false)
			downs.set_enabled(false)
			ctx.reply("Waves are off, and the map is cleared of them.")
		"clear":
			var gone := waves.spawner.clear_all()
			ctx.reply("Cleared %d." % gone)
		_:
			ctx.reply_lines(waves.describe_lines())


## `pg_spec` — watch somebody else.
##
## A sandbox is the one place where watching is not about being dead: the interesting
## thing on a server like this is usually what somebody else is making, and the answer to
## "what is that noise in the corner" is a camera.
func _cmd_spec(ctx: DotCmdContext) -> void:
	var session := ctx.session

	if session == null:
		ctx.reply("Only a player can watch somebody.")
		return

	var viewer := _player_id(session)

	match ctx.arg(0):
		"", "next":
			var res := spectate.next_target(viewer)
			ctx.reply(
				("Watching %s." % String(spectate.target_of(viewer))) if res.ok
				else res.error.message
			)
		"off", "stop":
			spectate.stop(viewer)
			ctx.reply("Back to your own view.")
		_:
			var wanted := _player_named(ctx.arg(0))

			if wanted == &"":
				ctx.reply("There is nobody called '%s' here." % ctx.arg(0))
				return

			var res := spectate.watch(viewer, wanted)
			ctx.reply(
				("Watching %s." % String(wanted)) if res.ok else res.error.message
			)


## A player id by display name, case-insensitively and by prefix.
##
## What every server in this genre does: `!pg_spec ad` finds Ada. The first match wins
## and the order is the roster's, which is stable — the alternative is refusing an
## ambiguous prefix, and a player who typed two letters and got "be more specific" types
## three letters and gives up.
func _player_named(text: String) -> StringName:
	var wanted := text.strip_edges().to_lower()

	if wanted == "":
		return &""

	for session in server.sessions():
		var name := session.display_name.to_lower()
		if name == wanted or name.begins_with(wanted):
			return _player_id(session)

	for id: Variant in game.players.keys():
		var name := String(id).to_lower()
		if name == wanted or name.begins_with(wanted):
			return StringName(id)

	return &""


## `pg_shop` — turn the price list on, off, or read it.
##
## Off by default, and the cvar is the point: a sandbox where everything is free is a
## sandbox, and one where a jeep costs four hundred credits is a game. Turning one into
## the other because an addon was installed is what this family's rule about cvars
## exists to prevent.
func _cmd_shop(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"on":
			shop.set_enabled(true)
			ctx.reply("The shop is on. Everything has a price now.")
		"off":
			shop.set_enabled(false)
			ctx.reply("The shop is off. Take what you like.")
		"prices":
			if shop.economy == null or shop.economy.shop == null:
				ctx.reply("There is no price list.")
			else:
				ctx.reply_lines(shop.economy.shop.describe_lines())
		_:
			ctx.reply_lines(shop.describe_lines())


## `pg_credits` — read a balance, or hand somebody a few.
func _cmd_credits(ctx: DotCmdContext) -> void:
	var who := ctx.arg(0)

	if who == "":
		var lines := PackedStringArray()
		for id: Variant in game.players.keys():
			lines.append("%-20s %d" % [String(id), shop.balance(StringName(id))])
		if lines.is_empty():
			lines.append("Nobody is here.")
		ctx.reply_lines(lines)
		return

	var target := _player_named(who)

	if target == &"":
		ctx.reply("There is nobody called '%s' here." % who)
		return

	var amount := ctx.arg(1)

	if amount == "":
		ctx.reply("%s has %d." % [String(target), shop.balance(target)])
		return

	var paid := shop.award(target, amount.to_int(), &"admin")
	ctx.reply(
		"%s now has %d (%s%d)."
			% [String(target), shop.balance(target), "+" if paid >= 0 else "", paid]
	)


## `pg_give` — put something in somebody's bag, as the server. It reaches their client as
## the whole bag, like any change the server makes; see [PlaygroundInventoryNet].
func _cmd_give(ctx: DotCmdContext) -> void:
	var target := _player_named(ctx.arg(0))
	var item := StringName(ctx.arg(1))

	if target == &"" or item == &"":
		ctx.reply("pg_give <player> <prop> [count]")
		return

	if game.inventory == null or bridge == null or bridge.inventory_net == null:
		ctx.reply("This server has no inventory.")
		return

	var count := maxi(1, ctx.arg(2).to_int()) if ctx.arg(2) != "" else 1
	var bag := bridge.inventory_net.bag_key(PlaygroundNetBridge.session_of(target))
	var given := game.inventory.give(bag, item, count)

	if not given.ok:
		ctx.reply_error(given)
		return

	ctx.reply("%s now carries %d %s." % [String(target), game.inventory.carries(bag, item), item])


## `pg_inv` — what somebody is carrying, as the server has it.
func _cmd_inv(ctx: DotCmdContext) -> void:
	var target := _player_named(ctx.arg(0))

	if target == &"":
		ctx.reply("pg_inv <player>")
		return

	if game.inventory == null or bridge == null or bridge.inventory_net == null:
		ctx.reply("This server has no inventory.")
		return

	var bag := bridge.inventory_net.bag_key(PlaygroundNetBridge.session_of(target))
	ctx.reply_lines(game.inventory.for_player(bag).describe_lines())


func _cmd_vote(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"open":
			var opened := vote.director.open_vote()

			if opened.ok:
				ctx.reply("Vote opened.")
			else:
				ctx.reply_error(opened)
		"next":
			ctx.reply("Next in rotation: %s" % String(vote.next_in_rotation()))
		_:
			ctx.reply_lines(vote.describe_lines())


func _cmd_achievements(ctx: DotCmdContext) -> void:
	var session := ctx.session

	if ctx.args.size() > 0:
		var found := server.find_sessions(ctx.arg(0), ctx.session)
		session = found[0] if not found.is_empty() else null

	if session == null:
		ctx.reply("Who?")
		return

	var key := PlaygroundPlatform.key_for_session(server, session)
	var listing := progress.achievements.listing(key)

	if listing.is_empty():
		ctx.reply("%s has earned nothing yet." % session.display_name)
		return

	ctx.reply("%s — %d points" % [
		session.display_name, progress.achievements.points_of(key)
	])

	for row in listing:
		var entry: Dictionary = row

		# A secret one that has not been earned is not listed at all. That is what
		# `secret` means, and a listing that named it would be a listing that spoils it.
		if bool(entry.get("secret", false)) and not bool(entry.get("unlocked", false)):
			continue

		ctx.reply("  %s %-24s %s" % [
			"*" if bool(entry.get("unlocked", false)) else " ",
			str(entry.get("name", "")),
			str(entry.get("description", "")),
		])


func _cmd_gag(ctx: DotCmdContext) -> void:
	await _punish(ctx, DotPunishment.Kind.GAG, "gagged")


func _cmd_mute(ctx: DotCmdContext) -> void:
	await _punish(ctx, DotPunishment.Kind.VOICE_MUTE, "muted")


## The shared half of gag and mute.
##
## One function because the only difference is a kind: dot-moderation already models both
## as one record with an expiry, a scope and a revocation, and writing them separately
## would be two chances to forget the duration parsing or the immunity.
func _punish(ctx: DotCmdContext, kind: DotPunishment.Kind, verb: String) -> void:
	if ctx.args.size() < 2:
		ctx.reply("Usage: %s <who> <seconds, 0 for permanent> [reason]" % ctx.command)
		return

	var targets := server.find_sessions(ctx.args[0], ctx.session)

	if targets.is_empty():
		ctx.reply("Nobody matches '%s'." % ctx.args[0])
		return

	if targets.size() > 1:
		# Refused rather than applied to all of them: `@me` and a name prefix both match
		# more than one person, and a mute applied to four people by accident is a thing
		# an operator finds out about from the four people.
		ctx.reply("'%s' matches %d people. Be more specific." % [
			ctx.args[0], targets.size()
		])
		return

	var session := targets[0]
	var seconds := maxi(0, ctx.arg_int(1))
	var reason := ctx.rest(2) if ctx.args.size() > 2 else "No reason given."

	var issued: DotResult = await services.moderation.issue(
		kind,
		DotPunishmentSubject.for_uid(session.uid()),
		reason,
		ctx.caller_label(),
		seconds,
		ctx.immunity
	)

	if not issued.ok:
		ctx.reply("Refused: %s" % issued.error.message)
		return

	ctx.reply("%s %s: %s" % [
		session.display_name, verb, DotPunishment.format_duration(seconds)
	])

	# Told to the person it happened to, on the channel they are reading. A mute nobody is
	# told about is a microphone that has stopped working, which is what they report.
	services.chat.notice(
		session.peer_id,
		(issued.value as DotPunishment).player_message(),
		PlaygroundServices.CHANNEL_ALL
	)


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
