extends Node

const Playground := preload("../game/playground.gd")
const PlaygroundArena := preload("../game/playground_arena.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundDowns := preload("../game/playground_downs.gd")
const PlaygroundEvent := preload("../game/net/playground_event.gd")
const PlaygroundEvents := preload("../game/net/playground_events.gd")
const PlaygroundNetBridge := preload("../game/net/playground_net_bridge.gd")
const PlaygroundRequest := preload("../game/net/playground_request.gd")
const PlaygroundPlatform := preload("../game/playground_platform.gd")
const PlaygroundProgress := preload("../game/playground_progress.gd")
const PlaygroundServices := preload("../game/playground_services.gd")
const PlaygroundShop := preload("../game/playground_shop.gd")
const PlaygroundSpectate := preload("../game/playground_spectate.gd")
const PlaygroundVote := preload("../game/playground_vote.gd")
const PlaygroundWaves := preload("../game/playground_waves.gd")

## Boots a real [DotServer], loads the playground module into it, and runs the
## commands an operator and an admin would actually type.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]
##
## [b]This is the seam the family's own notes say is never run.[/b] The playground's
## other suite exercises the joins between the gameplay addons; this one exercises the
## join between the game and the server — the console, the module lifecycle, the
## permission flags, and the tick rate travelling from `sv_tickrate` all the way to a
## record's `tick_rate` field.
##
## Nothing here opens a socket. A dedicated server that never accepts a client is
## still a dedicated server as far as its console, its cvars and its modules are
## concerned, and those are what this is about.

## Sections that ran to their last line, and the checks they ran between them.
##
## [b]Both, because either alone reports a healthy run with checks missing.[/b] A runtime
## error inside a section aborts that function and not the run, so the checks after it
## never happen and the "0 failed" at the bottom says nothing about them. The section
## counter catches a section that stopped; the total catches the one shape it cannot — a
## section that aborted AFTER announcing itself, which is how dot-settings reported "8
## sections, 63 passed, 0 failed" with eight checks missing. See docs/testing.md.
##
## This suite had neither until 2026-09-24. Each section calls [method _section_done] as
## its last line; an early `return` after a failed check skips it deliberately, because a
## section that stopped early did not do what it says.
const SECTIONS := 27
const CHECKS := 246

## Everything this run writes, and it is deleted on the way in and on the way out.
##
## [b]A suite that writes to `user://` is a suite whose result depends on the last run.[/b]
## This one wrote the real punishment store, the server's ban and admin files, its audit log
## and an identity directory at their defaults, so every run appended to them: 352
## punishments in the store a real server enforces, and a gag against `uid-pg-test` every
## time. The achievements half of this already failed once on an unchanged tree.
const SERVER_DIR := "user://pg_dedicated"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _sections_done := 0

var server: DotServer = null
var game: Playground = null
var platform: PlaygroundPlatform = null

## The app's URL segment on the website, which is this game's code name.
##
## Display only — a listing prints it to say which game this is, and nothing treats it as
## proof.
const APP_URL := "playground"


## The loaded module, looked up rather than kept.
##
## [b]Looked up every time, because `_test_module_unloads_cleanly` unloads it.[/b] A field
## holding it would be a freed object the moment that section ran, and every section after
## it would be testing a use-after-free rather than the thing it names.
##
## Typed as [DotModule] rather than as its own class, because `playground_module.gd` has
## **no `class_name`** — it is loaded by path, which is the shape a module delivered in a
## dot-cloud pack must have. Its fields come back through `get()` for the same reason.
func _module() -> DotModule:
	return server.modules.get_module("playground")


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


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
		_test_zone_workflow()
		_test_prop_commands()
		_test_permissions()
		_test_services()
		await _test_moderation()
		_test_arena()
		_test_waves()
		_test_shop()
		_test_spectating()
		await _test_downed()
		await _test_progress()
		_test_query()
		_test_vote()
		_test_identity()
		await _test_live_tools()
		await _test_blind_and_beacon()
		_test_creative()
		_test_saved_builds()
		_test_inventory_commands()
		_test_welcome_waits_for_ready()
		_test_disconnect_is_handled()
		await _test_module_unloads_cleanly()
		_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)

	# The copy of this suite that the exit probe runs does not run the probe itself.
	var sections := SECTIONS - (1 if _is_exit_probe() else 0)
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	_forget_learned_heat()

	print("")
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [
		_passed, _failed, _sections_done, sections
	])

	for line in _failures:
		print("  FAIL  %s" % line)

	if _sections_done != sections:
		print("ERROR: %d of %d sections ran to their last line." % [_sections_done, sections])
		get_tree().quit(1)
		return

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, checks
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


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


## The last line of every section. See [constant SECTIONS].
func _section_done() -> void:
	_sections_done += 1


## The server half of this game's own server browser.
##
## [b]`PlaygroundBrowser` has existed for as long as this client has, and nothing in this
## repository could answer it.[/b] The interesting part of a sandbox's listing row is not
## the map: it is which of `pg_arena`, `pg_waves` and `pg_shop` are on, because each turns
## this into a different server and all three default to off.
func _test_query() -> void:
	print("")
	print("[a server browser's half]")

	_check(server.query_source != null, "the server has a query source to contribute to")

	var module := _module()

	if module == null:
		_check(false, "the module is loaded")
		return

	var snapshot := DotQuerySnapshot.new()

	for provider in module._query_providers:
		provider.call("_contribute", snapshot)

	# Through `get()`, because this module has no `class_name` — the shape a module
	# delivered in a dot-cloud pack must have. Same reason `_module()` is typed DotModule.
	var joined: Dictionary = module.get("_joined")
	var arena: Object = module.get("arena")

	_check(snapshot.game.has("map"), "the query says what map is loaded")
	_check(
		game.maps.current != null and server.games.reported_map() == String(game.maps.current.id),
		"and the query's own map field, which A2S answers with, names it rather than the content id",
		server.games.reported_map()
	)
	_check(
		int(snapshot.game.get("players", -1)) == joined.size(),
		"and how many people are on it",
		str(snapshot.game.get("players", -1))
	)
	_check(
		snapshot.game.has("arena") and snapshot.game.has("waves")
			and snapshot.game.has("shop"),
		"and which of the three cvars that change the game are on"
	)
	# Not "is true": the point is that the row follows the cvar rather than restating a
	# default, so it is asserted against the subsystem's own answer.
	_check(
		bool(snapshot.game.get("arena", not arena.enabled)) == arena.enabled,
		"and the arena flag is the arena's own state"
	)
	_check(
		int(snapshot.game.get("props", -1)) == game.props.world_count(),
		"the prop count is the spawner's own rather than a second tally",
		str(snapshot.game.get("props", -1))
	)
	_section_done()


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


## Runs a console command as the local console and returns what it replied.
##
## [b]Through a reply sink captured in an [Array], not by reading the template's own
## output.[/b] Two reasons, and both are traps the family's notes already name:
## [method DotConsole.execute] builds a FRESH context from the template and copies
## only the sink, so the template's `output` stays empty; and a GDScript lambda
## captures by value, so a [PackedStringArray] appended to inside one is unchanged
## outside it. An [Array] is a reference and is not.
func _forget_learned_heat() -> void:
	var dir := "user://npc_heat"

	if not DirAccess.dir_exists_absolute(dir):
		return

	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/" + file))

	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []

	var template := DotCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)

	server.console.execute(line, template)

	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.to_lower().contains(text.to_lower()):
			return true
	return false


# --- Boot ------------------------------------------------------------------

