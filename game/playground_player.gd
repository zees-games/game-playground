extends "res://game/playground_player_base.gd"

func set_water(boxes: Array[AABB]) -> void:
	swim.volumes = boxes
	if controller != null and controller.motor != null and controller.state != null \
			and controller.state.mode == swim.mode_id and boxes.is_empty():
		controller.motor.set_mode(controller.state, DotFpsState.Mode.AIR)


func _ready() -> void:
	controller = DotFpsController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate

	# EXTERNAL, not LOCAL, even in single player.
	#
	# [b]The game owns the tick, and that is the whole ordering argument.[/b] In
	# LOCAL the controller accumulates frame time and ticks itself, which means the
	# timer would be fed from a signal fired inside somebody else's loop and a bot
	# could not be driven at all. Owning the loop here makes the order explicit —
	# sample, move, then time the tick with the position the move produced — and it
	# is the same shape a dot-net bridge and a dedicated server use, so nothing has
	# to be rearranged when one arrives.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = _tunables()
	# What a map box is made of reaches the feet: ice, mud, sand, snow, rubber. Read off box
	# metadata both ends build from one map document, so a client predicts it too.
	controller.surfaces = PlaygroundMaterials.player_surfaces()
	# Every player, both ends: an admin's noclip is a modifier whose index travels on the
	# wire. See dot-player-controller's DotFpsAdminModifiers.
	controller.admin_abilities = true

	# body_ref left unset, so it defaults to the parent — this node, which is the
	# Node3D the movement drives. `DotNodeRef.of_self()` looks equivalent and is not:
	# it resolves to the CONTROLLER, which is a plain Node, and setup() then refuses
	# with "the player body must be a Node3D" and the whole player never simulates.
	# Swimming: one mode per player, registered on every setup (a style rebuilds the motor),
	# the same on every machine because its id is on the wire. The water comes from the map.
	controller.extra_modes = [swim]

	add_child(controller)

	controller.simulated.connect(_on_simulated)

	if samples_input:
		sampler = DotFpsSampler.new(controller.tunables)
		DotFpsSampler.register_default_actions(sampler)


## Gives this player a third-person controller and the switch that hands between them. A different motor, not a
## moved camera: a sandbox ranks and rewinds nothing, so it is free to use one (the racing and arena games keep one).
## Built on demand, only for a player that samples input: `DotTpsController` drives a CharacterBody3D, a real
## per-tick cost a dedicated server full of remote players should not pay.
## Returns whether it was built.
func build_view_switch() -> bool:
	if tps != null:
		return true

	if not samples_input:
		return false

	# [b]The component root both controllers bind through.[/b] `DotPlayerController` is a
	# `DotPlayerComponent`: it finds its player by walking up, reads the body from it and
	# refuses to run unbound. Without this node the third-person controller has no body to
	# ask for and logs "no CharacterBody3D for this player" once per activation.
	player_node = DotPlayer.new()
	player_node.name = "Player"
	player_node.player_key = String(player_id)
	player_node.is_local = true
	# [b]No `roster_ref`, deliberately.[/b] `DotPlayer` binds on a key alone when it
	# cannot find a roster, and everything the controllers ask it for — the body, whether
	# the player is alive — is answered without one. Pointing it at the stack's roster
	# would mean either a node path across two subtrees or turning
	# `register_service` on, and a registry name is global to the process: two servers in
	# one editor session would collide on it, which is the reason the stacks turn it off.
	# The body is this node, which is why it is a CharacterBody3D at all.
	player_node.body_ref = DotNodeRef.of_path(NodePath(".."))
	add_child(player_node)

	tps = DotTpsController.new()
	tps.name = "ThirdPerson"
	tps.controller_id = &"tp"
	tps.tunables = DotTpsTunables.new()
	add_child(tps)

	# [b]The id BEFORE the switch is added, and that ordering is the bug.[/b]
	# `DotPlayerControllerSwitch._ready` runs `refresh()` and activates its default the
	# moment it enters the tree — so a controller still carrying an empty `controller_id`
	# at that instant is registered under its class name instead, `default_controller`
	# names something that is not there, and the switch falls back to whatever it found
	# first. The sandbox opened in third person and the only symptom was the camera.
	controller.controller_id = &"fp"

	controller_switch = DotPlayerControllerSwitch.new()
	controller_switch.name = "ViewSwitch"
	# First person is what a sandbox opens in: the tools are aimed down a crosshair and a
	# physics gun held over the shoulder is a different, worse tool.
	controller_switch.default_controller = &"fp"
	add_child(controller_switch)

	# This is the moment a client learns the player is its own, so the body built for them
	# as somebody else's is hidden now: they are looking out of it.
	refresh_body()

	return true
