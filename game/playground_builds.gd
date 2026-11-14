extends RefCounted

## Saved builds: what a player made, as a document they can put down again later.
##
## [b]A document of catalogue ids, never of scenes or node paths[/b], because the thing it
## has to survive is the catalogue changing under it: a prop renamed or removed in a later
## release is refused BY NAME when the build is loaded ("this build uses \"crate_old\", which
## this server does not have"), rather than half a build appearing. Every prop is stored
## relative to the build's origin and turned by the yaw it was saved facing, so a build is put
## down in front of whoever loads it, facing the way they face.
##
## [b]What is kept[/b]: each prop's id, where it is, how it is turned, whether it is frozen, the
## tool gun's size and paint; the welds, ropes and no-collides between them (and welds to the
## world, kept as a point); and dot-props' wires between them (buttons to doors).
##
## [b]Placed whole or not at all.[/b] The player's limits are asked first, kind by kind, so a
## build bigger than what they are allowed is refused before anything appears; and a spawn the
## spawner refuses anyway takes back everything this load put down. Half a bridge is worse
## than none, and it is half a bridge somebody has to clean up.
##
## [b]Stored on the server[/b], under the player's statistics key (the same key their bag and
## their numbers are kept under), as JSON in `user://builds/<key>/<name>.json`. JSON because
## it is the format a person can read when a build will not load.

const CHANNEL := "playground.builds"

const ToolPhysprop := preload("toolgun/tool_physprop.gd")

const FORMAT := 1

## The most props one build may hold. Past this a save is refused: a whole server's worth of
## props in one file is a load that stalls the tick. 0 = unlimited. The server sets it from
## `build_max_props` in the config (the default here is that setting's default).
static var max_props: int = 200

## What a build's name may be: letters, digits, `-` and `_`, up to 32. It becomes a file name.
const NAME_PATTERN := "^[A-Za-z0-9_-]{1,32}$"

## Where builds are kept. A server sets it; the suites point it somewhere of their own.
var directory: String = "user://builds"


# --- Capture ---------------------------------------------------------------------

## Everything [param owner_id] has in the world, relative to [param origin] and [param yaw]
## (degrees, the way they face). Fails when they own nothing or more than [member max_props].
func capture(game: Node, owner_id: StringName, origin: Vector3, yaw: float) -> DotResult:
	var spawner: DotPropSpawner = game.get("props")
	var mine := spawner.props_of(owner_id).filter(func(p: DotPropInstance) -> bool:
		return p.is_alive() and p.def != null and p.node is Node3D and not bool(p.def.meta.get("hidden", false)))

	if mine.is_empty():
		return DotResult.fail(DotError.CODE_STATE, "You have nothing in the world to save.")
	if max_props > 0 and mine.size() > max_props:
		return DotResult.fail(DotError.CODE_INVALID, "A build can hold %d props; you have %d." % [max_props, mine.size()])

	var frame := Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), origin)
	var inverse := frame.affine_inverse()
	var index_of := {}
	var props: Array = []

	for prop: DotPropInstance in mine:
		index_of[prop.instance_id] = props.size()
		var local := inverse * (prop.node as Node3D).global_transform
		var q := local.basis.get_rotation_quaternion()
		var entry := {
			"id": String(prop.def.id),
			"at": [local.origin.x, local.origin.y, local.origin.z],
			"turn": [q.x, q.y, q.z, q.w],
			"frozen": prop.frozen,
		}
		var scale: Variant = prop.node.get("size_scale")
		if scale is float and not is_equal_approx(scale, 1.0):
			entry["scale"] = scale
		var tint: Variant = prop.node.get("tint")
		if tint is Color and (tint as Color).a > 0.0:
			entry["tint"] = (tint as Color).to_html(true)
		var physics := _physics_of(prop.node as RigidBody3D)
		if not physics.is_empty():
			entry["physics"] = physics
		props.append(entry)

	var links: Array = []
	var constraints: Object = game.get("constraints")
	if constraints != null:
		for c: Variant in constraints.call("all_items"):
			var a_index: Variant = _index_of_body(spawner, index_of, c.a)
			if a_index == null:
				continue
			var b_index: Variant = _index_of_body(spawner, index_of, c.b) if c.b != null else -1
			if b_index == null:
				continue
			var link := {"kind": ["weld", "nocollide", "rope"][int(c.kind)], "a": a_index, "b": b_index}
			link["a_at"] = _v(c.a_local)
			# A weld or rope to the world keeps its world point in the build's frame.
			link["b_at"] = _v(inverse * c.b_local) if c.b == null else _v(c.b_local)
			link["length"] = c.length
			links.append(link)

	var wires: Array = []
	var io: DotPropIO = game.get("io")
	if io != null:
		for prop: DotPropInstance in mine:
			for w: Dictionary in io.links_from(prop.instance_id):
				if index_of.has(int(w["to"])):
					wires.append({"from": index_of[prop.instance_id], "output": String(w["output"]),
						"to": index_of[int(w["to"])], "input": String(w["input"])})

	return DotResult.success({
		"format": FORMAT, "kind": "build", "props": props, "links": links, "wires": wires,
	})


