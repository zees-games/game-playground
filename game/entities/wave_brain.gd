extends "res://addons/dot_npc_ai/runtime/dot_npc_ai_brain.gd"

## What a director-released NPC does: come at the players, and back off when it loses them.
##
## [b]Extended by PATH, like every brain.[/b] A brain is named by
## [member DotNpcDef.brain_script_path] and a mounted dot-cloud pack's `class_name` globals
## are not registered in the host — so a brain that named a class could only ever ship
## inside a build.
##
## [b]A tree here, and a machine in `npc_hunter.gd`, and the difference is the point.[/b]
## dot-npc-ai ships both and says which is which: a machine holds what an NPC *is* and a
## tree decides what it *does* within that. A wave NPC has one job — reach the players —
## and what varies is which of three ways it is currently doing it, in priority order. That
## is a selector, and writing it as a machine would be three states whose transitions are
## all "if the higher-priority one is unavailable".
##
## The trap this file exists to stay out of: **a guard behind a plain sequence is asked
## exactly once.** The sequence resumes at the running action and never re-checks the
## condition, so an NPC chases a target it no longer has. `reactive_with` is the idiom and
## it is used here for exactly that reason.

## How fast, in metres a second. From the definition, so a catalogue tunes it.
var speed: float = 4.6


func _build() -> void:
	if npc != null and npc.def != null:
		speed = float(npc.def.meta.get("speed", speed))

	tree = DotNpcAiSelector.new(&"root", [
		# Reach them. [b]Reactive, because a sequence that resumed at its running action
		# would keep walking at somebody who is no longer there[/b] — the guard is asked
		# once and never again, which dot-npc-ai wrote into its own fixture on the first
		# pass and documents at both ends.
		DotNpcAiSequence.reactive_with(&"chase", [
			DotNpcAiLeaf.Condition.new(&"sees", _sees),
			DotNpcAiSelector.new(&"engage", [
				# Three of the wave on a player at a time — the squad's attack slots — and
				# the rest on a ring round them, working round to the side the player is not
				# facing. A wave that queued would be a wave a player holds off at a door.
				DotNpcAiSequence.reactive_with(&"attack", [
					DotNpcAiLeaf.Condition.new(&"has a slot", _has_slot),
					DotNpcAiLeaf.Action.new(&"advance", _advance),
				] as Array[DotNpcAiNode]),
				DotNpcAiLeaf.Action.new(&"surround", _surround),
			] as Array[DotNpcAiNode]),
		] as Array[DotNpcAiNode]),
		# Go and look. Not standing still: an NPC that stops dead the instant it loses you
		# is one you escape by stepping behind a crate.
		DotNpcAiSequence.reactive_with(&"search", [
			DotNpcAiLeaf.Condition.new(&"remembers", _remembers),
			DotNpcAiLeaf.Action.new(&"look", _search),
		] as Array[DotNpcAiNode]),
		# Where players actually go on this map, for the NPCs with the tactics to know it.
		DotNpcAiLeaf.Action.new(&"patrol", func(c: DotNpcAiContext) -> int: return patrol_hot(c, speed * 0.5)),
		DotNpcAiLeaf.Action.new(&"wander", _wander),
	] as Array[DotNpcAiNode])


## Whether it can see somebody AND has had time to react to them.
##
## [b]Both halves, and the second is the one that matters.[/b] An NPC that commits on the
## tick it first perceives somebody is one no player can ever surprise — `has_reacted` is
## the arena shooters' reaction time, and the gate every "act on what you see" branch
## belongs
## behind.
func _sees(_ctx: DotNpcAiContext) -> bool:
	return npc.has_target() and has_reacted()


## Whether there is somewhere worth looking. dot-npc-ai's memory, which lasts the
## character's `memory_time` rather than the ten seconds this file used to hard-code.
func _has_slot(_ctx: DotNpcAiContext) -> bool:
	return claim_attack_slot()


func _surround(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	return surround(ctx, speed * 0.8, 4.0, 1.8)


func _remembers(_ctx: DotNpcAiContext) -> bool:
	return remembers_target()


func _advance(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	var goal := _target_position()

	if goal == Vector3.INF:
		return DotNpcAiNode.Status.FAILURE

	# Not remembered here any more: dot-npc-ai's brain keeps the last known position itself,
	# every tick there is a target, for as long as this NPC's character remembers.

	# With spacing: a wave converging on one player climbs itself, and the one on top has
	# a horizontal offset of nothing from the one below — so it chases perfectly at a dead
	# stop with every number about it correct.
	steer_with_spacing(goal, speed, ctx.delta, 1.8)
	return DotNpcAiNode.Status.RUNNING


## Goes there and looks round, then gives up. dot-npc-ai's search: it walks to the spot,
## sweeps its sight cone either side, and forgets once it has looked — where this file used
## to stop dead on arrival and drift off, which a player read as it never having looked.
func _search(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	return search(ctx, speed * 0.8, 1.8)


func _wander(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	var angle := float(blackboard.get_value(&"angle", ctx.now, 0.0))
	angle = DotNpcAiSteering.wander(angle, 0.3, npc.seed + int(ctx.now * 2.0))
	blackboard.put(&"angle", angle, ctx.now, 0.0)

	steer_toward(
		npc.position() + DotNpcAiSteering.angle_to_direction(angle) * 6.0,
		speed * 0.4,
		ctx.delta
	)
	return DotNpcAiNode.Status.RUNNING


## Where the thing this NPC has committed to is, or `Vector3.INF`.
##
## [b]Infinity rather than zero for "gone".[/b] Zero is the middle of the map, so an NPC
## whose target disconnected would sprint to the origin and mill about — which reads as a
## pathfinding bug and is a missing null check.
func _target_position() -> Vector3:
	if not npc.has_target() or director == null:
		return Vector3.INF

	if not director.has_method(&"candidate_position"):
		return Vector3.INF

	var at: Variant = director.call(
		&"candidate_position", npc.target_id, Vector3.INF
	)

	return at if at is Vector3 else Vector3.INF
