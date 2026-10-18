extends Node

## The playground's side of dot-timer: run timing, courses, records and practice checkpoints,
## for a server that added the timer.
##
## [b]The timer does not ship with the game.[/b] A sandbox has no use for one until somebody
## builds a course, so the playground runs without it and this hook does nothing unless
## `res://addons/dot_timer` is there: a server owner links or copies dot-timer's addon in (or a
## subscriber delivers it), and on the next start the courses' zones are timed again. The
## playground itself knows only the duck-typed surface it calls on [member Playground.run_timer]
## (`tick`, `add_player`, `on_map_changed`, `start_for`, ...), all of which is this file.
##
## [b]Every dot-timer script is loaded by path and every call goes through [method Object.call].[/b]
## A script that named `DotTimerManager` would not compile in a checkout without the addon, and
## the game's parse pass checks this file too. That is the whole reason it reads like
## reflection.
##
## Not carried over when the timer moved out: the zone painting commands (`pg_zone*`; a map's
## zones come from its `.zones.json` or its own `timer_zones()`), the server-to-client run
## replication (a connected client times its own predicted run for the HUD, and the server's
## verdict reaches it as a notice), and the HUD's personal-best and record comparison.

const CHANNEL := "pg.timer"

const ROOT := "res://addons/dot_timer"
const PLUGIN := ROOT + "/plugin.cfg"
const MANAGER := ROOT + "/runtime/dot_timer_manager.gd"
const CONFIG := ROOT + "/core/dot_timer_config.gd"
const STYLE := ROOT + "/core/dot_timer_style.gd"
const ZONE := ROOT + "/core/dot_timer_zone.gd"
const ZONE_SET := ROOT + "/core/dot_timer_zone_set.gd"
const TRACK := ROOT + "/core/dot_timer_track.gd"
const RULES := ROOT + "/core/dot_timer_rules.gd"
const RUN := ROOT + "/core/dot_timer_run.gd"
const REPLAY := ROOT + "/replay/dot_timer_replay.gd"
const HUD := ROOT + "/ui/dot_timer_hud.gd"

## The DotTimerManager, or null when the addon is absent.
var manager: Node = null

var game: Node = null

var authoritative: bool = true

var _send: Callable = Callable()

## DotTimerZone.Kind, name -> value.
var _kind: Dictionary = {}

var _rules: GDScript = null
var _track: GDScript = null
var _run: GDScript = null
var _flags: Dictionary = {}

## Reused by [method _zone_at] every tick: a typed Array[DotTimerZone], built by reflection.
var _found: Array = []

## player id -> whether admin help was on last tick, for the edge log.
var _assisted: Dictionary = {}

var _hud: Control = null
var _hud_block: Control = null
var _hud_player: StringName = &""


func playground_register(menu) -> void:
	if not FileAccess.file_exists(PLUGIN):
		DotLog.info(CHANNEL, "dot-timer is not installed; no run timer", {"looked_for": ROOT})
		return

	game = menu.host
	authoritative = menu.authoritative
	_send = menu.send_fn

	var zone_script: GDScript = load(ZONE)
	_kind = zone_script.get_script_constant_map()["Kind"]
	_found = Array([], TYPE_OBJECT, &"Resource", zone_script)
	_rules = load(RULES)
	_track = load(TRACK)
	_run = load(RUN)
	_flags = (load(REPLAY) as GDScript).get_script_constant_map()

	# A DotTimerConfig rather than exports one at a time, so the timer is configured through the
	# same layered path as everything else. The game has already resolved its tick rate from
	# `sv_tickrate`, so the timer is handed that rather than reading the engine a second time.
	var config: Object = (load(CONFIG) as GDScript).new()
	config.set("tick_rate", int(game.get("tick_rate")))
	config.set("default_tick_rate", int(game.get("tick_rate")))
	config.set("authoritative", authoritative)
	config.set("record_runs", true)
	config.set("records_directory", game.config.records_directory)
	config.set("record_replays", game.config.record_replays)
	config.set("fastest_expected_speed", 40.0)

	manager = (load(MANAGER) as GDScript).new()
	manager.name = "Timers"
	manager.set("config", config)
	add_child(manager)

	var styles: Array = (load(STYLE) as GDScript).call("defaults")
	for style in styles:
		# Air starts on: a hopper leaves the start pad mid-hop more often than not, and the
		# prespeed clamp in [method _post_move] is what guards the dive-through.
		style.set("allow_air_start", true)
	manager.call("set_styles", styles)

	manager.connect("effect_requested", _on_effect_requested)
	manager.connect("player_finished", _on_player_finished)
	# Only the authority files: a client's timer is its prediction of the run, for the HUD,
	# and its refusals ("not authoritative") would read as the server's.
	if authoritative:
		manager.connect("record_accepted", _on_record_accepted)
		manager.connect("record_refused", _on_record_refused)

	_define_boards()
	game.call("attach_run_timer", self)


