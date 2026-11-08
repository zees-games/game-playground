extends DotGameNetchaosClient

const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Playground's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosClient). No fire action: the pilot only walks and jumps.


func _configure() -> void:
	client_scene = "res://game/playground.tscn"


func _prepare(label: String) -> Variant:
	return PlaygroundPresentation.use_scratch_settings(label)


func _roster() -> Array:
	var out: Array = []
	var world = _client.get("playground") if _client != null else null
	if world != null:
		out.append_array(world.players.values())
	var me = _client.get("player") if _client != null else null
	if me != null and not out.has(me):
		out.append(me)
	return out