func _boot() -> void:
	print("booting a dedicated server")

	# The tick rate is set the way an operator actually sets it: a line in a config
	# file the server execs at boot.
	#
	# [b]Not by assigning `config.tickrate`, and that is the point of doing it this
	# way.[/b] A `server.cfg` beats anything set in code, which is correct and is
	# also exactly the trap this family has hit before: dot-server's own self-test
	# once asserted a cvar value that the addon's shipped `server.cfg` had already
	# overridden. Testing the file path tests what an operator will experience.
	#
	# [b]`startup_config`, not `autoexec_config`.[/b] `sv_tickrate` is
	# FLAG_STARTUP_ONLY — a live server cannot re-negotiate its tick rate — and
	# dot-server execs `server.cfg` BEFORE the listener for exactly that reason,
	# while `autoexec.cfg` runs after and would have it refused. Putting the tick
	# rate in the wrong one of the two is the mistake this test would otherwise be
	# making silently.
	#
	# 100, deliberately not the project's own default of 128: the whole point of the
	# chain below is that the SERVER decides, so a test using the same number on both
	# sides would pass with the chain disconnected.
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

	# A port nothing else on a developer's machine is likely to be holding, and a boot
	# that failed on a busy 27015 would look like the module being broken.
	config.port = 28765
	config.query_port = 28766
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
	pg_config.initial_map = &"pg_surf_intro"
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
	# Through the script, loaded here, rather than a `preload` at the top of this file: a
	# preload would load the module when this scene loads, long before the host does, and
	# the order scripts load in is what decides whether Godot 4.7.2 leaks them at exit. See
	# [method _run_exit_probe]. This is the order a deployed server has.
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


func _test_tickrate_reaches_the_timer() -> void:
	print("sv_tickrate reaches the record")

	# The chain, end to end and in one test, because every link in it is silent when
	# it breaks: an operator writes `sv_tickrate 100`; dot-server writes
	# `Engine.physics_ticks_per_second`; the playground reads it; the timer manager
	# adopts it; and it lands on the record. A timer counting 128 a second on a
	# server stepping 100 reports every run 28% long, and nothing about the run
	# looks unusual.
	_check(
		server.console.get_int("sv_tickrate") == 100,
		"server.cfg set sv_tickrate to 100",
		"%d" % server.console.get_int("sv_tickrate")
	)
	_check(
		Engine.physics_ticks_per_second == 100,
		"the engine steps at 100"
	)
	_check(
		game.tick_rate == 100,
		"the game counts at 100",
		"%d" % game.tick_rate
	)
	_check(
		game.timers.tick_rate == 100,
		"the timer counts at 100",
		"%d" % game.timers.tick_rate
	)
	_check(
		game.timers.tick_rate_matches_engine(),
		"and nothing disagrees"
	)

	var run := DotTimerRun.make(0, &"normal", 1.0 / float(game.timers.tick_rate))
	run.begin(0.0)
	run.ticks = 250
	run.finish(0.0)

	var record := DotTimerRecord.from_run(run, &"m", &"p", "P")

	_check(record.tick_rate == 100, "and a record is stamped with it")
	_check(
		absf(record.time - 2.5) < 0.001,
		"so its time means what it says",
		"%.3f s" % record.time
	)

	# And the status line says so when they disagree, which is what somebody
	# debugging it will actually look at.
	var status := _run_command("pg_status")
	_check(_said(status, "tick rate"), "pg_status reports the tick rate", str(status))
	_section_done()


# --- Commands --------------------------------------------------------------

func _test_map_commands() -> void:
	print("map commands")

	var listed := _run_command("pg_map")
	_check(_said(listed, "pg_surf_intro"), "pg_map lists the maps", str(listed))

	var missing := _run_command("pg_map not_a_map")
	_check(_said(missing, "no map matches"), "and refuses one that is not there")

	_run_command("pg_map pg_bhop_intro")

	# The command awaits a map change, so it lands over the next few frames.
	for _i in range(10):
		await get_tree().process_frame

	_check(
		game.maps.current.id == &"pg_bhop_intro",
		"pg_map changes map",
		String(game.maps.current.id)
	)

	# The plain name, which is dot-map's now. It used to be dot-server's and it changed the
	# GAME -- so on this server, one game and several maps, `map` did the one thing an
	# operator typing it did not mean.
	var plain := _run_command("map")
	_check(_said(plain, "pg_surf_intro"), "`map` lists the maps", str(plain))

	_run_command("map pg_surf_intro")
	for _i in range(10):
		await get_tree().process_frame
	_check(
		game.maps.current.id == &"pg_surf_intro",
		"and `map <id>` changes it, through the game's own reset rather than the session",
		String(game.maps.current.id)
	)

	# A custom map from game-playground-maps, through the same catalogue and the same command.
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
	_run_command("map pg_surf_intro")
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


func _test_timer_commands() -> void:
	print("timer commands")

	var styles := _run_command("pg_style")
	_check(_said(styles, "sideways"), "pg_style lists the styles", str(styles))
	_check(_said(styles, "points"), "with what they are worth")

	var top := _run_command("pg_top")
	_check(top.size() > 0, "pg_top answers even with no records", str(top))

	# Commands that need a player refuse politely from the console rather than
	# erroring, because an operator typing them is the normal way to find out what
	# they do.
	for command in ["pg_track", "pg_cp", "pg_tp", "pg_cp_clear"]:
		var reply := _run_command(command)
		_check(
			_said(reply, "only a player"),
			"%s refuses politely from the console" % command,
			str(reply)
		)
	_section_done()


func _test_zone_workflow() -> void:
	print("the sm_zones workflow")

	# Drawing a zone the way an admin does on a map whose author never used this
	# engine: pick a kind, stand on one corner, stand on the other.
	var before := game.timers.zones.zones.size()

	var began := _run_command("pg_zone start")
	_check(_said(began, "stand on one corner"), "pg_zone starts a zone", str(began))

	var first := _run_command("pg_zone_mark")
	_check(_said(first, "first corner"), "the first mark is taken", str(first))

	var second := _run_command("pg_zone_mark")
	_check(
		game.timers.zones.zones.size() == before + 1,
		"and the second completes the zone",
		"%d -> %d" % [before, game.timers.zones.zones.size()]
	)

	# Live immediately. An admin who had to reload the map to test a start line
	# would test it once.
	_check(
		game.timers.timer_for(&"nobody") == null
			or game.timers.zones.zones.size() == before + 1,
		"and it is live without a map reload"
	)

	var listed := _run_command("pg_zone_list")
	_check(_said(listed, "START"), "pg_zone_list shows it", str(listed))

	var undone := _run_command("pg_zone_undo")
	_check(_said(undone, "removed"), "pg_zone_undo removes it", str(undone))
	_check(
		game.timers.zones.zones.size() == before,
		"and the count goes back"
	)

	# Saving a set with a problem is refused rather than written with a warning: a
	# zone file with a start and no end is playable and unfinishable, and the moment
	# it is on disk somebody else has a copy.
	var broken := DotTimerZoneSet.new()
	broken.map_id = &"broken"
	broken.add(DotTimerZone.make(DotTimerZone.Kind.START).set_box(
		Vector3.ZERO, Vector3.ONE
	))

	var real := game.timers.zones
	game.timers.zones = broken

	var refused := _run_command("pg_zone_save")
	_check(
		_said(refused, "not saving"),
		"a zone set with a problem is not written",
		str(refused)
	)

	game.timers.zones = real

	var saved := _run_command("pg_zone_save user://test_zones.json")
	_check(_said(saved, "wrote"), "and a good one is", str(saved))
	_check(
		FileAccess.file_exists("user://test_zones.json"),
		"with a file on disk"
	)

	DirAccess.remove_absolute(
		ProjectSettings.globalize_path("user://test_zones.json")
	)

	# Both spellings of a track, because both are what somebody types — and reading
	# only the first token turned `bonus 99` into bonus 1 and then read the 99 as a
	# stage number, so an impossible track became a plausible zone on the wrong one.
	for spelling in ["pg_zone start b99", "pg_zone start bonus 99"]:
		var bad_track := _run_command(spelling)
		_check(
			_said(bad_track, "no such track"),
			"'%s' is refused rather than silently becoming another track" % spelling,
			str(bad_track)
		)

	var good_track := _run_command("pg_zone end bonus 2")
	_check(
		_said(good_track, "Bonus 2"),
		"while a real two-token track is understood",
		str(good_track)
	)

	_run_command("pg_zone_mark")
	_run_command("pg_zone_mark")

	var bonus := game.timers.zones.first_of_kind(
		DotTimerZone.Kind.END, DotTimerTrack.of_bonus(2)
	)
	_check(bonus != null, "and the zone lands on it")

	_run_command("pg_zone_undo")
	_section_done()


