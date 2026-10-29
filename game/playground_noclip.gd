extends "playground_world.gd"

## Whether a player may use noclip: `(player_id: StringName) -> bool`. Empty means solo rules (any mode but `off`); the server
## module assigns one that asks the player's admin session. See [member PlaygroundConfig.noclip].
var noclip_policy: Callable = Callable()


## Whether [param id] may noclip under the config and [member noclip_policy].
func may_noclip(id: StringName) -> bool:
	var mode := "permission" if config == null else config.noclip
	if mode == "off":
		return false
	if mode == "everyone" or not noclip_policy.is_valid():
		return true
	return bool(noclip_policy.call(id))


## Grants or revokes each body's noclip permit (a replicated modifier) to match [method may_noclip]; the authority only.
func _sync_noclip_permits() -> void:
	for id in players:
		var body := players[id] as PlaygroundPlayer
		if body == null or body.controller == null:
			continue
		var want := may_noclip(id)
		if DotFpsAdminModifiers.has_noclip_permit(body.controller) != want:
			DotFpsAdminModifiers.set_noclip_permit(body.controller, want)
