extends "playground_events_base.gd"


# --- Inventory -------------------------------------------------------------

## What an [constant Ask.INVENTORY] carries.
enum InvAsk {
	## An op the client has already applied to its own copy: a sequence number and the op.
	OP,
	## "Send me the whole bag": the newest sequence number this client has used.
	RESYNC,
	## Buy one of this into the bag, through the shop.
	BUY,
}

## What a [constant Kind.INVENTORY] carries.
enum InvTell {
	## The answer to one op: its sequence number, yes or no, and why not.
	ACK,
	## The whole bag, and the newest sequence number it already reflects.
	DOC,
}

const INV_SUB_BITS := 2
const INV_CONTAINER_BYTES := 48
const INV_REASON_BYTES := 120
## A JSON document. A full 10x6 bag of one-cell items is about five kilobytes, inside
## [constant PlaygroundEvent.MAX_BODY]; see [method write_inv_doc] for what happens past it.
const INV_DOC_BYTES := 12000
const INV_OP_KIND_BITS := 3
const INV_CELL_MIN := -1
const INV_CELL_MAX := 254


## Whether every sub-kind fits its field: [enum InvAsk] and [enum InvTell] in
## [constant INV_SUB_BITS], dot-inventory's [enum DotInvOp.Kind] (an enum that grows outside
## this game, written clamped) in [constant INV_OP_KIND_BITS], and [enum ProjectileTell] in
## [constant PROJECTILE_SUB_BITS]. What headless_net reads.
static func sub_kinds_fit() -> bool:
	return int(InvAsk.values().max()) < (1 << INV_SUB_BITS) \
		and int(InvTell.values().max()) < (1 << INV_SUB_BITS) \
		and int(DotInvOp.Kind.values().max()) < (1 << INV_OP_KIND_BITS) \
		and int(ProjectileTell.values().max()) < (1 << PROJECTILE_SUB_BITS)


## One op, and its sequence number.
##
## Without [code]state[/code] on purpose: it is whatever a game carries with an ADD, which a client
## must not write. The [code]actor[/code] is absent too: the server sets it from the peer.
static func write_inv_op(seq: int, op: Dictionary) -> PackedByteArray:
	var w := _w()
	w.write_uint(InvAsk.OP, INV_SUB_BITS)
	w.write_varint(maxi(seq, 0))
	w.write_uint(clampi(int(op.get("kind", 0)), 0, (1 << INV_OP_KIND_BITS) - 1), INV_OP_KIND_BITS)
	w.write_string(str(op.get("from", "")), INV_CONTAINER_BYTES)
	w.write_varint(maxi(int(op.get("from_uid", 0)), 0))
	w.write_string(str(op.get("to", "")), INV_CONTAINER_BYTES)
	var cell: Variant = op.get("cell", [0, 0])
	var cx := 0
	var cy := 0
	if cell is Array and (cell as Array).size() >= 2:
		cx = int(cell[0])
		cy = int(cell[1])
	w.write_svarint(clampi(cx, INV_CELL_MIN, INV_CELL_MAX))
	w.write_svarint(clampi(cy, INV_CELL_MIN, INV_CELL_MAX))
	w.write_bool(bool(op.get("rotated", false)))
	w.write_varint(maxi(int(op.get("to_uid", 0)), 0))
	w.write_varint(maxi(int(op.get("count", 1)), 0))
	w.write_string(str(op.get("item", "")), ID_BYTES)
	return w.to_bytes()


## Reads the sub-kind every [constant Ask.INVENTORY] starts with.
static func read_inv_ask(r: DotNetReader) -> int:
	return r.read_uint(INV_SUB_BITS)


## The rest of an [constant InvAsk.OP], after [method read_inv_ask]. The op comes back as
## the dictionary [method DotInvOp.from_dictionary] reads.
static func read_inv_op(r: DotNetReader) -> Dictionary:
	var seq := r.read_varint()
	var op := {
		"kind": r.read_uint(INV_OP_KIND_BITS),
		"from": r.read_string(INV_CONTAINER_BYTES),
		"from_uid": r.read_varint(),
		"to": r.read_string(INV_CONTAINER_BYTES),
		"cell": [r.read_svarint(), r.read_svarint()],
		"rotated": r.read_bool(),
		"to_uid": r.read_varint(),
		"count": r.read_varint(),
		"item": r.read_string(ID_BYTES),
		"state": {},
	}
	return {"seq": seq, "op": op, "ok": r.ok()}


