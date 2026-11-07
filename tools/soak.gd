extends Node

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Soak on the real sandbox: N players wander one map for M simulated minutes through dot-bot's DotBotSoak, fed by dot-spawn's DotSpawnWatch.
## The playground has no bot brain (a sandbox has nothing to chase), so each stand-in holds a random heading for a second or three and jumps now and then,
## which is what walks them into walls, water, ramps and every prop and pane a map has. Run `./game.sh soak [map] [minutes]`; DotBotSoakConfig flags are accepted too.
## Writes .godot/test-logs/soak-<map>.json, prints the SOAK line, exits 1 on failure. No navigation, goals or combat here: stuck is lenient (they bump walls on purpose).

const DEFAULT_MAP := &"pg_flatgrass"
const DEFAULT_MINUTES := 1.0
const DEFAULT_BOTS := 4
const TICK_RATE := 64

var _game: Playground
var _tick := 0
var _rng := RandomNumberGenerator.new()
var _heading: Dictionary = {}
var _lost := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := PlaygroundPresentation.use_scratch_settings("soak")
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1]
	return fallback


func _run() -> void:
	var map_id := StringName(_arg("map", String(DEFAULT_MAP)))
	var cfg := DotBotSoakConfig.new()
	cfg.minutes = DEFAULT_MINUTES
	cfg.bots = DEFAULT_BOTS
	cfg.apply_cli()
	cfg.minutes = float(_arg("minutes", str(cfg.minutes)))
	cfg.bots = int(_arg("bots", str(cfg.bots)))
	# Wanderers press into walls for as long as a heading lasts; a real stuck is a long one. Nothing hurts, so no kills are expected.
	cfg.max_stuck_sec = maxf(cfg.max_stuck_sec, 20.0)
	cfg.require_kills_after_sec = -1.0
	_rng.seed = cfg.seed_value

	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.initial_map = map_id
	config.map_seconds = 0.0
	_game = Playground.new()
	_game.config = config
	_game.tick_rate = TICK_RATE
	_game.external_tick = true
	add_child(_game)
	# _ready awaits the first map change, so it may or may not be up after the first frame.
	for _i in range(600):
		if _game.booted:
			break
		await get_tree().process_frame
	if not _game.booted or _game.maps.current == null:
		_fail("no map %s" % map_id)
		return

	for i in range(cfg.bots):
		var id := StringName("u%d" % (900 + i))
		if _game.add_player(id, "Soak%d" % i) == null:
			_fail("add_player refused %s" % id)
			return
	await get_tree().physics_frame
	await get_tree().physics_frame

	var watch := DotSpawnWatch.new()
	watch.rules.enabled = true
	watch.rules.kill_y = -5000.0

	var soak := DotBotSoak.new(cfg)
	soak.watch = watch
	soak.movers_fn = _movers
	soak.object_count_fn = func() -> int: return int(Performance.get_monitor(Performance.OBJECT_COUNT))
	soak.step_fn = _step

	var delta := 1.0 / float(TICK_RATE)
	while not soak.is_done():
		soak.advance(delta)
		# Yield now and then so deferred frees and physics bodies catch up.
		if soak.ticks % 32 == 0:
			await get_tree().physics_frame

	var report := soak.finish()
	report["map"] = String(map_id)
	report["out_of_world"] = _lost
	if _lost > 0:
		report["ok"] = false
		(report["reasons"] as Array).append("%d wanderer-ticks outside the world" % _lost)
	print(DotBotSoak.summary(report))
	print(DotBotSoak.report_line(report))
	var path := ProjectSettings.globalize_path("res://.godot/test-logs/soak-%s.json" % map_id)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if soak.write_report(report, path) != OK:
		push_error("could not write %s" % path)
	# A world still loaded at quit can abort the process.
	_game.queue_free()
	for _i in range(3):
		await get_tree().process_frame
	get_tree().quit(0 if report["ok"] else 1)


func _step(_delta: float) -> void:
	_tick += 1
	for id: StringName in _game.players:
		var body: PlaygroundPlayer = _game.players[id]
		var at := body.controller.state.position
		if not at.is_finite() or absf(at.y) > 5000.0 or Vector2(at.x, at.z).length() > 20000.0:
			_lost += 1
		var held: Dictionary = _heading.get(id, {"until": 0, "yaw": 0.0})
		if _tick >= int(held["until"]):
			held = {"until": _tick + _rng.randi_range(64, 192), "yaw": _rng.randf_range(-180.0, 180.0)}
			_heading[id] = held
		var command := DotFpsCommand.new()
		command.yaw = float(held["yaw"])
		command.pitch = 0.0
		command.move = Vector2(0.0, 1.0)
		command.set_button(DotFpsCommand.BUTTON_JUMP, _tick % 96 < 3)
		body.controller.apply_command(command)
	_game.tick_once(_tick)


func _movers() -> Array:
	var out: Array = []
	for id: StringName in _game.players:
		var body: PlaygroundPlayer = _game.players[id]
		out.append({"id": id, "position": body.controller.state.position, "kind": &"bot", "has_goal": false})
	return out


func _fail(why: String) -> void:
	printerr("SOAK setup failed: ", why)
	get_tree().quit(2)
