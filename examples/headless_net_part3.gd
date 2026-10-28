extends "res://examples/headless_net_part2.gd"

var _lip_mine: PlaygroundPlayer
var _lip_identity
var _lip_server_from: Vector3

func _test_local_is_predicted() -> void:
	_section("this client predicts its own player, and nobody else")

	_lip_mine = _client_player()
	var mine_net := _lip_mine.get_node_or_null("Net") as PlaygroundPlayerNet if _lip_mine != null else null

	if mine_net == null or mine_net.identity == null:
		_check(false, "the client has its own player, replicated")
		return

	_lip_identity = mine_net.identity
	_check(
		_lip_identity.owner_peer_id == _client_net.local_peer_id and _lip_identity.is_owner,
		"the client's mirror of its own player is owned by this client (peer %d)"
			% _client_net.local_peer_id,
		"owner %d, is_owner %s" % [_lip_identity.owner_peer_id, str(_lip_identity.is_owner)]
	)

	var predicted := _client_net.registry.predicted()
	_check(
		predicted.size() == 1 and predicted[0] == _lip_identity,
		"so it is the one entity the client predicts",
		"predicted %d" % predicted.size()
	)

	# Somebody else, on a peer with no client in this process.
	var session := SESSION + 3
	var added := _server_bridge.add_player(CLIENT_PEER + 3, session, "Cy")
	await _steps(4)
	var theirs: PlaygroundPlayer = _client_game.players.get(&"u%d" % session)
	var theirs_net := theirs.get_node_or_null("Net") as PlaygroundPlayerNet if theirs != null else null
	_check(
		added.ok and theirs_net != null and theirs_net.identity != null
			and theirs_net.identity.owner_peer_id == 0
			and not theirs_net.identity.is_predicted(),
		"a second player is mirrored as the server's, and not predicted",
		"owner %s" % (str(theirs_net.identity.owner_peer_id) if theirs_net != null else "-")
	)
	_check(
		_client_net.registry.predicted().size() == 1,
		"and the client still predicts exactly one player",
		"%d" % _client_net.registry.predicted().size()
	)
	_server_bridge.remove_player(session)
	await _steps(4)

	# A key, and nothing from the server: one client tick, no server tick, no flush. Standing
	# still first, so the press is the only reason to move.
	await _steps(24)
	var client_from := _lip_mine.controller.state.position
	var node_from := _lip_mine.global_position
	_lip_server_from = _server_player().controller.state.position
	_tick += 1
	_client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_client_bridge.client_tick(_tick + INPUT_LEAD, _forward())
	var moved := _lip_mine.controller.state.position.distance_to(client_from)
	_check(
		_to_client.is_empty() and moved > 0.0005,
		"a key moves the player on the client in the tick it is pressed, before any snapshot",
		"%.4f m (a client that waits for the server moves 0)" % moved
	)
	_check(
		_lip_mine.global_position.distance_to(node_from) > 0.0005,
		"and the node the camera and the body follow moved with it",
		"%.4f m" % _lip_mine.global_position.distance_to(node_from)
	)
	await _test_local_is_predicted_2()
	await _test_local_is_predicted_3()

