extends "playground_noclip.gd"

## Breakable map boxes (panes): damage, breaking, the shards and the impacts that break them.
## A layer of the playground node between the noclip and tick layers.


## Damage to [param node] if it is a breakable map box; true when it was one. The one door
## shots, blasts and impacts all come through, as `hurt_prop` is for props.
func hurt_pane(node: Node, amount: float, by: StringName) -> bool:
	if not authoritative or not panes_break or node == null or not node.has_meta(&"pg_box"):
		return false
	var index := int(node.get_meta(&"pg_box"))
	var hit := DotPropPanes.damage(panes, index, amount)
	if hit.is_empty():
		return false
	var before := float(hit["before"])
	var at := DotPropPanes.bounds_of(node).get_center() if node is Node3D else Vector3.ZERO
	var broke: bool = hit["broke"]
	if broke:
		break_pane(index)
	confirm_hit(by, hit_victim_id(DotEntity.KIND_OTHER, index + 1), minf(amount, maxf(before, 0.0)), at, broke)
	return true


## A blast hurts every pane within [param radius] of [param at], less with distance.
func hurt_panes_in(at: Vector3, radius: float, amount: float, by: StringName) -> void:
	for hit: Array in DotPropPanes.blast_hits(panes, at, radius, amount):
		var _hurt := hurt_pane(hit[0], float(hit[1]), by)


## Breaks pane [param index] on this end: the box goes, and on the authority shards fly.
## A client calls it from the server's event and gets the same removal and the sound.
func break_pane(index: int) -> void:
	if not panes.has(index):
		return
	var pane: Dictionary = panes[index]
	panes.erase(index)
	broken_panes.append(index)
	var node := pane["node"] as Node3D
	var bounds := DotPropPanes.bounds_of(node) if node != null and is_instance_valid(node) else AABB()
	var material: StringName = pane["material"]
	if node != null and is_instance_valid(node):
		node.queue_free()
	if authoritative:
		_throw_shards(bounds, material)
	pane_broken.emit(index, bounds.get_center(), material)


## Debris in the pane's colour, flung outward, gone in `debris_seconds` like a broken prop's.
func _throw_shards(bounds: AABB, material: StringName) -> void:
	if props == null or config == null:
		return
	var colour := PlaygroundMaterials.look(String(material), Color.WHITE)
	colour.a = 1.0
	var interval := props.limits.spawn_interval if props.limits != null else 0.0
	if props.limits != null:
		props.limits.spawn_interval = 0.0
	for shard: Dictionary in DotPropPanes.shard_plan(bounds):
		var piece := props.spawn(&"debris", &"", shard["at"])
		if piece == null:
			break
		if piece.node is PlaygroundProp:
			(piece.node as PlaygroundProp).set_tint(colour)
		if piece.node is RigidBody3D:
			(piece.node as RigidBody3D).linear_velocity = shard["velocity"]
		_debris_expiry[piece.instance_id] = _clock_seconds() + config.debris_seconds
	if props.limits != null:
		props.limits.spawn_interval = interval


## Fast things breaking panes: a prop thrown into one, a player running into one. Read off the velocity at the end of the LAST
## tick, because the contact has already stopped them, and only its part along the pane's normal: running ALONG a wall is not into it.
func _pane_impacts() -> void:
	if not authoritative or not panes_break or panes.is_empty():
		_last_speed.clear()
		return
	var bodies: Array = []
	for prop: DotPropInstance in props.all_props():
		bodies.append([prop.instance_id, prop.node])
	var walkers: Array = []
	for id: StringName in players.keys():
		walkers.append([id, (players[id] as PlaygroundPlayer).controller.state.position])
	var hits := DotPropPanes.impact_hits(panes, bodies, walkers, _last_speed)
	for hit: Array in hits:
		var _broke := hurt_pane(hit[0], float(hit[1]), &"")
	_last_speed.clear()
	for prop: DotPropInstance in props.all_props():
		if prop.node is RigidBody3D:
			_last_speed[prop.instance_id] = (prop.node as RigidBody3D).linear_velocity
	for id: StringName in players.keys():
		_last_speed[id] = (players[id] as PlaygroundPlayer).controller.state.velocity
