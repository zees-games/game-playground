extends "playground_tool.gd"

## Lays patrol waypoints and links them: the route armed NPCs of yours walk when they have
## nothing to fight.
##
## Left click on the ground puts a point down; with [code]chain[/code] on (the default) it is
## linked to the one before, so clicking along a corridor is a patrol. Left click on an
## existing point picks it up as the one to link from (or links the picked one to it), so a
## loop or a branch is two clicks on points that are already there. Right click removes a
## point, or, on the ground, lets go of the chain. Reload removes all of your points.
##
## Never decides how an NPC walks the route: that is the brain's (`soldier_brain.gd`), which
## reads [member waypoint.gd links].


func _init() -> void:
	id = &"waypoint"
	display_name = "Waypoints"
	description = "Lays patrol points and links them. Your armed NPCs walk the route when idle."
	help_primary = "lay a point (links to the last one), or pick one to link from"
	help_secondary = "remove a point, or stop chaining"
	help_reload = "remove all of your points"
	super()


func schema() -> Array[Dictionary]:
	return [{
		"key": "chain", "label": "Link each new point to the last", "type": "bool", "default": true,
	}]


static func is_point(body: Variant) -> bool:
	return body is Node and (body as Node).get("links") is Array and (body as Node).has_method("link")


func primary(gun: Object, hit: Dictionary) -> DotResult:
	if not hit.has("point"):
		return DotResult.fail(DotError.CODE_STATE, "Point at the ground.")

	var body: Variant = hit.get("body")

	if is_point(body):
		return _pick_or_link(gun, body as Node3D)

	var spawner: DotPropSpawner = gun.get("spawner")

	if spawner == null:
		return DotResult.fail(DotError.CODE_STATE, "This weapon has no world.")

	var normal: Vector3 = hit.get("normal", Vector3.UP)
	var at: Vector3 = (hit["point"] as Vector3) + normal * 0.1
	var prop := spawner.spawn(&"waypoint", gun.get("wielder"), at)

	if prop == null:
		# The refusal has gone to the player through the spawner's `refused`.
		return DotResult.fail(DotError.CODE_QUOTA, "")

	var made := prop.node as Node3D

	if bool(setting("chain")) and pending.has("point") and is_instance_valid(pending["point"]):
		var linked := _link(gun, pending["point"] as Node3D, made)

		if not linked.ok:
			return linked

	pending = {"point": made}
	return DotResult.success(made)


func _pick_or_link(gun: Object, point: Node3D) -> DotResult:
	if pending.has("point") and is_instance_valid(pending["point"]) and pending["point"] != point:
		var res := _link(gun, pending["point"] as Node3D, point)
		pending = {"point": point}
		return res

	pending = {"point": point}
	return DotResult.success("first")


func _link(gun: Object, a: Node3D, b: Node3D) -> DotResult:
	if not bool(a.call("link", b)):
		return DotResult.fail(DotError.CODE_CONFLICT, "Those two are already linked.")

	# The visible half: a rope between two frozen bodies moves nothing and is drawn on every
	# client. Not counted against the player's constraints.
	var constraints: Object = gun.call("constraints")

	if constraints != null:
		var _rope: Variant = constraints.call(
			"rope", gun.get("wielder"), a as RigidBody3D, a.global_position,
			b as RigidBody3D, b.global_position, 0.0, false
		)

	return DotResult.success(b)


func secondary(gun: Object, hit: Dictionary) -> DotResult:
	var body: Variant = hit.get("body")

	if not is_point(body):
		pending = {}
		return DotResult.success(0)

	var prop: Variant = hit.get("prop")

	if pending.get("point") == body:
		pending = {}

	if prop is DotPropInstance:
		gun.get("spawner").remove((prop as DotPropInstance).instance_id, DotPropSpawner.REASON_PLAYER)

	return DotResult.success(1)


func reload(gun: Object, _hit: Dictionary) -> DotResult:
	var game: Variant = gun.get("game")
	var mine: StringName = gun.get("wielder")
	var removed := 0

	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "This weapon has no world.")

	for point in (game.get("waypoints") as Array).duplicate():
		if not is_instance_valid(point):
			continue

		var instance: Variant = point.get("instance")

		if instance is DotPropInstance and (instance as DotPropInstance).owner_id == mine:
			if gun.get("spawner").remove((instance as DotPropInstance).instance_id, DotPropSpawner.REASON_PLAYER):
				removed += 1

	pending = {}
	return DotResult.success(removed)
