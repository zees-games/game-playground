extends "playground_panes.gd"

## Reused per-tick buffers; none escapes the function that fills it.
var _entity_buf: Array[PlaygroundEntity] = []
var _burning_buf: Array = []
var _melting_next: Dictionary = {}

func _ready() -> void:
	if config == null:
		config = PlaygroundConfig.new()
	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)

	# Layered before anything reads it: a file, cfg/ yml, the environment, then argv. Strict
	# (a typo or bad value stops the boot) on a dedicated or headless server.
	config_binder = PlaygroundConfig.make_binder(config, config_file)
	var loaded := config_binder.load_layers()

	if not loaded.ok:
		DotGameConfigBinder.fail_boot(get_tree(), loaded)
		return

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
	weapon_layer = preload("playground_weapon_layer.gd").new()
	weapon_layer.setup(self)
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


## The simulation loop: a fixed step accumulated from the frame time, not the frame's own delta, which would make the same play move
## differently per machine and a run's time depend on frame rate. The budget bound stops a spike spending the next frame on a hundred ticks.
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
			"dropped_s": snappedf(_accumulator, 0.001)
		})
		_accumulator = 0.0


## One simulated tick for everything, in the order a dedicated server uses: move every player, then time the tick with the
## position the move produced. Timing first shifts every run by one tick, a different amount at each tickrate.
func _simulate_tick(step: float) -> void:
	var _t_props_maps := DotFrameCost.now()
	props.advance(step)
	maps.advance(step)
	DotFrameCost.add(&"tick.props_maps", _t_props_maps)

	# Drivers' intent, then the chassis, before the players move: a rider's own move is skipped.
	var _t_vehicles := DotFrameCost.now()
	_drive_vehicles()
	vehicles.tick(step)
	DotFrameCost.add(&"tick.vehicles", _t_vehicles)

	# What the entities can see, rebuilt before any of them thinks: a list built at the end of a tick is last tick's positions,
	# and a chaser steering at them lags its target by one tick.
	var _t_npc_candidates := DotFrameCost.now()
	_rebuild_npc_candidates()
	DotFrameCost.add(&"tick.npc_candidates", _t_npc_candidates)

	var _t_npc_world := DotFrameCost.now()
	if npc_world != null:
		npc_world.advance(step)
	DotFrameCost.add(&"tick.npc_world", _t_npc_world)

	var _t_entities := DotFrameCost.now()
	_tick_entities(step)
	DotFrameCost.add(&"tick.entities", _t_entities)

	if authoritative:
		_sync_noclip_permits()

	var _t_players_simulate := DotFrameCost.now()
	_simulate_players(step)
	DotFrameCost.add(&"tick.players_simulate", _t_players_simulate)

	# The toys after everybody moved: a walk into a ball pushes it, weight tips a see-saw.
	var _t_toys := DotFrameCost.now()
	_advance_toys(step)
	DotFrameCost.add(&"tick.toys", _t_toys)

	# Held players after every holder has moved and aimed, and before the timers.
	var _t_pickup_weapons := DotFrameCost.now()
	pickup.tick(players, step)
	weapon_layer.tick(step)
	DotFrameCost.add(&"tick.pickup_weapons", _t_pickup_weapons)

	# After everybody has moved, so a grenade is swept against the world as the tick
	# leaves it, which is also where anybody it could hit now is.
	var _t_projectiles := DotFrameCost.now()
	if projectiles != null:
		projectiles.tick(step)
	DotFrameCost.add(&"tick.projectiles", _t_projectiles)

	var _t_debris_doors_liquid := DotFrameCost.now()
	_expire_debris()
	_swing_doors(step)
	_liquid_tick(step)
	_pane_impacts()
	DotFrameCost.add(&"tick.debris_doors_liquid", _t_debris_doors_liquid)

	# After the moves and before the timers, which is the same ordering rule: a rider's
	# position for this tick is where the vehicle carried them, not where they were.
	var _t_riders := DotFrameCost.now()
	_carry_riders()
	DotFrameCost.add(&"tick.riders", _t_riders)

	# Locomotion state from the movement just done: fed last tick's position it animates a tick late.
	var _t_drive_character := DotFrameCost.now()
	for id in players:
		(players[id] as PlaygroundPlayer).drive_character(step)
	DotFrameCost.add(&"tick.drive_character", _t_drive_character)

	# The run timer last, with the positions every move above produced.
	if run_timer != null:
		run_timer.call("tick", _tick)


## Entities before players, as the timer runs after them: an NPC moved after the player lags what collided with it by a tick.
## Iterated over a copy because an entity may remove itself and `_on_prop_removed` erases from this list.
func _tick_entities(step: float) -> void:
	_entity_buf.assign(entities)
	for entity in _entity_buf:
		if is_instance_valid(entity):
			entity.entity_tick(step)


