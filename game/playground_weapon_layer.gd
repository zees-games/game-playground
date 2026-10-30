extends Node

## Zee guns lying in the world: dot-weapon's drop layer under the `sv_weapon_drop*` rules, built on
## the server (simulates, hands a gun to an unarmed player) and on a client (draws what it is told).

const PlaygroundZee := preload("playground_zee.gd")

## A gun left the player's hands (throw or death); the net layer takes the rig off them.
signal thrown(player_id: StringName)
## An unarmed player picked [param state] up; the net layer arms them with it.
signal picked(player_id: StringName, state: Dictionary)

## How far in front of the eye a thrown gun starts, so it clears the thrower's own body.
const REACH := 0.6

## The server owner's cvars; they outlive a map change, so the game owns them, not the layer.
var rules: DotWeaponDropRules = DotWeaponDropRules.new()
var drops: DotWeaponDrops = null
var game: Node = null
## `(player_id) -> bool`; the arena points it at its health, so the dead throw and take nothing.
var alive_fn: Callable = Callable()


## Names itself and joins [param owner_game], on either side.
func setup(owner_game: Node) -> void:
	game = owner_game
	name = "WeaponLayer"
	game.add_child(self)
	drops = DotWeaponDrops.new()
	drops.name = "WeaponDrops"
	drops.rules = rules
	drops.is_authority = game.authoritative
	drops.draws = DisplayServer.get_name() != "headless"
	drops.collision_mask = game.ragdoll_rules.collision_mask
	drops.look_of = _look
	add_child(drops)
	game.maps.changed.connect(func(_map: Variant, _world: Variant) -> void: clear())


## The drop key. Server side. Returns the drop's id, or 0 when nothing was thrown.
func throw_for(player_id: StringName) -> int:
	var r := rules.resolve(null)
	var player: Node = game.players.get(player_id)
	if drops == null or player == null or not r.enabled or not r.key_enabled or not _alive(player_id):
		return 0
	var state := _take_gun(player)
	if state.is_empty():
		return 0
	var aim: Vector3 = player.aim_direction()
	var velocity: Vector3 = player.controller.state.velocity + aim * r.throw_force + Vector3.UP * r.throw_up
	var id := drops.spawn(state, player.eye_position() + aim * REACH, velocity, _entity(player_id), r)
	thrown.emit(player_id)
	return id


## An unarmed player standing at a dropped gun takes it. Server side.
func tick(_delta: float) -> void:
	if drops == null or not drops.is_authority or drops.count() == 0:
		return
	for player_id: StringName in game.players:
		var player: Node = game.players[player_id]
		if player.zee_rig != null or not _alive(player_id):
			continue
		var hands := _Hands.new()
		var at: Vector3 = player.controller.state.position + Vector3.UP * 0.5
		if drops.take_for(hands, at, _entity(player_id)) != 0:
			picked.emit(player_id, hands.state)


## Called as a player dies: whatever they hold stays on the floor. Server side.
func drop_dead(player_id: StringName) -> void:
	var r := rules.resolve(null)
	var player: Node = game.players.get(player_id)
	if drops == null or player == null or not r.enabled or not r.on_death:
		return
	var state := _take_gun(player)
	if state.is_empty():
		return
	var velocity: Vector3 = player.controller.state.velocity * 0.5 + Vector3.UP * 2.0 + player.aim_direction()
	var _id := drops.spawn(state, player.controller.state.position + Vector3.UP, velocity, _entity(player_id), r)
	thrown.emit(player_id)


## Registers the sv_weapon_drop* cvars, archived and replicated.
func bind_cvars(add: Callable) -> Variant:
	return rules.bind_cvars(add, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)


func clear() -> void:
	if drops != null:
		drops.clear()


func describe() -> Dictionary:
	return {"drops": drops.count() if drops != null else 0, "authority": drops != null and drops.is_authority}


func _take_gun(player: Node) -> Dictionary:
	var rig: Variant = player.zee_rig
	if rig == null or not is_instance_valid(rig) or rig.arsenal == null:
		return {}
	var empty: Array[int] = []
	return rig.arsenal.drop_current(empty)


func _alive(player_id: StringName) -> bool:
	return not alive_fn.is_valid() or bool(alive_fn.call(player_id))


func _entity(player_id: StringName) -> int:
	return game.entity_table.id_for_key(player_id)


func _look(_weapon_id: StringName) -> Node3D:
	var body := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.08, 0.14, 0.5)
	body.mesh = mesh
	return body


## What [method DotWeaponDrops.take_for] asks of an arsenal, for a player who has none: no slot is
## held, any zee gun is wanted, and the state is kept for the net layer to arm them with.
class _Hands extends RefCounted:
	var catalogue: _Defs = _Defs.new()
	var state: Dictionary = {}

	func has_slot(_slot: Variant) -> bool:
		return false

	func give(_id: StringName, _select: bool = false) -> DotResult:
		return DotResult.success()

	func apply_dropped(taken: Dictionary) -> void:
		state = taken


class _Defs extends RefCounted:
	func get_def(id: StringName) -> Variant:
		var def: Variant = PlaygroundZee.catalogue().get_def(id)
		return def if def != null else PlaygroundZee.pack_def(id)
