extends Node3D

const PlaygroundPlayer := preload("playground_player.gd")

## What flash, smoke and incendiary grenades leave behind. arena_weapons' [AwGrenadeBlast] decides
## what a blast does and hands back events; this turns the smoke, fire and blind ones into a
## cloud, a burning zone and a signal. The projectile layer builds one and ticks it.
##
## Authority only: a connected client is told a grenade went off, not what kind it was, so it
## draws the flash and none of this.

## Seconds between a fire zone's damage pulses.
const FIRE_PULSE := 0.5

## How far above or below a fire's origin a body still stands in it.
const FIRE_HEIGHT := 2.0

## The layer whose blasts are turned into zones. Set by [PlaygroundProjectiles].
var projectiles: Node = null

var _smokes: Array[Dictionary] = []
var _fires: Array[Dictionary] = []

## A flash blinded the player [param player_id] for [param seconds].
signal blinded(player_id: StringName, seconds: float)


## Takes the smoke, fire and blind events of one blast from [param owner_id].
func blasted(events: Array[Dictionary], owner_id: StringName) -> void:
	for event in events:
		match String(event["event"]):
			"smoke":
				_smokes.append(_zone(event, Color(0.72, 0.74, 0.78, 0.55), {}))
			"fire":
				_fires.append(_zone(event, Color(1.0, 0.42, 0.1, 0.4), {
					"dps": float(event["dps"]), "owner": owner_id, "pulse": 0.0,
				}))


## A flash blinded [param body], if it is a player.
func blind(body: Node3D, seconds: float) -> void:
	if body is PlaygroundPlayer:
		blinded.emit(StringName(str(body.get("player_id"))), seconds)


func tick(delta: float) -> void:
	for i in range(_smokes.size() - 1, -1, -1):
		if _age(_smokes[i], delta):
			_smokes.remove_at(i)

	for i in range(_fires.size() - 1, -1, -1):
		var zone := _fires[i]
		zone["pulse"] = float(zone["pulse"]) - delta

		if float(zone["pulse"]) <= 0.0:
			zone["pulse"] = FIRE_PULSE
			_burn(zone)

		if _age(zone, delta):
			_fires.remove_at(i)


func active_smokes() -> int:
	return _smokes.size()


func active_fires() -> int:
	return _fires.size()


func describe() -> Dictionary:
	return {"smokes": _smokes.size(), "fires": _fires.size()}


## Everyone standing in the fire takes a pulse, from the thrower, through the same path a blast
## uses, so the arena's own rules for friendly fire and armour apply.
func _burn(zone: Dictionary) -> void:
	var at: Vector3 = zone["position"]
	var radius: float = zone["radius"]

	for body: Node3D in projectiles.colliders_in(at, radius):
		var feet := body.global_position

		if Vector2(feet.x - at.x, feet.z - at.z).length() < radius and absf(feet.y - at.y) <= FIRE_HEIGHT:
			projectiles.hurt(body, float(zone["dps"]) * FIRE_PULSE, zone["owner"], at.distance_to(feet))


func _zone(event: Dictionary, colour: Color, extra: Dictionary) -> Dictionary:
	var zone := {
		"position": event["position"], "radius": float(event["radius"]),
		"left": float(event["seconds"]), "total": float(event["seconds"]), "alpha": colour.a, "node": _draw(event, colour),
	}
	zone.merge(extra)
	return zone


## Counts a zone down. True when it is over, and its node is gone.
func _age(zone: Dictionary, delta: float) -> bool:
	zone["left"] = float(zone["left"]) - delta
	var node: MeshInstance3D = zone["node"]

	if float(zone["left"]) > 0.0:
		# Thins over its last second, so a cloud does not vanish between two frames.
		var material := node.mesh.material as StandardMaterial3D
		material.albedo_color.a = minf(1.0, float(zone["left"])) * float(zone["alpha"])
		return false

	node.queue_free()
	return true


func _draw(event: Dictionary, colour: Color) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = float(event["radius"])
	mesh.height = mesh.radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = colour
	mesh.material = material

	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.top_level = true
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	node.global_position = event["position"]
	return node
