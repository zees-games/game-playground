extends "res://examples/headless_net_part4.gd"

## Another player has a body on this client, it stands where the server has them, and it
## moves every frame rather than every snapshot.
##
## [b]On a networked client nobody else had a body until 2026-09-24, for two reasons at
## once[/b], and every section above passed throughout because each reads the simulation
## and none reads the screen: the body was hidden (the "first person hides your own body"
## rule was applied to every player, and a remote one's view mode reads "fp"), and it was
## at the world origin (the rig hung off a plain `Node`, which a `Node3D` does not inherit a
## transform through). The lobby's spawn IS the origin, which is why a body standing on the
## spawn pad looked right — so this runs them well away from it before asking.
##
## Driven through `PlaygroundClient.present_frame`, the function the real client's
## `_process` calls, so a client that stops interpolating or stops placing bodies fails
## here rather than in a screenshot.
var _seid_session: int
var _seid_server_bea: PlaygroundPlayer
var _seid_theirs: PlaygroundPlayer
var _seid_bea_net: PlaygroundPlayerNet
var _seid_server_track: Array[Vector3]
var _seid_drawn: Array[Vector3]

func _test_somebody_else_is_drawn() -> void:
	_section("somebody else has a body, where the server has them, moving every frame")

	_seid_session = SESSION + 2
	var added := _server_bridge.add_player(CLIENT_PEER + 2, _seid_session, "Bea")
	_check(added.ok, "a second player joins on a peer of their own")
	await _steps(6)

	_seid_server_bea = _server_game.players.get(&"u%d" % _seid_session)
	_seid_theirs = _client_game.players.get(&"u%d" % _seid_session)
	var mine := _client_player()

	if _seid_server_bea == null or _seid_theirs == null or mine == null:
		_check(false, "both ends have them, and this client has its own player")
		return

	# What the real client has done by now and this suite's hand-driven halves have not: its
	# manager is RUNNING, which `present_frame` asks before it interpolates, and it has told
	# its own player that it is the local one, which is when a first-person body is hidden
	# (`PlaygroundClient._build_view_switch`, in the same two lines).
	if not _client_net.is_running():
		var _started := _client_net.start()
	mine.samples_input = true
	var _switch := mine.build_view_switch()

	var shown := PlaygroundClient.present_frame(_client_net, _client_game, 0.0, mine)

	# Your own player is drawn at the clock's render alpha (dot-player-controller's
	# `render_clock`), so a clock slip does not stall or double the eye.
	_check(
		mine.controller != null and mine.controller.get(&"render_clock") == _client_net.clock,
		"your own player is drawn on the client clock's render alpha"
	)

	_check(
		_seid_theirs.character != null and _seid_theirs.character.is_body_visible()
		and _seid_theirs.character.rig.is_visible_in_tree(),
		"the client draws a body for them",
		"character %s, shown %s" % [
			str(_seid_theirs.character != null),
			str(_seid_theirs.character.is_body_visible()) if _seid_theirs.character != null else "-",
		]
	)
	_check(
		mine.character == null or not mine.character.is_body_visible(),
		"and none round its own camera, which is in first person"
	)
	_check(shown == 1, "so exactly one body is drawn on this client", "%d" % shown)
	_check(
		_seid_theirs.character != null and _seid_theirs.character.is_on_body(),
		"the body hangs off the player's own node, which is what places it"
	)

	# Running, with the client drawing FRAMES_PER_TICK frames between ticks. Driven the way a
	# peer drives them: the command their input would have carried, applied by the server.
	_seid_bea_net = _seid_server_bea.get_node("Net") as PlaygroundPlayerNet
	var run := DotFpsCommand.new()
	run.move = Vector2(0.0, 1.0)
	run.yaw = 90.0
	_seid_bea_net.last_move = run

	_seid_server_track = []
	_seid_drawn = []
	await _test_somebody_else_is_drawn_2()
	await _test_somebody_else_is_drawn_3()

