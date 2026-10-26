class_name PlaygroundProfileSchemas
extends RefCounted

## The schemas of the `config_<file>` kinds, for dot-profile's profile_check (a registered class with this static is a provider).

const PlaygroundConfig := preload("../game/playground_config.gd")


static func profile_schemas() -> Dictionary:
	var out := {}
	for set: DotProfileSet in PlaygroundConfig.make_binder(PlaygroundConfig.new()).profile_sets():
		out[set.rel_path] = set.schema
	return out
