extends SceneTree

## Rewrites cfg/game/game-playground/config_*/game.yml from PlaygroundConfig's fields: godot --headless --path . --script tools/cfg_templates.gd

const PlaygroundConfig := preload("../game/playground_config.gd")


func _init() -> void:
	var binder := PlaygroundConfig.make_binder(PlaygroundConfig.new())
	var files := binder.template_files()
	for path: String in files:
		var res := DotPaths.write_text("res://" + path, files[path])
		print("%s %s" % ["wrote" if res.ok else "FAILED", path])
	quit()
