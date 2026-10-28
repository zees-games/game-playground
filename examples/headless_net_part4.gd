extends "res://examples/headless_net_part3.gd"

func _test_prop_removal() -> void:
	_section("undo")

	var before := int(_client_bridge.describe()["props"])
	_check(before > 0, "there is something to undo", str(before))

	_client_bridge.ask_undo()
	_exchange()
	await _steps(4)

	var server_after := int(_server_bridge.describe()["props"])
	_check(server_after == before - 1, "the server removed one",
		"%d -> %d" % [before, server_after])

	_exchange()
	await _steps(2)
	_check(
		int(_client_bridge.describe()["props"]) == server_after,
		"and the client stopped drawing it"
	)
	_done()


## A vehicle spawned, driven and ridden with a real socket between the two ends.
##
## [b]This is the only thing that has ever run [DotVehicleNetSync] across a wire.[/b]
## dot-vehicle's 122 checks and game-playground's own vehicle test both run in one
## process, where the client IS the server's dictionary and every id agrees by
## construction. What only this can catch: a spec dot-net will not accept, a wheel angle
## that arrives as a body rotation, a seat mask nobody reads, a driver whose input is
## applied on the client and never sent, and a rider drawn on the other machine at the
## spot where they got in.
func _test_vehicle_over_the_wire() -> void:
	_section("a vehicle, over the socket")

	var id := &"u%d" % SESSION
	var driver := _server_player()

	if driver == null:
		return

	var at := Vector3(-60.0, 1.2, -60.0)
	driver.teleport(at + Vector3(2.5, 0.0, 0.0), 0.0)

	_server_game.props.limits.spawn_interval = 0.0
	var spawned := _server_game.props.spawn(&"buggy", id, at)
	_check(spawned != null, "the server spawns a buggy")

	if spawned == null:
		return

	var vehicle := _server_game.vehicles.vehicle_for_node(spawned.node)
	_check(vehicle != null, "and adopts it as a vehicle")

	if vehicle == null:
		return

	_exchange()
	await _steps(8)

	var mirror := _find_vehicle_node(_client_game)
	_check(mirror != null, "the client builds its own copy of it")
	_check(
		mirror != null and mirror.get_node_or_null("Net") is PlaygroundVehicleNet,
		"replicating through DotVehicleNetSync rather than as a plain prop"
	)
	_check(
		mirror != null and (mirror as PlaygroundVehicle).wheel_count() == 4,
		"with its wheels built on the client too"
	)

	# [b]The mirror is taken out of the physics world for the drive, and that is a fact
	# about this HARNESS rather than about the game.[/b] Both halves are plain nodes in
	# one scene tree, so they share one physics space — and the client's frozen copy of
	# the car sits at exactly the coordinates the server's car is trying to drive out of.
	# The first version of this test measured 1.24 m and a car reversing at half a metre
	# a second, which was the server's buggy wedged against its own reflection. On two
	# machines there is no such body.
	if mirror != null:
		mirror.collision_layer = 0
		mirror.collision_mask = 0

	# Let it settle onto its suspension. A raycast vehicle spawned in the air is falling,
	# and "did it drive" measured through the drop measures the drop.
	await _steps(40)

	# The client asks. It has no seats, no exit sweep and no vehicle spawner: the server
	# owns every one of those, and this is the same division a spawn already makes.
	_client_bridge.ask_use_vehicle()
	_exchange()
	await _steps(6)

	_check(vehicle.driver() == id, "the client's use key puts it in the driving seat")
	_check(driver.riding, "the server stops walking them")
	_check(
		_client_player() != null and _client_player().riding,
		"and the SEAT event stops the client predicting them",
		"a predicted controller under a rider fights every snapshot"
	)

	# Sat down, not standing. A rider's node is carried to the seat, and the body hanging off
	# it was a standing 1.8 m figure — legs through the floor of the car, head two metres over
	# it. The client learns it from the same SEAT event, and the vehicle with it, so the body
	# faces the way the car does rather than where the rider happens to look.
	var rider := _client_player()
	# Looking out of the side, a quarter turn off the car's heading: otherwise the rider's
	# look and the car's heading agree, and "faces the car" cannot be told from "faces where
	# they look" — which is how this check first passed with the vehicle never sent.
	if rider != null and mirror != null:
		rider.controller.state.yaw = rad_to_deg(mirror.global_rotation.y) + 90.0
	var _drawn := PlaygroundClient.present_frame(_client_net, _client_game, 0.0)
	var rider_body: PlaygroundCharacter = rider.character if rider != null else null
	var head := (
		rider_body.rig.get_node_or_null("Body/Head") as Node3D
		if rider_body != null and rider_body.rig != null else null
	)
	_check(
		rider_body != null and rider_body.is_seated_pose() and head != null
			and head.position.y < 1.2,
		"and the client sits their body down in the seat",
		"head %.2f m above the seat" % (head.position.y if head != null else -1.0)
	)
	var facing_dot := (
		rider_body.rig.global_basis.z.normalized().dot(mirror.global_basis.z.normalized())
		if rider_body != null and mirror != null else -2.0
	)
	_check(
		facing_dot > 0.99,
		"facing the way the car faces",
		"dot %.3f" % facing_dot
	)

	var before := vehicle.position()
	var mirror_before := mirror.global_position if mirror != null else Vector3.ZERO

	# The driver's own input goes round trip. That is dot-vehicle's decision rather than
	# a gap here: a rigid body is not reproducible across machines, so a predicted
	# vehicle is a corrected vehicle and a correction on something a player is steering
	# reads worse than the latency does.
	# [b]Sampled while it drives, not read off the end.[/b] 320 ticks at full throttle
	# is further than the clear ground round the spawn: the car reaches about 10 m/s and
	# then arrives at map geometry, and the reading taken after it has stopped against
	# something is the rebound rather than the drive. It was -0.47 m/s, deterministically,
	# while the car had plainly driven twelve metres in the direction it was pointed —
	# a check measuring the wrong instant rather than a vehicle refusing to move.
	var fastest := 0.0

	for _leg in range(16):
		await _steps(20, _forward())
		fastest = maxf(fastest, vehicle.forward_speed())

	_exchange()
	await _steps(6)

	var travelled := vehicle.position().distance_to(before)
	# Deliberately well under what the car can do in 320 ticks. The client is on a
	# different tick rate from the server here on purpose, so how many of its inputs land
	# in a given wall-clock stretch is not a constant — and a threshold set at the
	# measured figure is a test that fails on a loaded machine rather than on a bug.
	_check(travelled > 3.0, "keys sent over the wire drive it", "%.2f m" % travelled)
	_check(fastest > 0.5, "forwards", "%.2f m/s at its fastest" % fastest)
	_check(
		mirror != null and mirror.global_position.distance_to(mirror_before) > 2.0,
		"and the client's copy went with it",
		"%.2f m" % (mirror.global_position.distance_to(mirror_before) if mirror != null else -1.0)
	)
	_check(
		mirror != null and mirror.global_position.distance_to(vehicle.position()) < 6.0,
		"to roughly where the server has it",
		"%.2f m apart" % (
			mirror.global_position.distance_to(vehicle.position()) if mirror != null else -1.0
		)
	)

	var net_behaviour := mirror.get_node_or_null("Net") as PlaygroundVehicleNet
	_check(
		net_behaviour != null and net_behaviour.seat_occupied(0),
		"the seat mask says the driving seat is full"
	)
	_check(
		net_behaviour != null and not net_behaviour.seat_occupied(1),
		"and the passenger seat is not"
	)

	# The rider's own position, which is the half that is invisible in one process.
	_check(
		driver.controller.state.position.distance_to(vehicle.position()) < 4.0,
		"the rider's replicated position is on the vehicle, not where they got in",
		"%.2f m" % driver.controller.state.position.distance_to(vehicle.position())
	)

	# Turning the wheels. A client cannot derive this from anything else it is sent.
	var turn := DotFpsCommand.new()
	turn.move = Vector2(1.0, 1.0)
	await _steps(60, turn)
	_exchange()
	await _steps(4)

	_check(
		net_behaviour != null and absf(net_behaviour.net_steering) > 2,
		"the wheels' angle crosses the wire",
		"quantised %d" % (net_behaviour.net_steering if net_behaviour != null else 0)
	)

	# Getting out, from the client, with the server owning the refusal.
	var brake := DotFpsCommand.new()
	brake.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	await _steps(200, brake)

	if mirror != null:
		await _measure_round_trip(vehicle, mirror, brake)

	_client_bridge.ask_use_vehicle()
	_exchange()
	await _steps(6)

	_check(not driver.riding, "the same key takes them back out")
	_check(vehicle.is_empty(), "leaving the car empty")
	_check(
		_client_player() != null and not _client_player().riding,
		"and the client is predicting them again"
	)
	_check(
		rider_body != null and not rider_body.is_seated_pose() and head != null
			and head.position.y > 1.4,
		"and standing up again",
		"head %.2f m" % (head.position.y if head != null else -1.0)
	)
	_check(
		driver.global_position.distance_to(vehicle.position()) > 0.9,
		"put down beside the car rather than inside it",
		"%.2f m" % driver.global_position.distance_to(vehicle.position())
	)

	_server_game.props.remove(spawned.instance_id, DotPropSpawner.REASON_ADMIN)
	_exchange()
	await _steps(6)

	_check(_find_vehicle_node(_client_game) == null, "and removing it removes the mirror")
	_done()