func _test_somebody_else_is_drawn_2() -> void:

	for i in range(160):
		await _step()
		_seid_server_track.append(_seid_server_bea.controller.state.position)

		for f in range(FRAMES_PER_TICK):
			var _n := PlaygroundClient.present_frame(
				_client_net, _client_game, float(f) / float(FRAMES_PER_TICK)
			)
			if _seid_theirs.character != null and i >= 60:
				_seid_drawn.append(_seid_theirs.character.rig.global_position)

	_seid_bea_net.last_move = DotFpsCommand.new()

	var from := _seid_server_track[0]
	var to := _seid_server_track[_seid_server_track.size() - 1]
	_check(
		Vector2(to.x, to.z).distance_to(Vector2(from.x, from.z)) > 3.0,
		"the server runs them off the spawn pad",
		"%.2f m" % Vector2(to.x, to.z).distance_to(Vector2(from.x, from.z))
	)

	# Tracking: every frame's body is within a hand of SOME position the server really had
	# them at. Not the latest one, because a remote player is drawn an interpolation delay in
	# the past on purpose; the nearest point on the server's own track is the fair test.
	var worst := 0.0
	for at in _seid_drawn:
		var nearest := INF
		for p in _seid_server_track:
			nearest = minf(nearest, at.distance_to(p))
		worst = maxf(worst, nearest)

	_check(
		not _seid_drawn.is_empty() and worst < 0.25,
		"and every frame draws the body on the path the server ran them along",
		"worst %.3f m off it, over %d frames" % [worst, _seid_drawn.size()]
	)

	var last: Vector3 = _seid_drawn[_seid_drawn.size() - 1] if not _seid_drawn.is_empty() else Vector3.ZERO
	_check(
		Vector2(last.x, last.z).length() > 3.0,
		"so the body followed them away from the world origin, where it used to stay",
		"last drawn %s" % str(last)
	)

	# Smoothness: at a steady running speed each frame should advance the body by about the
	# same distance. A client that draws only when a snapshot lands moves it on one frame in
	# several and not at all on the rest — the judder the family measured as a 47% change in
	# apparent speed.
	var mean := 0.0
	var largest := 0.0
	var smallest := INF
	for j in range(1, _seid_drawn.size()):
		var d := _seid_drawn[j].distance_to(_seid_drawn[j - 1])
		mean += d
		largest = maxf(largest, d)
		smallest = minf(smallest, d)
	mean /= float(maxi(_seid_drawn.size() - 1, 1))

	_check(
		mean > 0.001 and largest < mean * 1.5 and smallest > mean * 0.5,
		"and it moves by an even step on every frame, not in snapshot-sized jumps",
		"per frame %.4f m mean, %.4f..%.4f" % [mean, smallest, largest]
	)

func _test_somebody_else_is_drawn_3() -> void:
	_check(
		_seid_theirs.character != null
		and absf(wrapf(_seid_theirs.character.rig.rotation.y - deg_to_rad(90.0), -PI, PI)) < 0.05,
		"and it faces the way the server says they are looking",
		"%.1f deg" % (rad_to_deg(_seid_theirs.character.rig.rotation.y) if _seid_theirs.character != null else 0.0)
	)

	_server_bridge.remove_player(_seid_session)
	await _steps(4)
	_check(
		not _client_game.players.has(&"u%d" % _seid_session),
		"and they leave again, so the sections after this one see one player"
	)
	_done()


# --- The inventory ------------------------------------------------------------

