extends "res://examples/dedicated_part2.gd"
## Boots a real [DotServer], loads the playground module into it, and runs the
## commands an operator and an admin would actually type.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]
##
## The join between the game and the server: the console, the module lifecycle, the permission
## flags, and `sv_tickrate` all the way to a record's `tick_rate`. Nothing here opens a socket.

const PgTestPorts := preload("test_ports.gd")


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DotLog.signals().record.connect(_on_log_record)
	_run.call_deferred()


## An ERROR from the stats layer would otherwise scroll past and leave a stat dead with every check green.
func _on_log_record(rec: Dictionary) -> void:
	if int(rec.get("level", 0)) >= DotLog.Level.ERROR and String(rec.get("channel", "")).begins_with("stats"):
		_stats_errors.append(str(rec.get("message", rec)))


func _run() -> void:
	print("playground — dedicated server")
	print("")

	# The module turns on saving what the wave NPCs learn of each map, as a real server
	# should — so a run here would leave a file the next run's NPCs patrol by. Cleared before
	# and after, so no run is trained by the last.
	_forget_learned_heat()

	var probe: Array = []
	if not _is_exit_probe():
		probe = await _run_exit_probe()

	DotPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()

	if game != null:
		_test_tickrate_reaches_the_timer()
		await _test_map_commands()
		_test_timer_commands()
		_test_prop_commands()
		_test_permissions()
		_test_services()
		await _test_moderation()
		_test_arena()
		await _test_arena_loadout()
		_test_waves()
		_test_shop()
		_test_spectating()
		await _test_downed()
		await _test_progress()
		_test_query()
		_test_stats_report()
		_test_vote()
		_test_map_rotation_file()
		_test_identity()
		await _test_live_tools()
		await _test_blind_and_beacon()
		await _test_loading_cover()
		_test_creative()
		_test_noblock()
		_test_saved_builds()
		_test_inventory_commands()
		_test_welcome_waits_for_ready()
		if _timer_linked():
			await _test_records_follow_the_account()
		_test_disconnect_is_handled()
		await _test_module_unloads_cleanly()
		await _test_a_module_reload()
		_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)

	# The copy of this suite that the exit probe runs does not run the probe itself.
	var sections := SECTIONS - (1 if _is_exit_probe() else 0) + (TIMER_SECTIONS if _timer_linked() else 0)
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0) + (TIMER_CHECKS if _timer_linked() else 0)

	_check(_stats_errors.is_empty(), "the stats layer logged no error", str(_stats_errors))
	_check(PlaygroundProgress.stats_schema().validate().ok, "the stats schema, hitzones included, validates")

	_forget_learned_heat()

	_report_sections(_sections_done, _sections_done, sections, checks)


## Takes the server down before quitting, so nothing is left for the engine to tear out
## from under itself — whatever is alive at that point is reported leaked, which reads as
## a reference cycle in the game and is a test that stopped one line early.
func _shut_down() -> void:
	if server == null:
		return

	if server.modules != null:
		server.modules.unload_all()

	server.shutdown("the dedicated test is finished")

	for _i in range(10):
		await get_tree().process_frame

	for node: Node in [game, platform, get_node_or_null("QueryHost"), server]:
		if is_instance_valid(node):
			remove_child(node)
			node.free()

	game = null
	platform = null
	server = null
	await get_tree().process_frame