static func _index_of_body(spawner: DotPropSpawner, index_of: Dictionary, body: Node) -> Variant:
	if body == null:
		return null
	var prop := spawner.prop_for_node(body)
	return index_of.get(prop.instance_id) if prop != null else null


static func _v(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _vec(a: Variant) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2])) if a is Array and (a as Array).size() == 3 else Vector3.ZERO


# --- Checking ------------------------------------------------------------------------

## Whether [param doc] is a build this server can put down: the format, the shape, and every
## prop id in [param catalogue]. Unknown ids are named, all of them, in the refusal.
static func validate(doc: Variant, catalogue: DotPropCatalogue) -> DotResult:
	if not (doc is Dictionary) or str((doc as Dictionary).get("kind", "")) != "build":
		return DotResult.fail(DotError.CODE_PARSE, "That is not a saved build.")
	if int(doc.get("format", 0)) != FORMAT:
		return DotResult.fail(DotError.CODE_VERSION, "That build was saved in format %s; this server reads %d." % [doc.get("format"), FORMAT])

	var props: Variant = doc.get("props")
	if not (props is Array) or (props as Array).is_empty() or (max_props > 0 and (props as Array).size() > max_props):
		return DotResult.fail(DotError.CODE_INVALID, "A build holds 1 to %d props." % max_props)

	var unknown := PackedStringArray()
	for entry: Variant in props:
		if not (entry is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "A prop in that build is not a prop.")
		var id := str((entry as Dictionary).get("id", ""))
		if catalogue.get_prop(StringName(id)) == null and not unknown.has(id):
			unknown.append(id)

	if not unknown.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "This build uses %s, which this server does not have." % ", ".join(
			Array(unknown).map(func(id: String) -> String: return "\"%s\"" % id)))

	var count := (props as Array).size()
	for list_key in ["links", "wires"]:
		for item: Variant in doc.get(list_key, []):
			if not (item is Dictionary):
				return DotResult.fail(DotError.CODE_INVALID, "A %s entry in that build is malformed." % list_key)
			for end in (["a", "b"] if list_key == "links" else ["from", "to"]):
				var i := int((item as Dictionary).get(end, -2))
				if i < (-1 if end == "b" else 0) or i >= count:
					return DotResult.fail(DotError.CODE_INVALID, "A %s entry in that build names a prop it does not have." % list_key)

	return DotResult.success(doc)


# --- Putting it down -------------------------------------------------------------