func _test_prop_commands() -> void:
	print("prop commands")

	var listed := _run_command("pg_prop")
	_check(_said(listed, "only a player"), "pg_prop needs a player", str(listed))

	# The admin command does not, because clearing up after somebody is exactly what
	# an operator does from a terminal.
	game.props.limits.spawn_interval = 0.0
	game.props.spawn(&"crate", &"ghost", Vector3(0.0, 5.0, 0.0))
	game.props.spawn(&"crate", &"ghost", Vector3(0.0, 6.0, 0.0))

	_check(game.props.world_count() == 2, "two props are in the world")

	var cleared := _run_command("pg_props_clear")
	_check(_said(cleared, "removed 2"), "pg_props_clear removes them", str(cleared))
	_check(game.props.world_count() == 0, "and the world is empty")
	_section_done()


func _test_permissions() -> void:
	print("permissions")

	# The zone commands are CHANGEMAP, not GENERIC: drawing a start line is editing
	# the map's rules, and somebody who can do it can invalidate every record on it.
	var zone_cmd: DotConCommand = server.console.find_command("pg_zone")
	_check(zone_cmd != null, "pg_zone is registered")

	if zone_cmd != null:
		_check(
			zone_cmd.permission == DotAdminFlags.CHANGEMAP,
			"and needs the changemap flag",
			zone_cmd.permission
		)

	var rtv_cmd: DotConCommand = server.console.find_command("pg_rtv")
	_check(
		rtv_cmd != null and rtv_cmd.permission == "",
		"while rocking the vote needs nothing"
	)

	var clear_cmd: DotConCommand = server.console.find_command("pg_props_clear")
	_check(
		clear_cmd != null and clear_cmd.permission == DotAdminFlags.GENERIC,
		"and clearing everybody's props is an admin action"
	)
	_section_done()


## A disconnect actually reaches the module.
##
## [b]This is an ARITY check dressed as a behaviour check, and it is the only kind that
## could have caught what it caught.[/b] `DotServer.client_disconnected` emits
## `(session, reason)` and the handler took only the session, so Godot refused every call
## — "Method expected 1 argument(s), but called with 2" — and the handler never ran. No
## player was removed, no peer released, and the server kept building snapshots for
## clients that had gone, three engine errors a tick, for ever.
##
## Nothing here had ever disconnected: every other test in this file adds its players
## directly and the module is torn down at the end. So the bug needed a real browser
## client to show, and this is the check that means it will not need one again.
## Chat, voice, and the one join between them that has to work.
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


## A gag, written and read back off disk.
func _test_moderation() -> void:
	print("")
	print("moderation")

	var services: PlaygroundServices = _module().get("services")
	var subject := DotPunishmentSubject.for_uid("uid-pg-test")

	var gagged: DotResult = await services.moderation.issue(
		DotPunishment.Kind.GAG, subject, "testing", "console", 60
	)
	_check(gagged.ok, "a gag is issued and stored", str(gagged.error))

	var reloaded := DotModerationManager.new()
	reloaded.store = DotPunishmentStoreFile.new(services.punishments_path)
	reloaded.register_mute_source = false
	reloaded.register_ban_source = false
	add_child(reloaded)
	reloaded.load_all()

	var found := reloaded.active_of_kind(subject, DotPunishment.Kind.GAG)
	_check(
		found != null and found.kind == DotPunishment.Kind.GAG,
		"and comes back off disk as a GAG rather than as a WARN",
		"the kind is written and read through one table for exactly this reason"
	)

	var muted: DotResult = await services.moderation.issue(
		DotPunishment.Kind.VOICE_MUTE, subject, "testing", "console", 60
	)
	_check(muted.ok, "a voice mute is issued", str(muted.error))
	_check(
		services.moderation.is_voice_muted_key(subject),
		"and reads back as a voice mute rather than as a warning"
	)
	reloaded.queue_free()
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

	arena.release(&"u900")
	arena.release(&"u901")
	_run_command("pg_arena off")
	_check(not arena.enabled, "and the console turns it off again")
	_section_done()


## NPCs the server releases.
func _test_waves() -> void:
	print("")
	print("waves")

	var waves: PlaygroundWaves = _module().get("waves")

	_check(waves != null, "the wave layer is built")
	_check(not waves.is_enabled(), "and is off by default")
	_check(
		waves.spawner != null and not waves.spawner.two_dimensional,
		"its spawner is a 3D one"
	)
	_check(
		PlaygroundWaves.shared_catalogue().size() == 3,
		"with three kinds (%d)" % PlaygroundWaves.shared_catalogue().size()
	)

	# [b]Line of sight is ON here and off in the other two games, and that is the point of
	# the flag.[/b] A sandbox has walls, pillars and whatever somebody built; an NPC that
	# saw through all of it would make cover meaningless.
	var runner := PlaygroundWaves.shared_catalogue().get_npc(&"runner")
	_check(
		runner != null and runner.require_line_of_sight,
		"and they need to actually see you"
	)

	_run_command("pg_waves on")
	_check(waves.is_enabled(), "the console turns them on")

	# The director wants somebody to pace against. With nobody in the world it must not
	# spawn anything — a wave released at an empty server is a wave nobody meets and a
	# population budget spent on nothing.
	for _step in range(120):
		waves.tick(_step, 1.0 / float(game.tick_rate))

	_check(
		waves.count() == 0,
		"and release nothing with nobody playing (%d)" % waves.count(),
		"the director paces against players, and there are none"
	)

	_run_command("pg_waves off")
	_check(not waves.is_enabled(), "the console turns them off")
	_section_done()


## Statistics, and what they are worth.
# --- The shop ---------------------------------------------------------------

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


# --- Spectating -------------------------------------------------------------

func _test_spectating() -> void:
	print("")
	print("spectating")

	var spectate: PlaygroundSpectate = _module().get("spectate")

	_check(spectate != null, "the spectate layer is built")

	if spectate == null:
		return

	_check(
		spectate.manager.rules.force_camera == 0,
		"and anybody may watch anybody in a sandbox",
		str(spectate.manager.rules.force_camera)
	)
	_check(
		spectate.manager.rules.allow_roaming,
		"with a free camera, which is how you look at a contraption from the outside"
	)

	# And the moment it stops being a sandbox.
	spectate.set_fighting(true)
	_check(
		spectate.manager.rules.force_camera == 1
		and not spectate.manager.rules.allow_roaming,
		"and the policy tightens when the arena is on, because a living player "
		+ "watching a living one while they shoot at each other is a wallhack"
	)
	spectate.set_fighting(false)
	_check(
		spectate.manager.rules.force_camera == 0,
		"and loosens again when it is off"
	)
	_section_done()


# --- Down rather than dead ---------------------------------------------------

func _test_downed() -> void:
	print("")
	print("down rather than dead")

	var downs: PlaygroundDowns = _module().get("downs")
	var arena: PlaygroundArena = _module().get("arena")

	_check(downs != null, "the downs layer is built")

	if downs == null or arena == null:
		return

	_check(
		not downs.enabled,
		"and is off while the waves are",
		"a sandbox where nobody dies is a very confusing bug"
	)
	_check(
		arena.death_rule_fn.is_valid(),
		"the arena asks it before reporting a death, so the rule lives in ONE place "
		+ "rather than at every damage site"
	)
	_check(
		StringName(str(downs.report_zero_health(&"nobody"))) == &"dead",
		"and while it is off, zero health is death"
	)

	var _on := _run_command("pg_waves on")
	_check(
		downs.enabled,
		"turning the waves on turns it on too, because being killed by a wave is what "
		+ "it is for"
	)

	var victim := &"faller"
	var helper := &"lifter"
	_check(
		StringName(str(downs.report_zero_health(victim))) == &"down",
		"and now zero health is going down"
	)
	_check(downs.is_down(victim), "they are down")

	var state := downs.state_of(victim)
	_check(state != null and state.incaps == 1, "for the first time")
	_check(
		state != null and is_equal_approx(state.health, downs.effects.rules.downed_health),
		"with a full bleed-out pool"
	)

	# Nobody near them: the revive is refused rather than silently doing nothing.
	var far := downs.begin_revive(victim, helper)
	_check(
		not far.ok,
		"and nobody picks them up from across the map",
		str(far.error)
	)

	# Bleeding out is a death the scoreboard still has to hear about, and the arena's
	# own path was skipped when they went down. This is the other end of that decision.
	for _i in range(int(downs.effects.rules.bleed_out_ticks()) + 4):
		downs.tick(1.0 / float(game.tick_rate))
		game.tick_once(game.current_tick() + 1)

	_check(
		not downs.is_down(victim),
		"and a player nobody picks up bleeds out"
	)
	_check(
		downs.state_of(victim).is_dead(),
		"and is dead rather than still lying there"
	)

	var _off := _run_command("pg_waves off")
	_check(not downs.enabled, "turning the waves off turns it off")
	_section_done()


