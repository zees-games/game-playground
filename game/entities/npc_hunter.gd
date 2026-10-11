extends "playground_entity.gd"

## A chaser with a **decision** rather than an `if`: dot-npc-ai's state machine and
## characteristics table, on top of dot-npc's senses.
##
## [b]`npc_chaser.gd` is still here and is still correct, and this is not a replacement for
## it.[/b] That one is thirty lines and does one thing; this one is what the same NPC looks
## like when a game wants it to be an opponent rather than a hazard. Both are in the
## catalogue, because a sandbox wants the cheap one for filling a room with and the
## expensive one for the arena — and because keeping both is the only honest way to say
## what the addon actually bought.
##
## What it buys, concretely:
##
## - **A reaction time.** `DotNpcAiCharacter` is the arena shooters' characteristics
##   table, and
##   `has_reacted()` is the gate every "act on what you see" branch belongs behind. An NPC
##   that turns and commits on the tick it first perceives somebody is one no player can
##   ever surprise, and that is the difference between a bot and a target.
## - **A character per NPC, which the server moves rather than replaces.** Each one gets its
##   own seed from its spawn (`npc.seed`), so twenty of them do not all react at the same moment —
##   which reads as a firing squad and is the bug the seeding exists to prevent. `npc_skill`
##   and `npc_reaction_scale` ([member Playground.npc_skill]) shift it live.
## - **Separation.** Twelve of these converging on one player climb each other, and the one
##   on top has a horizontal offset of nothing from the one below: it chases perfectly at a
##   dead stop with every number about it correct. `steer_with_spacing` is the fix and
##   dot-npc-ai found it the hard way.
## - **A machine rather than a tree**, because there are four states and the transitions
##   between them are the whole design. A tree here would be four leaves under a selector
##   pretending to be a hierarchy.
##
## [b]`extends` a PATH, not a class.[/b] A brain is named by path in the catalogue and a
## mounted dot-cloud pack's `class_name` globals are not registered in the host, so an
## entity that named a class could only ever ship inside a build.

const STATE_PATROL := &"patrol"
const STATE_ALERT := &"alert"
const STATE_CHASE := &"chase"
const STATE_LOST := &"lost"

## The decision, and the memory it is made against.
var machine: DotNpcAiMachine = null
var blackboard: DotNpcAiBlackboard = null
var context: DotNpcAiContext = null
var character: DotNpcAiCharacter = null

## The character as the catalogue named it, before the server's skill moved it.
var _base_character: DotNpcAiCharacter = null
var _skill_revision: int = -1

var _heading: Vector3 = Vector3.FORWARD
var _stand_off: float = 1.8
var _speed: float = 5.0


func _entity_ready() -> void:
	_speed = tune(&"speed", 5.0)
	_stand_off = tune(&"stand_off", 1.8)

	# [b]A character per NPC, seeded from the spawn.[/b] A preset is one resource, and
	# twenty NPCs sharing it share a seed — so every one of them reacts at the same
	# moment, which reads as a firing squad. `with_seed` is the one call that prevents it.
	_base_character = DotNpcAiCharacter.preset(tune_string(&"skill", "normal")).with_seed(
		npc.seed if npc != null else 0
	)

	blackboard = DotNpcAiBlackboard.new()
	context = DotNpcAiContext.make(npc, self, blackboard)
	_refresh_character()

	_heading = Vector3.FORWARD.rotated(
		Vector3.UP, float(npc.seed if npc != null else 0)
	)

	machine = DotNpcAiMachine.new()

	machine.add(
		DotNpcAiState.make(STATE_PATROL, _patrol)
			.when(_sees_somebody, STATE_ALERT)
	)
	machine.add(
		# [b]ALERT is where the reaction time is spent, and it is a state rather than a
		# check inside CHASE.[/b] An NPC that "reacted" by standing perfectly still for a
		# third of a second and then sprinting is a different thing from one that turns to
		# look and then sprints — and only the second reads as having noticed you.
		DotNpcAiState.make(STATE_ALERT, _turn_toward)
			.when(func(_c: DotNpcAiContext) -> bool: return not _has_target(), STATE_LOST)
			.when(func(_c: DotNpcAiContext) -> bool: return _reacted(), STATE_CHASE)
	)
	machine.add(
		DotNpcAiState.make(STATE_CHASE, _chase)
			.when(func(_c: DotNpcAiContext) -> bool: return not _has_target(), STATE_LOST)
	)
	machine.add(
		# [b]LOST has a floor as well as a condition.[/b] Without the timer an NPC on the
		# edge of its sight range flickers between CHASE and PATROL every tick, which
		# looks like a fit — the classic broken NPC this family already documented once.
		DotNpcAiState.make(STATE_LOST, _search)
			.when(_sees_somebody, STATE_ALERT)
			.after(tune(&"give_up_seconds", 2.5), STATE_PATROL)
	)

	var started := machine.go_to(context, STATE_PATROL)

	if not started.ok:
		DotLog.warn("playground.npc", "a hunter could not start patrolling", {
			"why": started.error.message,
		})


func _entity_tick(delta: float) -> void:
	if context == null or machine == null:
		return

	context.advance(delta)
	_refresh_character()
	machine.tick(context)


