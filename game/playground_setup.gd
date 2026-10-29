extends Node3D

const PlaygroundAmbience := preload("playground_ambience.gd")
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
const PlaygroundUndo := preload("playground_undo.gd")

## The playground: a sandbox on a flat grass plate with spawnable props and a physics gun. Any map a server adds plays here too;
## a run timer comes only from `addons/pg_timer` (see [member run_timer]). Nothing is networked here: the bridge is dot-net's.
## The one place every movement-half addon runs together, and the seams between them are where the bugs are: `examples/headless_playground.tscn` runs the joins.

const CHANNEL := "playground"

## The registry name a dot-server module finds this under: a module is loaded by path, and a path cannot carry an instance.
const SERVICE := &"playground"

## The map changed and everything has been rebuilt against it.
signal map_ready(map: DotMapDef)

## The first map, if any, is up. Check [member booted] first: [method change_map] may finish without suspending, so this has
## already fired before a caller reaches its `await` and the `await` never returns. A signal is not a state.
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

## A shot, blast or blow took health off a body, a breakable prop or a pane: the authority's confirmation (never a prediction)
## the shooter's hit marker is drawn from, sent to the shooter alone. [param victim] only groups hits on one thing
## ([method hit_victim_id]); [param point] is where the number goes up. Fed from the four damage sites ([method confirm_hit]).
signal hit_landed(player_id: StringName, victim: int, amount: float, point: Vector3, killed: bool, headshot: bool)

## Somebody walked over a weapon lying in the world. The bridge gives it to them on a
## server; the client equips it offline.
signal weapon_picked_up(player_id: StringName, weapon_id: StringName)

## Somebody finished a timed run of [param time] seconds; [param rank] is 0 when not filed and [param reason] says why. Emitted
## only by a run timer (see [member run_timer]). A time rather than dot-timer's run object, because this file must compile
## with the timer absent.
signal run_filed(player_id: StringName, time: float, rank: int, reason: String)

@export_group("Content")

## Layered configuration, created with the defaults if left empty. A config rather than exports on this node, because a
## dedicated server is configured by somebody not opening the editor. See [PlaygroundConfig].
@export var config: PlaygroundConfig = null

## A JSON file to layer over [member config]'s defaults, or empty for none.
@export var config_file: String = ""

@export_group("Role")

## Simulation ticks per second. The engine's rate wins whenever dot-server has set it from `sv_tickrate` (see
## [method _resolve_tick_rate]); the export is the fallback for a client or test with no server to ask.
## It stamps every record a run timer files, which is what lets a disputed time be checked.
@export_range(1, 240, 1) var tick_rate: int = 128

## Registry scope, so a server game and a client game can share one process (every headless netcode test does). Without it
## both register under one name and a lookup of `playground` silently reaches whichever booted last.
@export var service_scope: StringName = &""

## Whether this instance is the authority: it times, it ranks, it spawns props. Derived from [member PlaygroundConfig.authoritative]
## on ready rather than exported beside it, so the two cannot disagree. A client leaves it false and runs its own copy for its HUD.
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

## [param who] undid something (a prop, or a disaster an addon registered); [param at] is where it was, or zero. Fires on
## the authority, and on a client when the authority says so, so a client plays its own player's cue from this.
signal undone(who: StringName, at: Vector3)

## What each player may undo, props and addon-made things in spawn order. See [PlaygroundUndo].
var undo_stack: PlaygroundUndo = null

## Whether [signal ready_for_players] has been emitted. See that signal.
var booted: bool = false

var maps: DotMapSession = null

## Whether the map session's own clock running out changes to the rotation's next map. On for a sandbox with no vote; off once
## [code]PlaygroundModule[/code] has a ballot, because both acting ended a map the players had voted to extend on the old clock.
var rotation_ends_maps: bool = true

## The clock that ends a map, as [method DotVoteClockView.state_of] describes it; set by [code]PlaygroundModule[/code], unset on a sandbox with no vote.
## A Callable rather than the vote, because the game does not know the vote exists. [method time_left_text] (so `pg_status` and
## [method describe]) reads it: reading the session's clock instead showed a limit an extend had already moved.
var clock_fn: Callable = Callable()

## The run timer, or null: the game ships none. `addons/pg_timer`'s hook attaches a `DotTimerManager` through [method attach_run_timer]
## only when `addons/dot_timer` is present. Untyped and called by name, because every script must compile without dot-timer;
## every call is guarded on null.
var run_timer: Object = null
var props: DotPropSpawner = null