## [b]What the driver feels: how far their own car is behind their keys.[/b] See `[veh-3]`.
##
## dot-vehicle does not predict a vehicle, so the driver's throttle goes to the server and
## comes back as a snapshot, and what they see is the client's MIRROR of the car — drawn
## where [method DotNetManager.interpolate_frame] puts it, an interpolation buffer
## behind the newest snapshot. Measured here on the drawn mirror, over a loopback holding
## every message [constant VEHICLE_TRANSIT_TICKS] ticks each way and dropping every
## [constant VEHICLE_DROP_EVERY]rd snapshot:
##
## - per tick, the gap between the drawn mirror and the server's car (metres, degrees),
##   and the same gap as TIME: how many ticks back along the server's own path the mirror is;
## - key to visible: throttle on from rest, and steer on at speed, to the first tick the
##   server's car responds and the first tick the mirror does;
## - how long the mirror takes to land on the car once the car has stopped.
##
## The figures are printed; what is asserted is only that the mirror follows (key to
## visible under a generous bound) and converges once the car stops. The decision taken on
## these numbers is in docs/vehicles.md, "What a driver feels".
func _measure_round_trip(
	vehicle: DotVehicleInstance, mirror: Node3D, brake: DotFpsCommand
) -> void:
	var car := vehicle.body()
	# Turned round where it stands. The drive above ends nose-first against map geometry
	# (at about z -72, from a spawn at -60), and a throttle measured into a wall is a
	# latency of forever. Backwards along its own tracks is ground it has just crossed.
	car.global_basis = Basis(Vector3.UP, PI) * car.global_basis
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	var rate := float(_server_game.tick_rate)
	var ms := 1000.0 / rate

	_drop_every = VEHICLE_DROP_EVERY
	_delay_ticks = VEHICLE_TRANSIT_TICKS

	var gaps_m: Array[float] = []
	var gaps_deg: Array[float] = []
	var behind_ticks: Array[float] = []
	var trail: Array[Vector3] = []
	# Smoothness: while the car moves, how much the mirror's step this tick differs from
	# the car's. A mirror that stalls on a dropped snapshot and then jumps shows here.
	var step_err_cm: Array[float] = []
	var last_mirror := [mirror.global_position]

	# One tick: step, draw the mirror as the renderer would, and record the gap.
	var sample := func(command: DotFpsCommand) -> void:
		await _step(command)
		# The interpolation `PlaygroundClient.present_frame` does once a frame, called
		# directly: present_frame asks whether the manager is RUNNING first, and this
		# suite's hand-driven client is not started until a later section. The first run
		# of this measurement went through present_frame, drew the newest snapshot every
		# tick, and measured a mirror stepping at the snapshot rate that no real client has.
		_client_net.interpolate_frame(0.0)
		trail.append(car.global_position)
		gaps_m.append(mirror.global_position.distance_to(car.global_position))
		gaps_deg.append(absf(rad_to_deg(angle_difference(
			mirror.global_rotation.y, car.global_rotation.y
		))))
		var mirror_step: float = mirror.global_position.distance_to(last_mirror[0])
		last_mirror[0] = mirror.global_position
		# How far back along the server's own path the mirror sits, while it is moving.
		if vehicle.speed() > 1.0:
			var car_step := trail[trail.size() - 1].distance_to(trail[trail.size() - 2])
			step_err_cm.append(absf(mirror_step - car_step) * 100.0)
			var best := 0
			var best_d := INF
			for k in range(mini(trail.size(), 64)):
				var d := trail[trail.size() - 1 - k].distance_to(mirror.global_position)
				if d < best_d:
					best_d = d
					best = k
			behind_ticks.append(float(best))

	# Fill the pipe at a standstill, under the delay and the loss, and let the car settle.
	for _i in range(64):
		await sample.call(brake)

	# Throttle on, from rest.
	var driving_from := gaps_m.size()
	var rest_car := car.global_position
	var rest_mirror := mirror.global_position
	var throttle_car := -1
	var throttle_mirror := -1
	for i in range(90):
		await sample.call(_forward())
		if throttle_car < 0 and car.global_position.distance_to(rest_car) > RESPONSE_METRES:
			throttle_car = i + 1
		if throttle_mirror < 0 \
				and mirror.global_position.distance_to(rest_mirror) > RESPONSE_METRES:
			throttle_mirror = i + 1
	var speed_at_steer := vehicle.speed()

	# Steer on, at speed. Measured as a departure from the heading each was holding,
	# extrapolated at the yaw rate it had over the tick before the key.
	var steer := DotFpsCommand.new()
	steer.move = Vector2(-1.0, 1.0)
	var yaw_car := car.global_rotation.y
	var yaw_mirror := mirror.global_rotation.y
	await sample.call(_forward())
	var rate_car := angle_difference(yaw_car, car.global_rotation.y)
	var rate_mirror := angle_difference(yaw_mirror, mirror.global_rotation.y)
	yaw_car = car.global_rotation.y
	yaw_mirror = mirror.global_rotation.y
	var steer_car := -1
	var steer_mirror := -1
	# Whether the mirror's HEADING is drawn smoothly too: once it has started turning, the
	# ticks on which it did not turn at all.
	var turning_ticks := 0
	var held_ticks := 0
	var last_yaw := mirror.global_rotation.y
	for i in range(60):
		await sample.call(steer)
		var yaw_step := absf(rad_to_deg(angle_difference(last_yaw, mirror.global_rotation.y)))
		last_yaw = mirror.global_rotation.y
		if steer_mirror > 0:
			turning_ticks += 1
			if yaw_step < 0.01:
				held_ticks += 1
		var expect_car := yaw_car + rate_car * float(i + 1)
		var expect_mirror := yaw_mirror + rate_mirror * float(i + 1)
		if steer_car < 0 and absf(rad_to_deg(angle_difference(
			expect_car, car.global_rotation.y
		))) > RESPONSE_DEGREES:
			steer_car = i + 1
		if steer_mirror < 0 and absf(rad_to_deg(angle_difference(
			expect_mirror, mirror.global_rotation.y
		))) > RESPONSE_DEGREES:
			steer_mirror = i + 1

	var moving_gaps_m := gaps_m.slice(driving_from)
	var moving_gaps_deg := gaps_deg.slice(driving_from)

	# Brake to a stop, then count until the mirror is on the car.
	var stopped_at := -1
	var converged_after := -1
	for i in range(400):
		await sample.call(brake)
		if stopped_at < 0 and vehicle.speed() < 0.05:
			stopped_at = i
		if stopped_at >= 0 and gaps_m[gaps_m.size() - 1] < 0.05 \
				and gaps_deg[gaps_deg.size() - 1] < 1.0:
			converged_after = i - stopped_at
			break

	_drop_every = 0
	_delay_ticks = 0
	# Drain what the delayed link still holds before anything else runs on it.
	await _steps(VEHICLE_TRANSIT_TICKS + 4, brake)

	var interp := _client_net.interpolator
	print("    round trip: server %d Hz, snapshots %d Hz, every %drd snapshot dropped, " % [
		_server_game.tick_rate, SNAPSHOT_RATE, VEHICLE_DROP_EVERY
	] + "%d ticks (%.1f ms) each way, interpolation buffer %.1f ticks (%.1f ms)" % [
		VEHICLE_TRANSIT_TICKS, VEHICLE_TRANSIT_TICKS * ms,
		interp.delay_ticks() if interp != null else -1.0,
		interp.delay_ms() if interp != null else -1.0
	])
	print("    mirror vs car while driving: %s m, %s deg (median/p95/max, %d ticks, %.1f m/s at the steer)" % [
		_spread(moving_gaps_m), _spread(moving_gaps_deg), moving_gaps_m.size(), speed_at_steer
	])
	print("    mirror behind the car's own path: %s ticks (median/p95/max) = %.0f ms median" % [
		_spread(behind_ticks, "%.0f"), _percentile(behind_ticks, 0.5) * ms
	])
	print("    mirror's per-tick step against the car's: %s cm (median/p95/max)" % [
		_spread(step_err_cm)
	])
	print("    mirror's heading held still on %d of %d ticks while it turned" % [
		held_ticks, turning_ticks
	])
	print("    throttle: car moves %d ticks after the key, mirror %d ticks (%.0f ms)" % [
		throttle_car, throttle_mirror, throttle_mirror * ms
	])
	print("    steer:    car turns %d ticks after the key, mirror %d ticks (%.0f ms)" % [
		steer_car, steer_mirror, steer_mirror * ms
	])
	print("    stopped: car at rest %d ticks after the brake key, mirror on it %d ticks (%.0f ms) later" % [
		stopped_at + 1, converged_after, converged_after * ms
	])

	# Never before the server's car: a mirror that "responds" first was still moving from
	# something else, and the first armed run caught exactly that at 16 ticks against 50.
	_check(
		throttle_mirror >= throttle_car and throttle_car > 0
			and throttle_mirror <= KEY_TO_VISIBLE_LIMIT_TICKS,
		"the driver sees their throttle within %d ticks over a lossy link"
			% KEY_TO_VISIBLE_LIMIT_TICKS,
		"mirror %d ticks, car %d" % [throttle_mirror, throttle_car]
	)
	_check(
		steer_mirror >= steer_car and steer_car > 0
			and steer_mirror <= KEY_TO_VISIBLE_LIMIT_TICKS,
		"and their steering within %d" % KEY_TO_VISIBLE_LIMIT_TICKS,
		"mirror %d ticks, car %d" % [steer_mirror, steer_car]
	)
	_check(
		converged_after >= 0 and converged_after <= CONVERGE_LIMIT_TICKS,
		"and the mirror lands on the car within %d ticks of it stopping" % CONVERGE_LIMIT_TICKS,
		"%d ticks (stopped at %d)" % [converged_after, stopped_at]
	)
	# `[veh-heading-1]`: the rotation crossed as four INTs, which the interpolator
	# switches at the midpoint, so the body snapped round at the snapshot rate while its
	# position slid -- still on 26 of 31 turning ticks. A few still ticks are the lossy
	# link's stalls, not the format; armed with the INTs back, this fails.
	_check(
		turning_ticks > 10 and held_ticks * 5 <= turning_ticks,
		"and the mirror's heading turns on nearly every tick, not once a snapshot",
		"held still on %d of %d turning ticks" % [held_ticks, turning_ticks]
	)


