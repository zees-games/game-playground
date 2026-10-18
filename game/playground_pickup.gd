extends RefCounted

## Picking players up with the physics gun, and who may not be.
##
## [b]A held player is a rider whose vehicle is a beam.[/b] Everything a vehicle seat
## already turns off is what holding somebody has to turn off: their own movement (two
## authorities over one position shake), their client's prediction of it (a predicted
## controller fights every snapshot), and the timer (being carried down a course is not a
## run). So a hold sets [member PlaygroundPlayer.riding] with no vehicle, and every reader
## of that flag — the predictor, the camera blend, the mod tools' teleport — already does
## the right thing. On the wire it is a SEAT with vehicle 0, which is also what an older
## client understands: it stops predicting and adopts the server's position.
##
## [b]Moved by sweeping the body, not by writing the position.[/b] A held player carried
## into a wall is stopped by it, as a held crate is; written straight into the state they
## would be put inside the wall and the motor would spend the next tick pushing them out.
##
## [b]Immunity is by role, and an override role beats it.[/b] `pg_pickup_immune "admin"`
## keeps the admins on their feet; `pg_pickup_override "root"` lets the owner pick up
## anybody. Roles are [PlaygroundLimits]' answer — admin groups by name, `admin`, `root` —
## so a server with an admin file already has them. Letting go keeps the beam's velocity:
## a throw.

const PlaygroundPlayer := preload("playground_player.gd")

const CHANNEL := "playground.pickup"

## Emitted when [param target_id] is picked up or let go by [param holder_id].
signal changed(holder_id: StringName, target_id: StringName, held: bool)

## Off turns the whole thing off; a player in the beam is then nothing the gun can take.
var enabled: bool = true

## A player holding any of these may not be picked up...
var immune_roles: PackedStringArray = PackedStringArray()

## ...unless the holder holds any of these.
var override_roles: PackedStringArray = PackedStringArray(["root"])

## `func(player_id: StringName) -> PackedStringArray`. Unset, nobody has a role.
var roles_fn: Callable = Callable()

## How hard the beam pulls toward the point in front of the holder, per metre of offset.
var stiffness: float = 12.0

## Fastest a held player is carried. A throw is capped here too.
var max_speed: float = 20.0

## Closest a held player is kept to the holder's eye.
var min_distance: float = 2.0

## Furthest a held player can be picked up from, and pushed out to.
var reach: float = 12.0

## holder id -> { target, distance, velocity }
var _holds: Dictionary = {}

## target id -> holder id
var _holder_of: Dictionary = {}


func holding(holder_id: StringName) -> StringName:
	var hold: Dictionary = _holds.get(holder_id, {})
	return hold.get("target", &"")


func held_by(target_id: StringName) -> StringName:
	return _holder_of.get(target_id, &"")


func is_held(target_id: StringName) -> bool:
	return _holder_of.has(target_id)


func hold_count() -> int:
	return _holds.size()


func roles_of(player_id: StringName) -> PackedStringArray:
	if roles_fn.is_valid():
		var found: Variant = roles_fn.call(player_id)
		if found is PackedStringArray:
			return found
		if found is Array:
			return PackedStringArray(found)
	return PackedStringArray()


## Parses a role list from a cvar: commas or spaces, case kept, blanks dropped.
static func parse_roles(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for part in text.replace(",", " ").split(" ", false):
		var role := part.strip_edges()
		if role != "" and not out.has(role):
			out.append(role)
	return out


## Whether [param holder] may pick up [param target]. Every refusal says why, because a
## beam that goes through a player and does nothing reads as the gun being broken.
func may_pick_up(holder: PlaygroundPlayer, target: PlaygroundPlayer) -> DotResult:
	if not enabled:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Picking up players is off on this server.")
	if holder == null or target == null or holder == target:
		return DotResult.fail(DotError.CODE_INVALID, "Nobody there to pick up.")
	if holder.riding:
		return DotResult.fail(DotError.CODE_STATE, "You cannot pick anybody up from where you are.")
	if _holds.has(holder.player_id):
		return DotResult.fail(DotError.CODE_STATE, "You are already holding somebody.")
	if target.riding or _holder_of.has(target.player_id):
		return DotResult.fail(DotError.CODE_STATE, "%s cannot be picked up right now." % target.display_name)
	if target.creative:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "%s is in creative mode." % target.display_name)
	if holder.creative:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "You cannot pick anybody up in creative mode.")
	if _holds.has(target.player_id):
		# A holder picked up would carry their own beam with them: A holds B, C holds A,
		# and B now moves with C's mouse through A's. Refused rather than modelled.
		return DotResult.fail(DotError.CODE_STATE, "%s is holding somebody." % target.display_name)

	if not immune_roles.is_empty():
		var theirs := roles_of(target.player_id)
		var immune := ""
		for role in immune_roles:
			if theirs.has(role):
				immune = role
				break
		if immune != "":
			var mine := roles_of(holder.player_id)
			for role in override_roles:
				if mine.has(role):
					return DotResult.success(target)
			return DotResult.fail(
				DotError.CODE_FORBIDDEN, "%s cannot be picked up (%s)." % [target.display_name, immune]
			)

	return DotResult.success(target)