func _test_local_is_predicted_2() -> void:
	_check(
		_server_player().controller.state.position.distance_to(_lip_server_from) < 0.0001,
		"while the server has not moved them yet: this is prediction, not a snapshot"
	)

	# Key to motion, counted: ticks from the press to the client's player moving, over a whole
	# exchange with the server. Zero is the tick it was pressed in.
	await _steps(24)
	var still_from := _lip_mine.controller.state.position
	var latency := -1
	for i in range(16):
		await _step(_forward())
		if latency < 0 and _lip_mine.controller.state.position.distance_to(still_from) > 0.0005:
			latency = i
	_check(latency == 0, "key to motion over the link is zero ticks", "%d ticks" % latency)
	await _steps(24)

	# A move only the server made: the client cannot predict it and must be corrected to it.
	var corrections_before := _corrections_and_snaps()
	var server_mine := _server_player()
	var target := server_mine.controller.state.position + Vector3(3.0, 0.0, 0.0)
	server_mine.teleport(target, server_mine.controller.state.yaw)
	var before_gap := _lip_mine.controller.state.position.distance_to(target)
	await _steps(32)
	var server_at := server_mine.controller.state.position
	var gap := _lip_mine.controller.state.position.distance_to(server_at)
	var corrections := _corrections_and_snaps() - corrections_before
	_check(
		before_gap > 2.0 and gap < 0.05,
		"a teleport only the server made is corrected and converges",
		"%.2f m away when it happened, %.4f m after" % [before_gap, gap]
	)
	_check(
		_lip_mine.global_position.distance_to(server_at) < 0.05,
		"on the node as well as in the state",
		"%.4f m" % _lip_mine.global_position.distance_to(server_at)
	)
	_check(
		corrections > 0, "by the predictor, as a correction or a snap",
		"%d corrections and snaps" % corrections
	)
	_check(
		_client_net.registry.predicted().size() == 1 and _lip_identity.is_predicted(),
		"and the player is still predicted afterwards"
	)

	# [b]Both orders HELLO and this player's JOIN can arrive in, and each is its own half of
	# the fix.[/b] `add_player` broadcasts JOIN to every connected peer, the joiner included,
	# BEFORE that peer has asked to be admitted — so in this suite's handshake, as on any
	# server whose client is listening by then, JOIN comes first and the mirror is built
	# before the client knows it is its own: HELLO has to CLAIM it. Admitted again, `_admit`
	# sends HELLO first and JOIN after it, and the mirror has to be built owned. Each is
	# forced here, and each was armed on its own: without the claim, the first nine checks
	# above fail and so does the claim below; without the owned mirror, only the rebuild does.
	var _given := _client_net.registry.change_owner(_lip_identity.net_id, 0)
	_check(not _lip_identity.is_predicted(), "a mirror handed back to the server stops being predicted")
	_client_bridge.ask_ready()
	_exchange()
	await _steps(4)
	_check(
		_lip_identity.owner_peer_id == _client_net.local_peer_id and _lip_identity.is_predicted(),
		"and HELLO claims it again for this client (JOIN first)",
		"owner %d" % _lip_identity.owner_peer_id
	)

func _test_local_is_predicted_3() -> void:

	# HELLO first: the client forgets its mirror, as a LEAVE would, and is admitted again.
	_client_bridge._on_event(PlaygroundEvent.new(
		PlaygroundEvents.Kind.LEAVE, PlaygroundEvents.write_player(SESSION)
	))
	await get_tree().process_frame
	_check(_client_player() == null, "a client that forgot its own player has none")
	_client_bridge.ask_ready()
	_exchange()
	await _steps(4)
	var rebuilt := _client_player()
	var rebuilt_net := rebuilt.get_node_or_null("Net") as PlaygroundPlayerNet if rebuilt != null else null
	_check(
		rebuilt_net != null and rebuilt_net.identity != null
			and rebuilt_net.identity.owner_peer_id == _client_net.local_peer_id
			and rebuilt_net.identity.is_predicted()
			and _client_net.registry.predicted().size() == 1,
		"and a JOIN after HELLO builds it owned by this client, and predicted (HELLO first)",
		"owner %s" % (str(rebuilt_net.identity.owner_peer_id) if rebuilt_net != null else "-")
	)
	await _steps(8)
	_done()


# --- Props, which is what makes this a sandbox -----------------------------

var _pr_client_node: Node3D
var _pr_server_node: Node3D
var _pr_at_first: Vector3
var _pr_server_first: Vector3
var _pr_waited: int