func _test_progress() -> void:
	print("")
	print("statistics and achievements")

	var progress: PlaygroundProgress = _module().get("progress")

	_check(progress != null, "the progress layer is built")
	_check(
		progress.stats != null and progress.stats.schema.size() >= 9,
		"with a stats schema (%d)"
			% (progress.stats.schema.size() if progress.stats != null else -1)
	)
	_check(progress.link != null, "and a link from the stats to the achievements")

	# [b]Every stat an achievement watches has to be one the game declares.[/b] An
	# achievement watching a stat nothing reports never unlocks, nothing errors, and the
	# only symptom is a player who did the thing and was not told.
	var schema := PlaygroundProgress.stats_schema()
	var missing := PackedStringArray()

	for stat in progress.achievements.catalogue.watched_stats():
		if not schema.has(stat):
			missing.append(String(stat))

	_check(
		missing.is_empty(),
		"every watched stat is one the game declares",
		"missing: %s" % str(missing)
	)

	var problems := progress.achievements.catalogue.validate()
	_check(problems.ok, "the catalogue validates", str(problems.error))

	# [b]Wipe this player's stored progress first.[/b] `DotAchievementStoreFile` writes to
	# `user://`, so every run of this suite ADDED sixty spawns to whatever the last one
	# left — and after about nine runs the "and not the second" check below crossed 500
	# and started failing for ever, on a tree with no changes in it. A suite that carries
	# state between runs is a suite whose result depends on how many times it has been
	# run, which is the one thing a check must not depend on.
	#
	# Matched by substring rather than by a filename this test would have to know: the
	# store's naming is the store's business, and a second copy of it here is the
	# family's most repeated bug in miniature.
	_forget_stored_progress(progress, "pg-test")

	progress.begin("pg-test")

	for _one in range(60):
		progress.achievements.record("pg-test", &"props", 1.0)

	_check(
		progress.achievements.is_unlocked("pg-test", &"build_50"),
		"fifty spawns unlocks the first tier"
	)
	_check(
		not progress.achievements.is_unlocked("pg-test", &"build_500"),
		"and not the second"
	)

	# A LOWEST merge, which is the other end of dot-stats' four kinds — and the reason
	# `DotAchievementRule.Merge` is deliberately the same table: the two would otherwise
	# disagree about what a new reading does to an old one.
	progress.achievements.record("pg-test", &"fastest_run", 40.0)
	progress.achievements.record("pg-test", &"fastest_run", 18.0)
	progress.achievements.record("pg-test", &"fastest_run", 55.0)
	_check(
		progress.achievements.is_unlocked("pg-test", &"under_20"),
		"a best time keeps the LOWEST reading, not the newest"
	)

	var written: DotResult = await progress.achievements.flush()
	_check(written.ok, "progress writes to disk", str(written.error))
	_section_done()


## What plays next, decided by the players.
func _test_vote() -> void:
	print("")
	print("the vote")

	var vote: PlaygroundVote = _module().get("vote")

	_check(vote != null, "the vote is built")
	_check(
		vote.director != null and vote.director.source != null
			and vote.director.source.is_usable(),
		"with a source over dot-map's own catalogue",
		"one engine, two sources — game-hungario votes over games and this votes over "
		+ "maps, and neither file names the other"
	)

	var options := vote.director.build_options(2)
	_check(options.size() > 0, "a ballot has something on it (%d)" % options.size())

	# Hibernation: both map clocks wait while the server is empty and restart on a join.
	var game_for_clocks: Playground = _module().get("game")
	_check(server.hibernation_changed.is_connected(vote.director.set_hibernating)
		and game_for_clocks != null and server.hibernation_changed.is_connected(game_for_clocks.maps.set_hibernating),
		"the vote's clock and the map's follow the server's hibernation")

	var next := vote.next_in_rotation()
	_check(next != &"", "something is next in the rotation (%s)" % String(next))
	_check(
		game.maps.current == null or next != game.maps.current.id,
		"and it is not the map that is playing"
	)

	# Rocking the vote at the start of the map, inside `rtv_delay_sec`, so this is refused — which is the check: a refusal that
	# ARRIVES is a rule that ran, and dot-vote shipped a version where rocking the vote
	# was refused for ever on the deployment that depends on it.
	var rocked := vote.director.rock_the_vote(&"u1")
	_check(
		rocked != null,
		"rocking the vote answers rather than doing nothing",
		str(rocked.error) if not rocked.ok else "accepted"
	)

	_check(
		not vote.director.begin_on_apply,
		"the director does not announce its own change",
		"the host announces it, which also fires for an operator typing pg_map — both "
		+ "firing halves every cooldown"
	)

	_check(
		vote.director.rules.nomination_seconding,
		"seconding is allowed, which is what makes MOST_NOMINATED mean anything",
		"without it every nomination count is exactly 1 and there is nothing to sort by"
	)

	# Once. It self-advanced AND the module advanced it every tick, so every clock in the
	# vote ran at twice the speed it said.
	_check(
		not vote.director.self_advance and not vote.director.is_physics_processing(),
		"the vote's clock is advanced once a tick, by the module, and not also by itself"
	)

	# dot-vote's commands, none of which existed here.
	var absent := PackedStringArray()
	for name in [
		"rtv", "unrtv", "nominate", "vote", "timeleft", "nextmap",
		"setnextmap", "nominate_addmap", "forcertv", "votereload",
	]:
		if server.console.find_command(name) == null:
			absent.append(name)
	_check(absent.is_empty(), "dot-vote's commands are on the console", ", ".join(absent))

	# One rock-the-vote. `pg_rtv` went to the map session's tally while the wire's `rtv`
	# went to the ballot. What the ballot says to this player is asked first — a refusal,
	# so asking changes nothing — and both commands must say exactly that, and leave the
	# session's tally where it was.
	var session := DotClientSession.new()
	session.peer_id = 4343
	session.userid = 43
	session.display_name = "Rocker"
	var _adopted := server.adopt_session(session)
	var expected := vote.director.rock_the_vote(&"u43")
	var tally_before := game.maps.time_limit.rtv_votes()
	for line in ["rtv", "pg_rtv"]:
		var replies: Array[String] = []
		var ctx := session.make_context(
			line, PackedStringArray(), DotCmdContext.Source.CHAT,
			func(text: String) -> void: replies.append(text)
		)
		server.console.execute(line, ctx)
		_check(
			not expected.ok and replies.size() == 1
				and replies[0].begins_with(expected.error.message),
			"`%s` is the ballot's rock-the-vote (%s)" % [line, str(replies)]
		)
	_check(
		game.maps.time_limit.rtv_votes() == tally_before,
		"and neither touches the map session's tally"
	)

	# Who the vote treats as an admin — the wire's `extend`, an instant rtv, the
	# nomination bypasses. It was `is_admin()`, which is "holds any flag at all", so a
	# reserved slot was enough to extend the map from the client.
	session.permissions = PackedStringArray(["reservation", "chat"])
	var slot_only: bool = _module().call("_voter_is_admin", &"u43")
	session.permissions = PackedStringArray(["changemap"])
	var changer: bool = _module().call("_voter_is_admin", &"u43")
	session.permissions = PackedStringArray()
	_check(not slot_only and changer,
		"a reserved slot is not a vote admin, and changemap is",
		"slot %s, changemap %s" % [slot_only, changer])
	var _released := server.release_session(session.peer_id)

	_check(
		not game.rotation_ends_maps,
		"and the map session's own clock no longer ends a map the vote may have extended"
	)

	# What the module forwards to every client as a VOTE event, heard at the vote's edge.
	var heard: Array = []
	var probe := func(cue: StringName, seconds_left: int, _runoff: bool) -> void:
		heard.append([String(cue), seconds_left])
	vote.cue_due.connect(probe)
	var was_min := vote.director.rules.min_players_to_vote
	vote.director.rules.min_players_to_vote = 0
	var opened := vote.director.open_vote(DotVoteClock.REASON_MANUAL)
	vote.director.rules.min_players_to_vote = was_min
	if opened.ok:
		vote.director.close_vote()
	vote.cue_due.disconnect(probe)
	_check(
		heard.has([String(PlaygroundVote.CUE_START), 0]) and heard.has([String(PlaygroundVote.CUE_END), 0]),
		"a ballot's start and end cues are handed on for the wire (%s)" % str(heard),
		"" if opened.ok else opened.error.message
	)

	_test_status_clock(vote)
	_section_done()


