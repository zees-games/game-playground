extends RefCounted

const PlaygroundPaths := preload("playground_paths.gd")

const PlaygroundVehicles := preload("playground_vehicles.gd")
const PlaygroundZee := preload("playground_zee.gd")

## Everything this build can put in the world, and what kind of thing each one is.
##
## [b]A prop is inert and an entity has a script.[/b] That is the sandbox's own
## division and it is the right one: a crate is a shape with a mass, and a thing that
## walks about needs code. dot-props does not know the difference and does not need
## to — it instantiates a scene, places it, and counts it against a budget — so the
## difference lives in [member DotPropDef.meta] and is applied by [Playground] on
## spawn.
##
## [codeblock]
## { "kind": "entity", "script": "res://game/entities/npc_wanderer.gd" }
## [/codeblock]
##
## [b]The script is named by PATH, and that is not a style choice.[/b] A game
## delivered through dot-cloud is a mounted `.pck`, and **a mounted pack's
## `class_name` globals are not registered in the host** — measured, and written down
## in game-dev/docs/bugs-found.md. So every cross-file type reference inside a pack
## fails to compile and the pack's scripts are dead, while `preload("res://x.gd")` and
## `extends "res://x.gd"` both work. A catalogue that named a class could therefore
## only ever ship inside the build. Naming a path is what makes an entity deliverable,
## and it is why the entities here `extends "res://game/entities/playground_entity.gd"`
## rather than `extends PlaygroundEntity` — they are the template a pack copies, so
## they are written the way a pack has to be.

const CHANNEL := "playground.spawnables"

## The scene an inert prop is built into. Carries [PlaygroundProp] already.
static var SCENE_PROP := PlaygroundPaths.rebase("res://game/prop.tscn")

## The scene an entity is built into: a bare [RigidBody3D] whose script comes from the
## definition. Bare, because attaching one here would mean every entity replaced it.
static var SCENE_ENTITY := PlaygroundPaths.rebase("res://game/entity.tscn")

enum Kind {
	## A shape with a mass. No code.
	PROP,
	## A prop with a script attached at spawn, ticked by the simulation.
	ENTITY,
	## A prop that is also a [DotVehicleInstance]: it has seats and it drives.
	##
	## [b]Still a prop, and that is the decision.[/b] It counts against the same budget,
	## it is on the same undo stack, it goes when its owner leaves, and a gravity gun can
	## punt it — because a car you cannot punt is not a sandbox car. What being a vehicle
	## adds is a chassis and the handover, and both are dot-vehicle's.
	VEHICLE,
}


## What kind of thing a definition describes. Anything unrecognised is a prop.
##
## Defaulting to PROP rather than refusing: a catalogue written for an older build, or
## by an operator who has not heard of entities, is a catalogue of props — which is
## both true and the safe reading, because the failure mode of guessing "entity" is a
## script path that does not exist.
static func kind_of(def: DotPropDef) -> Kind:
	if def == null:
		return Kind.PROP

	match str(def.meta.get("kind", "prop")).to_lower():
		"entity", "npc":
			return Kind.ENTITY
		"vehicle":
			return Kind.VEHICLE
		_:
			return Kind.PROP


## The script an entity runs, or empty.
static func script_of(def: DotPropDef) -> String:
	return str(def.meta.get("script", "")) if def != null else ""


## Loads an entity's script, or null with a reason logged.
##
## [b]Every failure here is loud.[/b] A script that does not load leaves a body that
## sits there being a crate, which is indistinguishable from an NPC that has nothing
## to do — and "the NPC does not move" would send somebody to the movement code.
static func load_script(def: DotPropDef) -> GDScript:
	var path := script_of(def)

	if path == "":
		DotLog.error(CHANNEL, "an entity has no script", {"entity": String(def.id)})
		return null

	if not ResourceLoader.exists(path):
		DotLog.error(CHANNEL, "an entity's script is not there", {
			"entity": String(def.id), "script": path
		})
		return null

	var res: Resource = load(path)

	if not (res is GDScript):
		DotLog.error(CHANNEL, "an entity's script is not a script", {
			"entity": String(def.id), "script": path
		})
		return null

	return res as GDScript


