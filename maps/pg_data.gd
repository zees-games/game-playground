extends "../game/playground_map.gd"

const PlaygroundGeometry := preload("../game/playground_geometry.gd")
const PlaygroundMaterials := preload("../game/playground_materials.gd")

## A map that is a document: the one scene every custom sandbox map is built by.
##
## [b]Why a document and not a script.[/b] The built-in maps are `_build()`s full of
## constants, which is right for a map that ships inside this game. A map written for one
## server and delivered beside the game is a different thing: it lives in another pack
## (game-playground-maps), mounted at its own prefix, and a script there that `extends`
## this game's map base by path names a path that is only right in one of the two places it
## runs — the family's mount constraint. A JSON document of boxes is data: both packs can be
## anywhere, a person can read it when a map will not load, and dot-map's catalogue lists it
## without loading anything.
##
## The document ([constant FORMAT] 1):
##
## [codeblock]
## {"format": 1, "kind": "playground_map", "id": "pgc_plots", "name": "Build Plots",
##  "map_kind": "sandbox", "tier": 1, "author": "...",
##  "spawn": [0, 1, 0], "spawn_yaw": 0,
##  "boxes": [{"at": [x, y, z], "size": [x, y, z], "colour": "floor" | "#rrggbb",
##             "turn": [ax, ay, az, degrees], "material": "ice"}],
##  "declared": [{"min": [x, y, z], "max": [x, y, z], "why": "..."}],
##  "props": [{"id": "door", "at": [x, y, z], "yaw": 90, "frozen": true,
##             "tint": "#rrggbb", "scale": 1.5,
##             "physics": {"gravity": true, "weight": 1, "friction": 0.2, "bounce": 0}}],
##  "wires": [{"from": 0, "out": "pressed", "to": 1, "in": "toggle"}],
##  "lighting": {"sun": {...}, "fog": {...}, "sky_top": [r, g, b]}}
## [/codeblock]
##
## `lighting` (optional) is a dot-lighting document, the keys `DotLightDocument` reads plus
## this game's `sky_top`; a map without one gets the game's daylight
## (`PlaygroundLighting.DAYLIGHT`).
##
## A box's `material` (optional, 2026-10-07) is one of dot-physics' standard surfaces
## (`PlaygroundMaterials`): concrete, metal, wood, glass, dirt, grass, sand, snow, ice, rock,
## mud, rubber, and the liquids water and lava. A solid one is drawn in its material's look
## unless it names a colour, slides and bounces as that material, and is that material to a
## player walking on it. A LIQUID is built with no collider at all, as a see-through volume
## the map records ([method liquid_volumes]): something is IN water, not on it. A liquid
## box may not be turned, because a volume is asked about as an axis-aligned box. Foliage is
## not solid either, and not a liquid: drawn, walked through, hidden in, recorded nowhere.
##
## `props` and `wires` are optional (2026-10-07), so every older document still reads. A prop
## is a catalogue id, put down by the SERVER when the map loads ([method map_props]) and owned
## by nobody in particular (`Playground.MAP_OWNER`): a door with a button beside it, a stack
## of barrels, planks at the top of a slope. Frozen unless it says otherwise, because map
## furniture that falls over on load is not furniture. A wire joins two of them by index
## through dot-props' DotPropIO, exactly as the tool gun's Wire mode does.
##
## A box is centred on `at` (the [method PlaygroundGeometry.box] convention) and turned
## about its own centre. `declared` is [method survey_declared]: ground only a noclip
## reaches, with the reason.
##
## [b]Built by [method configure_doc], not in `_ready`[/b], for `pg_generated`'s reason:
## dot-map instantiates the shared scene and adds it, and the document is only known from
## the catalogue entry, which [Playground] hands over from its `map_changed` handler before
## anybody is spawned.

const CHANNEL := "playground.maps"

const FORMAT := 1

## The most boxes one map may hold. A map is a few hundred; past this it is a mistake or a
## document meant to stall a server's load.
const MAX_BOXES := 4000

## How far from the origin anything may be, in metres. The wire's own extent is larger.
const MAX_EXTENT := 2000.0

## The most props one map may put down. Each is a rigid body on every client.
const MAX_PROPS := 300

const NAMED_COLOURS := {
	"floor": PlaygroundGeometry.COLOUR_FLOOR,
	"ramp": PlaygroundGeometry.COLOUR_RAMP,
	"start": PlaygroundGeometry.COLOUR_START,
	"end": PlaygroundGeometry.COLOUR_END,
	"platform": PlaygroundGeometry.COLOUR_PLATFORM,
	"boost": PlaygroundGeometry.COLOUR_BOOST,
	"float": PlaygroundGeometry.COLOUR_FLOAT,
}

## The document this was built from, or empty before [method configure_doc].
var doc: Dictionary = {}

var _built := false
var _declared: Array = []
var _liquids: Array = []


