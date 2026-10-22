extends Node3D

const PlaygroundPaths := preload("playground_paths.gd")
const PlaygroundZee := preload("playground_zee.gd")

const PlaygroundConfig := preload("playground_config.gd")
const PlaygroundEntity := preload("entities/playground_entity.gd")
const PlaygroundInventory := preload("playground_inventory.gd")
const PlaygroundLimits := preload("playground_limits.gd")
const PlaygroundPickup := preload("playground_pickup.gd")
const PlaygroundConstraints := preload("playground_constraints.gd")
const PlaygroundNpcWorld := preload("playground_npc_world.gd")
const PlaygroundProjectiles := preload("playground_projectiles.gd")
const PlaygroundMap := preload("playground_map.gd")
const PlaygroundPlayer := preload("playground_player.gd")
const PlaygroundPlayerStack := preload("playground_player_stack.gd")
const PlaygroundProp := preload("playground_prop.gd")
const PlaygroundSpawnables := preload("playground_spawnables.gd")
const PlaygroundVehicle := preload("playground_vehicle.gd")
const PlaygroundVehicles := preload("playground_vehicles.gd")
const PlaygroundWeaponDef := preload("weapons/playground_weapon_def.gd")
const PlaygroundWorkshop := preload("playground_workshop.gd")
const PlaygroundWeapons := preload("playground_weapons.gd")
const ToolPhysprop := preload("toolgun/tool_physprop.gd")
const PlaygroundMaterials := preload("playground_materials.gd")
const PlaygroundAddons := preload("playground_addons.gd")
const PlaygroundProfiles := preload("playground_profiles.gd")

## The playground: a sandbox on a flat grass plate, with props you can spawn and a
## physics gun to move them with. Any map a server adds plays here too, surf and bunny-hop
## courses among them; a run timer is not shipped, and a server that adds dot-timer gets
## one through `addons/pg_timer` (see [member run_timer]).
##
## [b]This is the only place every addon in the movement half of the family runs
## together[/b] — dot-player-controller, dot-map, dot-props and dot-leaderboard, over
## dot-core — and, by the family's own repeated lesson, the
## seams between them are where the bugs are. Each addon's own suite runs it with the
## others absent; `examples/headless_playground.tscn` is the only thing that runs the
## joins.
##
## [codeblock]
## godot --headless --path . res://examples/headless_playground.tscn
## [/codeblock]
##
## [b]It is a server and a client in one process.[/b] Nothing here is networked yet —
## dot-net's bridge is the next piece, and the shape is deliberately ready for it:
## the prop spawner is authoritative in one place, and the player's own copy of it
## would be non-authoritative.

const CHANNEL := "playground"

## The name this registers itself under, so a dot-server module can find it.
##
## A registry name rather than being handed in, because a module is loaded by PATH —
## [code]server.modules.load_module("res://game/playground_module.gd")[/code] — and a
## path cannot carry an instance.
const SERVICE := &"playground"

## The map changed and everything has been rebuilt against it.
signal map_ready(map: DotMapDef)

## The playground has finished booting: the first map, if any, is up.
##
## [b]Paired with [member booted], and a caller must check that first.[/b]
## [method change_map] may complete without ever suspending — a built-in map is a
## scene already in the build — in which case this has been emitted before the caller
## reaches its `await` and the `await` never returns. That is the family's own
## fan-out trap in its smallest form: a signal is not a state, and code that waits on
## one has to be able to see that it has already happened.
signal ready_for_players()

## A player now exists in [member players]. The net bridge answers this by building the
## entity that replicates them, so a player the GAME made itself — a bot, a test — is
## replicated exactly like one a peer asked for.
signal player_added(id: StringName)

## A player is about to stop existing. Emitted BEFORE the teardown, so a listener can
## still read what they were.
signal player_removed(id: StringName)

## Somebody switched creative mode on or off. See [method set_creative].
signal creative_changed(id: StringName, on: bool)

## A player's physics gun took hold of [param prop] or let go of it. What the net bridge
## tells everybody, so a connected client can draw somebody else's beam.
signal held_changed(id: StringName, prop: DotPropInstance, held: bool)

## A breakable map box (a pane of glass) broke: its index in the map document, where, and
## what it was made of. Emitted on every end that removes it, so a client plays the sound.
signal pane_broken(index: int, at: Vector3, material: StringName)

## A player's shot, blast or blow took something off a body, a breakable prop or a pane: the
## confirmation the shooter's hit marker and damage numbers are drawn from. The authority's
## decision, never a client's prediction; the bridge sends it to the shooter alone. Fed from
## the four places damage is applied ([method confirm_hit]). [param victim] only groups hits
## on one thing ([method hit_victim_id]); [param point] is where the number goes up.
signal hit_landed(player_id: StringName, victim: int, amount: float, point: Vector3, killed: bool, headshot: bool)

## Somebody walked over a weapon lying in the world. The bridge gives it to them on a
## server; the client equips it offline.
signal weapon_picked_up(player_id: StringName, weapon_id: StringName)

## Somebody finished a timed run, [param time] seconds long. [param rank] is 0 when it was
## not filed, and [param reason] then says why. Emitted only by a run timer (see
## [member run_timer]); a game without one never emits it.
##
## A time rather than dot-timer's run object, because this file must compile with the
## timer absent, and a signal naming its class would not.
signal run_filed(player_id: StringName, time: float, rank: int, reason: String)

@export_group("Content")

## Layered configuration. One is created with the defaults if this is left empty.
##
## [b]A config rather than a wall of exports on this node[/b], because a dedicated
## server is configured by somebody who is not opening the editor. See
## [PlaygroundConfig].
@export var config: PlaygroundConfig = null

## A JSON file to layer over [member config]'s defaults, or empty for none.
@export var config_file: String = ""

@export_group("Role")

## Simulation ticks per second.
##
## [b]Read from the engine, not from here, whenever the engine has been told.[/b]
## dot-server writes [member Engine.physics_ticks_per_second] from its own
## [code]sv_tickrate[/code] cvar, so on a real server this ends up being whatever the
## operator put in [code]server.cfg[/code] — see [method _resolve_tick_rate]. The
## export is the fallback for a client or a test with no server to ask.
##
## It is also what every record a run timer files is stamped with, which is what lets a
## disputed time be checked afterwards.
@export_range(1, 240, 1) var tick_rate: int = 128

## Registry scope, so a server game and a client game can share one process — the shape
## every headless netcode test in this family takes.
##
## Without it both halves register under the same name and the second one wins, so a
## component resolving `playground` reaches whichever game happened to boot last. There
## is no error: the lookup succeeds, at the wrong game.
@export var service_scope: StringName = &""

## Whether this instance is the authority: it times, it ranks, it spawns props.
##
## Derived from [member PlaygroundConfig.authoritative] on ready rather than exported
## beside it, so there is one place to set it and no way for the two to disagree. A
## client leaves it false, runs its own copy of everything for its HUD, and files nothing.
var authoritative: bool = true

## What the hooks of the addons folder registered: the Q menu's Addons tab, and where a
## chosen entry runs. Built in [method _ready] after the world exists. See
## [PlaygroundAddons].
var addons: PlaygroundAddons = null

## The NPC and pack-weapon menu derived from profiles, and their live edit. See [PlaygroundProfiles].
var profiles: PlaygroundProfiles = null
## Replaces the profile config roots (tests); empty uses `res://cfg`, `user://cfg` and `--config`.
var profile_roots := PackedStringArray()

## An addon's callback has something every client must be told; the net bridge sends it.
signal addon_message(addon: String, body: Dictionary)

## Whether [signal ready_for_players] has been emitted. See that signal.
var booted: bool = false

var maps: DotMapSession = null

## Whether the map session's own clock running out changes to the rotation's next map.
##
## On for a sandbox with no vote, where that clock is the only thing that ever ends a map.
## Off once [code]PlaygroundModule[/code] has a ballot: the vote's clock ends a map then,
## and both acting was a map the players voted to extend being ended on the old clock, by
## a rotation nobody asked.
var rotation_ends_maps: bool = true

## The clock that ends a map, as [method DotVoteClockView.state_of] describes it. Set by
## [code]PlaygroundModule[/code] to its vote's [code]clock_state[/code]; unset on a sandbox
## with no vote, where the map session's own clock is the one that ends a map.
##
## [b]A Callable rather than the vote, because the game does not know the vote exists[/b]
## — the module builds it, over this game. It is read by [method time_left_text], which is
## what `pg_status` and [method describe] say: both read the map session's clock after the
## vote had taken the map's end over, so an operator was shown a limit an extend had
## already moved, and under the deployed `trigger: rtv_only` with no duration, thirty
## minutes the server did not have.
var clock_fn: Callable = Callable()

## The run timer, or null: the game ships none.
##
## [b]Attached by `addons/pg_timer`'s hook, and only when `addons/dot_timer` is present.[/b]
## A server that wants timed runs adds the dot_timer addon (or a player subscribes to it);
## the hook then builds a `DotTimerManager` and calls [method attach_run_timer]. Untyped and
## called by name, because nothing in the game may name a dot-timer class: every script must
## compile in a checkout without it. What it is called with is the whole interface, and
## every call below is guarded on null.
var run_timer: Object = null
var props: DotPropSpawner = null

## The vehicles. Every one of them is also a [DotPropInstance] in [member props] — see
## [PlaygroundVehicles] for why both, and [PlaygroundSpawnables.Kind.VEHICLE] for the
## one field of `meta` that joins them.
var vehicles: DotVehicleSpawner = null
var boards: DotLeaderboardManager = null

## The scripted spawnables in the world, ticked every simulated tick.
##
## A list beside the spawner's rather than a walk over it every tick: a sandbox with a
## thousand crates and four NPCs would otherwise ask a thousand props whether they are
## an NPC, a hundred and twenty-eight times a second.
var entities: Array[PlaygroundEntity] = []

## What the entities can perceive, shared by all of them.
##
## [b]dot-npc's, rather than "the nearest player" recomputed every tick.[/b] The chaser
## used to ask [method PlaygroundEntity.nearest_player] on every one of the hundred and
## twenty-eight ticks a second this game runs at, which is the classic broken NPC: two
## players standing a metre apart make it turn back and forth for ever, and one who steps
## behind a pillar makes it forget instantly and walk away mid-swing.
## [DotNpcSenses] acquires at one threshold and drops at a weaker one, with a grace
## measured from the last sighting.
##
## One object for the whole world, because its tuning is the world's rather than an
## NPC's: how far a particular thing can see belongs on its catalogue entry, and that is
## where it is.
var npc_senses: DotNpcSenses = null

## How good every NPC is, server-wide: `npc_skill`, `npc_reaction_scale`,
## `npc_reaction_min`, bound by the module.
##
## On the world, because both kinds of NPC here need it and neither owns the other: the
## waves' spawner has it attached, and a sandbox hunter — built by the spawn menu rather
## than by a spawner — asks for it here.
var npc_skill: DotNpcAiSkill = DotNpcAiSkill.new()

## How many props, NPCs, entities, vehicles, balloons, weapons and constraints one player may
## have, and the roles that get more. dot-props asks it through
## [member DotPropSpawner.limit_resolver]; the module binds `pg_max_*` and `pg_limit_roles`.
var spawn_limits: PlaygroundLimits = PlaygroundLimits.new()

## Welds, ropes and no-collides between props. Built by the tool gun.
var constraints: PlaygroundConstraints = null

## Standing on a moving prop carries a player with it (`config.prop_surfing`). dot-props'
## own, under the spawner; each player asks it once a tick after its move
## ([method PlaygroundPlayer._on_simulated]).
var carry: DotPropCarry = null

## dot-props' health and breaking, for `config.destruction`. Built on every machine; only the
## authoritative one hurts anything (see [method hurt_prop]).
var prop_damage: DotPropDamage = null

## Props wired to props (dot-props' DotPropIO): buttons, levers and doors. See `_machines`
## in PlaygroundSpawnables, [method use_prop] and [method _on_io_input].
var io: DotPropIO = null

## How long a door takes to swing, and how far a player reaches to press something.
const DOOR_SECONDS := 0.6
const USE_REACH := 2.6

## Door instance id -> {"open": bool, "t": float 0..1, "base": Transform3D}. `base` is where
## it stood shut, taken when it starts to open from shut, so a door somebody moved first
## swings from where they put it.
var _doors: Dictionary = {}

## Lever instance id -> on.
var _levers: Dictionary = {}

## Debris instance id -> the game time it goes, in seconds.
var _debris_expiry: Dictionary = {}

## Props breaking right now. A barrel's blast reaches the barrel itself, which is still in the
## spawner while it explodes; hurting it again breaks it again, for ever. Cleared at the end of
## the outermost blast, so a chain of barrels still goes up, once each.
var _breaking: Dictionary = {}
var _blast_depth: int = 0

## Who is holding whom with the physics gun. The module binds `pg_pickup*` to it and hands
## it the same roles [member spawn_limits] uses.
var pickup: PlaygroundPickup = PlaygroundPickup.new()

## What an armed NPC's brain asks the world, and where its squads and sounds hang.
var npc_world: PlaygroundNpcWorld = null

## Grenades and rockets in flight. Built on both ends: the authority detonates, a client
## flies what it is told about so it can draw it.
var projectiles: PlaygroundProjectiles = null

## Every armed NPC alive — soldiers and rebels. They are perception candidates for each other.
var armed_npcs: Array = []

## Players and armed NPCs, as candidates. See [method _rebuild_npc_candidates]; the older
## entities perceive [member npc_candidates], players only, and are unchanged.
var npc_candidates_all: Array = []

## What each player wants the NPCs they spawn to carry: a weapon id, `none`, or absent for
## the catalogue's own choice. Set from the Q menu's entities tab.
var npc_weapon_choice: Dictionary = {}

## The squads armed NPCs fight in, and the sounds they hear.
var npc_squads: DotNpcAiSquads = DotNpcAiSquads.new()
var npc_sounds: DotNpcAiSounds = DotNpcAiSounds.new()

## How far a gunshot is heard by an NPC, in metres.
const GUNFIRE_RADIUS := 30.0

## Push on a prop per point of a shot's damage. The same feel as `PlaygroundZee.shove_props`.
const SHOT_IMPULSE := 0.6

## The players as [DotNpcSenses.Candidate]s, rebuilt once per simulated tick.
##
## Once per tick and not once per entity: twenty NPCs each building their own list of
## eight players is a hundred and sixty allocations a tick for one list that does not
## differ between them.
var npc_candidates: Array = []

## What a player may hold. See [PlaygroundWeapons].
var weapons: Array[PlaygroundWeaponDef] = []

## What every player is carrying — prepaid props, a grid and a weight. See
## [PlaygroundInventory], and [PlaygroundInventoryNet] for how it crosses a wire.
##
## [b]The game's, on both ends, and authoritative exactly when the game is.[/b] A server
## holds one bag per person and decides; a client holds its OWN bag and nobody else's, and
## predicts. It was built by nothing until 2026-09-25 — the class existed, its suite
## passed, and no running game had an inventory at all.
var inventory: PlaygroundInventory = null

## The node loaded maps and spawned props are put under.
var world: Node3D = null

## Who is in the session, which side, what class, where they start, and the physics.
##
## [b]Built last and binds to everything else.[/b] It adds no authority: the props are
## still the spawner's and the course is still dot-timer's. What it does is keep one set
## of records in step, so a scoreboard, a spectator seat and a start selector read the
## same thing. See [PlaygroundPlayerStack].
var player_stack: PlaygroundPlayerStack = null

## The players in this instance, by id.
## Every world object this game has an id for. See [DotEntityTable].
##
## [b]Owned by the game and opened on join, NOT by the layer that happens to need an
## id first.[/b] That distinction is the bug this replaced. `PlaygroundArena` kept a
## counter and two dictionaries and only ran when the waves mode was on, so
## `PlaygroundDowns` — which is a separate switch — fell back to
## `abs(String(player_id).hash())` when the arena was off. A player therefore had TWO
## entity ids depending on which layers an operator had enabled, and the file said so
## in a comment: "answering differently in the two is how a player who is down in one
## system is up in the other." A handle whose existence depends on a mode is not a
## handle.
##
## [b]Named `entity_table` and not `entities` because this project got there first[/b]:
## [member Playground.entities] is the sandbox's own list of spawned
## `PlaygroundEntity`s and has been since before dot-entity existed. The other three
## games call theirs `entities`. Renaming the sandbox's list is a much larger change
## than living with two names, and the day those two concepts merge -- a sandbox entity
## IS a world object with an id -- is the day this one takes the name.
var entity_table := DotEntityTable.new()

