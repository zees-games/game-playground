extends RigidBody3D

## One spawnable thing, built from its [DotPropDef] rather than from a saved scene.
##
## [b]One scene for the whole catalogue, because this project ships no art.[/b] A
## sandbox needs a menu with enough in it to build something — planks, panels,
## barrels, balls of four sizes — and the honest way to get that is a modelled prop
## per entry. There are none here, so the shape, the extent and the colour are three
## fields of [member DotPropDef.meta] and this builds the body from them. A server
## with real content points [member DotPropDef.scene_path] at its own scenes and
## never loads this at all, which is the seam the catalogue was designed around:
## [DotPropDef] is checkable without loading anything, and the scene is fetched only
## when something is actually created.
##
## [codeblock]
## "meta": { "shape": "cylinder", "extent": [0.5, 1.4, 0.5], "colour": "6a6f78" }
## [/codeblock]
##
## [b]The body is built by [method configure], not by [method Node._ready].[/b]
## [DotPropSpawner] instantiates the scene, places it, adds it to the world and
## [i]then[/i] emits `spawned` — so the definition is not available until after the
## node is in the tree, and a `_ready` that built a default box would build one that
## is immediately thrown away. Configuring instead of rebuilding also means the
## collision shape is only ever created once.

const PlaygroundFigure := preload("playground_figure.gd")

const CHANNEL := "playground.prop"

## Extent used when a definition says nothing. A one-metre crate.
const DEFAULT_EXTENT := Vector3.ONE

enum Shape {
	BOX,
	SPHERE,
	CYLINDER,
}

## The model a definition wears, or empty for a drawn shape. A file under a folder the game
## scanned (see [DotPropFolder]); never a path a client sent, because a definition only ever
## comes from the catalogue.
static func model_of(p_def: DotPropDef) -> String:
	return str(p_def.meta.get("model", "")) if p_def != null else ""

## The definition this was built from. Kept so a tool or a HUD can name the prop
## without going back to the catalogue.
var def: DotPropDef = null

## How much bigger or smaller than its definition this prop is. 1 is as catalogued.
##
## [b]Rebuilt, never `scale`d.[/b] A scaled RigidBody3D is something Godot's physics does
## not support — the shape's size and the solver's idea of it disagree, contacts jitter and
## the body sinks into the floor — so a resize builds a new collision shape and mesh at the
## new extent, from the definition, every time. From the definition rather than from the
## current shape, so inflating and deflating back is exactly where it started.
var size_scale: float = 1.0

## A colour the tool gun painted, or none (alpha 0). Over the definition's colour, not
## instead of it, so taking the paint off brings the catalogue's back.
var tint: Color = Color(0, 0, 0, 0)

## The ropes drawn from this prop, up to [constant ROPE_SLOTS]: each `{id: int (the
## constraint's), peer: Node3D or null, a: Vector3 (local), b: Vector3 (peer-local, or a
## world point with no peer), length: float}`. Written by [PlaygroundConstraints], read by
## the prop's net behaviour to tell clients.
var ropes: Array = []

## How many ropes one prop tells clients about. A rope is described on whichever of its two
## props has room, so a hub with three balloons tied to it uses none of the hub's slots
## (each balloon carries its own string), and three is room for a crate slung between
## anchors as well. More ropes than that on both ends are still simulated, and not drawn.
const ROPE_SLOTS := 3

## Times the definition's mass, on top of the size: the physical-properties tool's weight.
var mass_multiplier: float = 1.0

## The smallest and largest a prop may be resized to.
const MIN_SCALE := 0.25
const MAX_SCALE := 4.0

var _configured: bool = false


func _ready() -> void:
	# A prop that nothing configured has no collision shape and no mesh: it falls
	# through the floor, is invisible, and cannot be grabbed — three symptoms that
	# all point somewhere else. Said once, loudly, on the frame after spawning,
	# which is the first moment "nobody called configure" is distinguishable from
	# "configure has not been called yet".
	_warn_if_unconfigured.call_deferred()


