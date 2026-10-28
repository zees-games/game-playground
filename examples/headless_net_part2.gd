extends "res://examples/headless_net_part1.gd"

## The map's time left, from the server's vote to what the client's HUD draws.
##
## The HUD drew the client's own map session, which starts when the client loads the map
## and hears nothing the server decides — so an extend changed the server's clock and
## not one pixel on a client, and the deployed `trigger: rtv_only` with no limit showed
## thirty minutes counting down to nothing. This is the check that both reach the screen.
func _test_clock_wire() -> void:
	_section("the vote's clock over the link")

	var round_trip := PlaygroundEvents.read_clock(DotNetReader.new(
		PlaygroundEvents.write_clock({"has_clock": true, "seconds_left": 1234, "running": true})
	))
	_check(
		bool(round_trip["ok"]) and bool(round_trip["has_clock"])
			and int(round_trip["seconds_left"]) == 1234 and bool(round_trip["running"]),
		"a CLOCK round-trips, with the flag, the seconds and whether it counts"
	)

	# A real vote on the server's game, on this game's own rules. `setup` does not apply
	# or register anything; the module is what would.
	var vote := PlaygroundVote.new()
	vote.name = "ClockVote"
	vote.config_path = ""
	add_child(vote)
	var built := vote.setup(_server_game)
	_check(built.ok, "a vote is built on the server's game", str(built.error) if not built.ok else "")
	if not built.ok:
		remove_child(vote)
		vote.free()
		return
	vote.note_playing(_server_game.maps.current.id)

	var arrived: Array[Dictionary] = []
	var on_clock := func(state: Dictionary) -> void: arrived.append(state)
	_client_bridge.clock_received.connect(on_clock)
	vote.clock_due.connect(_server_bridge.broadcast_clock)
	var dt := 1.0 / float(_server_game.tick_rate)

	vote.advance(dt)
	_flush()
	var now := Time.get_ticks_msec() / 1000.0
	var before := _client_bridge.clock_view.remaining_at(now)
	_check(
		arrived.size() == 1 and _client_bridge.clock_view.has_clock
			and absf(before - vote.director.clock.remaining) <= 1.0,
		"the client is told the vote's time left (%.0f s, the server's is %.0f s)" % [
			before, vote.director.clock.remaining
		]
	)
	_check(
		PlaygroundHud.time_left_text(_client_bridge.clock_view, "9:59", now)
			== _client_bridge.clock_view.formatted_at(now),
		"and the HUD draws that rather than the client's own map clock (%s)" % (
			PlaygroundHud.time_left_text(_client_bridge.clock_view, "9:59", now)
		)
	)

	for i in range(_server_game.tick_rate * 3):
		vote.advance(dt)
	_flush()
	_check(
		arrived.size() == 1,
		"three quiet seconds send nothing: the client counts them itself (%d sent)" % (
			arrived.size() - 1
		)
	)

	var extend_by := vote.director.rules.extend_seconds
	_check(vote.director.clock.extend(), "the server extends the map")
	vote.advance(dt)
	_flush()
	now = Time.get_ticks_msec() / 1000.0
	var after := _client_bridge.clock_view.remaining_at(now)
	_check(
		arrived.size() == 2 and absf((after - before) - (extend_by - 3.0)) <= 2.0,
		"and what the client sees moves by the extension (%.0f s -> %.0f s, extended by %.0f)" % [
			before, after, extend_by
		],
		"the HUD would go on counting down the old limit"
	)

	# The deployed shape: `metadata: map_vote: {trigger: rtv_only, duration_sec: 0}`.
	vote.director.rules.duration_sec = 0.0
	vote.director.rules.trigger = DotVoteRules.Trigger.RTV_ONLY
	vote.note_playing(_server_game.maps.current.id)
	vote.advance(dt)
	_flush()
	now = Time.get_ticks_msec() / 1000.0
	_check(
		arrived.size() == 3 and not _client_bridge.clock_view.has_clock,
		"an rtv-only vote with no limit tells the client there is no clock"
	)
	_check(
		PlaygroundHud.time_left_text(_client_bridge.clock_view, "29:59", now) == "",
		"and the HUD shows none, rather than the local session's thirty minutes"
	)
	_check(
		PlaygroundHud.time_left_text(null, "29:59", now) == "29:59",
		"while a HUD nothing has told (offline) keeps the local session's, which is the real one there"
	)

	_client_bridge.clock_received.disconnect(on_clock)
	_client_bridge.clock_view = DotVoteClockView.new()
	remove_child(vote)
	vote.free()
	_done()