func _boot() -> void:
	print("booting a dedicated server")

	# The tick rate is set the way an operator sets it: a line in a config file the server execs
	# at boot, not by assigning `config.tickrate` (a `server.cfg` beats anything set in code).
	#
	# `startup_config`, not `autoexec_config` (`sv_tickrate` is FLAG_STARTUP_ONLY). 100, not the default 128,
	# so the same number on both sides cannot pass with the chain disconnected.
	var cfg_path := "%s/server.cfg" % SERVER_DIR
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)

	if cfg == null:
		_check(false, "the test config file could be written", cfg_path)
		return

	cfg.store_line("// written by examples/dedicated.gd")
	cfg.store_line("sv_tickrate 100")
	cfg.store_line("hostname \"playground test\"")
	cfg.close()

	var config := DotServerConfig.new()
	config.startup_config = cfg_path
	# And nothing in the after-the-listener file, so the test is unambiguous about
	# which one set it.
	config.autoexec_config = ""
	config.hostname = "playground test"
	config.max_players = 16
	config.hibernate_when_empty = false
	config.rcon_password = ""
	# On, and it used to be off. This game ships `PlaygroundBrowser` -- a real server
	# list with sources, filters and favourites -- against a server that answered
	# nothing, so the half being exercised here was the half that already worked.
	config.query_enabled = true

	# Probed free, so two suites never collide.
	config.port = PgTestPorts.free_port(2)
	config.query_port = config.port + 1
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	# Off: nobody is at the keyboard, and the exit probe's copy of this suite inherits
	# whatever stdin this one has — a reader thread blocked on a terminal is a process that
	# never exits.
	# Kept after dot-server 5f46687, which no longer reads a pipe unless `stdin_console_pipes`
	# is on: a terminal is still read, and a suite takes no commands from either.
	config.stdin_console_enabled = false

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)

	# Answering a query is its own addon, and a server only answers if a host is plugged
	# in. Added before the server finishes booting so the listener opens with it.
	var query_host := DotQueryHost.new()
	query_host.name = "QueryHost"
	query_host.app_url = APP_URL
	query_host.server_ref = DotNodeRef.of_path(NodePath("../Server"))
	add_child(query_host)

	# `auto_boot` makes `_ready` await `boot()`, which opens a listener and reads the
	# config's environment and command-line layers — so this takes several frames and
	# a single `process_frame` catches it half-built.
	for _i in range(60):
		await get_tree().process_frame

		if server.state == DotServer.State.RUNNING:
			break

	_check(
		server.state == DotServer.State.RUNNING,
		"the server boots",
		DotServer.State.keys()[server.state]
	)
	_check(server.console != null, "the server has a console")
	_check(
		Engine.physics_ticks_per_second == 100,
		"and sv_tickrate reached the engine's physics rate",
		"%d" % Engine.physics_ticks_per_second
	)

	# The game, built AFTER the server so it reads the rate the server has set —
	# which is the ordering a real deployment has, because the server is what boots
	# first.
	var pg_config := PlaygroundConfig.new()
	pg_config.records_directory = ""
	pg_config.initial_map = &"pg_flatgrass"
	pg_config.map_seconds = 0.0

	game = Playground.new()
	game.name = "Playground"
	game.config = pg_config
	add_child(game)

	# Two frames: the playground's own `_ready` awaits its first map change.
	await get_tree().process_frame
	await get_tree().process_frame

	_check(game.maps.current != null, "the game loaded a map",
		String(game.maps.current.id) if game.maps.current else "-")

	# [b]The identity half, before the modules.[/b] [DotPlatformModule] refuses to load
	# without a [DotPlatformHub] in the registry, and building the hub is awaited work —
	# which is why it is here, in the application, rather than inside a module's
	# `_module_load`, which dot-server's module host does not await.
	platform = PlaygroundPlatform.new()
	platform.name = "Identity"
	platform.directory = "%s/identity" % SERVER_DIR
	add_child(platform)

	var identity: DotResult = await platform.setup()
	_check(identity.ok, "profiles and avatars are up", str(identity.error))

	var platform_module: DotResult = await server.modules.load_module(
		"res://addons/dot_platform/dot_platform_module.gd"
	)
	_check(platform_module.ok, "the platform module loads", str(platform_module.error))

	# Into this run's own directory. See [constant SERVER_DIR].
	#
	# Loaded here, not preloaded at the top: a preload would load the module long before the host
	# does, and script load order decides whether Godot 4.7.2 leaks them at exit.
	(load("res://game/playground_module.gd") as GDScript).set(
		"punishments_path", "%s/punishments.json" % SERVER_DIR
	)

	var loaded: DotResult = await server.modules.load_module(
		"res://game/playground_module.gd"
	)

	_check(loaded.ok, "the playground module loads into the server",
		loaded.error.message if not loaded.ok else "")

	if not loaded.ok:
		return

	# [b]The store, and that it is empty.[/b] The second is what says the first worked on
	# THIS run: a path that is right and a directory that was not wiped is a suite carrying
	# the last run's gag into this one.
	var services: PlaygroundServices = _module().get("services")
	var moderation: DotModerationManager = services.moderation if services != null else null
	_check(services != null and services.punishments_path.begins_with(SERVER_DIR),
		"punishments go to this run's own store, not the one a real server enforces",
		services.punishments_path if services != null else "no services")
	_check(moderation != null and moderation.count() == 0,
		"and it starts empty, so nothing a previous run did is in it",
		"%d records" % moderation.count() if moderation != null else "no moderation")

	_check(
		server.console.find_command("pg_status") != null,
		"and registers its commands"
	)
	_check(
		server.console.find_cvar("pg_map_seconds") != null,
		"and its cvars"
	)


