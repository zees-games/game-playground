extends Node

const PlaygroundPaths := preload("playground_paths.gd")
const PlaygroundFigure := preload("playground_figure.gd")

const Playground := preload("playground.gd")
const PlaygroundPlayer := preload("playground_player.gd")

## NPCs the **server** releases, paced by dot-npc-ai-director.
##
## [b]This is a second population beside the entities, and the split is deliberate.[/b]
## This game's own note says an entity is a `DotPropInstance` first — it counts against a
## prop budget, it is on the undo stack, it goes when its owner leaves, and a physics gun
## can pick it up — because *an NPC you cannot pick up is the first thing a sandbox player
## will try*. That argument is about NPCs a **player** put there.
##
## A wave is not one. It is the server's, nobody spawned it, nobody owns it, and it is
## reclaimed when the players walk away from it — which is exactly the population
## [DotNpcSpawner] and [DotNpcDirector] are for, and none of which a prop budget can
## express. So there are two, with two different owners and two different reasons, and
## `pg_waves 1` is the only thing that makes the second exist at all.
##
## **Off by default**, like the arena. A sandbox where things come at you while you are
## building is a different server, and turning one into the other silently because an addon
## was installed is what a cvar exists to prevent.

const CHANNEL := "playground.waves"

## The body a wave NPC is.
##
## [b]`playground_`-prefixed, and that is a deployment constraint rather than a style.[/b]
## dot-server-deploy flattens every built-in game into one `game/` directory — a
## `.tscn` names its scripts by absolute `res://` path and there is no relative form — so
## an unprefixed name is one another game can silently overwrite. `entity.tscn`,
## `prop.tscn` and `vehicle.tscn` predate that rule and are the reason it exists: the lobby
## added a `prop.tscn` and collided with this project's on the first vendored build.
static var WAVE_SCENE := PlaygroundPaths.rebase("res://game/playground_npc.tscn")
static var WAVE_BRAIN := PlaygroundPaths.rebase("res://game/entities/wave_brain.gd")

## Candidate id prefix, so a target id can be turned back into a player.
##
## A prefix rather than a bare id, because this game keys players by [StringName] already
## and an id that was only a number would be ambiguous the moment a wave NPC could target
## another one.
const PLAYER_PREFIX := "p:"

## How far a shot is heard by a wave NPC of alertness 1, in metres.
const GUNFIRE_RADIUS := 30.0

## The wave's squad — three on a player, the rest surrounding — and what it can hear.
## On the spawner as metadata, where dot-npc-ai's brain finds both.
var squads: DotNpcAiSquads = DotNpcAiSquads.new()
var sounds: DotNpcAiSounds = DotNpcAiSounds.new()

## Where players go on each map, learned while the waves run and patrolled by the wave NPCs
## with the tactics for it. Saving is off until the module turns it on — every suite builds
## waves, and a suite's players must not train the next run's NPCs.
var heat: DotNpcAiHeatKeeper = _make_heat()


static func _make_heat() -> DotNpcAiHeatKeeper:
	var keeper := DotNpcAiHeatKeeper.new("user://npc_heat", "playground")
	keeper.persist = false
	return keeper


## A wave arrived, or one of them is gone. Server side.
signal wave_changed(count: int)


var spawner: DotNpcSpawner = null
var director: DotNpcDirector = null
var game: Playground = null

var _tick: int = 0


## Three kinds, and each is a different problem.
static func catalogue() -> DotNpcCatalogue:
	var out := DotNpcCatalogue.new()

	_add(out, &"runner", "Runner", 60.0, 6.4, 30.0, 1)
	_add(out, &"walker", "Walker", 140.0, 3.6, 40.0, 2)
	_add(out, &"brute", "Brute", 500.0, 2.4, 26.0, 6)

	return out


static func _add(
	into: DotNpcCatalogue,
	id: StringName,
	display: String,
	health: float,
	speed: float,
	sight: float,
	cost: int
) -> void:
	var def := DotNpcDef.make(id, WAVE_SCENE)
	def.display_name = display
	def.brain_script_path = WAVE_BRAIN
	def.category = &"wave"
	def.faction = &"wave"
	def.cost = cost
	def.max_health = health
	def.sight_range = sight
	def.hearing_range = sight * 0.5
	# [b]On, and this is the one place in the family where it is.[/b] A sandbox has walls,
	# pillars and whatever a player built, and an NPC that saw through all of it would
	# make cover meaningless — which is the whole reason `occlusion_mask` exists. The
	# other two games are open arenas with nothing to be occluded by.
	def.require_line_of_sight = true
	# `skill` names the character dot-npc-ai's brain gives it. Until it did, a wave NPC had
	# none, and `has_reacted()` — the gate wave_brain.gd's whole chase sits behind — answered
	# true on the tick it first saw somebody.
	def.meta = {"speed": speed, "skill": "normal", "squad": "wave", "attackers": 3}
	into.add(def)


static var _shared: DotNpcCatalogue = null