## What a dead body does, and which death reactions the server allows: dot-player-char's
## `sv_ragdoll*` cvars, bound by the module (REPLICATED) and followed by a client through its
## link, because the client draws the bodies. Decided with by [method PlaygroundArena.decide_death].
var ragdoll_rules: DotPlayerRagdollRules = DotPlayerRagdollRules.new()

## The current map's toys (dot-props' [DotPropToyBox]): balls, barrels, swings, see-saws, a
## roundabout, trampolines, switches. Built from the map's `map_toys()` on both ends in the same
## order, simulated here where [member authoritative] and posed from snapshots on a client
## (PlaygroundToyNet). A child of this node, not of the map: the map's tree is classified onto
## the `world` layer when it is ready, which would take every toy with it. Null before a map.
var toys: DotPropToyBox = null

## dot-props' `sv_toys*` (whether a map's toys are there, how many simulate at once, how hard a
## walk pushes one). Bound by the module (REPLICATED) and followed by a client, which draws them.
var toy_rules: DotPropToyRules = DotPropToyRules.new()

## The map's toys are about to go (a map change), on both ends. What the bridge releases their
## entities on, before the nodes are freed.
signal toys_clearing()

## Pack content ([method follow_workshop]) appeared, went, or was hidden by a session change.
signal workshop_changed()

## The Workshop's adapter, once [method follow_workshop] has been called.
var workshop: PlaygroundWorkshop = null

## The map's toys are built, on both ends. What a client's bridge pairs them on.
signal toys_built()

## dot-player-controller's `mp_forceview` (may a player switch to third person) and
## `mp_solidplayers` (do players block each other). Bound by the module (REPLICATED) and
## followed by a client through its link.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()

var players: Dictionary = {}

## The movement styles, by id: dot-player-controller's own set.
var movement_styles: Dictionary = {}

## The styles' ids in declared order, which is the same on every machine. What a style index
## means on the wire, and what the style key cycles through.
var style_order: Array[StringName] = []

## Simulation ticks run. The tick number every player is stamped with.
var _tick: int = 0

## Frame time not yet spent on a simulation tick.
var _accumulator: float = 0.0

## Whether something else drives the tick — a net bridge, whose tick has to happen
## between dot-net applying inputs and building the snapshot. See [PlaygroundNetBridge].
var external_tick: bool = false


func _ready() -> void:
	if config == null:
		config = PlaygroundConfig.new()

	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)

	# Layered before anything reads it: a file, then the environment, then argv.
	var loaded := config.load_layered(config_file)

	if not loaded.ok:
		DotLog.error(CHANNEL, "the playground configuration is not usable", {
			"why": loaded.error.message
		})

	authoritative = config.authoritative
	tick_rate = _resolve_tick_rate()

	DotLog.info(CHANNEL, "playground starting", {
		"config": config.describe_summary(),
		"tick_rate": tick_rate,
		"authoritative": authoritative,
	})

	DotRegistry.register(DotRegistry.scoped_name(SERVICE, service_scope), self)

	world = Node3D.new()
	world.name = "World"
	add_child(world)

	weapons = PlaygroundWeapons.built_in()
	# zee-dot-weapons after the toys, so the menu's first weapons are still this game's own.
	weapons.append_array(PlaygroundZee.defs())

	_build_styles()
	_build_leaderboards()
	_build_props()
	_build_inventory()
	_build_vehicles()
	_build_npc_senses()
	_build_npc_world()
	_build_maps()
	_build_player_stack()
	_build_addons()

	# A run timer's records keyed the old way are moved aside before the first map. The
	# timer's own business, here only because it has to come before `change_map`.
	if authoritative and run_timer != null:
		await run_timer.call("retire_legacy_records")

	# Physics ticks drive everything. Not _process: a timer sampled per frame counts
	# a different number of ticks on a 144 Hz monitor than on a 60 Hz one, and the
	# player's time then depends on their hardware.
	set_physics_process(true)

	if config.initial_map != &"":
		var started: DotResult = await change_map(config.initial_map)
		DotLog.result(CHANNEL, "loading the first map", started)

	booted = true
	ready_for_players.emit()


## Finds the addons folder's hooks. After the world, so a hook may parent nodes under it.
func _build_addons() -> void:
	addons = PlaygroundAddons.new()
	addons.message.connect(func(addon: String, body: Dictionary) -> void:
		addon_message.emit(addon, body)
	)
	profiles = PlaygroundProfiles.new()
	profiles.setup(profile_roots)
	profiles.apply_npcs(props.catalogue)
	profiles.runtime.profile_changed.connect(_on_profile_changed)
	addons.profiles = profiles
	var count := addons.scan(self, authoritative)
	var providers := addons.scan_providers(self)
	DotLog.info(CHANNEL, "addons folder scanned", {"hooks": count, "providers": providers, "plain": addons.skipped().size()})


## A profile edit landed (here, or from the server): new spawns read the new numbers at once; live
## NPCs of that profile take them through [method PlaygroundEntity.re_apply].
func _on_profile_changed(kind: String, id: String, _revision: int) -> void:
	if kind == DotWeaponProfiles.KIND and addons != null:
		var _n := addons.reapply_weapons(self, id)
		return
	if kind != DotNpcProfiles.KIND or props == null:
		return
	profiles.apply_npcs(props.catalogue, id)
	for entity in entities:
		if is_instance_valid(entity) and entity.def != null and String(entity.def.id) == id:
			entity.re_apply()


## Runs a menu entry an addon registered, as [param player_id] looking at [param at].
func activate_addon_item(
	key: String, player_id: int = 0, at: Vector3 = Vector3.ZERO, who: StringName = &""
) -> DotResult:
	if addons == null:
		return DotResult.fail(DotError.CODE_STATE, "the addons are not built yet")

	if not authoritative:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "only the authority starts an addon item")

	var ctx := PlaygroundAddons.Context.new()
	ctx.authoritative = true
	ctx.world = world
	ctx.player_id = player_id
	ctx.at = at
	ctx.game = self
	ctx.who = who
	return addons.activate(key, ctx)


## Stands up the player-facing addons and binds them to this game.
##
## After the maps, because it reads the start points the map session loads — and a
## stack built before them binds to nothing and reports success.
func _build_player_stack() -> void:
	player_stack = PlaygroundPlayerStack.new()
	player_stack.name = "PlayerStack"
	# A client mirrors the server's physics; re-applying a sandbox profile there would
	# have its props settle on a different schedule from the server's, which in a
	# server-authoritative sandbox is visible as props that snap.
	player_stack.apply_physics = authoritative
	add_child(player_stack)

	var res := player_stack.setup(self)

	if not res.ok:
		DotLog.warn(CHANNEL, "the player stack is off", {"why": res.error.message})
		remove_child(player_stack)
		player_stack.queue_free()
		player_stack = null


## The rate everything counts in.
##
## [b]The engine's, when a server has set it.[/b] The chain is: an operator writes
## `sv_tickrate 128` in `server.cfg`; dot-server's `_apply_tickrate` writes
## `Engine.physics_ticks_per_second`; this reads it; a run timer adopts it; and it lands
## on every record filed. Without that, the rate would be an export
## on a node nobody would think to change, and a server retuned from 64 to 128 would
## go on producing times computed against 64 — twice their real length, on a
## leaderboard shared with servers that got it right, with no error anywhere.
##
## The exported value is the fallback for a client or a test, where the engine's rate
## is a rendering default rather than a decision anybody made.
func _resolve_tick_rate() -> int:
	var engine_rate := Engine.physics_ticks_per_second

	if engine_rate > 0:
		return engine_rate

	return tick_rate


## The simulation loop.
##
## [b]A fixed step accumulated from the frame time, not the frame's own delta.[/b]
## Delta is an input to the movement, so a variable one makes the same play produce
## different results on different machines — and it makes a run's time depend on the
## frame rate, which on a leaderboard is disqualifying. The bound on the budget is
## there so a frame spike does not spend the next frame simulating a hundred ticks and
## make the stall worse.
func _physics_process(delta: float) -> void:
	if external_tick:
		return

	var step := 1.0 / float(maxi(tick_rate, 1))

	_accumulator += delta

	var budget := 8

	while _accumulator >= step and budget > 0:
		_accumulator -= step
		budget -= 1
		_tick += 1
		_simulate_tick(step)

	if _accumulator >= step:
		DotLog.debug(CHANNEL, "tick budget exhausted; dropping simulation time", {
			"dropped": "%.3f s" % _accumulator
		})
		_accumulator = 0.0


## One simulated tick for everything.
##
## The order is the point, and it is the same order a dedicated server uses:
## move every player, then time the tick with the position the move produced. Timing
## first shifts every run by exactly one tick — and by a DIFFERENT amount at each
## tickrate, which is the tickrate dependence a run timer's sub-tick fractions exist to
## remove.
func _simulate_tick(step: float) -> void:
	props.advance(step)
	maps.advance(step)

	# The drivers' intent, then the chassis. Before the players move, because a rider's
	# own move is skipped entirely and what a driver's keys mean this tick is engine
	# force rather than acceleration.
	_drive_vehicles()
	vehicles.tick(step)

	# What the entities can see, rebuilt before any of them thinks about it.
	#
	# Before, not after: a candidate list built at the end of a tick is a list of where
	# everybody was, and a chaser steering at last tick's position lags its target by
	# exactly one tick — which is the thing the ordering below already exists to avoid.
	_rebuild_npc_candidates()

	if npc_world != null:
		npc_world.advance(step)

	# Entities before players, for the same reason the timer runs after them: an NPC
	# that moved after the player was moved would be a tick behind everything that
	# collided with it, and a chaser would visibly lag its target at exactly the rate
	# the server ticks.
	#
	# Iterated over a copy because an entity may remove itself — walking into a pit,
	# or being cleaned up by a script — and `_on_prop_removed` erases from this list.
	for entity in entities.duplicate():
		if is_instance_valid(entity):
			entity.entity_tick(step)

	for id in players:
		var body := players[id] as PlaygroundPlayer
		# A body the client's load gate froze (`process_mode` DISABLED) waits for the level
		# and the camera; simulating it anyway is how it fell through a map not yet built.
		if body.is_inside_tree() and not body.can_process():
			continue
		body.simulate(_tick, step)

	# The toys after everybody moved: a walk into a ball pushes it, weight tips a see-saw.
	_advance_toys(step)

	# Held players after every holder has moved and aimed, so the beam ends where the
	# holder is looking THIS tick, and before the timers, which read where they were put.
	pickup.tick(players, step)

	# After everybody has moved, so a grenade is swept against the world as the tick
	# leaves it, which is also where anybody it could hit now is.
	if projectiles != null:
		projectiles.tick(step)

	_expire_debris()
	_swing_doors(step)
	_liquid_tick(step)
	_pane_impacts()

	# After the moves and before the timers, which is the same ordering rule: a rider's
	# position for this tick is where the vehicle carried them, not where they were.
	_carry_riders()

	# And the locomotion state, from the movement that has just happened. Same rule
	# again: a state machine fed the position a player WAS at is one tick behind them,
	# and at a walk-to-run threshold that is a visible late change of animation.
	for id in players:
		(players[id] as PlaygroundPlayer).drive_character(step)

	# The run timer last, with the positions every move above produced.
	if run_timer != null:
		run_timer.call("tick", _tick)


## One authoritative tick driven from outside, at a tick number the driver chose.
##
## The net bridge calls this instead of letting [method _physics_process] run, because
## the game's tick has to happen between dot-net applying the inputs that arrived and
## building the snapshot that goes back out. A game still running its own loop would
## simulate somewhere between those two and send state from the wrong instant.
func tick_once(tick: int) -> void:
	_tick = tick
	_simulate_tick(1.0 / float(maxi(tick_rate, 1)))

	if player_stack != null:
		player_stack.tick(tick)


## The client's half of a tick: what it was told is in the air, and the run timer.
##
## What a CLIENT runs. A client may not simulate props — rigid bodies are not
## reproducible across machines, which is the whole reason this sandbox is
## server-authoritative — and it may not simulate remote players, which are
## interpolated from snapshots. Its own player is simulated by the predictor through
## [PlaygroundPlayerNet]. What is left is the projectiles it was told about, and feeding a
## run timer the position it can see, so a local run reads a tick earlier than any packet
## could deliver it.
func tick_timers_only(tick: int) -> void:
	_tick = tick

	# What this client was told is in the air. It decides nothing; see PlaygroundProjectiles.
	if projectiles != null:
		projectiles.tick(1.0 / float(maxi(tick_rate, 1)))

	if run_timer != null:
		run_timer.call("tick", _tick)


## Puts the whole game on a tick rate decided elsewhere — a server's `sv_tickrate`,
## reaching a client through HELLO.
##
## [b]Every player's controller moves with it, not just the loop.[/b] A controller
## keeps its own rate to size a step, so changing the game's and leaving theirs runs
## the simulation at one rate and the movement at another — and the symptom is a
## player who is correct on their own screen and wrong everywhere else.
## The tick this game is on.
##
## The same accessor `ArenaGame` and `G2GGame` both have, and this project did without
## because every layer it had was handed the tick as an argument. A layer that is ticked
## from the module rather than from `_simulate_tick` has no such argument, and reaching
## for `_tick` from outside would be reaching past the underscore.
func current_tick() -> int:
	return _tick


func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	# The run timer is told, because two copies of this number that disagree is the
	# failure the whole method exists to prevent.
	if run_timer != null:
		run_timer.call("set_tick_rate", rate)

	for id in players:
		(players[id] as PlaygroundPlayer).tick_rate = tick_rate

	DotLog.info(CHANNEL, "tick rate adopted", {"tick_rate": tick_rate})
	return true


# --- Building --------------------------------------------------------------

func _build_styles() -> void:
	for style in DotFpsStyle.defaults():
		movement_styles[style.id] = style
		style_order.append(style.id)


func _build_leaderboards() -> void:
	boards = DotLeaderboardManager.new()
	boards.name = "Leaderboards"
	boards.store = DotLeaderboardStoreMemory.new()
	# Off by default: publishing sends player names and times off the server, and
	# that is an operator's decision rather than a default.
	boards.report_to_backbone = config.report_to_backbone
	add_child(boards)

	# No boards are defined here: the game ranks nothing by itself. A run timer defines its
	# own (`fastest`, `top_speed`, `points`) when a server adds one.


func _build_props() -> void:
	props = DotPropSpawner.new()
	props.name = "Props"
	props.authoritative = authoritative and config.allow_props
	props.catalogue = _prop_catalogue()

	var limits := DotPropLimits.new()
	limits.per_player_budget = config.prop_budget
	limits.world_budget = config.prop_world_budget
	limits.spawn_interval = config.prop_spawn_interval
	props.limits = limits

	# A count per kind, beside the cost budget, with per-role overrides. See
	# PlaygroundLimits; the server module binds the `pg_max_*` cvars and the roles.
	spawn_limits.apply_to(limits)
	props.limit_resolver = spawn_limits.resolve

	props.world_ref = DotNodeRef.of_path(^"../World")

	# Every prop this build ships is the same scene, and what makes a plank a plank
	# rather than a crate is three fields of its definition. dot-props deliberately
	# does not know that: it instantiates a scene and places it, because a server
	# with real content has a scene per prop and nothing to configure.
	props.spawned.connect(_on_prop_spawned)
	props.removed.connect(_on_prop_removed)

	add_child(props)

	carry = DotPropCarry.new()
	carry.name = "PropCarry"
	props.add_child(carry)

	io = DotPropIO.new()
	io.name = "PropIO"
	io.authoritative = authoritative
	props.add_child(io)
	io.input_received.connect(_on_io_input)

	prop_damage = DotPropDamage.new()
	prop_damage.name = "PropDamage"
	prop_damage.authoritative = authoritative
	props.add_child(prop_damage)
	prop_damage.broken.connect(_on_prop_broken)
	prop_damage.exploded.connect(_on_prop_exploded)


## After the props, because the item catalogue is derived from the prop catalogue — one
## list, so a prop somebody adds can be carried without anybody remembering to say so.
func _build_inventory() -> void:
	inventory = PlaygroundInventory.new()
	inventory.name = "Inventory"
	inventory.authoritative = authoritative
	add_child(inventory)

	var res := inventory.setup(props.catalogue, service_scope)

	if not res.ok:
		DotLog.warn(CHANNEL, "the inventory is off", {"why": res.error.message})
		remove_child(inventory)
		inventory.queue_free()
		inventory = null


