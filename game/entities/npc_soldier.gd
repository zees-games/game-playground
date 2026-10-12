extends "playground_entity.gd"

## An NPC that carries a weapon and fights with it: dot-npc-ai's tactical brain on a body,
## with a real zee weapon in its hands.
##
## [b]The weapon is a zee rig, the same one a player holds.[/b] Fire rate, magazine,
## reload, spread and damage are the weapon's, not this file's, so an NPC with a shotgun is
## dangerous close and useless far for the same reason a player with one is. The brain
## decides when to pull the trigger — every gate a person has, see `ready_to_fire` — and
## this body holds it down for the rig. Ammunition is topped up from an endless reserve,
## because an NPC that ran dry and stood there would read as broken, not as out of ammo.
##
## [b]Hostile or friendly is a faction, nothing more.[/b] A soldier is on `hostile` and
## fights players and rebels; a rebel is on `player`, so the senses never pick a player and
## it fights soldiers instead, and follows whoever spawned it. Same file, two catalogue rows.
##
## [b]It dies.[/b] Health from the catalogue; shots from players and from other NPCs land
## through [method take_damage]; at zero it drops its weapon as a pickup and is removed.

const PlaygroundZee := preload("../playground_zee.gd")
const SoldierBrain := preload("soldier_brain.gd")
const NpcHands := preload("npc_hands.gd")

## Seconds a dropped weapon lies before it is cleaned up.
const DROP_LIFETIME := 45.0

## Set by [PlaygroundZee.arm] — the rig in this NPC's hands, or null.
var zee_rig: Node = null

## The hand a world model hangs from on a client. See `npc_hands.gd`.
var zee_world: Node3D = null

## The game's weapon id in its hands (`zee:smg`), or empty.
var weapon_id: StringName = &""

var health: float = 100.0
var max_health: float = 100.0

var brain: Object = null

var _hands: Node3D = null
var _held_trigger: bool = false
var _dead: bool = false


func _entity_ready() -> void:
	max_health = tune(&"health", 100.0)
	health = max_health

	# Upright, always. A box that a shove tips over lies on its side shooting the floor,
	# and turning is the brain's job through `face`, which writes the basis directly.
	axis_lock_angular_x = true
	axis_lock_angular_z = true

	npc.def.meta = def.meta.duplicate(true) if def != null else {}
	npc.def.max_health = max_health
	npc.health = max_health

	_hands = NpcHands.new()
	_hands.name = "Hands"
	add_child(_hands)
	_hands.position = Vector3(0.35, 0.25, -0.35)

	var chosen := game.npc_weapon_for(instance.owner_id if instance != null else &"", StringName(tune_string(&"weapon", "")))
	var _armed := arm_with(chosen)

	var made: Object = SoldierBrain.new()
	made.set("body", self)

	var preset := tune_string(&"skill", "normal")
	made.set("character", DotNpcAiCharacter.preset(preset))
	# One squad per player AND per side. Per player, so two players' armies do not share
	# slots; per side, because a player who spawns soldiers and rebels has spawned two
	# armies, not one — and the first version put both in one squad, so each side's
	# fire-lane check found a squadmate standing in the lane (its own target) and nobody
	# ever fired. Found by a probe printing every gate: seen, reacted, facing, and silent.
	made.set("squad_name", StringName("npc:%s:%s" % [
		String(instance.owner_id if instance != null else &""), tune_string(&"faction", "hostile"),
	]))
	brain = made
	brain.call("bind", npc, game.npc_world)

	game.register_armed_npc(self)


## Puts [param id] in its hands, or empties them for an empty id. Refuses a weapon an NPC
## cannot use. What the tool gun's NPC-weapon mode calls.
func arm_with(id: StringName) -> DotResult:
	if id == &"" or id == &"none":
		PlaygroundZee.disarm(self)
		weapon_id = &""
		return DotResult.success(&"")

	var def := game.weapon_def(id) if game != null else null

	if def == null or not PlaygroundZee.npc_can_use(def):
		return DotResult.fail(DotError.CODE_INVALID, "An NPC cannot use that.", String(id))

	var rig := PlaygroundZee.arm(self, def, ZeeWeaponRig.Role.SERVER, true, game.tick_rate, game.current_tick())

	if rig == null:
		return DotResult.fail(DotError.CODE_STATE, "That weapon could not be armed.")

	weapon_id = id
	PlaygroundZee.top_up(rig)
	return DotResult.success(id)