## The vehicles. Every one of them is also a [DotPropInstance] in [member props] — see
## [PlaygroundVehicles] for why both, and [PlaygroundSpawnables.Kind.VEHICLE] for the
## one field of `meta` that joins them.
var vehicles: DotVehicleSpawner = null
var boards: DotLeaderboardManager = null
## Where the boards live; null builds one layered from [constant BOARDS_CONFIG_PATH].
var boards_config: DotBoardsConfig = null

const BOARDS_CONFIG_PATH := "user://playground_boards.json"


## The scripted spawnables in the world, ticked every simulated tick. A list beside the spawner's rather than a walk over it,
## which would ask a thousand props a hundred and twenty-eight times a second whether they are an NPC.
var entities: Array[PlaygroundEntity] = []

## What the entities can perceive, shared by all of them: dot-npc's [DotNpcSenses], which acquires at one threshold and drops at a weaker one.
## "Nearest player" recomputed per tick made a chaser turn back and forth between two players and forget one behind a pillar.
## One object for the world because its tuning is the world's; how far a thing can see belongs on its catalogue entry.
var npc_senses: DotNpcSenses = null

## How good every NPC is, server-wide: `npc_skill`, `npc_reaction_scale`, `npc_reaction_min`, bound by the module. On the world because
## both the waves' spawner and a sandbox hunter built by the spawn menu need it, and neither owns the other.
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

## The players as [DotNpcSenses.Candidate]s, rebuilt once per simulated tick and not once per entity: twenty NPCs would each build
## their own identical list.
var npc_candidates: Array = []

## What a player may hold. See [PlaygroundWeapons].
var weapons: Array[PlaygroundWeaponDef] = []

## What every player is carrying: prepaid props, a grid and a weight (see [PlaygroundInventory], [PlaygroundInventoryNet]).
## The game's on both ends: a server holds one bag per person and decides, a client holds its OWN bag and predicts.
var inventory: PlaygroundInventory = null

## The node loaded maps and spawned props are put under.
var world: Node3D = null

## Who is in the session, which side, what class, where they start, and the physics. See [PlaygroundPlayerStack]. Built last and
## binds to everything else; it adds no authority, it keeps one set of records in step so a scoreboard, a spectator seat and a
## start selector read the same thing.
var player_stack: PlaygroundPlayerStack = null

## Every world object this game has an id for ([DotEntityTable]), opened on join by the game and not by whichever layer needs an id
## first: otherwise a player had two entity ids depending on which layers were enabled. Named `entity_table` because
## [member Playground.entities] is the sandbox's own list of spawned `PlaygroundEntity`s; the day the two concepts merge this takes the name.
var entity_table := DotEntityTable.new()

## What a dead body does, and which death reactions the server allows: dot-player-char's
## `sv_ragdoll*` cvars, bound by the module (REPLICATED) and followed by a client through its
## link, because the client draws the bodies. Decided with by [method PlaygroundArena.decide_death].
var ragdoll_rules: DotPlayerRagdollRules = DotPlayerRagdollRules.new()

## The current map's toys (dot-props' [DotPropToyBox]): built from `map_toys()` on both ends, simulated where [member authoritative] and
## posed from snapshots on a client. A child of this node, not of the map, whose tree is classified onto `world` and would take every
## toy with it. Null before a map.
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

## dot-player-controller's `mp_forceview` and `mp_solidplayers`, and the ambience cvars (`pg_ambient*`): bound by the module
## (REPLICATED) and followed by a client through its link.
var ambient_rules: DotAmbienceRules = PlaygroundAmbience.make_rules()
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()

## Binds [member config] to cvars, the cfg/ yml layers and the workbench; made by `_ready`.
var config_binder: DotGameConfigBinder = null

## dot-team's block rules (`!block`, `!noblock`, `mp_teamblock`), set by the server module or
## `DotGameClient.add_noblock`. They feed [member body_rules]'s `pair_fn`.
var block_rules: Object = null:
	set(value):
		if block_rules != null and block_rules.is_connected(&"changed", body_rules.refresh):
			block_rules.disconnect(&"changed", body_rules.refresh)
		block_rules = value
		if block_rules != null and block_rules.has_signal(&"changed"):
			block_rules.connect(&"changed", body_rules.refresh)

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


## The fastest a prop rises through a liquid under its own buoyancy, m/s. See
## [method _float_props].
const RISE_SPEED := 2.0


## Who a map's own props belong to. Not a player id (one is `u<n>`), so no player's limits,
## undo or "remove mine" reach them, and the map change that clears every prop clears them.
const MAP_OWNER := &"map"


## Every waypoint placed, in the order placed. See [method nearest_waypoint].
var waypoints: Array = []


## `func(victim: StringName, amount: float) -> bool`: hurts a player standing in a hazard (lava) and says whether it did. The module sets it to
## the arena's `hurt` while the arena is on; unset or false, a hazard sends the player back to the spawn, so a sandbox where nobody can be hurt still says "not in there".
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