func _test_prop_replication() -> void:
	_section("a prop the server spawns reaches the client")

	var catalogue := _server_game.props.catalogue
	_check(catalogue != null and catalogue.size() > 0, "the server has a prop catalogue",
		str(catalogue.size()) if catalogue != null else "none")

	# By id rather than by category: the categories are the spawn menu's tabs
	# (construction, containers, toys, entities) and a test that hard-codes a tab name
	# breaks when somebody renames one. A crate is a crate.
	var def := catalogue.get_prop(&"crate")
	_check(def != null, "the catalogue has a crate in it")

	if def == null:
		return
	# Well clear of the spawn pad and high above it. Dropped on the player's head it is
	# pushed sideways and UP by the capsule it is resting on, which is a perfectly real
	# physics result and a useless test: the assertion below is that gravity reaches the
	# client, not that two bodies collide.
	var spawned := _server_game.props.spawn(
		def.id, &"u%d" % SESSION, Vector3(18.0, 24.0, 18.0)
	)
	_check(spawned != null, "the server spawns one")

	if spawned == null:
		return

	_exchange()
	await _steps(4)

	var mirrored := int(_client_bridge.describe()["props"])
	_check(mirrored == 1, "the client mirrors it", "%d props" % mirrored)

	# [b]The id is ADOPTED, not allocated.[/b] dot-2d's scatter could not be mirrored at
	# all until it grew an adopt(): a peer that allocates its own index gives the same
	# object two different ids and every snapshot for it lands on nothing.
	var server_props := int(_server_bridge.describe()["props"])
	_check(server_props == mirrored, "under the id the server gave it, not one of its own")

	# And it MOVES. A prop that replicated its spawn and then sat still is the family's
	# "produced correctly and consumed by nothing" — the position looks right because it
	# was right once.
	_pr_client_node = _client_prop_node()
	_check(_pr_client_node != null, "the client built a body for it")

	if _pr_client_node == null:
		return

	# [b]Measured against the server's drop, not a fixed number of exchanges.[/b] This
	# was `_steps(64)` and then "has the mirror fallen 0.5 m", and it was reported failing
	# about one run in three with the mirror HIGHER than it started (23.99 -> 25.02). The
	# two ends tick at different rates, so a fixed count asks the client at a point in the
	# fall that differs from run to run; the server's crate is now watched until it has
	# really fallen a metre, and the client is then asked whether its copy is where the
	# server's is. [b]Not the cause, measured:[/b] the server's crate and the client's
	# mirror are in different `World3D`s (two space RIDs), so they cannot touch; a crate
	# pushed UP is the server's, or the interpolation's, and the print and the separate
	# server check below say which the next time it happens. 12 of 12 old-form runs
	# passed on 2026-09-24, so the 25.02 was not reproduced.
	_pr_server_node = _server_prop_node()
	_check(_pr_server_node != null, "the server has a body for it")

	if _pr_server_node == null:
		return

	_pr_at_first = _pr_client_node.global_position
	_pr_server_first = _pr_server_node.global_position
	_pr_waited = 0
	await _test_prop_replication_2()

func _test_prop_replication_2() -> void:

	while _pr_server_node.global_position.y > _pr_server_first.y - 1.0 and _pr_waited < 512:
		await _steps(1)
		_pr_waited += 1

	# A few more exchanges, so the client's interpolation has the last snapshots.
	await _steps(8)

	var server_last := _pr_server_node.global_position
	var at_last := _pr_client_node.global_position

	print("    the crate: server %.2f -> %.2f in %d steps, client %.2f -> %.2f" % [
		_pr_server_first.y, server_last.y, _pr_waited, _pr_at_first.y, at_last.y,
	])

	_check(server_last.y < _pr_server_first.y - 1.0,
		"the server's physics drops it a metre",
		"%.2f -> %.2f in %d steps" % [_pr_server_first.y, server_last.y, _pr_waited])
	_check(at_last.y < _pr_at_first.y - 0.5,
		"and it falls on the client because the server's physics moved it",
		"%.2f -> %.2f" % [_pr_at_first.y, at_last.y])
	_check(at_last.distance_to(_pr_at_first) > 0.5,
		"which is movement the client did not simulate for itself")
	# Within 0.5 m: the client draws an interpolated past, some ticks behind the server,
	# and a crate falling at ~5 m/s covers 0.5 m in about thirteen of the server's ticks.
	_check(
		server_last.distance_to(at_last) < 0.5,
		"where the server has it",
		"%.3f m apart" % server_last.distance_to(at_last)
	)

	# A mirrored rigid body must not simulate locally as well: an unfrozen one fights
	# every position written into it and jitters against gravity.
	var body := _pr_client_node as RigidBody3D
	_check(body == null or body.freeze, "the mirrored body does not simulate itself too")

	# `[prop-mirror-layer-1]`: the mirror is on the layout's props layer with its mask,
	# as the server's body is — not the scene's 1/1, which made a crate scenery to a
	# client that predicts its own player against its own copy of the world.
	var client_body := _pr_client_node as CollisionObject3D
	var server_body := _pr_server_node as CollisionObject3D
	_check(
		client_body != null and server_body != null
			and server_body.collision_layer != 1
			and client_body.collision_layer == server_body.collision_layer
			and client_body.collision_mask == server_body.collision_mask,
		"and it is on the server's collision layer and mask, not the scene's",
		"client %d/%d, server %d/%d" % [
			client_body.collision_layer if client_body != null else -1,
			client_body.collision_mask if client_body != null else -1,
			server_body.collision_layer if server_body != null else -1,
			server_body.collision_mask if server_body != null else -1,
		]
	)

	_done()


