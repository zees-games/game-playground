extends "playground_tool.gd"

const PlaygroundZee := preload("../playground_zee.gd")

## Spawns NPCs where it points, armed with the weapon chosen here, or lays a spawn point that
## keeps making them.
##
## [b]Through the prop spawner, as the wielder.[/b] The NPC limit, the cost budget and creative
## protection answer for a tool click exactly as for the entities tab; this tool is a way to
## choose where and with what, never a way round a cap.

## What it can make, in the order the menu shows them.
const KINDS := [
	"npc_soldier", "npc_soldier_elite", "npc_rebel", "npc_wanderer", "npc_chaser", "npc_hunter",
]

## "default" in the weapon choice: the kind's own, or what the player picked on the menu.
const OWN := "default"


func _init() -> void:
	id = &"npc_spawn"
	display_name = "NPC spawner"
	description = "Spawns armed NPCs where you point, or lays a spawn point that keeps making them."
	help_primary = "spawn here (or lay a spawn point)"
	help_secondary = "remove the NPC or spawn point"
	help_reload = "remove all of your spawn points"
	super()


func schema() -> Array[Dictionary]:
	var weapons: Array = [OWN, "none"]
	weapons.append_array(npc_weapon_ids())

	return [
		{"key": "kind", "label": "Kind", "type": "choice", "default": KINDS[0], "options": KINDS.duplicate()},
		{"key": "weapon", "label": "Weapon", "type": "choice", "default": OWN, "options": weapons},
		{"key": "count", "label": "How many", "type": "float", "default": 1.0, "min": 1.0, "max": 8.0, "step": 1.0},
		{"key": "point", "label": "Lay a spawn point instead", "type": "bool", "default": false},
		{"key": "interval", "label": "Point: seconds between", "type": "float", "default": 8.0, "min": 1.0, "max": 120.0, "step": 1.0},
		{"key": "limit", "label": "Point: alive at once", "type": "float", "default": 2.0, "min": 1.0, "max": 8.0, "step": 1.0},
	]


static func npc_weapon_ids() -> Array:
	var out: Array = []

	for def in PlaygroundZee.defs():
		if PlaygroundZee.npc_can_use(def):
			out.append(String(def.id))

	return out


## The weapon id to arm with, or empty for the kind's own.
func chosen_weapon() -> StringName:
	var weapon := str(setting("weapon"))
	return &"" if weapon == OWN else StringName(weapon)


func primary(gun: Object, hit: Dictionary) -> DotResult:
	if not hit.has("point"):
		return DotResult.fail(DotError.CODE_STATE, "Point at the ground.")

	var spawner: DotPropSpawner = gun.get("spawner")

	if spawner == null:
		return DotResult.fail(DotError.CODE_STATE, "This weapon has no world.")

	var wielder: StringName = gun.get("wielder")
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	var at: Vector3 = (hit["point"] as Vector3) + normal * 0.15
	var kind := StringName(str(setting("kind")))

	if bool(setting("point")):
		var prop := spawner.spawn(&"spawn_point", wielder, at)

		if prop == null:
			return DotResult.fail(DotError.CODE_QUOTA, "")

		var made := prop.node
		made.call("configure_point", kind, chosen_weapon(), float(setting("interval")), int(setting("limit")))
		return DotResult.success(made)

	var spawned: Array = []

	for i in int(setting("count")):
		# A ring round the click, so a squad does not spawn inside itself.
		var angle := TAU * float(i) / maxf(float(setting("count")), 1.0)
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * (0.0 if int(setting("count")) == 1 else 1.2)
		var prop := spawner.spawn(kind, wielder, at + Vector3.UP * 1.0 + offset)

		if prop == null:
			break

		spawned.append(prop.node)
		var body := prop.node

		if chosen_weapon() != &"" and body.has_method("arm_with"):
			var _armed: Variant = body.call("arm_with", chosen_weapon())

	if spawned.is_empty():
		return DotResult.fail(DotError.CODE_QUOTA, "")

	return DotResult.success(spawned.size())


func secondary(gun: Object, hit: Dictionary) -> DotResult:
	var prop: Variant = hit.get("prop")

	if not (prop is DotPropInstance):
		return nothing_there()

	var node := (prop as DotPropInstance).node
	var is_npc := node != null and (node.get("npc") != null or node.has_meta(&"spawn_point"))

	if not is_npc:
		return DotResult.fail(DotError.CODE_STATE, "Point at an NPC or a spawn point.")

	gun.get("spawner").remove((prop as DotPropInstance).instance_id, DotPropSpawner.REASON_PLAYER)
	return DotResult.success(1)


func reload(gun: Object, _hit: Dictionary) -> DotResult:
	var spawner: DotPropSpawner = gun.get("spawner")
	var mine: StringName = gun.get("wielder")
	var removed := 0

	if spawner == null:
		return DotResult.fail(DotError.CODE_STATE, "This weapon has no world.")

	for entity in (gun.get("game").get("entities") as Array).duplicate():
		if not is_instance_valid(entity) or not (entity as Node).has_meta(&"spawn_point"):
			continue

		var instance: Variant = entity.get("instance")

		if instance is DotPropInstance and (instance as DotPropInstance).owner_id == mine:
			if spawner.remove((instance as DotPropInstance).instance_id, DotPropSpawner.REASON_PLAYER):
				removed += 1

	return DotResult.success(removed)