# --- The built-in catalogue -------------------------------------------------

## Everything this build ships: fourteen props and four entities.
##
## [b]Enough to build something, which is the point of a sandbox.[/b] Four props are a
## demonstration; a plank, a panel, a beam and a pillar are a set somebody can make a
## house out of, and the spawn menu needs categories to be worth having at all.
##
## Every prop is [code]res://game/prop.tscn[/code] and every entity is
## [code]res://game/entity.tscn[/code]; what differs is the definition. See
## [PlaygroundProp] for what `meta` means and why it is done that way.
##
## [b]The masses are the interesting column.[/b] They are what a physics gun's
## `grab_mass_limit` is checked against and what a gravity gun's punt is divided by, so
## a beach ball that is bigger than a boulder and a fortieth of its weight is the one
## entry that proves both tools read it.
## Kilograms per cubic metre for the props that must sink: rock and concrete.
const DENSE := {&"boulder": 2600.0, &"slab": 2400.0, &"pillar": 2400.0, &"die": 1200.0}


## The stock model packs, one folder per kit under assets/props (each with a props.json that
## carries the credit, the scale and a baked extent so nothing is measured at start).
const STOCK_KITS: Array[String] = ["furniture", "food", "survival", "nature", "market"]


## [param base] plus the stock model packs plus whatever is in [param drop_dir].
static func with_models(base: DotPropCatalogue, drop_dir: String) -> DotPropCatalogue:
	for kit in STOCK_KITS:
		var dir := PlaygroundPaths.rebase("res://assets/props/%s" % kit)
		var res := DotPropFolder.load_into(base, dir, SCENE_PROP, {"measure": false})
		if not res.ok:
			DotLog.warn(CHANNEL, "a stock prop pack was not read", {"kit": kit, "why": res.error.message})

	add_drop_ins(base, drop_dir)
	return base


## Models in [param drop_dir] that are not in [param catalogue] yet. A dropped file never
## replaces a built-in (the loader's default), so it cannot take over an id a client trusts.
static func add_drop_ins(catalogue: DotPropCatalogue, drop_dir: String) -> PackedStringArray:
	if drop_dir == "":
		return PackedStringArray()

	var res := DotPropFolder.load_into(catalogue, drop_dir, SCENE_PROP, {"category": "custom"})
	if not res.ok:
		DotLog.warn(CHANNEL, "the prop drop-in folder was not read", {"dir": drop_dir, "why": res.error.message})
		return PackedStringArray()

	return (res.value as Dictionary)["added"]


