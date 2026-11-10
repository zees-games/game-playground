extends "playground_setup.gd"
## The spawned prop's body: classify, entity and vehicle set-up, removal, and the catalogue the spawner draws from.


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

	var built := PlaygroundSpawnables.with_models(PlaygroundSpawnables.catalogue(), config.props_dir if config != null else "user://props")
	if config != null:
		PlaygroundSpawnables.apply_npc_scales(built, config.soldier_health_scale, config.hunter_speed_scale)
	return built