## The tool gun's resize and paint, and an armed NPC's weapon, over the wire.
##
## [b]Last, and that placement is the point[/b], for the reason the comment in `_run` gives:
## both halves are one physics space and one snapshot stream, and the vehicle check drops
## every third snapshot — so steps added anywhere before it move its phase. Put inside the
## prop section first, these checks took that check from passing to "held still on 7 of 33"
## every run, with the new prop fields themselves ruled out by turning them off.
var _tlaan_crate: DotPropInstance
var _tlaan_soldier: DotPropInstance
var _tlaan_armed_mirror: PlaygroundNpcNet

func _test_tool_look_and_armed_npcs() -> void:
	_section("a resized, painted prop and an armed NPC reach the client")

	# Its own crate: the replication section's is long gone by now.
	_tlaan_crate = _server_game.props.spawn(&"crate", &"u%d" % SESSION, Vector3(14.0, 3.0, -14.0))
	_exchange()
	await _steps(8)
	var server_net: PlaygroundPropNet = _server_bridge.get("_prop_nets").get(_tlaan_crate.instance_id) if _tlaan_crate != null else null
	var server_node: Node3D = _tlaan_crate.node if _tlaan_crate != null else null
	var client_node: Node3D = _client_bridge.call("_mirror_node", server_net.identity.net_id) if server_net != null else null

	if server_node == null or client_node == null:
		_check(false, "a crate is spawned and mirrored for this section")
		return

	# The tool gun's resize and paint reach the client, and the mirror is REBUILT at the new
	# size rather than drawn at the old one — a crate the server made twice as big that
	# clients still draw normal-sized is a crate players walk into the invisible half of.
	server_node.call("set_size_scale", 2.0)
	server_node.call("set_tint", Color(0.9, 0.2, 0.2))
	# Waited for rather than counted: by now the suite's link carries a delay and drops
	# snapshots, so a fixed count asks at a different point in the stream each run.
	for i in 128:
		await _steps(1)
		if absf(float(client_node.get("size_scale")) - 2.0) < 0.02 and (client_node.get("tint") as Color).a > 0.0:
			break
	_check(absf(float(client_node.get("size_scale")) - 2.0) < 0.02,
		"a resize reaches the client", "%.3f" % float(client_node.get("size_scale")))
	var mirror_box := (client_node.get_node_or_null("Collision") as CollisionShape3D)
	_check(mirror_box != null and (mirror_box.shape as BoxShape3D).size.x > 1.9,
		"and the mirror is rebuilt at that size")
	_check((client_node.get("tint") as Color).r > 0.8 and (client_node.get("tint") as Color).g < 0.3,
		"and so does a coat of paint")

	# Two ropes on the one crate are both drawn. One slot per prop used to be replicated,
	# so the second rope on a prop was simulated by the server and drawn by nobody.
	var crate_body := server_node as RigidBody3D
	var first: DotResult = _server_game.constraints.rope(&"u%d" % SESSION, crate_body,
		crate_body.global_position, null, crate_body.global_position + Vector3(0, 4, 0), 0.0, false)
	var second: DotResult = _server_game.constraints.rope(&"u%d" % SESSION, crate_body,
		crate_body.global_position, null, crate_body.global_position + Vector3(3, 4, 0), 0.0, false)
	var client_prop_net: PlaygroundPropNet = null
	for net in _client_bridge.get("_prop_nets").values():
		if net is PlaygroundPropNet and (net as PlaygroundPropNet).prop == client_node:
			client_prop_net = net
	for i in 128:
		await _steps(1)
		if client_prop_net != null and client_prop_net.ropes_drawn() == 2:
			break
	_check(first.ok and second.ok and client_prop_net != null and client_prop_net.ropes_drawn() == 2,
		"two ropes on one prop are both drawn on the client",
		"%d drawn" % (client_prop_net.ropes_drawn() if client_prop_net != null else -1))
	_server_game.constraints.remove(first.value)
	for i in 128:
		await _steps(1)
		if client_prop_net != null and client_prop_net.ropes_drawn() == 1:
			break
	_check(client_prop_net != null and client_prop_net.ropes_drawn() == 1,
		"and taking one off takes that one away")
	_check(client_prop_net != null and client_prop_net.net_rope_b.distance_to(crate_body.global_position + Vector3(3, 4, 0)) < 0.5,
		"leaving the other", str(client_prop_net.net_rope_b) if client_prop_net != null else "")
	_server_game.constraints.remove(second.value)

	# An armed NPC's mirror holds its weapon: the client is told which, and draws it.
	_tlaan_soldier = _server_game.props.spawn(&"npc_soldier", &"u%d" % SESSION, Vector3(-18.0, 2.0, -18.0))
	_check(_tlaan_soldier != null, "the server spawns an armed NPC")
	_exchange()
	_tlaan_armed_mirror = null
	await _test_tool_look_and_armed_npcs_2()