## `pg_status`'s "time left" is the vote's clock, and an extend moves it.
##
## [b]It read the map session's clock after the vote had taken the map's end over[/b], so
## an operator asking how long was left was shown a limit an extend had already moved —
## the same bug the HUD had, one screen over. Through the console, which is how an
## operator reads it, and asserting the session's clock did NOT move while the line did:
## the line moving with the session held still is the line reading the vote.
func _test_status_clock(vote: PlaygroundVote) -> void:
	var rules := vote.director.rules
	var clock := vote.director.clock
	var was_duration := rules.duration_sec
	var was_trigger := rules.trigger
	var was_max_extends := rules.max_extends

	# A known clock, so the numbers mean something whatever the config shipped — which is
	# `trigger: rtv_only` with no duration, and so no clock at all.
	rules.duration_sec = 600.0
	rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
	rules.max_extends = 0
	clock.start()

	var session_before := game.maps.time_limit.formatted_remaining()
	var before := _status_seconds(_run_command("pg_status"))
	_check(
		absf(before - clock.remaining) <= 1.0,
		"`pg_status` reports the vote's time left (%d s, the vote's is %.0f s)" % [
			before, clock.remaining
		]
	)

	_check(clock.extend(), "the vote extends the map")
	var after := _status_seconds(_run_command("pg_status"))
	_check(
		after - before == int(rules.extend_seconds)
			and game.maps.time_limit.formatted_remaining() == session_before,
		"and the status line moves by the extension while the map session's clock does not "
			+ "(%d s -> %d s, extended by %.0f)" % [before, after, rules.extend_seconds],
		"the line is reading the map session's clock, which nothing extends"
	)
	_check(
		String(game.describe()["time_left"]) == "%d:%02d" % [after / 60, after % 60],
		"and so does describe()'s (%s)" % String(game.describe()["time_left"])
	)

	rules.duration_sec = 0.0
	rules.trigger = DotVoteRules.Trigger.RTV_ONLY
	clock.start()
	var status := _run_command("pg_status")
	_check(
		_said(status, "time left    no limit"),
		"a vote with no clock is reported as no limit, not as the session's (%s)" % _status_line(status)
	)

	rules.duration_sec = was_duration
	rules.trigger = was_trigger
	rules.max_extends = was_max_extends
	clock.start()


func _status_line(lines: PackedStringArray) -> String:
	for line in lines:
		if line.begins_with("time left"):
			return line
	return ""


## Seconds on `pg_status`'s time-left line, or -1 when it is not an m:ss.
func _status_seconds(lines: PackedStringArray) -> int:
	var parts := _status_line(lines).trim_prefix("time left").strip_edges().split(" ")[0].split(":")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return -1
	return int(parts[0]) * 60 + int(parts[1])


## Profiles and avatars: ids and a schema, and no art anywhere.
func _test_identity() -> void:
	print("")
	print("identity")

	_check(platform.hub != null and platform.hub.is_ready(), "the platform is up")
	_check(
		server.modules.get_module("platform") != null,
		"and its module is loaded beside the game's"
	)

	var schema := PlaygroundPlatform.avatar_schema()
	var problems := schema.validate_schema()

	# [b]A schema that validates is not a formality.[/b] game-hungario shipped a part that
	# was its own fallback — a resolution loop that cannot terminate — and its suite never
	# noticed, because it never validated a schema.
	_check(problems.ok, "the avatar schema is valid", str(problems.error))

	var legal := DotAvatar.make(&"pg_builder")
	legal.set_part(&"body", &"body_overalls")
	legal.set_part(&"hat", &"hat_cap")

	_check(
		schema.validate(legal, DotAvatarEntitlements.none()).ok,
		"a free avatar is accepted with no entitlements at all"
	)

	var locked := DotAvatar.make(&"pg_builder")
	locked.set_part(&"body", &"body_plain")
	locked.set_part(&"hat", &"hat_hard")

	# [b]Entitlements default to nothing and that default is the important one.[/b] A
	# server that granted everything would work perfectly in every test, ship, and quietly
	# be a game where every unlock is free — which nobody reports as a bug.
	_check(
		not schema.validate(locked, DotAvatarEntitlements.none()).ok,
		"and one nobody has unlocked is refused"
	)
	_check(
		schema.validate(locked, DotAvatarEntitlements.of([&"hat_hard"])).ok,
		"until they hold it"
	)

	# [b]The key a statistic is filed under, and the reason dot-platform is here at
	# all.[/b] dot-stats refuses an account id as a player key before it leaves the
	# server, and a board is exactly the same kind of record — so the one function that
	# decides has to give a scoped id when there is an identity stack and something
	# honest when there is not.
	var key := PlaygroundPlatform.key_for_session(server, null)
	_check(key == "", "no session is no key rather than a guessed one")

	_check(
		PlaygroundProgress.stats_schema().has(&"props"),
		"the stats schema declares what the game reports"
	)
	_section_done()


## dot-moderation's live tools, as an operator types them.
##
## The course is timed, so the timer's rule is the one asserted first: noclip abandons a
## run and taints any run begun under it. Then the arena's half — god and slay mean
## something only while `pg_arena` is on, and say so when it is off.
func _test_live_tools() -> void:
	print("")
	print("the moderator's live tools")

	_check(
		server.console.find_command("noclip") != null and server.console.find_command("slay") != null,
		"the live tools' commands are on the console"
	)

	var player := game.add_player(&"u77", "Pat")
	var session := DotClientSession.new()
	session.peer_id = 7707
	session.userid = 77
	session.display_name = "Pat"
	var _adopted := server.adopt_session(session)

	var stopped: Array[StringName] = []
	var on_stop := func(_r: DotTimerRun, why: StringName) -> void: stopped.append(why)
	player.timer.run_stopped.connect(on_stop)
	player.timer.run.begin(0.0)

	var _on := await _run_command_later("noclip Pat")
	_check(DotFpsAdminModifiers.is_noclipped(player.controller), "`noclip Pat` puts them in noclip")
	_check(stopped.has(&"noclip") and not player.timer.run.is_active(),
		"and abandons the course run they were on", str(stopped))

	player.timer.run.begin(0.0)
	player._on_simulated(0, player.controller.state)
	_check(player.timer.run.tainted, "a run begun while noclipped is marked assisted")
	var _off := await _run_command_later("noclip Pat off")

	# A slap is a shove in a direction the slapper knows: speed nobody earned.
	#
	# Out of the start zone first. Pat joined at the spawn, which is inside the start, and
	# standing in the start ends a live run (dot-timer's REASON_RESET): the run begun
	# here was thrown away on the first tick after the slap and replaced by a clean one,
	# so the check read a run the slap never touched. Up in the air is in no zone at all.
	# Then let the timer see the move: leaving the start is what STARTS a run, so a run
	# begun before that tick is replaced by the timer's own the moment it is processed.
	player.teleport(Vector3(0.0, 400.0, 0.0))
	for _i in 4:
		await get_tree().physics_frame
	if not player.timer.run.is_active():
		player.timer.run.begin(0.0)
	var clean_before_slap := not player.timer.run.tainted
	var _slapped := await _run_command_later("slap Pat")
	# Two checks, not one `and`: when it was one, a failure could not say whether the run
	# was already tainted before the slap or the slap failed to taint it.
	_check(clean_before_slap, "a run begun after noclip is turned off starts clean")
	_check(player.timer.run.tainted,
		"a slap taints the course run it lands in, so it is not a boost with a time at the end")

	player.timer.run_stopped.disconnect(on_stop)
	player.timer.stop()

	var arena: PlaygroundArena = _module().get("arena")
	var was_on := arena.enabled
	_run_command("pg_arena off")
	var no_arena := await _run_command_later("god Pat")
	_check(_said(no_arena, "arena is off"), "`god` with the arena off says why it means nothing",
		" | ".join(no_arena))

	_run_command("pg_arena on")
	arena.admit(&"u77", "Pat")
	var health := arena.health_of(&"u77")
	var _god := await _run_command_later("god Pat")
	_check(health != null and health.invulnerable, "with it on, `god Pat` makes them invulnerable")
	var slain := await _run_command_later("slay Pat")
	_check(health != null and not health.alive, "and `slay Pat` kills them through it",
		" | ".join(slain))

	var given := await _run_command_later("give Pat rifle")
	_check(_said(given, "physics gun"), "`give` says what a player holds here instead",
		" | ".join(given))

	# `return` after a map change. Moved once by a moderator, so `return` has somewhere to
	# put them — a position on THIS map, which the change is about to free. Then the map
	# changes and `return` must have nowhere to put them, rather than a point on a map that
	# is gone (armed 2026-09-25: without the clear it returned Pat to the old map's spot).
	var tools: DotModTools = _module().get("mod_tools")
	var here := player.global_position
	var _moved: DotResult = await tools.teleport(&"", &"77", here + Vector3(6.0, 0.0, 0.0))
	_check(tools.can_return(&"77"),
		"a moderator moves Pat, so `return` has somewhere to put them")

	var was_map := game.maps.current.id
	var other := &"pg_bhop_intro" if was_map != &"pg_bhop_intro" else &"pg_surf_intro"
	_run_command("map %s" % other)
	for _i in range(10):
		await get_tree().process_frame

	var returned: DotResult = await tools.return_player(&"", &"77")
	_check(
		game.maps.current.id == other and not tools.can_return(&"77") and not returned.ok,
		"and after a map change `return` has nowhere to put them",
		"map %s; it put them at %s, a spot on the previous map"
			% [game.maps.current.id, str(returned.value) if returned.ok else "-"]
	)

	_run_command("map %s" % was_map)
	for _i in range(10):
		await get_tree().process_frame
	_check(game.maps.current.id == was_map, "and the map goes back for the sections after this",
		String(game.maps.current.id))

	_run_command("pg_arena %s" % ("on" if was_on else "off"))
	var _released := server.release_session(session.peer_id)
	game.remove_player(&"u77")
	_section_done()