## The player [param holder] is looking at, within [member reach] and with nothing solid
## in front of them, or null. [param space] may be null in a test with no world.
func player_in_beam(
	players: Dictionary, holder: PlaygroundPlayer, space: Variant, origin: Vector3, aim: Vector3
) -> PlaygroundPlayer:
	aim = aim.normalized()
	var best: PlaygroundPlayer = null
	var best_t := reach

	for id in players:
		var other: PlaygroundPlayer = players[id]
		if other == holder or not is_instance_valid(other):
			continue
		var t := _ray_capsule(origin, aim, other.controller.state.position, other.eye_position(), 0.5)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = other

	if best == null or space == null:
		return best

	# Line of sight: the first thing the ray meets must be the player, not a wall or a
	# prop between them. The holder is excluded so an eye inside a capsule cannot matter.
	var query := PhysicsRayQueryParameters3D.create(origin, origin + aim * best_t)
	query.exclude = [holder.get_rid(), best.get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	return best if hit.is_empty() else null


## [param holder] picks up [param target], held as far from [param origin] as they are now.
##
## A refusal carries [code]error.context.pickup[/code] (the target's id), so a caller that
## got it through [method Playground.phys_gun_grab] can tell it from a prop refusal.
func pick_up(holder: PlaygroundPlayer, target: PlaygroundPlayer, origin: Vector3) -> DotResult:
	var allowed := may_pick_up(holder, target)
	if not allowed.ok:
		allowed.error.context["pickup"] = String(target.player_id) if target != null else ""
		return allowed

	var distance := clampf(origin.distance_to(_centre(target)), min_distance, reach)
	_holds[holder.player_id] = {"target": target.player_id, "distance": distance, "velocity": Vector3.ZERO}
	_holder_of[target.player_id] = holder.player_id

	target.set_held(true)
	target.stop_run(&"teleport")

	DotLog.info(CHANNEL, "picked up", {"holder": String(holder.player_id), "target": String(target.player_id)})
	changed.emit(holder.player_id, target.player_id, true)
	return DotResult.success(target)


## Moves the hold nearer or further, as the scroll wheel does a held prop.
func push(holder_id: StringName, amount: float) -> void:
	if _holds.has(holder_id):
		var hold: Dictionary = _holds[holder_id]
		hold["distance"] = clampf(float(hold["distance"]) + amount, min_distance, reach)


## Once a tick, after the holders have moved: carries every held player toward the point
## in front of their holder.
func tick(players: Dictionary, step: float) -> void:
	if _holds.is_empty() or step <= 0.0:
		return

	for holder_id in _holds.keys():
		var holder: PlaygroundPlayer = players.get(holder_id)
		var hold: Dictionary = _holds[holder_id]
		var target: PlaygroundPlayer = players.get(hold["target"])

		if holder == null or target == null or not is_instance_valid(holder) \
				or not is_instance_valid(target) or holder.riding:
			release(players, holder_id, false)
			continue

		var goal := holder.eye_position() + holder.aim_direction() * float(hold["distance"])
		var offset := goal - _centre(target)
		var velocity := (offset * stiffness).limit_length(max_speed)

		var before := target.global_position
		if target.is_inside_tree():
			target.move_and_collide(velocity * step)
		else:
			target.global_position += velocity * step

		var moved := target.global_position - before
		hold["velocity"] = moved / step
		target.adopt_ride(target.global_position, hold["velocity"])


## Lets go of whoever [param holder_id] holds. [param throw] keeps the beam's velocity.
func release(players: Dictionary, holder_id: StringName, throw: bool = true) -> StringName:
	if not _holds.has(holder_id):
		return &""

	var hold: Dictionary = _holds[holder_id]
	var target_id: StringName = hold["target"]
	_holds.erase(holder_id)
	_holder_of.erase(target_id)

	var target: PlaygroundPlayer = players.get(target_id)
	if target != null and is_instance_valid(target):
		target.set_held(false)
		if throw:
			target.controller.state.velocity = (hold["velocity"] as Vector3).limit_length(max_speed)

	changed.emit(holder_id, target_id, false)
	return target_id


## Lets [param player_id] go, and lets go of whoever they hold. For a player leaving,
## dying, getting into a vehicle or changing map.
func forget(players: Dictionary, player_id: StringName) -> void:
	release(players, player_id, false)
	var holder: StringName = _holder_of.get(player_id, &"")
	if holder != &"":
		release(players, holder, false)


func release_all(players: Dictionary) -> void:
	for holder_id in _holds.keys():
		release(players, holder_id, false)


func describe() -> Dictionary:
	return {
		"enabled": enabled,
		"immune_roles": immune_roles,
		"override_roles": override_roles,
		"holds": _holds.size(),
	}


static func _centre(player: PlaygroundPlayer) -> Vector3:
	var feet := player.controller.state.position
	return feet + (player.eye_position() - feet) * 0.5


## Distance along a ray (unit [param dir]) to a capsule from [param a] to [param b] of
## [param radius], or -1. Approximate by closest approach, which is all aiming needs.
static func _ray_capsule(origin: Vector3, dir: Vector3, a: Vector3, b: Vector3, radius: float) -> float:
	var best := -1.0
	# Sample the segment: a capsule is a stack of spheres, and five is plenty at 1.8 m.
	for i in 5:
		var c := a.lerp(b, float(i) / 4.0)
		var t := (c - origin).dot(dir)
		if t < 0.0:
			continue
		if (origin + dir * t).distance_to(c) <= radius and (best < 0.0 or t < best):
			best = t
	return best
