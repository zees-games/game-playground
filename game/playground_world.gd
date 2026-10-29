extends "res://game/playground_setup.gd"

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

		# Every prop this build ships is the same scene; what makes a plank a plank is three fields of its definition. dot-props does
		# not know that: it instantiates a scene and places it, because a server with real content has a scene per prop.
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


## The current map's swimmable liquids (water, slime), as the boxes a player's swim mode is
## given. Lava is not here: a person does not swim in it.
func water_boxes() -> Array[AABB]:
	var out: Array[AABB] = []
	for liquid: Dictionary in liquids:
		if PlaygroundMaterials.is_swimmable(String(liquid["material"])):
			out.append(liquid["box"] as AABB)
	return out


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


## The vehicle spawner, and the handover it drives. It spawns nothing: every vehicle arrives through [DotPropSpawner] and is handed over with
## [method DotVehicleSpawner.adopt], because a vehicle is a prop first (budgeted, undoable). Its own budget is left generous so the prop
## budget is what limits vehicles; a second limit biting first is a refusal `pg_prop_budget` could not explain.
func _build_vehicles() -> void:
	vehicles = DotVehicleSpawner.new()
	vehicles.name = "Vehicles"
	vehicles.authoritative = authoritative and config.allow_props
	vehicles.catalogue = PlaygroundVehicles.catalogue()
	vehicles.world_ref = DotNodeRef.of_path(^"../World")
	vehicles.world_budget = 0
	vehicles.per_player_budget = 0
	vehicles.spawn_interval = 0.0

		# The rider node IS carried: a PlaygroundPlayer is a Node3D with the camera under it on a client, so parenting it into the seat puts a
		# rider's view on the vehicle with no camera code here. The controller state is pulled back each tick, see [method _carry_riders].
	vehicles.ride.carry_rider_nodes = true

		# Layer 1 is the world's, checked rather than left at the addon's default by luck: an exit sweep against the wrong mask
		# finds nothing, always succeeds and puts players through walls.
	vehicles.ride.exit_mask = 1

	vehicles.ride.on_seated = _on_seated
	vehicles.ride.on_unseated = _on_unseated

	add_child(vehicles)


## Whoever is in a vehicle stops being a player who walks. The controller is turned OFF, not ignored: one still simulating a player
## parented into a moving vehicle writes its own answer each tick and the two fight, reading as the vehicle shaking itself apart.
## [method PlaygroundPlayer.set_riding] is the switch; [method _carry_riders] keeps the replicated state honest meanwhile.
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
	projectiles.rules = grenade_rules
	projectiles.add_board(npc_sounds, npc_world.now)
	projectiles.effects.senses = npc_senses
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


## The maps this build ships; a server with delivered maps loads a JSON catalogue. An instance method that forwards, and a static
## one beside it because the server browser needs the list without a game: a copy written into the menu went stale four times.
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


## Adds every map document (`*.json`) in [param dir] to [param catalogue], each built by [constant DATA_MAP_SCENE] with its path in
## `meta.doc`. An unreadable document is left out with a WARN; an existing id is kept, so a delivered map never replaces a
## built-in one. Returns how many were added.
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


func spawn_player(id: StringName) -> void:
	var player: PlaygroundPlayer = players.get(id)

	if player == null:
		return

	# A respawn is a teleport, and a held player teleported is pulled straight back to the
	# beam on the next tick.
	pickup.forget(players, id)

	var track := track_of(id)
	var map := current_map_node()

		# The director chooses among the map's own starts; the map is the fallback. `PlaygroundPlayerStack.refresh_spawns` copies every
		# track's start into it, so this is a better choice among one set: the per-site cooldown, occupancy check, and the arena's protection
		# window granted inside `choose` and nowhere else.
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


## [param at], or the nearest point on a ring round it that nobody else is standing on. Every start is a single point and every
## player was put on it: two joiners stood inside each other and each first-person camera was inside the other's head. dot-spawn's
## occupancy cannot help with one site. Two rings of eight at 1.5 m fit the smallest pad (6 m); a crowd past seventeen shares the centre.
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


## Tells the shooter their hit landed ([signal hit_landed]): from the arena's damage to a player, an NPC's [code]take_damage[/code],
## [method hurt_prop] and [method hurt_pane]. Only for a player, only on the authority, only for something taken: a hit that took
## nothing (a dead body, a protected prop) did not land.
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


## A blast at [param at]: every moving toy within [param radius] thrown away from it. Server
## side; a grenade's ([PlaygroundProjectiles]) and a breaking barrel's. How many it moved.
func blast_toys(at: Vector3, radius: float) -> int:
	if toys == null or not authoritative:
		return 0
	return toys.blast(at, radius, TOY_BLAST_SPEED)


func current_map_node() -> PlaygroundMap:
	return maps.world as PlaygroundMap if maps != null else null


## The track [param id] is on: the run timer's answer, or 0 (the main track).
func track_of(id: StringName) -> int:
	if run_timer != null:
		return int(run_timer.call("track_of", id))

	return 0


## Where a player on [param track] starts, as `{at: Vector3, yaw: float}` (degrees), or an empty dictionary with no map or no start.
## The run timer's SPAWN zone first when it has one for the track; a sandbox with no timer starts every track at the map's spawn.
func start_for(track: int) -> Dictionary:
	if run_timer != null:
		var zoned: Dictionary = run_timer.call("start_for", track)

		if not zoned.is_empty():
			return zoned

	var map := current_map_node()

	if map == null:
		return {}

	return {"at": map.spawn_for(track), "yaw": map.spawn_yaw_for(track)}


func change_map(id: StringName) -> DotResult:
	return await maps.change_to(id)


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
		# A map that has to be told something before it can build itself, duck-typed so a delivered map of the same shape works and this
		# file names nothing from `maps/`. Before the spawns below: a generated map's spawn comes out of the generator, and spawning
		# before it ran puts a player at the fallback, a guess that may be inside a wall.
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


## The map ran out of time, or enough players rocked the vote. The session says the map is over; what happens next is here, since
## a session that changed the map itself would be fought by every game that wanted a vote, a scoreboard or a finished round first.
## A run in progress is not protected: waiting for the last runner would never end a map while one person keeps restarting.
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