## An administrator's blind and beacon, typed at the console of a real server.
##
## What is asserted is the flag on the player and on the entity the netcode sends, because
## that is the whole of what the server decides; whether the owner's client — and only the
## owner's — receives it is `headless_net`'s, and what it looks like is
## `tools/screenshot_views.sh`'s.
func _test_blind_and_beacon() -> void:
	print("")
	print("[blind and beacon]")

	var player := game.add_player(&"u78", "Quin")
	var session := DotClientSession.new()
	session.peer_id = 7808
	session.userid = 78
	session.display_name = "Quin"
	var _adopted := server.adopt_session(session)

	var blinded := await _run_command_later("blind Quin")
	_check(player.blinded, "`blind Quin` blacks their screen out", " | ".join(blinded))

	# The flag reaching the replicated field is the half of this the server owns. `pull`
	# is what the netcode's tick calls; this suite drives no net tick, so it is called here.
	var net := player.get_node_or_null("Net")
	if net != null:
		net.call("pull")
	_check(
		net != null and bool(net.get("net_blind")),
		"and it is on the entity the netcode sends them"
	)

	var _lift := await _run_command_later("blind Quin off")
	_check(not player.blinded, "`blind Quin off` lifts it")

	# A blind is a spell. dot-moderation lifts it through the same handler when the time
	# is up, so what is checked is the flag, not the timer.
	var _spell := await _run_command_later("blind Quin 0.2")
	_check(player.blinded, "`blind Quin 0.2` blinds them for a fifth of a second")
	await get_tree().create_timer(0.4).timeout
	_check(not player.blinded, "and it lifts on its own when the time is up")

	var lit := await _run_command_later("beacon Quin")
	_check(player.beacon, "`beacon Quin` marks them for everybody", " | ".join(lit))

	var _dark := await _run_command_later("blind Quin")
	var _back := await _run_command_later("respawn Quin")
	_check(
		player.blinded and player.beacon,
		"a respawn keeps both: they are about the person, not the body"
	)

	var described := _run_command("modtools")
	var abilities := ""
	var refused := ""
	for line in described:
		if line.begins_with("abilities"):
			abilities = line
		elif line.begins_with("refused"):
			refused = line
	_check(
		abilities.contains("blind") and abilities.contains("beacon")
		and not refused.contains("blind") and not refused.contains("beacon"),
		"`modtools` lists both as abilities and refuses neither",
		"%s / %s" % [abilities, refused]
	)

	var _dark_off := await _run_command_later("blind Quin off")
	var _unlit := await _run_command_later("beacon Quin off")
	var tools: DotModTools = _module().get("mod_tools")
	_check(
		not player.blinded and not player.beacon
		and not tools.is_active(&"78", DotModTools.ACTION_BLIND)
		and not tools.is_active(&"78", DotModTools.ACTION_BEACON),
		"and both come off, with the tools' record agreeing with the world"
	)

	var _released := server.release_session(session.peer_id)
	game.remove_player(&"u78")
	_section_done()


