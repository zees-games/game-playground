extends DotGameWorkbenchSuite

## game-playlot: the workbench over the config binder, one edit per profile set, the export and its cfg round trip.
## Run: godot --headless --path . res://examples/headless_workbench.tscn

const PlaygroundConfig := preload("../game/playground_config.gd")


func _make_config() -> DotConfig:
	return PlaygroundConfig.new()


func _make_binder(config: DotConfig) -> DotGameConfigBinder:
	return PlaygroundConfig.make_binder(config)