## The inventory's wire on its own: every encoder against its decoder, and the one field a
## client must not be able to write.
func _test_inventory_wire() -> void:
	_section("the inventory's wire round-trips, and carries no state a client wrote")

	var sent := DotInvOp.move(BACKPACK, 12, BACKPACK, Vector2i(3, 4), true).to_dictionary()
	sent["state"] = {"serial": "forged"}
	var r := DotNetReader.new(PlaygroundEvents.write_inv_op(41, sent))
	var sub := PlaygroundEvents.read_inv_ask(r)
	var got := PlaygroundEvents.read_inv_op(r)
	var back := DotInvOp.from_dictionary(got["op"])
	_check(
		sub == PlaygroundEvents.InvAsk.OP and bool(got["ok"]) and int(got["seq"]) == 41,
		"an op arrives with its sequence number"
	)
	_check(
		back.kind == DotInvOp.Kind.MOVE and back.from_uid == 12 and back.to_cell == Vector2i(3, 4)
			and back.to_rotated and back.from_container == BACKPACK and back.to_container == BACKPACK,
		"and every field of it",
		back.describe_line()
	)
	_check(back.state.is_empty(), "but not a state the client wrote into it", str(back.state))

	var add := DotNetReader.new(PlaygroundEvents.write_inv_op(2, DotInvOp.add(&"crate", 1, BACKPACK).to_dictionary()))
	PlaygroundEvents.read_inv_ask(add)
	var add_got := PlaygroundEvents.read_inv_op(add)
	var add_back := DotInvOp.from_dictionary(add_got["op"])
	_check(
		add_back.kind == DotInvOp.Kind.ADD and add_back.to_cell == Vector2i(-1, -1) and add_back.item == &"crate",
		"an ADD's 'anywhere' cell survives, so a refusal matches what was predicted"
	)

	var ack_r := DotNetReader.new(PlaygroundEvents.write_inv_ack(9, false, "no room"))
	var ack_sub := PlaygroundEvents.read_inv_tell(ack_r)
	var ack := PlaygroundEvents.read_inv_ack(ack_r)
	_check(
		ack_sub == PlaygroundEvents.InvTell.ACK and bool(ack["ok"]) and int(ack["seq"]) == 9
			and not bool(ack["accepted"]) and str(ack["reason"]) == "no room",
		"an answer round-trips: which op, yes or no, and why"
	)

	var doc := {
		"containers": {String(BACKPACK): {
			"id": String(BACKPACK), "shape": "grid", "next_uid": 4,
			"entries": {"3": {"item": "crate", "count": 1, "cell": [2, 1], "rotated": false, "state": {}}},
		}},
		"parents": {}, "max_depth": 3, "next_child": 1,
	}
	var doc_r := DotNetReader.new(PlaygroundEvents.write_inv_doc(17, doc))
	var doc_sub := PlaygroundEvents.read_inv_tell(doc_r)
	var doc_got := PlaygroundEvents.read_inv_doc(doc_r)
	var entry: Dictionary = {}
	if bool(doc_got.get("ok", false)):
		entry = ((doc_got["doc"]["containers"][String(BACKPACK)]["entries"] as Dictionary).get("3", {}))
	_check(
		doc_sub == PlaygroundEvents.InvTell.DOC and bool(doc_got.get("ok", false))
			and int(doc_got["through"]) == 17 and str(entry.get("item", "")) == "crate",
		"a whole bag round-trips as the JSON dot-inventory writes, with what it already includes"
	)

	var huge_entries := {}
	for i in range(400):
		huge_entries[str(i)] = {"item": "a_long_item_name_%d" % i, "count": 1, "cell": [i, 0], "rotated": false, "state": {}}
	var huge := {"containers": {"x": {"entries": huge_entries}}}
	_check(
		PlaygroundEvents.write_inv_doc(1, huge).is_empty(),
		"a bag too big to send is refused rather than truncated into JSON nobody can read"
	)

	var rs := DotNetReader.new(PlaygroundEvents.write_inv_resync(5))
	var rs_sub := PlaygroundEvents.read_inv_ask(rs)
	var buy := DotNetReader.new(PlaygroundEvents.write_inv_buy(&"barrel"))
	var buy_sub := PlaygroundEvents.read_inv_ask(buy)
	_check(
		rs_sub == PlaygroundEvents.InvAsk.RESYNC and int(PlaygroundEvents.read_inv_resync(rs)["seq"]) == 5
			and buy_sub == PlaygroundEvents.InvAsk.BUY
			and StringName(PlaygroundEvents.read_inv_buy(buy)["item"]) == &"barrel",
		"a request for the whole bag and a purchase round-trip"
	)
	_done()


func _server_bag(session: int = SESSION) -> DotInvManager:
	return _server_game.inventory.for_player(_server_bridge.inventory_net.bag_key(session))


func _client_bag() -> DotInvManager:
	return _client_bridge.inventory_manager()


## A bag as the things two ends have to agree about: every entry's uid, item, cell and
## rotation, and the next uid either end will hand out.
##
## [b]The uids are the point.[/b] The next op names an entry by uid, so two bags laid out
## identically under different uids are two bags in which "move #4" means different
## things — which is a duplication or a loss one op later, and invisible in any picture.
static func _bag_summary(m: DotInvManager) -> String:
	if m == null or m.doc == null:
		return "-"
	var c := m.doc.get_container(BACKPACK)
	if c == null:
		return "-"
	var parts := PackedStringArray()
	for uid: Variant in c.entries.keys():
		var e: Dictionary = c.entries[uid]
		var at: Variant = e.get("cell", Vector2i.ZERO)
		var cell: Vector2i = at if at is Vector2i else Vector2i(-9, -9)
		parts.append("%s#%d@%d,%d%s" % [
			str(e.get("item", "")), int(uid), cell.x, cell.y,
			"r" if bool(e.get("rotated", false)) else "",
		])
	parts.sort()
	return "%s next=%d" % [",".join(parts), int(c.to_dictionary().get("next_uid", 0))]