func _test_map_commands() -> void:
	print("map commands")

	var listed := _run_command("pg_map")
	_check(_said(listed, "pg_flatgrass"), "pg_map lists the maps", str(listed))

	var missing := _run_command("pg_map not_a_map")
	_check(_said(missing, "no map matches"), "and refuses one that is not there")

	_run_command("pg_map pg_generated")

	# The command awaits a map change, so it lands over the next few frames.
	for _i in range(10):
		await get_tree().process_frame

	_check(
		game.maps.current.id == &"pg_generated",
		"pg_map changes map",
		String(game.maps.current.id)
	)

	# The map menu's server half (M): the owner's flag changes the map now, anybody else
	# gets a nomination and a rock-the-vote. Contexts as dot-server makes them for a chat line.
	var menu_half: Object = _module().get("vote").get("commands").get("map_menu")
	_check(menu_half != null and server.console.find_command("mapmenu") != null
		and server.console.find_cvar("sv_map_menu_flag").get_string() == "generic"
		and (menu_half.get("change_fn") as Callable).is_valid(),
		"the map menu is there, staff-only by default, changing the map now")
	var staff := DotCmdContext.new()
	staff.source = DotCmdContext.Source.CHAT
	staff.permissions = PackedStringArray(["generic"])
	var player := DotCmdContext.new()
	player.source = DotCmdContext.Source.CHAT
	var offered: Dictionary = menu_half.call("offer", player)
	_check((offered["maps"] as Array).size() > 1 and not bool(offered["allowed"]) and bool(offered["vote"]),
		"a player is offered every map, as a vote")
	var target: StringName = &""
	for row: Dictionary in offered["maps"]:
		if not bool(row["current"]):
			target = StringName(str(row["id"]))
			break
	var menu_changed: Dictionary = await menu_half.call("choose", staff, target)
	_check(bool(menu_changed["ok"]) and game.maps.current.id == target, "staff choosing one changes the map on the spot",
		"%s: %s" % [target, menu_changed.get("text", "")])

	# The plain name, which is dot-map's now. It used to be dot-server's and it changed the
	# GAME -- so on this server, one game and several maps, `map` did the one thing an
	# operator typing it did not mean.
	var plain := _run_command("map")
	_check(_said(plain, "pg_generated"), "`map` lists the maps", str(plain))

	# The menu above moved off pg_generated, so this is a real change.
	_run_command("map pg_generated")
	for _i in range(10):
		await get_tree().process_frame
	_check(
		game.maps.current.id == &"pg_generated",
		"and `map <id>` changes it, through the game's own reset rather than the session",
		String(game.maps.current.id)
	)

	# A custom map from playlot-maps, through the same catalogue and the same command.
	_run_command("map pgc_quarry")
	for _i in range(10):
		await get_tree().process_frame
	var built: Node = game.maps.world
	_check(
		game.maps.current != null and game.maps.current.id == &"pgc_quarry"
			and built != null and built.has_method("configure_doc") and str(built.get("doc").get("id", "")) == "pgc_quarry"
			and built.get_child_count() > 20,
		"a custom map loads through the catalogue, built from its document",
		"%s, %d nodes" % [String(game.maps.current.id) if game.maps.current != null else "none", built.get_child_count() if built != null else -1]
	)
	_run_command("map pg_flatgrass")
	for _i in range(10):
		await get_tree().process_frame

	var map_command: DotConCommand = server.console.find_command("map")
	_check(map_command != null, "`map` is registered")
	_check(
		map_command != null and map_command.chat_allowed,
		"and IS typable in chat here, because a sandbox has no ranked run for it to destroy"
	)
	_check(
		server.console.find_command("game") != null,
		"while `game` is what changes the game, which is what dot-server's `map` used to do"
	)
	_check(
		server.console.find_command("mapinfo") != null,
		"and `mapinfo` answers what `nextmap` and `timeleft` would, without taking dot-vote's names"
	)

	var next := _run_command("pg_nextmap")
	_check(_said(next, "next"), "pg_nextmap says what plays next", str(next))

	# The ballot's clock, which is the one that ends a map on a server with a vote. It
	# extended the map session's, which on this server decides nothing.
	var clock := (_module().get("vote") as PlaygroundVote).director.clock
	var before := clock.remaining

	var extended := _run_command("pg_extend 300")
	_check(_said(extended, "extended"), "pg_extend extends the map", str(extended))
	_check(
		is_equal_approx(clock.remaining, before + 300.0),
		"and adds the time to the clock that ends it",
		"%.0f -> %.0f" % [before, clock.remaining]
	)

	# From the server console there is no player, so rocking the vote is refused
	# rather than counted for nobody.
	var rocked := _run_command("pg_rtv")
	_check(
		_said(rocked, "only a player"),
		"and the console cannot rock the vote for nobody",
		str(rocked)
	)
	_section_done()