func _warn_if_unconfigured() -> void:
	if _configured:
		return

	DotLog.error(CHANNEL, "a prop was spawned and never configured", {
		"hint": "Playground connects DotPropSpawner.spawned to configure it.",
	})


## Builds the body from a definition. Called once, immediately after spawning.
func configure(p_def: DotPropDef) -> void:
	def = p_def
	_configured = true
	_build_body()


## Rebuilds the collision and the mesh from the definition, [member size_scale] and
## [member tint]. What `configure`, a resize and a repaint all come down to.
func _build_body() -> void:
	for old_name in ["Collision", "Mesh"]:
		var old := get_node_or_null(old_name)

		if old != null:
			# Renamed before it goes: `queue_free` is deferred, and a new child given the
			# same name in the same frame would be renamed "Collision2" by the tree — and
			# every lookup by name would then find the dying one.
			old.name = "%sOld" % old_name
			remove_child(old)
			old.queue_free()

	var extent := extent_of(def) * size_scale
	var shape := shape_of(def)
	var colour := tint if tint.a > 0.0 else colour_of(def)

	# Mass is NOT set here. `DotPropSpawner` puts `def.mass` on the body before it
	# enters the tree, which is earlier than this runs and earlier than the first
	# physics step — and setting it twice would make it ambiguous which of the two
	# an operator is editing.

	if model_of(def) != "" and _build_model():
		continuous_cd = true
		return

	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = _make_shape(shape, extent)
	add_child(collision)

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = _make_mesh(shape, extent)

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	# Unshaded, like the maps: this project ships no lights, and a lit grey box in
	# an unlit scene is a black box.
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = material

	add_child(mesh)

	# An NPC is a person, so it is drawn as one: the kit's figure, its look chosen by what
	# it is (every soldier alike, a rebel unlike them). The collision stays the definition's
	# shape. Rebuilt with the body, because a resize changes its height.
	var old_figure := get_node_or_null(^"Figure")
	if old_figure != null:
		old_figure.name = "FigureOld"
		remove_child(old_figure)
		old_figure.queue_free()
	if def != null and String(def.id).begins_with("npc_"):
		var _dressed := PlaygroundFigure.dress_body(self, extent.y, String(def.id))

	# Continuous collision detection, because a sandbox's whole point is throwing
	# things hard. A punted prop at 40 m/s moves 31 cm in a 128 Hz step, which is
	# further than a plank is thick — so the discrete solver puts it through a wall
	# and the player watches their build leave the map.
	continuous_cd = true


## A real model: its picture, and a hull or primitive fitted to it, scaled by the definition's
## `model_scale` times [member size_scale]. Returns false when the file will not load, and the
## caller then builds the drawn box so the prop still exists, is still solid, and is the
## wrong shape where somebody can see it.
##
## The collision shape is [DotPropModel]'s cached one at this scale, so forty chairs are one
## hull. A painted prop paints the model's own materials through a material override, which
## flattens its colours: that is what the tool gun's paint is asked to do.
func _build_model() -> bool:
	var scale := float(def.meta.get("model_scale", 1.0)) * size_scale
	var info := DotPropModel.measure(model_of(def), scale, str(def.meta.get("shape", "convex")))

	if not info.ok:
		DotLog.warn(CHANNEL, "a prop's model would not load", {
			"prop": String(def.id), "why": info.error.message,
		})
		return false

	var data := info.value as Dictionary
	var visual := DotPropModel.visual(model_of(def), scale, data["offset"])

	if visual == null:
		return false

	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = data["shape"]
	add_child(collision)

	visual.name = "Mesh"
	add_child(visual)

	if tint.a > 0.0:
		_apply_tint(visual, tint)

	return true


func _apply_tint(node: Node, colour: Color) -> void:
	for found in node.find_children("*", "MeshInstance3D", true, false):
		var material := StandardMaterial3D.new()
		material.albedo_color = colour
		(found as MeshInstance3D).material_override = material


