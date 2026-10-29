extends Node

const PlaygroundPlayer := preload("playground_player.gd")

## What flash, smoke and incendiary grenades leave behind, on the authority: arena_weapons' [AwUtilityZones]
## does the zones and the blinds, and this plugs the sandbox's bodies, world trace and hurt path into it.
## The projectile layer builds one, hands it each utility blast and ticks it.

## Owner ids start high so they never equal a victim's index, which the blast reads as "the thrower".
const OWNER_BASE := 1000000

## A cloud or a fire to draw, as [method AwGrenadeFx.show] reads it. Offline play shows it; a server sends it.
signal effect(info: Dictionary)

## A flash blinded the player [param player_id] for [param seconds].
signal blinded(player_id: StringName, seconds: float)

## The zones, ticked by [method tick].
var zones := AwUtilityZones.new()

## The layer whose blasts are turned into zones; set by [method bind].
var projectiles: Node = null

## Fire zones in the world: `{position, radius, left}`, so a pulse can find who stands in one.
var _regions: Array[Dictionary] = []
var _bodies: Array = []
var _owners: Array[StringName] = []
## dot-npc's senses, when the game has them: a smoke cloud registers a sight blocker there. Set by the world.
var senses: DotNpcSenses = null
## Smoke clouds up: `{id, left}`, the blocker's id in [member senses] and its seconds to go.
var _blockers: Array[Dictionary] = []
## What the last [method detonate] left, for the wire: `{fx, seconds}` or empty.
var _last: Dictionary = {}


func bind(layer: Node) -> void:
	projectiles = layer
	zones.victims = _victims
	zones.los = AwUtilityZones.los_from_ray(_blocked)
	zones.damage = _damage
	zones.effect.connect(_on_effect)


## Sets off a utility grenade [param g] at its position. Returns `{fx, seconds}` for a smoke or a fire, else empty.
func detonate(g: AwGrenade, def: DotWeaponDef, owner_id: StringName, radius: float) -> Dictionary:
	_last = {}
	zones.rules = projectiles.rules
	g.owner_entity = _owner_index(owner_id)
	var mine := _regions.size()
	_regions.append({"position": g.position, "radius": radius, "left": 0.0})
	var _events := zones.detonate(g, def)
	_regions.remove_at(mine)
	return _last


func tick(delta: float) -> void:
	zones.tick(delta)
	_age_blockers(delta)
	for i in range(_regions.size() - 1, -1, -1):
		_regions[i]["left"] = float(_regions[i]["left"]) - delta
		if float(_regions[i]["left"]) <= 0.0:
			_regions.remove_at(i)


func clear() -> void:
	zones.clear()
	_drop_blockers()
	_regions.clear()


func active_smokes() -> int:
	return zones.active_smokes()


func active_fires() -> int:
	return zones.active_fires()


func describe() -> Dictionary:
	return zones.describe()


func _on_effect(info: Dictionary) -> void:
	match int(info["fx"]):
		AwUtilityZones.Fx.BLIND:
			var body: Node3D = _bodies[int(info["victim"])] if int(info["victim"]) < _bodies.size() else null
			if body is PlaygroundPlayer:
				blinded.emit(StringName(str(body.get("player_id"))), float(info["seconds"]))
		AwUtilityZones.Fx.SMOKE, AwUtilityZones.Fx.FIRE:
			_last = {"fx": int(info["fx"]), "seconds": float(info["seconds"])}
			if int(info["fx"]) == AwUtilityZones.Fx.SMOKE:
				_block_sight(info["position"], float(info["radius"]), float(info["seconds"]))
			if int(info["fx"]) == AwUtilityZones.Fx.FIRE:
				_regions.append({"position": info["position"], "radius": float(info["radius"]), "left": float(info["seconds"])})
			effect.emit(info)


## Zombies and NPCs stop seeing through a cloud (hearing passes) until it ends; dot-npc API 6.
func _block_sight(at: Vector3, radius: float, seconds: float) -> void:
	if senses == null or DotAddonApi.build_level("dot_npc") < 6:
		return

	# Until removed (seconds 0): the senses' own clock is only set when an NPC decides.
	_blockers.append({"id": senses.add_sight_blocker(at + Vector3(0.0, 1.0, 0.0), radius), "left": seconds})


func _age_blockers(delta: float) -> void:
	for i in range(_blockers.size() - 1, -1, -1):
		_blockers[i]["left"] = float(_blockers[i]["left"]) - delta

		if float(_blockers[i]["left"]) <= 0.0:
			if senses != null:
				senses.remove_sight_blocker(int(_blockers[i]["id"]))

			_blockers.remove_at(i)


func _drop_blockers() -> void:
	for b in _blockers:
		if senses != null:
			senses.remove_sight_blocker(int(b["id"]))

	_blockers.clear()


## Everyone in a fire or in this blast. Ids are indexes into [member _bodies], good until the next call.
func _victims() -> Array:
	_bodies.clear()
	var out: Array = []

	for region in _regions:
		for body: Node3D in projectiles.colliders_in(region["position"], float(region["radius"])):
			if _bodies.has(body):
				continue
			var eye := body.global_position + (Vector3.UP * 0.9 if body is PlaygroundPlayer else Vector3.ZERO)
			out.append(AwUtilityZones.victim(_bodies.size(), body.global_position, eye, -body.global_basis.z))
			_bodies.append(body)

	return out


## Only static geometry blocks sight, so a flash is not stopped by the crate it is about to throw.
func _blocked(from: Vector3, direction: Vector3, dist: float) -> bool:
	var space: PhysicsDirectSpaceState3D = projectiles.get_world_3d().direct_space_state
	var found := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + direction * dist))
	return not found.is_empty() and found["collider"] is StaticBody3D


## Through the layer's own hurt, so an armed NPC, a player's arena health and a breakable prop all take a pulse.
func _damage(attacker: int, victim: int, amount: float, _type: Variant, _weapon: StringName) -> void:
	var owner_index := attacker - OWNER_BASE
	if victim < _bodies.size() and is_instance_valid(_bodies[victim]) and owner_index >= 0 and owner_index < _owners.size():
		projectiles.hurt(_bodies[victim], amount, _owners[owner_index], 0.0)


func _owner_index(owner_id: StringName) -> int:
	var at := _owners.find(owner_id)
	if at < 0:
		_owners.append(owner_id)
		at = _owners.size() - 1
	return OWNER_BASE + at