## Builds a spawned prop's body from the definition it came from.
##
## Connected rather than done inside a subclass of [DotPropSpawner], because what a
## prop's scene needs is the game's business and overriding the spawner would mean
## re-implementing the budget, the cooldown and the undo stack to get at one line.
func _on_prop_spawned(prop: DotPropInstance) -> void:
	_classify_spawned(prop)

	match PlaygroundSpawnables.kind_of(prop.def):
		PlaygroundSpawnables.Kind.ENTITY:
			_configure_entity(prop)
			return
		PlaygroundSpawnables.Kind.VEHICLE:
			_configure_vehicle(prop)
			return
		_:
			pass

	var body := prop.node as PlaygroundProp

	if body == null:
		# A delivered prop with its own scene. Nothing to do — and not a warning,
		# because that is the shape a real server's catalogue has.
		return

	body.configure(prop.def)

	# A door stands frozen where it was put, and the server swings it (see `_swing_doors`).
	if bool(prop.def.meta.get("door", false)) and authoritative:
		DotPhysGun.set_frozen(prop, true)
		reclassify_prop(prop.node, true, false)
		_doors[prop.instance_id] = {"open": false, "t": 0.0, "base": (prop.node as Node3D).global_transform}


## The current map's swimmable liquids (water, slime), as the boxes a player's swim mode is
## given. Lava is not here: a person does not swim in it.
func water_boxes() -> Array[AABB]:
	var out: Array[AABB] = []
	for liquid: Dictionary in liquids:
		if PlaygroundMaterials.is_swimmable(String(liquid["material"])):
			out.append(liquid["box"] as AABB)
	return out


## What the liquids do, on the authority: lava burns a player (through [member hazard_hurt],
## or back to the spawn) and melts a prop that stays in it. Water's own behaviour, floating
## and swimming, is not here.
func _liquid_tick(step: float) -> void:
	if not authoritative or liquids.is_empty():
		return

	_float_props(step)

	var burning: Array = []
	for liquid: Dictionary in liquids:
		var s := PlaygroundMaterials.surface(String(liquid["material"]))
		if s != null and s.hazard_damage > 0.0:
			burning.append([liquid["box"] as AABB, s.hazard_damage])
	if burning.is_empty():
		return

	for id: StringName in players.keys():
		var player: PlaygroundPlayer = players[id]
		if player == null or player.riding:
			continue
		var feet := player.controller.state.position + Vector3.UP * 0.1
		for each: Array in burning:
			if not (each[0] as AABB).has_point(feet):
				continue
			var hurt := hazard_hurt.is_valid() and bool(hazard_hurt.call(id, float(each[1]) * step))
			if not hurt:
				spawn_player(id)
			break

	# Once a prop has touched lava it is burning, and goes MELT_SECONDS later whether or not it
	# bounced clear in between: a timer reset by every bounce let a light crate ride a lava lake.
	var still: Dictionary = {}
	for prop: DotPropInstance in props.all_props():
		var node := prop.node as Node3D
		if node == null or not prop.is_alive():
			continue
		if _melting.has(prop.instance_id):
			still[prop.instance_id] = float(_melting[prop.instance_id]) + step
			continue
		# Its underside in the lava, not its centre: a crate floats on lava (it is denser than
		# wood), and a centre test let a floating crate ride a lava lake for ever.
		# A light one floats in it by millimetres, so the bottom is asked of the lava grown a
		# little: resting on the surface is touching it.
		var underside := node.global_position - Vector3.UP * _half_height_of(prop)
		for each: Array in burning:
			if (each[0] as AABB).grow(0.1).has_point(underside):
				still[prop.instance_id] = float(_melting.get(prop.instance_id, 0.0)) + step
				break
	_melting = still
	for instance_id: int in still.keys():
		if float(still[instance_id]) >= MELT_SECONDS:
			_melting.erase(instance_id)
			var _gone := props.remove(instance_id, DotPropSpawner.REASON_CLEANUP)


# --- Breakable map boxes: glass ----------------------------------------------------

## Map box index -> `{node: StaticBody3D, health: float, material: StringName}` for every box
## whose material breaks (dot-physics' `break_health`: glass). Rebuilt per map.
var panes: Dictionary = {}

## Indices of the panes broken on this map, in order. What a joiner is told.
var broken_panes: Array[int] = []

## Whether breakable boxes break at all (`pg_breakable_glass`, on). Independent of
## `destruction`, which is about props: glass in a map is there to be broken.
var panes_break: bool = true

## Speed above which a prop or a player going into a pane breaks it, in m/s.
const PANE_IMPACT_SPEED := 6.0

## How many shards a broken pane throws, per square metre, and the most it ever throws.
const SHARDS_PER_M2 := 0.6
const SHARDS_MAX := 10

## Speeds as the last tick left them, by player id and prop instance id: what a body was
## doing BEFORE the contact that stopped it, which is the speed it hit the pane at.
var _last_speed: Dictionary = {}


func _index_panes(map: Node) -> void:
	panes.clear()
	broken_panes.clear()
	_last_speed.clear()
	if map == null:
		return
	var stack: Array[Node] = [map]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if not (n is StaticBody3D) or not n.has_meta(&"pg_box"):
			continue
		var material := PlaygroundMaterials.material_of(n)
		var s := PlaygroundMaterials.surface(String(material)) if material != &"" else null
		if s != null and s.break_health > 0.0:
			panes[int(n.get_meta(&"pg_box"))] = {"node": n, "health": s.break_health, "material": material}


## Damage to [param node] if it is a breakable map box; true when it was one. The one door
## shots, blasts and impacts all come through, as `hurt_prop` is for props.
func hurt_pane(node: Node, amount: float, by: StringName) -> bool:
	if not authoritative or not panes_break or node == null or not node.has_meta(&"pg_box"):
		return false
	var index := int(node.get_meta(&"pg_box"))
	if not panes.has(index):
		return false
	var pane: Dictionary = panes[index]
	var before := float(pane["health"])
	pane["health"] = before - amount
	var at := _pane_bounds(node).get_center() if node is Node3D else Vector3.ZERO
	var broke := float(pane["health"]) <= 0.0
	if broke:
		break_pane(index)
	confirm_hit(by, hit_victim_id(DotEntity.KIND_OTHER, index + 1), minf(amount, maxf(before, 0.0)), at, broke)
	return true


## A blast hurts every pane within [param radius] of [param at], less with distance.
func hurt_panes_in(at: Vector3, radius: float, amount: float, by: StringName) -> void:
	if radius <= 0.0:
		return
	for index: int in panes.keys():
		var node := (panes[index] as Dictionary)["node"] as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var distance := _pane_bounds(node).get_center().distance_to(at)
		distance = maxf(0.0, distance - _pane_bounds(node).size.length() * 0.5)
		if distance < radius:
			var _hit := hurt_pane(node, amount * clampf(1.0 - distance / radius, 0.0, 1.0), by)


## Breaks pane [param index] on this end: the box goes, and on the authority shards fly.
## A client calls it from the server's event and gets the same removal and the sound.
func break_pane(index: int) -> void:
	if not panes.has(index):
		return
	var pane: Dictionary = panes[index]
	panes.erase(index)
	broken_panes.append(index)
	var node := pane["node"] as Node3D
	var bounds := _pane_bounds(node) if node != null and is_instance_valid(node) else AABB()
	var material: StringName = pane["material"]
	if node != null and is_instance_valid(node):
		node.queue_free()
	if authoritative:
		_throw_shards(bounds, material)
	pane_broken.emit(index, bounds.get_center(), material)


## The world AABB of a map box, from its own collision shape.
static func _pane_bounds(node: Node3D) -> AABB:
	for child in node.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is BoxShape3D:
			var size := ((child as CollisionShape3D).shape as BoxShape3D).size
			return node.global_transform * AABB(-size * 0.5, size)
	return AABB(node.global_position, Vector3.ZERO)


## Debris in the pane's colour, flung outward, gone in `debris_seconds` like a broken prop's.
func _throw_shards(bounds: AABB, material: StringName) -> void:
	if props == null or config == null:
		return
	var faces := [bounds.size.x * bounds.size.y, bounds.size.x * bounds.size.z, bounds.size.y * bounds.size.z]
	faces.sort()
	var count := clampi(int(ceil(float(faces[2]) * SHARDS_PER_M2)), 3, SHARDS_MAX)
	var colour := PlaygroundMaterials.look(String(material), Color.WHITE)
	colour.a = 1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(bounds.get_center())
	var interval := props.limits.spawn_interval if props.limits != null else 0.0
	if props.limits != null:
		props.limits.spawn_interval = 0.0
	for i in count:
		var at := bounds.position + Vector3(rng.randf(), rng.randf(), rng.randf()) * bounds.size
		var piece := props.spawn(&"debris", &"", at)
		if piece == null:
			break
		if piece.node is PlaygroundProp:
			(piece.node as PlaygroundProp).set_tint(colour)
		if piece.node is RigidBody3D:
			var out := (at - bounds.get_center())
			out.y = absf(out.y)
			(piece.node as RigidBody3D).linear_velocity = out.normalized() * rng.randf_range(2.0, 5.0) + Vector3.UP * 1.5
		_debris_expiry[piece.instance_id] = _clock_seconds() + config.debris_seconds
	if props.limits != null:
		props.limits.spawn_interval = interval


## Fast things breaking panes: a prop thrown into one, a player running into one. Read off the
## velocity each had at the end of the LAST tick, because the contact has already stopped
## them, and only its part along the pane's normal: running ALONG a greenhouse wall at full
## speed is not running into it.
func _pane_impacts() -> void:
	if not authoritative or not panes_break or panes.is_empty():
		_last_speed.clear()
		return
	var hits: Array = []
	for index: int in panes.keys():
		var node := (panes[index] as Dictionary)["node"] as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var bounds := _pane_bounds(node)
		var normal := _pane_normal(node)
		for prop: DotPropInstance in props.all_props():
			var body := prop.node as RigidBody3D
			if body == null or not body.is_inside_tree():
				continue
			var was: Vector3 = _last_speed.get(prop.instance_id, Vector3.ZERO)
			var into := absf(was.dot(normal))
			if into > PANE_IMPACT_SPEED and bounds.grow(0.5 + _reach_of(body)).has_point(body.global_position):
				hits.append([node, body.mass * into * 0.5])
		for id: StringName in players.keys():
			var player: PlaygroundPlayer = players[id]
			var was: Vector3 = _last_speed.get(id, Vector3.ZERO)
			# The chest for a wall, the feet for a floor: a player landing on thin ice has their
			# chest a metre above it, and the first version asked only the chest.
			var feet := player.controller.state.position + Vector3.UP * 0.1
			var near := bounds.grow(0.7)
			if absf(was.dot(normal)) > PANE_IMPACT_SPEED and (near.has_point(feet + Vector3.UP * 0.8) or near.has_point(feet)):
				hits.append([node, (panes[index] as Dictionary)["health"]])
	for hit: Array in hits:
		var _broke := hurt_pane(hit[0], float(hit[1]), &"")
	_last_speed.clear()
	for prop: DotPropInstance in props.all_props():
		if prop.node is RigidBody3D:
			_last_speed[prop.instance_id] = (prop.node as RigidBody3D).linear_velocity
	for id: StringName in players.keys():
		_last_speed[id] = (players[id] as PlaygroundPlayer).controller.state.velocity


## A pane's normal: its box's thinnest axis, in the world.
static func _pane_normal(node: Node3D) -> Vector3:
	for child in node.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is BoxShape3D:
			var size := ((child as CollisionShape3D).shape as BoxShape3D).size
			var axis := 0 if size.x <= size.y and size.x <= size.z else (1 if size.y <= size.z else 2)
			return node.global_basis[axis].normalized()
	return Vector3.UP


static func _reach_of(body: Node3D) -> float:
	for child in body.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			return (child as CollisionShape3D).shape.get_debug_mesh().get_aabb().size.length() * 0.5
	return 0.5


## The fastest a prop rises through a liquid under its own buoyancy, m/s. See
## [method _float_props].
const RISE_SPEED := 2.0


## Buoyancy and drag on every loose prop in a liquid, on the authority (props are not
## predicted). A body lighter than the liquid for its volume floats, sitting as deep as its
## density says; a heavier one sinks, slowed. Its density is the catalogue's `density` when
## the definition gives one (rock, concrete: the catalogue's masses are tuned for a physics
## gun, and a 900 kg, 3 m boulder works out lighter than water) and its mass over its volume
## otherwise.
func _float_props(step: float) -> void:
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	for prop: DotPropInstance in props.all_props():
		var body := prop.node as RigidBody3D
		if body == null or body.freeze or not body.is_inside_tree() or prop.held_by != &"":
			continue
		var at := body.global_position
		for liquid: Dictionary in liquids:
			var box: AABB = liquid["box"]
			if not box.grow(2.0).has_point(at):
				continue
			var s := PlaygroundMaterials.surface(String(liquid["material"]))
			if s == null:
				continue
			var volume := _volume_of(prop)
			var half := _half_height_of(prop)
			var submerged := clampf((box.end.y - (at.y - half)) / maxf(half * 2.0, 0.01), 0.0, 1.0)
			if submerged <= 0.0 or at.x < box.position.x or at.x > box.end.x or at.z < box.position.z or at.z > box.end.z:
				continue
			var density := float(prop.def.meta.get("density", body.mass / maxf(volume, 0.001))) if prop.def != null else body.mass / maxf(volume, 0.001)
			# Up by the liquid's weight displaced; the engine already pulls down by the body's.
			var lift := s.density * volume * submerged * gravity
			# A dense body is heavier than its mass says: pull the difference down too, so a
			# boulder whose catalogue mass makes it a balloon still sinks like rock.
			var extra := maxf(density * volume - body.mass, 0.0) * gravity * submerged
			# Drag, never more than the velocity it is taking off.
			var drag := clampf(s.dampening * submerged * step, 0.0, 1.0)
			# And the bob damped critically. Buoyancy is a spring whose stiffness is the
			# liquid's density over the body's: a crate the catalogue makes fifty times lighter
			# than water is a very stiff one, and the first version shot crates a metre out of
			# the pond and let them bounce for ever. Damping at 2 sqrt(k) settles it in a bob.
			var ratio := clampf(s.density / maxf(density, 1.0), 0.0, 60.0)
			var critical := 2.0 * sqrt(gravity * ratio / maxf(half * 2.0, 0.1))
			# Whenever it touches, not scaled by how deep: a body that floats rides almost
			# entirely out of the liquid, and damping scaled by that depth let a crate bounce on
			# lava half a metre high indefinitely.
			var settle := clampf(critical * step, 0.0, 1.0)
			# The vertical velocity is worked out once, here, and set with one impulse. Applied
			# as separate impulses the damping read the velocity BEFORE the lift landed, so a
			# beach ball held at the bottom of a pool gained the whole of a sixty-g lift every
			# tick, kept it, and left the surface at tens of metres a second (the harbour's
			# balls reached y 2081). Under water a body rises at most at [constant RISE_SPEED]:
			# drag sets a terminal speed in a real liquid, and this is that.
			var vy := body.linear_velocity.y
			var rise := (lift - extra) * step / maxf(body.mass, 0.001)
			var vy_after := minf(vy * (1.0 - drag) * (1.0 - settle) + rise, maxf(vy, RISE_SPEED))
			body.apply_central_impulse(Vector3.UP * (vy_after - vy) * body.mass)
			var flat := Vector3(body.linear_velocity.x, 0.0, body.linear_velocity.z)
			body.apply_central_impulse(-flat * body.mass * drag)
			body.angular_velocity *= 1.0 - drag
			break


static func _volume_of(prop: DotPropInstance) -> float:
	if prop.def == null:
		return 1.0
	var e := PlaygroundProp.extent_of(prop.def)
	var scale := float(prop.node.get("size_scale")) if prop.node != null and prop.node.get("size_scale") != null else 1.0
	var box := e.x * e.y * e.z * pow(scale, 3.0)
	match PlaygroundProp.shape_of(prop.def):
		PlaygroundProp.Shape.SPHERE:
			return box * PI / 6.0
		PlaygroundProp.Shape.CYLINDER:
			return box * PI / 4.0
	return box


static func _half_height_of(prop: DotPropInstance) -> float:
	if prop.def == null:
		return 0.5
	var scale := float(prop.node.get("size_scale")) if prop.node != null and prop.node.get("size_scale") != null else 1.0
	return PlaygroundProp.extent_of(prop.def).y * 0.5 * scale


