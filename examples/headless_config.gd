extends Node

## PlaygroundConfig through DotGameConfigBinder: fields, cvars, the arena and the shop reading them, strict refusal, the diff and the workbench round trip.
##
## [codeblock]
## godot --headless --path . res://examples/headless_config.tscn
## [/codeblock]

const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundAmbience := preload("../game/playground_ambience.gd")
const ROOT := "user://pg_cfgtest"
const GAME := "game-playground"
const CHECKS := 29

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String, _detail := "") -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _run() -> void:
	if OS.get_cmdline_user_args().has("--probe"):
		_probe()
		return
	print("game-playground: config binder")
	var config := PlaygroundConfig.new()
	var binder := PlaygroundConfig.make_binder(config)
	binder.strict = true
	_check(binder.load_layers().ok, "defaults load")
	_check(binder.diff().is_empty(), "no diff at the code defaults")
	var keys := PackedStringArray()
	for e: Dictionary in binder.schema():
		keys.append(e["key"])
	for k in ["arena_round_sec", "arena_score_limit", "arena_health", "arena_respawn_sec", "arena_friendly_fire", "wave_kill_reward", "arena_kill_reward", "max_players", "prop_budget", "map_seconds"]:
		_check(keys.has(k), "%s is exposed" % k)

	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	console.set_cvar("pg_arena_score_limit", "7")
	_check(config.arena_score_limit == 7 and binder.source_of("arena_score_limit") == "cvar", "a cvar writes the field")
	_check(binder.diff_yaml().contains("arena_score_limit: 7"), "the diff names the edit")
	var schema_path := "user://pg_config_schema.json"
	_check(binder.write_schema(schema_path).ok and FileAccess.file_exists(schema_path), "write_schema writes the schema")
	DirAccess.remove_absolute(schema_path)

	var bad := FileAccess.open("user://pg_config_bad.json", FileAccess.WRITE)
	bad.store_string('{"no_such_field": 1}')
	bad.close()
	var strict := PlaygroundConfig.make_binder(PlaygroundConfig.new(), "user://pg_config_bad.json")
	strict.strict = true
	_check(not strict.load_layers().ok, "strict: an unknown key is refused")
	DirAccess.remove_absolute("user://pg_config_bad.json")

	_layers()
	_templates(binder)

	var wb := DotGameWorkbench.new()
	wb.panel_mode = 1
	wb.config = {"enabled": false}
	for set: DotProfileSet in binder.profile_sets():
		wb.add_set(set, set.rel_path)
	add_child(wb)
	_check(wb.start().ok, "the workbench starts")
	binder.attach(wb.api.runtime)
	var listed := PackedStringArray()
	for kind: String in wb.api.kinds():
		var got: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "get", "kind": kind, "id": binder.profile_id})
		if got.ok:
			listed.append_array(PackedStringArray((got.value as Dictionary).get("values", {}).keys()))
	var missing := PackedStringArray()
	for k in keys:
		if not listed.has(k):
			missing.append(k)
	_check(missing.is_empty() and binder.profile_sets().size() == 3, "the workbench lists all %d keys over %d files" % [keys.size(), binder.profile_sets().size()], ",".join(missing))
	var res: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "config_arena", "id": binder.profile_id, "key": "wave_kill_reward", "value": 90})
	_check(res.ok and config.wave_kill_reward == 90, "a workbench edit reaches the live config")
	var files: Dictionary = wb.exporter.call("collect")
	var text: String = files.get("cfg/game/game-playground/config_arena/game.yml", "")
	_check(text.contains("wave_kill_reward: 90"), "the export holds the edit in the cfg layout")

	var ambient := PlaygroundAmbience.cvar_types()
	var odd := PackedStringArray()
	for name: String in ambient:
		if not name.begins_with("pg_ambient"):
			odd.append(name)
	_check(not ambient.is_empty() and odd.is_empty(), "the ambience set offers the pg_ambient* cvars", ",".join(odd))

	wb.free()
	console.free()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)



## Child process: loads the layers strictly over the test root and prints what the live config holds.
func _probe() -> void:
	var config := PlaygroundConfig.new()
	var binder := PlaygroundConfig.make_binder(config)
	binder.strict = true
	binder.roots = PackedStringArray([ProjectSettings.globalize_path(ROOT)])
	var loaded := binder.load_layers()
	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	print("PROBE ok=%s secs=%s secs_src=%s budget=%s budget_src=%s cvar=%s score=%s score_src=%s max=%s max_src=%s" % [
		loaded.ok, config.map_seconds, binder.source_of("map_seconds"), config.prop_budget, binder.source_of("prop_budget"),
		console.find_cvar("pg_prop_budget").get_string(), config.arena_score_limit, binder.source_of("arena_score_limit"),
		config.max_players, binder.source_of("max_players")])
	get_tree().quit(0)


func _write(rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT.path_join(rel).get_base_dir())
	var f := FileAccess.open(ROOT.path_join(rel), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _child() -> String:
	var out: Array = []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://examples/headless_config.tscn", "--", "--probe", "--pg-arena-score-limit=9", "--pg-max-players=12"], out, true)
	return "".join(PackedStringArray(out))


## A value set in a cfg file, the environment and argv each reaches the live config, and later layers win.
func _layers() -> void:
	_write("game/%s/config_server/game.yml" % GAME, "map_seconds: 1230.0\n")
	_write("game/%s/config_props/game.yml" % GAME, "prop_budget: 20\n")
	OS.set_environment("PLAYGROUND_PROP_BUDGET", "44")
	var text := _child()
	_check(text.contains("PROBE ok=true"), "the layers load strictly in a fresh process", text.right(300))
	_check(text.contains("secs=1230") and text.contains("secs_src=yml"), "a cfg file reaches the live config")
	_check(text.contains("budget=44") and text.contains("budget_src=env") and text.contains("cvar=44"), "the environment beats a second file and reaches the cvar")
	_check(text.contains("score=9") and text.contains("score_src=argv"), "argv alone reaches the config")
	_check(text.contains("max=12") and text.contains("max_src=argv"), "a second argv flag reaches it too")
	OS.unset_environment("PLAYGROUND_PROP_BUDGET")
	_write("game/%s/config_arena/game.yml" % GAME, "map_seconds: 99.0\n")
	_check(_child().contains("PROBE ok=false"), "strict: a key in the wrong file is refused")
	for f in ["config_server", "config_props", "config_arena"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ROOT.path_join("game/%s/%s/game.yml" % [GAME, f])))


## The shipped cfg files hold every key, in step with PlaygroundConfig, and change nothing as they are.
func _templates(binder: DotGameConfigBinder) -> void:
	var files := binder.template_files()
	_check(files.size() == 3, "three shipped cfg files", str(files.size()))
	var stale := PackedStringArray()
	for path: String in files:
		if not FileAccess.file_exists("res://" + path) or FileAccess.get_file_as_string("res://" + path) != files[path]:
			stale.append(path)
	_check(stale.is_empty(), "the shipped files match the config (run addons/dot_game/qa/dot_game_cfg_templates.gd)", ",".join(stale))