func _define_boards() -> void:
	var boards: DotLeaderboardManager = game.get("boards")
	if boards == null:
		return

	var fastest := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME)
	fastest.display_name = "Fastest time"
	boards.define(fastest)

	var top_speed := DotLeaderboardDef.make(&"top_speed", DotLeaderboardDef.Kind.POINTS)
	top_speed.display_name = "Highest speed"
	top_speed.decimals = 1
	top_speed.unit = "m/s"
	boards.define(top_speed)

	var points := DotLeaderboardDef.make(&"points", DotLeaderboardDef.Kind.POINTS)
	points.display_name = "Ranking points"
	points.decimals = 1
	boards.define(points)


# --- What the playground calls ---------------------------------------------------

## Once a tick, after every move: the timer decides crossings from where the move put them.
func tick(_tick: int) -> void:
	for id in game.players:
		var player: Node = game.players[id]
		var state: DotFpsState = player.controller.state
		manager.call("tick_player",
			game.record_key(id), state.position, state.velocity, state.is_grounded(), true,
			state.yaw, state.pitch, state.previous_buttons, _replay_flags(player)
		)


func set_tick_rate(rate: int) -> void:
	manager.call("set_tick_rate", rate)


func add_player(id: StringName, player: Node) -> void:
	var key: StringName = game.record_key(id)
	var added: DotResult = manager.call("add_player", key, player.display_name)
	if not added.ok:
		DotLog.result(CHANNEL, "a player could not be timed", added)
		return

	player.timer = manager.call("timer_for", key)
	player.post_move_fn = _post_move
	_on_style_changed(player.movement_style, player)
	player.style_changed.connect(_on_style_changed.bind(player))


func remove_player(id: StringName) -> void:
	manager.call("remove_player", game.record_key(id))
	_assisted.erase(id)


## dot-timer has no idea a vehicle exists. Getting in stops a run on a foot track; on a
## DRIVEN track (the map says which) the car is the point, so it is getting out that stops it.
func on_seated(player: Node) -> void:
	if player.timer != null and not _driven(player.timer.get("track")):
		player.stop_run(&"teleport")


func on_unseated(player: Node) -> void:
	if player.timer != null and _driven(player.timer.get("track")):
		player.stop_run(&"teleport")


func on_map_changing() -> void:
	for id in game.players:
		game.players[id].stop_run(&"reset")