func _test_tool_look_and_armed_npcs_2() -> void:
	for i in 128:
		await _steps(1)
		for net in _client_bridge.get("_prop_nets").values():
			if net is PlaygroundNpcNet:
				_tlaan_armed_mirror = net
		if _tlaan_armed_mirror != null and _tlaan_armed_mirror.net_weapon != "":
			break
	var server_side := ""
	for net in _server_bridge.get("_prop_nets").values():
		if net is PlaygroundNpcNet:
			server_side = (net as PlaygroundNpcNet).net_weapon
	_check(_tlaan_armed_mirror != null and _tlaan_armed_mirror.net_weapon == "zee_smg",
		"the client is told which weapon the NPC holds",
		"client '%s', server '%s'" % [_tlaan_armed_mirror.net_weapon if _tlaan_armed_mirror != null else "(no mirror)", server_side])
	_check(_tlaan_armed_mirror != null and _tlaan_armed_mirror.prop.get_node_or_null("Hands") != null,
		"and puts one in its hands")
	# A wave NPC reaches the client too, through the same path: it was never replicated,
	# so a connected player was hunted by a wave they could not see.
	var waves := DotNpcSpawner.new()
	waves.name = "TestWaves"
	waves.catalogue = PlaygroundWaves.shared_catalogue()
	var limits := DotNpcLimits.new()
	limits.spawn_interval = 0.0
	limits.require_navigable_spawn = false
	waves.limits = limits
	waves.authoritative = true
	_server_game.world.add_child(waves)
	_server_bridge.watch_npc_spawner(waves, PlaygroundWaves.shared_catalogue())

	var props_before := int(_client_bridge.describe()["props"])
	var wave := waves.spawn(&"walker", Vector3(-10.0, 1.0, 10.0))
	_check(wave != null, "a wave NPC spawns on the server")
	_exchange()
	for i in 128:
		await _steps(1)
		if int(_client_bridge.describe()["props"]) > props_before:
			break
	_check(int(_client_bridge.describe()["props"]) == props_before + 1, "and the client builds it")

	if wave != null:
		(wave.node as Node3D).global_position = Vector3(-6.0, 1.0, 10.0)
		var mirror_of: Node3D = null
		for i in 128:
			await _steps(1)
			var wave_net: PlaygroundPropNet = _server_bridge.get("_prop_nets").get(wave.instance_id)
			mirror_of = _client_bridge.call("_mirror_node", wave_net.identity.net_id) if wave_net != null else null
			if mirror_of != null and mirror_of.global_position.distance_to(Vector3(-6.0, 1.0, 10.0)) < 0.3:
				break
		_check(mirror_of != null and mirror_of.global_position.distance_to(Vector3(-6.0, 1.0, 10.0)) < 0.3,
			"and draws it where the server has it",
			str(mirror_of.global_position) if mirror_of != null else "no mirror")
		waves.remove(wave.instance_id)
		_exchange()
		for i in 128:
			await _steps(1)
			if int(_client_bridge.describe()["props"]) == props_before:
				break
		_check(int(_client_bridge.describe()["props"]) == props_before, "and lets it go when the server does")

	waves.queue_free()

	if _tlaan_soldier != null:
		_server_game.props.remove(_tlaan_soldier.instance_id)
	_server_game.props.remove(_tlaan_crate.instance_id)
	_exchange()
	await _steps(4)
	_done()