func _test_services() -> void:
	print("")
	print("chat and voice")

	var services: PlaygroundServices = _module().get("services")

	_check(services != null, "the services are up")
	_check(
		services.chat != null and services.chat.channel_ids().size() == 4,
		"with four chat channels (%d)"
			% (services.chat.channel_ids().size() if services.chat != null else -1)
	)
	_check(
		services.chat.channel(PlaygroundServices.CHANNEL_NEAR).scope
			== DotChatChannel.Scope.RADIUS,
		"one of which is a radius, so a build is a conversation"
	)
	_check(
		services.chat.channel(PlaygroundServices.CHANNEL_NEAR).backlog == 0,
		"and has no backlog, because a line said quietly beside a build must not be "
		+ "replayed to a stranger who was not standing there"
	)

	# [b]THE join.[/b] dot-chat consults a `dot_mute_source` and dot-moderation publishes
	# one, and neither imports the other — so the only thing that makes a gag work is that
	# something is registered under that name.
	_check(
		DotRegistry.has(DotModerationManager.MUTE_SERVICE),
		"a mute source is registered, which is the only thing that makes a gag work"
	)
	_check(
		DotRegistry.has(DotModerationManager.BAN_SERVICE),
		"and a ban source, which dot-server's admission check consults"
	)

	# [b]Voice is the whole server here, and the near channel is text's.[/b] The other two
	# games chose differently and all three are right for what they are — a lobby you can
	# see all of, an arena bigger than a screen, and a sandbox that is both at once.
	_check(
		services.voice != null
			and services.voice.default_channel == DotVoiceRouter.Channel.ALL,
		"voice reaches the whole server, and the near channel is text's"
	)
	_check(
		services.voice.config.format_fingerprint()
			== PlaygroundServices.voice_config().format_fingerprint(),
		"and its format is the one a client builds from the same file"
	)

	# The operator's switch: registered by the module, replicated so clients hide their key,
	# and enforced on the router.
	var voice_cvar: DotConVar = server.console.find_cvar("sv_voice_enable")
	_check(voice_cvar != null and DotConsole.is_replicated(voice_cvar),
		"sv_voice_enable is registered and replicated to clients")
	var off_enabled := true
	if voice_cvar != null:
		var _off := voice_cvar.set_value("0")
		off_enabled = services.voice.enabled
		var _on := voice_cvar.set_value("1")
	_check(not off_enabled and services.voice.enabled, "and turns the router off and on")

	# dot-server's own chat is cancelled rather than run beside the router.
	var legacy := server.events.fire("player_chat", {
		"userid": 1, "name": "Nobody", "text": "hello", "team_only": false,
	})
	_check(
		legacy.cancelled,
		"dot-server's own chat broadcast is cancelled, so there is exactly one path"
	)

	# The wire, both directions. Every encoder against its decoder, because the two have
	# to be exact inverses and nothing can check that for you.
	var line := DotChatMessage.make(
		DotChatMessage.Kind.SAY, PlaygroundServices.CHANNEL_NEAR, "7", "Ada", "over here"
	)
	line.seq = 3

	var wire := line.to_dictionary()
	wire["x"] = {"p": 7}

	var back := PlaygroundEvents.read_chat(
		DotNetReader.new(PlaygroundEvents.write_chat(wire))
	)
	_check(bool(back["ok"]), "a chat line round-trips")
	_check(String(back["m"]) == "over here", "with the text")
	_check(
		String(back["c"]) == String(PlaygroundServices.CHANNEL_NEAR),
		"and the channel it was said on"
	)
	_check(
		typeof(back.get("x")) == TYPE_DICTIONARY
			and int((back["x"] as Dictionary).get("p", 0)) == 7,
		"and who said it, which is the one meta field this wire carries"
	)

	# Every value of the enum, because dot-moderation's bug was exactly one value with no
	# case — and the two ends of a serialisation are as capable of never meeting as the
	# two ends of a wire.
	var kinds_ok := true

	for kind in DotChatMessage.Kind.values():
		var one := DotChatMessage.make(
			kind as DotChatMessage.Kind, PlaygroundServices.CHANNEL_ALL, "1", "Ada", "x"
		)
		var round_trip := PlaygroundEvents.read_chat(
			DotNetReader.new(PlaygroundEvents.write_chat(one.to_dictionary()))
		)

		if String(round_trip["k"]) != one.kind_name():
			kinds_ok = false

	_check(kinds_ok, "every chat kind survives the wire, not just the common one")
	_section_done()