## A map that carries its own zones hands them over (`timer_zones()`, duck-typed, so a
## delivered course map can still be written against dot-timer); one that ships a JSON file
## has already had it read by dot-map into `maps.zones_json`.
func on_map_changed(map: DotMapDef, loaded: Node) -> void:
	var zones: Object = null

	if loaded != null and loaded.has_method("timer_zones"):
		zones = loaded.call("timer_zones")

	var text: String = game.maps.zones_json
	if zones == null and text != "":
		var parsed: DotResult = (load(ZONE_SET) as GDScript).call("from_json", text)
		if parsed.ok:
			zones = parsed.value
		else:
			DotLog.warn(CHANNEL, "a map's zone file could not be read", {
				"map": String(map.id) if map != null else "", "why": parsed.error.message
			})

	# A map with no zones still gets a set, named for it: the manager files every record under
	# its zones' map id, so with none a finish made by command would land on a board called
	# nothing. A zone file that forgot its map id takes the loaded map's for the same reason.
	if zones == null and map != null:
		zones = (load(ZONE_SET) as GDScript).new()
	if zones != null and map != null and (zones.get("map_id") == null or String(zones.get("map_id")) == ""):
		zones.set("map_id", map.id)

	var bound: DotResult = manager.call("set_zones", zones)
	if not bound.ok:
		DotLog.result(CHANNEL, "the zones could not be bound", bound)

	DotLog.info(CHANNEL, "zones for the map", {
		"map": String(map.id) if map != null else "", "zones": _zones().size()
	})


## The main track and every track with a zone on this map, sorted.
func tracks() -> Array:
	var out: Array = [0]
	for zone in _zones():
		var track := int(zone.get("track"))
		if not out.has(track):
			out.append(track)
	out.sort()
	return out


func track_of(id: StringName) -> int:
	var timer: Object = manager.call("timer_for", game.record_key(id))
	return int(timer.get("track")) if timer != null else 0


## The track's SPAWN zone as `{at, yaw}`, or empty for the map's own spawn.
func start_for(track: int) -> Dictionary:
	var zones: Object = manager.get("zones")
	if zones == null:
		return {}
	var spawn: Object = zones.call("first_of_kind", _kind["SPAWN"], track)
	if spawn == null:
		return {}
	return {"at": spawn.get("destination"), "yaw": float(spawn.get("destination_yaw"))}


## Before records were keyed by account they were keyed by the session's `u<userid>`, a
## server-local counter that cannot be mapped back to anybody. Such rows are written to
## `legacy_records.jsonl` (in the records directory, else `user://`) and then removed with
## the manager's `wipe_player`, which re-scores every board they touched. Nothing is deleted
## before it is written. Idempotent. Returns how many rows were moved.
func retire_legacy_records() -> int:
	var store: Object = manager.get("store")
	if not authoritative or store == null:
		return 0
	var listed: DotResult = await store.call("maps")
	if not listed.ok:
		return 0
	var legacy := {}
	for row in (listed.value as Array):
		var on_map: DotResult = await store.call("records_on_map", StringName(str((row as Dictionary).get("map", ""))))
		if not on_map.ok:
			continue
		for record in (on_map.value as Array):
			var key: StringName = record.get("player_id")
			if game.is_legacy_key(key):
				legacy[key] = true
	if legacy.is_empty():
		return 0

	var base: String = game.config.records_directory.strip_edges()
	var path := (base if base != "" else "user://").path_join("legacy_records.jsonl")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var out := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if out == null:
		DotLog.error(CHANNEL, "legacy records could not be archived; they stay where they are", {
			"path": path, "why": error_string(FileAccess.get_open_error()),
		})
		return 0
	out.seek_end()

	var moved := 0
	for key in legacy:
		var theirs: DotResult = await store.call("records_of", key, {"stage": -1})
		if not theirs.ok:
			continue
		for record in (theirs.value as Array):
			out.store_line(JSON.stringify(record.call("to_dictionary")))
		out.flush()
		var wiped: DotResult = await manager.call("wipe_player", key)
		if wiped.ok:
			moved += int(wiped.value)
	out.close()
	DotLog.info(CHANNEL, "records keyed by a session number were moved aside", {
		"players": legacy.size(), "records": moved, "archive": path,
	})
	return moved


func describe() -> Dictionary:
	return {
		"zones": _zones().size(),
		"players": int(manager.call("player_count")),
		"tick_rate": int(manager.get("tick_rate")),
		"tracks": tracks(),
	}


# --- On the tick ------------------------------------------------------------------