func _ready() -> void:
	# Deliberately not `_build()`. See the class note.
	pass


## Reads [param path] and builds the map it describes. Idempotent. A document that does not
## read leaves the fallback floor, so a broken custom map is a flat plate with a WARN rather
## than a player falling through nothing.
func configure_doc(path: String) -> DotResult:
	if _built:
		return DotResult.success(self)
	_built = true

	var read := read_doc(path)
	if not read.ok:
		DotLog.warn(CHANNEL, "a map document did not load; building a bare floor",
			{"path": path, "why": read.error.message})
		_build_fallback()
		return read

	doc = read.value
	_liquids = build_into(self, doc)
	add_contact_shade()
	fallback_spawn = _vec(doc.get("spawn", [0, 1, 0]))
	_declared = declared_of(doc)
	return DotResult.success(self)


## The yaw a player spawns facing, in degrees. Read by [Playground] beside the spawn.
func spawn_yaw() -> float:
	return float(doc.get("spawn_yaw", 0.0))


func spawn_yaw_for(_track: int) -> float:
	return spawn_yaw()


func survey_declared() -> Array:
	return _declared


## The liquids in this map: `[{box: AABB, material, index}]`, world space (a map's node is
## at the origin). What Playground asks for lava and water.
func liquid_volumes() -> Array:
	return _liquids


## The props this map puts down when it loads. See the class note; spawned by [Playground].
func map_props() -> Array:
	return doc.get("props", [])


func map_wires() -> Array:
	return doc.get("wires", [])


## The toys this map puts down (dot-props' placements), from the document's `toys`.
func map_toys() -> Array:
	return doc.get("toys", [])