## A request and its answer: the answer is queued during the first flush and delivered
## by the second.
func _exchange() -> void:
	_flush()
	_flush()


## One tick on both ends, with a real physics frame between them.
##
## [b]The awaited physics frame is not padding.[/b] A player's movement is swept by
## dot-player-controller and lands wherever the arithmetic says, so a suite that drives
## ticks in a tight loop moves players perfectly — which is why every other net suite in
## this family gets away without one. A PROP is a [RigidBody3D], integrated by Godot's
## physics server on the physics frame and by nothing else. Without this await the
## server's props never move, the client's copies match them exactly, and every
## assertion about replicated props passes while nothing has been replicated at all.
##
## That is this family's own "a test that passes for the wrong reason", reached by the
## one route a sandbox has and a shooter does not.
## The Q menu's Builds tab: the list is asked for and sent back, and a click asks for one
## build by name. The module answers both (dedicated's saved builds); this is the wire.
func _test_builds_over_the_wire() -> void:
	_section("saved builds over the wire")

	var asked: Array = []
	var loads: Array = []
	var on_asked := func(peer_id: int) -> void: asked.append(peer_id)
	var on_load := func(peer_id: int, build_name: String) -> void: loads.append([peer_id, build_name])
	var got: Array = []
	var on_list := func(list: Array) -> void: got.append(list)
	_server_bridge.builds_requested.connect(on_asked)
	_server_bridge.build_load_requested.connect(on_load)
	_client_bridge.builds_received.connect(on_list)

	_client_bridge.ask_builds()
	_exchange()
	await _steps(2)
	_check(asked == [CLIENT_PEER], "the client's Builds tab asks the server", str(asked))

	_server_bridge.send_builds(CLIENT_PEER, [{"name": "bridge", "props": 6, "custom": false}, {"name": "car", "props": 9, "custom": true}])
	_exchange()
	await _steps(2)
	var list: Array = got[0] if not got.is_empty() else []
	_check(list.size() == 2 and list[1]["name"] == "car" and bool(list[1]["custom"]),
		"and the list it sends back arrives whole", str(got))

	_client_bridge.ask_load_build("car")
	_exchange()
	await _steps(2)
	_check(loads == [[CLIENT_PEER, "car"]], "a click asks for that build by name", str(loads))

	_server_bridge.builds_requested.disconnect(on_asked)
	_server_bridge.build_load_requested.disconnect(on_load)
	_client_bridge.builds_received.disconnect(on_list)
	_done()