static func catalogue() -> DotPropCatalogue:
	var out := DotPropCatalogue.new()

	# id, name, category, shape, extent, colour, mass kg, cost, size
	var props := [
		[&"plank", "Plank", &"construction", "box", Vector3(3.0, 0.15, 0.6),
			"c9a227", 30.0, 1, DotPropDef.Size.SMALL],
		[&"beam", "Beam", &"construction", "box", Vector3(6.0, 0.4, 0.4),
			"8a6a3a", 80.0, 2, DotPropDef.Size.MEDIUM],
		[&"panel", "Panel", &"construction", "box", Vector3(4.0, 0.1, 4.0),
			"6f7480", 60.0, 2, DotPropDef.Size.MEDIUM],
		[&"slab", "Slab", &"construction", "box", Vector3(6.0, 0.6, 6.0),
			"4a4e57", 400.0, 4, DotPropDef.Size.LARGE],
		[&"pillar", "Pillar", &"construction", "cylinder", Vector3(1.0, 4.0, 1.0),
			"7d8189", 120.0, 2, DotPropDef.Size.MEDIUM],
		[&"platform", "Platform", &"construction", "box", Vector3(4.0, 0.4, 4.0),
			"46586a", 300.0, 3, DotPropDef.Size.LARGE],

		[&"crate", "Crate", &"containers", "box", Vector3(1.0, 1.0, 1.0),
			"b8873f", 20.0, 1, DotPropDef.Size.SMALL],
		[&"crate_large", "Large crate", &"containers", "box",
			Vector3(2.0, 2.0, 2.0), "9c7134", 90.0, 2, DotPropDef.Size.MEDIUM],
		[&"barrel", "Barrel", &"containers", "cylinder", Vector3(1.0, 1.4, 1.0),
			"3f6a55", 40.0, 1, DotPropDef.Size.SMALL],
		[&"can", "Can", &"containers", "cylinder", Vector3(0.4, 0.5, 0.4),
			"9aa3ad", 4.0, 1, DotPropDef.Size.TINY],

		[&"ball", "Ball", &"toys", "sphere", Vector3(1.0, 1.0, 1.0),
			"c25b4a", 8.0, 1, DotPropDef.Size.TINY],
		[&"beach_ball", "Beach ball", &"toys", "sphere", Vector3(2.4, 2.4, 2.4),
			"e0c14a", 2.0, 1, DotPropDef.Size.SMALL],
		[&"boulder", "Boulder", &"toys", "sphere", Vector3(3.0, 3.0, 3.0),
			"5b5750", 900.0, 3, DotPropDef.Size.LARGE],
		[&"die", "Die", &"toys", "box", Vector3(0.8, 0.8, 0.8),
			"ddd6c8", 12.0, 1, DotPropDef.Size.TINY],
	]

	for row in props:
		var prop := DotPropDef.make(row[0], SCENE_PROP)
		# Breakable only with `destruction` on (PlaygroundConfig); the health is always
		# declared, so turning it on needs nothing but the switch.
		prop.max_health = float(BREAKABLE.get(row[0], 0.0))
		prop.display_name = row[1]
		prop.category = row[2]
		prop.mass = row[6]
		prop.cost = row[7]
		prop.size = row[8]
		prop.meta = {
			"shape": row[3],
			"extent": [row[4].x, row[4].y, row[4].z],
			"colour": row[5],
		}
		# Densities the solver's masses do not give: these are tuned for a physics gun, and by
		# them a 3 m boulder is lighter than water. What a liquid floats or sinks is asked of
		# this when it is there (Playground._float_props).
		if DENSE.has(row[0]):
			prop.meta["density"] = DENSE[row[0]]
		if row[0] == &"barrel":
			# Shot open, it goes up: the arena's damage on whoever is beside it, and a
			# shove for everything loose.
			prop.explode_radius = 5.0
			prop.explode_damage = 60.0
			prop.explode_force = 300.0
		out.add(prop)

	# id, name, script, extent, colour, mass kg, cost, meta
	#
	# Entities cost more than props of the same size on purpose: each one runs a
	# script every tick and a budget counted only in physics would let a player fill
	# a server with things that are cheap to simulate and expensive to think.
	var entities := [
		[&"npc_wanderer", "Wanderer", "npc_wanderer", Vector3(0.8, 1.7, 0.8),
			"5d8fb8", 70.0, 3, {}],
		[&"npc_chaser", "Chaser", "npc_chaser", Vector3(0.9, 1.8, 0.9),
			"b8565d", 80.0, 4,
			{
				"speed": 5.0,
				# The perception envelope, read by dot-npc through
				# `PlaygroundEntity._make_npc`. `sight` replaced a `give_up_range` that
				# the chaser applied by hand: giving up is now what happens when a
				# target leaves the envelope and the commitment grace expires, which
				# also gets the hysteresis and the memory that the hand-rolled version
				# never had.
				"sight": 40.0,
				"sight_angle": 150.0,
				"hearing": 14.0,
			}],
		[&"npc_hopper", "Hopper", "npc_wanderer", Vector3(0.7, 0.9, 0.7),
			"6fae7a", 30.0, 2, {"speed": 2.5, "hop": 4.5, "turn_seconds": 1.2}],
		[&"turret_spinner", "Spinner", "npc_spinner", Vector3(1.6, 0.5, 1.6),
			"c9a227", 200.0, 3, {"rpm": 90.0, "shove": 9.0}],
		# The same NPC as `npc_chaser`, with a **decision** instead of an `if`: dot-npc-ai's
		# state machine and the arena shooters' characteristics table. Both are in the catalogue
		# deliberately — the cheap one is for filling a room with and the expensive one is
		# for the arena, and keeping both is the only honest way to say what the addon
		# actually bought. `skill` is a per-NPC character rather than a server difficulty,
		# which is dot-npc-ai's whole claim.
		[&"npc_hunter", "Hunter", "npc_hunter", Vector3(0.9, 1.8, 0.9),
			"c05a9a", 85.0, 6,
			{
				"speed": 5.4,
				"skill": "normal",
				"sight": 45.0,
				"sight_angle": 140.0,
				"hearing": 16.0,
				"give_up_seconds": 3.0,
			}],
		[&"npc_hunter_hard", "Hunter (hard)", "npc_hunter", Vector3(0.9, 1.8, 0.9),
			"e0483f", 85.0, 8,
			{
				"speed": 6.2,
				"skill": "hard",
				"sight": 55.0,
				"sight_angle": 160.0,
				"hearing": 20.0,
				"give_up_seconds": 4.5,
			}],
	]

	# Armed NPCs: dot-npc-ai's tactical brain with a zee weapon in hand. What they carry is
	# the player's choice on the entities tab, or `weapon` here when they made none. A
	# soldier is on `hostile` and fights players and rebels; a rebel is on `player`, never
	# targets one, fights soldiers and follows whoever spawned it.
	var armed := {
		"health": 100.0, "speed": 4.6, "sight": 50.0, "sight_angle": 150.0,
		# No line-of-sight cast, as for every NPC in this sandbox: the cast ends at the
		# other NPC's centre, inside its own body, and the props layer it is on blocks it —
		# so two armed NPCs on open ground never saw each other.
		"hearing": 18.0, "line_of_sight": 0.0, "near": 8.0, "far": 18.0, "reach": 1.6,
		"armed": true,
	}
	entities.append([&"npc_soldier", "Soldier", "npc_soldier", Vector3(0.8, 1.8, 0.8),
		"5a6470", 85.0, 6, _merged(armed, {
			"faction": "hostile", "skill": "normal", "weapon": "zee_smg",
		})])
	entities.append([&"npc_soldier_elite", "Soldier (elite)", "npc_soldier", Vector3(0.8, 1.9, 0.8),
		"2c3138", 95.0, 8, _merged(armed, {
			"faction": "hostile", "skill": "hard", "weapon": "zee_rifle", "health": 160.0,
		})])
	entities.append([&"npc_rebel", "Rebel", "npc_soldier", Vector3(0.8, 1.75, 0.8),
		"6f8a4e", 80.0, 6, _merged(armed, {
			"faction": "player", "skill": "normal", "weapon": "zee_pistol", "follow": 1.0,
		})])

	for row in entities:
		var entity := DotPropDef.make(row[0], SCENE_ENTITY)
		entity.display_name = row[1]
		entity.category = &"entities"
		# Something that thinks about players is an NPC and counts against `pg_max_npcs`;
		# a turret that only spins is an entity. The limit is on what a thing DOES to a
		# server, and an NPC's senses and decisions are the cost worth capping.
		# By the entry's id, not its script: the turret runs `npc_spinner.gd` and is not an NPC.
		entity.limit_group = &"npcs" if String(row[0]).begins_with("npc_") else &"entities"
		entity.mass = row[5]
		entity.cost = row[6]
		entity.size = DotPropDef.Size.MEDIUM

		# `meta` is assembled rather than assigned from the row, so an entity's own
		# settings and the fields every spawnable has cannot collide by accident: a
		# tuning key called "extent" would otherwise silently resize the body.
		var meta := {
			"kind": "entity",
			"script": PlaygroundPaths.rebase("res://game/entities/%s.gd") % row[2],
			"shape": "box",
			"extent": [row[3].x, row[3].y, row[3].z],
			"colour": row[4],
		}

		for key in (row[7] as Dictionary):
			meta[key] = (row[7] as Dictionary)[key]

		entity.meta = meta
		out.add(entity)

	for vehicle in PlaygroundVehicles.catalogue().vehicles:
		out.add(_vehicle_prop(vehicle))

	out.add(_balloon())
	out.add(_waypoint())
	out.add(_spawn_point())
	out.add(_debris())

	for machine in _machines():
		out.add(machine)

	for weapon in PlaygroundZee.defs():
		out.add(_pickup(weapon))

	return out


