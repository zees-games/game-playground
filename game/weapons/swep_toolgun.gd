extends "playground_weapon.gd"

## The tool gun: one weapon, many modes — inflate and deflate, paint, remove, weld, rope,
## no-collide, balloons, physical properties, arming an NPC, wiring, and editing a
## selected prop.
##
## [b]The gun does the parts every mode shares, once.[/b] It traces where the player is
## pointing, decides whether they may touch what they hit, and hands the mode a hit. A mode
## (`game/toolgun/`) only says what its three buttons do. Fourteen modes that each traced and
## each checked ownership would be fourteen places for one of them to forget.
##
## [b]Ownership is the sandbox's own rule, not the physics gun's.[/b] The physics gun also
## refuses what is too heavy to carry or what somebody else is holding — neither of which
## has anything to do with whether you may paint it. So the gun asks only "is it yours, or
## does this server let you touch other people's".
##
## Which mode and its settings come from the client — the Q menu's Tools tab — through
## [method set_mode]. On a server they arrive as a request and are clamped to each mode's
## schema before they are used.

# [b]`game/toolgun/`, never `game/tools/`.[/b] dot-server-deploy's pack for this game excludes
# directories named `tools` at ANY depth (it means the repository's dev scripts), and under
# that name every mode below was left out of every delivered build: a tool gun with no modes,
# then (once Playground preloaded one) a game that would not load. Found 2026-10-07 by
# dot-server-deploy's examples/playground_client.tscn.
const ToolResize := preload("../toolgun/tool_resize.gd")
const ToolColour := preload("../toolgun/tool_colour.gd")
const ToolRemover := preload("../toolgun/tool_remover.gd")
const ToolWeld := preload("../toolgun/tool_weld.gd")
const ToolNocollide := preload("../toolgun/tool_nocollide.gd")
const ToolRope := preload("../toolgun/tool_rope.gd")
const ToolBalloon := preload("../toolgun/tool_balloon.gd")
const ToolPhysprop := preload("../toolgun/tool_physprop.gd")
const ToolNpcWeapon := preload("../toolgun/tool_npc_weapon.gd")
const ToolWire := preload("../toolgun/tool_wire.gd")
const ToolEdit := preload("../toolgun/tool_edit.gd")
const ToolWaypoint := preload("../toolgun/tool_waypoint.gd")
const ToolNpcSpawn := preload("../toolgun/tool_npc_spawn.gd")
const PlaygroundLimits := preload("../playground_limits.gd")

## Every mode, in the order the menu shows them.
const MODES := [
	ToolResize, ToolColour, ToolRemover, ToolWeld, ToolNocollide, ToolRope,
	ToolBalloon, ToolPhysprop, ToolNpcWeapon, ToolWaypoint, ToolNpcSpawn, ToolWire, ToolEdit,
]

## The balloon this gun ties on. Hidden from the menu: a balloon is the tool's, not a prop.
const BALLOON_ID := &"balloon"

## How far the gun reaches. Further than a physics gun, because nothing is being carried.
const REACH := 150.0

## Mode id -> the mode.
var modes: Dictionary = {}

## The mode in use.
var mode: StringName = &"resize"

## What the last button press did, for a HUD line. Empty after a silent success.
var last_message: String = ""


func _equip() -> void:
	if modes.is_empty():
		for script in MODES:
			var made: Object = script.new()
			modes[made.get("id")] = made


## The mode in use, or null.
func current() -> Object:
	if modes.is_empty():
		_equip()
	return modes.get(mode)


## Switches to [param p_mode] and applies [param settings] to it.
##
## An unknown mode is refused rather than ignored: a client asking for a mode this server
## does not have is a client from a different build, and doing nothing would read as the
## tool gun being broken.
func set_mode(p_mode: StringName, settings: Dictionary = {}) -> DotResult:
	if modes.is_empty():
		_equip()

	if not modes.has(p_mode):
		return DotResult.fail(DotError.CODE_INVALID, "No such tool.", String(p_mode))

	if p_mode != mode and current() != null:
		current().call("cancel")

	mode = p_mode
	current().call("apply_settings", settings)
	return DotResult.success(current())


# --- The buttons ----------------------------------------------------------------