## Who a map's own props belong to. Not a player id (one is `u<n>`), so no player's limits,
## undo or "remove mine" reach them, and the map change that clears every prop clears them.
const MAP_OWNER := &"map"


## Puts down a map document's props and wires them (`maps/pg_data.gd`). An id this server's
## catalogue lacks is skipped with a WARN rather than refusing the map: a map is boxes first,
## and a missing barrel is not a reason to have no floor. Returns how many were placed.
func spawn_map_props(entries: Array, wires: Array) -> int:
	if props == null or entries.is_empty():
		return 0

	# The spawn rate limit is for players clicking; a map's props arrive in one frame.
	var interval := props.limits.spawn_interval if props.limits != null else 0.0
	if props.limits != null:
		props.limits.spawn_interval = 0.0

	var placed: Array = []
	var missing: PackedStringArray = []

	for entry: Dictionary in entries:
		var at: Array = entry.get("at", [0, 0, 0])
		var where := Vector3(float(at[0]), float(at[1]), float(at[2]))
		var prop := props.spawn(StringName(str(entry.get("id", ""))), MAP_OWNER, where)
		placed.append(prop)

		if prop == null:
			missing.append(str(entry.get("id", "")))
			continue

		var node := prop.node as Node3D
		node.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(float(entry.get("yaw", 0.0)))), where)

		if node.has_method("set_size_scale") and entry.has("scale"):
			var _s: float = node.call("set_size_scale", float(entry["scale"]))
		if node.has_method("set_tint") and Color.html_is_valid(str(entry.get("tint", ""))):
			node.call("set_tint", Color.html(str(entry["tint"])))
		if entry.get("physics") is Dictionary and node is RigidBody3D and node.has_method("refresh_mass"):
			var physics: Dictionary = entry["physics"]
			ToolPhysprop._apply(node as RigidBody3D, bool(physics.get("gravity", true)),
				clampf(float(physics.get("weight", 1.0)), 0.1, 10.0),
				clampf(float(physics.get("friction", 1.0)), 0.0, 2.0),
				clampf(float(physics.get("bounce", 0.0)), 0.0, 1.0))

		if bool(entry.get("frozen", true)):
			DotPhysGun.set_frozen(prop, true)
			reclassify_prop(node, true, false)
		elif node is RigidBody3D:
			DotPhysGun.set_frozen(prop, false)
			reclassify_prop(node, false, false)

		# A door keeps its shut transform from where the map put it, not from the spawn point.
		if _doors.has(prop.instance_id):
			(_doors[prop.instance_id] as Dictionary)["base"] = node.global_transform

	if props.limits != null:
		props.limits.spawn_interval = interval

	for wire: Dictionary in wires:
		var from: DotPropInstance = placed[int(wire["from"])]
		var to: DotPropInstance = placed[int(wire["to"])]
		if from != null and to != null and io != null:
			var _linked := io.link(from.instance_id, StringName(str(wire["out"])), to.instance_id, StringName(str(wire["in"])))

	if not missing.is_empty():
		DotLog.warn(CHANNEL, "a map named props this server does not have; left them out",
			{"missing": ", ".join(missing)})

	return placed.filter(func(p: Variant) -> bool: return p != null).size()


## Puts a spawned body on the layer that matches what it is.
##
## [b]`sandbox_3d` is the one preset with `held_prop` and `frozen_prop` in it, and this is
## why they exist.[/b] A prop being carried by the physics gun must not collide with the
## player carrying it — otherwise it shoves them backwards down a corridor — and a frozen
## prop is scenery that everything should be solid against. They are different rows in the
## layout rather than different code, which is the whole argument for having one.
##
## Everything arrived on Godot's default layer 1 masking layer 1 before this, so two
## crates dropped in the same place fell through one another and an NPC was indis-
## tinguishable from the floor as far as collision was concerned.
##
## [b]Spawn time only, and that is a real limitation.[/b] dot-props emits `spawned`,
## `removed` and `refused` and has no signal for freezing or grabbing, so a prop frozen
## later keeps the layer it spawned with. `PlaygroundProp` calls `reclassify` when it
## changes state, which is the half this can reach.
func _classify_spawned(prop: DotPropInstance) -> void:
	if player_stack == null or prop.node == null:
		return

	var _put := player_stack.classify(prop.node, layer_for(prop.def, prop.frozen))


## The collision layer a spawned body of [param def] belongs on.
##
## One answer for both ends: the server's spawn and a client's mirror of it
## (`PlaygroundNetBridge._apply_prop`) read this, because a mirror on a different layer
## is a client whose own predicted player collides with a different world from the one
## the server moves it through.
static func layer_for(def: DotPropDef, frozen: bool) -> StringName:
	match PlaygroundSpawnables.kind_of(def):
		PlaygroundSpawnables.Kind.ENTITY:
			return &"npc"
		PlaygroundSpawnables.Kind.VEHICLE:
			return &"vehicle"
		_:
			return &"frozen_prop" if frozen else &"prop"


## Re-reads a prop's layer after it was frozen, unfrozen, grabbed or dropped.
##
## Public because the states change long after the spawn and dot-props has no signal for
## any of them — so the code that changes the state is the code that has to say so.
func reclassify_prop(node: Node, frozen: bool, held: bool) -> void:
	if player_stack == null or node == null:
		return

	var layer := &"prop"

	if held:
		layer = &"held_prop"
	elif frozen:
		layer = &"frozen_prop"

	var _put := player_stack.classify(node, layer)


## Turns a spawned body into a scripted entity, by attaching the script its definition
## names.
##
## [b]This is the whole "an entity has a script" mechanism, and it is four lines.[/b]
## The scene is a bare [RigidBody3D]; the script comes from `meta`, is loaded by PATH
## because a mounted dot-cloud pack's `class_name` globals are not registered in the
## host, and is attached here. [method Node._ready] has already run by this point —
## the spawner adds the body to the world before it emits — so nothing in an entity
## may rely on `_ready`, which is why the base has `_entity_ready` instead.
##
## A failure removes the prop rather than leaving it. A body with no script sits there
## being a crate, which is indistinguishable from an NPC with nothing to do — and "the
## NPC does not move" sends the next person to the movement code.
func _configure_entity(prop: DotPropInstance) -> void:
	var script := PlaygroundSpawnables.load_script(prop.def)

	if script == null:
		props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)
		return

	var body := prop.node as RigidBody3D

	if body == null:
		DotLog.error(CHANNEL, "an entity's scene is not a RigidBody3D", {
			"entity": String(prop.def.id), "scene": prop.def.scene_path
		})
		props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)
		return

	body.set_script(script)

	# Checked after attaching rather than assumed. A script that is valid GDScript but
	# extends the wrong thing attaches perfectly and then has none of the methods the
	# tick calls — and the first symptom is a crash inside the simulation loop, a long
	# way from the catalogue entry that caused it.
	var entity := body as PlaygroundEntity

	if entity == null:
		DotLog.error(CHANNEL, "an entity's script is not an entity", {
			"entity": String(prop.def.id),
			"script": PlaygroundSpawnables.script_of(prop.def),
			"hint": "extend res://game/entities/playground_entity.gd",
		})
		props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)
		return

	entity.configure(prop.def)
	entity.bind(self, prop)

	entities.append(entity)


## The vehicle spawner, and the handover it drives.
##
## [b]It spawns nothing.[/b] Every vehicle in this game arrives through
## [DotPropSpawner] and is handed over with [method DotVehicleSpawner.adopt], because a
## vehicle here is a prop first — budgeted, undoable, and punt-able by a gravity gun. Its
## own budget is left generous for that reason: the number that actually limits vehicles
## is the prop budget, and a second limit that bites first would be a refusal an operator
## editing `pg_prop_budget` could not explain.
func _build_vehicles() -> void:
	vehicles = DotVehicleSpawner.new()
	vehicles.name = "Vehicles"
	vehicles.authoritative = authoritative and config.allow_props
	vehicles.catalogue = PlaygroundVehicles.catalogue()
	vehicles.world_ref = DotNodeRef.of_path(^"../World")
	vehicles.world_budget = 0
	vehicles.per_player_budget = 0
	vehicles.spawn_interval = 0.0

	# The rider node IS carried: a PlaygroundPlayer is a Node3D with the camera under it
	# on a client, so parenting it into the seat is what puts a rider's view on the
	# vehicle without a single line about cameras in this file. The controller state is
	# pulled back off the node each tick — see [method _carry_riders].
	vehicles.ride.carry_rider_nodes = true

	# Layer 1 is the world's, which is what a playground map builds its geometry on and
	# what the movement collides against. Checked rather than left at the addon's default
	# of 1 by luck: an exit sweep against the wrong mask finds nothing, always succeeds,
	# and puts players through walls — the one failure this whole sweep exists to stop.
	vehicles.ride.exit_mask = 1

	vehicles.ride.on_seated = _on_seated
	vehicles.ride.on_unseated = _on_unseated

	add_child(vehicles)


## Makes a spawned prop a vehicle as well.
##
## [b]Configured before adopted, and the order is load-bearing.[/b] [DotVehicleWheeled]
## walks the body's direct children for wheels once, when the chassis binds, and caches
## what it finds — so a car whose wheels are built after the adoption has four wheels
## that nothing drives, steers or brakes, with every number in its tunables correct.
func _configure_vehicle(prop: DotPropInstance) -> void:
	var body := prop.node as PlaygroundVehicle

	if body == null:
		# A delivered vehicle with its own scene, exactly as a delivered prop is. Its
		# scene is its own business; all this game needs is a Node3D to adopt.
		var plain := prop.node as Node3D

		if plain == null:
			DotLog.error(CHANNEL, "a vehicle's scene is not a Node3D", {
				"vehicle": String(prop.def.id), "scene": prop.def.scene_path
			})
			props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)
			return
	else:
		body.configure(prop.def)

	var vehicle_id := PlaygroundVehicles.vehicle_id_of(prop.def)
	var vehicle := vehicles.adopt(prop.node as Node3D, vehicle_id, prop.owner_id)

	if vehicle == null:
		# Loud, and the prop goes with it. A body that is a vehicle in the catalogue and
		# not one in the world is a car that will not drive, sitting there being a crate
		# — which sends the next person to the handling code.
		DotLog.error(CHANNEL, "a vehicle would not be adopted", {
			"prop": String(prop.def.id), "vehicle": String(vehicle_id)
		})
		props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)
		return

	if body != null:
		body.vehicle_def = vehicle.def


## Whoever is in a vehicle stops being a player who walks.
##
## [b]The controller is turned OFF, not ignored.[/b] A controller still simulating a
## player parented into a moving vehicle writes its own answer into the state every tick
## and the two fight: the movement pushes the body one way, the vehicle carries the node
## the other, and the result reads as the vehicle shaking itself apart. [method
## PlaygroundPlayer.set_riding] is the switch; [method _carry_riders] is what keeps the
## replicated state honest while it is off.
func _on_seated(
	rider_id: StringName, vehicle: DotVehicleInstance, seat: DotVehicleSeat
) -> void:
	var player: PlaygroundPlayer = players.get(rider_id)

	if player == null:
		return

	# Out of anybody's hands, and out of theirs, before the seat takes them: a seat and a
	# beam both own a rider's position, and the seat is the one that was asked for.
	pickup.forget(players, rider_id)

	player.set_riding(true, vehicle.node as Node3D)

	# A run timer decides what getting in means for a run (it ends one on foot and keeps
	# one on a driving track; see `PlaygroundMap.track_is_driven`).
	if run_timer != null:
		run_timer.call("on_seated", player)

	# A physics gun cannot hold a prop from inside a car. Not a rule about vehicles: the
	# tools reach from the eye and the eye has just moved, so whatever was on the end of
	# the beam is now somewhere the player never aimed.
	if player.phys_gun != null:
		player.phys_gun.release()
	if player.grav_gun != null:
		player.grav_gun.drop()

	DotLog.debug(CHANNEL, "a player got in", {
		"player": String(rider_id), "vehicle": String(vehicle.def.id), "seat": String(seat.id)
	})


func _on_unseated(
	rider_id: StringName,
	_vehicle: DotVehicleInstance,
	_seat: DotVehicleSeat,
	at: Vector3
) -> void:
	var player: PlaygroundPlayer = players.get(rider_id)

	if player == null:
		return

	player.set_riding(false)

	# And the mirror image: on a driving track the run ends when the driver leaves the car.
	if run_timer != null:
		run_timer.call("on_unseated", player)

	# Put down where the sweep said there was room, through the controller's own state
	# rather than by moving the node: the movement reads position from the state and
	# would put them straight back otherwise. `teleport` is the one call that sets both.
	player.teleport(at)


## Keeps a riding player's movement state on the seat they are sitting in.
##
## [b]The half that is invisible until somebody watches from another machine.[/b] The
## rider's NODE is carried by the vehicle, because dot-vehicle reparents it — but
## everything that reads a player reads [code]controller.state.position[/code]: the
## timer, the NPC candidate list, the HUD, and above all [PlaygroundPlayerNet], which
## replicates the movement state and nothing else. Without this a passenger is drawn on
## everybody else's screen at the spot where they got in, for the whole journey, while
## being perfectly correct on their own.
##
## Run AFTER the vehicles have ticked and before the timers are fed, which is the same
## "time the tick with the position the move produced" rule the players already follow.
func _carry_riders() -> void:
	if vehicles == null or vehicles.ride.rider_count() == 0:
		return

	for id in players:
		var player: PlaygroundPlayer = players[id]

		if not player.riding:
			continue

		var vehicle := vehicles.vehicle_of_rider(id)

		if vehicle == null:
			continue

		player.adopt_ride(player.global_position, vehicle.velocity())


## The constraints and the armed NPCs' world. After the props and the senses, which both
## of them read.
func _build_npc_world() -> void:
	constraints = PlaygroundConstraints.new()
	constraints.name = "Constraints"
	add_child(constraints)

	npc_world = PlaygroundNpcWorld.new()
	npc_world.name = "NpcWorld"
	npc_world.game = self
	add_child(npc_world)

	# Metadata on the director, where dot-npc-ai's brain looks — see DotNpcAiSkill.attach.
	npc_skill.attach(npc_world)
	npc_squads.attach(npc_world)
	npc_sounds.attach(npc_world)

	projectiles = PlaygroundProjectiles.new()
	projectiles.game = self
	projectiles.authority = authoritative
	projectiles.catalogue = PlaygroundZee.catalogue()
	projectiles.add_board(npc_sounds, npc_world.now)
	add_child(projectiles)


func _build_npc_senses() -> void:
	npc_senses = DotNpcSenses.new()

	# Tuned for a sandbox rather than for a horde. A playground NPC is something a
	# player is poking at, so it should be harder to make it change its mind and quicker
	# to give up than a zombie in a corridor would be.
	npc_senses.switch_ratio = 0.55
	npc_senses.commitment_grace = 2.5

	# Off. A line-of-sight raycast per candidate per NPC at 128 Hz is the single most
	# expensive thing an NPC layer can do, and in a sandbox where the NPCs are toys
	# nobody is hiding from them. A catalogue entry can still ask for it per kind.
	npc_senses.line_of_sight_enabled = true


## The players as perception candidates. See [member npc_candidates].
func _rebuild_npc_candidates() -> void:
	npc_candidates.clear()

	for id in players:
		var player: PlaygroundPlayer = players[id]

		# Loudness is the player's own speed. A sprinting player is heard further than
		# one edging along a wall, which is the whole reason hearing is separate from
		# sight — and it is a number this game already has.
		var loudness := player.speed() * 0.9

		npc_candidates.append(
			DotNpcSenses.Candidate.new(id, player.global_position, &"player", loudness)
		)

	# The armed NPCs see the players and each other: a soldier on `hostile` and a rebel on
	# `player` are candidates for one another, and the senses skip a candidate on the
	# perceiver's own faction — so a rebel never picks a player, which is what makes it
	# friendly. The older entities keep [member npc_candidates], players only.
	npc_candidates_all = npc_candidates.duplicate()

	for entity in armed_npcs:
		if not is_instance_valid(entity):
			continue

		var faction := StringName(entity.call("tune_string", &"faction", "hostile"))
		npc_candidates_all.append(DotNpcSenses.Candidate.new(
			npc_id_of(entity), (entity as Node3D).global_position, faction, 0.0
		))