## Health per prop, for `destruction`. What is not here does not break: the slab, the pillar
## and the platform are what somebody builds ON, and a floor shot out from under a build is
## not the fun kind of destruction. A barrel is the one that goes up.
const BREAKABLE := {
	&"plank": 60.0, &"beam": 150.0, &"panel": 80.0,
	&"crate": 40.0, &"crate_large": 120.0, &"barrel": 30.0, &"can": 5.0, &"die": 10.0,
}


## Things that say and hear: a button, a lever and a door, wired with the tool gun's Wire
## mode and pressed with F. dot-props' [DotPropIO] reads `outputs` and `inputs` here; what
## each one does is [Playground]'s (`_on_io_input`, `use_prop`).
##
## [b]A door is a frozen body the server swings[/b], round the hinge on its left edge, by
## writing its transform each tick: a static body teleported is exactly where it is told, which
## a door that people stand in the way of needs (mg-wipeout's finding about moving parts).
static func _machines() -> Array[DotPropDef]:
	var out: Array[DotPropDef] = []
	# id, name, extent, colour, mass, meta
	var rows := [
		[&"button", "Button", Vector3(0.6, 0.6, 0.25), "c23b3b", 6.0, {"outputs": ["pressed"]}],
		[&"lever", "Lever", Vector3(0.35, 0.9, 0.35), "c2a23b", 8.0, {"outputs": ["switched"]}],
		[&"door", "Door", Vector3(2.0, 2.6, 0.2), "7b5a3a", 120.0,
			{"inputs": ["toggle", "open", "close"], "outputs": ["opened", "closed"], "door": true}],
	]
	for row in rows:
		var def := DotPropDef.make(row[0], SCENE_PROP)
		def.display_name = row[1]
		def.category = &"machines"
		def.mass = row[4]
		def.cost = 1
		def.size = DotPropDef.Size.SMALL if row[0] != &"door" else DotPropDef.Size.MEDIUM
		var meta := {"shape": "box", "extent": [row[2].x, row[2].y, row[2].z], "colour": row[3]}
		meta.merge(row[5])
		def.meta = meta
		out.append(def)
	return out