## The tool gun's edit mode over the wire: the server selects, tells only the asker what the
## prop IS (named by the net id its mirror has), and an edit from the menu lands on the
## server's prop and comes back to the mirror.
func _test_edit_over_the_wire() -> void:
	_section("editing a selected prop over the wire")

	var theirs := _server_player()
	var id: StringName = theirs.player_id if theirs != null else &""
	_server_game.props.clear_player(id)
	await _steps(4)
	var crate := _server_game.props.spawn(&"crate", id, theirs.eye_position() + theirs.aim_direction() * 2.5)
	if crate == null:
		_check(false, "a crate in front of the player")
		_done()
		return
	DotPhysGun.set_frozen(crate, true)
	(crate.node as Node3D).call("set_tint", Color.html("e05252"))

	var got: Array = []
	var on_selection := func(state: Dictionary) -> void: got.append(state)
	_client_bridge.selection_received.connect(on_selection)

	_client_bridge.ask_weapon(&"toolgun")
	_client_bridge.ask_tool_mode(&"edit", {})
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)

	var fire := DotFpsCommand.new()
	fire.set_button(DotFpsCommand.BUTTON_USER_0, true)
	await _steps(2, fire)
	_exchange()
	await _steps(6)

	var server_net: PlaygroundPropNet = _server_bridge._prop_nets.get(crate.instance_id)
	var net_id: int = server_net.identity.net_id if server_net != null and server_net.identity != null else -1
	var first: Dictionary = got[0] if not got.is_empty() else {}
	_check(not got.is_empty() and int(first.get("net_id", 0)) == net_id,
		"a click selects the crate on the server, and this client is told which, by net id",
		"%s, net id %d" % [str(first), net_id])
	var mirror := _client_bridge.mirror_of(net_id)
	_check(mirror != null and mirror.global_position.distance_to((crate.node as Node3D).global_position) < 0.1,
		"which is this client's own copy of it")
	var read: Dictionary = first.get("settings", {})
	_check(bool(read.get("frozen", false)) and str(read.get("colour", "")) == "e05252",
		"with what it is: frozen, painted", str(read))

	var bigger := read.duplicate()
	bigger["size"] = 2.0
	_client_bridge.ask_tool_mode(&"edit", bigger)
	_exchange()
	await _steps(4)
	_check(is_equal_approx(float((crate.node as Node3D).get("size_scale")), 2.0),
		"a slider moved in the menu resizes the server's crate", "%.2f" % float((crate.node as Node3D).get("size_scale")))
	var last: Dictionary = got[got.size() - 1] if not got.is_empty() else {}
	_check(got.size() >= 2 and is_equal_approx(float((last.get("settings", {}) as Dictionary).get("size", 0.0)), 2.0),
		"and the answer says what it now is", str(last))
	for i in 128:
		await _steps(1)
		if mirror != null and absf(float(mirror.get("size_scale")) - 2.0) < 0.02:
			break
	_check(mirror != null and absf(float(mirror.get("size_scale")) - 2.0) < 0.02,
		"and the mirror is rebuilt at that size")

	_client_bridge.selection_received.disconnect(on_selection)
	_client_bridge.ask_tool(&"phys")
	var _gone := _server_game.props.remove(crate.instance_id)
	_exchange()
	await _steps(4)
	_done()


## A map document's props over the wire: the server puts them down, a client draws the
## server's and spawns none of its own, and changing back takes them away on both ends.
##
## [b]"None of its own" is held by dot-props, not by Playground's own guard.[/b] Armed by
## dropping `authoritative` from `spawn_map_props`'s call, every check still passed: a
## non-authoritative spawner refuses every spawn. The guard stays because without it each
## client would log that the map names props this server lacks, once per map, falsely.
func _test_map_props_over_the_wire() -> void:
	_section("a map's own props over the wire")

	var before: StringName = _server_game.maps.current.id
	var _changed: DotResult = await _server_game.change_map(&"pgc_town")
	for i in 240:
		_exchange()
		await _steps(1)
		if _client_game.maps.current != null and _client_game.maps.current.id == &"pgc_town":
			break
	await _exchange_steps(32)

	var server_count := _server_game.props.props_of(_server_game.MAP_OWNER).size()
	var doors := 0
	var mirrors := 0
	for behaviour: Variant in _client_bridge._prop_nets.values():
		var node: Variant = behaviour.get("prop")
		if node is Node and is_instance_valid(node) and node.get("def") is DotPropDef:
			mirrors += 1
			if (node.get("def") as DotPropDef).id == &"door":
				doors += 1
	_check(_client_game.maps.current != null and _client_game.maps.current.id == &"pgc_town", "the client follows the server to pgc_town")
	_check(server_count == 44 and mirrors >= server_count, "and draws every prop the map put down on the server",
		"%d on the server, %d mirrored" % [server_count, mirrors])
	_check(doors == 5, "its five doors among them", "%d doors" % doors)
	_check(_client_game.props.props_of(_client_game.MAP_OWNER).is_empty(), "and spawned none of its own")

	var _back: DotResult = await _server_game.change_map(before)
	for i in 240:
		_exchange()
		await _steps(1)
		if _client_game.maps.current != null and _client_game.maps.current.id == before:
			break
	await _exchange_steps(16)
	_done()