## The server's maps.yml, or null when there is none (every map rotates, as it always did).
var rotation_file: DotMapRotationFile = null


## Where a checkout links game-playground-maps' documents.
const CUSTOM_MAPS_DIR := "res://maps/custom"

## The one scene every map document is built by. See `maps/pg_data.gd`.
const DATA_MAP_SCENE := "res://maps/pg_data.tscn"


## match id -> record key, for the players who have one. See [method record_key].
var _record_keys: Dictionary = {}
## record key -> match id, the other way, for what a run timer reports back.
var _match_ids: Dictionary = {}


## How close two players may stand at a spawn, and how far one may be stepped aside.
const SPAWN_SPACING := 1.5
const SPAWN_RINGS := 2

## What a person weighs on a see-saw, kg.
const PERSON_MASS := 70.0

## How far the use key reaches a toy: a ball at your feet, a switch at arm's length.
const TOY_REACH := 2.6

## A grenade's or a barrel's blast at its centre, m/s to a toy of up to 3 kg.
const TOY_BLAST_SPEED := 12.0


## A toy made a sound (a bounce, a knock, a switch, a honk), on whichever end drew it: what the
## presentation plays.
signal toy_sound(id: StringName, at: Vector3, strength: float)


## How many [method next_seed]s have been handed out. Never reset, so a second round does not
## replay the first.
var _seed_serial: int = 0


## Finds the addons folder's hooks. After the world, so a hook may parent nodes under it.
func _build_addons() -> void:
	addons = PlaygroundAddons.new()
	addons.message.connect(func(addon: String, body: Dictionary) -> void:
		addon_message.emit(addon, body)
	)
	undo_stack = PlaygroundUndo.new()
	undo_stack.attach(props)
	addons.undo_sink = undo_stack.push
	undo_stack.undone.connect(_on_undone)
	addons.undo_heard.connect(func(who: StringName, at: Vector3) -> void: undone.emit(who, at))
	profiles = PlaygroundProfiles.new()
	profiles.setup(profile_roots)
	profiles.apply_npcs(props.catalogue)
	profiles.runtime.profile_changed.connect(_on_profile_changed)
	addons.profiles = profiles
	var count := addons.scan(self, authoritative)
	var providers := addons.scan_providers(self)
	DotLog.info(CHANNEL, "addons folder scanned", {"hooks": count, "providers": providers, "plain": addons.skipped().size()})


## Undoes [param who]'s newest spawn, prop or disaster. False when there is nothing to undo.
func undo(who: StringName) -> bool:
	return undo_stack != null and undo_stack.undo(who)


func _on_undone(who: StringName, at: Vector3) -> void:
	undone.emit(who, at)
	addon_message.emit(PlaygroundAddons.UNDO_ADDON, {"undo": String(who), "at": [at.x, at.y, at.z]})


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


## Stands up the player-facing addons and binds them to this game, after the maps: it reads the start points the map session
## loads, and a stack built before them binds to nothing and reports success.
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


## The rate everything counts in: the engine's when a server has set it (`sv_tickrate` into `Engine.physics_ticks_per_second`), else the
## export, a rendering default on a client or test. Every record is stamped with it, so a server retuned from 64 to 128 would
## otherwise file times against 64 with no error anywhere.
func _resolve_tick_rate() -> int:
	var engine_rate := Engine.physics_ticks_per_second

	if engine_rate > 0:
		return engine_rate

	return tick_rate


func _build_styles() -> void:
	for style in DotFpsStyle.defaults():
		movement_styles[style.id] = style
		style_order.append(style.id)


func _build_leaderboards() -> void:
	boards = DotLeaderboardManager.new()
	boards.name = "Leaderboards"
	if boards_config == null:
		boards_config = DotBoardsConfig.for_game("playground")
		var layered := boards_config.load_layered(BOARDS_CONFIG_PATH)
		if not layered.ok:
			DotLog.warn(CHANNEL, "the boards configuration is not usable, using memory", {
				"why": str(layered.error),
			})
			boards_config = DotBoardsConfig.for_game("playground")
	boards.backend = boards_config.backend
	# Off by default: publishing sends player names and times off the server, and
	# that is an operator's decision rather than a default.
	boards.report_to_backbone = config.report_to_backbone
	add_child(boards)

	# No boards are defined here: the game ranks nothing by itself. A run timer defines its
	# own (`fastest`, `top_speed`, `points`) when a server adds one.


## Builds a spawned prop's body from the definition it came from. Connected rather than done in a subclass of [DotPropSpawner],
## because overriding the spawner would mean re-implementing the budget, the cooldown and the undo stack to reach one line.
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


