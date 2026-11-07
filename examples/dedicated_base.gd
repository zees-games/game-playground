extends DotGameCheckSuite
## The header, counts and helpers of the dedicated-server suite, and the first sections.


const Playground := preload("../game/playground.gd")
const PlaygroundArena := preload("../game/playground_arena.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundDowns := preload("../game/playground_downs.gd")
const PlaygroundEvent := preload("../game/net/playground_event.gd")
const PlaygroundEvents := preload("../game/net/playground_events.gd")
const PlaygroundNetBridge := preload("../game/net/playground_net_bridge.gd")
const PlaygroundNetLink := preload("../game/net/playground_net_link.gd")
const PlaygroundRequest := preload("../game/net/playground_request.gd")
const PlaygroundPlatform := preload("../game/playground_platform.gd")
const PlaygroundProgress := preload("../game/playground_progress.gd")
const PlaygroundServices := preload("../game/playground_services.gd")
const PlaygroundShop := preload("../game/playground_shop.gd")
const PlaygroundSpectate := preload("../game/playground_spectate.gd")
const PlaygroundVote := preload("../game/playground_vote.gd")
const PlaygroundWaves := preload("../game/playground_waves.gd")


## Sections that ran to their last line, and the checks they ran between them. Both, because either
## alone reports a healthy run with checks missing: a runtime error aborts a section, not the run.
## Each section calls [method _section_done] last; an early `return` after a failed check skips it.
var _stats_errors: PackedStringArray = []

const SECTIONS := 32
const CHECKS := 300

## What the run timer's checks add when `res://addons/dot_timer` is linked (and
## `addons/pg_timer` turns it on): the records section and the timer's halves of the
## tick-rate, command and live-tool sections. A server without the timer is the default.
const TIMER_SECTIONS := 1
const TIMER_CHECKS := 24

## Everything this run writes, and it is deleted on the way in and on the way out.
##
## A suite that writes to `user://` has a result that depends on the last run, so this one writes to its own directory, not the real punishment store, ban and admin files and audit log.
const SERVER_DIR := "user://pg_dedicated"

var _sections_done := 0

var server: DotServer = null
var game: Playground = null
var platform: PlaygroundPlatform = null

## The app's URL segment on the website, this game's code name. Display only: a listing prints it
## and nothing treats it as proof.
const APP_URL := "playground"


## The loaded module, looked up every time because `_test_module_unloads_cleanly` unloads it. Typed
## as [DotModule]: `playground_module.gd` has no `class_name` (a pack-delivered module is loaded by
## path), so its fields come back through `get()`.
func _module() -> DotModule:
	return server.modules.get_module("playground")


## Whether dot-timer is linked into this checkout, which is what turns `addons/pg_timer` on.
static func _timer_linked() -> bool:
	return FileAccess.file_exists("res://addons/dot_timer/plugin.cfg")


## The last line of every section. See [constant SECTIONS].
func _section_done() -> void:
	_sections_done += 1


## The server half of this game's own server browser. What matters in a sandbox's listing row is
## not the map but which of `pg_arena`, `pg_waves` and `pg_shop` are on: each turns this into a
## different server and all three default to off.
func _test_query() -> void:
	print("")
	print("[a server browser's half]")

	_check(server.query_source != null, "the server has a query source to contribute to")
	var roster_max: int = module_roster_max()
	_check(
		roster_max == server.config.max_players,
		"the roster accepts what the server advertises (%d of %d)" % [roster_max, server.config.max_players]
	)

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


## The family cvar `stats_report` is registered, off, and turning it on makes the game's tracker report.
func _test_stats_report() -> void:
	print("")
	print("stats_report")

	var cv: DotConVar = server.console.find_cvar("stats_report")
	var progress: Object = _module().get("progress")
	_check(cv != null and cv.get_string() == "0", "stats_report is registered and off by default")
	_check(progress != null and progress.stats != null and not progress.stats.report_to_backbone,
		"and the tracker does not report at boot")
	if cv == null or progress == null:
		return
	var _off := cv.set_value("1")
	_check(not progress.stats.report_to_backbone, "on with no backbone client stays off, not a crash")

	var client := Node.new()
	var script := GDScript.new()
	script.source_code = "extends Node\nfunc post_integration(_a = null, _b = null, _c = null): return null\n"
	var _reloaded := script.reload()
	client.set_script(script)
	DotRegistry.register(&"dot_backbone_client", client)
	var _r0 := cv.set_value("0")
	var _r1 := cv.set_value("1")
	_check(progress.stats.report_to_backbone, "on with a backbone client makes the tracker report")
	_check(progress.stats.get_node_or_null(DotGameStatsReport.TIMER_NAME) != null, "and adds the flush timer")
	var _r2 := cv.set_value("0")
	_check(not progress.stats.report_to_backbone, "off stops it again")
	DotRegistry.unregister_instance(&"dot_backbone_client", client)
	client.free()
	_section_done()


## Runs a console command as the local console and returns what it replied. The reply sink is
## captured in an [Array]: [method DotConsole.execute] copies only the sink into a FRESH context,
## and a lambda captures by value, so a [PackedStringArray] appended to inside one is unchanged.
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


func _test_tickrate_reaches_the_timer() -> void:
	print("sv_tickrate reaches the record")

	# The chain, end to end in one test, because every link is silent when it breaks: sv_tickrate,
	# `Engine.physics_ticks_per_second`, the playground, the timer manager, the record.
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
	# The timer's half, when a server has one: its manager adopts the rate, and a record
	# is stamped with it, so a time means what it says.
	if _timer_linked():
		var manager: Object = game.run_timer.get("manager")
		_check(int(manager.get("tick_rate")) == 100, "the timer counts at 100",
			"%d" % int(manager.get("tick_rate")))
		_check(bool(manager.call("tick_rate_matches_engine")), "and nothing disagrees")
		var run: Object = load("res://addons/dot_timer/core/dot_timer_run.gd").call(
			"make", 0, &"normal", 1.0 / float(manager.get("tick_rate")))
		run.call("begin", 0.0)
		run.set("ticks", 250)
		run.call("finish", 0.0)
		var record: Object = load("res://addons/dot_timer/core/dot_timer_record.gd").call(
			"from_run", run, &"m", &"p", "P")
		_check(int(record.get("tick_rate")) == 100, "and a record is stamped with it")
		_check(absf(float(record.get("time")) - 2.5) < 0.001, "so its time means what it says",
			"%.3f s" % float(record.get("time")))

	# And the status line says so when they disagree, which is what somebody
	# debugging it will actually look at.
	var status := _run_command("pg_status")
	_check(_said(status, "tick rate"), "pg_status reports the tick rate", str(status))
	_check(_said(_run_command("workbench"), "workbench    off"), "the workbench is off by default and says so")
	_section_done()


func _test_timer_commands() -> void:
	print("timer commands")

	var styles := _run_command("pg_style")
	_check(_said(styles, "sideways"), "pg_style lists the styles", str(styles))
	# Points per style are the run timer's, so the list without it is ids and names.
	_check(_said(styles, "normal"), "with the normal style among them", str(styles))

	# The run timer's commands are `addons/pg_timer`'s, registered only when a server links
	# dot-timer; without it they are absent rather than answering "no timer" for ever.
	if not _timer_linked():
		for command in ["pg_top", "pg_track", "pg_cp", "pg_tp", "pg_cp_clear"]:
			_check(server.console.find_command(command) == null,
				"%s is not on a server without the run timer" % command)
		_section_done()
		return

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

	# Changing the map is CHANGEMAP, not GENERIC: what everybody plays next is the map
	# admin's call, and a reserved slot holds a flag without holding that one.
	var map_cmd: DotConCommand = server.console.find_command("pg_map")
	_check(map_cmd != null, "pg_map is registered")

	if map_cmd != null:
		_check(
			map_cmd.permission == DotAdminFlags.CHANGEMAP,
			"and needs the changemap flag",
			map_cmd.permission
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

	var edit_cmd: DotConCommand = server.console.find_command("spawn_add")
	_check(edit_cmd != null and edit_cmd.permission == DotAdminFlags.CONFIG, "the map-edit commands are installed behind the config flag")
	var shared: Object = _module().get("game")
	_check(shared.get("map_edit") != null and shared.get("map_edit") == _module().get("map_edit"), "the spawn-point tool is handed the same editor")
	_check(not bool((shared.get("map_edit_allowed_fn") as Callable).call(&"u4040")), "and a player with no admin session may not use it")
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


## B, the arena's loadout: dot-loadout's command over the arena's manager, closed outside the
## arena (the lead's call), `pg_arena_on` replicated so a client's B knows, and a choice made
## inside spawn protection in the hands at once.
func _test_arena_loadout() -> void:
	print("")
	print("the arena's loadout (B)")
	var module := _module()
	var arena: PlaygroundArena = module.get("arena")
	var cmd: Object = module.get("loadout_command")
	var on_cvar := server.console.find_cvar("pg_arena_on")
	_check(cmd != null and server.console.find_command("loadout") != null and server.console.find_cvar("mp_loadout_menu") != null
		and server.console.find_cvar("mp_loadout_allow") != null and server.console.find_cvar("mp_loadout_fixed") != null,
		"the server has the loadout command and the owner's mp_loadout_* cvars")
	_check(on_cvar != null and on_cvar.has_flag(DotConVar.FLAG_REPLICATED) and on_cvar.get_string() == "0"
		and not arena.enabled, "pg_arena_on is replicated and says the arena is off")
	if cmd == null or on_cvar == null:
		_section_done()
		return

	var _carol := game.add_player(&"u903", "Dana")
	var key: String = module.call(&"loadout_key", 903)
	var shut: Dictionary = await cmd.call(&"offer", key)
	var refused: Dictionary = await cmd.call(&"choose", null, key, {"primary": "impulse"})
	_check(not bool(shut.get("choose", true)) and str(shut.get("note")) == "Loadouts are in the arena."
		and not bool(refused.get("ok", true)), "outside the arena B is closed, and says the loadouts are in the arena", str(refused))

	_run_command("pg_arena on")
	_check(arena.enabled and on_cvar.get_string() == "1"
		and server.console.replicated_values().get("pg_arena_on", "") == "1", "pg_arena on says so to every client")

	var current := arena.loadouts.schema.slot(&"primary").default_item
	var other := &""
	for item in arena.loadouts.schema.choices_for(&"primary", DotLoadoutEntitlements.none()):
		if item.id != current:
			other = item.id
			break
	var chosen: Dictionary = await cmd.call(&"choose", null, key, {"primary": String(other)})
	var bridge: Object = module.get("bridge")
	var held: Variant = (bridge.get("_tool_of") as Dictionary).get(903, &"")
	_check(bool(chosen.get("ok")) and bool(chosen.get("now")) and held == other,
		"inside spawn protection a chosen weapon is in the hands at once (%s)" % other, "%s held %s" % [chosen, held])

	var _off := _run_command("pg_arena_on 0")
	_check(not arena.enabled, "and pg_arena_on is the switch as well: 0 turns the arena off")
	arena.release(&"u903")
	game.remove_player(&"u903")
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

	# Every stat an achievement watches must be declared, or it never unlocks and nothing errors.
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

	# Wipe stored progress first: the file store writes to `user://`, so each run would add sixty
	# spawns to the last and the "not the second" check would eventually fail on its own.
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

	# A LOWEST merge, the other end of dot-stats' four kinds.
	progress.achievements.record("pg-test", &"fastest_run", 40.0)
	progress.achievements.record("pg-test", &"fastest_run", 18.0)
	progress.achievements.record("pg-test", &"fastest_run", 55.0)
	_check(
		progress.achievements.is_unlocked("pg-test", &"under_20"),
		"a best time keeps the LOWEST reading, not the newest"
	)

	var zoned := DotDamage.make(1, 2, 5.0, _module().get("arena").combat.damage_type(&"kinetic"))
	zoned.hit_group = DotHitGroup.NECK
	zoned.weapon_id = &"probe"
	_module().get("arena").damage_landed.emit(&"pg-test", &"pg-victim", zoned)
	_check(
		progress.stats.session_values(&"pg-test").get_cell(DotStatsHitzones.HITS, "zone:neck") >= 1.0,
		"a hit with a hit_group is filed by body zone through the dot-stats hitzone hook"
	)

	var written: DotResult = await progress.achievements.flush()
	_check(written.ok, "progress writes to disk", str(written.error))
	_section_done()


## `pg_status`'s "time left" is the vote's clock, and an extend moves it. It once read the map
## session's clock after the vote took the map's end over. Through the console, asserting the
## session's clock did NOT move while the line did: that is the line reading the vote.
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


## Deletes any file the achievement store has written for [param player], so a run starts from
## nothing. A missing directory is not an error: the first run on a machine has none.
func _forget_stored_progress(progress: PlaygroundProgress, player: String) -> void:
	var dir := DirAccess.open(progress.progress_dir)

	if dir == null:
		return

	for file in dir.get_files():
		if file.contains(player):
			dir.remove(file)


## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3


## How long the copy may run before it is killed and this probe fails. A copy still running this
## long is hung, likeliest a scene whose script failed to parse (it never reaches `quit()` and
## prints nothing). `-- --exit-probe-seconds N` lowers it, which is how the deadline is armed.
const EXIT_PROBE_SECONDS := 300


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))


func module_roster_max() -> int:
	var module := _module()
	if module == null or module.game == null or module.game.player_stack == null:
		return -1
	return module.game.player_stack.roster.config.max_players