static func write_inv_resync(seq: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(InvAsk.RESYNC, INV_SUB_BITS)
	w.write_varint(maxi(seq, 0))
	return w.to_bytes()


static func read_inv_resync(r: DotNetReader) -> Dictionary:
	var seq := r.read_varint()
	return {"seq": seq, "ok": r.ok()}


static func write_inv_buy(item_id: StringName) -> PackedByteArray:
	var w := _w()
	w.write_uint(InvAsk.BUY, INV_SUB_BITS)
	w.write_string(String(item_id), ID_BYTES)
	return w.to_bytes()


static func read_inv_buy(r: DotNetReader) -> Dictionary:
	var item := StringName(r.read_string(ID_BYTES))
	return {"item": item, "ok": r.ok()}


static func write_inv_ack(seq: int, ok: bool, reason: String) -> PackedByteArray:
	var w := _w()
	w.write_uint(InvTell.ACK, INV_SUB_BITS)
	w.write_varint(maxi(seq, 0))
	w.write_bool(ok)
	w.write_string(reason, INV_REASON_BYTES)
	return w.to_bytes()


## Reads the sub-kind every [constant Kind.INVENTORY] starts with.
static func read_inv_tell(r: DotNetReader) -> int:
	return r.read_uint(INV_SUB_BITS)


static func read_inv_ack(r: DotNetReader) -> Dictionary:
	var seq := r.read_varint()
	var accepted := r.read_bool()
	var reason := r.read_string(INV_REASON_BYTES)
	return {"seq": seq, "accepted": accepted, "reason": reason, "ok": r.ok()}


## The whole bag, as the JSON [method DotInvDoc.to_dictionary] was written to survive.
##
## JSON on purpose: it is the saved format. Refused, not truncated, when too big (truncating leaves
## JSON the client cannot parse); an empty result is one [method PlaygroundNetBridge._tell] refuses.
static func write_inv_doc(through_seq: int, doc: Dictionary) -> PackedByteArray:
	var text := JSON.stringify(doc)
	if text.to_utf8_buffer().size() > INV_DOC_BYTES:
		return PackedByteArray()
	var w := _w()
	w.write_uint(InvTell.DOC, INV_SUB_BITS)
	w.write_varint(maxi(through_seq, 0))
	w.write_string(text, INV_DOC_BYTES)
	return w.to_bytes()


static func read_inv_doc(r: DotNetReader) -> Dictionary:
	var through := r.read_varint()
	var text := r.read_string(INV_DOC_BYTES)
	if not r.ok():
		return {"ok": false}
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false}
	return {"through": through, "doc": parsed as Dictionary, "ok": true}


# --- Projectiles ----------------------------------------------------------------