## Puts [param doc] down for [param owner_id] at [param origin], turned to [param yaw]. Whole
## or not at all: their limits are asked first, and a refusal mid-way takes back what this put
## down. Returns how many props it placed.
func place(game: Node, owner_id: StringName, doc: Dictionary, origin: Vector3, yaw: float) -> DotResult:
	var spawner: DotPropSpawner = game.get("props")
	var checked := validate(doc, spawner.catalogue)
	if not checked.ok:
		return checked

	var room := _room_for(spawner, owner_id, doc)
	if not room.ok:
		return room

	var frame := Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), origin)
	var placed: Array[DotPropInstance] = []

	for entry: Dictionary in doc["props"]:
		var local := Transform3D(Basis(_quat(entry.get("turn"))), _vec(entry.get("at")))
		var world := frame * local
		var prop := spawner.spawn(StringName(str(entry["id"])), owner_id, world.origin)
		if prop == null:
			for done in placed:
				var _gone := spawner.remove(done.instance_id)
			return DotResult.fail(DotError.CODE_FORBIDDEN, "The build could not be put down: %s was refused." % str(entry["id"]))
		placed.append(prop)
		(prop.node as Node3D).global_transform = world
		if prop.node.has_method("set_size_scale") and entry.has("scale"):
			var _s: float = prop.node.call("set_size_scale", float(entry["scale"]))
		if prop.node.has_method("set_tint") and entry.has("tint") and Color.html_is_valid(str(entry["tint"])):
			prop.node.call("set_tint", Color.html(str(entry["tint"])))
		# After the size: the weight is a multiple of the mass the size gives.
		if entry.get("physics") is Dictionary and prop.node is RigidBody3D and prop.node.has_method("refresh_mass"):
			var physics: Dictionary = entry["physics"]
			ToolPhysprop._apply(prop.node as RigidBody3D, bool(physics.get("gravity", true)),
				clampf(float(physics.get("weight", 1.0)), 0.1, 10.0),
				clampf(float(physics.get("friction", 1.0)), 0.0, 2.0),
				clampf(float(physics.get("bounce", 0.0)), 0.0, 1.0))
		if bool(entry.get("frozen", false)) or prop.frozen:
			DotPhysGun.set_frozen(prop, true)
			if game.has_method("reclassify_prop"):
				game.call("reclassify_prop", prop.node, true, false)

	var constraints: Object = game.get("constraints")
	if constraints != null:
		for link: Dictionary in doc.get("links", []):
			var a := placed[int(link["a"])].node as RigidBody3D
			var b_index := int(link["b"])
			var b := placed[b_index].node as RigidBody3D if b_index >= 0 else null
			var a_at := a.to_global(_vec(link.get("a_at")))
			var b_at := (b.to_global(_vec(link.get("b_at"))) if b != null else frame * _vec(link.get("b_at")))
			match str(link.get("kind", "")):
				"weld":
					var _w: DotResult = constraints.call("weld", owner_id, a, b, a_at)
				"nocollide":
					if b != null:
						var _n: DotResult = constraints.call("nocollide", owner_id, a, b)
				"rope":
					var slack := maxf(float(link.get("length", 0.0)) - a_at.distance_to(b_at), 0.0)
					var _r: DotResult = constraints.call("rope", owner_id, a, a_at, b, b_at, slack)

	var io: DotPropIO = game.get("io")
	if io != null:
		for w: Dictionary in doc.get("wires", []):
			var _l := io.link(placed[int(w["from"])].instance_id, StringName(str(w["output"])),
				placed[int(w["to"])].instance_id, StringName(str(w["input"])))

	DotLog.info(CHANNEL, "a build was put down", {"player": String(owner_id), "props": placed.size()})
	return DotResult.success(placed.size())


static func _quat(a: Variant) -> Quaternion:
	if a is Array and (a as Array).size() == 4:
		var q := Quaternion(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
		return q.normalized() if q.length_squared() > 0.0001 else Quaternion.IDENTITY
	return Quaternion.IDENTITY


## Whether [param owner_id] has room for every prop in [param doc], kind by kind, by the same
## limits a spawn asks. Asked before anything appears.
static func _room_for(spawner: DotPropSpawner, owner_id: StringName, doc: Dictionary) -> DotResult:
	var wanted := {}
	for entry: Dictionary in doc["props"]:
		var def := spawner.catalogue.get_prop(StringName(str(entry["id"])))
		var group := def.limit_group if def.limit_group != &"" else DotPropDef.GROUP_PROPS
		wanted[group] = int(wanted.get(group, 0)) + 1

	for group: StringName in wanted:
		var cap := spawner.limit_for(owner_id, group)
		if cap > 0 and spawner.group_count(owner_id, group) + int(wanted[group]) > cap:
			return DotResult.fail(DotError.CODE_FORBIDDEN, "That build needs %d %s and your limit leaves room for %d." % [
				int(wanted[group]), group, maxi(cap - spawner.group_count(owner_id, group), 0)])
	return DotResult.success(null)


# --- Storage ---------------------------------------------------------------------------

func save(key: String, name: String, doc: Dictionary) -> DotResult:
	var checked := _checked_name(name)
	if not checked.ok:
		return checked
	var folder := directory.path_join(_safe_key(key))
	DirAccess.make_dir_recursive_absolute(folder)
	var file := FileAccess.open(folder.path_join(name + ".json"), FileAccess.WRITE)
	if file == null:
		return DotResult.fail(DotError.CODE_IO, "The build could not be written.", str(FileAccess.get_open_error()))
	file.store_string(JSON.stringify(doc, "\t"))
	file.close()
	DotWeb.sync_filesystem()
	return DotResult.success(name)


func load_build(key: String, name: String) -> DotResult:
	var checked := _checked_name(name)
	if not checked.ok:
		return checked
	var path := directory.path_join(_safe_key(key)).path_join(name + ".json")
	if not FileAccess.file_exists(path):
		return DotResult.fail(DotError.CODE_INVALID, "You have no build called \"%s\"." % name)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "The build \"%s\" is not readable." % name)
	return DotResult.success(parsed)