## A body the client's load gate froze (`process_mode` DISABLED) is skipped: simulating it is how it fell through an unbuilt map.
func _simulate_players(step: float) -> void:
	for id in players:
		var body := players[id] as PlaygroundPlayer
		if body.is_inside_tree() and not body.can_process():
			continue
		body.simulate(_tick, step)


## One authoritative tick driven from outside, at a tick number the driver chose. The net bridge calls this instead of
## [method _physics_process] because the tick has to happen between dot-net applying inputs and building the snapshot; a game
## running its own loop would send state from the wrong instant.
func tick_once(tick: int) -> void:
	_tick = tick
	_simulate_tick(1.0 / float(maxi(tick_rate, 1)))

	if player_stack != null:
		player_stack.tick(tick)


## The client's half of a tick: what it was told is in the air, and the run timer. A client may not simulate props (rigid bodies are not
## reproducible across machines) or remote players (interpolated); its own player is predicted through [PlaygroundPlayerNet].
## It feeds a run timer the position it can see, so a local run reads a tick earlier than any packet could deliver it.
func tick_timers_only(tick: int) -> void:
	_tick = tick

	# What this client was told is in the air. It decides nothing; see PlaygroundProjectiles.
	if projectiles != null:
		projectiles.tick(1.0 / float(maxi(tick_rate, 1)))

	if run_timer != null:
		run_timer.call("tick", _tick)


## Puts the whole game on a tick rate decided elsewhere (a server's `sv_tickrate`, reaching a client through HELLO). Every player's
## controller moves with it, not just the loop: a controller keeps its own rate, and a mismatch is correct on one's own screen and wrong everywhere else.
## The tick accessor `ArenaGame` and `G2GGame` also have, so a layer ticked from the module need not reach past the underscore of `_tick`.
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


## What the liquids do, on the authority: lava burns a player (through [member hazard_hurt],
## or back to the spawn) and melts a prop that stays in it. Water's own behaviour, floating
## and swimming, is not here.
func _liquid_tick(step: float) -> void:
	if not authoritative or liquids.is_empty():
		return

	_float_props(step)

	var burning := _burning_buf
	burning.clear()
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
	var still := _melting_next
	still.clear()
	for prop: DotPropInstance in props.all_props():
		var node := prop.node as Node3D
		if node == null or not prop.is_alive():
			continue
		if _melting.has(prop.instance_id):
			still[prop.instance_id] = float(_melting[prop.instance_id]) + step
			continue
				# Its underside in the lava, not its centre: a crate floats on lava (it is denser than wood) and a centre test let one
				# ride a lava lake for ever. A light one floats by millimetres, so the bottom is asked of the lava grown a little.
		var underside := node.global_position - Vector3.UP * _half_height_of(prop)
		for each: Array in burning:
			if (each[0] as AABB).grow(0.1).has_point(underside):
				still[prop.instance_id] = float(_melting.get(prop.instance_id, 0.0)) + step
				break
	_melting_next = _melting
	_melting = still
	for instance_id: int in still.keys():
		if float(still[instance_id]) >= MELT_SECONDS:
			_melting.erase(instance_id)
			var _gone := props.remove(instance_id, DotPropSpawner.REASON_CLEANUP)


## Buoyancy and drag on every loose prop in a liquid, on the authority (props are not predicted), by [DotPropBuoyancy]. Density is
## the catalogue's `density` when given (rock, concrete: the catalogue's masses are tuned for a physics gun and a 900 kg boulder
## works out lighter than water), else mass over volume.
func _float_props(step: float) -> void:
	if liquids.is_empty():
		return
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var surface := func(material: Variant) -> Variant: return PlaygroundMaterials.surface(String(material))
	for prop: DotPropInstance in props.all_props():
		var body := prop.node as RigidBody3D
		if body == null or body.freeze or not body.is_inside_tree() or prop.held_by != &"":
			continue
		if not DotPropBuoyancy.near_liquid(body.global_position, liquids):
			continue
		var volume := _volume_of(prop)
		var density := float(prop.def.meta.get("density", body.mass / maxf(volume, 0.001))) if prop.def != null else body.mass / maxf(volume, 0.001)
		var _acted := DotPropBuoyancy.apply(body, volume, _half_height_of(prop), density, liquids, surface, step, gravity)


static func _volume_of(prop: DotPropInstance) -> float:
	if prop.def == null:
		return 1.0
	var scale := float(prop.node.get("size_scale")) if prop.node != null and prop.node.get("size_scale") != null else 1.0
	var shape: String = ["box", "sphere", "cylinder"][PlaygroundProp.shape_of(prop.def)]
	return DotPropBuoyancy.volume_of(PlaygroundProp.extent_of(prop.def), scale, shape)


static func _half_height_of(prop: DotPropInstance) -> float:
	if prop.def == null:
		return 0.5
	var scale := float(prop.node.get("size_scale")) if prop.node != null and prop.node.get("size_scale") != null else 1.0
	return PlaygroundProp.extent_of(prop.def).y * 0.5 * scale