## A projectile left a weapon. Floats in full for the velocity and the fuse numbers: a client
## flies its copy from these, and a quantised velocity is an arc that lands somewhere else.
static func write_launch(
	serial: int, spawn: DotWeaponSpawn, owner_id: StringName, sticks: bool
) -> PackedByteArray:
	var w := _w()
	w.write_uint(ProjectileTell.LAUNCH, PROJECTILE_SUB_BITS)
	w.write_varint(serial)
	w.write_string(String(spawn.id), ID_BYTES)
	w.write_string(String(owner_id), ID_BYTES)
	w.write_vector3_range(spawn.origin, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_float32(spawn.velocity.x)
	w.write_float32(spawn.velocity.y)
	w.write_float32(spawn.velocity.z)
	w.write_float32(spawn.gravity_scale)
	w.write_float32(spawn.radius)
	w.write_float32(spawn.splash_radius)
	w.write_varint(maxi(spawn.fuse_ticks, 0))
	w.write_varint(maxi(spawn.life_ticks, 0))
	w.write_bool(sticks)
	return w.to_bytes()


## Reads what [method write_launch] wrote, after the sub-kind, as a [DotWeaponSpawn] a
## client can fly. Damage is not sent: a client's copy hurts nobody.
static func read_launch(r: DotNetReader) -> Dictionary:
	var serial := r.read_varint()
	var spawn := DotWeaponSpawn.new()
	spawn.id = StringName(r.read_string(ID_BYTES))
	var owner_id := StringName(r.read_string(ID_BYTES))
	spawn.origin = r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	spawn.velocity = Vector3(r.read_float32(), r.read_float32(), r.read_float32())
	spawn.gravity_scale = r.read_float32()
	spawn.radius = r.read_float32()
	spawn.splash_radius = r.read_float32()
	spawn.fuse_ticks = r.read_varint()
	spawn.life_ticks = r.read_varint()
	spawn.meta[&"sticks"] = r.read_bool()
	return {"serial": serial, "spawn": spawn, "owner_id": owner_id, "ok": r.ok()}


## [param fx] is 0 for a blast that leaves nothing, else AwUtilityZones.Fx plus one (a smoke or a fire),
## with the seconds it lasts; a client draws the cloud from it.
static func write_detonate(serial: int, at: Vector3, radius: float, fx: int = 0, seconds: float = 0.0) -> PackedByteArray:
	var w := _w()
	w.write_uint(ProjectileTell.DETONATE, PROJECTILE_SUB_BITS)
	w.write_varint(serial)
	w.write_vector3_range(at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_float32(radius)
	w.write_uint(fx, DETONATE_FX_BITS)
	if fx > 0:
		w.write_float32(seconds)
	return w.to_bytes()


static func read_detonate(r: DotNetReader) -> Dictionary:
	var serial := r.read_varint()
	var at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	var radius := r.read_float32()
	var fx := r.read_uint(DETONATE_FX_BITS)
	var seconds := r.read_float32() if fx > 0 else 0.0
	return {"serial": serial, "position": at, "radius": radius, "fx": fx, "seconds": seconds, "ok": r.ok()}


## [param strength] (0..1, five bits) is how hard the flash hit.
static func write_blind(seconds: float, strength: float = 1.0) -> PackedByteArray:
	var w := _w()
	w.write_uint(ProjectileTell.BLIND, PROJECTILE_SUB_BITS)
	w.write_float32(seconds)
	w.write_float_range(strength, 0.0, 1.0, 5)
	return w.to_bytes()


static func read_blind(r: DotNetReader) -> Dictionary:
	var seconds := r.read_float32()
	var strength := r.read_float_range(0.0, 1.0, 5)
	return {"seconds": seconds, "strength": strength, "ok": r.ok()}


# --- ADDON ---------------------------------------------------------------------

const ADDON_NAME_BYTES := 48
const ADDON_BODY_BYTES := 900


static func write_addon(addon: String, body: Dictionary) -> PackedByteArray:
	var w := _w()
	w.write_string(addon, ADDON_NAME_BYTES)
	w.write_string(JSON.stringify(body), ADDON_BODY_BYTES)
	return w.to_bytes()


## [code]ok[/code] is false for a body that is not a JSON object, so a hook is never handed
## something it did not expect to be a dictionary.
static func read_addon(r: DotNetReader) -> Dictionary:
	var addon := r.read_string(ADDON_NAME_BYTES)
	var parsed: Variant = JSON.parse_string(r.read_string(ADDON_BODY_BYTES))
	return {"addon": addon, "body": parsed if parsed is Dictionary else {},
		"ok": r.ok() and parsed is Dictionary}


# --- BUILDS --------------------------------------------------------------------

## The most builds one list carries. A player with more sees the first this many by name;
## `pg_builds` in chat still lists all of them.
const BUILDS_MAX := 64
const BUILD_NAME_BYTES := 32


## [param list] is [method PlaygroundBuilds.summaries]: `{name, props, custom}` each.
static func write_builds(list: Array) -> PackedByteArray:
	var w := _w()
	var count := mini(list.size(), BUILDS_MAX)
	w.write_uint(count, 7)
	for i in count:
		var entry: Dictionary = list[i]
		w.write_string(str(entry.get("name", "")), BUILD_NAME_BYTES)
		w.write_uint(clampi(int(entry.get("props", 0)), 0, 255), 8)
		w.write_bool(bool(entry.get("custom", false)))
	return w.to_bytes()


static func read_builds(r: DotNetReader) -> Dictionary:
	var out: Array[Dictionary] = []
	var count := mini(r.read_uint(7), BUILDS_MAX)
	for i in count:
		var name := r.read_string(BUILD_NAME_BYTES)
		var props := r.read_uint(8)
		var custom := r.read_bool()
		out.append({"name": name, "props": props, "custom": custom})
	return {"builds": out, "ok": r.ok()}


# --- SELECTION -----------------------------------------------------------------

## The settings travel as JSON, for the reason a tool's settings do on the way in: they are
## one mode's schema, and a field-by-field encoding is a second copy of that schema.
const SELECTION_SETTINGS_BYTES := 512


static func write_selection(net_id: int, prop_name: String, settings: Dictionary, refused: String) -> PackedByteArray:
	var w := _w()
	w.write_varint(maxi(net_id, 0))
	w.write_string(prop_name, NAME_BYTES)
	w.write_string(JSON.stringify(settings), SELECTION_SETTINGS_BYTES)
	w.write_string(refused, TEXT_BYTES)
	return w.to_bytes()


static func read_selection(r: DotNetReader) -> Dictionary:
	var net_id := r.read_varint()
	var prop_name := r.read_string(NAME_BYTES)
	var text := r.read_string(SELECTION_SETTINGS_BYTES)
	var refused := r.read_string(TEXT_BYTES)
	if not r.ok():
		return {"ok": false}
	var parsed: Variant = JSON.parse_string(text) if text != "" else {}
	if not (parsed is Dictionary):
		return {"ok": false}
	return {"net_id": net_id, "name": prop_name, "settings": parsed, "refused": refused, "ok": true}


# --- PANE ----------------------------------------------------------------------

static func write_pane(index: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(maxi(index, 0))
	return w.to_bytes()


static func read_pane(r: DotNetReader) -> Dictionary:
	var index := r.read_varint()
	return {"index": index, "ok": r.ok()}


static func write_shatter(at: Vector3, material: int) -> PackedByteArray:
	var w := _w()
	w.write_vector3_range(at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_uint(clampi(material, 0, 7), 3)
	return w.to_bytes()


static func read_shatter(r: DotNetReader) -> Dictionary:
	var at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	var material := r.read_uint(3)
	return {"at": at, "material": material, "ok": r.ok()}


# --- TOYS ----------------------------------------------------------------------

## The toys of [param map_id], by their net ids in toy order.
static func write_toys(map_id: StringName, net_ids: PackedInt64Array) -> PackedByteArray:
	var w := _w()
	w.write_string(String(map_id), ID_BYTES)
	w.write_varint(net_ids.size())
	for id in net_ids:
		w.write_varint(maxi(int(id), 0))
	return w.to_bytes()


static func read_toys(r: DotNetReader) -> Dictionary:
	var map_id := StringName(r.read_string(ID_BYTES))
	var count := r.read_varint()
	var ids := PackedInt64Array()
	if count < 0 or count > 256:
		return {"map_id": map_id, "ids": ids, "ok": false}
	for i in count:
		ids.append(r.read_varint())
	return {"map_id": map_id, "ids": ids, "ok": r.ok()}


# --- HIT -----------------------------------------------------------------------

## Your hit landed ([signal Playground.hit_landed]). The victim as its kind (4 bits) and the
## low 32 bits of its serial, which only group hits on one body for the damage numbers: a
## whole id is a kind times 10^12 and does not fit a field worth sending.
static func write_hit(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> PackedByteArray:
	var w := _w()
	w.write_uint(clampi(victim / DotEntity.STRIDE, 0, 15), 4)
	w.write_uint(posmod(victim, DotEntity.STRIDE) & 0xFFFFFFFF, 32)
	w.write_float_range(clampf(amount, 0.0, 1000.0), 0.0, 1000.0, 14)
	w.write_vector3_range(point, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_uint((1 if killed else 0) | (2 if headshot else 0), 2)
	return w.to_bytes()


static func read_hit(r: DotNetReader) -> Dictionary:
	var kind := r.read_uint(4)
	var serial := r.read_uint(32)
	var amount := r.read_float_range(0.0, 1000.0, 14)
	var point := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	var flags := r.read_uint(2)
	return {"victim": kind * DotEntity.STRIDE + serial, "amount": amount, "point": point,
		"killed": flags & 1 != 0, "headshot": flags & 2 != 0, "ok": r.ok()}
