extends RefCounted

const PlaygroundLighting := preload("playground_lighting.gd")
const PlaygroundPaths := preload("playground_paths.gd")

## Builds dev-textured collision geometry in code, so the maps need no art.
##
## [b]Why the maps are built by a script rather than authored in the editor.[/b] Two
## reasons, and the second is the one that matters. The first is that this project
## ships no art and a hand-placed grey box is no more readable in a [code].tscn[/code]
## than one line of code. The second is that a map's survey, its toys and the suites read
## the same constants the geometry was built from, so none of them can drift apart.
##
## A real game authors its maps in the editor. These are test fixtures that happen to be
## playable.

## The palette: what each kind of surface a movement map is made of is drawn in.
##
## [b]Pastels over a light grid, so a surface says what it is and the map reads as a sunny
## place[/b] rather than a grey test level: a mid-grey floor, sky-blue ramps, a mint start,
## a pink end, lavender platforms, a saturated yellow for anything that throws you. Every
## built-in map and every custom document that names a colour ("ramp", "start") takes these,
## so a repaint is here and nowhere else; a document's own hex colours stay its own. They
## are albedo, sRGB, chosen bright because the grid texture under them is about 0.82 grey.
## Start and end keep their old meanings (green-ish and red-ish) so a route still reads.
## The floor is the exception to "bright": a mid cool grey, because it fills half of every
## frame, and near white (0.90, 0.91, 0.97) it rendered as a fifth of a flat map's pixels at
## pure white under Compatibility; the pastels on it now read against it (game-arena's
## ground is the same shade, for the same reason).
const COLOUR_FLOOR := Color(0.66, 0.68, 0.76)
const COLOUR_RAMP := Color(0.60, 0.82, 1.00)
const COLOUR_START := Color(0.58, 0.96, 0.78)
const COLOUR_END := Color(1.00, 0.62, 0.72)
const COLOUR_PLATFORM := Color(0.82, 0.74, 1.00)
## A booster: something on the map that throws the player. The one saturated colour.
const COLOUR_BOOST := Color(1.00, 0.78, 0.22)
## A float: columns standing in a low-gravity zone, which is invisible. A document's "float".
const COLOUR_FLOAT := Color(0.48, 0.90, 0.90)
## A relay gate's frame, and the see-through pane inside it that a player jumps into to be
## teleported (a TELEPORT zone, which is as invisible as the float's gravity).
const COLOUR_GATE := Color(0.86, 0.42, 1.00)
const COLOUR_GATE_PANE := Color(0.86, 0.42, 1.00, 0.30)

## Kenney's Prototype Textures (CC0): the light grid with white lines for every surface,
## and the light tiles for the floor colour, so the ground a player crosses reads as ground
## and a wall or a ramp beside it as something standing on it. Tinted per material.
const GRID_PATH := "res://assets/kenney/prototype/grid.png"
const TILES_PATH := "res://assets/kenney/prototype/tiles.png"

## Metres one copy of the grid texture covers. It has two major cells across, so 2 m puts
## a major line every metre (the unit a gap is counted in) and a faint one every 25 cm.
const GRID_METRES := 2.0