## The client's props are children of its world; the one carrying a net behaviour is
## what the bridge built.
func _client_prop_node() -> Node3D:
	return _find_prop_node(_client_game)


func _server_prop_node() -> Node3D:
	return _find_prop_node(_server_game)


func _find_prop_node(game: Playground) -> Node3D:
	var world: Node = game.world if game.world != null else game
	for child in world.get_children():
		for grandchild in child.get_children():
			if grandchild is PlaygroundPropNet:
				return child as Node3D
	return null


func _test_prop_request() -> void:
	_section("a client asks for a prop")

	var before := int(_server_bridge.describe()["props"])

	var catalogue := _client_game.props.catalogue
	var choice := catalogue.get_prop(&"barrel")
	_check(choice != null, "the client has the same catalogue the server does")

	if choice == null:
		return

	# What the presentation layer hears. An Array because a lambda captures locals by
	# value, and a counter assigned inside it would stay at zero out here.
	var arrivals: Array = []
	var hear := func(_at: Vector3, owner_session: int) -> void: arrivals.append(owner_session)
	_client_bridge.prop_arrived.connect(hear)

	# The spawn menu emits rather than spawning, which is the division this bridge was
	# waiting for: the client sends intent and the server owns the answer.
	_client_bridge.ask_spawn_prop(choice.id)
	_exchange()
	await _steps(4)

	var after := int(_server_bridge.describe()["props"])
	_check(after == before + 1, "the server spawned it", "%d -> %d" % [before, after])

	_exchange()
	await _steps(4)
	_check(
		int(_client_bridge.describe()["props"]) == after,
		"and the client was told about the one it asked for"
	)
	# The client makes its own spawn's noise by comparing this with its own session, so
	# an arrival that named nobody, or the server, would leave every spawn silent.
	_check(
		arrivals.size() == 1 and int(arrivals[0]) == _client_bridge.local_player_id,
		"and the arrival names the asking client as its owner, which is what makes it 'mine'",
		"%s, local %d" % [str(arrivals), _client_bridge.local_player_id]
	)
	_client_bridge.prop_arrived.disconnect(hear)

	# A prop this build does not have is refused, not guessed at.
	_client_bridge.ask_spawn_prop(&"no_such_prop_at_all")
	_exchange()
	await _steps(2)
	_check(
		int(_server_bridge.describe()["props"]) == after,
		"an unknown prop id spawns nothing"
	)

	# A path is not an id: a client cannot name a model file, only a catalogue entry.
	for hostile in [&"res://assets/props/food/apple.glb", &"../../etc/passwd", &"user://props/x.glb"]:
		_client_bridge.ask_spawn_prop(hostile)
	_exchange()
	await _steps(2)
	_check(
		int(_server_bridge.describe()["props"]) == after,
		"a model path named as an id spawns nothing"
	)

	# A stock model prop is an id like any other.
	_client_bridge.ask_spawn_prop(&"sofa")
	_exchange()
	await _steps(4)
	_check(
		int(_server_bridge.describe()["props"]) == after + 1,
		"a stock model prop spawns for a client by id"
	)
	_done()