## Draws a wave NPC as a person rather than its capsule, as tall as the capsule. Static, so
## a client's mirror is dressed by the same rule (`PlaygroundNetBridge`).
static func dress(body: Node3D, kind: String) -> void:
	if body == null:
		return
	var collision := body.get_node_or_null(^"Collision") as CollisionShape3D
	var capsule := collision.shape as CapsuleShape3D if collision != null else null
	var _dressed := PlaygroundFigure.dress_body(body, capsule.height if capsule != null else 1.8, kind)


static func shared_catalogue() -> DotNpcCatalogue:
	if _shared == null:
		_shared = catalogue()

	return _shared


# --- Lifecycle -------------------------------------------------------------

func setup(p_game: Playground) -> DotResult:
	game = p_game

	var limits := DotNpcLimits.new()
	limits.world_budget = 60
	limits.per_kind_cap = 20
	limits.spawn_interval = 0.0
	# [b]No navigable-spawn requirement.[/b] dot-npc is explicit that "no navigation" is
	# not the same as "off the navigation" — this game paths with a direct steer over a
	# flat map, and requiring a graph would refuse every spawn on a game that has none.
	limits.require_navigable_spawn = false
	# Long enough that being chased across the sandbox is a chase rather than a thing that
	# gives up. dot-npc's default is six seconds and this is a bigger map than that number
	# assumes.
	limits.reclaim_grace = 20.0

	var problem := limits.validate()

	if not problem.ok:
		return problem.wrap("The wave limits are not usable")

	spawner = DotNpcSpawner.new()
	spawner.name = "Spawner"
	spawner.catalogue = shared_catalogue()
	spawner.limits = limits
	spawner.authoritative = true
	# Each wave NPC's own seed (`npc.seed`) comes from the session's seed and its spawn count,
	# never its object id: see dot-npc's docs/runtime.md.
	spawner.seed_base = game.map_seed() if game != null else 0
	# The world's own node, so a wave NPC is in the same physics space as everything else
	# — which is what makes its line-of-sight cast see the sandbox's walls.
	spawner.world_ref = DotNodeRef.of_service(Playground.SERVICE)
	# Before the first spawn, so no wave NPC thinks a tick at the wrong skill.
	if game != null and game.npc_skill != null:
		game.npc_skill.attach(spawner)
	squads.attach(spawner)
	sounds.attach(spawner)
	add_child(spawner)

	spawner.spawned.connect(func(npc: DotNpcInstance) -> void:
		dress(npc.node as Node3D, String(npc.def.id))
		wave_changed.emit(spawner.world_count())
	)
	spawner.removed.connect(func(_npc: DotNpcInstance, _why: StringName) -> void:
		wave_changed.emit(spawner.world_count())
	)

	return _build_director()


func _build_director() -> DotResult:
	var rules := DotNpcDirectorRules.new()
	# A sandbox is tens of metres across, not hundreds. Every distance here is that scale,
	# and `spawn_ahead` is zero because there is no critical path to spawn ahead along —
	# an arena is reachable in every direction and "ahead of the party" means nothing when
	# the party is one person building a wall.
	rules.spawn_min_distance = 14.0
	rules.spawn_max_distance = 60.0
	rules.spawn_ahead = 0.0
	# [b]On, and this is the setting a sandbox actually wants.[/b] Something appearing in
	# front of you is a jump scare; something appearing behind a pillar and walking round
	# it is an encounter. dot-npc took its hiding spots from that practice for the same
	# reason.
	rules.spawn_out_of_sight = true
	rules.behind_fraction = 0.25
	rules.peak_per_player = 8.0
	rules.build_up_per_player = 4.0
	rules.relax_per_player = 1.0
	rules.absolute_cap = 40
	rules.spawn_burst = 3
	rules.spawn_interval = 1.0
	rules.reclaim_interval = 3.0
	# Zero would mean "never" here and "every tick" for `spawn_interval` — two settings
	# named the same way meaning opposite things at zero, which dot-npc-ai-director
	# documents and which is set explicitly rather than left.
	rules.relax_distance = 45.0
	rules.stress_decay = 0.08
	rules.stress_per_damage = 1.4
	rules.stress_per_threat = 0.05
	rules.stress_threat_radius = 10.0

	var problem := rules.validate()

	if not problem.ok:
		return problem.wrap("The director rules are not usable")

	director = DotNpcDirector.new()
	director.name = "Director"
	director.rules = rules
	director.spawner_ref = DotNodeRef.of_path(^"../Spawner")
	# Round-robin, so the mix is exact rather than approached: a random pick from three
	# gives three brutes in a row often enough for a player to notice and conclude the
	# director is broken.
	director.population = [&"runner", &"walker", &"runner", &"brute"]
	director.enabled = false
	add_child(director)

	return DotResult.success(null)


func set_enabled(on: bool) -> void:
	if director != null:
		director.enabled = on

	if not on and spawner != null:
		spawner.clear_all()


func is_enabled() -> bool:
	return director != null and director.enabled


