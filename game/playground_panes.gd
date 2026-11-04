extends "playground_noclip.gd"

## Breakable map boxes (panes): damage, breaking, the shards and the impacts that break them.
## A layer of the playground node between the noclip and tick layers.
var _hits_buf: Array = []


## Damage to [param node] if it is a breakable map box; true when it was one. The one door
## shots, blasts and impacts all come through, as `hurt_prop` is for props.
func hurt_pane(node: Node, amount: float, by: StringName) -> bool:
	if not authoritative or not panes_break or node == null or not node.has_meta(&"pg_box"):
		return false
	var index := int(node.get_meta(&"pg_box"))
	if not panes.has(index):
		return false
	var pane: Dictionary = panes[index]
	var before := float(pane["health"])
	pane["health"] = before - amount
	var at := _pane_bounds(node).get_center() if node is Node3D else Vector3.ZERO
	var broke := float(pane["health"]) <= 0.0
	if broke:
		break_pane(index)
	confirm_hit(by, hit_victim_id(DotEntity.KIND_OTHER, index + 1), minf(amount, maxf(before, 0.0)), at, broke)
	return true


## A blast hurts every pane within [param radius] of [param at], less with distance.
func hurt_panes_in(at: Vector3, radius: float, amount: float, by: StringName) -> void:
	if radius <= 0.0:
		return
	for index: int in panes.keys():
		var node := (panes[index] as Dictionary)["node"] as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var distance := _pane_bounds(node).get_center().distance_to(at)
		distance = maxf(0.0, distance - _pane_bounds(node).size.length() * 0.5)
		if distance < radius:
			var _hit := hurt_pane(node, amount * clampf(1.0 - distance / radius, 0.0, 1.0), by)


## Breaks pane [param index] on this end: the box goes, and on the authority shards fly.
## A client calls it from the server's event and gets the same removal and the sound.
func break_pane(index: int) -> void:
	if not panes.has(index):
		return
	var pane: Dictionary = panes[index]
	panes.erase(index)
	broken_panes.append(index)
	var node := pane["node"] as Node3D
	var bounds := _pane_bounds(node) if node != null and is_instance_valid(node) else AABB()
	var material: StringName = pane["material"]
	if node != null and is_instance_valid(node):
		node.queue_free()
	if authoritative:
		_throw_shards(bounds, material)
	pane_broken.emit(index, bounds.get_center(), material)


## The world AABB of a map box, from its own collision shape.
static func _pane_bounds(node: Node3D) -> AABB:
	for child in node.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is BoxShape3D:
			var size := ((child as CollisionShape3D).shape as BoxShape3D).size
			return node.global_transform * AABB(-size * 0.5, size)
	return AABB(node.global_position, Vector3.ZERO)


## Debris in the pane's colour, flung outward, gone in `debris_seconds` like a broken prop's.
func _throw_shards(bounds: AABB, material: StringName) -> void:
	if props == null or config == null:
		return
	var largest := maxf(bounds.size.x * bounds.size.y, maxf(bounds.size.x * bounds.size.z, bounds.size.y * bounds.size.z))
	var count := clampi(int(ceil(largest * SHARDS_PER_M2)), 3, SHARDS_MAX)
	var colour := PlaygroundMaterials.look(String(material), Color.WHITE)
	colour.a = 1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(bounds.get_center())
	var interval := props.limits.spawn_interval if props.limits != null else 0.0
	if props.limits != null:
		props.limits.spawn_interval = 0.0
	for i in count:
		var at := bounds.position + Vector3(rng.randf(), rng.randf(), rng.randf()) * bounds.size
		var piece := props.spawn(&"debris", &"", at)
		if piece == null:
			break
		if piece.node is PlaygroundProp:
			(piece.node as PlaygroundProp).set_tint(colour)
		if piece.node is RigidBody3D:
			var out := (at - bounds.get_center())
			out.y = absf(out.y)
			(piece.node as RigidBody3D).linear_velocity = out.normalized() * rng.randf_range(2.0, 5.0) + Vector3.UP * 1.5
		_debris_expiry[piece.instance_id] = _clock_seconds() + config.debris_seconds
	if props.limits != null:
		props.limits.spawn_interval = interval


## Fast things breaking panes: a prop thrown into one, a player running into one. Read off the velocity at the end of the LAST
## tick, because the contact has already stopped them, and only its part along the pane's normal: running ALONG a wall is not into it.
func _pane_impacts() -> void:
	if not authoritative or not panes_break or panes.is_empty():
		_last_speed.clear()
		return
	var hits := _hits_buf
	hits.clear()
	for index: int in panes.keys():
		var node := (panes[index] as Dictionary)["node"] as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var bounds := _pane_bounds(node)
		var normal := _pane_normal(node)
		for prop: DotPropInstance in props.all_props():
			var body := prop.node as RigidBody3D
			if body == null or not body.is_inside_tree():
				continue
			var was: Vector3 = _last_speed.get(prop.instance_id, Vector3.ZERO)
			var into := absf(was.dot(normal))
			if into > PANE_IMPACT_SPEED and bounds.grow(0.5 + _reach_of(body)).has_point(body.global_position):
				hits.append([node, body.mass * into * 0.5])
		for id: StringName in players.keys():
			var player: PlaygroundPlayer = players[id]
			var was: Vector3 = _last_speed.get(id, Vector3.ZERO)
			# The chest for a wall, the feet for a floor: a player landing on thin ice has their
			# chest a metre above it, and the first version asked only the chest.
			var feet := player.controller.state.position + Vector3.UP * 0.1
			var near := bounds.grow(0.7)
			if absf(was.dot(normal)) > PANE_IMPACT_SPEED and (near.has_point(feet + Vector3.UP * 0.8) or near.has_point(feet)):
				hits.append([node, (panes[index] as Dictionary)["health"]])
	for hit: Array in hits:
		var _broke := hurt_pane(hit[0], float(hit[1]), &"")
	_last_speed.clear()
	for prop: DotPropInstance in props.all_props():
		if prop.node is RigidBody3D:
			_last_speed[prop.instance_id] = (prop.node as RigidBody3D).linear_velocity
	for id: StringName in players.keys():
		_last_speed[id] = (players[id] as PlaygroundPlayer).controller.state.velocity


## A pane's normal: its box's thinnest axis, in the world.
static func _pane_normal(node: Node3D) -> Vector3:
	for child in node.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is BoxShape3D:
			var size := ((child as CollisionShape3D).shape as BoxShape3D).size
			var axis := 0 if size.x <= size.y and size.x <= size.z else (1 if size.y <= size.z else 2)
			return node.global_basis[axis].normalized()
	return Vector3.UP


static func _reach_of(body: Node3D) -> float:
	for child in body.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			return (child as CollisionShape3D).shape.get_debug_mesh().get_aabb().size.length() * 0.5
	return 0.5