func is_armed() -> bool:
	return zee_rig != null and is_instance_valid(zee_rig)


func holds_melee() -> bool:
	return is_armed() and PlaygroundZee.rig_is_melee(zee_rig)


## Where its shots start: the hands, which are where its weapon is drawn.
func muzzle() -> Vector3:
	return _hands.global_position if _hands != null else global_position + Vector3.UP * 0.4


# --- The tick -------------------------------------------------------------------

func _entity_tick(delta: float) -> void:
	if _dead or brain == null:
		return

	# Players AND the other armed NPCs, so rebels and soldiers find each other.
	var _target := game.npc_senses.update_target(
		npc, game.npc_candidates_all, game.npc_world.now(), game.npc_candidates_all.size()
	)

	brain.set("wants_fire", false)
	brain.call("think", delta)

	if is_armed():
		_drive_weapon()


func _drive_weapon() -> void:
	var rig := zee_rig as ZeeWeaponRig
	var fire := bool(brain.get("wants_fire"))
	var aim: Vector3 = brain.get("aim_at")
	var origin := muzzle()
	var direction := (aim - origin).normalized() if fire and aim.distance_to(origin) > 0.01 else -global_basis.z

	var command := DotWeaponCommand.new()
	# Held, then released, for a semi-automatic weapon: a trigger held down fires one shot
	# and then nothing, which is a semi's whole definition — so a held trigger is let go
	# every other tick. An automatic one simply fires at its own rate while held.
	var press := fire and not (_held_trigger and not PlaygroundZee.rig_is_automatic(rig))
	command.set_button(DotWeaponCommand.BUTTON_ATTACK, press)
	command.set_button(DotWeaponCommand.BUTTON_RELOAD, PlaygroundZee.rig_magazine_empty(rig))
	command.slot = PlaygroundZee.slot_of(rig)
	_held_trigger = press

	var ctx := DotWeaponContext.new()
	ctx.tick = game.current_tick()
	ctx.origin = origin
	ctx.direction = direction
	ctx.entity = game.npc_entity_id(self)
	ctx.authority = true

	var outcome := rig.simulate_tick(command, ctx.tick, ctx)

	if outcome != null and outcome.used:
		game.npc_shots_fired(self, outcome)

	PlaygroundZee.top_up(rig)


# --- Being hurt -----------------------------------------------------------------

## Damage from a shot, a blow or anything else. [param by] is a candidate id — a player
## (`u3`) or an armed NPC — and becomes what this NPC is angry with.
func take_damage(amount: float, by: StringName = &"") -> void:
	if _dead or amount <= 0.0:
		return

	var taken := minf(amount, maxf(health, 0.0))
	health -= amount

	# The shooter's hit marker and number, when the shooter is a player (the game decides).
	# Above the middle of the body, where a number reads, rather than wherever the pellet went.
	if game != null and is_inside_tree():
		game.confirm_hit(by, Playground.hit_victim_id(DotEntity.KIND_NPC, game.npc_entity_id(self)),
			taken, global_position + Vector3.UP * 1.4, health <= 0.0)

	if brain != null:
		brain.call("damaged", amount, by)

	if health <= 0.0:
		_die(by)


func _die(by: StringName) -> void:
	_dead = true

	DotLog.debug("playground.npc", "an armed NPC died", {
		"npc": String(def.id) if def != null else "?", "by": String(by),
	})

	if weapon_id != &"" and game != null:
		game.drop_weapon(weapon_id, global_position + Vector3.UP * 0.5, DROP_LIFETIME)

	if brain != null:
		brain.call("died", by)

	# How the body falls on every screen; the bridge sends it with the PROP_GONE.
	var _fall := game.decide_npc_death(self, by)
	game.props.remove(instance.instance_id, &"killed")


func _exit_tree() -> void:
	if game != null:
		game.unregister_armed_npc(self)

	if brain != null:
		brain.call("unbind")
		brain = null


func describe() -> Dictionary:
	var out := super.describe()
	out["health"] = "%.0f/%.0f" % [health, max_health]
	out["weapon"] = String(weapon_id) if weapon_id != &"" else "-"

	if brain != null:
		out["brain"] = brain.call("describe")

	return out