func _percentile(values: Array[float], q: float) -> float:
	if values.is_empty():
		return -1.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(int(ceil(q * sorted.size())) - 1, 0, sorted.size() - 1)]


func _spread(values: Array[float], format: String = "%.2f") -> String:
	return "/".join([
		format % _percentile(values, 0.5),
		format % _percentile(values, 0.95),
		format % _percentile(values, 1.0),
	])


func _find_vehicle_node(game: Playground) -> PlaygroundVehicle:
	var world: Node = game.world if game.world != null else game

	for child in world.get_children():
		var vehicle := child as PlaygroundVehicle

		if vehicle != null:
			return vehicle

	return null


## A line typed on the client, through the real services layer, and back to the client.
##
## [b]Every other chat check in this file is the codec[/b] — an encoder against its
## decoder. This is the path: the client's SAY over the link, the server bridge's
## `say_requested`, [PlaygroundServices] on [DotGameServices]' sequence with a real dot-chat
## router and dot-moderation manager behind it, the bridge's CHAT event, and the client's
## `chat_received`. With no [DotServer], which the subclass's bridge-shaped answers
## (`_key_of`, `_chat_peers`, `_subject_for_peer`) are what make possible — the base's own
## answer to "who is this peer" is a session, and there is none here.
##
## Then a gag, through the moderation the base built first, keyed the way the subclass keys
## a peer with no session. Armed: without the subclass's `_subject_for_peer` the gagged line
## is delivered; without its `_send_chat` the line arrives with nobody's id on it.
func _test_chat_end_to_end() -> void:
	_section("a chat line, end to end through the services")

	var store := ProjectSettings.globalize_path(NET_PUNISHMENTS)
	DirAccess.remove_absolute(store)

	var services := PlaygroundServices.new()
	services.name = "Services"
	services.service_scope = &"server"
	services.bridge = _server_bridge
	services.punishments_path = NET_PUNISHMENTS
	_server_bridge.get_parent().add_child(services)

	var ready: DotResult = services.setup(null, _server_game, _server_bridge)
	_check(
		ready.ok, "the services come up on DotGameServices with no DotServer",
		str(ready.error) if not ready.ok else ""
	)
	_check(
		services.chat != null and services.moderation != null and services.voice != null,
		"with chat, moderation and voice"
	)
	_check(
		services.mod_tools == null,
		"and no second set of live tools, which are the module's"
	)
	_check(
		Array(_server_bridge.ready_peers()).has(CLIENT_PEER),
		"the client is a peer the bridge will send a line to"
	)

	var heard: Array[Dictionary] = []
	var refused: Array[DotResult] = []
	var on_chat := func(wire: Dictionary) -> void:
		heard.append(wire)
	var on_say := func(peer_id: int, channel_id: StringName, text: String) -> void:
		var said: DotResult = services.say(peer_id, channel_id, text)
		if not said.ok:
			refused.append(said)
	_client_bridge.chat_received.connect(on_chat)
	_server_bridge.say_requested.connect(on_say)

	_client_bridge.say(PlaygroundServices.CHANNEL_ALL, "hello from the client")
	_exchange()

	_check(heard.size() == 1, "the line comes back to the client, once", "%d" % heard.size())
	var got: Dictionary = heard[0] if heard.size() > 0 else {}
	_check(String(got.get("m", "")) == "hello from the client", "with the text")
	_check(
		String(got.get("c", "")) == String(PlaygroundServices.CHANNEL_ALL),
		"on the channel it was said on"
	)
	_check(
		typeof(got.get("x")) == TYPE_DICTIONARY
			and int((got["x"] as Dictionary).get("p", 0)) == SESSION,
		"stamped with who said it, the one meta field this wire carries",
		str(got.get("x"))
	)

	# [b]The backlog is the module's[/b], sent from `_welcome` once the bridge says the peer
	# is ready. The base sends one from `add_peer` unless told not to, and both at once is
	# every line of the backlog twice for everybody who joins.
	heard.clear()
	services.add_peer(CLIENT_PEER)
	_exchange()
	_check(
		heard.is_empty(),
		"seating a peer sends no backlog of its own, because the module sends it",
		"%d lines" % heard.size()
	)

	var subject := DotPunishmentSubject.for_uid("local:%d" % SESSION)
	var gagged: DotResult = await services.moderation.issue(
		DotPunishment.Kind.GAG, subject, "testing", "console", 60
	)
	_check(gagged.ok, "a gag is issued", str(gagged.error) if not gagged.ok else "")

	heard.clear()
	_client_bridge.say(PlaygroundServices.CHANNEL_ALL, "and now I am gagged")
	_exchange()

	var leaked := 0
	for wire in heard:
		if String(wire.get("m", "")) == "and now I am gagged":
			leaked += 1
	_check(
		leaked == 0 and refused.size() == 1,
		"and the gagged player's next line reaches nobody",
		"%d delivered, %d refused" % [leaked, refused.size()]
	)

	_server_bridge.say_requested.disconnect(on_say)
	_client_bridge.chat_received.disconnect(on_chat)
	services.get_parent().remove_child(services)
	services.free()
	DirAccess.remove_absolute(store)

	_check(
		not DotRegistry.has(DotModerationManager.MUTE_SERVICE),
		"and the mute source goes with it, so no later section inherits a gag"
	)
	_done()