## Drops an entity from the tick list when its prop goes.
##
## Connected to the spawner's own signal rather than checked per tick. `removed` is
## emitted BEFORE the node is freed, which is exactly so a listener holding a
## reference can let go while it still exists.
func _on_prop_removed(prop: DotPropInstance, _reason: StringName) -> void:
	# Not while a blast is still walking the props: the barrel it started from must stay
	# skipped until the outermost blast is done (see [member _breaking]).
	if _blast_depth == 0:
		_breaking.erase(prop.instance_id)
	_debris_expiry.erase(prop.instance_id)
	_doors.erase(prop.instance_id)
	_levers.erase(prop.instance_id)

	# A vehicle first, because it may still have people in it. `remove` evacuates them —
	# forcing the exit, because a car being deleted is exactly the case where there may
	# be nowhere to stand — and leaves the node alone, since dot-props owns it.
	if PlaygroundSpawnables.kind_of(prop.def) == PlaygroundSpawnables.Kind.VEHICLE:
		# Found by NODE, not by the prop's instance id. dot-props and dot-vehicle both
		# key their tables on "an instance id" and there is nothing making the two the
		# same number; the node is what both of them actually agree about.
		var riding_vehicle := vehicles.vehicle_for_node(prop.node) if vehicles != null else null

		if riding_vehicle != null:
			vehicles.remove(riding_vehicle.instance_id, DotVehicleSpawner.REASON_CLEANUP)

	# Every weld, rope and no-collide on it goes first, while the node is still valid.
	if constraints != null and prop.node != null:
		constraints.forget_body(prop.node)

	var entity := prop.node as PlaygroundEntity

	if entity == null:
		return

	entities.erase(entity)
	unregister_armed_npc(entity)
	waypoints.erase(entity)


# --- Armed NPCs -----------------------------------------------------------------

## Every waypoint placed, in the order placed. See [method nearest_waypoint].
var waypoints: Array = []


func register_waypoint(entity: Node) -> void:
	if not waypoints.has(entity):
		waypoints.append(entity)


## The waypoint of [param owner]'s nearest to [param at] within [param radius] metres, or
## null. By owner, because two builders in one sandbox each laying a patrol would otherwise
## send one's soldiers along the other's route.
func nearest_waypoint(owner: StringName, at: Vector3, radius: float = 80.0) -> Node3D:
	var best: Node3D = null
	var best_d := radius

	for point in waypoints:
		if not is_instance_valid(point):
			continue

		var node := point as Node3D
		var instance: Variant = point.get("instance")

		if instance == null or (instance as DotPropInstance).owner_id != owner:
			continue

		var d := node.global_position.distance_to(at)

		if d < best_d:
			best_d = d
			best = node

	return best


func register_armed_npc(entity: Node) -> void:
	if not armed_npcs.has(entity):
		armed_npcs.append(entity)


func unregister_armed_npc(entity: Node) -> void:
	armed_npcs.erase(entity)


## The candidate id an armed NPC is known by: `n` and its instance id.
static func npc_id_of(entity: Node) -> StringName:
	return StringName("n%d" % entity.get_instance_id())


## The armed NPC a candidate id names, or null.
func armed_npc(id: StringName) -> Node3D:
	for entity in armed_npcs:
		if is_instance_valid(entity) and npc_id_of(entity) == id:
			return entity
	return null


## Where a perception candidate is: a player's chest or an armed NPC's.
func candidate_position(id: StringName, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	var player: Variant = players.get(id)

	if player is Node3D:
		return (player as Node3D).global_position + Vector3.UP * 0.9

	var npc := armed_npc(id)
	return npc.global_position + Vector3.UP * 0.4 if npc != null else fallback


## How a dead NPC's body falls (a sandbox soldier, a wave): the reaction rule over the
## server's `sv_ragdoll_reactions`, pushed away from [param by] when that is a player, from
## [method next_seed]. Kept on the node as `pg_death` for the bridge, which sends it with the
## PROP_GONE that takes the body away; every client copies a ragdoll from the figure it drew.
func decide_npc_death(body: Node3D, by: StringName, damage: float = 0.0) -> DotPlayerDeath:
	if body == null:
		return null
	var direction := Vector3.ZERO
	var killer: PlaygroundPlayer = players.get(by, null)
	if killer != null and killer.controller != null:
		direction = body.global_position - killer.controller.state.position
		direction.y = 0.0
	var death := DotPlayerDeath.decide(
		ragdoll_rules.reactions(), false, damage, direction, next_seed(&"npc_death")
	)
	body.set_meta(&"pg_death", death)
	return death


## The combat entity id an armed NPC shoots as. Its candidate id's number: unique, stable
## for its life, and never a player's session id because those are small.
func npc_entity_id(entity: Node) -> int:
	return entity.get_instance_id()


## What [param player_id] wants their NPCs to carry, or [param fallback].
func npc_weapon_for(player_id: StringName, fallback: StringName = &"") -> StringName:
	var chosen: Variant = npc_weapon_choice.get(player_id, null)

	if chosen == null or StringName(str(chosen)) == &"":
		return fallback

	return StringName(str(chosen))


## Sets what [param player_id]'s next NPCs carry. Refuses a weapon an NPC cannot use.
func set_npc_weapon_choice(player_id: StringName, weapon_id: StringName) -> DotResult:
	if weapon_id == &"" or weapon_id == &"none":
		npc_weapon_choice[player_id] = weapon_id
		return DotResult.success(weapon_id)

	var def := weapon_def(weapon_id)

	if def == null or not PlaygroundZee.npc_can_use(def):
		return DotResult.fail(DotError.CODE_INVALID, "NPCs cannot use that weapon.", String(weapon_id))

	npc_weapon_choice[player_id] = weapon_id
	return DotResult.success(weapon_id)


## How many welds, ropes and no-collides [param player_id] has. For `pg_limits`.
func constraint_count(player_id: StringName) -> int:
	return constraints.count_owned(player_id) if constraints != null else 0


# --- Shots ----------------------------------------------------------------------

## A player's zee weapon fired: NPCs in earshot hear it, and NPCs it hits are hurt.
##
## Players hurting players is the arena's, and props being shoved is
## `PlaygroundZee.shove_props`; this is the third thing a shot does, which only exists
## because NPCs can now be killed.
func player_shots_fired(player_id: StringName, outcome: DotWeaponOutcome) -> void:
	if outcome == null:
		return

	var player: Variant = players.get(player_id)

	if not (player is CollisionObject3D) or not (player as Node3D).is_inside_tree():
		return

	var shooter := player as CollisionObject3D

	# Before the `used` test: what a grenade's release produces is a spawn, and whether a
	# weapon calls that a use is the weapon's business. A spawn left in an outcome is a
	# grenade that cost one and never existed, which is what this game used to do.
	if projectiles != null:
		var _thrown := projectiles.accept(outcome, player_id, shooter)

	if not outcome.used:
		return

	npc_sounds.emit(
		DotNpcAiSounds.Kind.COMBAT, shooter.global_position, GUNFIRE_RADIUS,
		npc_world.now() if npc_world != null else 0.0, 0.5, player_id
	)

	var exclude: Array[RID] = [shooter.get_rid()]

	for hit in PlaygroundZee.trace_outcome(shooter.get_world_3d().direct_space_state, outcome, exclude):
		var collider: Variant = hit["collider"]

		# A toy first: a shot beach ball bounces away, a shot bell rings. The toy box's push,
		# never the prop shove below, whose damage-sized impulse sends a ball off at 40 m/s.
		if shoot_toy(collider, hit):
			continue

		if collider is Node and (collider as Node).has_method("take_damage"):
			(collider as Node).call("take_damage", float(hit["damage"]), player_id)
		elif collider is Node and hurt_pane(collider as Node, float(hit["damage"]), player_id):
			pass
		elif collider is Node:
			var _broke := hurt_prop(collider as Node, float(hit["damage"]), player_id)


## An armed NPC's weapon fired: what it hits is hurt — another NPC always, a player only
## while the arena is on (a sandbox where nobody can be killed stays one) — a loose prop is
## shoved, and everything in earshot hears it.
func npc_shots_fired(entity: Node3D, outcome: DotWeaponOutcome) -> void:
	if outcome == null or entity == null or not entity.is_inside_tree():
		return

	var shooter_id := npc_id_of(entity)

	if projectiles != null:
		var _thrown := projectiles.accept(outcome, shooter_id, entity)

	npc_sounds.emit(
		DotNpcAiSounds.Kind.COMBAT, entity.global_position, GUNFIRE_RADIUS,
		npc_world.now(), 0.5, shooter_id
	)

	var exclude: Array[RID] = [(entity as CollisionObject3D).get_rid()]

	for hit in PlaygroundZee.trace_outcome(entity.get_world_3d().direct_space_state, outcome, exclude):
		var collider: Variant = hit["collider"]
		var damage := float(hit["damage"])

		if shoot_toy(collider, hit):
			continue

		if collider is Node and (collider as Node).has_method("take_damage"):
			(collider as Node).call("take_damage", damage, shooter_id)
		elif collider is PlaygroundPlayer:
			if arena_hurt.is_valid():
				arena_hurt.call(shooter_id, (collider as PlaygroundPlayer).player_id, damage, float(hit["distance"]))
		elif collider is StaticBody3D and hurt_pane(collider as Node, damage, shooter_id):
			pass
		elif collider is RigidBody3D:
			# Hurt first: a shot that breaks a crate leaves nothing to shove.
			var _broke := hurt_prop(collider as Node, damage, shooter_id)
			if not (collider as RigidBody3D).freeze and (collider as Node3D).is_inside_tree():
				(collider as RigidBody3D).apply_impulse(
					(hit["direction"] as Vector3) * damage * SHOT_IMPULSE,
					(hit["point"] as Vector3) - (collider as Node3D).global_position
				)


## `func(victim: StringName, amount: float) -> bool`: hurts a player standing in a hazard
## (lava) and says whether it did. The module sets it to the arena's `hurt` while the arena
## is on; unset, or answering false, a hazard sends the player back to the spawn instead,
## because a sandbox where nobody can be hurt still has to say "not in there".
var hazard_hurt: Callable = Callable()

## The current map's liquid volumes, `[{box: AABB, material, index}]`, from a document map.
var liquids: Array = []

## Prop instance id -> seconds it has been inside a burning liquid. See [method _liquid_tick].
var _melting: Dictionary = {}

## Seconds a prop lasts in lava before it is gone.
const MELT_SECONDS := 1.0

## `func(attacker: StringName, victim: StringName, amount: float, distance: float)`: how an
## NPC's shot hurts a player. Set by the module to the arena's `hurt` while the arena is
## on; unset, NPCs cannot hurt players — the sandbox's own rule.
var arena_hurt: Callable = Callable()


# --- Weapons in the world -------------------------------------------------------

## The catalogue id a weapon lies in the world as.
static func pickup_id_of(weapon_id: StringName) -> StringName:
	return StringName("pickup_%s" % String(weapon_id).replace(":", "_"))


## Drops [param weapon_id] at [param at], cleaned up after [param lifetime] seconds. Owned
## by nobody, so it counts against no player's weapons limit.
func drop_weapon(weapon_id: StringName, at: Vector3, lifetime: float = 0.0) -> DotPropInstance:
	if props == null:
		return null

	var prop := props.spawn(pickup_id_of(weapon_id), &"", at)

	if prop != null and prop.node != null:
		prop.node.set("lifetime", lifetime)

	return prop


## A player walked over a weapon. Announced, and the server or the client gives it.
func pick_up_weapon(player_id: StringName, weapon_id: StringName) -> void:
	weapon_picked_up.emit(player_id, weapon_id)


func _build_maps() -> void:
	maps = DotMapSession.new()
	maps.name = "Maps"
	maps.world_ref = DotNodeRef.of_path(^"../World")
	add_child(maps)

	maps.catalogue = _map_catalogue()

	if config.catalogue_path != "":
		var loaded := maps.load_catalogue(config.catalogue_path)
		DotLog.result(CHANNEL, "loading the map catalogue", loaded)

	maps.rotation = DotMapRotation.of(maps.catalogue)
	maps.rotation.cooldown = 1

	maps.time_limit.duration = config.map_seconds
	maps.time_limit.rtv_fraction = config.rtv_fraction

	maps.changing.connect(_on_map_changing)
	maps.changed.connect(_on_map_changed)
	maps.map_over.connect(_on_map_over)


## The server's maps.yml, or null when there is none (every map rotates, as it always did).
var rotation_file: DotMapRotationFile = null


## Reads maps.yml (the game's shipped `res://maps.yml` under the server's
## [member PlaygroundConfig.map_rotation_file], looked for in the `--config` directory too) and
## applies it. The server module calls it at boot and `sv_map_rotation_file` calls it again.
## The merge, wildcards and rules are dot-map's [DotMapRotationFile]; this game supplies the
## paths. A file that is present and unreadable is an ERROR and changes nothing: rotating every
## map is a better failure than rotating none.
func load_rotation() -> DotResult:
	var stem := config.map_rotation_file if config != null else ""
	var dir := DotMapRotationFile.config_dir_arg()
	var found := DotMapRotationFile.find(stem, dir)

	if found == "" and stem != "" and (dir != "" or stem != PlaygroundConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every map rotates", {
			"file": stem, "config_dir": dir,
		})

	var paths := PackedStringArray()
	for candidate in ["res://maps.yml", found]:
		if candidate != "" and not paths.has(candidate) and FileAccess.file_exists(candidate):
			paths.append(candidate)

	var read := DotMapRotationFile.load_files(paths, "game-playground")

	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every map rotates", {
			"why": read.error.message,
		})
		rotation_file = null
		apply_rotation()
		return read

	rotation_file = read.value
	if rotation_file.has_rotations():
		DotLog.info(CHANNEL, "the map rotation file", {
			"paths": ", ".join(rotation_file.sources), "active": rotation_file.active_name(),
		})

	apply_rotation()
	return read


## Marks every catalogue map in or out of rotation ([member DotMapDef.in_rotation]) from the
## file. With no file, or one with no rotations, every map is in: what this game did before
## maps.yml. The vote's ballot, nominations, `next` and the rotation's draw all read the mark.
func apply_rotation() -> void:
	if maps == null or maps.catalogue == null or maps.rotation == null:
		return

	if rotation_file != null and rotation_file.has_rotations():
		# An empty rotation plays every installed map: the same set as having no file.
		rotation_file.fallback_in = func(_map: DotMapDef) -> bool: return true
		rotation_file.apply(maps.rotation)
		return

	maps.rotation.order = []

	for def in maps.catalogue.maps:
		def.in_rotation = true


## Whether maps.yml's active rotation plays [param id]. A map the catalogue lacks is not.
func in_rotation(id: StringName) -> bool:
	var def: DotMapDef = maps.catalogue.get_map(id) if maps != null and maps.catalogue != null else null

	return def != null and def.in_rotation


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func rotation_commands() -> Dictionary:
	return rotation_file.commands() if rotation_file != null else {}


## Every name a command of this game's own answers to (the first is the one help shows), from
## maps.yml's `commands: names:` block; the role's own name with no file. Lets `pg_rtv` and its
## siblings be renamed the way dot-vote's roles are.
func command_names(role: String) -> PackedStringArray:
	var names: Dictionary = rotation_commands().get("names", {})

	if not names.has(role):
		return PackedStringArray([role])

	return DotCommandNames.all_of("", names, {}, role)


## The maps this build ships. A server with delivered maps loads a JSON catalogue.
##
## An instance method that forwards, so a caller with a [Playground] keeps working — and
## [b]a static one beside it, because the server browser needs the list without a game.[/b]
## A browser is a menu: there is no world, no server and no [Playground] to ask, and a
## second copy of the list written into the menu is the thing this tree has now gone stale
## four times over.
func _map_catalogue() -> DotMapCatalogue:
	return map_catalogue()


static func map_catalogue() -> DotMapCatalogue:
	var catalogue := DotMapCatalogue.new()

	var table := [
		# The base: a big flat plate of grass, and the default everywhere.
		[&"pg_flatgrass", "Flatgrass", DotMapDef.KIND_SANDBOX, 1],
		# The one map in this family that is not written down. A sandbox's content is
		# what the players build in it, so "somewhere new" is worth more here than
		# "somewhere good".
		[&"pg_generated", "Playground: Generated", DotMapDef.KIND_SANDBOX, 1],
	]

	for row in table:
		var map := DotMapDef.new()
		map.id = row[0]
		map.display_name = row[1]
		map.kind = row[2]
		map.tier = row[3]
		map.scene_path = PlaygroundPaths.rebase("res://maps/%s.tscn") % String(row[0])
		map.author = "playground"
		catalogue.add(map)

	# Custom maps from game-playground-maps, where a checkout links them in (dot-bootstrap's
	# `maps/custom`). A delivered server and client add the same documents from the mounted
	# pack instead, with [method add_map_directory].
	var _linked := add_map_docs(catalogue, PlaygroundPaths.rebase(CUSTOM_MAPS_DIR))

	return catalogue