static func _uid_at(m: DotInvManager, cell: Vector2i) -> int:
	if m == null or m.doc == null:
		return 0
	var c := m.doc.get_container(BACKPACK)
	for uid: Variant in c.entries.keys():
		var at: Variant = (c.entries[uid] as Dictionary).get("cell", null)
		if at is Vector2i and (at as Vector2i) == cell:
			return int(uid)
	return 0


static func _cell_of(m: DotInvManager, item: StringName) -> Vector2i:
	if m == null or m.doc == null:
		return Vector2i(-9, -9)
	var c := m.doc.get_container(BACKPACK)
	for uid: Variant in c.entries.keys():
		var e: Dictionary = c.entries[uid]
		if str(e.get("item", "")) == String(item):
			var at: Variant = e.get("cell", null)
			return at if at is Vector2i else Vector2i(-9, -9)
	return Vector2i(-9, -9)


## The first free cell in the backpack, row-major — what first-fit will choose next.
static func _first_free(m: DotInvManager) -> Vector2i:
	var c := m.doc.get_container(BACKPACK)
	var taken := c.occupied_cells(m.catalogue)
	for y in range(c.height):
		for x in range(c.width):
			if not taken.has(Vector2i(x, y)):
				return Vector2i(x, y)
	return Vector2i(-1, -1)


static func _free_cells(m: DotInvManager) -> int:
	var c := m.doc.get_container(BACKPACK)
	return c.width * c.height - c.occupied_cells(m.catalogue).size()