## [method _run_command] as a player: what `!creative` in chat arrives as.
func _run_as(session: DotClientSession, line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := DotCmdContext.console("", PackedStringArray())
	template.session = session
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	return PackedStringArray(captured)


## Creative mode: `!creative` from a player, their props protected, out of the fight both
## ways, and `pg_creative 0` ending it for everybody.
func _test_creative() -> void:
	print("")
	print("[creative mode]")

	var builder := game.add_player(&"u79", "Builder")
	var other := game.add_player(&"u80", "Other")
	var session := DotClientSession.new()
	session.peer_id = 7909
	session.userid = 79
	session.display_name = "Builder"
	var _adopted := server.adopt_session(session)

	var said := _run_as(session, "creative")
	_check(builder.creative and _said(said, "on"), "`!creative` switches it on for the caller", " | ".join(said))
	_check(game.props.is_protected(&"u79"), "and protects their props in dot-props")

	var crate := game.props.spawn(&"crate", &"u79", Vector3(0.0, 40.0, 0.0))
	var tool := DotPropTool.new()
	tool.spawner = game.props
	tool.wielder = &"u80"
	_check(crate != null and not tool.may_act_on(crate).ok, "nobody else's tool may touch what they build")

	var net := builder.get_node_or_null("Net")
	if net != null:
		net.call("pull")
	_check(net != null and bool(net.get("net_creative")), "and it is on the entity everybody is sent")

	var arena: PlaygroundArena = _module().get("arena")
	_run_command("pg_arena on")
	arena.admit(&"u79", "Builder")
	arena.admit(&"u80", "Other")
	for step in range(game.tick_rate * 5):
		arena.tick(step, 1.0 / float(game.tick_rate))
	var at_them := arena.hurt(&"u80", &"u79", 30.0, 5.0)
	var by_them := arena.hurt(&"u79", &"u80", 30.0, 5.0)
	_check(at_them != null and at_them.refused, "nobody can hurt them", str(at_them))
	_check(by_them != null and by_them.refused, "and they cannot hurt anybody", str(by_them))

	said = _run_as(session, "creative")
	var lands := arena.hurt(&"u80", &"u79", 30.0, 5.0)
	_check(not builder.creative and lands != null and not lands.refused, "`!creative` again turns it off, and a hit lands", str(lands))

	var _on := _run_as(session, "creative")
	_run_command("pg_creative 0")
	_check(not builder.creative and not game.props.is_protected(&"u79"), "`pg_creative 0` ends it for everybody")
	said = _run_as(session, "creative")
	_check(not builder.creative and _said(said, "off on this server"), "and refuses it after", " | ".join(said))
	_run_command("pg_creative 1")
	_check(game.config.allow_creative, "`pg_creative 1` allows it again")

	arena.release(&"u79")
	arena.release(&"u80")
	_run_command("pg_arena off")
	if crate != null:
		var _gone := game.props.remove(crate.instance_id)
	var _released := server.release_session(session.peer_id)
	game.remove_player(&"u79")
	game.remove_player(&"u80")
	_section_done()


## `pg_save`, `pg_builds`, `pg_load` and `pg_build_delete`, typed by a player.
func _test_saved_builds() -> void:
	print("")
	print("[saved builds]")

	var module := _module()
	module.get("builds").set("directory", "%s/builds" % SERVER_DIR)
	var builder := game.add_player(&"u81", "Mason")
	var session := DotClientSession.new()
	session.peer_id = 8101
	session.userid = 81
	session.display_name = "Mason"
	var _adopted := server.adopt_session(session)

	var at := builder.controller.state.position
	var _a := game.props.spawn(&"crate", &"u81", at + Vector3(0.0, 30.0, -3.0))
	var _b := game.props.spawn(&"plank", &"u81", at + Vector3(1.0, 30.0, -3.0))

	var said := _run_as(session, "pg_save tower")
	_check(_said(said, "saved") and _said(said, "2 props"), "`pg_save tower` saves what they built", " | ".join(said))
	said = _run_as(session, "pg_builds")
	_check(_said(said, "tower"), "`pg_builds` lists it", " | ".join(said))
	game.props.clear_player(&"u81")
	said = _run_as(session, "pg_load tower")
	_check(_said(said, "put down") and game.props.props_of(&"u81").size() == 2, "`pg_load tower` puts it back", " | ".join(said))
	said = _run_as(session, "pg_load nothing")
	_check(_said(said, "no build called"), "a build they never saved is refused by name", " | ".join(said))

	# The Q menu's Builds tab asks over the wire; the module answers the same as the commands.
	var summaries: Array = module.get("builds").call("summaries", PlaygroundPlatform.key_for_session(server, session))
	_check(summaries.size() == 1 and summaries[0]["name"] == "tower" and int(summaries[0]["props"]) == 2,
		"the Builds tab is sent what pg_builds lists", str(summaries))
	game.props.clear_player(&"u81")
	# The click is answered over the wire with a NOTICE to the clicker. 8101 is a session
	# this suite adopted with no socket behind it, so sent for real that NOTICE was an
	# `rpc_id` to a peer the multiplayer API has never heard of, and every green run printed
	# "Attempt to call RPC with unknown peer ID: 8101". Caught on the link's loopback for the
	# one call instead: the reply becomes a check, and a real unknown-peer line in this
	# suite's stderr is a real one.
	var link: Variant = module.get("bridge").get("link")
	var replies: Array = []
	if link != null:
		link.loopback = func(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
			replies.append({"method": method, "peer": peer_id, "payload": payload})
	module.get("bridge").build_load_requested.emit(session.peer_id, "tower")
	if link != null:
		link.loopback = Callable()
	_check(game.props.props_of(&"u81").size() == 2, "and a click on it puts it down, as pg_load does")
	var told := false
	for reply: Dictionary in replies:
		if reply["method"] == &"event" and int(reply["peer"]) == session.peer_id \
				and (reply["payload"] as PackedByteArray).hex_encode().contains("Put down".to_utf8_buffer().hex_encode()):
			told = true
	_check(link != null and told, "and the clicker alone is told it was put down", str(replies.map(func(r: Dictionary) -> String: return "%s->%d" % [r["method"], r["peer"]])))
	said = _run_as(session, "pg_build_delete tower")
	_check(_said(said, "deleted") and not _said(_run_as(session, "pg_builds"), "tower"), "and `pg_build_delete` takes it away", " | ".join(said))

	game.props.clear_player(&"u81")
	var _released := server.release_session(session.peer_id)
	game.remove_player(&"u81")
	_section_done()


## [method _run_command] for a coroutine handler: the live tools record each action on a
## punishment store, which may be remote, so the reply can land a frame late.
func _run_command_later(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := DotCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	await get_tree().process_frame
	await get_tree().process_frame
	return PackedStringArray(captured)


## The inventory from the console: an operator puts something in somebody's bag and reads it
## back. `headless_net` is where the bag crosses the wire; this is where the MODULE's half —
## the commands and who a session is for a bag that outlasts it — is run at all.
func _test_inventory_commands() -> void:
	print("")
	print("[the inventory, from the console]")

	var bridge: Variant = _module().get("bridge")
	_check(
		bridge != null and (bridge.get("inventory_key_fn") as Callable).is_valid(),
		"the module tells the bridge who a session is, so a bag can outlast a reconnect"
	)

	var player := game.add_player(&"u79", "Rae")
	var session := DotClientSession.new()
	session.peer_id = 7909
	session.userid = 79
	session.display_name = "Rae"
	var _adopted := server.adopt_session(session)

	var given := _run_command("pg_give Rae crate 2")
	var bag: StringName = bridge.get("inventory_net").call("bag_key", 79) if bridge != null else &""
	_check(
		player != null and game.inventory.carries(bag, &"crate") == 2 and _said(given, "2 crate"),
		"`pg_give Rae crate 2` puts two crates in their bag (%s)" % bag,
		" | ".join(given)
	)
	var carried := _run_command("pg_inv Rae")
	_check(_said(carried, "crate"), "and `pg_inv Rae` lists them", " | ".join(carried))
	var nobody := _run_command("pg_give Nobody crate")
	_check(_said(nobody, "pg_give <player>"), "somebody who is not here is answered with the usage")

	# A session nobody can recognise next time has no bag that outlasts it: the platform's
	# `local:<userid>` identifies nobody after a reconnect, and a bag kept under it would be
	# one abandoned bag per connection for the life of the server.
	var key := str(_module().call("_bag_key_for", 79))
	_check(
		not key.begins_with("bag:local:"),
		"and a key that identifies nobody next time is not used to keep a bag (%s)" % (key if key != "" else "the session's own")
	)

	var _released := server.release_session(session.peer_id)
	game.remove_player(&"u79")
	_section_done()


## A joiner is welcomed when it says READY, which on every real join is AFTER `client_spawn`.
##
## [b]The module's own half of `[pg-rpc-before-scene]`.[/b] `_welcome` (the chat backlog and
## the join line) ran from `client_spawn` and returned unless the bridge had the peer READY,
## which it never does at spawn, because the client says READY only once its scene is up. So
## no connected player had ever been sent either. This drives the real order: a session,
## `client_spawn`, then READY through the bridge, recording what goes to that one peer.
func _test_welcome_waits_for_ready() -> void:
	print("a joiner is welcomed when it says READY, and not before")

	var bridge: PlaygroundNetBridge = _module().get("bridge")
	var services: PlaygroundServices = _module().get("services")
	var peer := 7909
	var session := DotClientSession.new()
	session.peer_id = peer
	session.userid = 79
	session.display_name = "Wren"
	var _adopted := server.adopt_session(session)
	var _said: Variant = services.chat.announce("said before Wren came", PlaygroundServices.CHANNEL_ALL)

	var kinds: Array[int] = []
	var old_send: Callable = bridge.net.send_fn
	bridge.net.send_fn = func(peer_id: int, payload: PackedByteArray, _delivery: int) -> void:
		if peer_id != peer:
			return
		var decoded: DotResult = bridge.net.messages.decode(DotNetReader.new(payload), 1, false)
		if decoded.ok and decoded.value is PlaygroundEvent:
			kinds.append((decoded.value as PlaygroundEvent).kind)

	var _spawned: DotEvent = server.events.fire("client_spawn", {"userid": 79})
	_check(game.players.has(&"u79"), "client_spawn puts the joiner in the game")
	_check(
		kinds.is_empty(),
		"and sends them nothing, because they have not said READY",
		str(kinds)
	)

	var writer := DotNetWriter.new()
	var _encoded: DotResult = bridge.net.messages.encode(
		PlaygroundRequest.new(PlaygroundEvents.Ask.READY, PackedByteArray()), writer
	)
	var _ready: DotResult = bridge.receive_request(peer, writer.to_bytes())
	var chats := kinds.count(PlaygroundEvents.Kind.CHAT)
	_check(
		kinds.has(PlaygroundEvents.Kind.HELLO) and chats >= 2,
		"READY sends HELLO and then the welcome: the backlog and the join line (%d chat)" % chats,
		str(kinds)
	)

	kinds.clear()
	var _again: DotResult = bridge.receive_request(peer, writer.to_bytes())
	_check(
		kinds.count(PlaygroundEvents.Kind.CHAT) == 0,
		"a READY said twice does not welcome them twice",
		str(kinds)
	)

	_check(bridge.net.peers().has(peer), "and dot-net now replicates to them")

	bridge.net.send_fn = old_send
	server.client_disconnected.emit(session, "closed")
	_check(not game.players.has(&"u79"), "and they leave cleanly")
	# The module takes them off the ready set BEFORE the bridge removes the player, and
	# the bridge used to ask that same set whether to tell dot-net: every peer that ever
	# disconnected stayed in `net.peers()`, built a snapshot for every tick.
	_check(
		not bridge.net.peers().has(peer),
		"and dot-net stops replicating to them",
		str(bridge.net.peers())
	)
	_section_done()


func _test_disconnect_is_handled() -> void:
	print("a client disconnecting reaches the module")

	var session := DotClientSession.new()
	session.userid = 4242
	session.peer_id = 0
	session.display_name = "Leaver"

	game.add_player(&"u4242", "Leaver")
	_check(game.players.has(&"u4242"), "a player is in the game")

	# Emitted with BOTH arguments, exactly as DotServer emits it. A handler with the
	# wrong arity is refused by the engine rather than adapted to.
	server.client_disconnected.emit(session, "closed")

	_check(
		not game.players.has(&"u4242"),
		"and the disconnect took them back out again"
	)
	_section_done()


func _test_module_unloads_cleanly() -> void:
	print("the module unloads cleanly")

	game.add_player(&"u1", "One")
	_check(game.players.size() == 1, "a player is in the game")

	var unloaded := server.modules.unload_module("playground")
	_check(unloaded.ok, "the module unloads",
		unloaded.error.message if not unloaded.ok else "")

	# Its commands go with it. A module that left them behind would leave a console
	# whose commands call into a module that is no longer there.
	_check(
		server.console.find_command("pg_status") == null,
		"and takes its commands with it"
	)
	_check(
		server.console.find_command("noclip") == null,
		"the live tools' included"
	)
	_check(
		server.console.find_cvar("pg_map_seconds") == null,
		"and its cvars"
	)

	# And the players it put in the game come back out, or the game would be holding
	# players whose sessions no longer exist.
	_check(
		game.players.is_empty(),
		"and the players it added",
		"%d left" % game.players.size()
	)

	var reloaded: DotResult = await server.modules.load_module(
		"res://game/playground_module.gd"
	)
	_check(reloaded.ok, "and it can be loaded again")

	await get_tree().process_frame
	_section_done()


## Deletes any file the achievement store has written for [param player].
##
## The store is a directory of files under `user://` and it is not part of what this
## suite is testing; what matters is that a run starts from nothing. Failing to open the
## directory is not an error — the first run on a machine has no directory yet.
func _forget_stored_progress(progress: PlaygroundProgress, player: String) -> void:
	var dir := DirAccess.open(progress.progress_dir)

	if dir == null:
		return

	for file in dir.get_files():
		if file.contains(player):
			dir.remove(file)


## [b]The one line that leaked mg-buses-from-hell's whole script graph at exit.[/b]
##
## A script that `extends DotNetMessage` and preloads ITSELF, first loaded from a module a
## running [DotServer] loads — which is how every deployed server loads this game — leaves
## every loaded script alive at exit on Godot 4.7.2 (measured in mg-buses-from-hell,
## 8ed866c). This game's event and request both did it, for a typed `of()` factory.
##
## [b]Asserted on the source, because the symptom is where no check can reach.[/b] The
## leak is reported after `quit()`, by the engine, as warnings a CI filter already treats
## as noise; an assertion here runs before any of it exists. So this checks the cause
## instead: every message script in `game/`, read as text.
func _test_no_message_preloads_itself() -> void:
	print("exiting clean")

	var messages := PackedStringArray()
	var offenders := PackedStringArray()
	var pending: Array[String] = ["res://game"]

	while not pending.is_empty():
		var dir_path: String = pending.pop_back()

		for sub in DirAccess.get_directories_at(dir_path):
			pending.append(dir_path.path_join(sub))

		for file in DirAccess.get_files_at(dir_path):
			if not file.ends_with(".gd"):
				continue

			var path := dir_path.path_join(file)
			var source := FileAccess.get_file_as_string(path)

			if not _extends_message(source):
				continue

			messages.append(path)

			if source.contains('preload("%s")' % file) or source.contains('preload("%s")' % path):
				offenders.append(path)

	_check(
		messages.size() >= 2,
		"this game's message scripts are found, so the next check is about something",
		", ".join(messages)
	)
	_check(
		offenders.is_empty(),
		"and none of them preloads itself, which leaks every script at exit",
		", ".join(offenders)
	)
	_section_done()


func _extends_message(source: String) -> bool:
	for line in source.split("\n"):
		if line.begins_with("extends "):
			return line.contains("DotNetMessage") or line.contains("dot_net_message.gd")
	return false


# --- Exiting clean ----------------------------------------------------------------

## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3


## How long the copy may run before it is killed and this probe fails. A copy that is still
## running this long after it started is hung, and the likeliest reason is the one that says
## nothing at all: a scene whose script failed to parse never reaches `quit()` and prints
## nothing. `-- --exit-probe-seconds N` lowers it, which is how the deadline itself is armed —
## any N shorter than the suite takes is a copy that is still running when it expires.
const EXIT_PROBE_SECONDS := 300


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


func _exit_probe_seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return EXIT_PROBE_SECONDS


## Runs this same suite in a fresh process: `[exit code, its stdout, its stderr, whether it
## had to be killed, the seconds it was allowed]`.
##
## [b]A leak is reported after `quit()`, by the engine, where nothing in the process that
## leaked can read it.[/b] "N ObjectDB instances were leaked at exit" is printed once the
## scene tree is gone, so the only process that can check a run's exit is another one. On
## Godot 4.7.2 a script that names itself, loaded after its base, cuts the engine's exit
## teardown short and every script loaded before it is reported leaked — hundreds of lines
## a passing run printed for weeks, which is why this is a check now and not a warning.
##
## [b]First, before this run opens a port[/b], so the two never contend for a socket — and
## so this run is always the second one against the same `user://`, which is the other
## thing no single run can see.
##
## [b]Not `OS.execute`.[/b] That blocks until the copy exits, so a copy that hangs held this
## run for ever; and when the outer `timeout` then killed this run, the copy was left behind
## holding the suite's directory and port. So the copy is started, polled against a deadline
## and killed at it. Two deadlines, because Godot dies on SIGTERM without running a line of
## script — nothing in this process can clean up after it is killed:
##
## - coreutils `timeout` wraps the copy where it exists. It is an exec wrapper, not a shell,
##   and it outlives this process, so a copy orphaned by the outer `timeout` still dies on
##   time. Its exit status 124 is how its expiry is recognised.
## - this loop's own deadline, a little later, for a platform without it.
##
## `execute_with_pipe` rather than `create_process`, because the latter captures nothing and
## the whole point is reading what the copy printed. Non-blocking, and drained on every pass
## rather than once at the end: a pipe holds 64 KiB, and a copy that fills it blocks on its
## next print — a hang this probe would then report as the suite's own. The copy's stdin is
## the other end of a pipe this process holds open, which is why every suite turns the
## server's stdin console off: a reader blocked on it never lets the copy exit.
func _run_exit_probe() -> Array:
	var seconds := _exit_probe_seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit — %d s allowed)" % seconds)
	var scene := scene_file_path if scene_file_path != "" else "res://examples/dedicated.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	])
	var wrapped := false
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(seconds), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, seconds]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (seconds + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		_drain_exit_probe(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await get_tree().create_timer(0.1).timeout
	# Once more after it exits: what it wrote between the last pass and its exit is still in
	# the pipe, and the leak report is always the last thing it writes.
	_drain_exit_probe(pipes, bytes)

	# OS.kill has already reaped it, and asking for the exit code of a reaped pid is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, seconds]


func _drain_exit_probe(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


func _test_exits_clean(probe: Array) -> void:
	print("")
	print("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Every leak line is the engine's, and the engine writes them to stderr; both are
	# searched so that stays a fact about the engine rather than an assumption here. Shown
	# apart, because a pipe each is two streams whose interleaving is lost, and where a hung
	# copy had got to is the end of its stdout.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so neither of the last two was seen, and
	# passing them on an absence of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))
	_section_done()


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))