## The character in force, worked out again only when the server's skill changed.
##
## The same thing `DotNpcAiBrain` does for a spawned NPC; this entity is built by the spawn
## menu rather than by a spawner, so it has no brain to do it and asks the world instead.
func _refresh_character() -> void:
	var skill: DotNpcAiSkill = game.npc_skill if game != null else null
	var revision := skill.revision if skill != null else 0

	if revision == _skill_revision and character != null:
		return

	_skill_revision = revision
	character = skill.apply(_base_character) if skill != null else _base_character
	context.character = character

	# How far this one sees, from its character. dot-npc's senses read it per NPC.
	if npc != null:
		npc.sight_scale = character.alertness


# --- States ----------------------------------------------------------------

func _patrol(ctx: DotNpcAiContext) -> void:
	# Wandered rather than re-rolled. A direction chosen fresh every tick is Brownian
	# motion: it averages to standing still, and an NPC that never goes anywhere is one
	# players never meet.
	var angle := DotNpcAiSteering.wander(
		atan2(_heading.z, _heading.x), 0.35,
		(npc.seed if npc != null else 0) + int(ctx.now * 3.0)
	)
	_heading = DotNpcAiSteering.angle_to_direction(angle)

	# Slower than a chase. An NPC that patrols at full speed cannot be crept up on and
	# cannot be outrun, which removes both halves of the encounter.
	drive(_heading, _speed * 0.35, ctx.delta)


func _turn_toward(ctx: DotNpcAiContext) -> void:
	var to := _to_target()

	if to == Vector3.ZERO:
		return

	# Turning, not moving. The view turn is the character's — `view_turn_deg` is what
	# stops it snapping round in one tick, which is the other half of not being a target.
	look_at_direction(to)
	drive(Vector3.ZERO, 0.0, ctx.delta)


func _chase(ctx: DotNpcAiContext) -> void:
	var chasing := target()

	if chasing == null:
		return

	var to := _to_target()

	if to.length() < _stand_off:
		# Stops just short rather than walking into them: a rigid body pressing against a
		# CharacterBody3D every tick pushes the player around the map, and a player being
		# shoved by something they cannot damage is the worst thing this file could do.
		look_at_direction(to)
		return

	# [b]With spacing, which is the whole reason this uses dot-npc-ai's brain helper.[/b]
	# A pack converging on one player climbs each other, and the one on top has a
	# horizontal offset of nothing from the one below — so it chases perfectly at a dead
	# stop with every number about it correct.
	var here := global_position
	var apart := DotNpcAiSteering.separate(
		here, _neighbours(2.4), 2.4, global_basis.x
	)
	var wanted := DotNpcAiSteering.blend([
		[DotNpcAiSteering.seek(here, here + to), 1.0], [apart, 0.6]
	])

	if wanted.length() < 0.001:
		return

	drive(wanted, _speed, ctx.delta)


func _search(ctx: DotNpcAiContext) -> void:
	# Toward where they were last seen rather than standing still. An NPC that stops dead
	# the instant it loses you is one you escape by stepping behind a crate; one that
	# comes to look is one you have to actually leave.
	var last: Variant = blackboard.get_value(&"last_seen", ctx.now, null)

	if last is Vector3:
		var to: Vector3 = (last as Vector3) - global_position
		to.y = 0.0

		if to.length() > 1.0:
			drive(to, _speed * 0.7, ctx.delta)
			return

	_patrol(ctx)


# --- Conditions ------------------------------------------------------------

func _sees_somebody(_ctx: DotNpcAiContext) -> bool:
	if not _has_target():
		return false

	# Remembered on the tick it is seen, for as long as this character remembers — a
	# blackboard that never forgot would send an NPC to a position from five minutes ago.
	# A memory of nothing is skipped rather than written: a lifetime of 0 is "for ever".
	if character != null and character.memory_time > 0.0:
		blackboard.put(&"last_seen", _target_position(), context.now, character.memory_time)
	return true


func _has_target() -> bool:
	return target() != null


## Whether enough time has passed since this NPC committed to what it is looking at.
##
## [b]`target_since`, not `engaged_at`, and the difference is a bug this file also had.[/b]
## `engaged_at` is refreshed on every pass in which the target is perceived — which is what
## a reclaim asks about — so a reaction time measured against it never elapses for an NPC
## that can currently see somebody. The first version of this file used it and the hunter
## sat in ALERT for ever; so did [method DotNpcAiBrain.has_reacted], which is where the fix
## actually belongs and where it now is. `DotNpcInstance.target_since` was added to dot-npc
## for exactly this and moves only when the commitment does.
func _reacted() -> bool:
	if character == null or npc == null or context == null:
		return true

	return character.has_reacted(npc.target_since, context.now)


func _to_target() -> Vector3:
	var chasing := target()

	if chasing == null:
		return Vector3.ZERO

	var to := chasing.global_position - global_position
	to.y = 0.0
	return to


func _target_position() -> Vector3:
	var chasing := target()
	return chasing.global_position if chasing != null else Vector3.ZERO


## Everything of this kind standing near enough to be climbed.
func _neighbours(radius: float) -> Array:
	var out: Array = []

	if game == null:
		return out

	for other in game.entities:
		if other == self or not is_instance_valid(other):
			continue

		if other.global_position.distance_to(global_position) <= radius:
			out.append(other.global_position)

	return out


func describe() -> Dictionary:
	var out := super.describe()
	out["state"] = String(machine.current()) if machine != null else "?"
	out["skill"] = character.id if character != null else &""
	return out