## Who holds what on the physics gun, told to every client (`Kind.HELD`), so a connected
## client can draw the beams. Before 2026-10-07 the encoder and decoder existed and nothing
## sent or read them: a connected player saw nobody's beam, their own included.
func _test_held_over_the_wire() -> void:
	_section("who holds what on the physics gun reaches the client")

	var theirs := _server_player()
	var crate := _server_game.props.spawn(&"crate", theirs.player_id, theirs.eye_position() + theirs.aim_direction() * 2.5)
	if crate == null:
		_check(false, "a crate in front of the player")
		_done()
		return
	await _exchange_steps(4)
	# Through the real path: the client holds fire with the physics gun out, and the server's
	# `_drive_tools` grabs on the press and lets go when the button is up.
	_client_bridge.ask_tool(&"phys")
	await _exchange_steps(4)
	var fire := DotFpsCommand.new()
	fire.set_button(DotFpsCommand.BUTTON_USER_0, true)
	for i in 12:
		_exchange()
		await _steps(1, fire)
	var grabbed := crate.held_by == theirs.player_id

	var session := SESSION
	var server_net: PlaygroundPropNet = _server_bridge._prop_nets.get(crate.instance_id)
	var net_id: int = server_net.identity.net_id if server_net != null and server_net.identity != null else -1
	_check(grabbed and int(_client_bridge.held_props.get(session, 0)) == net_id,
		"the client is told this player holds the crate, by its net id",
		"%s, %s against %d" % [str(grabbed), str(_client_bridge.held_props), net_id])
	var holders: Array = _client_bridge.holders()
	_check(holders.size() == 1 and holders[0]["prop"] == _client_bridge.mirror_of(net_id)
		and holders[0]["player"] == _client_game.players.get(theirs.player_id),
		"and resolves it to its own copies of the player and the crate, for a beam", str(holders))

	await _exchange_steps(8)
	_check(crate.held_by == &"" and not _client_bridge.held_props.has(session) and _client_bridge.holders().is_empty(), "letting go of fire lets go, and that is told too")

	var _gone := _server_game.props.remove(crate.instance_id)
	await _exchange_steps(4)
	_check(_client_bridge.mirror_of(net_id) == null, "and the crate goes", str(_client_bridge.mirror_of(net_id)))
	_done()


## A pane of glass broken on the server is gone from every client's own copy of the map,
## which each built from the document: the shards are props and travel as props, the hole
## travels as `Kind.PANE`.
func _test_glass_over_the_wire() -> void:
	_section("glass broken on the server is gone on the client")

	var before: StringName = _server_game.maps.current.id
	var _changed: DotResult = await _server_game.change_map(&"pgc_nature")
	for i in 240:
		_exchange()
		await _steps(1)
		if _client_game.maps.current != null and _client_game.maps.current.id == &"pgc_nature":
			break
	await _exchange_steps(16)

	var index: int = _server_game.panes.keys()[0] if not _server_game.panes.is_empty() else -1
	_check(index >= 0 and _client_game.panes.has(index), "both ends know the map's panes", "%d" % index)
	var client_node: Variant = (_client_game.panes[index] as Dictionary)["node"] if _client_game.panes.has(index) else null
	var heard: Array = []
	var on_broken := func(i: int, _at: Vector3, _m: StringName) -> void: heard.append(i)
	_client_game.pane_broken.connect(on_broken)

	var server_node: Node = (_server_game.panes[index] as Dictionary)["node"] if index >= 0 else null
	var hits: Array = []
	var on_hit := func(victim: int, amount: float, _point: Vector3, killed: bool, _head: bool) -> void:
		hits.append([victim, amount, killed])
	_client_bridge.hit_received.connect(on_hit)
	# The world's damage (nobody behind it) first: it confirms nothing to anybody.
	var _scratched := _server_game.hurt_pane(server_node, 0.5, &"")
	var health := float((_server_game.panes[index] as Dictionary)["health"]) if index >= 0 else 0.0
	var _broke := _server_game.hurt_pane(server_node, 1000.0, &"u%d" % SESSION)
	await _exchange_steps(8)
	_client_bridge.hit_received.disconnect(on_hit)
	_check(hits.size() == 1 and DotEntity.kind_of(int(hits[0][0])) == DotEntity.KIND_OTHER
		and absf(float(hits[0][1]) - health) < 0.2 and bool(hits[0][2]),
		"the player who broke it is told their hit landed: what it had left, and that it broke",
		"%s for %.1f left" % [str(hits), health])
	_check(not _server_game.panes.has(index) and not _client_game.panes.has(index) and _client_game.broken_panes.has(index),
		"a pane the server breaks is broken on the client too")
	var gone := not is_instance_valid(client_node) or not (client_node as Node).is_inside_tree() \
		or (client_node as Node).is_queued_for_deletion()
	_check(gone, "and gone from the client's world",
		"valid %s" % is_instance_valid(client_node))
	_check(heard == [index], "with the signal its sound plays from", str(heard))

	_client_game.pane_broken.disconnect(on_broken)
	var _back: DotResult = await _server_game.change_map(before)
	for i in 240:
		_exchange()
		await _steps(1)
		if _client_game.maps.current != null and _client_game.maps.current.id == before:
			break
	await _exchange_steps(16)
	_done()