## Where a checkout links game-playground-maps' documents.
const CUSTOM_MAPS_DIR := "res://maps/custom"

## The one scene every map document is built by. See `maps/pg_data.gd`.
const DATA_MAP_SCENE := "res://maps/pg_data.tscn"


## Adds every map document (`*.json`) in [param dir] to [param catalogue], each built by
## [constant DATA_MAP_SCENE] with its path in `meta.doc`. A document that does not read is
## left out with a WARN; an id already in the catalogue is left as it was, so a delivered map
## can never replace a built-in one under the same name. Returns how many were added.
static func add_map_docs(catalogue: DotMapCatalogue, dir: String) -> int:
	if not DirAccess.dir_exists_absolute(dir):
		return 0
	var added := 0
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for file in files:
		if not file.ends_with(".json"):
			continue
		var path := dir.path_join(file)
		var read: DotResult = _data_map_script().read_doc(path)
		if not read.ok:
			DotLog.warn(CHANNEL, "a map document was left out", {"path": path, "why": read.error.message})
			continue
		var doc: Dictionary = read.value
		var id := StringName(str(doc["id"]))
		if catalogue.get_map(id) != null:
			continue
		var map := DotMapDef.new()
		map.id = id
		map.display_name = str(doc.get("name", String(id)))
		map.kind = StringName(str(doc.get("map_kind", DotMapDef.KIND_SANDBOX)))
		map.tier = int(doc.get("tier", 1))
		map.author = str(doc.get("author", ""))
		map.scene_path = PlaygroundPaths.rebase(DATA_MAP_SCENE)
		map.meta["doc"] = path
		catalogue.add(map)
		added += 1
	return added


## `maps/pg_data.gd`, loaded when first wanted rather than preloaded: it extends the map
## base, which preloads the player, and this file is preloaded by both.
static func _data_map_script() -> GDScript:
	return load(PlaygroundPaths.rebase("res://maps/pg_data.gd")) as GDScript


## Adds the map documents in [param dir] to this game's live catalogue, and puts them in
## the rotation. For a mounted maps pack: the module calls it with each dependency's mount
## prefix on a server, the client with each pack the server told it to fetch.
func add_map_directory(dir: String) -> int:
	if maps == null or maps.catalogue == null:
		return 0
	var added := add_map_docs(maps.catalogue, dir)
	if added > 0:
		maps.rotation = DotMapRotation.of(maps.catalogue)
		maps.rotation.cooldown = 1
		# A new rotation object has forgotten the file's order and its in/out marks.
		apply_rotation()
		DotLog.info(CHANNEL, "custom maps added", {"dir": dir, "maps": added})
	return added


func _prop_catalogue() -> DotPropCatalogue:
	if config.props_path != "":
		# An operator's own catalogue, which is the seam between "a game with a
		# handful of props" and "a server with a content pack". Loaded here rather
		# than layered over the built-in list: a catalogue that merged with the
		# defaults would give every server these fourteen whether it wanted them or
		# not, and there would be no way to remove one.
		var loaded := DotPropCatalogue.load_json(config.props_path)

		if loaded.ok:
			var theirs := loaded.value as DotPropCatalogue

			DotLog.info(CHANNEL, "loaded a prop catalogue", {
				"path": config.props_path, "props": theirs.size()
			})

			for problem in theirs.problems():
				DotLog.warn(CHANNEL, "the prop catalogue has a problem", {
					"problem": problem
				})

			return theirs

		# Refused rather than fallen back on silently. An operator who pointed this
		# at a file and got the built-in props would conclude their file was being
		# read and their edits ignored.
		DotLog.error(CHANNEL, "the prop catalogue could not be read", {
			"path": config.props_path, "why": loaded.error.message
		})

	return PlaygroundSpawnables.with_models(PlaygroundSpawnables.catalogue(), config.props_dir if config != null else "user://props")


## Reads the prop folders again and adds what is new, so a model dropped in while the game
## runs appears in the next menu. Returns the ids added.
func rescan_props() -> PackedStringArray:
	if props == null or props.catalogue == null:
		return PackedStringArray()

	return PlaygroundSpawnables.add_drop_ins(
		props.catalogue, config.props_dir if config != null else "user://props"
	)


# --- Players ---------------------------------------------------------------

## match id -> record key, for the players who have one. See [method record_key].
var _record_keys: Dictionary = {}
## record key -> match id, the other way, for what a run timer reports back.
var _match_ids: Dictionary = {}


## The key a run timer, its records and the boards know a player by.
##
## [b]Not the match id.[/b] The match id (`u<userid>`) is dot-server's sequential,
## server-local counter: it names a seat for the length of one connection, and the same
## account reconnecting is a new number (and a restarted server hands the old numbers to
## strangers). A record keyed by it was a different runner at every connection and could
## be inherited. The key is the account's `session.uid()` (a guest's is per device), given
## to [method add_player]. A player added without one (a solo game, a client's copy, a
## test) is known by the match id, which is then also the key. A display name is never a key.
func record_key(id: StringName) -> StringName:
	return _record_keys.get(id, id)


## The match id a record key belongs to; the key itself when none does.
func match_id(key: StringName) -> StringName:
	return _match_ids.get(key, key)


## True for a key that is a server-local session number (`u<digits>`): the keying records
## carried before they were keyed by account. A run timer moves such records aside.
static func is_legacy_key(key: StringName) -> bool:
	var text := String(key)
	return text.length() > 1 and text.begins_with("u") and text.substr(1).is_valid_int() and not text.contains("-")


func _claim_record_key(id: StringName, key: StringName) -> void:
	if key == &"" or key == id:
		return
	if _match_ids.has(key) and _match_ids[key] != id:
		# The same account twice at once would share one timer, and the second seat's
		# runs would be filed under the first's. It keeps its match id as its key: a
		# legacy-shaped key, which is never ranked.
		DotLog.warn(CHANNEL, "an account is already playing; this seat has no records", {
			"player": String(id), "key": String(key),
		})
		return
	_record_keys[id] = key
	_match_ids[key] = id


func _release_record_key(id: StringName) -> void:
	var key: StringName = _record_keys.get(id, &"")
	_record_keys.erase(id)
	if key != &"":
		_match_ids.erase(key)


## Adds a player and puts them on the current map's spawn. [param p_record_key] is the
## account uid the player's records are filed under; see [method record_key].
func add_player(id: StringName, display_name: String, p_record_key: StringName = &"") -> PlaygroundPlayer:
	if players.has(id):
		return players[id]

	_claim_record_key(id, p_record_key)

	var player := PlaygroundPlayer.new()
	player.name = "Player_" + String(id)
	player.player_id = id
	player.display_name = display_name
	player.authoritative = authoritative
	player.tick_rate = tick_rate

	add_child(player)

	player.carry = carry
	player.carry_enabled_fn = func() -> bool: return config == null or config.prop_surfing
	# The map's toys: the trampolines and pads that throw them, the roundabout that carries
	# them. Both ends; the box is the current map's (see [method _build_toys]).
	player.toys = toys
	player.bounced_fn = _on_bounced

	var _styled := player.set_style(movement_styles[&"normal"])

	player.phys_gun = DotPhysGun.new()
	player.phys_gun.spawner = props
	player.phys_gun.wielder = id

	# [b]A held prop, a frozen prop and a loose one are three rows in the layout.[/b]
	# `sandbox_3d` carries `held_prop` and `frozen_prop` for exactly this, and until
	# dot-props grew these three signals a game could only set a layer at spawn and then
	# be wrong for the rest of the prop's life — a carried crate colliding with the
	# player carrying it, which shoves them backwards down a corridor.
	player.phys_gun.grabbed.connect(
		func(prop: DotPropInstance, who: StringName) -> void:
			reclassify_prop(prop.node, false, true)
			held_changed.emit(who, prop, true)
	)
	player.phys_gun.released.connect(
		func(prop: DotPropInstance, who: StringName) -> void:
			reclassify_prop(prop.node, prop.frozen, false)
			held_changed.emit(who, prop, false)
	)
	player.phys_gun.freeze_changed.connect(
		func(prop: DotPropInstance, frozen: bool) -> void:
			reclassify_prop(prop.node, frozen, prop.held_by != &"")
	)

	player.grav_gun = DotGravGun.new()
	player.grav_gun.spawner = props
	player.grav_gun.wielder = id

	# The layout's player mask rather than the magic 1. With props, entities and
	# vehicles on their own layers, a mask of 1 is a player who walks through all three.
	if player_stack != null:
		_apply_body_mask(player)
		# And a body other people can see. Built for every player, local or not: the one
		# who does not need it is the LOCAL player in first person, and that is a
		# `set_shown(false)` rather than a missing model.
		player.build_character(player_stack.character(), _colour_for(id))
		# And the body itself, now that a player IS a CharacterBody3D — it is in the
		# physics space whether or not the movement uses it, and a body on layer 1 is a
		# body every other sweep treats as level geometry.
		var _put := player_stack.classify(player, &"player")


	players[id] = player
	player.set_water(water_boxes())

	# Given a timer before the first spawn, which asks it which track the player is on.
	if run_timer != null:
		run_timer.call("add_player", id, player)

	spawn_player(id)

	# Their entity id, before anything that might want one. Opened here rather than in
	# a layer so every layer sees the same id whether or not the others are switched
	# on; `PlaygroundDowns` and `PlaygroundArena` both used to mint their own.
	var opened := entity_table.open(
		DotEntity.KIND_PLAYER,
		player,
		&"",
		id,
		float(_tick) / float(maxi(tick_rate, 1))
	)

	if not opened.ok:
		# Guarded above by the `players.has(id)` early return, so a refusal means this
		# id is already an entity and something removed a player without closing them.
		DotLog.error(CHANNEL, "could not open an entity for a player", {
			"player": String(id), "why": opened.error.message,
		})

	# After the player is fully built and in the dictionary: a listener answers this
	# by replicating them, and an entity built over a half-constructed player would
	# replicate a controller that has no style and no timer.
	player_added.emit(id)

	return player


func remove_player(id: StringName) -> void:
	if not players.has(id):
		return

	# Before anything is torn down, so a listener can still read what they were.
	player_removed.emit(id)

	# Let go of them, and of whoever they hold: a beam from a player who is gone holds a
	# player who can never walk again.
	pickup.forget(players, id)

	# Closed after the signal and before the node goes: a listener asking the table
	# who this was must still get an answer, and anything holding the id afterwards
	# gets nothing rather than getting whoever joins next -- serials are not reused.
	entity_table.close(entity_table.id_for_key(id), DotEntityTable.REASON_OWNER_LEFT)

	# Their rock-the-vote goes with them. Without it a server whose players trickle
	# away keeps their votes while the threshold falls with the player count, so a
	# map ends on the votes of people who are no longer there.
	maps.time_limit.unrock(id)

	# Out of the car before anything else, and forced. A player who disconnects while
	# riding leaves a node stowed inside a vehicle and a rider id the ride will never
	# clear — so the seat stays occupied for the rest of the round and the id can never
	# enter anything again. Forced because there may be nowhere legal to stand, and the
	# alternative to putting them somewhere is not putting them anywhere.
	if vehicles != null and vehicles.ride.is_riding(id):
		var riding := vehicles.vehicle_of_rider(id)

		if riding != null:
			vehicles.ride.exit(riding, id, true)

	# Their vehicles are DISOWNED rather than removed, which is dot-vehicle's rule and
	# the opposite of dot-props'. A prop is a thing somebody built; a vehicle is a thing
	# somebody parked, usually with other people in it, and deleting it deletes the car
	# three passengers are riding in.
	if vehicles != null:
		vehicles.owner_left(id)

	# The prop spawner first: it may free nodes, and doing it after the player's own
	# teardown means a physics gun holding one of them is already gone.
	props.player_left(id)

	if run_timer != null:
		run_timer.call("remove_player", id)

	(players[id] as PlaygroundPlayer).queue_free()

	players.erase(id)
	_release_record_key(id)


## Puts a player at the current map's spawn for their track.

## A stable colour for a player, derived from their id.
##
## [b]Derived rather than assigned, so two machines agree without sending anything.[/b]
## A colour handed out by the server is one more field on the wire and one more thing to
## be out of step during a reconnect; a hash of the id is the same colour everywhere, for
## ever, for free. Full saturation and a fixed value, because two players told apart by
## brightness alone are not told apart at a distance.
func _colour_for(id: StringName) -> Color:
	var hue := float(hash(String(id)) % 360) / 360.0
	return Color.from_hsv(hue, 0.62, 0.92)


func spawn_player(id: StringName) -> void:
	var player: PlaygroundPlayer = players.get(id)

	if player == null:
		return

	# A respawn is a teleport, and a held player teleported is pulled straight back to the
	# beam on the next tick.
	pickup.forget(players, id)

	var track := track_of(id)
	var map := current_map_node()

	# [b]The director chooses among the map's own starts; the map is the fallback.[/b]
	# `PlaygroundPlayerStack.refresh_spawns` copies every track's start into it, so this
	# is a better choice among one set rather than a second set — the per-site cooldown,
	# the occupancy check, and with the arena layer on the protection window that is
	# granted inside `choose` and nowhere else.
	if player_stack != null:
		var chosen := player_stack.choose_start(id, track)

		if chosen.ok:
			var choice := chosen.value as DotSpawnChoice
			# Degrees out, for the same reason radians went in: `DotFpsState.yaw` is in
			# degrees and `DotFpsController` converts at exactly this boundary too.
			player.teleport(
				_clear_of_players(choice.transform.origin, id),
				rad_to_deg(choice.transform.basis.get_euler().y)
			)
			return

	var start := start_for(track)

	if not start.is_empty():
		player.teleport(_clear_of_players(start["at"], id), float(start["yaw"]))
	elif map != null:
		player.teleport(_clear_of_players(map.fallback_spawn, id), map.fallback_yaw)
	else:
		player.teleport(_clear_of_players(Vector3(0.0, 2.0, 0.0), id), 0.0)


## How close two players may stand at a spawn, and how far one may be stepped aside.
const SPAWN_SPACING := 1.5
const SPAWN_RINGS := 2

## [param at], or the nearest point on a ring round it that nobody else is standing on.
##
## [b]Every start here is a single point, and every player was put on it.[/b] Two people
## joining the sandbox stood inside each other at (0, 1, 0), facing the same way, so each
## one's first-person camera was inside the other's head: a connected client that drew
## the other player perfectly showed a wall of their colour, and stepping off the spot was
## the only way either found out anybody else was there. dot-spawn's occupancy does not
## help with one site — it can only choose between sites. Two rings of eight at 1.5 m
## stay on the smallest start pad (6 m), and a crowd past seventeen shares the centre
## rather than being thrown off a course.
func _clear_of_players(at: Vector3, id: StringName) -> Vector3:
	for ring in range(SPAWN_RINGS + 1):
		var steps := 1 if ring == 0 else 8

		for step in range(steps):
			var angle := TAU * float(step) / float(steps)
			var spot := at + Vector3(cos(angle), 0.0, sin(angle)) * SPAWN_SPACING * ring

			if not _someone_at(spot, id):
				return spot

	return at


func _someone_at(spot: Vector3, id: StringName) -> bool:
	for other_id: Variant in players:
		if other_id == id:
			continue

		var other: PlaygroundPlayer = players[other_id]

		if other == null or other.controller == null or other.controller.state == null:
			continue

		var there := other.controller.state.position
		if Vector2(there.x - spot.x, there.z - spot.z).length() < SPAWN_SPACING * 0.9 \
				and absf(there.y - spot.y) < 2.0:
			return true

	return false


## Puts a player on a movement style. A run timer hears it through the player's
## `style_changed` and moves the ranking half with it.
func set_player_style(id: StringName, style_id: StringName) -> bool:
	var player: PlaygroundPlayer = players.get(id)

	if player == null or not movement_styles.has(style_id):
		return false

	return player.set_style(movement_styles[style_id]).ok


