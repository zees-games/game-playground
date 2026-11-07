extends SceneTree
## Boot-compile profile: loads the playground scene headless and reports how long the load
## took and how many scripts it pulled in (game and addons, by count and bytes). Run:
##   godot --headless --path . --script res://tools/boot_load_profile.gd
## Script compile is the whole cost of the load; compare the counts before and after a change.


func _walk(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			_walk(dir.path_join(sub), out)


func _report(label: String, root: String) -> void:
	var all: Array = []
	_walk(root, all)
	var count := 0
	var bytes := 0
	var per_addon := {}
	for p in all:
		if not ResourceLoader.has_cached(p):
			continue
		count += 1
		var size := FileAccess.get_file_as_string(p).length()
		bytes += size
		if root == "res://addons":
			var addon: String = p.split("/")[3]
			per_addon[addon] = int(per_addon.get(addon, 0)) + size
	print("PROFILE ", label, " scripts=", count, "/", all.size(), " bytes=", bytes)
	for addon in per_addon:
		print("PROFILE   ", addon, " bytes=", per_addon[addon])


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	load("res://game/playground.tscn")
	print("PROFILE load_ms=", Time.get_ticks_msec() - t0)
	_report("game", "res://game")
	_report("addons", "res://addons")
	quit()
