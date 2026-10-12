extends RefCounted
## A person: one of the family's animated people (dot-player-char's `DotHumanoidFigure`, the
## style every game's players, bots and NPCs share), dressed from the site's three choices.
##
## [b]Why a figure at all.[/b] Players and NPCs here were capsules, and a member who dressed
## on the site walked into the sandbox as a coloured pill.
##
## [b]Per part, still.[/b] The site's avatar is Kenney's blocky kit, a face, a top and legs each
## one of its eighteen skins; the person takes its skin and hair from the face's skin (which
## also picks which of the four bodies), its top from the top's and its trousers from the legs'
## (`DotHumanoidLook.SITE_SKINS`), so a member is recognisable as what they chose.
##
## [b]Facing -Z, feet at the origin[/b], like every figure here; the person turns itself.

const PlaygroundPaths := preload("playground_paths.gd")
const PlaygroundAvatars := preload("playground_avatars.gd")

const CHANNEL := "playground.figure"

## The person, [param height] metres tall with its feet at the origin and facing -Z, or null
## when the people's art is not in this build. [param skins] is [face, top, legs] as kit
## indices; a negative one takes the next slot's, and all negative takes [param fallback_key]
## hashed, so a guest is dressed the same on every machine.
static func build(height: float, skins: PackedInt32Array, fallback_key: String = "") -> Node3D:
	var resolved := resolve(skins, fallback_key)
	var face := PlaygroundAvatars.LETTERS[resolved[0]]
	var look := DotHumanoidLook.from_letter(face)
	if look == null:
		look = DotHumanoidLook.stock(hash(fallback_key))
	var top: DotHumanoidLook = DotHumanoidLook.from_letter(PlaygroundAvatars.LETTERS[resolved[1]])
	var legs: DotHumanoidLook = DotHumanoidLook.from_letter(PlaygroundAvatars.LETTERS[resolved[2]])
	if top != null:
		look.top = top.top
	if legs != null:
		look.bottom = legs.bottom

	var person := DotHumanoidFigure.new()
	person.name = "Figure"
	person.build(look, height)
	if not person.from_art:
		DotLog.warn(CHANNEL, "no people art; drawing the capsule", {})
		person.free()
		return null
	return person


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


## The person in [param figure], or null for a capsule.
static func person_of(figure: Node) -> DotHumanoidFigure:
	return figure as DotHumanoidFigure


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
	# Nothing here knows how fast an NPC or a prop moves: the person measures it.
	(figure as DotHumanoidFigure).auto_animate = true
	body.add_child(figure)

	var mesh := body.get_node_or_null(^"Mesh") as MeshInstance3D
	if mesh != null:
		mesh.visible = false

	return true