## Resizes to [param factor] of the definition, clamped to [constant MIN_SCALE] ..
## [constant MAX_SCALE]. Mass goes with the volume — a barrel twice the size weighs eight
## times as much — because a giant crate a physics gun lifts like a feather is the first
## thing anybody tries with a resizer. Returns the scale actually applied.
func set_size_scale(factor: float) -> float:
	var clamped := clampf(factor, MIN_SCALE, MAX_SCALE)

	if is_equal_approx(clamped, size_scale):
		return size_scale

	size_scale = clamped

	if def != null:
		refresh_mass()
		_build_body()

	return size_scale


## The mass this prop should have: the definition's, by its volume, by the weight setting.
func refresh_mass() -> void:
	if def != null:
		mass = maxf(def.mass * pow(size_scale, 3.0) * mass_multiplier, 0.1)


## Paints the prop. A colour with no alpha takes the paint off.
func set_tint(colour: Color) -> void:
	tint = colour

	if model_of(def) != "" and get_node_or_null("Mesh") != null:
		if colour.a > 0.0:
			_apply_tint(get_node("Mesh"), colour)
		else:
			_build_body()
		return

	var mesh := get_node_or_null("Mesh") as MeshInstance3D

	if mesh != null and mesh.material_override is StandardMaterial3D:
		(mesh.material_override as StandardMaterial3D).albedo_color = (
			colour if colour.a > 0.0 else (colour_of(def) if def != null else Color.WHITE)
		)


# --- Reading a definition --------------------------------------------------
#
# Public, and static, because the spawn menu draws an icon from the same three fields
# this builds the body from. A barrel is a green cylinder in the world and a green
# cylinder in the menu because both read `meta` through here — and a second copy of
# "what does meta mean" is a second thing that can disagree with the first.

static func shape_of(p_def: DotPropDef) -> Shape:
	match str(p_def.meta.get("shape", "box")).to_lower():
		"sphere":
			return Shape.SPHERE
		"cylinder":
			return Shape.CYLINDER
		_:
			return Shape.BOX


static func extent_of(p_def: DotPropDef) -> Vector3:
	var raw: Variant = p_def.meta.get("extent", null)

	if not (raw is Array) or (raw as Array).size() != 3:
		return DEFAULT_EXTENT

	var values := raw as Array

	# Clamped rather than trusted. A zero extent is a collision shape with no
	# volume, which the solver treats as a point and which then falls through
	# everything — and it arrives here from a JSON catalogue an operator wrote.
	return Vector3(
		maxf(float(values[0]), 0.05),
		maxf(float(values[1]), 0.05),
		maxf(float(values[2]), 0.05)
	)


static func colour_of(p_def: DotPropDef) -> Color:
	var raw := str(p_def.meta.get("colour", ""))

	if raw == "" or not Color.html_is_valid(raw):
		return Color(0.72, 0.55, 0.30)

	return Color.html(raw)


static func _make_shape(shape: Shape, extent: Vector3) -> Shape3D:
	match shape:
		Shape.SPHERE:
			var sphere := SphereShape3D.new()
			# The extent is a diameter everywhere else in this file, so halve it
			# here rather than making spheres the one entry an operator writes in
			# radii.
			sphere.radius = extent.x * 0.5
			return sphere
		Shape.CYLINDER:
			var cylinder := CylinderShape3D.new()
			cylinder.radius = extent.x * 0.5
			cylinder.height = extent.y
			return cylinder
		_:
			var box := BoxShape3D.new()
			box.size = extent
			return box


static func _make_mesh(shape: Shape, extent: Vector3) -> Mesh:
	match shape:
		Shape.SPHERE:
			var sphere := SphereMesh.new()
			sphere.radius = extent.x * 0.5
			# A SphereMesh's height is its full extent while its radius is half of
			# one, so the two have to be set together or it draws an ellipsoid that
			# does not match the collision shape it is inside.
			sphere.height = extent.x
			return sphere
		Shape.CYLINDER:
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = extent.x * 0.5
			cylinder.bottom_radius = extent.x * 0.5
			cylinder.height = extent.y
			return cylinder
		_:
			var box := BoxMesh.new()
			box.size = extent
			return box