## The physics gun, over the wire.
##
## [b]A tool that never grabs anything is invisible to every other check here.[/b] The
## props still replicate, the player still moves, and the only symptom is that clicking
## does nothing — which is exactly the shape of bug this family keeps shipping: a value
## produced and consumed by nothing, or in this case a button sent and read by nobody.
func _test_tools() -> void:
	_section("the physics gun, over the wire")

	# Put a crate right in front of the player, at their own height.
	var player := _server_player()
	_check(player != null, "there is a player to aim")

	if player == null:
		return

	# Out of the park first. pg_flatgrass puts beach balls and barrels round the spawn, and a
	# crate held over one rests on it: carried 0.41 m in a swing that should take it 1.7.
	player.teleport(Vector3(-40.0, 0.0, -40.0), player.controller.state.yaw)
	await _steps(8)

	var at := player.eye_position() + player.aim_direction() * 2.5
	var why := PackedStringArray()
	var watch := func(_pid: StringName, _prop: StringName, reason: String) -> void:
		why.append(reason)
	_server_game.props.refused.connect(watch)
	var crate := _server_game.props.spawn(&"crate", &"u%d" % SESSION, at)
	_server_game.props.refused.disconnect(watch)
	_check(crate != null, "a crate is put in front of them", ", ".join(why))

	if crate == null:
		return

	await _exchange_steps(4)

	# The client selects the physics gun and holds the primary trigger, which is a
	# BUTTON on the command rather than a request — see PlaygroundNetBridge._drive_tools.
	_client_bridge.ask_tool(&"phys")
	_exchange()
	await _steps(2)

	# [b]Aimed at where the crate ended up, not at where it was put.[/b] It is a rigid
	# body dropped at eye height and it falls about a third of a metre before the button
	# is held — so a grab command that carries the default pitch is a ray over the top of
	# it, and whether the tool fires depends on how many ticks the sections above happened
	# to take. Aiming at the settled body is what makes this a test of the button.
	var grab := DotFpsCommand.new()
	grab.set_button(DotFpsCommand.BUTTON_USER_0, true)
	_aim_at(grab, player, (crate.node as Node3D).global_position)
	await _steps(12, grab)

	_check(player.phys_gun.held != null,
		"the server's physics gun grabbed it from a held button")

	if player.phys_gun.held == null:
		return

	# Held means carried: the prop tracks the player's aim rather than resting where it
	# was. Moving it and seeing the prop follow is the difference between "grabbed" and
	# "grabbed and then dropped on the next tick".
	var held_at := (crate.node as Node3D).global_position
	var turn := DotFpsCommand.new()
	turn.set_button(DotFpsCommand.BUTTON_USER_0, true)
	turn.pitch = player.controller.state.pitch
	turn.yaw = player.controller.state.yaw + 40.0
	await _steps(16, turn)

	var moved_to := (crate.node as Node3D).global_position
	_check(moved_to.distance_to(held_at) > 0.5,
		"and holding it carries it with the aim", "%.2f m" % moved_to.distance_to(held_at))

	# Releasing the button drops it. A gun that never lets go is a gun with one use.
	await _steps(4, DotFpsCommand.new())
	_check(player.phys_gun.held == null, "releasing the button lets go")

	_server_game.props.remove(crate.instance_id, DotPropSpawner.REASON_ADMIN)
	await _exchange_steps(4)
	_done()


## Points [param command] at [param target] from [param player]'s eye.
##
## The inverse of [method DotFpsMotor.aim_for], and it is written as the inverse rather
## than copied from it: a test that restates the view convention is a second place for
## it to be wrong.
func _aim_at(command: DotFpsCommand, player: PlaygroundPlayer, target: Vector3) -> void:
	var to := target - player.eye_position()

	if to.length_squared() <= 0.0:
		return

	to = to.normalized()
	command.yaw = rad_to_deg(atan2(-to.x, -to.z))
	command.pitch = rad_to_deg(asin(clampf(to.y, -1.0, 1.0)))


## A weapon is a purchase, and the client has to ask for it.
##
## [b]This is the check that was missing, and the hole it left was money.[/b]
## `PlaygroundClient._set_tool` told the server which TOOL it held and said nothing at
## all about a weapon — so `_give_weapon`, the only thing that calls `charge_fn`, was
## called by nobody. `pg_shop` prices every weapon at 350 credits and every one of them
## was free on a networked server, with the props beside them correctly charged. Nothing
## errors: a client that arms itself looks exactly like a client that was given one.
##
## The other half is the same bug pointing the other way — the server broadcast what
## each player was holding and the client's reader was a bare `pass`.
func _test_weapon_request() -> void:
	_section("a weapon is asked for, paid for and announced")

	# A price list that records rather than a real shop: what is being tested is that
	# the charge is REACHED, and a shop here would test dot-economy's arithmetic twice.
	var charged: Array[StringName] = []
	var refuse := [false]
	_server_bridge.charge_fn = func(_id: StringName, thing: StringName) -> DotResult:
		charged.append(thing)
		if bool(refuse[0]):
			return DotResult.fail(DotError.CODE_STATE, "You cannot afford that.")
		return DotResult.success(null)

	var told: Array = []
	_client_bridge.weapon_changed.connect(
		func(pid: int, wid: StringName) -> void: told.append([pid, wid])
	)

	_client_bridge.ask_weapon(&"launcher")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)

	_check(
		charged.has(&"launcher"),
		"the server charged for the weapon",
		"charged: %s" % [charged]
	)
	_check(told.size() > 0, "and told the clients who is holding what")
	if told.size() > 0:
		_check(
			StringName(told[-1][1]) == &"launcher",
			"and it is the weapon that was asked for"
		)

	# A weapon nobody can afford is refused, and the refusal must not announce it: a
	# client that armed itself and was refused would be holding what it was denied.
	refuse[0] = true
	var before := told.size()
	_client_bridge.ask_weapon(&"remover")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)
	_check(charged.has(&"remover"), "a second weapon is charged for too")
	_check(
		told.size() == before,
		"and a refused purchase announces nothing",
		"%d -> %d" % [before, told.size()]
	)

	# A weapon this build does not have is refused before the money is touched.
	var paid := charged.size()
	_client_bridge.ask_weapon(&"no_such_weapon_at_all")
	_exchange()
	await _steps(2)
	_check(charged.size() == paid, "an unknown weapon id charges nothing")

	refuse[0] = false
	_server_bridge.charge_fn = Callable()
	_done()


