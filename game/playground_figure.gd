extends RefCounted
## A person drawn from the character kit: one model, its face, top and legs each painted
## with one of the kit's eighteen atlases.
##
## [b]Why a figure at all.[/b] Players and NPCs here were capsules, and a member who dressed
## on the site walked into the sandbox as a coloured pill. The kit is CC0, the same art the
## site's avatar editor draws, so a face picked on the site is the face drawn here.
##
## [b]Per part, not per figure.[/b] Every character in the kit is byte-identical geometry
## and UVs over a different atlas, and each limb is its own mesh, so the head can take one
## atlas and the torso another. The minigames paint one atlas over the whole figure; this
## game draws the site's three choices as three.
##
## [b]Turned half a turn.[/b] The kit is glTF, which faces +Z; everything here looks down -Z.
## Unturned, every face is on the back of its head -- game-g2gfast and game-arena shipped
## that and it took a render with a marker on the look direction to see it.
##
## [b]By path, rebased.[/b] Delivered, this game is mounted under `res://dot_cloud/...`, and
## a model or an atlas named by its built path is the one file not there.

const PlaygroundPaths := preload("playground_paths.gd")
const PlaygroundAvatars := preload("playground_avatars.gd")

const CHANNEL := "playground.figure"

static var MODEL := PlaygroundPaths.rebase("res://assets/kenney/characters/character-a.glb")
static var TEXTURES := PlaygroundPaths.rebase("res://assets/kenney/characters/Textures/texture-%s.png")

## Which of [face, top, legs] paints each mesh of the kit, by the mesh's name.
const PART_SLOT := {
	&"head": 0,
	&"torso": 1, &"arm-left": 1, &"arm-right": 1,
	&"leg-left": 2, &"leg-right": 2,
}

## The figure, [param height] metres tall with its feet at the origin and facing -Z, or null
## when the kit's model is not in this build. [param skins] is [face, top, legs] as kit
## indices; a negative one takes the next slot's, and all negative takes [param fallback_key]
## hashed, so a guest is dressed the same on every machine.
static func build(height: float, skins: PackedInt32Array, fallback_key: String = "") -> Node3D:
	var scene: Variant = load(MODEL)

	if not (scene is PackedScene):
		DotLog.warn(CHANNEL, "no character model; drawing the capsule", {"path": MODEL})
		return null

	var model := (scene as PackedScene).instantiate() as Node3D

	if model == null:
		return null

	var resolved := resolve(skins, fallback_key)
	var bounds := _bounds(model, Transform3D.IDENTITY)
	var scale_by := height / maxf(bounds.size.y, 0.01)

	model.name = "Figure"
	model.basis = Basis(Vector3.UP, PI).scaled(Vector3.ONE * scale_by)
	model.position = Vector3(0.0, -bounds.position.y * scale_by, 0.0)

	for mesh in _meshes(model):
		var slot: int = PART_SLOT.get(StringName(mesh.name), 1)
		var material := _material(resolved[slot])
		if material != null:
			mesh.material_override = material

	# The kit's own AnimationPlayer would pose the figure on a clock this game does not run;
	# the body here is posed by the character, so the player is stopped rather than left to
	# play whatever its default is.
	var anim := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if anim != null:
		anim.stop()
		anim.active = false

	return model


## [face, top, legs] with every slot filled: a missing one borrows the top's, then the
## face's, then [param fallback_key]'s hash.
static func resolve(skins: PackedInt32Array, fallback_key: String) -> PackedInt32Array:
	var out := PackedInt32Array([-1, -1, -1])
	for i in range(mini(skins.size(), 3)):
		out[i] = skins[i] if skins[i] >= 0 and skins[i] < PlaygroundAvatars.LETTERS.length() else -1

	var anchor := out[1] if out[1] >= 0 else out[0] if out[0] >= 0 else out[2]
	if anchor < 0:
		anchor = PlaygroundAvatars.stock_index(fallback_key)

	for i in range(3):
		if out[i] < 0:
			out[i] = anchor

	return out


## The kit's leg meshes, for a pose that moves them. Empty for a capsule.
static func legs(figure: Node) -> Array[Node3D]:
	var out: Array[Node3D] = []
	if figure == null:
		return out
	for leg_name in ["leg-left", "leg-right"]:
		var leg := figure.find_child(leg_name, true, false) as Node3D
		if leg != null:
			out.append(leg)
	return out


## Not cached here: the texture is the engine's resource cache's, and a static dictionary of
## materials would outlive the game at exit, which `dedicated` asserts nothing does.
static func _material(index: int) -> StandardMaterial3D:
	var texture: Variant = load(TEXTURES % PlaygroundAvatars.LETTERS[index])

	if not (texture is Texture2D):
		DotLog.warn(CHANNEL, "a character atlas is missing", {"index": index})
		return null

	# Unshaded, as the kit's own material is, and nearest-filtered because it is pixel art.
	var m := StandardMaterial3D.new()
	m.albedo_texture = texture
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return m


static func _bounds(node: Node, to_root: Transform3D) -> AABB:
	var out := AABB()
	var seeded := false
	var mesh := node as MeshInstance3D

	if mesh != null and mesh.mesh != null:
		out = to_root * mesh.mesh.get_aabb()
		seeded = true

	for child in node.get_children():
		var child_to_root := to_root
		if child is Node3D:
			child_to_root = to_root * (child as Node3D).transform
		var inner := _bounds(child, child_to_root)
		if inner.size == Vector3.ZERO and inner.position == Vector3.ZERO:
			continue
		out = inner if not seeded else out.merge(inner)
		seeded = true

	return out


static func _meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		out.append_array(_meshes(child))
	return out


## Swaps a body's primitive `Mesh` child for a figure [param height] tall, standing on the
## bottom of a body centred on its origin (a capsule NPC, an entity prop). [param key] picks
## the look, so every NPC of one kind is dressed alike on every machine and a soldier is told
## from a rebel at a glance. True when the figure went on.
static func dress_body(body: Node3D, height: float, key: String) -> bool:
	if body == null or body.get_node_or_null(^"Figure") != null:
		return false

	var figure := build(height, PackedInt32Array(), key)

	if figure == null:
		return false

	figure.position.y -= height * 0.5
	body.add_child(figure)

	var mesh := body.get_node_or_null(^"Mesh") as MeshInstance3D
	if mesh != null:
		mesh.visible = false

	return true
