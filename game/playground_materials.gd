extends RefCounted

## What a map box can be made of, and what that means here: how it looks, how props slide
## and bounce on it, how a player moves on it, and whether it is a liquid you are IN.
##
## [b]The numbers are dot-physics' standard table, read once.[/b] Friction, bounce and
## density go to the solver from `DotPhysicsSurface`; the player's movement comes from the
## same entry through dot-player-controller's `DotFpsSurface.from_physics`, so ice is one
## number for a crate and for a person. The only thing this file adds is the LOOK, which is
## this game's (a colour over the prototype grid, lit by the map's sun).
##
## [b]A player's surface is found from the box's metadata[/b] (`dot_fps_surface`), which a
## client and a server both build from the same map document: a surface resolved any other
## way is one the prediction and the server disagree about.

# No CHANNEL: nothing here logs. A map that names an unknown material is refused by the
# document's validation, which says so.

const META_SURFACE := &"dot_fps_surface"
const META_MATERIAL := &"pg_material"

## What each material looks like, as a colour on the grid. Alpha under 1 is see-through.
const LOOKS := {
	"concrete": Color(0.55, 0.55, 0.53),
	"metal": Color(0.46, 0.52, 0.60),
	"wood": Color(0.55, 0.38, 0.22),
	"glass": Color(0.70, 0.88, 0.95, 0.30),
	"dirt": Color(0.45, 0.33, 0.22),
	"grass": Color(0.30, 0.55, 0.25),
	"sand": Color(0.86, 0.76, 0.52),
	"snow": Color(0.94, 0.96, 0.98),
	"ice": Color(0.70, 0.88, 0.98, 0.85),
	"flesh": Color(0.80, 0.45, 0.45),
	"water": Color(0.15, 0.40, 0.70, 0.55),
	"rock": Color(0.42, 0.41, 0.40),
	"mud": Color(0.33, 0.24, 0.16),
	"rubber": Color(0.20, 0.20, 0.22),
	"lava": Color(1.00, 0.42, 0.08),
	"thin_ice": Color(0.78, 0.92, 1.00, 0.60),
	"slime": Color(0.45, 0.85, 0.20, 0.65),
	"foliage": Color(0.25, 0.50, 0.20, 0.80),
}

static var _physics: DotPhysicsSurfaceSet = null
static var _player: DotFpsSurfaceSet = null


## dot-physics' standard surfaces, built once.
static func physics() -> DotPhysicsSurfaceSet:
	if _physics == null:
		_physics = DotPhysicsSurfaceSet.standard()
	return _physics


## The same table as a player's movement surfaces, for every player's controller.
static func player_surfaces() -> DotFpsSurfaceSet:
	if _player == null:
		_player = DotFpsSurfaceSet.from_physics(physics())
	return _player


static func is_known(id: String) -> bool:
	return physics().has(StringName(id))


static func surface(id: String) -> DotPhysicsSurface:
	return physics().get_surface(StringName(id)) if is_known(id) else null


static func is_liquid(id: String) -> bool:
	var s := surface(id)
	return s != null and s.liquid


## Built with no collider at all: a liquid, or something not solid (foliage).
static func is_volume(id: String) -> bool:
	var s := surface(id)
	return s != null and (s.liquid or not s.solid)


## A liquid a person swims in rather than sinks to the bottom of or burns in: water, slime.
## By density, because that is what decides it (dot-physics' lava is three times water's).
const SWIM_DENSITY := 1200.0


static func is_swimmable(id: String) -> bool:
	var s := surface(id)
	return s != null and s.liquid and s.density <= SWIM_DENSITY


## The colour a box of this material is drawn in, or [param fallback] for none.
static func look(id: String, fallback: Color) -> Color:
	return LOOKS.get(id, fallback)


## Marks a built solid box as made of [param id]: the player's surface, the solver's
## friction and bounce, and the name everything else reads (glass breaking, footsteps).
static func apply(body: StaticBody3D, id: String) -> void:
	var s := surface(id)
	if s == null or body == null:
		return
	body.set_meta(META_SURFACE, StringName(id))
	body.set_meta(META_MATERIAL, StringName(id))
	body.physics_material_override = s.to_physics_material()


static func material_of(node: Object) -> StringName:
	if node is Node and (node as Node).has_meta(META_MATERIAL):
		return StringName(str((node as Node).get_meta(META_MATERIAL)))
	return &""