func _toy_of(game: Playground, id: String) -> DotPropToy:
	if game.toys == null:
		return null
	for t in game.toys.toys:
		if String(t.def["id"]) == id:
			return t
	return null


## dot-props' toys on the lobby, over the wire: an entity per toy on both ends paired by index
## (TOYS), the client's frozen and posed from the server's state, a kicked ball followed, a
## switch's lamps lit on the client, a roundabout's spin measured there so a rider is carried,
## and a map change and back re-pairing them all.
func _test_map_toys_over_the_wire() -> void:
	_section("the map's toys over the wire")

	var on_lobby := _server_game.maps.current != null and _server_game.maps.current.id == &"pg_flatgrass"
	if not on_lobby:
		var _changed: DotResult = await _server_game.change_map(&"pg_flatgrass")
	for i in 240:
		_exchange()
		await _steps(1)
		if _client_game.maps.current != null and _client_game.maps.current.id == &"pg_flatgrass" and _client_bridge.toy_count() > 0:
			break
	await _exchange_steps(8)

	var count := _server_game.toys.count() if _server_game.toys != null else 0
	_check(count >= 25 and _server_bridge.toy_count() == count and _client_bridge.toy_count() == count,
		"every toy is an entity on both ends, paired by index", "%d toys, %d and %d replicated" % [count, _server_bridge.toy_count(), _client_bridge.toy_count()])

	var server_ball := _toy_of(_server_game, "beach_ball")
	var client_ball := _toy_of(_client_game, "beach_ball")
	_check(client_ball != null and client_ball.body.freeze and not client_ball.authoritative and server_ball.authoritative,
		"the client's toys are frozen copies; the server's simulate")

	# Kicked on the server: the client's copy follows it there.
	var _kicked := _server_game.toys.use(server_ball.index, server_ball.body.global_position + Vector3(0, 1.4, 1.2), Vector3(0, -0.3, -1))
	var furthest := 0.0
	for i in 30:
		await _exchange_steps(1)
		furthest = maxf(furthest, client_ball.body.global_position.distance_to(client_ball.rest.origin))
	await _exchange_steps(30)
	var apart := client_ball.body.global_position.distance_to(server_ball.body.global_position)
	_check(furthest > 1.0 and apart < 0.6, "a ball kicked on the server rolls off on the client, and comes to rest where the server's did",
		"%.2f m out, %.2f m apart at rest" % [furthest, apart])

	# The switch on the server lights its lamps on the client.
	var server_switch := _toy_of(_server_game, "light_switch")
	var client_lamp := _client_game.toys.toy(int(server_switch.links[0]))
	var was := client_lamp.on
	var _pressed := _server_game.toys.use(server_switch.index, server_switch.global_position + Vector3(0, 1.4, 1), Vector3(0, -0.3, -1))
	await _exchange_steps(12)
	_check(client_lamp.on != was and client_lamp.on == _server_game.toys.toy(client_lamp.index).on, "the switch pressed on the server lights the lamp on the client")

	# A roundabout spun on the server turns on the client, which measures the spin from the poses
	# it is shown: what carries the client's own player standing on it, predicted.
	var server_spinner := _toy_of(_server_game, "merry_go_round")
	var client_spinner := _toy_of(_client_game, "merry_go_round")
	var hub := server_spinner.body.global_position
	var _spun := _server_game.toys.use(server_spinner.index, hub + Vector3(1.6, 1.0, 0), Vector3(0, 0, 1))
	await _exchange_steps(16)
	var ride := _client_game.toys.carry_for(hub + Vector3(1.0, 0.05, 0), 1.0 / 60.0)
	var server_ride := _server_game.toys.carry_for(hub + Vector3(1.0, 0.05, 0), 1.0 / 60.0)
	_check(not ride.is_empty() and not server_ride.is_empty() and signf(float(ride["yaw"])) == signf(float(server_ride["yaw"]))
		and absf(float(ride["yaw"]) - float(server_ride["yaw"])) < absf(float(server_ride["yaw"])) * 0.5,
		"a roundabout spun on the server turns on the client, and carries a rider there at nearly its rate",
		"client %s, server %s" % [str(ride.get("yaw")), str(server_ride.get("yaw"))])

	# A map change and back: the old entities go on both ends, the new ones are paired again.
	var _away: DotResult = await _server_game.change_map(&"pgc_plots")
	for i in 240:
		_exchange()
		await _steps(1)
		if _client_game.maps.current != null and _client_game.maps.current.id == &"pgc_plots" and _client_bridge.toy_count() == _server_game.toys.count():
			break
	var plots := _server_game.toys.count()
	_check(plots > 0 and _client_bridge.toy_count() == plots and _client_game.toys.count() == plots,
		"a map change replaces them on both ends", "%d on the server, %d paired on the client" % [plots, _client_bridge.toy_count()])
	var _back: DotResult = await _server_game.change_map(&"pg_flatgrass")
	for i in 240:
		_exchange()
		await _steps(1)
		if _client_game.maps.current != null and _client_game.maps.current.id == &"pg_flatgrass" and _client_bridge.toy_count() == _server_game.toys.count():
			break
	await _exchange_steps(8)
	_done()