func _test_timer() -> void:
	_section("the timer")

	# A run timer is `addons/pg_timer` over dot-timer, there only when a server links it;
	# without it nobody has one, on either end.
	var linked := FileAccess.file_exists("res://addons/dot_timer/plugin.cfg")
	var player := _client_player()
	_check(player != null and (player.timer != null) == linked,
		"the client player has a timer exactly when dot-timer is linked")

	# A client runs its own timer over its own copy of the zones and reaches the same
	# answer a tick earlier than any packet could, so both must count at one rate.
	var rates := [-1, -1]
	if linked:
		rates = [int(_client_game.run_timer.get("manager").get("tick_rate")),
			int(_server_game.run_timer.get("manager").get("tick_rate"))]
	_check(
		rates[0] == rates[1],
		"counted at one rate on both ends, which is what makes a time comparable",
		"%d vs %d" % rates
	)
	_done()


func _test_lossy() -> void:
	_section("with packets going missing")

	_drop_every = 3
	var before := _client_player().controller.state.position
	await _steps(96, _forward())
	var after := _client_player().controller.state.position
	_drop_every = 0

	_check(after.distance_to(before) > 1.0, "the client keeps moving through the loss",
		"%.2f m" % after.distance_to(before))

	var server_at := _server_player().controller.state.position
	_check(server_at.distance_to(after) < 2.0,
		"and stays with the server", "%.3f m apart" % server_at.distance_to(after))
	_done()