## A piece of something broken: hidden, owned by nobody, cleaned up after a few seconds by
## [method Playground._expire_debris]. A plain prop, so it tumbles, is shoved and is drawn on
## every client through the spawner like any other.
static func _debris() -> DotPropDef:
	var def := DotPropDef.make(&"debris", SCENE_PROP)
	def.display_name = "Debris"
	def.category = &"debris"
	def.limit_group = &"debris"
	def.mass = 3.0
	def.cost = 1
	def.size = DotPropDef.Size.TINY
	def.meta = {
		"shape": "box",
		"extent": [0.35, 0.35, 0.35],
		"colour": "8a8a8a",
		"hidden": true,
	}
	return def


## A balloon, as the tool gun ties on. Hidden from the menu — it is the tool's, not a prop to
## place — and counted against `balloons`, not `props`.
static func _balloon() -> DotPropDef:
	var def := DotPropDef.make(&"balloon", SCENE_ENTITY)
	def.display_name = "Balloon"
	def.category = &"tools"
	def.limit_group = &"balloons"
	def.mass = 0.4
	def.cost = 1
	def.size = DotPropDef.Size.SMALL
	def.meta = {
		"kind": "entity",
		"script": PlaygroundPaths.rebase("res://game/entities/balloon.gd"),
		"shape": "sphere",
		"extent": [1.0, 1.0, 1.0],
		"colour": "e05252",
		"hidden": true,
	}
	return def