## A connected client predicts its own player swimming (pgc_harbour's basin): the swim mode
## is entered from `PlaygroundPlayer._on_simulated`, which a prediction replay runs too, and
## its water is a list of boxes both ends built from the one map document. Measured: what a
## swim costs in corrections, and where the two ends end up.
##
## [b]What this cannot see:[/b] armed by entering the mode on the server only, it still
## passes. The mode travels in the snapshot, and on this suite's short link the server's
## snapshot puts the client in the water before its prediction has drifted past a correction.
## The client's own entry is what keeps a real round trip from showing the player walking on
## the bed for 100 ms; this asserts the swim agrees, not that.
func _test_swimming_over_the_wire() -> void:
	_section("swimming, predicted by a connected client")

	var before: StringName = _server_game.maps.current.id
	var _changed: DotResult = await _server_game.change_map(&"pgc_harbour")
	for i in 240:
		_exchange()
		await _steps(1)
		if _client_game.maps.current != null and _client_game.maps.current.id == &"pgc_harbour":
			break
	await _exchange_steps(16)

	var mine := _client_player()
	var theirs := _server_player()
	_check(mine.swim.volumes.size() == 1 and theirs.swim.volumes.size() == 1, "both ends have the basin's water")
	theirs.teleport(Vector3(-70.0, -1.0, -60.0), 0.0)
	await _steps(320)
	_check(theirs.controller.state.mode == theirs.swim.mode_id and mine.controller.state.mode == mine.swim.mode_id,
		"the server's player and the client's prediction of it are both swimming",
		"server %d, client %d" % [theirs.controller.state.mode, mine.controller.state.mode])

	# Getting IN is the moment the client's own entry matters: the mode is in the snapshot, so
	# a client that never entered by itself is corrected into the water a round trip late.
	# Walked in, as a player would: down the west slipway from the quay, into the basin.
	theirs.teleport(Vector3(-80.0, 0.3, 14.0), 0.0)
	await _steps(160)
	var c := _forward()
	c.yaw = 0.0
	var corrections_before := _corrections_and_snaps()
	var entered_at := -1
	for i in 320:
		await _step(c)
		if entered_at < 0 and theirs.controller.state.mode == theirs.swim.mode_id:
			entered_at = i
	var corrections := _corrections_and_snaps() - corrections_before
	await _steps(32)
	var gap := mine.controller.state.position.distance_to(theirs.controller.state.position)
	print("    walked down the slipway into the water (in at tick %d) and swam: %d corrections, ends %.3f m apart" % [entered_at, corrections, gap])
	_check(entered_at > 0 and corrections == 0, "walking in and swimming costs the prediction nothing", "%d corrections" % corrections)
	_check(gap < 0.1, "and the client ends where the server does", "%.3f m" % gap)

	var _back: DotResult = await _server_game.change_map(before)
	for i in 240:
		_exchange()
		await _steps(1)
		if _client_game.maps.current != null and _client_game.maps.current.id == before:
			break
	await _exchange_steps(16)
	_done()