func _primary(space: Variant, origin: Vector3, aim: Vector3) -> DotResult:
	return _use(&"primary", space, origin, aim)


func _secondary(space: Variant, origin: Vector3, aim: Vector3) -> DotResult:
	return _use(&"secondary", space, origin, aim)


func _reload(space: Variant, origin: Vector3, aim: Vector3) -> DotResult:
	return _use(&"reload", space, origin, aim)


func _use(button: StringName, space: Variant, origin: Vector3, aim: Vector3) -> DotResult:
	var tool := current()

	if tool == null:
		return DotResult.fail(DotError.CODE_STATE, "No tool selected.")

	var hit := trace(space, origin, aim)

	if hit.has("refused"):
		return hit["refused"]

	var res: DotResult = tool.call(button, self, hit)
	last_message = ""

	if res != null and res.ok and str(res.value) == "first":
		last_message = "Now the second."

	return res


## Where the player is pointing: `{point, normal, body, prop}` for a prop, `{point, normal,
## world: true}` for the map, `{}` for nothing, `{refused: DotResult}` for somebody else's.
func trace(space: Variant, origin: Vector3, aim: Vector3) -> Dictionary:
	var state := space as PhysicsDirectSpaceState3D

	if state == null:
		return {}

	var query := PhysicsRayQueryParameters3D.create(origin, origin + aim * REACH)
	var player: Variant = game.players.get(wielder) if game != null else null

	if player is CollisionObject3D:
		query.exclude = [(player as CollisionObject3D).get_rid()]

	var found := state.intersect_ray(query)

	if found.is_empty():
		return {}

	var hit := {"point": found["position"], "normal": found["normal"]}
	var collider: Variant = found["collider"]

	if collider is RigidBody3D and spawner != null:
		var prop := spawner.prop_for_node(collider)

		if prop != null:
			if not may_touch(prop):
				return {"refused": DotResult.fail(DotError.CODE_FORBIDDEN, "That is not yours.")}

			hit["body"] = collider
			hit["prop"] = prop
			return hit

	if collider is StaticBody3D or collider is CSGShape3D:
		hit["world"] = true
		return hit

	# A player, or something nobody spawned. Neither is a thing to weld.
	return {}


# --- What modes ask the gun -----------------------------------------------------

## Whether the wielder may change [param prop]. Theirs, or anybody's on a server that says so.
func may_touch(prop: DotPropInstance) -> bool:
	if prop == null or not prop.is_alive():
		return false

	if prop.owner_id == wielder:
		return true

	# Creative mode: the owner protected it in dot-props, and the tool gun asks too.
	if game != null and game.props != null and not game.props.may_act_for(prop, wielder):
		return false

	return game == null or game.config == null or game.config.touch_others_props


func constraints() -> Object:
	return game.constraints if game != null else null


## Whether the wielder may make one more weld, rope or no-collide.
func may_constrain() -> DotResult:
	if game == null or game.constraints == null:
		return DotResult.fail(DotError.CODE_STATE, "This world cannot tie things.")

	var cap := game.spawn_limits.limit_for(wielder, PlaygroundLimits.CONSTRAINTS)
	var have: int = game.constraints.count_owned(wielder)

	if cap > 0 and have >= cap:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"You have reached your constraints limit (%d)." % cap,
			"%d of %d" % [have, cap]
		)

	return DotResult.success(null)


## A balloon of [param lift] in [param colour], at [param at], counted against `balloons`.
func spawn_balloon(at: Vector3, lift: float, colour: String) -> DotResult:
	if spawner == null:
		return DotResult.fail(DotError.CODE_STATE, "This weapon has no world.")

	var prop := spawner.spawn(BALLOON_ID, wielder, at)

	if prop == null:
		# The refusal has already gone to the player through the spawner's `refused`.
		return DotResult.fail(DotError.CODE_QUOTA, "")

	var body := prop.node as RigidBody3D

	if body != null:
		body.set("lift", lift)
		if body.has_method("set_tint") and Color.html_is_valid(colour):
			body.call("set_tint", Color.html(colour))

	return DotResult.success(body)


func describe() -> Dictionary:
	var out := super.describe()
	out["mode"] = String(mode)
	if current() != null:
		out["settings"] = (current().get("settings") as Dictionary).duplicate()
	return out