## After the move, on every end that simulates the player (a prediction replay included).
## The timer decides and the game acts: dot-timer never moves a player.
func _post_move(player: Node, state: DotFpsState) -> void:
	var timer: Object = player.timer
	if timer == null:
		return
	var controller: DotFpsController = player.controller

	# An admin's help makes a run assisted every tick it is on, so a run begun with it on
	# carries it too; `taint` is dot-timer's mark and the run is never filed.
	var helped := (
		DotFpsAdminModifiers.is_noclipped(controller)
		or not is_equal_approx(DotFpsAdminModifiers.speed_of(controller), 1.0)
		or not is_equal_approx(DotFpsAdminModifiers.gravity_of(controller), 1.0)
	)
	if helped:
		timer.call("taint")
	# On the edge, at INFO: "my time was not filed" is what an admin will be asked about.
	if helped != bool(_assisted.get(player.player_id, false)):
		_assisted[player.player_id] = helped
		if helped:
			DotLog.info(CHANNEL, "admin help is on: this player's runs are assisted and will not be filed",
				{"player": String(player.player_id)})
		else:
			DotLog.debug(CHANNEL, "admin help is off", {"player": String(player.player_id)})

	# The prespeed limit runs inside the simulation, because clamping speed changes where
	# the player ends up. `in_zone`, not `is_inside`, which answers only for EFFECT zones.
	var style: DotFpsStyle = player.movement_style
	if style != null and style.prespeed_limit > 0.0 and bool(timer.call("in_zone", _kind["START"])):
		state.velocity = _rules.clamp_prespeed(state.velocity, style.prespeed_limit)

	var speed_zone: Object = timer.call("effect", _kind["SPEED_LIMIT"])
	if speed_zone != null:
		state.velocity = _rules.apply_speed_limit(state.velocity, speed_zone)

	var step := 1.0 / float(maxi(1, controller.tick_rate))

	# PUSH and GRAVITY are read where the player IS this tick, not from `timer.effect()`:
	# a predicting client replays ticks with the timer standing at the newest sample, and a
	# replay across a booster's edge was pushed differently from the first time.
	var push_zone := _zone_at(timer, state.position, _kind["PUSH"])
	if push_zone != null:
		state.velocity = _rules.apply_push(state.velocity, push_zone, step)

	# Air only: on the ground gravity is what holds a player to the floor.
	var gravity_zone := _zone_at(timer, state.position, _kind["GRAVITY"])
	if gravity_zone != null and not state.is_grounded() and controller.tunables != null:
		state.velocity.y += controller.tunables.gravity * (1.0 - float(gravity_zone.get("number"))) * step


## The EFFECT zone of [param kind] at [param point], or null; the last found wins, as the
## timer's own effects resolve. Not track-filtered, as dot-timer's effects are not.
func _zone_at(timer: Object, point: Vector3, kind: int) -> Object:
	var index: Object = timer.get("index")
	if index == null:
		return null
	index.call("zones_at", point, _found)
	var found: Object = null
	for zone in _found:
		if int(zone.get("kind")) == kind:
			found = zone
	return found


## Ducked, jumped and teleported, for the replay; a ghost that is never told is smeared
## across every teleport.
func _replay_flags(player: Node) -> int:
	var flags := 0
	var state: DotFpsState = player.controller.state
	if state.crouch_fraction > 0.5:
		flags |= int(_flags["FLAG_DUCKED"])
	if state.time_since_jump < 1.5 / float(maxi(player.controller.tick_rate, 1)):
		flags |= int(_flags["FLAG_JUMPED"])
	if player.take_teleported():
		flags |= int(_flags["FLAG_TELEPORT"])
	return flags


## The ranking half of a style follows the movement half, so a sideways run is ranked as one.
func _on_style_changed(style: DotFpsStyle, player: Node) -> void:
	if style == null or player.timer == null:
		return
	var ranking: Object = manager.call("style_for", style.id)
	if ranking != null:
		player.timer.call("set_style", ranking)


# --- The timer's events ------------------------------------------------------------