# --- The tick --------------------------------------------------------------

## Advances this player by one simulated tick.
##
## Called by [Playground], not by the controller: see the note in [method _ready]
## about who owns the loop.
func simulate(tick: int, delta: float) -> void:
	if sampler != null:
		controller.apply_command(sampler.sample(delta))

	# A rider's movement is TURNED OFF, not ignored, and the sample above still happens.
	#
	# Off, because a controller simulating a player who is parented into a moving vehicle
	# writes its own answer into the state every tick while the vehicle carries the node
	# somewhere else — two authorities over one transform, which reads as the car shaking
	# itself apart at speed. Sampled anyway, because those same keys are what the car is
	# being driven with: `Playground._drive_vehicles` reads the pending command and turns
	# it into throttle and steering.
	if riding:
		return

	controller.simulate_tick(tick, delta)


## Called once per simulated tick, by the controller, after the move.
##
## [b]After the move, and that ordering is the point.[/b] What runs here changes where
## the player ends up this tick, and a run timer decides whether the player crossed a line
## from where they were and where they now are — so it has to see the position the move
## produced, not the one it started from.
func _on_simulated(_tick: int, state: DotFpsState) -> void:
	global_position = state.position

	# Into the water once the waist is in it. Here because this runs on every simulated tick,
	# a prediction replay's included, so a client and the server enter on the same tick.
	if not riding and controller.motor != null:
		swim.update(controller.motor, state)

	if post_move_fn.is_valid():
		post_move_fn.call(self, state)

	_launch_from_toy(state)
	_ride_prop(state)


## A trampoline or a bounce pad under the feet throws them, after the move, on every end that
## simulates this player (a predicting client's replays included): dot-props' `launch_for` is a
## pure function of where the toys stand, so the client is thrown on the tick the server is.
## AIR at once, as a jump leaves the ground, or the motor's ground snap holds them down.
func _launch_from_toy(state: DotFpsState) -> void:
	if toys == null or riding or not state.is_grounded():
		return
	var thrown := toys.launch_for(state.position, state.velocity)
	if thrown.is_empty():
		return
	state.velocity = thrown["velocity"]
	state.mode = DotFpsState.Mode.AIR
	state.time_since_grounded = 1000.0
	if bounced_fn.is_valid():
		bounced_fn.call(int(thrown["index"]))


## Carried by the prop underfoot, after the move (mg-buses-from-hell's shape).
##
## [b]`ground_id` is a local physics handle, not simulation state[/b], so riding is
## resolved on each machine from its own bodies. Written into the state as well as the
## node: the next move starts from `state.position`, and a lift applied to the node alone
## is undone by it, so the player would ride one frame a tick and stand still overall.
func _ride_prop(state: DotFpsState) -> void:
	if carry == null or not state.is_grounded() or riding:
		return

	var step := 1.0 / float(maxi(1, controller.tick_rate))
	var surfing := not carry_enabled_fn.is_valid() or bool(carry_enabled_fn.call())
	var lift := Vector3.ZERO

	# A prop underfoot (prop surfing), and a turning roundabout through the same call
	# (`DotPropCarry.toys`). With prop surfing off, the roundabout still carries: it is a toy
	# on the map, not a prop somebody spawned to ride.
	if surfing:
		lift = carry.ride(state.ground_id, state.position, MASS_KG, step)
	elif carry.toys != null:
		lift = carry.toys.carry_for(state.position, step, state.ground_id).get("offset", Vector3.ZERO)

	# A connected client's ground is a mirror, which its spawner does not know and whose body
	# is frozen: its velocity is the one its net behaviour measured (PlaygroundPropNet).
	if surfing and lift == Vector3.ZERO and state.ground_id != 0:
		var ground: Object = instance_from_id(state.ground_id)
		if ground is Node and (ground as Node).has_meta(&"mirror_velocity"):
			lift = ((ground as Node).get_meta(&"mirror_velocity") as Vector3) * step

	if lift == Vector3.ZERO:
		return

	state.position += lift
	global_position = state.position
	carried_metres += lift.length()


