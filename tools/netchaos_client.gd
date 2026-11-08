extends DotGameNetchaosClient

const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Playground's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosClient). No fire action: the pilot only walks and jumps.


func _configure() -> void:
	client_scene = "res://game/playground.tscn"


func _prepare(label: String) -> Variant:
	return PlaygroundPresentation.use_scratch_settings(label)


func _roster() -> Array:
	var world = _client.get("playground") if _client != null else null
	return world.players.values() if world != null else []
