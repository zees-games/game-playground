extends "playground_entity.gd"

## An NPC spawn point: puts one of its kind in the world every [member interval] seconds
## while fewer than [member limit] of its own are alive.
##
## [b]What it spawns is the owner's, through the owner's own limits.[/b] The NPC goes through
## the prop spawner as the owner, so `pg_max_npcs`, the cost budget and creative protection
## all answer for it exactly as for a click on the entities tab; a spawn point that bypassed
## them would be the way round every cap. A refusal is not an error here, it is a point that
## waits and tries again.
##
## Configured by the spawner tool after it spawns (`configure_point`), because a catalogue
## row is one thing and a point's kind and rhythm are the player's.

## The catalogue id of what it makes.
var kind: StringName = &"npc_soldier"

## A zee weapon id for what it makes, or empty for the kind's own.
var weapon: StringName = &""

## Seconds between spawns.
var interval: float = 8.0

## How many of its own may be alive at once.
var limit: int = 2

var _next_at: float = 2.0
var _made: Array = []


func _entity_ready() -> void:
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	set_meta(&"spawn_point", true)


## Sets what this point makes and how often. [param ids] are checked by the tool.
func configure_point(p_kind: StringName, p_weapon: StringName, p_interval: float, p_limit: int) -> void:
	kind = p_kind
	weapon = p_weapon
	interval = maxf(p_interval, 1.0)
	limit = maxi(p_limit, 1)
	_next_at = age + 1.0


func _entity_tick(_delta: float) -> void:
	if age < _next_at or game == null or instance == null:
		return

	_next_at = age + interval

	_made = _made.filter(func(n: Variant) -> bool: return is_instance_valid(n) and (n as Node).is_inside_tree())

	if _made.size() >= limit:
		return

	var made := spawn_one()

	if made != null:
		_made.append(made)


## Makes one NPC now, above this point. Null when the spawner refuses (a limit, a budget).
func spawn_one() -> Node3D:
	var prop := game.props.spawn(kind, instance.owner_id, global_position + Vector3.UP * 1.2)

	if prop == null:
		return null

	var body := prop.node as Node3D

	if body != null and weapon != &"" and body.has_method("arm_with"):
		var _armed: Variant = body.call("arm_with", weapon)

	return body


func describe() -> Dictionary:
	var out := super.describe()
	out["makes"] = String(kind)
	out["every"] = interval
	out["alive"] = _made.size()
	return out