func _on_effect_requested(key: StringName, zone: Object) -> void:
	var id: StringName = game.match_id(key)
	var player: Node = game.players.get(id)
	if player == null:
		return
	var kind := int(zone.get("kind"))
	if kind == _kind["RESPAWN"] or kind == _kind["SLAY"]:
		game.spawn_player(id)
	elif kind == _kind["TELEPORT"]:
		# Part of the route (asked only for the player's own track), so the run is kept.
		player.teleport(zone.get("destination"), float(zone.get("destination_yaw")), true)


## The movement statistics are the controller's and the run is the timer's; this is where
## they meet.
func _on_player_finished(key: StringName, _finished: Object) -> void:
	var player: Node = game.players.get(game.match_id(key))
	if player == null:
		return
	manager.call("note_stats", key, player.controller.stats.to_dictionary())
	player.controller.stats.reset()


func _on_record_accepted(record: Object, _previous: Object, rank: int) -> void:
	var key: StringName = record.get("player_id")
	var name_of: String = record.get("player_name")
	var scope := {
		"map": String(record.get("map_id")), "track": str(record.get("track")), "style": String(record.get("style_id")),
	}
	var stats: Dictionary = record.get("stats")
	var boards: DotLeaderboardManager = game.get("boards")

	# A seat with no account keeps its session number as its key, and a session number is
	# nobody: its time stands for this process only, and the boards never get a row for it.
	if boards != null and not game.is_legacy_key(key):
		await boards.submit(&"fastest", scope, key, name_of, float(record.get("time")))
		if stats.has("max_speed"):
			await boards.submit(&"top_speed", scope, key, name_of, float(stats["max_speed"]))
		# Points are global: the sum of what a player has earned on the server.
		var totals := DotStatSet.new()
		totals.add(&"points", float(record.get("points")))
		totals.add(&"completions", 1.0)
		await boards.add_stats(key, totals)
		await boards.publish_stat(&"points", {}, key, name_of, &"points")

	# The player may have left during any of the awaits above.
	var who: Object = manager.call("player", key)
	if who == null or who.get("last_finished") == null:
		return
	_filed(game.match_id(key), float(who.get("last_finished").call("time")), rank, "")


## Reported, not swallowed: "I finished and nothing happened" is the commonest complaint on
## a timer server, and the reason is almost always one the player could have been told.
func _on_record_refused(key: StringName, refused: Object, reason: String) -> void:
	var id: StringName = game.match_id(key)
	DotLog.info(CHANNEL, "a run was not recorded", {"player": String(id), "why": reason})
	_filed(id, float(refused.call("time")) if refused != null else -1.0, 0, reason)


func _filed(id: StringName, time: float, rank: int, reason: String) -> void:
	game.run_filed.emit(id, time, rank, reason)
	if _send.is_valid():
		_send.call({"player": String(id), "time": time, "rank": rank, "reason": reason})


## On a client: the server's verdict on a run, shown as the game's own `run_filed`.
func playground_receive(msg: Dictionary) -> void:
	if authoritative or game == null:
		return
	game.run_filed.emit(StringName(str(msg.get("player", ""))), float(msg.get("time", -1.0)),
		int(msg.get("rank", 0)), str(msg.get("reason", "")))


# --- The HUD -----------------------------------------------------------------------

func attach_hud(hud: Control, player_id: StringName) -> void:
	var script: GDScript = load(HUD)
	var block: Control = script.new()
	block.name = "Timer"
	block.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The whole rect: the block places itself in a corner of whatever it is given. Top left,
	# because a sandbox's bottom centre is where the spawn menu and the tool prompts go.
	block.set("corner", script.get_script_constant_map()["Placement"]["TOP_LEFT"])
	block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.set_timer_hud(block)
	_hud = hud
	_hud_block = block
	_hud_player = player_id
	hud.status_fn = _status

	manager.connect("player_staged", func(key: StringName, number: int, split: float) -> void:
		if game.match_id(key) == _hud_player and is_instance_valid(_hud):
			_hud.notice("Stage %d — %s" % [number, _run.format_time(split)])
	)