## A static box with collision and a visible mesh.
##
## [param size] is the full extent, and [param at] is its centre — the same
## convention [AABB] and [BoxShape3D] use, and deliberately not "a corner", because
## every zone in this file is placed relative to a box's middle.
static func box(
	parent: Node3D,
	at: Vector3,
	size: Vector3,
	colour: Color = COLOUR_FLOOR,
	basis: Basis = Basis.IDENTITY
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(basis, at)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh.mesh = box_mesh

	mesh.material_override = _material(colour)

	body.add_child(mesh)
	parent.add_child(body)

	return body


## A box that is drawn and nothing else: no body, no collision.
##
## For what a map shows without being ground: a gate's frame and its pane. Not a
## `StaticBody3D`, so `PlaygroundMapSurvey` (which reads bodies) never sees one and a
## player passes through it.
static func panel(
	parent: Node3D, at: Vector3, size: Vector3, colour: Color = COLOUR_FLOOR
) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh.mesh = box_mesh
	mesh.material_override = _material(colour)
	mesh.position = at
	# Passable by design (this function's whole point): said so to dot-core's collision audit,
	# so a panel is not one of the findings that a real missing collider would be.
	mesh.set_meta(DotCollisionAudit.META, true)
	parent.add_child(mesh)
	return mesh


## One material per colour, shared by every box of that colour: the client draws with the
## Compatibility renderer, where a material change is a state change per draw.
static var _materials: Dictionary = {}

## The grid every surface is drawn with, loaded (or generated) once.
static var _grid: Texture2D = null
static var _tiles: Texture2D = null

## Pixels per metre of the generated fallback grid, and how dark its lines are.
const GRID_PIXELS := 64
const GRID_LINE := 0.72


## The material a box of [param colour] is drawn with: the colour over Kenney's prototype
## grid, laid in WORLD space and lit by the map's sun.
##
## [b]A grid, because flat colour said nothing about size.[/b] Until 2026-09-25 these were a
## bare colour, so a 3 m block beside a 60 m ramp read as two tiles and a gap could not be
## judged from any angle. World-triplanar rather than UV, because a box's own UVs stretch
## one texture over its whole face, which is the scale problem again.
##
## [b]Lit, since every map carries a sun, a sky and a fill light[/b] (`playground_lighting.gd`).
## They were unshaded while the maps had no light worth the name; lit, a face turned from
## the sun is a shade darker and the edges of a box show without a line drawn on them.
static func _material(colour: Color) -> StandardMaterial3D:
	if _materials.has(colour):
		return _materials[colour]

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	var texture := _grid_texture()
	if colour == COLOUR_FLOOR:
		texture = _tiles_texture()
	material.albedo_texture = texture
	material.uv1_scale = Vector3.ONE / (GRID_METRES if texture is CompressedTexture2D else 1.0)
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	material.roughness = 0.85
	material.metallic = 0.0
	# A colour that is not opaque is a see-through material: glass, water, ice. Drawn both
	# sides, so a pane of glass is seen from inside a room too, and a water surface from
	# under it.
	if colour.a < 0.999:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_materials[colour] = material
	return material


## Kenney's grid, through the rebase (a delivered game's art is under its mount). A checkout
## that has not been imported yet falls back to a generated one-metre grid rather than
## failing, which is why the material asks which of the two it got.
static func _grid_texture() -> Texture2D:
	if _grid != null:
		return _grid

	_grid = _load(GRID_PATH)
	if _grid != null:
		return _grid

	var image := Image.create(GRID_PIXELS, GRID_PIXELS, false, Image.FORMAT_RGB8)
	image.fill(Color.WHITE)
	var line := Color(GRID_LINE, GRID_LINE, GRID_LINE)
	var half := Color(0.88, 0.88, 0.88)

	for i in range(GRID_PIXELS):
		for w in range(2):
			image.set_pixel(i, w, line)
			image.set_pixel(w, i, line)
		image.set_pixel(i, GRID_PIXELS / 2, half)
		image.set_pixel(GRID_PIXELS / 2, i, half)

	image.generate_mipmaps()
	_grid = ImageTexture.create_from_image(image)
	return _grid


## The floor's tiles, or the grid where the checkout has not been imported.
static func _tiles_texture() -> Texture2D:
	if _tiles == null:
		_tiles = _load(TILES_PATH)
	return _tiles if _tiles != null else _grid_texture()


static func _load(path: String) -> Texture2D:
	var at := PlaygroundPaths.rebase(path)
	return load(at) as Texture2D if ResourceLoader.exists(at) else null


## A ramp: a long thin box, tilted by [param angle_degrees] about [param axis].
##
## The tilt is applied to the box rather than to a plane, so the ramp has a back and
## an end — which is what makes a surf map a place rather than an infinite slope, and
## is the difference between this and [code]DotFpsFlatBody.add_ramp[/code].
static func ramp(
	parent: Node3D,
	at: Vector3,
	size: Vector3,
	angle_degrees: float,
	axis: Vector3 = Vector3.FORWARD,
	colour: Color = COLOUR_RAMP
) -> StaticBody3D:
	return box(
		parent, at, size, colour,
		Basis(axis.normalized(), deg_to_rad(angle_degrees))
	)


## The map's sun, sky and air, from [param lighting] (a dot-lighting document; empty is
## the game's daylight). Every map calls this once from its build, so the light arrives and
## leaves with the map. See `playground_lighting.gd`.
static func light(parent: Node3D, lighting: Dictionary = {}) -> DirectionalLight3D:
	return PlaygroundLighting.build(parent, lighting)
