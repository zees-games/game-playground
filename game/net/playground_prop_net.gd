extends DotNetBehaviour

## What a prop, an NPC or anything else with rigid-body physics replicates: where it is
## and how it is turned.
##
## [b]Server-authoritative and never predicted, and that is a decision rather than an
## omission.[/b] Godot's rigid-body solver is not reproducible across machines — island
## ordering, sleep thresholds and contact caching all differ — so a client that
## predicted a stack of barrels would disagree with the server within a second and be
## corrected continuously. That is why the whole sandbox is built around the client
## sending INTENT (spawn this, grab that) and the server owning the answer.
##
## The consequence a player feels is one round trip between clicking the physics gun and
## the prop moving, and it is the correct trade: a wrong-but-immediate barrel that snaps
## back is worse than a right one that starts a moment later.
##
## [member net_position] and [member net_rotation] are interpolated. Nothing else is
## replicated per tick: a client draws a prop, it does not simulate one.

var prop: Node3D = null

var net_position: Vector3 = Vector3.ZERO
var net_rotation: Quaternion = Quaternion.IDENTITY

## Whether the server has frozen it — a physics gun's freeze. Replicated because it
## changes how the prop is drawn, and because a frozen prop stops sending changes and a
## client otherwise cannot tell "frozen" from "the packets stopped".
var net_frozen: bool = false

## The tool gun's resize. Quantised: nobody tells 1.003 from 1.0, and a float per prop per
## change is bandwidth for nothing.
var net_scale: float = 1.0

## The tool gun's paint, as RGBA8 in one int; 0 is "the catalogue's own colour".
var net_tint: int = 0

## The ropes from this prop, one slot of four fields each, up to
## [constant PlaygroundProp.ROPE_SLOTS]: `peer` -1 none, 0 to a point in the world, otherwise
## the other prop's net id. Fields rather than an array because a replicated field is a
## property; slot 0 keeps the names the single rope had. The physics of every rope is the
## server's either way.
var net_rope_peer: int = -1
var net_rope_a: Vector3 = Vector3.ZERO
var net_rope_b: Vector3 = Vector3.ZERO
var net_rope_length: float = 0.0
var net_rope1_peer: int = -1
var net_rope1_a: Vector3 = Vector3.ZERO
var net_rope1_b: Vector3 = Vector3.ZERO
var net_rope1_length: float = 0.0
var net_rope2_peer: int = -1
var net_rope2_a: Vector3 = Vector3.ZERO
var net_rope2_b: Vector3 = Vector3.ZERO
var net_rope2_length: float = 0.0

## The field-name prefix of each slot.
const ROPE_FIELDS := ["net_rope", "net_rope1", "net_rope2"]

## `func(node: Node) -> int`: a body's net id. Set by the server's bridge, which knows them.
var net_id_of: Callable = Callable()

## `func(net_id: int) -> Node3D`: the mirror a net id draws. Set by a client's bridge.
var mirror_of: Callable = Callable()

const RopeView := preload("../playground_rope_view.gd")

## One view per slot, null where nothing is drawn.
var _rope_views: Array = [null, null, null]
var _applied_scale: float = 1.0
var _applied_tint: int = 0