## Starts offering what the player subscribed to (the Workshop) on the spawn menu and the map
## list: pack weapons, props, NPCs and entities, and maps of the kinds `provides.json` accepts.
##
## [b]Solo only, and it is the caller that decides.[/b] The offline client calls this; a dedicated
## server and a connected client never do, so an online game has none of it, and the index's own
## session tag hides it again for a solo game that goes online. [param index] defaults to the
## shared one.
func follow_workshop(index: DotContentIndex = null) -> PlaygroundWorkshop:
	var shared := index if index != null else DotContentIndex.shared()
	if workshop == null:
		workshop = PlaygroundWorkshop.new()
		workshop.changed.connect(func() -> void: workshop_changed.emit())
	workshop.follow(shared, props.catalogue, weapons)
	if maps != null and maps.catalogue != null:
		maps.catalogue.follow_content(shared, PlaygroundWorkshop.accepted_map_kinds())
	return workshop


## Stops [method follow_workshop]: the pack rows leave the catalogue and the weapon list.
func unfollow_workshop() -> void:
	if workshop != null:
		workshop.unfollow()
	if maps != null and maps.catalogue != null:
		maps.catalogue.unfollow_content()


## The definition of one weapon, or null.
func weapon_def(id: StringName) -> PlaygroundWeaponDef:
	return PlaygroundWeapons.find(weapons, id)


## Whether a player may act on somebody else's props, from the configuration.
##
## [b]Asked of the game, not decided in a tool.[/b] dot-props passes
## `can_touch_others` to every tool call precisely so this is one answer in one place;
## a physics gun and a remover that disagreed would be a server where you cannot move
## somebody's crate but can delete it.
## The physics gun's primary press: a player in the beam first, then a prop. A player
## refused (immune, already held) is an answer, not a miss, so the prop behind them is not
## grabbed instead; a beam that meets nobody falls through to the gun.
func phys_gun_grab(
	player: PlaygroundPlayer, space: Variant, origin: Vector3, aim: Vector3, view: Basis, may_touch: bool
) -> DotResult:
	var target := pickup.player_in_beam(players, player, space, origin, aim) if pickup.enabled else null
	if target != null:
		return pickup.pick_up(player, target, origin)
	return player.phys_gun.grab(space, origin, aim, view, may_touch)


## Lets go of whatever the physics gun holds, a player or a prop. A player is thrown with
## the beam's velocity.
func phys_gun_release(player: PlaygroundPlayer) -> void:
	pickup.release(players, player.player_id, true)
	player.phys_gun.release()


## Turns creative mode on or off for [param id]: their props protected in dot-props (every
## tool and every source of harm asks the spawner), out of anybody's beam, and the arena's
## damage refused both ways. Refused when the server does not allow it.
##
## [b]Both ways[/b]: a player nobody can hurt who could still hurt everybody would be the
## best way to win the arena, not a way to build.
func set_creative(id: StringName, on: bool) -> DotResult:
	var player: PlaygroundPlayer = players.get(id)

	if player == null:
		return DotResult.fail(DotError.CODE_INVALID, "No such player.")

	if on and config != null and not config.allow_creative:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Creative mode is off on this server.")

	if player.creative == on:
		return DotResult.success(on)

	player.creative = on

	if props != null:
		props.set_protected(id, on)

	if on:
		# Out of anybody's hands now, and out of their own grip on anybody else.
		pickup.forget(players, id)

		# A prop of theirs somebody else is holding is let go: protection that waited for
		# the holder to let go first would not be protection.
		for other_id in players:
			if other_id == id:
				continue
			var other: PlaygroundPlayer = players[other_id]
			var held: DotPropInstance = other.phys_gun.held if other.phys_gun != null else null
			if held != null and held.owner_id == id:
				other.phys_gun.release()
			var carried: DotPropInstance = other.grav_gun.carried if other.grav_gun != null else null
			if carried != null and carried.owner_id == id:
				var _dropped := other.grav_gun.drop()

	DotLog.info(CHANNEL, "creative mode", {"player": String(id), "on": on})
	creative_changed.emit(id, on)
	return DotResult.success(on)


func is_creative(id: StringName) -> bool:
	var player: PlaygroundPlayer = players.get(id)
	return player != null and player.creative


## A shot or a blast reached [param node]: if it is a prop with health and `destruction` is
## on, it takes [param amount] from [param by]. True when it did. One place, so the gun, the
## NPC's gun and the grenade cannot disagree about what breaks.
func hurt_prop(node: Node, amount: float, by: StringName) -> bool:
	if not authoritative or config == null or not config.destruction or prop_damage == null or props == null:
		return false

	var prop := props.prop_for_node(node)

	if prop == null or _breaking.has(prop.instance_id) or not prop_damage.is_breakable(prop.instance_id):
		return false

	var before := prop_damage.health_of(prop.instance_id)
	var at := prop.position()
	var taken := prop_damage.hurt(prop.instance_id, amount, by)

	if taken.ok:
		confirm_hit(by, hit_victim_id(DotEntity.KIND_PROP, prop.instance_id),
			minf(amount, maxf(before, 0.0)), at, float(taken.value) <= 0.0)

	return taken.ok


## Tells the shooter their hit landed ([signal hit_landed]): from the arena's damage to a
## player, an NPC's [code]take_damage[/code], [method hurt_prop] and [method hurt_pane].
##
## [b]Only for a player, only on the authority, and only for something taken.[/b] An NPC's
## shot, a barrel nobody lit and the world's own damage confirm nothing to anybody; a hit
## that took nothing (a dead body, a protected prop) did not land.
func confirm_hit(by: StringName, victim: int, amount: float, point: Vector3, killed: bool, headshot: bool = false) -> void:
	if not authoritative or amount <= 0.0 or by == &"" or not players.has(by):
		return
	hit_landed.emit(by, victim, amount, point, killed, headshot)


## A key for [param serial] of [param kind] ([code]DotEntity.KIND_*[/code]) in one space, so the
## damage numbers on an NPC, a crate and a pane never add up together. Not an entity id: a
## pane and an NPC have none, and an NPC's serial here is its object id.
static func hit_victim_id(kind: int, serial: int) -> int:
	return kind * DotEntity.STRIDE + posmod(serial, DotEntity.STRIDE)


## Broken: a few pieces in its colour where it stood, owned by nobody and gone in
## `debris_seconds`. Spawned through the spawner so every client draws them.
func _on_prop_broken(prop: DotPropInstance, at: Vector3, _by: StringName) -> void:
	_breaking[prop.instance_id] = true

	if not authoritative or config == null or props == null:
		return

	var colour := PlaygroundProp.colour_of(prop.def) if prop.def != null else Color.GRAY
	var extent := PlaygroundProp.extent_of(prop.def) if prop.def != null else Vector3.ONE
	var count := mini(config.debris_pieces, maxi(1, int(ceil(extent.x * extent.y * extent.z * 4.0))))
	var rng := RandomNumberGenerator.new()
	rng.seed = next_seed(&"debris")

	for i in count:
		var offset := Vector3(rng.randf_range(-0.5, 0.5) * extent.x, rng.randf_range(0.0, 0.5) * extent.y, rng.randf_range(-0.5, 0.5) * extent.z)
		var piece := props.spawn(&"debris", &"", at + offset)

		if piece == null:
			break

		if piece.node is PlaygroundProp:
			(piece.node as PlaygroundProp).set_tint(colour)

		if piece.node is RigidBody3D:
			(piece.node as RigidBody3D).linear_velocity = offset.normalized() * rng.randf_range(2.0, 5.0) + Vector3.UP * 2.0

		_debris_expiry[piece.instance_id] = _clock_seconds() + config.debris_seconds


## A barrel went up: players beside it are hurt through the arena (so only with it on),
## armed NPCs through their own health, and other breakables take the blast too.
func _on_prop_exploded(at: Vector3, radius: float, damage: float, _force: float, by: StringName) -> void:
	if not authoritative or radius <= 0.0:
		return

	for id in players:
		var player: PlaygroundPlayer = players[id]
		var distance := player.global_position.distance_to(at)
		if distance <= radius and arena_hurt.is_valid():
			arena_hurt.call(by, id, damage * (1.0 - distance / radius), distance)

	_blast_depth += 1

	var _thrown := blast_toys(at, radius)

	if props != null:
		for other in props.all_props():
			if other == null or not other.is_alive() or other.node == null or _breaking.has(other.instance_id):
				continue
			var distance := other.position().distance_to(at)
			if distance > radius:
				continue
			if other.node.has_method("take_damage"):
				other.node.call("take_damage", damage * (1.0 - distance / radius), by)
			else:
				var _hurt := hurt_prop(other.node, damage * (1.0 - distance / radius), by)

	_blast_depth -= 1

	if _blast_depth == 0:
		_breaking.clear()


# --- Toys ----------------------------------------------------------------------

## What a person weighs on a see-saw, kg.
const PERSON_MASS := 70.0

## How far the use key reaches a toy: a ball at your feet, a switch at arm's length.
const TOY_REACH := 2.6

## A grenade's or a barrel's blast at its centre, m/s to a toy of up to 3 kg.
const TOY_BLAST_SPEED := 12.0


## The map's toys from its `map_toys()` (dot-props placements), on both ends, in the order the
## map lists them: that order is how a client pairs each with the server's entity. Every player
## is handed the box for the trampolines and the roundabout.
func _build_toys(loaded: Node) -> void:
	_clear_toys()
	var placements: Array = loaded.call("map_toys") if loaded != null and loaded.has_method("map_toys") else []
	var layout: DotPhysicsLayout = player_stack.physics.layout if player_stack != null and player_stack.physics != null else null

	toys = DotPropToyBox.new()
	toys.name = "Toys"
	toys.authoritative = authoritative
	toys.rules = toy_rules
	toys.gravity = PlaygroundMap.MOVE_GRAVITY
	toys.kill_y = -60.0
	if layout != null:
		toys.loose_layer = layout.layer_mask(&"toy")
		toys.loose_mask = layout.collision_mask(&"toy")
		toys.solid_layer = layout.layer_mask(&"frozen_prop")
		toys.solid_mask = layout.collision_mask(&"frozen_prop")
		toys.footprint_layer = layout.layer_mask(&"footprint")
		toys.aim_mask = layout.mask_of([&"world", &"prop", &"frozen_prop", &"toy"] as Array[StringName])
	add_child(toys)

	var built := toys.build(placements)
	if not built.ok:
		DotLog.warn(CHANNEL, "a map's toys would not build", {"why": built.error.message})

	var _sounds := toys.sound.connect(func(id: StringName, at: Vector3, strength: float) -> void: toy_sound.emit(id, at, strength))

	if carry != null:
		carry.toys = toys
	for id in players:
		(players[id] as PlaygroundPlayer).toys = toys

	toys_built.emit()


func _clear_toys() -> void:
	if toys == null:
		return
	toys_clearing.emit()
	if carry != null:
		carry.toys = null
	for id in players:
		(players[id] as PlaygroundPlayer).toys = null
	remove_child(toys)
	toys.queue_free()
	toys = null


## A toy made a sound (a bounce, a knock, a switch, a honk), on whichever end drew it: what the
## presentation plays.
signal toy_sound(id: StringName, at: Vector3, strength: float)


## The toy [param player] is looking at within reach, or -1. Both ends.
func toy_aimed(player: PlaygroundPlayer) -> int:
	if toys == null or player == null or not player.is_inside_tree():
		return -1
	return toys.aimed(player.eye_position(), player.aim_direction(), TOY_REACH)


## A hit scan's hit on a toy: dot-props pushes it by the damage (a shot bell rings). True when
## the collider was a toy's, so the caller does not also hurt or shove it. Server side.
func shoot_toy(collider: Variant, hit: Dictionary) -> bool:
	if toys == null or not authoritative or not (collider is Object):
		return false
	return toys.shot(collider as Object, hit["point"], hit["direction"], float(hit["damage"])) >= 0 \
		or DotPropToyBox.toy_of(collider) != null


## A blast at [param at]: every moving toy within [param radius] thrown away from it. Server
## side; a grenade's ([PlaygroundProjectiles]) and a breaking barrel's. How many it moved.
func blast_toys(at: Vector3, radius: float) -> int:
	if toys == null or not authoritative:
		return 0
	return toys.blast(at, radius, TOY_BLAST_SPEED)


## Everybody against the toys this tick, after they moved: a walk into a ball pushes it, weight
## on a see-saw tips it, then the box's own tick (the awake cap, the lost sent home). A person
## is not a rigid body, so this is how one touches a toy at all. Server side.
func _advance_toys(step: float) -> void:
	if toys == null or not authoritative:
		return

	for id in players:
		var player: PlaygroundPlayer = players[id]
		if player.riding:
			continue
		var state := player.controller.state
		if state == null:
			continue
		var tunables := player.controller.tunables
		var radius := tunables.radius if tunables != null else 0.35
		var height := lerpf(tunables.stand_height, tunables.crouch_height, state.crouch_fraction) if tunables != null else 1.8
		var _pushed := toys.push_from(state.position, state.velocity, radius, height)
		if state.is_grounded():
			var _bore := toys.stand_on(state.position, PERSON_MASS)

	toys.advance(step)


## A player thrown by a toy: its count goes up, which every client hears. Server side.
func _on_bounced(index: int) -> void:
	if authoritative and toys != null:
		toys.launched(index)


func _expire_debris() -> void:
	if _debris_expiry.is_empty() or props == null:
		return

	var now := _clock_seconds()

	for instance_id: int in _debris_expiry.keys():
		if now >= float(_debris_expiry[instance_id]):
			_debris_expiry.erase(instance_id)
			var _gone := props.remove(instance_id, DotPropSpawner.REASON_CLEANUP)


func _clock_seconds() -> float:
	return float(_tick) / float(maxi(tick_rate, 1))


func may_touch_others() -> bool:
	return config == null or config.touch_others_props


func current_map_node() -> PlaygroundMap:
	return maps.world as PlaygroundMap if maps != null else null


## Which tracks this map has something on, main track (0) first.
##
## The run timer's answer, from its zones, when there is one. [code][0][/code] otherwise,
## because a sandbox is a legitimate track and every map has it.
func tracks_on_this_map() -> Array[int]:
	var out: Array[int] = [0]

	if run_timer != null:
		out.assign(run_timer.call("tracks"))

	return out


## The track [param id] is on: the run timer's answer, or 0 (the main track).
func track_of(id: StringName) -> int:
	if run_timer != null:
		return int(run_timer.call("track_of", id))

	return 0


## Where a player on [param track] starts, as `{at: Vector3, yaw: float}` (degrees), or an
## empty dictionary when there is no map or the track has no start.
##
## The run timer's SPAWN zone first, when it has one for the track: a course's start is
## the timer's to say, and a sandbox with no timer starts every track at the map's spawn.
func start_for(track: int) -> Dictionary:
	if run_timer != null:
		var zoned: Dictionary = run_timer.call("start_for", track)

		if not zoned.is_empty():
			return zoned

	var map := current_map_node()

	if map == null:
		return {}

	return {"at": map.spawn_for(track), "yaw": map.spawn_yaw_for(track)}


## Called by a run timer's hook to plug itself in. See [member run_timer].
func attach_run_timer(timer: Object) -> void:
	run_timer = timer
	DotLog.info(CHANNEL, "a run timer is attached", {"by": str(timer.get_script().resource_path)})


## A time as `m:ss.mmm`, the way every run timer shows one: thousandths, always, because
## runs are decided by them. A copy of dot-timer's format, so the HUD and the logs can say a
## time with the timer absent.
static func format_time(seconds: float) -> String:
	var total := absf(seconds)
	var hours := int(total / 3600.0)
	var minutes := int(fmod(total, 3600.0) / 60.0)
	var rest := fmod(total, 60.0)
	var text := "%d:%02d:%06.3f" % [hours, minutes, rest] if hours > 0 else "%d:%06.3f" % [minutes, rest]
	return ("-" if seconds < 0.0 else "") + text


# --- Maps ------------------------------------------------------------------

func change_map(id: StringName) -> DotResult:
	return await maps.change_to(id)


## How many [method next_seed]s have been handed out. Never reset, so a second round does not
## replay the first.
var _seed_serial: int = 0


## The seed a generated map is built from.
##
## [b]Zero means "pick one and announce it", which is the only honest default.[/b] A
## generated world nobody can name the seed of is a world nobody can share, and "play the
## map I played" is the single most-requested feature every one of them gets. `pg_seed`
## is the cvar, and the seed that was actually used is logged whichever way it came.
##
## Taken from dot-randomness when a game has one, so a generated map and every other
## random thing in the session come out of one seed rather than two.
func map_seed() -> int:
	if config != null and config.map_seed != 0:
		return config.map_seed

	var rng: Object = DotRegistry.get_service(&"dot_random_source")
	if rng != null and rng.has_method("seed_for"):
		return int(rng.call("seed_for", &"map"))

	# Nothing configured and no randomness manager: a fixed seed rather than a random
	# one, because a sandbox that is a different shape on every boot and cannot say why
	# is worse than one that is always the same.
	return 1


