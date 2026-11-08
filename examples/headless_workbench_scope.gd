extends DotGameCheckSuite

## The playground's Workbench lists only what is loaded: the arena mode's settings while `pg_arena` is on, a heading per
## weapon pack that has profiles, addon cvar sets when their cvars exist, and every heading says which side it edits.
##
## [codeblock]
## godot --headless --path . res://examples/headless_workbench_scope.tscn
## [/codeblock]

const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundProfiles := preload("../game/playground_profiles.gd")
const PlaygroundWorkbenchSets := preload("../game/playground_workbench_sets.gd")
const ROOT := "user://pg_wbscope"
const PACK := "pg_scope_pack"
const EMPTY_PACK := "pg_scope_empty"
const CHECKS := 17
const SECTIONS := 3


## What [PlaygroundWorkbenchSets] reads off a Playground, without the scene.
class FakeGame:
	extends RefCounted
	var profiles: Object = null
	var config_binder: DotGameConfigBinder = null
	var flashlight_binder: Object = null

	func flashlight_conf() -> Variant:
		return null


var _entered := 0
var _finished := 0
var _arena := false


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("game-playground: workbench scope")
	_write("addons/%s/weapon/scope_pistol.yml" % PACK, "weight: 1.0\nmagazine: 7\n")
	var root := ProjectSettings.globalize_path(ROOT)
	var profiles := PlaygroundProfiles.new()
	profiles.setup(PackedStringArray([root]))
	var game := FakeGame.new()
	game.profiles = profiles
	game.config_binder = PlaygroundConfig.make_binder(PlaygroundConfig.new())
	game.config_binder.roots = PackedStringArray([root])
	var _loaded := game.config_binder.load_layers()
	var _early := profiles.refine_weapon_entries(EMPTY_PACK, [])

	var wb := DotGameWorkbench.new()
	wb.panel_mode = 1
	wb.listen_host_fn = func() -> bool: return true
	wb.config = {"enabled": false}
	wb.thread_cvars = false
	wb.relevance_cvars = false
	wb.npc_lod_cvars = false
	PlaygroundWorkbenchSets.add_sets(wb, game, func() -> bool: return _arena)
	add_child(wb)
	_check(wb.start(profiles.runtime).ok, "the workbench starts")

	_entered += 1
	var kinds := _kinds(wb)
	_check(not kinds.has("config_arena"), "Playground only: no arena section", ", ".join(kinds))
	_check(not _headings(wb).any(func(h: String) -> bool: return h.contains("Arena")), "Playground only: no heading says Arena", " | ".join(_headings(wb)))
	_check(kinds.has("config_world") and kinds.has("config_server") and kinds.has("config_props"), "the playground's own settings are listed", ", ".join(kinds))
	_check(kinds.has("npc"), "the NPC profiles are listed", ", ".join(kinds))
	_check(not kinds.has("weapon"), "the weapon group is not a heading of its own")
	_check(not DotWorkbenchScope.owners(wb.api, DotWorkbenchScope.sections(wb.api, wb._labels)).has(PlaygroundWorkbenchSets.ARENA_OWNER), "the arena mode is not among the loaded owners")
	_arena = true
	kinds = _kinds(wb)
	var owners := DotWorkbenchScope.owners(wb.api, DotWorkbenchScope.sections(wb.api, wb._labels))
	_check(kinds.has("config_arena") and kinds.has("config_world"), "both loaded: the arena and the playground sections show", ", ".join(kinds))
	_check(owners.has(PlaygroundWorkbenchSets.GAME) and owners.has(PlaygroundWorkbenchSets.ARENA_OWNER), "both loaded: both owners are named", ", ".join(owners))
	_check(_headings(wb).has("Arena mode (pg_arena)  ·  server"), "the arena heading says it is server side", " | ".join(_headings(wb)))
	_arena = false
	_finished += 1

	_entered += 1
	var _refined := profiles.refine_weapon_entries(PACK, [{"id": "scope_pistol"}])
	kinds = _kinds(wb)
	var view := "weapon%s%s" % [DotWorkbenchSetView.SEP, PACK]
	_check(kinds.has(view), "a weapon pack scanned after the start is listed", ", ".join(kinds))
	_check(_headings(wb).has("Weapons: %s  ·  server, replicated" % PACK), "its heading names the pack and the side", " | ".join(_headings(wb)))
	_check(not kinds.has("weapon%s%s" % [DotWorkbenchSetView.SEP, EMPTY_PACK]), "a pack with no profiles stays off")
	var listed: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "list", "kind": view})
	_check(listed.ok and (listed.value["ids"] as Array).has("scope_pistol"), "the pack's profiles are listed under it", str(listed.value if listed.ok else listed.error.message))
	var edit: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": view, "id": "scope_pistol", "key": "magazine", "value": 9})
	_check(edit.ok and profiles.weapons.runtime_paths("scope_pistol").get("magazine") == 9, "an edit under the pack's heading reaches the weapon group", str(edit.error.message if not edit.ok else ""))
	_finished += 1

	_entered += 1
	var console := DotConsole.new()
	add_child(console)
	var _bounce := console.cvar("sv_grenade_bounce", "0.4", "how far a grenade bounces")
	var _on := console.cvar("sv_grenade_trails", "1", "trails").with_range(0.0, 1.0)
	var listed_sets := PlaygroundWorkbenchSets.add_cvar_sets(wb, console, profiles.runtime)
	kinds = _kinds(wb)
	_check(listed_sets == 1 and kinds.has("grenades") and not kinds.has("ragdolls"), "only the addon cvar sets whose cvars exist are listed", ", ".join(kinds))
	var types := PlaygroundWorkbenchSets.cvar_types(console, "sv_grenade")
	_check(types.get("sv_grenade_bounce") == "float" and types.get("sv_grenade_trails") == "bool", "cvar types follow the cvars", str(types))
	_finished += 1

	wb.free()
	console.free()
	profiles.release()
	_clean()
	_report_sections(_entered, _finished, SECTIONS, CHECKS)


func _kinds(wb: DotGameWorkbench) -> PackedStringArray:
	var out := PackedStringArray()
	for pair: Array in DotWorkbenchScope.sections(wb.api, wb._labels):
		out.append(String(pair[0]))
	return out


func _headings(wb: DotGameWorkbench) -> Array:
	return DotWorkbenchScope.sections(wb.api, wb._labels).map(func(p: Array) -> String: return String(p[1]))


func _write(rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT.path_join(rel).get_base_dir())
	var f := FileAccess.open(ROOT.path_join(rel), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _clean() -> void:
	DirAccess.remove_absolute(ROOT.path_join("addons/%s/weapon/scope_pistol.yml" % PACK))
	for d in ["addons/%s/weapon" % PACK, "addons/%s" % PACK, "addons", ""]:
		DirAccess.remove_absolute(ROOT.path_join(d))