## Keeps a riding player's movement state on the seat they are in. The rider's NODE is carried by dot-vehicle, but everything
## reads [code]controller.state.position[/code] (timer, NPC list, HUD, [PlaygroundPlayerNet]): without this a passenger is drawn
## elsewhere at the spot they got in. Run AFTER the vehicles tick and before the timers are fed, as the players' own rule.
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

		# The armed NPCs see the players and each other: a soldier on `hostile` and a rebel on `player` are candidates for one
		# another and the senses skip the perceiver's own faction, so a rebel never picks a player. Older entities keep [member npc_candidates].
	npc_candidates_all.assign(npc_candidates)

	for entity in armed_npcs:
		if not is_instance_valid(entity):
			continue

		var faction := StringName(entity.call("tune_string", &"faction", "hostile"))
		npc_candidates_all.append(DotNpcSenses.Candidate.new(
			npc_id_of(entity), (entity as Node3D).global_position, faction, 0.0
		))


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


## The candidate id an armed NPC is known by: `n` and its instance id.
static func npc_id_of(entity: Node) -> StringName:
	if not entity.has_meta(&"pg_npc_id"):
		entity.set_meta(&"pg_npc_id", StringName(String.num_int64(entity.get_instance_id()).insert(0, "n")))
	return entity.get_meta(&"pg_npc_id")


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


## How a dead NPC's body falls (a sandbox soldier, a wave): the reaction rule over the server's `sv_ragdoll_reactions`, pushed away
## from [param by] when that is a player, from [method next_seed]. Kept as `pg_death` for the bridge, which sends it with the PROP_GONE;
## every client copies a ragdoll from the figure it drew.
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


func _expire_debris() -> void:
	if _debris_expiry.is_empty() or props == null:
		return

	var now := _clock_seconds()

	for instance_id: int in _debris_expiry.keys():
		if now >= float(_debris_expiry[instance_id]):
			_debris_expiry.erase(instance_id)
			var _gone := props.remove(instance_id, DotPropSpawner.REASON_CLEANUP)


## Turns each driver's movement keys into what their vehicle is being asked for. The mapping is here, not in dot-vehicle, which has no
## input at all: a [DotVehicleCommand] is built from a keyboard, pad, touch layout or bot. Reuses [DotFpsCommand] rather than a second
## wire format: a client already sends one per tick, sanitised, replayed by the predictor and quantised.
func _drive_vehicles() -> void:
	if vehicles == null or vehicles.ride.rider_count() == 0:
		return

	for id in players:
		var player: PlaygroundPlayer = players[id]

		if not player.riding:
			continue

		var vehicle := vehicles.vehicle_of_rider(id)

		if vehicle == null or vehicle.driver() != id:
						# A passenger's keys do nothing, and the refusal is dot-vehicle's anyway: `set_command` checks the driver on the server
						# every command, because a client can be edited and driving from the back seat is the hole that would give.
			continue

				# S brakes while the car still rolls forward and reverses once stopped (dot-vehicle's `brake_then_reverse`); reverse thrust alone
				# took about three times the brake's distance. Here and not in `drive_command`, which has no vehicle to read a speed from.
		var cmd := drive_command(player.pending_command())
		vehicles.set_command(vehicle.instance_id, id, cmd.brake_then_reverse(vehicle.forward_speed()))


## One tick of driving, from one tick of movement input. Static and public because it is the whole mapping, and a suite that had
## to build a player to test it would be testing something else.
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


## The player's motor mask under `mp_solidplayers`, and the standing hull the others stop at (a player's body has no shape of its
## own): with the rule on, somebody walking into you stops at your shoulder. Through `apply_to`, which goes through `set_collision_mask`
## (a style does not undo it) and makes the players' layer one a player may walk out of.
func _apply_body_mask(player: PlaygroundPlayer) -> void:
	if player_stack == null or player == null or player.controller == null:
		return
	var layout: DotPhysicsLayout = player_stack.physics.layout if player_stack.physics != null else null
	var players_layer := layout.layer_mask(&"player") if layout != null else 0
	body_rules.apply_to(player.controller, player_stack.player_collision_mask(), players_layer)
	var tunables := player.controller.tunables
	if player.zee_rig != null and is_instance_valid(player.zee_rig):
		player.zee_rig.set("wall_extra_mask", tunables.collision_mask)
	body_rules.apply_hull(player, tunables.stand_height, tunables.radius)


## `mp_solidplayers` changed: every player's mask and hull now.
func _on_body_rules_changed() -> void:
	for id in players:
		_apply_body_mask(players[id] as PlaygroundPlayer)
	apply_pass_through()


## Hands every controller the bodies it passes through under `block_rules` (teammates and
## `!noblock` requests); the same call on every machine, or a client predicts a wall.
func apply_pass_through() -> void:
	var entries := {}
	for id: Variant in players:
		var who := players[id] as PlaygroundPlayer
		if who != null and who.controller != null:
			entries[id] = {"body": who, "controller": who.controller}
	body_rules.apply_exceptions(entries)