## An administrator's blind and beacon, through the real handlers, over the wire.
##
## [b]The audience is the whole point of both.[/b] This client (peer 2) owns player 7; a
## second player, 8, is added on the server with a peer of its own that has no client in
## this process — which makes THIS client the "somebody else" for player 8. A blind on 8
## is 8's screen and nobody else's, so this client must never be told; a blind on 7 is
## this client's own screen, so it must be; a beacon is for everybody. Asserted on the
## client's own copy of each player, which is what its HUD and its renderer read.
func _test_blind_and_beacon() -> void:
	_section("an admin's blind and beacon: who is told")

	var other_peer := CLIENT_PEER + 1
	var added := _server_bridge.add_player(other_peer, SESSION + 1, "Bea")
	_check(added.ok, "a second player joins on a peer of their own")
	await _steps(4)

	var theirs: PlaygroundPlayer = _client_game.players.get(&"u%d" % (SESSION + 1))
	_check(theirs != null, "and this client draws them")

	var server_net := _server_player().get_node_or_null("Net") as PlaygroundPlayerNet
	_check(
		server_net != null
		and server_net.find_var(&"net_blind").audience == DotNetVar.Audience.OWNER
		and server_net.find_var(&"net_beacon").audience == DotNetVar.Audience.EVERYONE,
		"the blind is declared owner-only and the beacon for everybody"
	)

	var handlers := PlaygroundModTools.handlers(_server_game, null)
	var blind: Callable = handlers[DotModTools.ACTION_BLIND]
	var beacon: Callable = handlers[DotModTools.ACTION_BEACON]
	var them := StringName(str(SESSION + 1))
	var me := StringName(str(SESSION))

	var on_blind: DotResult = blind.call(them, {"on": true, "actor": "1"})
	var on_beacon: DotResult = beacon.call(them, {"on": true, "actor": "1"})
	_check(on_blind.ok and on_beacon.ok, "the server blinds and beacons player 8")

	# Several snapshots' worth, so an absence below is not a snapshot that had not come.
	await _steps(12)

	var their_net := theirs.get_node_or_null("Net") as PlaygroundPlayerNet \
		if theirs != null else null
	_check(
		theirs != null and not theirs.blinded
		and their_net != null and not their_net.net_blind,
		"this client is never told somebody else is blind",
		"received net_blind = %s" % (str(their_net.net_blind) if their_net != null else "-")
	)
	_check(
		theirs != null and theirs.beacon,
		"but draws the beacon on them, because a beacon is for everybody"
	)
	_check(
		not _client_player().blinded and not _client_player().beacon,
		"and neither mark lands on this client's own player"
	)
	_check(
		_server_player().get_node("Identity").always_relevant
		and theirs != null and theirs.is_inside_tree(),
		"a beaconed player is relevant to every peer, as every player here already is"
	)

	var mine: DotResult = blind.call(me, {"on": true, "actor": "1"})
	await _steps(12)
	_check(
		mine.ok and _client_player().blinded,
		"a blind on this client's OWN player reaches it, so its HUD goes dark"
	)

	var _off_me: DotResult = blind.call(me, {"on": false, "actor": "1"})
	var _off_them: DotResult = blind.call(them, {"on": false, "actor": "1"})
	var _unlit: DotResult = beacon.call(them, {"on": false, "actor": "1"})
	await _steps(12)
	_check(
		not _client_player().blinded and theirs != null and not theirs.beacon,
		"and turning both off reaches the client"
	)

	# Creative mode is everybody's too: a watcher sees who is building, and this client's
	# own tools ask before the server has to refuse.
	var _creative := _server_game.set_creative(&"u%d" % (SESSION + 1), true)
	await _steps(12)
	_check(theirs != null and theirs.creative, "creative mode on somebody else reaches this client")
	var _plain := _server_game.set_creative(&"u%d" % (SESSION + 1), false)
	await _steps(12)
	_check(theirs != null and not theirs.creative, "and so does turning it off")

	_server_bridge.remove_player(SESSION + 1)
	await _steps(4)
	_check(
		not _client_game.players.has(&"u%d" % (SESSION + 1)),
		"the second player leaves again, so the sections after this one see one"
	)
	_done()
