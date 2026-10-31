class_name PlaygroundViewGrip
extends RefCounted

## Where the first-person hands go on a zee weapon: ZeeViewModel measures the grip and fore-end
## from the weapon's own bounds, this only maps its pose to one hand or two.

const NEEDS_LEVEL := 8
## Poses held with the firing hand alone.
const ONE_HAND: Array[StringName] = [&"melee", &"thrown", &"fists"]


static func available() -> bool:
	return DotAddonApi.build_level("dot_player_char") >= NEEDS_LEVEL


## The grip for a hands_reached call, reusing [param old] while the weapon and hand count hold.
static func update(old: DotViewGrip, anchor: Node3D, grip: Vector3, fore: Vector3, pose: StringName) -> DotViewGrip:
	var one := pose in ONE_HAND
	var made := old
	if made == null or made.anchor != anchor or made.is_two_hand() == one:
		made = DotViewGrip.one_hand(anchor, grip) if one else DotViewGrip.two_hand(anchor, grip, fore)
	made.grip = grip
	if not one:
		made.support = fore
	return made