func _request_bytes(kind: int, body: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var writer := DotNetWriter.new()
	var _encoded := _client_net.messages.encode(PlaygroundRequest.new(kind, body), writer)
	return writer.to_bytes()


## Every INVENTORY event the server sent to [param peer_id] while recording, decoded.
func _inventory_events(peer_id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for sent in _server_events:
		if int(sent["peer"]) != peer_id:
			continue
		var decoded := _client_net.messages.decode(DotNetReader.new(sent["payload"]), 1, false)
		if not decoded.ok:
			continue
		var event := decoded.value as PlaygroundEvent
		if event == null or event.kind != PlaygroundEvents.Kind.INVENTORY:
			continue
		var r := event.reader()
		var entry := {"sub": PlaygroundEvents.read_inv_tell(r)}
		if int(entry["sub"]) == PlaygroundEvents.InvTell.DOC:
			entry.merge(PlaygroundEvents.read_inv_doc(r))
		out.append(entry)
	return out


## Every peer an INVENTORY event went to while recording, broadcast (0) included.
func _inventory_peers() -> Array[int]:
	var out: Array[int] = []
	for sent in _server_events:
		var peer := int(sent["peer"])
		if not out.has(peer) and not _inventory_events(peer).is_empty():
			out.append(peer)
	return out


static func _doc_count(doc: Dictionary, item: String) -> int:
	var n := 0
	var containers: Dictionary = doc.get("containers", {})
	for id: Variant in containers.keys():
		var entries: Dictionary = (containers[id] as Dictionary).get("entries", {})
		for uid: Variant in entries.keys():
			if str((entries[uid] as Dictionary).get("item", "")) == item:
				n += int((entries[uid] as Dictionary).get("count", 1))
	return n


## The client predicts, the server decides, and nothing is left waiting.
func _test_inventory_predicted() -> void:
	_section("an inventory op is predicted, sent through the bridge, and confirmed")

	var mine := _client_bag()
	_check(mine != null, "the client holds a bag, made when the server sent it on admission")
	if mine == null:
		return
	_check(
		_client_game.inventory.keys().size() == 1,
		"and exactly one: its own",
		str(_client_game.inventory.keys())
	)
	_check(not mine.authoritative, "which predicts rather than decides")

	var bag := _server_bridge.inventory_net.bag_key(SESSION)
	var gave_crate := _server_game.inventory.give(bag, &"crate")
	var gave_ball := _server_game.inventory.give(bag, &"beach_ball")
	_check(gave_crate.ok and gave_ball.ok, "the server puts a crate and a ball in this player's bag")
	await _steps(2)
	_check(
		mine.doc.count_of(&"crate") == 1 and mine.doc.count_of(&"beach_ball") == 1,
		"and both reach the client"
	)
	_check(
		_bag_summary(mine) == _bag_summary(_server_bag()),
		"laid out exactly as the server's, uids and all",
		"%s vs %s" % [_bag_summary(mine), _bag_summary(_server_bag())]
	)

	var ball := _uid_at(mine, _cell_of(mine, &"beach_ball"))
	var requests := _client_bridge.link.requests_sent
	var moved := mine.apply(DotInvOp.move(BACKPACK, ball, BACKPACK, Vector2i(6, 3)))
	_check(moved.ok, "the client moves the ball")
	_check(
		_cell_of(mine, &"beach_ball") == Vector2i(6, 3)
			and _cell_of(_server_bag(), &"beach_ball") != Vector2i(6, 3),
		"and sees it moved before the server has heard of it"
	)
	_check(
		mine.pending_count() == 1 and _client_bridge.inventory_net.in_flight_count() == 1,
		"kept as one op in flight, so it can be rolled back"
	)
	_check(
		_client_bridge.link.requests_sent == requests + 1,
		"and sent as one request, through the bridge — the manager's send_fn is the seam",
		"%d -> %d" % [requests, _client_bridge.link.requests_sent]
	)

	var confirmed := _client_bridge.inventory_net.confirmed_count
	_exchange()
	_check(
		_cell_of(_server_bag(), &"beach_ball") == Vector2i(6, 3),
		"the server applied it to the authoritative bag"
	)
	_check(
		mine.pending_count() == 0 and _client_bridge.inventory_net.in_flight_count() == 0
			and _client_bridge.inventory_net.confirmed_count == confirmed + 1,
		"and confirmed it: nothing is left waiting",
		str(_client_bridge.inventory_net.describe())
	)
	_check(
		_bag_summary(mine) == _bag_summary(_server_bag()),
		"the two bags agree, uids and all",
		"%s vs %s" % [_bag_summary(mine), _bag_summary(_server_bag())]
	)
	_done()


## Two refusals: one the client could have known about, sent with a good op behind it, and
## one it could not — the server had changed the bag and not yet said so.
var _ir_mine: DotInvManager
var _ir_server: DotInvManager
var _ir_on_refused

func _test_inventory_refused() -> void:
	_section("an op the server refuses is rolled back, and a good op sent behind it survives")

	_ir_mine = _client_bag()
	_ir_server = _server_bag()
	var net_half: PlaygroundInventoryNet = _client_bridge.inventory_net
	var reasons: Array[String] = []
	_ir_on_refused = func(reason: String) -> void: reasons.append(reason)
	_client_bridge.inventory_refused.connect(_ir_on_refused)

	var crates := _ir_mine.doc.count_of(&"crate")
	var server_crates := _ir_server.doc.count_of(&"crate")
	var docs := _server_bridge.inventory_net.docs_sent

	# A client giving itself something. Predicted like any other op, because a client
	# cannot know what it may do — and a predicting manager applies it before asking.
	var gift := _ir_mine.apply(DotInvOp.add(&"crate", 1, BACKPACK))
	_check(
		gift.ok and _ir_mine.doc.count_of(&"crate") == crates + 1,
		"a client that gives itself a crate sees it, locally"
	)
	var crate := _uid_at(_ir_mine, _cell_of(_ir_mine, &"crate"))
	var behind := _ir_mine.apply(DotInvOp.move(BACKPACK, crate, BACKPACK, Vector2i(9, 5)))
	_check(
		behind.ok and net_half.in_flight_count() == 2,
		"and moves its real crate right behind it, both in flight before either is answered"
	)

	var rolled := net_half.rolled_back_count
	_exchange()
	_check(
		_ir_server.doc.count_of(&"crate") == server_crates,
		"the server never gave it: an ADD from a client is the server's to do"
	)
	_check(reasons.size() == 1, "the client is told why", str(reasons))
	_check(
		_ir_mine.doc.count_of(&"crate") == crates and net_half.rolled_back_count == rolled + 1,
		"and the crate it gave itself is gone again"
	)
	_check(
		_uid_at(_ir_mine, Vector2i(9, 5)) != 0 and _uid_at(_ir_server, Vector2i(9, 5)) != 0,
		"while the move sent behind it survives the rollback — DotInvManager.rollback alone restores the snapshot from before the refused op, which undoes this one too"
	)
	_check(
		_ir_mine.pending_count() == 0 and net_half.in_flight_count() == 0,
		"and nothing is left waiting"
	)
	await _steps(4)
	_check(
		_bag_summary(_ir_mine) == _bag_summary(_ir_server) and _server_bridge.inventory_net.docs_sent == docs,
		"the two bags agree, uids and all, with no document sent to put it right",
		"%s vs %s, %d documents" % [_bag_summary(_ir_mine), _bag_summary(_ir_server), _server_bridge.inventory_net.docs_sent - docs]
	)

	# The race: the server has put something where the client is about to, and has not
	# said so yet — it says so once a tick, and this is inside one.
	var where := _first_free(_ir_server)
	var gave := _server_game.inventory.give(_server_bridge.inventory_net.bag_key(SESSION), &"barrel")
	_check(gave.ok and _cell_of(_ir_server, &"barrel") == where, "the server puts a barrel in the first free cell")
	var ball_was := _cell_of(_ir_mine, &"beach_ball")
	var into := _ir_mine.apply(DotInvOp.move(BACKPACK, _uid_at(_ir_mine, ball_was), BACKPACK, where))
	_check(into.ok, "and the client, not yet told, moves its ball into that same cell")
	_flush()
	_flush()
	_check(
		reasons.size() == 2 and _cell_of(_ir_mine, &"beach_ball") == ball_was,
		"the server refuses, and the ball springs back to where it was",
		"%s, ball at %s" % [str(reasons), str(_cell_of(_ir_mine, &"beach_ball"))]
	)
	await _test_inventory_refused_2()

func _test_inventory_refused_2() -> void:
	await _steps(2)
	_check(
		_ir_mine.doc.count_of(&"barrel") == 1 and _bag_summary(_ir_mine) == _bag_summary(_ir_server),
		"then the barrel arrives, and the two bags agree",
		"%s vs %s" % [_bag_summary(_ir_mine), _bag_summary(_ir_server)]
	)

	_client_bridge.inventory_refused.disconnect(_ir_on_refused)
	_done()


## dot-net drops a client request past its per-peer message rate and tells nobody. An op in
## that request would sit in the client's bag, predicted and never answered, for ever.
func _test_inventory_lost() -> void:
	_section("an op the transport dropped is rolled back, wherever in the stream it was lost")

	var mine := _client_bag()
	var server := _server_bag()
	var net_half: PlaygroundInventoryNet = _client_bridge.inventory_net

	# In the middle: the answer to the op behind it is what says it never arrived.
	var ball_was := _cell_of(mine, &"beach_ball")
	var a := mine.apply(DotInvOp.move(BACKPACK, _uid_at(mine, ball_was), BACKPACK, Vector2i(3, 3)))
	var dropped: bool = a.ok and not _to_server.is_empty() and _to_server.back()["method"] == &"request"
	if dropped:
		_to_server.pop_back()
	_check(dropped, "an op is predicted and its request is lost on the way")
	var crate_was := _cell_of(mine, &"crate")
	var b := mine.apply(DotInvOp.move(BACKPACK, _uid_at(mine, crate_was), BACKPACK, Vector2i(4, 4)))
	_check(b.ok and net_half.in_flight_count() == 2, "and a second op is sent behind it")
	_exchange()
	_check(
		_cell_of(mine, &"beach_ball") == ball_was and _cell_of(mine, &"crate") == Vector2i(4, 4),
		"the answer to the second rolls the first back, because an answer to #2 says #1 never came",
		"ball %s crate %s" % [str(_cell_of(mine, &"beach_ball")), str(_cell_of(mine, &"crate"))]
	)
	_check(
		net_half.in_flight_count() == 0 and _bag_summary(mine) == _bag_summary(server),
		"nothing is left waiting, and the bags agree",
		"%s vs %s" % [_bag_summary(mine), _bag_summary(server)]
	)

	# At the tail: nothing after it will ever be answered, so nothing can say it was lost.
	var t := mine.apply(DotInvOp.move(BACKPACK, _uid_at(mine, ball_was), BACKPACK, Vector2i(2, 2)))
	var tail: bool = t.ok and not _to_server.is_empty() and _to_server.back()["method"] == &"request"
	if tail:
		_to_server.pop_back()
	await _steps(2)
	var asked := net_half.resyncs_asked
	_check(
		tail and net_half.in_flight_count() == 1 and _cell_of(mine, &"beach_ball") == Vector2i(2, 2),
		"a last op lost on the way is still waiting, a few ticks later, with nothing to say so"
	)
	var clock := [Time.get_ticks_msec() + PlaygroundInventoryNet.RESYNC_AFTER_MS + 1000]
	net_half.now_fn = func() -> int: return int(clock[0])
	await _steps(2)
	_check(
		net_half.resyncs_asked == asked + 1,
		"once it is overdue the client asks for the whole bag"
	)
	_check(
		net_half.in_flight_count() == 0 and _cell_of(mine, &"beach_ball") == ball_was
			and _bag_summary(mine) == _bag_summary(server),
		"and the bag it is sent does not have the lost move in it: the bags agree",
		"%s vs %s" % [_bag_summary(mine), _bag_summary(server)]
	)
	net_half.now_fn = func() -> int: return Time.get_ticks_msec()
	_done()


## A purchase, a spawn from the bag and an admin's give all change a bag on the server. Each
## reaches its owner as the whole bag.
var _ifts_charged: Array[StringName]
var _ifts_bag: StringName
var _ifts_inv: PlaygroundInventory
var _ifts_balls: int

func _test_inventory_from_the_server() -> void:
	_section("what the server changes reaches the owner: a purchase, a spawn from the bag")

	_ifts_charged = []
	_server_bridge.charge_fn = func(_id: StringName, thing: StringName) -> DotResult:
		_ifts_charged.append(thing)
		return DotResult.success(null)

	_ifts_bag = _server_bridge.inventory_net.bag_key(SESSION)
	var barrels := _server_game.inventory.carries(_ifts_bag, &"barrel")

	_client_bridge.ask_buy(&"barrel")
	_exchange()
	await _steps(2)
	_check(_ifts_charged.size() == 1 and _ifts_charged[0] == &"barrel", "a barrel bought into the bag is charged for", str(_ifts_charged))
	_check(
		_server_game.inventory.carries(_ifts_bag, &"barrel") == barrels + 1
			and _client_bag().doc.count_of(&"barrel") == barrels + 1,
		"and lands in the bag on both ends"
	)
	_check(
		_bag_summary(_client_bag()) == _bag_summary(_server_bag()),
		"where the server put it, rather than wherever the client would have",
		"%s vs %s" % [_bag_summary(_client_bag()), _bag_summary(_server_bag())]
	)

	var notices: Array[String] = []
	var on_notice := func(_pid: int, text: String) -> void: notices.append(text)
	_client_bridge.notice_received.connect(on_notice)
	_client_bridge.ask_buy(&"boulder")
	_exchange()
	await _steps(2)
	_check(
		_ifts_charged.size() == 1 and _client_bag().doc.count_of(&"boulder") == 0,
		"a 900 kg boulder in a 400 kg bag is refused before anybody is charged",
		str(_ifts_charged)
	)
	_check(notices.size() == 1, "and the player is told why", str(notices))
	_client_bridge.notice_received.disconnect(on_notice)

	var props := _server_game.props.world_count()
	_client_bridge.ask_spawn_prop(&"barrel")
	_exchange()
	await _steps(4)
	_check(_server_game.props.world_count() == props + 1, "a barrel spawned from the bag appears")
	_check(_ifts_charged.size() == 1, "and is not charged for again: it was paid for when it went in", str(_ifts_charged))
	_check(
		_server_game.inventory.carries(_ifts_bag, &"barrel") == barrels
			and _client_bag().doc.count_of(&"barrel") == barrels,
		"and the bag has one fewer, on both ends"
	)

	# The server's own changes spend nobody's budget. They spent the PLAYER'S: thirty
	# a second, so the thirty-first thing given in a second was refused.
	_ifts_inv = _server_game.inventory
	_ifts_balls = _ifts_inv.carries(_ifts_bag, &"beach_ball")
	var burst := 0
	for i in range(35):
		if _ifts_inv.give(_ifts_bag, &"beach_ball").ok:
			burst += 1
	await _steps(2)
	_check(
		burst == 35 and _client_bag().doc.count_of(&"beach_ball") == _ifts_balls + 35,
		"thirty-five things given by the server in one tick all land, on both ends (%d)" % burst
	)
	await _test_inventory_from_the_server_2()

func _test_inventory_from_the_server_2() -> void:

	# A purchase into a bag with no ROOM. dot-inventory validated an ADD for the item, the
	# container and the weight and not for room, so asking only it charged first; it asks
	# room now, and this is the check that says so from here.
	var filled := _ifts_inv.give(_ifts_bag, &"beach_ball", _free_cells(_server_bag()))
	_check(filled.ok and _free_cells(_server_bag()) == 0, "the server fills the bag to the last cell")
	var validated := _server_bag().validate(DotInvOp.add(&"crate", 1, BACKPACK))
	_check(
		not validated.ok and validated.code() == DotError.CODE_QUOTA,
		"and dot-inventory's own validate says there is no room for a crate"
	)
	var paid := _ifts_charged.size()
	_client_bridge.ask_buy(&"crate")
	_exchange()
	await _steps(2)
	_check(
		_ifts_charged.size() == paid and _client_bag().doc.count_of(&"crate") == _server_bag().doc.count_of(&"crate"),
		"so a crate bought into it is refused before anybody is charged",
		str(_ifts_charged)
	)

	while _ifts_inv.carries(_ifts_bag, &"beach_ball") > _ifts_balls:
		if not _ifts_inv.take(_ifts_bag, &"beach_ball").ok:
			break
	await _steps(2)
	_check(
		_bag_summary(_client_bag()) == _bag_summary(_server_bag()),
		"and emptied again, the two bags agree",
		"%s vs %s" % [_bag_summary(_client_bag()), _bag_summary(_server_bag())]
	)

	_server_game.props.undo(_client_player().player_id if _client_player() != null else &"u%d" % SESSION)
	await _steps(2)
	_server_bridge.charge_fn = Callable()
	_done()


## Nobody else is told what anybody is carrying — not even that it changed, and not a bot's,
## whose peer id is the broadcast address.
func _test_inventory_is_private() -> void:
	_section("a bag is private: nobody else is told, not even that it changed")

	var other_peer := CLIENT_PEER + 3
	var other := SESSION + 3
	var bot := SESSION + 4

	_server_events.clear()
	_recording = true
	var added := _server_bridge.add_player(other_peer, other, "Cy")
	_server_bridge.link.deliver(&"request", other_peer, _request_bytes(PlaygroundEvents.Ask.READY))
	var bot_added := _server_bridge.add_player(0, bot, "Bot")
	await _steps(2)
	_check(added.ok and bot_added.ok, "a second player joins on a peer of their own, and a bot on none")

	var theirs := _inventory_events(other_peer)
	_check(
		theirs.size() == 1 and int(theirs[0]["sub"]) == PlaygroundEvents.InvTell.DOC
			and bool(theirs[0].get("ok", false)) and _doc_count(theirs[0]["doc"], "crate") == 0,
		"the second player is sent their own bag on admission, and it is empty",
		str(theirs)
	)

	_server_events.clear()
	var inv := _server_game.inventory
	var net_half: PlaygroundInventoryNet = _server_bridge.inventory_net
	var gave := inv.give(net_half.bag_key(SESSION), &"die").ok \
		and inv.give(net_half.bag_key(other), &"can").ok \
		and inv.give(net_half.bag_key(bot), &"ball").ok
	_check(gave, "the server changes all three bags in one tick")
	await _steps(2)

	var to_mine := _inventory_events(CLIENT_PEER)
	var to_other := _inventory_events(other_peer)
	_check(
		_inventory_events(0).is_empty(),
		"nothing about any bag is broadcast — not the bot's either, whose peer id is the broadcast address"
	)
	_check(
		to_other.size() == 1 and _doc_count(to_other[0].get("doc", {}), "can") == 1
			and _doc_count(to_other[0].get("doc", {}), "die") == 0
			and _doc_count(to_other[0].get("doc", {}), "crate") == 0,
		"the second player hears about their own can, and nothing of this client's bag",
		str(to_other)
	)
	_check(
		to_mine.size() == 1 and _doc_count(to_mine[0].get("doc", {}), "die") == 1
			and _doc_count(to_mine[0].get("doc", {}), "can") == 0
			and _doc_count(to_mine[0].get("doc", {}), "ball") == 0,
		"and this client hears about its die and nobody else's anything"
	)
	var peers := _inventory_peers()
	peers.sort()
	_check(
		peers.size() == 2 and peers[0] == CLIENT_PEER and peers[1] == other_peer,
		"no inventory message went anywhere but to the two owners",
		str(peers)
	)
	_check(
		_client_game.inventory.keys().size() == 1
			and _client_bag().doc.count_of(&"can") == 0 and _client_bag().doc.count_of(&"ball") == 0,
		"and this client still holds one bag, its own"
	)

	_recording = false
	_server_events.clear()
	_server_bridge.remove_player(other)
	_server_bridge.remove_player(bot)
	await _steps(4)
	_check(
		not inv.has_bag(net_half.bag_key(other)) and not inv.has_bag(net_half.bag_key(bot)),
		"and a bag that belonged to a session goes with it"
	)
	_done()


## Every EVENT kind the server sent to [param peer_id] while recording.
func _event_kinds(peer_id: int) -> Array[int]:
	var out: Array[int] = []
	for sent in _server_events:
		if int(sent["peer"]) != peer_id:
			continue
		var decoded := _client_net.messages.decode(DotNetReader.new(sent["payload"]), 1, false)
		if decoded.ok and decoded.value is PlaygroundEvent:
			out.append((decoded.value as PlaygroundEvent).kind)
	return out
