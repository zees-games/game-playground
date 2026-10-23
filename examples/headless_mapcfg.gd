extends Node

const PlaygroundMapConfig := preload("../game/playground_map_config.gd")

## A map gets its file's values and the next map has them back; a key off the whitelist is refused.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapcfg.tscn
## [/codeblock]

const CHECKS := 7

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-playground: per-map cvars")
	var file := "res://cfg/game/game-playground/dot_map/map/pgt_mapcfg.yml"
	var out := FileAccess.open(file, FileAccess.WRITE)
	if out != null:
		out.store_string("pg_destruction: 1\npg_prop_surf: 0\nnot_listed: 3\n")
		out.close()
	var console := DotConsole.new()
	add_child(console)
	console.cvar("pg_destruction", "0", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("pg_prop_surf", "1", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("pg_other", "5", "", DotConVar.FLAG_ARCHIVE)
	var cfg := PlaygroundMapConfig.build(console)
	_check(out != null, "the test map file was written")

	var got := cfg.apply("pgt_mapcfg")
	_check(got.size() == 2, "the test map applies its two accepted keys (%s)" % [got])
	_check(console.find_cvar("pg_destruction").get_int() == 1, "pg_destruction is 1 on the test map")
	_check(console.find_cvar("pg_other").get_int() == 5, "a cvar outside the whitelist is untouched")

	cfg.apply("pg_flatgrass")
	_check(console.find_cvar("pg_destruction").get_int() == 0, "the next map has pg_destruction back")
	_check(console.find_cvar("pg_prop_surf").get_int() == 1, "and pg_prop_surf back")
	_check(cfg.applied().is_empty(), "a map with no file applies nothing")

	DirAccess.remove_absolute(file)
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what)
		print("  FAIL  %s" % what)