## Health, weapons that hurt, and a round.
func _test_arena() -> void:
	print("")
	print("the arena")

	var arena: PlaygroundArena = _module().get("arena")

	_check(arena != null, "the arena is built")
	_check(
		not arena.enabled,
		"and is OFF by default",
		"a server where somebody can shoot you while you are building is a different "
		+ "server, and an addon must not turn one into the other silently"
	)

	# The schema, which is what a dedicated server validates a loadout against without
	# loading a single model.
	var schema := arena.loadouts.schema
	var problems := schema.validate()
	_check(problems.ok, "the loadout schema validates", str(problems.error))
	_check(
		schema.slot(&"primary") != null and schema.slot(&"primary").required
			and schema.slot(&"primary").default_item != &"",
		"and its required slot has a default",
		"a required slot with none cannot be repaired, so a player who has never "
		+ "chosen could never spawn"
	)

	# [b]Entitlements default to nothing, and that default is the important one.[/b] A
	# server that granted everything would work perfectly in every test, ship, and
	# quietly be a game where every unlock is free — which nobody reports as a bug.
	var free_only := schema.choices_for(&"primary", DotLoadoutEntitlements.none())
	var everything := schema.choices_for(&"primary", DotLoadoutEntitlements.everything())
	_check(
		everything.size() > free_only.size(),
		"and something is locked (%d free of %d)" % [free_only.size(), everything.size()]
	)

	_run_command("pg_arena on")
	_check(arena.enabled, "the console turns it on")

	arena.admit(&"u900", "Alice")
	arena.admit(&"u901", "Bob")

	var alice := arena.health_of(&"u900")
	_check(alice != null and alice.health == PlaygroundArena.MAX_HEALTH,
		"somebody admitted starts on full health")

	# [b]Spawn protection is counted in ticks, and this is what it is for.[/b] A player
	# shot on the tick they appear has not had a game.
	_check(alice.is_protected(0), "and is protected on the tick they appear")

	# [b]Through the arena's own tick, not the health's.[/b] Spawn protection is checked
	# by `DotHealth.apply` against the tick the MANAGER last saw, and ticking only the
	# health leaves the manager on zero — so the protection reads as expired everywhere
	# except in the one place that decides. A test that ticked the health alone would pass
	# its own assertion and then be refused by the thing it was setting up.
	for step in range(game.tick_rate * 5):
		arena.tick(step, 1.0 / float(game.tick_rate))

	_check(
		not alice.is_protected(arena._tick),
		"and is not, five seconds later"
	)

	var hit := arena.hurt(&"u901", &"u900", 30.0, 5.0)
	_check(hit != null and not hit.refused, "a hit lands", str(hit))
	_check(
		alice.health < PlaygroundArena.MAX_HEALTH,
		"and takes health off (%.0f)" % alice.health
	)

	# Falloff. [b]The whole reason it is worth having[/b]: a shot from across the map has
	# to be worth less than one at point blank, or range is not a decision.
	var far := arena.hurt(&"u901", &"u900", 30.0, 200.0)
	_check(
		far != null and far.amount < hit.amount,
		"and one from across the map does less (%.1f against %.1f)"
			% [far.amount if far != null else -1.0, hit.amount]
	)

	# Self damage is on and scaled, because launching a boulder at your own feet hurting
	# you is the joke the weapon exists for — and hurting you as much as somebody else is
	# not.
	var own := arena.hurt(&"u900", &"u900", 30.0, 1.0)
	_check(
		own != null and not own.refused and own.amount < 30.0,
		"self damage lands and is scaled down (%.1f)"
			% (own.amount if own != null else -1.0)
	)

	# --- How a dead body falls: picked here, from the server's own weights ---
	#
	# Armed by deciding nothing in `_on_killed` (null) and by leaving the cvars unbound in
	# the module (the replicated check fails and the pick is a draw over the stock weights).
	var weights := server.console.find_cvar("sv_ragdoll_reactions")
	_check(weights != null and weights.has_flag(DotConVar.FLAG_REPLICATED),
		"the sv_ragdoll* set is bound, replicated, because the clients draw the bodies")
	var carol := game.add_player(&"u902", "Carol")
	arena.admit(&"u902", "Carol")
	var start := arena._tick
	for step in range(game.tick_rate * 5):
		arena.tick(start + step + 1, 1.0 / float(game.tick_rate))
	var _only := _run_command("sv_ragdoll_reactions limp=0,crumple=0,face_plant=1")
	var killed: Array = []
	var on_killed := func(victim: StringName, _killer: StringName) -> void: killed.append(victim)
	arena.player_killed.connect(on_killed)
	var fatal := arena.hurt(&"u901", &"u902", 500.0, 2.0)
	_check(fatal != null and fatal.lethal and carol != null and carol.death != null
			and carol.death.reaction == DotPlayerDeathReactions.FACE_PLANT,
		"a kill picks the body's fall on the server, from sv_ragdoll_reactions",
		str(carol.death.describe()) if carol != null and carol.death != null else "no death")
	# A downed player bleeding out is a death too, which nothing told a client before: it
	# crumples where it lay, and the arena announces it like any other.
	var _stock := _run_command("sv_ragdoll_reactions limp=4,headshot_launch=6,power_launch=8,face_plant=1.5,crumple=2.5")
	var downs: Object = _module().get("downs")
	killed.clear()
	if downs != null:
		downs.died.emit(&"u902", &"bleed_out")
	arena.player_killed.disconnect(on_killed)
	_check(killed == [&"u902"] and carol.death != null
			and carol.death.reaction == DotPlayerDeathReactions.CRUMPLE,
		"and a bleed-out crumples, announced like any death", str(killed))
	arena.release(&"u902")
	game.remove_player(&"u902")

	arena.release(&"u900")
	arena.release(&"u901")
	_run_command("pg_arena off")
	_check(not arena.enabled, "and the console turns it off again")
	_section_done()


