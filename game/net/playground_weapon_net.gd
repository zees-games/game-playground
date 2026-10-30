extends RefCounted

## Carries the weapon layer over the link: the drop layer's three signals out as events, a joiner's
## snapshot, a client's events back into the layer's mirror, and the server's hand-over of a gun
## (a throw or a death takes the rig off the player, a pickup arms them). Lives beside the bridge
## because the bridge is over its size gate; it reaches the bridge's send and tool calls by name.

const PlaygroundEvents := preload("playground_events.gd")
const PlaygroundZee := preload("../playground_zee.gd")
const EXTENT := PlaygroundEvents.WORLD_EXTENT
const POS_BITS := 20

var _bridge: Object = null
var _watched: DotWeaponDrops = null


func attach(bridge: Object) -> void:
	_bridge = bridge


## Server, every tick: follows whichever layer the game has now.
func watch(layer: Node) -> void:
	var drops: DotWeaponDrops = layer.drops if layer != null else null
	if drops == _watched:
		return
	_watched = drops
	if drops != null:
		drops.dropped.connect(_on_dropped)
		drops.settled.connect(_on_settled)
		drops.removed.connect(_on_removed)
		layer.thrown.connect(_on_thrown)
		layer.picked.connect(_on_picked)


## Every gun lying about, at rest where it lies, for a joiner.
func send_snapshot(peer_id: int, layer: Node) -> void:
	if layer == null or layer.drops == null:
		return
	for entry: Dictionary in layer.drops.snapshot():
		_bridge._tell(peer_id, PlaygroundEvents.Kind.WEAPON_DROP,
			_drop_body(entry["state"], int(entry["id"]), entry["at"], Vector3.ZERO, float(entry["life"]), bool(entry["rest"])))


## Client: whether [param kind] was a weapon-drop event, applied to the layer's mirror.
func apply(kind: int, reader: DotNetReader, layer: Node) -> bool:
	if kind < PlaygroundEvents.Kind.WEAPON_DROP or kind > PlaygroundEvents.Kind.WEAPON_GONE:
		return false
	var drops: DotWeaponDrops = layer.drops if layer != null else null
	if drops == null:
		return true
	match kind:
		PlaygroundEvents.Kind.WEAPON_DROP:
			var d := read_drop(reader)
			if bool(d["ok"]):
				drops.mirror_drop(int(d["id"]), {"id": StringName(d["weapon"]),
					"magazine": int(d["magazine"]), "reserve": int(d["reserve"])},
					d["at"], d["velocity"], float(d["seconds"]), bool(d["rest"]))
		PlaygroundEvents.Kind.WEAPON_SETTLED:
			var s := read_settled(reader)
			if bool(s["ok"]):
				drops.mirror_settled(int(s["id"]), s["at"])
		_:
			var gone := read_gone(reader)
			if bool(gone["ok"]):
				drops.mirror_removed(int(gone["id"]))
	return true


func _on_dropped(id: int, state: Dictionary, at: Transform3D, velocity: Vector3, _owner: int) -> void:
	_bridge._broadcast(PlaygroundEvents.Kind.WEAPON_DROP, _drop_body(state, id, at, velocity, _watched.rules.lifetime, false))


func _on_settled(id: int, at: Transform3D) -> void:
	_bridge._broadcast(PlaygroundEvents.Kind.WEAPON_SETTLED, write_settled(id, at))


func _on_removed(id: int, _taker: int) -> void:
	var w := DotNetWriter.new()
	w.write_varint(id)
	_bridge._broadcast(PlaygroundEvents.Kind.WEAPON_GONE, w.to_bytes())


## The gun left the hands: the player is on the physics gun again, as on any unequip.
func _on_thrown(player_id: StringName) -> void:
	_bridge._select_tool(_bridge.session_of(player_id), player_id, &"phys")


## Arms [param player_id] with the gun picked up, ammunition as it lay. No charge: it was free on the floor.
func _on_picked(player_id: StringName, state: Dictionary) -> void:
	var game: Object = _bridge.game
	var player: Node = game.players.get(player_id)
	var def = game.weapon_def(StringName(PlaygroundZee.ID_PREFIX + String(state["id"])))
	if player == null or def == null:
		return
	var session: int = _bridge.session_of(player_id)
	_bridge._drop_toy(session)
	game.phys_gun_release(player)
	player.grav_gun.drop()
	var rig: Variant = PlaygroundZee.arm(player, def, ZeeWeaponRig.Role.SERVER, true, game.tick_rate, game.current_tick())
	if rig == null:
		return
	rig.arsenal.apply_dropped(state)
	_bridge._tool_of[session] = def.id
	_bridge._broadcast(PlaygroundEvents.Kind.WEAPON, PlaygroundEvents.write_weapon(session, def.id))


func _drop_body(state: Dictionary, id: int, at: Transform3D, velocity: Vector3, seconds: float, rest: bool) -> PackedByteArray:
	var w := DotNetWriter.new()
	w.write_varint(id)
	w.write_string(String(state["id"]), PlaygroundEvents.ID_BYTES)
	w.write_varint(maxi(0, int(state.get("magazine", 0))))
	w.write_varint(maxi(0, int(state.get("reserve", 0))))
	_write_pose(w, at)
	w.write_vector3_range(velocity, -64.0, 64.0, 12)
	w.write_varint(ceili(maxf(seconds, 0.0)))
	w.write_bool(rest)
	return w.to_bytes()


static func write_settled(id: int, at: Transform3D) -> PackedByteArray:
	var w := DotNetWriter.new()
	w.write_varint(id)
	_write_pose(w, at)
	return w.to_bytes()


static func read_drop(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint(), "weapon": reader.read_string(PlaygroundEvents.ID_BYTES),
		"magazine": reader.read_varint(), "reserve": reader.read_varint()}
	out["at"] = _read_pose(reader)
	out["velocity"] = reader.read_vector3_range(-64.0, 64.0, 12)
	out["seconds"] = reader.read_varint()
	out["rest"] = reader.read_bool()
	out["ok"] = reader.ok()
	return out


static func read_settled(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint(), "at": _read_pose(reader)}
	out["ok"] = reader.ok()
	return out


static func read_gone(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint()}
	out["ok"] = reader.ok()
	return out


static func _write_pose(w: DotNetWriter, at: Transform3D) -> void:
	w.write_vector3_range(at.origin, -EXTENT, EXTENT, POS_BITS)
	w.write_quaternion(at.basis.get_rotation_quaternion(), 9)


static func _read_pose(reader: DotNetReader) -> Transform3D:
	var origin := reader.read_vector3_range(-EXTENT, EXTENT, POS_BITS)
	return Transform3D(Basis(reader.read_quaternion(9)), origin)