func _process(_delta: float) -> void:
	if _hud_block == null or not is_instance_valid(_hud_block):
		return
	var player: Node = game.players.get(_hud_player)
	if player == null or player.timer == null:
		return
	var timer: Object = player.timer
	var style: Object = timer.get("style")
	_hud_block.set("style_name", str(style.get("display_name")) if style != null else "")
	_hud_block.call("show_run", timer.get("run"), player.speed(), player.controller.stats.to_dictionary())


## The run's parts of the HUD's status line: checkpoints, PRACTICE (a run that used one is
## never filed, and the finish line is the worst moment to learn it) and the track, always.
func _status(player_id: StringName) -> PackedStringArray:
	var parts := PackedStringArray()
	var key: StringName = game.record_key(player_id)
	var checkpoints: Object = manager.call("checkpoints_for", key)
	if checkpoints != null and not bool(checkpoints.call("is_empty")):
		parts.append("cp %d/%d" % [int(checkpoints.get("index")) + 1, int(checkpoints.call("count"))])
	var timer: Object = manager.call("timer_for", key)
	if timer != null:
		if bool(timer.get("run").get("used_checkpoints")):
			parts.append("PRACTICE")
		parts.append(_track.name_of(int(timer.get("track"))))
	return parts


## The client's track and checkpoint keys.
func on_key(action: StringName, player_id: StringName, hud: Control) -> void:
	var said := ""
	match action:
		&"track":
			said = _cycle_track(player_id)
		&"checkpoint_save":
			said = checkpoint(player_id, 0)
		&"checkpoint_load":
			said = checkpoint(player_id, 1)
		&"checkpoint_clear":
			said = checkpoint(player_id, 2)
		&"checkpoint_next":
			said = checkpoint(player_id, 3)
	if said != "" and hud != null:
		hud.notice(said)


func _cycle_track(player_id: StringName) -> String:
	var timer: Object = manager.call("timer_for", game.record_key(player_id))
	if timer == null:
		return ""
	var all := tracks()
	if all.size() < 2:
		return "This map has one track."
	var next: int = all[(all.find(int(timer.get("track"))) + 1) % all.size()]
	if not bool(timer.call("set_track", next)):
		return ""
	# To the new track's start: staying put leaves a course timer that can never start.
	game.spawn_player(player_id)
	return "Track: %s" % _track.name_of(next)


## Practice checkpoints: 0 save, 1 go to, 2 forget, 3 next. Saving is free; going to one is
## a teleport, which flags the run as practice. Returns what to tell the player.
func checkpoint(player_id: StringName, action: int, which: int = -1) -> String:
	var player: Node = game.players.get(player_id)
	var checkpoints: Object = manager.call("checkpoints_for", game.record_key(player_id))
	if player == null or checkpoints == null:
		return "Only a player has checkpoints."
	var state: DotFpsState = player.controller.state
	match action:
		0:
			var saved: DotResult = checkpoints.call("save", state.position, state.velocity,
				state.yaw, state.pitch, state.is_grounded(), state.is_crouched())
			if not saved.ok:
				return saved.error.message
			return "Checkpoint %d saved." % int(checkpoints.call("count"))
		1:
			if which >= 0:
				checkpoints.set("index", clampi(which, 0, maxi(int(checkpoints.call("count")) - 1, 0)))
			# load_current(), not peek(): this is the teleport, and the teleport is what flags it.
			var point: Object = checkpoints.call("load_current")
			if point == null:
				return "You have no checkpoints. C (or pg_cp) saves one."
			player.teleport(point.get("position"), float(point.get("yaw")))
			state.velocity = point.get("velocity")
			state.pitch = float(point.get("pitch"))
			return "Checkpoint %d of %d." % [int(checkpoints.get("index")) + 1, int(checkpoints.call("count"))]
		2:
			checkpoints.call("clear")
			# Said, because it is what a player assumes: clearing does not launder a run.
			return "Checkpoints cleared. The current run is still flagged."
		3:
			if checkpoints.call("next") == null:
				return ""
			return "Checkpoint %d of %d." % [int(checkpoints.get("index")) + 1, int(checkpoints.call("count"))]
	return ""