## Gets in or out of a vehicle. Called by the ride's `on_seated` / `on_unseated`.
##
## Both halves matter and the second is the one that is easy to leave out: a player put
## back down after a drive whose velocity was whatever it was when they got in launches
## across the map on their first step.
func set_riding(value: bool, vehicle_node: Node3D = null) -> void:
	# Before the early return: a client told twice about one ride may learn the vehicle
	# only the second time.
	ride_node = vehicle_node if value else null

	if character != null:
		character.set_seated(value)

	if riding == value:
		return

	riding = value

	if riding:
		controller.state.velocity = Vector3.ZERO
	else:
		# Handed back walking, standing still and in the air. The controller works out
		# on its next tick whether there is ground under them, which is the honest answer
		# — the exit sweep only proved there was room, not that it was a floor.
		controller.state.velocity = Vector3.ZERO
		controller.state.mode = DotFpsState.Mode.AIR


## Held by somebody's physics gun ([PlaygroundPickup]): a rider with no vehicle and no
## seat. Movement off, prediction off, and the body standing, because nobody sat down.
func set_held(value: bool) -> void:
	set_riding(value)
	if character != null:
		character.set_seated(false)


## Copies where the vehicle has carried this player into the movement state.
##
## [b]Without this a passenger is drawn on every other machine at the spot where they got
## in.[/b] The NODE is carried by dot-vehicle, which reparents it into the seat — but the
## timer, the NPC candidate list, the HUD and above all [PlaygroundPlayerNet] all read
## [code]controller.state.position[/code], and nothing was writing it. The failure is
## invisible in one process, because in one process the node is the thing being looked at.
func adopt_ride(at: Vector3, velocity: Vector3) -> void:
	controller.state.position = at
	controller.state.velocity = velocity


## The command this player is about to be simulated with, or was last simulated with.
##
## What a vehicle is driven from. Never null: the controller keeps the last command it
## was given, which is what makes a dropped input a straight line rather than a stop.
func pending_command() -> DotFpsCommand:
	return controller.current_command if controller.current_command != null else DotFpsCommand.new()


## Draws [member beacon] for one frame, and says when it pings.
##
## Called once a frame by whatever draws this player — `PlaygroundClient._process` for every
## player in the world, a screenshot tool for the ones it arranges — and never on a server,
## so a dedicated server builds no marker. Returns true when a new ripple starts, which is
## when the caller plays the ping; a return value rather than a signal, because the one
## caller that plays it is the one that asked.
##
## [param local_view] is whether this is the player whose eyes the camera is behind, which
## hides the column (see [DotFxBeacon]).
##
## [b]Not hidden while dead, unlike the reference game's.[/b] Nothing on this node knows
## the arena killed it: a dead player here is a body standing where it fell until dot-match's
## respawn teleports it, and a marker on that body marks where the player is.
##
## Placed at the SIMULATED position, the one the client's camera follows: the render state
## on the local player and the interpolated one on a remote player, both written into
## `controller.state` once a frame.
func present_beacon(delta: float, local_view: bool) -> bool:
	if not beacon:
		if beacon_marker != null:
			beacon_marker.queue_free()
			beacon_marker = null
		return false

	if beacon_marker == null:
		beacon_marker = DotFxBeacon.new()
		beacon_marker.name = "Beacon"
		# Red-orange, the colour nothing in a grey dev-textured sandbox is, and brighter than
		# the warm props a player spawns. Ping off: the game plays its own catalogue ping
		# (BEACON_SOUND) from advance()'s return, so the node's would be heard twice.
		beacon_marker.colour = Color(1.0, 0.24, 0.14)
		beacon_marker.ring_radius = 0.78
		beacon_marker.column_height = 14.0
		beacon_marker.column_base = 2.1
		beacon_marker.ping_enabled = false
		add_child(beacon_marker)

	beacon_marker.local_view = local_view
	beacon_marker.global_position = controller.state.position if controller != null \
		else global_position

	return beacon_marker.advance(delta)


func describe() -> Dictionary:
	return {
		"id": String(player_id),
		"name": display_name,
		"style": String(movement_style.id) if movement_style != null else "-",
		"speed": "%.1f m/s" % speed(),
		"run": str(timer.get("run")) if timer != null else "-",
		"blinded": blinded,
		"beacon": beacon,
	}




## Whether this player was teleported since the last call, and forgets it. Read once a tick
## by a run timer's replay recorder, so a ghost is not smeared across a teleport.
func take_teleported() -> bool:
	var was := _teleported
	_teleported = false
	return was