func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	_client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_server_bridge.server_tick(_tick)
	_flush()
	# A real client stamps its command far enough ahead to cover the trip; the lead grows
	# with the transit delay for the same reason.
	_client_bridge.client_tick(
		_tick + INPUT_LEAD + _delay_ticks, command if command != null else DotFpsCommand.new()
	)
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		await _step(command)


func _forward() -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(0.0, 1.0)
	return c


func _server_player() -> PlaygroundPlayer:
	return _server_game.players.get(&"u%d" % SESSION)


func _test_avatars_over_the_wire() -> void:
	_section("what a member wears reaches every client")

	# The translation: a site avatar's face, top and legs, each its own skin.
	var site := DotAvatar.new()
	site.schema_id = &"builtin"
	site.set_part(&"face", &"face.skin-b")
	site.set_part(&"top", &"top.skin-k")
	site.set_part(&"legs", &"legs.skin-r")
	var translated := PlaygroundAvatars.from_site(site)
	_check(
		PlaygroundAvatars.skins_of(translated) == PackedInt32Array([1, 10, 17]),
		"a site avatar is three skins, face, top and legs", str(PlaygroundAvatars.skins_of(translated))
	)
	var other := DotAvatar.new()
	other.schema_id = &"some_game"
	_check(PlaygroundAvatars.from_site(other) == null, "and somebody else's document is not guessed at")

	# The wire: skins after the style byte, and a JOIN without them still reads.
	var with_skins := PlaygroundEvents.write_join(7, 9, "Ada", 1, PackedInt32Array([1, 10, 17]))
	var read := PlaygroundEvents.read_join(DotNetReader.new(with_skins))
	_check(bool(read["ok"]) and read["skins"] == PackedInt32Array([1, 10, 17]), "JOIN carries them", str(read["skins"]))
	var old := with_skins.slice(0, with_skins.size() - 3)
	var read_old := PlaygroundEvents.read_join(DotNetReader.new(old))
	_check(bool(read_old["ok"]) and (read_old["skins"] as PackedInt32Array).is_empty() and int(read_old["style_index"]) == 1,
		"and a JOIN from before them reads with none", str(read_old))

	# The server dresses its player and tells everybody; the client's body changes with it.
	# A face that cannot be the stock one this player's id picks, or the figure check below
	# passes on the stock look -- which it did, the first time this was armed.
	var face := (PlaygroundAvatars.stock_index("u%d" % SESSION) + 7) % PlaygroundAvatars.LETTERS.length()
	var dressed := PackedInt32Array([face, 10, 17])
	_server_bridge.skin_fn = func(_session: int) -> PackedInt32Array: return dressed
	_server_bridge.refresh_skins(SESSION)
	await _exchange_steps(8)
	var mine := _client_player()
	_check(mine != null and mine.skins == dressed, "the client has them",
		str(mine.skins) if mine != null else "no player")
	var figure: Node = mine.character.rig.find_child("Figure", true, false) if mine != null and mine.character != null else null
	# The figure is one of the family's people: the face's skin is its skin colour.
	var person := figure as DotHumanoidFigure
	var wanted_skin := Color(DotHumanoidLook.SITE_SKINS[PlaygroundAvatars.LETTERS[face]][0])
	_check(person != null and person.look != null and person.look.skin.is_equal_approx(wanted_skin),
		"and draws the member's face on the figure", str(person.look.to_dict()) if person != null and person.look != null else "no person")
	_server_bridge.skin_fn = Callable()
	_done()


func _client_player() -> PlaygroundPlayer:
	return _client_game.players.get(&"u%d" % SESSION)


# --- The tests -------------------------------------------------------------