## A spawn the prop budget refuses costs nothing.
##
## [b]It cost the price.[/b] `_spawn_for` charged and then spawned, so a spawn the spawner
## refused had been paid for — credits gone and nothing in the world. It asks now, spawns,
## and charges only what exists; the check below fails on the old order.
func _test_refused_spawn_is_free() -> void:
	_section("a spawn the prop budget refuses costs nothing")

	var charged: Array[StringName] = []
	_server_bridge.charge_fn = func(_id: StringName, thing: StringName) -> DotResult:
		charged.append(thing)
		return DotResult.success(null)
	var notices: Array[String] = []
	var on_notice := func(_pid: int, text: String) -> void: notices.append(text)
	_client_bridge.notice_received.connect(on_notice)

	var spawner := _server_game.props
	var budget := spawner.limits.world_budget
	var props := spawner.world_count()
	var spent := spawner.world_cost()
	var bag := _server_bridge.inventory_net.bag_key(SESSION)
	_check(
		spent > 0 and _server_game.inventory.carries(bag, &"barrel") == 0,
		"the world has props in it and the bag has no barrel, so a spawn is bought, not carried",
		"cost %d" % spent
	)
	# Full: a world budget of exactly what is already spent.
	spawner.limits.world_budget = spent
	_client_bridge.ask_spawn_prop(&"barrel")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(2)
	_check(spawner.world_count() == props, "the spawner refuses a barrel past the world budget")
	_check(charged.is_empty(), "and nobody is charged for it", str(charged))
	_check(
		notices.size() == 1 and notices[0].contains("prop limit"),
		"and the player is told why, by the spawner",
		str(notices)
	)
	spawner.limits.world_budget = budget

	# Asked before anything is spawned: a player who cannot afford it gets nothing placed.
	notices.clear()
	_server_bridge.may_charge_fn = func(_id: StringName, _thing: StringName) -> DotResult:
		return DotResult.fail(DotError.CODE_STATE, "$100 short of 'barrel'.")
	_client_bridge.ask_spawn_prop(&"barrel")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(2)
	_check(
		spawner.world_count() == props and charged.is_empty(),
		"a spawn nobody can afford places nothing and charges nothing"
	)
	_check(notices.size() == 1 and notices[0].contains("short"), "and says so", str(notices))
	_server_bridge.may_charge_fn = Callable()

	# And one that is allowed is charged once, after it exists. Taken back out, because every
	# body in this one physics space moves the readings of the sections after it.
	_client_bridge.ask_spawn_prop(&"barrel")
	_exchange()
	await _steps(4)
	_check(
		spawner.world_count() == props + 1 and charged.size() == 1 and charged[0] == &"barrel",
		"a barrel that fits is spawned, and charged for once",
		"%d props, charged %s" % [spawner.world_count() - props, str(charged)]
	)
	spawner.undo(_client_player().player_id if _client_player() != null else &"u%d" % SESSION)
	await _steps(2)

	_client_bridge.notice_received.disconnect(on_notice)
	_server_bridge.charge_fn = Callable()
	_done()