func _register_net_vars() -> void:
	replicate(&"net_position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
	# Smallest-three, nine bits an element. A prop's orientation does not need more:
	# the error is under a degree and nobody aligns a barrel to a degree.
	replicate(&"net_rotation", DotNetVar.Type.QUATERNION).bits(9).interpolated()
	replicate(&"net_frozen", DotNetVar.Type.BOOL)
	replicate(&"net_scale", DotNetVar.Type.FLOAT_RANGE).range_of(0.25, 4.0).bits(10)
	replicate(&"net_tint", DotNetVar.Type.UINT).bits(32)
	for slot: String in ROPE_FIELDS:
		replicate(StringName(slot + "_peer"), DotNetVar.Type.INT).bits(32)
		replicate(StringName(slot + "_a"), DotNetVar.Type.VECTOR3_RANGE).range_of(-16.0, 16.0).bits(12)
		replicate(StringName(slot + "_b"), DotNetVar.Type.VECTOR3_POSITION)
		replicate(StringName(slot + "_length"), DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 64.0).bits(10)


## Authority only. The prop is moved by the physics server, and this copies where it
## ended up into the replicated properties.
func pull() -> void:
	if prop == null or not is_instance_valid(prop):
		return
	net_position = prop.global_position
	net_rotation = prop.global_basis.get_rotation_quaternion()
	var body := prop as RigidBody3D
	if body != null:
		net_frozen = body.freeze

	# Duck-typed: a vehicle is not a PlaygroundProp and has neither.
	var scale_value: Variant = prop.get("size_scale")
	net_scale = float(scale_value) if scale_value != null else 1.0
	var tint_value: Variant = prop.get("tint")
	net_tint = (tint_value as Color).to_rgba32() if tint_value is Color and (tint_value as Color).a > 0.0 else 0

	var listed: Variant = prop.get("ropes")
	var ropes: Array = listed if listed is Array else []

	for i in ROPE_FIELDS.size():
		var slot: String = ROPE_FIELDS[i]

		if i >= ropes.size():
			set(slot + "_peer", -1)
			continue

		var rope: Dictionary = ropes[i]
		var other: Variant = rope.get("peer")
		var peer_id := 0
		if other is Node and is_instance_valid(other) and net_id_of.is_valid():
			peer_id = int(net_id_of.call(other))
		set(slot + "_peer", peer_id)
		set(slot + "_a", rope.get("a", Vector3.ZERO))
		set(slot + "_b", rope.get("b", Vector3.ZERO))
		set(slot + "_length", float(rope.get("length", 0.0)))


func _net_simulate(_tick: int, _delta: float) -> void:
	if identity != null and identity.is_authoritative:
		pull()


## A remote prop, on a snapshot. Written straight to the node: nothing here is
## predicted, so there is no reconciliation to spoil by moving it — the reason
## [PlaygroundPlayerNet] guards this line does not apply.
func _net_state_applied(tick: int) -> void:
	_note_velocity(tick)
	_draw()


## Every frame between snapshots. Without this a prop steps at the snapshot rate however
## smoothly the interpolator did its work — the family's own "produced correctly and
## consumed by nothing", which cost dot-net two bugs.
func _net_interpolated(_tick: int) -> void:
	_draw()


func _draw() -> void:
	if prop == null or not is_instance_valid(prop):
		return
	if identity != null and identity.is_authoritative:
		return

	prop.global_position = net_position
	prop.global_basis = Basis(net_rotation)

	# A mirrored prop must not be simulated locally as well. Freezing it is not
	# cosmetic: an unfrozen RigidBody3D fights every position written into it, and the
	# result is a prop that jitters against gravity while the packets say it is still.
	var body := prop as RigidBody3D
	if body != null and not body.freeze:
		body.freeze = true

	_draw_look()
	_draw_rope()


## The mirror's velocity, kept as the node's `mirror_velocity` meta for whoever stands on it
## ([method PlaygroundPlayer._ride_prop]). A mirror is frozen and moved by writing its
## position, so its own `linear_velocity` is zero, and a client's rider would otherwise stand
## still on a moving deck and be pulled along only by the server's corrections: one a
## snapshot, measured.
##
## [b]From the server's positions and the ticks they were taken on, never from a clock.[/b]
## It was the drawn position over `Time.get_ticks_usec()` between draws, and the rider feeds
## it into a PREDICTED tick, so the prediction depended on how far apart in wall time two
## frames happened to land: `headless_net`'s moving deck cost 7 to 12 corrections on an idle
## machine and up to 16 under load, against a limit of 12, for identical ticks. The baseline
## (what the server last sent, not the interpolator's blend the property holds between
## snapshots) at two snapshot ticks is the server's own motion, the same on every machine.
func _note_velocity(tick: int) -> void:
	if prop == null or not is_instance_valid(prop):
		return
	if identity != null and identity.is_authoritative:
		return
	var sent: Variant = received_values().get(&"net_position")
	if not (sent is Vector3):
		return
	var at := sent as Vector3
	var seconds := float(tick_seconds_fn.call()) if tick_seconds_fn.is_valid() else 0.0
	if _sent_tick >= 0 and tick > _sent_tick and seconds > 0.0:
		prop.set_meta(&"mirror_velocity", (at - _sent_position) / (float(tick - _sent_tick) * seconds))
	_sent_tick = tick
	_sent_position = at


## `func() -> float`: seconds per server tick, for [method _note_velocity]. Set by a client's
## bridge on every mirror; unset, a mirror reports no velocity.
var tick_seconds_fn: Callable = Callable()

## The snapshot tick and the server's position at it, last time one arrived.
var _sent_tick: int = -1
var _sent_position: Vector3 = Vector3.ZERO


## The resize and the paint, applied to the mirror only when they changed: a resize
## rebuilds the shape and the mesh, which is not a thing to do every frame.
func _draw_look() -> void:
	if not is_equal_approx(net_scale, _applied_scale) and prop.has_method("set_size_scale"):
		_applied_scale = float(prop.call("set_size_scale", net_scale))

	if net_tint != _applied_tint and prop.has_method("set_tint"):
		_applied_tint = net_tint
		prop.call("set_tint", Color.hex(net_tint) if net_tint != 0 else Color(0, 0, 0, 0))


func _draw_rope() -> void:
	for i in ROPE_FIELDS.size():
		_draw_rope_slot(i)


func _draw_rope_slot(i: int) -> void:
	var slot: String = ROPE_FIELDS[i]
	var peer := int(get(slot + "_peer"))
	var view: MeshInstance3D = _rope_views[i]

	if peer < 0:
		if view != null:
			view.queue_free()
			_rope_views[i] = null
		return

	var end: Vector3 = get(slot + "_b")

	if peer > 0:
		var other: Variant = mirror_of.call(peer) if mirror_of.is_valid() else null

		if not (other is Node3D) or not is_instance_valid(other):
			return

		end = (other as Node3D).to_global(end)

	if view == null:
		view = RopeView.new()
		prop.add_child(view)
		_rope_views[i] = view

	view.draw_between(prop.to_global(get(slot + "_a")), end, float(get(slot + "_length")))


## How many ropes this mirror draws. For a check.
func ropes_drawn() -> int:
	var drawn := 0
	for view in _rope_views:
		if view != null:
			drawn += 1
	return drawn