func _test_handshake() -> void:
	_section("a client joins")

	# The READY first, as over ENet with loss: a client is PLAYING by its own reckoning once it has
	# sent `loaded`, on another channel, so its READY can reach the server before its seat. Kept,
	# and answered by the seat; a bridge that drops it never tells this client who it is.
	_client_bridge.ask_ready()
	_exchange()
	_check(_client_bridge.local_player_id != SESSION, "a READY before the seat is told nothing yet")

	var added := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(added.ok, "the server adds the player", str(added.error) if not added.ok else "")
	_check(_server_player() != null, "and the game has them")

	var behaviour_count: Variant = _server_bridge.describe()["players"]
	_check(int(behaviour_count) == 1, "with an entity replicating them", str(behaviour_count))

	_exchange()
	await _steps(4)

	_check(_client_bridge.local_player_id == SESSION, "the client is told who it is",
		str(_client_bridge.local_player_id))
	_check(_client_player() != null, "and builds the player")

	# The whole point of the disagreement set up in _build.
	_check(
		_client_game.tick_rate == _server_game.tick_rate,
		"the client adopted the server's tick rate through HELLO",
		"client %d, server %d" % [_client_game.tick_rate, _server_game.tick_rate]
	)
	_check(
		Engine.physics_ticks_per_second == _server_game.tick_rate,
		"and so did the engine, which is what decides whether it looks smooth",
		"engine %d" % Engine.physics_ticks_per_second
	)
	_check(
		_client_net.clock.tick_rate == _server_game.tick_rate,
		"and the netcode clock, which is built from the config and not updated by it"
	)

	_check(
		_client_game.maps.current != null
			and _client_game.maps.current.id == _server_game.maps.current.id,
		"both ends are on the same map"
	)

	# [b]The style table has to be built from a DECLARED order, not a sort of the ids.[/b]
	# Godot compares StringNames by their interned pointer, so `Array.sort()` on them
	# gives two peers two different tables — and this suite CANNOT see that, because one
	# process has one intern table and both ends agree no matter how the table was built.
	# It took a browser client joining and putting itself on "Sideways" to show it. So
	# assert the SOURCE instead: the table must match the declared ordering
	# (`Playground.style_order`, dot-player-controller's list), the same on every machine.
	var declared := PackedStringArray()
	for style_id in _server_game.style_order:
		declared.append(String(style_id))

	var built := PackedStringArray()
	for style_id in _server_bridge.style_table():
		built.append(String(style_id))

	_check(built == declared,
		"the style table follows the declared ordering, not a StringName sort",
		"%s vs %s" % [str(built), str(declared)])

	var mine := _client_player()
	_check(
		mine != null and declared.size() > 0
			and String(mine.movement_style.id) == declared[0],
		"so a joining player lands on the style the server named",
		String(mine.movement_style.id) if mine != null and mine.movement_style != null else "-"
	)

	_check(_client_net.stats.rtt_percentile(0.5) > 0.0,
		"the client fed the clock an RTT sample, which nothing in dot-net does for it")
	_done()


func _test_prediction() -> void:
	_section("moving")

	var before := _client_player().controller.state.position
	await _steps(48, _forward())
	var after := _client_player().controller.state.position

	_check(after.distance_to(before) > 1.0, "the client moves under its own prediction",
		"%.2f m" % after.distance_to(before))

	var server_at := _server_player().controller.state.position
	_check(server_at.distance_to(after) < 1.0,
		"and the server agrees with it", "%.3f m apart" % server_at.distance_to(after))

	# The measure that caught a bridge reconciling on top of dot-net's own
	# reconciliation, and a _net_state_applied that moved the node before reconcile
	# measured the error. Both read as a predictor that snapped every packet.
	var rate: float = _client_net.predictor.correction_rate()
	_check(rate < 0.35, "the correction rate is low", "%.3f" % rate)
	_done()


## [b]The section above passes for a client that predicts nobody[/b], and did until
## 2026-09-25: `_apply_join` mirrored every player — this client's own included — with owner
## 0, so `registry.predicted()` was empty, `client_tick` simulated nobody, and the local
## player moved only when a snapshot came back. "It moves" and "the server agrees" both hold
## for a client that simply adopts every snapshot, and the correction rate is lowest of all
## for a predictor that never runs. So this asks the four things only prediction answers:
## who owns the mirror, who is in `predicted()`, whether a key moves the player on the tick
## it is pressed with nothing from the server in between, and whether a move only the server
## made still wins.
func _corrections_and_snaps() -> int:
	var d := _client_net.predictor.describe()
	return int(d.get("corrections", 0)) + int(d.get("snaps", 0))


## A flush pair with ticks after it, which is what most of these want.
func _exchange_steps(count: int) -> void:
	_exchange()
	await _steps(count)