func count() -> int:
	return spawner.world_count() if spawner != null else 0


# --- The tick --------------------------------------------------------------

## One authoritative step, from the game's own tick.
func tick(current_tick: int, delta: float) -> void:
	_tick = current_tick

	if not is_enabled() or game == null:
		return

	# [b]The candidate list and the spawn points are rebuilt before the NPCs run.[/b] Once
	# per tick and not once per NPC, because forty NPCs each building their own list of
	# eight players is three hundred allocations a tick for a list that does not differ
	# between them — and *before* rather than after, because a list built at the end of a
	# tick is a list of where everybody was.
	spawner.set_candidates(_candidates())
	_report_players()
	_learn(delta)

	if director.spawn_points.is_empty():
		_seed_spawn_points()

	spawner.tick(delta)
	squads.prune()
	director.tick(delta)


func _exit_tree() -> void:
	# The last minutes of learning, on the way out. The keeper saves every two minutes; a
	# server stopped between two saves would otherwise lose up to that much.
	if spawner != null:
		heat.save(spawner.now())


## Samples where the players are into this map's heat. Before the spawner thinks, so a
## wave NPC patrols what was learned up to this tick.
func _learn(delta: float) -> void:
	var positions: Array = []

	for id in game.players.keys():
		var player := game.players[id] as PlaygroundPlayer

		if player != null and player.controller != null and player.controller.state != null:
			positions.append(player.controller.state.position)

	var map_id: StringName = game.maps.current.id if game.maps != null and game.maps.current != null else &""
	heat.tick(delta, map_id, positions, spawner.now(), spawner)


## A player fired. Every wave NPC in earshot hears it and knows who. Called by the module
## for every shot the net bridge hands it, whether or not the arena is on: a gun fired in
## the sandbox is still a gun fired.
func note_fire(player_id: StringName, origin: Vector3) -> void:
	if spawner == null:
		return

	sounds.emit(
		DotNpcAiSounds.Kind.COMBAT, origin, GUNFIRE_RADIUS, spawner.now(), 0.5,
		StringName("%s%s" % [PLAYER_PREFIX, player_id])
	)


func _candidates() -> Array:
	var out: Array = []

	for id in game.players.keys():
		var found: Variant = game.players[id]
		var player := found as PlaygroundPlayer

		if player == null or player.controller == null \
				or player.controller.state == null:
			continue

		out.append(DotNpcSenses.Candidate.new(
			StringName("%s%s" % [PLAYER_PREFIX, id]),
			player.controller.state.position,
			&"player",
			# Loudness scaled by speed: somebody sprinting past is harder to miss than
			# somebody standing still building, which is the one thing a sandbox wants
			# hearing for.
			clampf(player.speed() / 12.0, 0.0, 1.0)
		))

	return out


## What the director measures its phases against.
##
## [b]The stress is being chased, and it is expressed as the "health" the director
## understands.[/b] Its own model is damage plus proximity to a threat; a sandbox with the
## arena off has no damage at all, so what is reported is the half that is always true —
## how close the nearest wave NPC is. With the arena on, health is real and is used.
func _report_players() -> void:
	for id in game.players.keys():
		var found: Variant = game.players[id]
		var player := found as PlaygroundPlayer

		if player == null or player.controller == null \
				or player.controller.state == null:
			director.forget_player(StringName("%s%s" % [PLAYER_PREFIX, id]))
			continue

		director.report_player(
			StringName("%s%s" % [PLAYER_PREFIX, id]),
			player.controller.state.position,
			health_fn.call(id) if health_fn.is_valid() else 1.0
		)


## Where a player's health comes from, when there is any.
##
## `func(id: StringName) -> float`, in 0..1. Unset means everybody is at full health, which
## is what a sandbox with the arena off is. [PlaygroundModule] points it at
## [PlaygroundArena] when that is on — and the director then paces against something real
## rather than against proximity alone.
var health_fn: Callable = Callable()


## Somewhere to put them, from the spawn points the map already declares.
##
## [b]Read from the map rather than invented.[/b] `DotSpawnPoint`s are where a mapper said
## a person may appear, which is by construction somewhere reachable and not inside
## anything — and a director inventing its own would be a director putting a brute in a
## wall. When a map has none, a ring around the origin is the fallback, and it says so.
func _seed_spawn_points() -> void:
	var points := PackedVector3Array()

	for node in game.get_tree().get_nodes_in_group(&"spawn_points"):
		if node is Node3D:
			points.append((node as Node3D).global_position)

	if points.is_empty() and game.world != null:
		for step in range(16):
			var angle := TAU * float(step) / 16.0
			points.append(Vector3(cos(angle), 0.0, sin(angle)) * 40.0)

		DotLog.info(CHANNEL, "this map declares no spawn points; using a ring", {
			"points": points.size(),
		})

	director.spawn_points = points


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("waves        %d (%s)" % [count(), "on" if is_enabled() else "off"])

	if director != null and is_enabled():
		out.append_array(director.describe_lines())

	return out