func _test_shop() -> void:
	print("")
	print("the shop")

	var shop: PlaygroundShop = _module().get("shop")

	_check(shop != null, "the shop is built")

	if shop == null:
		return

	_check(
		not shop.enabled,
		"and is OFF by default",
		"a sandbox where everything is free is a sandbox and one where a jeep costs "
		+ "four hundred credits is a game; an addon must not turn one into the other"
	)

	# Free while it is off, and that is what makes it a layer a caller can consult
	# unconditionally rather than a branch at every call site.
	var free := shop.may_have(&"nobody", &"pg_crate")
	_check(free.ok, "everything is free while it is off", str(free.error))

	var prices := _run_command("pg_shop prices")
	_check(prices.size() > 3, "the price list can be read", "%d lines" % prices.size())

	# Derived from the catalogue rather than authored, which is why there are as many
	# entries as there are props and weapons.
	var expected := 0
	if game.props != null and game.props.catalogue != null:
		expected += game.props.catalogue.props.size()
	expected += game.weapons.size()
	_check(
		shop.economy.shop.items.size() == expected,
		"and has one entry per prop and weapon the game ships",
		"%d against %d" % [shop.economy.shop.items.size(), expected]
	)

	var _on := _run_command("pg_shop on")
	_check(shop.enabled, "it turns on")

	var buyer := &"shopper"
	shop.on_player_added(buyer)
	_check(
		shop.balance(buyer) == PlaygroundShop.START_CREDITS,
		"a player starts with credits",
		str(shop.balance(buyer))
	)

	# Something cheap, then everything, then something at all.
	var cheapest := shop.economy.shop.for_team(1)[0]
	var bought := shop.charge(buyer, cheapest.id)
	_check(bought.ok, "and can buy the cheapest thing", str(bought.error))
	_check(
		shop.balance(buyer) == PlaygroundShop.START_CREDITS - cheapest.price,
		"which costs what it says",
		str(shop.balance(buyer))
	)

	var _spent := shop.award(buyer, -shop.balance(buyer), &"test")
	var refused := shop.charge(buyer, cheapest.id)
	_check(
		not refused.ok,
		"and cannot buy anything with nothing"
	)
	_check(
		refused.error.message.contains("short"),
		"with a message that says how short they are",
		refused.error.message
	)

	shop.on_wave_kill(buyer)
	_check(
		shop.balance(buyer) == PlaygroundShop.WAVE_KILL,
		"killing something the director sent pays",
		str(shop.balance(buyer))
	)

	var _off := _run_command("pg_shop off")
	_check(not shop.enabled, "and it turns off again")
	_check(
		shop.may_have(buyer, cheapest.id).ok,
		"after which everything is free again even with an empty account"
	)
	_section_done()