## A stable seed for the next thing that wants its own randomness: a scripted entity's
## [member DotNpcInstance.seed], or a broken prop's debris. The session's [method map_seed]
## and a count of what has asked, on a stream per kind.
##
## [b]Never an object id.[/b] Entities and debris were seeded from `instance_id`, the Godot
## object id, which moves whenever anything earlier in the process allocates one more object:
## the same session then walked its NPCs and scattered its debris differently from build to
## build. Always above 1, because dot-npc-ai reads a character seed of 0 or 1 as the preset's.
func next_seed(kind: StringName) -> int:
	_seed_serial += 1
	return DotRandomStream.new(map_seed()).stream_for(kind, _seed_serial).range_i_at(0, 2, 0x7FFFFFFF)


func _on_map_changing(_from: DotMapDef, _to: DotMapDef) -> void:
	# Announced before anything is torn down, which is the whole point of the signal:
	# every run in progress is on geometry that is about to stop existing, and every
	# prop is parented to it.
	pickup.release_all(players)

	if run_timer != null:
		run_timer.call("on_map_changing")

	for id in players:
		var player: PlaygroundPlayer = players[id]

		if player.phys_gun != null:
			player.phys_gun.release()

		if player.grav_gun != null:
			player.grav_gun.drop()

	props.clear_all(DotPropSpawner.REASON_CLEANUP)

	if projectiles != null:
		projectiles.clear()

	_clear_toys()


func _on_map_changed(map: DotMapDef, loaded: Node) -> void:
	# A map that has to be told something before it can build itself. Duck-typed rather
	# than type-checked, so a delivered map with the same shape works and this file names
	# nothing from `maps/`.
	#
	# [b]Before the spawns below, and that ordering is the whole reason it is here.[/b]
	# A generated map's spawn point comes out of the generator, so spawning a player
	# before it has run puts them at the fallback -- which on a generated map is a guess,
	# and a guess inside a wall is a player who cannot move.
	if loaded != null and loaded.has_method("configure"):
		loaded.call("configure", map_seed(), DotRegistry.get_service(&"dot_random_source"))

	# A map that is a document is told which one, for the same reason and in the same place.
	if loaded != null and loaded.has_method("configure_doc"):
		loaded.call("configure_doc", str(map.meta.get("doc", "")))
	liquids = loaded.call("liquid_volumes") if loaded != null and loaded.has_method("liquid_volumes") else []
	_melting.clear()
	for id in players:
		(players[id] as PlaygroundPlayer).set_water(water_boxes())
	_index_panes(loaded)
	if config != null:
		panes_break = config.breakable_glass

	_build_toys(loaded)

	# Its props, once the boxes they stand on exist. The server's only: a client gets them
	# through the prop path like anything else anybody spawned.
	if authoritative and loaded != null and loaded.has_method("map_props"):
		spawn_map_props(loaded.call("map_props"), loaded.call("map_wires"))

	# The run timer's zones before anybody is spawned: a course's start is one of them.
	if run_timer != null:
		run_timer.call("on_map_changed", map, loaded)

	for id in players:
		spawn_player(id)

	DotLog.info(CHANNEL, "map ready", {
		"map": String(map.id),
		"players": players.size(),
	})

	map_ready.emit(map)


## The map ran out of time, or enough players rocked the vote.
##
## [b]The session says the map is over; deciding what happens next is here.[/b] A
## game might run a vote, show a scoreboard, finish the round first, or go straight
## to the rotation — and a session that changed the map itself would have to be
## fought by every game that wanted any of those.
##
## A run in progress is not protected: a map ending under somebody mid-run costs them
## that attempt, which is what a time limit means. Waiting for the last runner would
## mean a map that never ends while one person keeps restarting.
func _on_map_over(_map: DotMapDef, reason: StringName) -> void:
	if not rotation_ends_maps:
		DotLog.debug(CHANNEL, "the map clock ran out; the vote decides", {"reason": String(reason)})
		return

	var next := maps.rotation.choose(players.size())

	if next == null:
		DotLog.warn(CHANNEL, "the map is over and the rotation has nothing to offer")
		return

	DotLog.info(CHANNEL, "changing map", {
		"reason": String(reason), "to": String(next.id)
	})

	var changed: DotResult = await change_map(next.id)

	if not changed.ok:
		# Still on the old map, which is what dot-map's ordering guarantees. Restart
		# its clock rather than leaving a server that will never try again.
		DotLog.warn(CHANNEL, "the map change failed; extending instead", {
			"why": changed.error.message
		})
		maps.time_limit.extend(120.0)


## Registers a rock-the-vote from a player.
# --- Vehicles ---------------------------------------------------------------

## Turns each driver's movement keys into what their vehicle is being asked for.
##
## [b]The mapping is here and not in dot-vehicle, and that is where it belongs.[/b] A
## [DotVehicleCommand] is built by the game from a keyboard, a gamepad, a touch layout or
## a bot; the addon deliberately has no input at all. Reusing [DotFpsCommand] rather than
## adding a second wire format is the other half of the same decision — a client already
## sends one of those every tick, it is already sanitised, already replayed by the
## predictor and already quantised, and a driver's throttle is exactly as much a per-tick
## intent as a walk is.
func _drive_vehicles() -> void:
	if vehicles == null or vehicles.ride.rider_count() == 0:
		return

	for id in players:
		var player: PlaygroundPlayer = players[id]

		if not player.riding:
			continue

		var vehicle := vehicles.vehicle_of_rider(id)

		if vehicle == null or vehicle.driver() != id:
			# A passenger's keys do nothing, and the refusal is dot-vehicle's anyway:
			# `set_command` checks the driver on the server on every command, because a
			# client is a program the player can edit and driving from the back seat is
			# what that hole would give them.
			continue

		# S brakes while the car still rolls forward and reverses once it has stopped
		# (dot-vehicle's `brake_then_reverse`), the convention every driving game here
		# keeps; on reverse thrust alone it took about three times the brake's distance.
		# Here and not in `drive_command`, which has no vehicle to read a speed from.
		var cmd := drive_command(player.pending_command())
		vehicles.set_command(vehicle.instance_id, id, cmd.brake_then_reverse(vehicle.forward_speed()))


## One tick of driving, from one tick of movement input.
##
## Static and public because it is the whole mapping, and a suite that had to build a
## player to test it would be testing something else.
static func drive_command(move: DotFpsCommand) -> DotVehicleCommand:
	var cmd := DotVehicleCommand.new()

	if move == null:
		return cmd

	# W and S. `move.y` is forward in DotFpsCommand and +1 is forward in
	# DotVehicleCommand, so this is not a coincidence worth inverting.
	cmd.throttle = move.move.y
	# A and D. `move.x` strafes right and +1 steers right.
	cmd.steer = move.move.x

	# Crouch brakes and jump is the handbrake. Both are chosen so a player who gets into
	# a car with their fingers where they were still has a brake under one of them.
	cmd.brake = 1.0 if move.is_pressed(DotFpsCommand.BUTTON_CROUCH) else 0.0
	cmd.handbrake = move.is_pressed(DotFpsCommand.BUTTON_JUMP)

	cmd.aim_yaw = deg_to_rad(move.yaw)
	cmd.aim_pitch = deg_to_rad(move.pitch)

	return cmd.sanitise()


## The nearest vehicle a player could get into, or null.
##
## [b]Measured from the eye and not from the feet.[/b] A player standing beside a car is
## about 1.7 m above the point their body reports, and a reach measured from there is a
## reach that fails while they are looking straight at the door.
func vehicle_near(player_id: StringName, reach: float = 3.5) -> DotVehicleInstance:
	var player: PlaygroundPlayer = players.get(player_id)

	if player == null or vehicles == null:
		return null

	return vehicles.nearest_free(player.eye_position(), reach)


## Gets a player into whatever they are standing next to, or out of what they are in.
##
## [b]One entry point for both, because the player pressed one key.[/b] A game with
## separate "enter" and "exit" calls has a client deciding which one to send, and a
## client that guesses wrong asks to get into the car it is already in.
## What F does: presses the button, throws the lever or swings the door in front of the
## player, and otherwise gets in or out of a vehicle. One key, because both are "use" and the
## bridge already carries it (`ask_use_vehicle`), so pressing a button needs no new message.
func use_vehicle(player_id: StringName) -> DotResult:
	var player: PlaygroundPlayer = players.get(player_id)

	if player == null or vehicles == null:
		return DotResult.fail(DotError.CODE_STATE, "No such player.")

	if vehicles.vehicle_of_rider(player_id) == null:
		var used := use_prop(player_id)
		if used.ok:
			return used

	var riding := vehicles.vehicle_of_rider(player_id)

	if riding != null:
		return vehicles.ride.exit(riding, player_id)

	var near := vehicle_near(player_id)

	if near == null:
		return DotResult.fail(DotError.CODE_STATE, "There is nothing to get into.")

	return vehicles.ride.enter(near, player_id, player)


## Presses what [param player_id] is looking at within [constant USE_REACH]: a button fires
## `pressed`, a lever switches and fires `switched` with its new state, a door swings. Fails
## when there is nothing usable in front of them. On the authority only.
func use_prop(player_id: StringName) -> DotResult:
	var player: PlaygroundPlayer = players.get(player_id)

	if player == null or io == null or not authoritative or player.grav_gun == null or not player.is_inside_tree():
		return DotResult.fail(DotError.CODE_STATE, "Nothing to use.")

	# A toy looked at, before any prop: a kick, a push, a switch, a honk.
	var toy := toy_aimed(player)

	if toy >= 0 and toys.use(toy, player.eye_position(), player.aim_direction()):
		return DotResult.success(toys.toy(toy))

	var gun := player.grav_gun
	var reach := gun.reach
	gun.reach = USE_REACH
	var prop := gun.target(player.get_world_3d().direct_space_state, player.eye_position(), player.aim_direction())
	gun.reach = reach

	if prop == null or prop.def == null:
		return DotResult.fail(DotError.CODE_STATE, "Nothing to use.")

	if _doors.has(prop.instance_id):
		_set_door(prop, not bool(_doors[prop.instance_id]["open"]))
		return DotResult.success(prop)

	var outputs := DotPropIO.outputs_of(prop.def)

	if outputs.has("pressed"):
		var _heard := io.fire(prop.instance_id, &"pressed")
		return DotResult.success(prop)

	if outputs.has("switched"):
		var on := not bool(_levers.get(prop.instance_id, false))
		_levers[prop.instance_id] = on
		if prop.node is PlaygroundProp:
			(prop.node as PlaygroundProp).set_tint(Color(0.3, 0.8, 0.35) if on else Color(0.8, 0.3, 0.3))
		var _heard := io.fire(prop.instance_id, &"switched", on)
		return DotResult.success(prop)

	return DotResult.fail(DotError.CODE_STATE, "Nothing to use.")


## An input reached a prop through a wire. A door is the one that hears: `open`, `close`, and
## `toggle`, which a button (no value) flips and a lever (its on/off) sets.
func _on_io_input(target: DotPropInstance, input: StringName, value: Variant, _source: DotPropInstance) -> void:
	if not _doors.has(target.instance_id):
		return

	var open: bool = _doors[target.instance_id]["open"]

	match input:
		&"open":
			open = true
		&"close":
			open = false
		&"toggle":
			open = bool(value) if value is bool else not open

	_set_door(target, open)


func _set_door(prop: DotPropInstance, open: bool) -> void:
	var state: Dictionary = _doors.get(prop.instance_id, {})

	if state.is_empty() or bool(state["open"]) == open:
		return

	# Shut and about to open: where it stands now is where it swings from.
	if open and float(state["t"]) <= 0.0 and prop.node is Node3D:
		state["base"] = (prop.node as Node3D).global_transform

	state["open"] = open


## Every door moving toward where it was told, about the hinge on its left edge, written as a
## transform: frozen, so nothing else moves it. Says `opened` / `closed` on arriving.
func _swing_doors(step: float) -> void:
	if _doors.is_empty() or props == null:
		return

	for instance_id: int in _doors.keys():
		var prop := props.get_prop(instance_id)
		var state: Dictionary = _doors[instance_id]

		if prop == null or not prop.is_alive() or not (prop.node is Node3D) or not prop.frozen:
			continue

		var target := 1.0 if bool(state["open"]) else 0.0
		var t := float(state["t"])

		if is_equal_approx(t, target):
			continue

		t = move_toward(t, target, step / DOOR_SECONDS)
		state["t"] = t
		var width := PlaygroundProp.extent_of(prop.def).x
		var pivot := Vector3(-width * 0.5, 0.0, 0.0)
		var swing := Transform3D(Basis(Vector3.UP, deg_to_rad(90.0) * t), Vector3.ZERO)
		var local := Transform3D(Basis.IDENTITY, pivot) * swing * Transform3D(Basis.IDENTITY, -pivot)
		(prop.node as Node3D).global_transform = (state["base"] as Transform3D) * local

		if is_equal_approx(t, target):
			var _said := io.fire(instance_id, &"opened" if target > 0.5 else &"closed")


## Whether the door [param instance_id] is open (or opening). For the suites and `describe`.
func door_is_open(instance_id: int) -> bool:
	return bool(_doors.get(instance_id, {}).get("open", false))


func door_swing(instance_id: int) -> float:
	return float(_doors.get(instance_id, {}).get("t", 0.0))


func rock_the_vote(player_id: StringName) -> bool:
	return maps.rock_the_vote(player_id, players.size())


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"map": String(maps.current.id) if maps != null and maps.current != null else "-",
		"players": players.size(),
		"props": props.world_count() if props != null else 0,
		"tick_rate": tick_rate,
		"time_left": time_left_text(),
		"run_timer": run_timer.call("describe") if run_timer != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("map          %s" % (
		String(maps.current.id) if maps != null and maps.current != null else "-"
	))
	out.append("players      %d" % players.size())
	out.append("props        %d" % (props.world_count() if props != null else 0))
	out.append("tick rate    %d%s" % [
		tick_rate,
		"" if run_timer == null or tick_rate == Engine.physics_ticks_per_second
			else " (DISAGREES with the engine's %d)" % Engine.physics_ticks_per_second,
	])
	out.append("time left    %s" % time_left_text())

	for id in players:
		out.append("  %s" % str((players[id] as PlaygroundPlayer).describe()))

	return out


## The map's time left as an operator should read it: the vote's clock when there is a
## vote — "no limit" when that vote has none, "stopped" while a ballot holds it or it has
## run out — and the map session's otherwise.
##
## "no limit" here where the HUD shows nothing: a status line is read when somebody asks,
## and an absent row reads as a diagnostic that forgot to say, not as a clock that is off.
func time_left_text() -> String:
	if clock_fn.is_valid():
		var state: Dictionary = clock_fn.call()

		if not bool(state.get("has_clock", false)):
			return "no limit"

		var total := int(state.get("seconds_left", 0))
		return "%d:%02d%s" % [
			total / 60, total % 60, "" if bool(state.get("running", false)) else " (stopped)"
		]

	return maps.time_limit.formatted_remaining() if maps != null else "-"


func _exit_tree() -> void:
	DotRegistry.unregister_instance(DotRegistry.scoped_name(SERVICE, service_scope), self)
	if addons != null:
		addons.release()
	if profiles != null:
		profiles.release()


## The player's motor mask under `mp_solidplayers`, and the standing hull the others stop at
## (a player's body has no shape of its own): with the rule on, somebody walking into you
## stops at your shoulder instead of filling your screen. Through `apply_to`, which goes
## through `set_collision_mask` (a style does not undo it) and makes the players' layer one a
## player may walk out of.
func _apply_body_mask(player: PlaygroundPlayer) -> void:
	if player_stack == null or player == null or player.controller == null:
		return
	var layout: DotPhysicsLayout = player_stack.physics.layout if player_stack.physics != null else null
	var players_layer := layout.layer_mask(&"player") if layout != null else 0
	body_rules.apply_to(player.controller, player_stack.player_collision_mask(), players_layer)
	var tunables := player.controller.tunables
	body_rules.apply_hull(player, tunables.stand_height, tunables.radius)


## `mp_solidplayers` changed: every player's mask and hull now.
func _on_body_rules_changed() -> void:
	for id in players:
		_apply_body_mask(players[id] as PlaygroundPlayer)