## Puts a spawned body on the layer that matches what it is. `sandbox_3d` is the one preset with `held_prop` and `frozen_prop`: a
## carried prop must not collide with its carrier (it shoves them down a corridor) and a frozen one is scenery everything is solid against.
## Spawn time only: dot-props has no signal for freezing or grabbing, so `PlaygroundProp` calls `reclassify` when it changes state.
func _classify_spawned(prop: DotPropInstance) -> void:
	if player_stack == null or prop.node == null:
		return

	var _put := player_stack.classify(prop.node, layer_for(prop.def, prop.frozen))


## The collision layer a spawned body of [param def] belongs on. One answer for both ends: the server's spawn and a client's mirror
## (`PlaygroundNetBridge._apply_prop`) read it, because a mirror on a different layer collides with a different world from the server's.
static func layer_for(def: DotPropDef, frozen: bool) -> StringName:
	match PlaygroundSpawnables.kind_of(def):
		PlaygroundSpawnables.Kind.ENTITY:
			return &"npc"
		PlaygroundSpawnables.Kind.VEHICLE:
			return &"vehicle"
		_:
			return &"frozen_prop" if frozen else &"prop"


## Re-reads a prop's layer after it was frozen, unfrozen, grabbed or dropped. Public because dot-props has no signal for those
## states, so the code that changes the state is the code that has to say so.
func reclassify_prop(node: Node, frozen: bool, held: bool) -> void:
	if player_stack == null or node == null:
		return

	var layer := &"prop"

	if held:
		layer = &"held_prop"
	elif frozen:
		layer = &"frozen_prop"

	var _put := player_stack.classify(node, layer)


## Turns a spawned body into a scripted entity by attaching the script its definition names: the whole "an entity has a script" mechanism.
## The script comes from `meta`, loaded by PATH because a mounted dot-cloud pack's `class_name` globals are not registered in the host.
## [method Node._ready] has already run by now, hence `_entity_ready`. A failure removes the prop: a script-less body is a crate, which looks like an NPC with nothing to do.
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

	# set_script itself errors on a script whose native base is not this body's.
	if not ClassDB.is_parent_class(body.get_class(), String(script.get_instance_base_type())):
		DotLog.error(CHANNEL, "an entity's script is not an entity", {
			"entity": String(prop.def.id),
			"script": PlaygroundSpawnables.script_of(prop.def),
			"hint": "extend res://game/entities/playground_entity.gd",
		})
		props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)
		return

	body.set_script(script)

		# Checked after attaching rather than assumed: a script that is valid GDScript but extends the wrong thing attaches and then lacks
		# the methods the tick calls, and the crash lands in the simulation loop, far from the catalogue entry that caused it.
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


## Makes a spawned prop a vehicle as well. Configured before adopted, and the order is load-bearing: [DotVehicleWheeled] walks the
## body's direct children for wheels once, when the chassis binds, so wheels built after adoption are four that nothing drives,
## steers or brakes.
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


## Drops an entity from the tick list when its prop goes. Connected to the spawner's own signal rather than checked per tick;
## `removed` is emitted BEFORE the node is freed so a listener can let go while the reference still exists.
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
		# Looked up by NODE, not by the prop's instance id. dot-props and dot-vehicle both
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


func unregister_armed_npc(entity: Node) -> void:
	armed_npcs.erase(entity)


func _prop_catalogue() -> DotPropCatalogue:
	if config.props_path != "":
				# An operator's own catalogue, the seam between a game with a handful of props and a server with a content pack. Loaded here
				# rather than layered over the built-in list: a merged catalogue would give every server these fourteen with no way to remove one.
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


func _clock_seconds() -> float:
	return float(_tick) / float(maxi(tick_rate, 1))


## The seed a generated map is built from. Zero means "pick one and announce it": a world nobody can name the seed of cannot be
## shared. `pg_seed` is the cvar and the seed used is logged either way. Taken from dot-randomness when a game has one, so a
## generated map and every other random thing in the session come from one seed.
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


## A stable seed for the next thing wanting its own randomness (a scripted entity's [member DotNpcInstance.seed], a broken prop's
## debris): the session's [method map_seed] and a count of what has asked, a stream per kind. Never an object id, which moves
## whenever anything earlier allocates and made NPCs and debris move differently build to build. Always above 1: dot-npc-ai reads 0 or 1 as the preset's.
func next_seed(kind: StringName) -> int:
	_seed_serial += 1
	return DotRandomStream.new(map_seed()).stream_for(kind, _seed_serial).range_i_at(0, 2, 0x7FFFFFFF)