# --- Commands ----------------------------------------------------------------------

## The module's commands, bound only when the timer is here. [param target_fn] is the
## module's `_target(ctx, allow_named)`: a player for themself, the console for anybody.
func bind_commands(add_command: Callable, target_fn: Callable) -> void:
	add_command.call("pg_timer", func(ctx: DotCmdContext) -> void:
		var run: Object = manager.call("run_for", game.record_key(target_fn.call(ctx, true)))
		if run == null:
			ctx.reply("No timer for that player.")
		else:
			ctx.reply_lines(run.call("describe_lines")),
		"Show a player's run, or your own", "").with_chat()

	add_command.call("pg_track", func(ctx: DotCmdContext) -> void:
		var id: StringName = target_fn.call(ctx, false)
		if id == &"" or not game.players.has(id):
			ctx.reply("Only a player can switch track.")
			return
		if ctx.args.is_empty():
			ctx.reply("Track: %s" % _track.name_of(track_of(id)))
			return
		var text := " ".join(Array(ctx.args))
		var track: int = _track.parse(text)
		# Refused rather than read as "main": that would file a record on a track nobody asked for.
		if track < 0:
			ctx.reply("No such track: %s" % text)
			return
		if not bool(manager.call("set_player_track", game.record_key(id), track)):
			ctx.reply("Already on %s." % _track.name_of(track))
			return
		game.spawn_player(id)
		ctx.reply("Track: %s" % _track.name_of(track)),
		"Switch track: main, or bonus <n>", "").with_chat()

	add_command.call("pg_top", func(ctx: DotCmdContext) -> void:
		var store: Object = manager.get("store")
		if game.maps.current == null or store == null:
			ctx.reply("No records here.")
			return
		var timer: Object = manager.call("timer_for", game.record_key(target_fn.call(ctx, false)))
		var track := int(timer.get("track")) if timer != null else 0
		var style: StringName = &"normal"
		if timer != null and timer.get("style") != null:
			style = timer.get("style").get("id")
		var listed: DotResult = await store.call("top", game.maps.current.id, track, style, 10)
		if not listed.ok:
			ctx.reply_error(listed)
			return
		if (listed.value as Array).is_empty():
			ctx.reply("Nobody has finished %s on %s yet." % [String(game.maps.current.id), String(style)])
			return
		var lines := PackedStringArray(["%s — %s, %s:" % [game.maps.current.name_or_id(), _track.name_of(track), String(style)]])
		var rows: Array = listed.value
		for i in rows.size():
			lines.append("  %2d. %-20s %s" % [i + 1, rows[i].get("player_name"), rows[i].call("formatted_time")])
		ctx.reply_lines(lines),
		"The fastest times on this map, track and style", "").with_chat()

	add_command.call("pg_cp", func(ctx: DotCmdContext) -> void:
		ctx.reply(checkpoint(target_fn.call(ctx, false), 0)),
		"Save a practice checkpoint", "").with_chat()
	add_command.call("pg_tp", func(ctx: DotCmdContext) -> void:
		var which := ctx.args[0].to_int() - 1 if ctx.args.size() > 0 and ctx.args[0].is_valid_int() else -1
		ctx.reply(checkpoint(target_fn.call(ctx, false), 1, which)),
		"Go back to a practice checkpoint", "").with_chat()
	add_command.call("pg_cp_clear", func(ctx: DotCmdContext) -> void:
		ctx.reply(checkpoint(target_fn.call(ctx, false), 2)),
		"Forget them all", "").with_chat()


# --- Helpers -----------------------------------------------------------------------

func _zones() -> Array:
	var zones: Object = manager.get("zones") if manager != null else null
	return zones.get("zones") if zones != null else []


func _driven(track: Variant) -> bool:
	var map: Node = game.current_map_node()
	return map != null and map.track_is_driven(int(track))