func _build_fallback() -> void:
	PlaygroundGeometry.light(self)
	PlaygroundGeometry.box(self, Vector3(0.0, -0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	fallback_spawn = Vector3(0.0, 1.0, 0.0)


# --- The document --------------------------------------------------------------

## Reads and checks a map document.
static func read_doc(path: String) -> DotResult:
	if not FileAccess.file_exists(path):
		return DotResult.fail(DotError.CODE_IO, "No map document at %s." % path)
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "%s is not a JSON object." % path)
	return validate(parsed)


## Whether a document is one this builds. Every field is checked before anything is built,
## so a bad map is refused whole rather than half drawn.
static func validate(d: Dictionary) -> DotResult:
	if int(d.get("format", 0)) != FORMAT or str(d.get("kind", "")) != "playground_map":
		return DotResult.fail(DotError.CODE_VERSION,
			"Not a playground map document of format %d." % FORMAT)
	var id := str(d.get("id", ""))
	if not id.is_valid_identifier():
		return DotResult.fail(DotError.CODE_INVALID, "A map id must be an identifier, not \"%s\"." % id)
	if not _is_vec(d.get("spawn")):
		return DotResult.fail(DotError.CODE_INVALID, "Map %s has no spawn." % id)
	var boxes: Variant = d.get("boxes")
	if not (boxes is Array) or (boxes as Array).is_empty() or (boxes as Array).size() > MAX_BOXES:
		return DotResult.fail(DotError.CODE_INVALID,
			"Map %s needs between 1 and %d boxes." % [id, MAX_BOXES])
	for i in (boxes as Array).size():
		var b: Variant = boxes[i]
		if not (b is Dictionary) or not _is_vec(b.get("at")) or not _is_vec(b.get("size")):
			return DotResult.fail(DotError.CODE_INVALID, "Map %s: box %d needs at and size." % [id, i])
		var size := _vec(b["size"])
		if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
			return DotResult.fail(DotError.CODE_INVALID, "Map %s: box %d has no volume." % [id, i])
		if _vec(b["at"]).length() > MAX_EXTENT:
			return DotResult.fail(DotError.CODE_INVALID, "Map %s: box %d is out of the world." % [id, i])
		if b.has("turn") and not (b["turn"] is Array and (b["turn"] as Array).size() == 4):
			return DotResult.fail(DotError.CODE_INVALID, "Map %s: box %d's turn is [axis x, y, z, degrees]." % [id, i])
		if b.has("material"):
			var material := str(b["material"])
			if not PlaygroundMaterials.is_known(material):
				return DotResult.fail(DotError.CODE_INVALID, "Map %s: box %d is made of %s, which is not a material." % [id, i, material])
			if PlaygroundMaterials.is_liquid(material) and b.has("turn"):
				return DotResult.fail(DotError.CODE_INVALID, "Map %s: box %d is %s and turned; a liquid is an axis-aligned volume." % [id, i, material])
	if d.has("lighting") and not (d["lighting"] is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "Map %s: lighting is a dot-lighting document (an object)." % id)
	var props: Variant = d.get("props", [])
	if not (props is Array) or (props as Array).size() > MAX_PROPS:
		return DotResult.fail(DotError.CODE_INVALID, "Map %s: props is a list of at most %d." % [id, MAX_PROPS])
	for i in (props as Array).size():
		var p: Variant = props[i]
		if not (p is Dictionary) or str(p.get("id", "")) == "" or not _is_vec(p.get("at")):
			return DotResult.fail(DotError.CODE_INVALID, "Map %s: prop %d needs an id and at." % [id, i])
		if _vec(p["at"]).length() > MAX_EXTENT:
			return DotResult.fail(DotError.CODE_INVALID, "Map %s: prop %d is out of the world." % [id, i])
	var wires: Variant = d.get("wires", [])
	if not (wires is Array):
		return DotResult.fail(DotError.CODE_INVALID, "Map %s: wires is a list." % id)
	for i in (wires as Array).size():
		var w: Variant = wires[i]
		var count := (props as Array).size()
		if not (w is Dictionary) or int(w.get("from", -1)) < 0 or int(w.get("from", -1)) >= count \
				or int(w.get("to", -1)) < 0 or int(w.get("to", -1)) >= count \
				or str(w.get("out", "")) == "" or str(w.get("in", "")) == "":
			return DotResult.fail(DotError.CODE_INVALID, "Map %s: wire %d needs from, out, to and in, naming props." % [id, i])
	return DotResult.success(d)


## Builds a checked document's boxes under [param parent], and returns its liquid volumes:
## `[{box: AABB, material: StringName, index: int}]`.
static func build_into(parent: Node3D, d: Dictionary) -> Array:
	PlaygroundGeometry.light(parent, d.get("lighting", {}))
	var liquids: Array = []
	var boxes: Array = d.get("boxes", [])
	for i in boxes.size():
		var b: Dictionary = boxes[i]
		var material := str(b.get("material", ""))
		var colour := colour_of(b.get("colour", "floor")) if b.has("colour") or material == "" \
			else PlaygroundMaterials.look(material, PlaygroundGeometry.COLOUR_FLOOR)
		if material != "" and b.has("colour") and PlaygroundMaterials.look(material, Color.WHITE).a < 0.999:
			# A see-through material keeps its transparency in a mapper's own colour.
			colour.a = PlaygroundMaterials.look(material, Color.WHITE).a
		var at := _vec(b["at"])
		var size := _vec(b["size"])
		if material != "" and PlaygroundMaterials.is_volume(material):
			var mesh := _liquid_mesh(at, size, colour, i)
			if b.has("turn"):
				var t: Array = b["turn"]
				var axis := Vector3(float(t[0]), float(t[1]), float(t[2]))
				if axis.length() > 0.0:
					mesh.basis = Basis(axis.normalized(), deg_to_rad(float(t[3])))
			parent.add_child(mesh)
			if PlaygroundMaterials.is_liquid(material):
				liquids.append({"box": AABB(at - size * 0.5, size), "material": StringName(material), "index": i})
			continue
		var basis := Basis.IDENTITY
		if b.has("turn"):
			var t: Array = b["turn"]
			var axis := Vector3(float(t[0]), float(t[1]), float(t[2]))
			if axis.length() > 0.0:
				basis = Basis(axis.normalized(), deg_to_rad(float(t[3])))
		var body := PlaygroundGeometry.box(parent, at, size, colour, basis)
		body.set_meta(&"pg_box", i)
		if material != "":
			PlaygroundMaterials.apply(body, material)
	return liquids


## A liquid's volume, drawn and nothing else: no body, so nothing stands on it and the
## survey (which reads static bodies) sees the bed under it.
static func _liquid_mesh(at: Vector3, size: Vector3, colour: Color, index: int) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = "Liquid%d" % index
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh.mesh = box_mesh
	mesh.position = at
	mesh.material_override = PlaygroundGeometry._material(colour)
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Water, lava and foliage have no collider by design: a body is swum or pushed through,
	# not stood on, and the bed under it is solid. The audit's lenient pass would pass it on
	# the bed's shape; this says it is meant.
	mesh.set_meta(DotCollisionAudit.META, true)
	return mesh


static func declared_of(d: Dictionary) -> Array:
	var out: Array = []
	for entry: Variant in d.get("declared", []):
		if entry is Dictionary and _is_vec(entry.get("min")) and _is_vec(entry.get("max")):
			var lo := _vec(entry["min"])
			out.append({"box": AABB(lo, _vec(entry["max"]) - lo), "why": str(entry.get("why", ""))})
	return out


static func colour_of(value: Variant) -> Color:
	var name := str(value)
	if NAMED_COLOURS.has(name):
		return NAMED_COLOURS[name]
	if name.begins_with("#") and Color.html_is_valid(name):
		return Color.html(name)
	return PlaygroundGeometry.COLOUR_FLOOR


static func _is_vec(v: Variant) -> bool:
	return v is Array and (v as Array).size() == 3


static func _vec(v: Variant) -> Vector3:
	var a: Array = v
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