## A patrol waypoint, as the waypoint tool lays them. Hidden from the menu (the tool is how
## one is placed) and counted against `waypoints`, so a patrol cannot eat the NPC allowance.
static func _waypoint() -> DotPropDef:
	var def := DotPropDef.make(&"waypoint", SCENE_ENTITY)
	def.display_name = "Waypoint"
	def.category = &"tools"
	def.limit_group = &"waypoints"
	def.mass = 5.0
	def.cost = 0
	def.size = DotPropDef.Size.SMALL
	def.meta = {
		"kind": "entity",
		"script": PlaygroundPaths.rebase("res://game/entities/waypoint.gd"),
		"shape": "box",
		"extent": [0.9, 0.12, 0.9],
		"colour": "36d1e0",
		"hidden": true,
	}
	return def


## An NPC spawn point, as the spawner tool lays them. Hidden and counted against `spawners`.
static func _spawn_point() -> DotPropDef:
	var def := DotPropDef.make(&"spawn_point", SCENE_ENTITY)
	def.display_name = "NPC spawn point"
	def.category = &"tools"
	def.limit_group = &"spawners"
	def.mass = 5.0
	def.cost = 0
	def.size = DotPropDef.Size.SMALL
	def.meta = {
		"kind": "entity",
		"script": PlaygroundPaths.rebase("res://game/entities/spawn_point.gd"),
		"shape": "box",
		"extent": [1.2, 0.12, 1.2],
		"colour": "e0a436",
		"hidden": true,
	}
	return def


## A weapon lying in the world. Hidden from the props and entities tabs — it is spawned
## from the weapons tab with a right click — and counted against `weapons`.
static func _pickup(weapon: Object) -> DotPropDef:
	var weapon_id := StringName(str(weapon.get("id")))
	var def := DotPropDef.make(StringName("pickup_%s" % String(weapon_id).replace(":", "_")), SCENE_ENTITY)
	def.display_name = str(weapon.call("name_or_id"))
	def.category = &"weapons"
	def.limit_group = &"weapons"
	def.mass = 4.0
	def.cost = 1
	def.size = DotPropDef.Size.SMALL
	def.meta = {
		"kind": "entity",
		"script": PlaygroundPaths.rebase("res://game/entities/weapon_pickup.gd"),
		"shape": "box",
		"extent": [0.9, 0.25, 0.3],
		"colour": (weapon.get("colour") as Color).to_html(false),
		"weapon": String(weapon_id),
		"hidden": true,
	}
	return def


static func _merged(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate(true)

	for key in b:
		out[key] = b[key]

	return out


## The prop definition a vehicle is spawned through.
##
## [b]Derived from the vehicle definition, never written twice.[/b] It is the same
## "one description, three representations" rule the maps follow: the mass a physics gun
## checks and the mass the chassis puts on the rigid body are the SAME number, read from
## the tunables, so a catalogue saying 620 kg over a chassis saying 900 is a state this
## build cannot reach. Two hand-kept copies is exactly the shape that gave dot-props a
## prop a gun refused for being too heavy and a gravity gun threw like a beach ball.
static func _vehicle_prop(vehicle: DotVehicleDef) -> DotPropDef:
	var def := DotPropDef.make(vehicle.id, PlaygroundVehicles.SCENE)
	def.display_name = vehicle.name_or_id()
	def.category = &"vehicles"
	def.limit_group = &"vehicles"
	def.mass = vehicle.tuning().mass
	def.cost = vehicle.cost
	def.size = DotPropDef.Size.LARGE

	var meta := {
		"kind": "vehicle",
		"vehicle": String(vehicle.id),
		"shape": "box",
	}

	# Assembled rather than assigned, exactly as an entity's is: the vehicle's own
	# fields — extent, colour, the wheel geometry — come across, and the three keys
	# above cannot be overwritten by one of them by accident.
	for key in vehicle.meta:
		if not meta.has(key):
			meta[key] = vehicle.meta[key]

	def.meta = meta
	return def