func names(key: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(directory.path_join(_safe_key(key)))
	if dir == null:
		return out
	for file in dir.get_files():
		if file.get_extension() == "json":
			out.append(file.get_basename())
	out.sort()
	return out


## Every build [param key] has, as `{name, props, custom}`, for the Q menu's Builds tab.
## `custom` is a build that is ONE welded piece — see [method is_custom_prop]. A file that
## no longer reads is left out rather than listed as something that cannot be loaded.
func summaries(key: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for name in names(key):
		var doc := load_build(key, name)
		if not doc.ok:
			continue
		var props: Array = doc.value.get("props", [])
		out.append({"name": name, "props": props.size(), "custom": is_custom_prop(doc.value)})
	return out


## Whether a build is a custom prop: two or more props, every one welded to the rest, and
## nothing welded to the world. Such a build moves as one thing, so the menu offers it as a
## thing to spawn rather than a place to rebuild; it is loaded exactly like any build.
static func is_custom_prop(doc: Dictionary) -> bool:
	var props: Array = doc.get("props", [])
	var count := props.size()
	if count < 2:
		return false
	var parent: Array[int] = []
	for i in count:
		parent.append(i)
	# Union-find over the welds; `parent` is an Array, so the lambda shares it.
	var find := func(i: int) -> int:
		while parent[i] != i:
			parent[i] = parent[parent[i]]
			i = parent[i]
		return i
	for link: Variant in doc.get("links", []):
		if not (link is Dictionary) or str(link.get("kind", "")) != "weld":
			continue
		var a := int(link.get("a", -1))
		var b := int(link.get("b", -1))
		if b < 0:
			return false
		if a < 0 or a >= count or b >= count:
			continue
		var ra: int = find.call(a)
		var rb: int = find.call(b)
		parent[ra] = rb
	var root: int = find.call(0)
	for i in count:
		if find.call(i) != root:
			return false
	return true


func delete(key: String, name: String) -> DotResult:
	var checked := _checked_name(name)
	if not checked.ok:
		return checked
	var path := directory.path_join(_safe_key(key)).path_join(name + ".json")
	if not FileAccess.file_exists(path):
		return DotResult.fail(DotError.CODE_INVALID, "You have no build called \"%s\"." % name)
	DirAccess.remove_absolute(path)
	DotWeb.sync_filesystem()
	return DotResult.success(name)


static func _checked_name(name: String) -> DotResult:
	var pattern := RegEx.create_from_string(NAME_PATTERN)
	if pattern.search(name) == null:
		return DotResult.fail(DotError.CODE_INVALID, "A build's name is up to 32 letters, digits, - and _.")
	return DotResult.success(name)


## A key as a folder name: anything that is not a letter, digit, - or _ becomes _.
static func _safe_key(key: String) -> String:
	var out := ""
	for c in key:
		out += c if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "-" or c == "_" else "_"
	return out if out != "" else "_"


## What the physical-properties and edit modes changed on [param body], or `{}` when it is
## as catalogued: gravity, weight, friction, bounce. Only written when something differs, so
## a build of untouched props reads exactly as it did before this field existed.
static func _physics_of(body: RigidBody3D) -> Dictionary:
	if body == null or not body.has_method("refresh_mass"):
		return {}
	var material := body.physics_material_override
	var out := {
		"gravity": body.gravity_scale != 0.0,
		"weight": float(body.get("mass_multiplier")),
		"friction": material.friction if material != null else 1.0,
		"bounce": material.bounce if material != null else 0.0,
	}
	if bool(out["gravity"]) and is_equal_approx(float(out["weight"]), 1.0) \
			and is_equal_approx(float(out["friction"]), 1.0) and is_equal_approx(float(out["bounce"]), 0.0):
		return {}
	return out
