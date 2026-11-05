extends "res://examples/headless_presentation_part1.gd"


func _test_party_does_not_migrate() -> void:
	_section("A host leaving a sandbox takes the sandbox with them")

	DotP2PSignallerLoopback.reset_all()

	var party := PlaygroundParty.new()
	party.name = "Party"
	add_child(party)
	_check(party.setup().ok, "a party sets up")

	# The decision only this game makes, and it follows from one fact: the world IS the
	# host's physics state, so electing a new host hands everybody an empty room.
	_check(
		not party.session.config.migrate_host,
		"a sandbox does not migrate its host, because the world does not move with it"
	)
	_check(
		party.session.config.trust == DotP2PConfig.Trust.HOST_AUTHORITATIVE,
		"while the host decides, which in a sandbox is what a friend hosting should do"
	)

	_check(party.reporting_allowed(), "an ordinary session files what it likes")
	party.session._state = &"hosting"
	_check(
		not party.reporting_allowed(),
		"and a live one files nothing, asked in one place rather than by four reporters"
	)

	var lines := party.describe_lines()
	var says := false
	for l in lines:
		if l.contains("does not survive"):
			says = true
	_check(says, "and it says so when asked, rather than leaving it to be discovered")

	party.queue_free()
	_done()


func _test_touch_buttons() -> void:
	_section("A phone's on-screen buttons")
	var list := PlaygroundTouch.layout()
	var ids: Array = list.map(func(b: Dictionary) -> Variant: return b["id"])
	for want: StringName in [PlaygroundTouch.PREV, PlaygroundTouch.NEXT, PlaygroundTouch.BOARD, PlaygroundTouch.CHAT, PlaygroundTouch.MENU]:
		_check(ids.has(want), "the layout has the %s button" % want)
	var probe := DotTouchButtons.new()
	var m := probe.margin
	probe.free()
	for size: Vector2 in [Vector2(667, 375), Vector2(844, 390), Vector2(932, 430)]:
		var clear := true
		var inside := true
		for i in list.size():
			var a: Vector2 = size - Vector2(m, m) - (list[i]["offset"] as Vector2)
			var ra: float = list[i]["radius"]
			inside = inside and a.x - ra >= size.x * 0.5 and a.y - ra >= 0.0 and a.x + ra <= size.x and a.y + ra <= size.y
			for j in range(i + 1, list.size()):
				var b: Vector2 = size - Vector2(m, m) - (list[j]["offset"] as Vector2)
				clear = clear and a.distance_to(b) >= ra + float(list[j]["radius"])
		_check(inside, "every button sits in the right half at %dx%d" % [size.x, size.y])
		_check(clear, "and no two overlap at %dx%d" % [size.x, size.y])
	var got: Array = []
	var handlers := {}
	for id: StringName in [PlaygroundTouch.PREV, PlaygroundTouch.NEXT, PlaygroundTouch.BOARD, PlaygroundTouch.CHAT]:
		handlers[id] = func(down: bool) -> void: got.append([id, down])
	PlaygroundTouch.route(PlaygroundTouch.NEXT, true, Callable(), handlers)
	PlaygroundTouch.route(PlaygroundTouch.BOARD, false, Callable(), handlers)
	_check(got == [[PlaygroundTouch.NEXT, true], [PlaygroundTouch.BOARD, false]], "a press and a release reach their handlers", str(got))
	_done()


func _test_chat_box() -> void:
	_section("A sandbox where you can be talked to and can talk back")

	var p := _make()
	var window := p.chat_window

	_check(window != null, "the client builds a chat box at all")

	if window == null:
		_done()
		return

	_check(
		DotInputBinding.describe_action(window.open_action) == "Y",
		"opened by Y, which is where this genre has put it for twenty-five years"
	)

	# The channels are the server's own definitions rather than a second list here.
	var ids := PackedStringArray()
	for entry in window.channels:
		ids.append(String(entry.get("id", "")))
	_check(
		Array(ids).has(String(PlaygroundServices.CHANNEL_ALL))
			and Array(ids).has(String(PlaygroundServices.CHANNEL_NEAR)),
		"offering the channels the server actually routes (%s)" % [ids]
	)
	_check(
		not Array(ids).has(String(PlaygroundServices.CHANNEL_ADMIN)),
		"and not the admin one, which a player cannot send on anyway"
	)

	_check(window.enabled, "drawn by default, on a server that said nothing")

	p.set_chat_relayed(true)
	_check(not window.enabled, "auto takes it away when a relay is carrying chat")

	window.add_said("someone", "but you can still hear this")
	_check(
		window.line_count() > 0,
		"and the log still draws what other people said",
		"off means you type somewhere else, never that you are out of the conversation"
	)

	p.settings.set_value(&"chat_window", &"on")
	_check(window.enabled, "on keeps the box even with a relay running: both, if you want")

	p.settings.set_value(&"chat_window", &"off")
	_check(not window.enabled, "off never draws it")

	p.settings.set_value(&"chat_window", &"auto")
	p.set_chat_relayed(false)
	_check(window.enabled, "and auto gives it back")

	p.settings.set_value(&"chat_open_key", "T")
	_check(
		DotInputBinding.describe_action(window.open_action) == "T",
		"rebinding through the settings document moves the key"
	)
	_check(
		InputMap.action_get_events(window.open_action).size() == 1,
		"and leaves ONE binding, not the old one as well"
	)

	_check(not p.swallows_input(), "a closed box does not swallow input")
	window.open()
	_check(p.swallows_input(), "an open one does, so a typed key is not a tool being fired")
	window.close()
	_check(not p.swallows_input(), "and gives it back when it closes")

	_test_chat_drawn_once(p)

	_done()


## Every chat line is drawn once: in the box when there is one, on the notice line only when there is not.
## The client is never added to the tree (its `_ready` builds the netcode); only the handler and three fields are used.
func _test_chat_drawn_once(p: PlaygroundPresentation) -> void:
	var hud := PlaygroundHud.new()
	hud.name = "ChatHud"
	add_child(hud)
	var notice: Label = hud.get_node("Notice")

	var chat := DotChatClient.new()
	chat.channels = PlaygroundServices.chat_channels()

	var client = PlaygroundClient.new()
	client.hud = hud
	client.chat = chat
	client.presentation = p

	var window := p.chat_window
	var before := window.line_count()
	client._on_chat_message(
		DotChatMessage.system(PlaygroundServices.CHANNEL_ALL, "Vote: Surf, Bhop, Lobby (30s)"),
		PlaygroundServices.CHANNEL_ALL
	)
	_check(
		window.line_count() == before + 1 and notice.text == "",
		"a server line (a ballot) is drawn in the chat box and not on the notice line too",
		"box %d -> %d, notice '%s'" % [before, window.line_count(), notice.text]
	)

	before = window.line_count()
	client._on_chat_message(
		DotChatMessage.say(PlaygroundServices.CHANNEL_ALL, "k1", "ada", "gg"),
		PlaygroundServices.CHANNEL_ALL
	)
	_check(
		window.line_count() == before + 1 and notice.text == "",
		"and so is a player's line",
		"box %d -> %d, notice '%s'" % [before, window.line_count(), notice.text]
	)

	# A join notice is a name and NO text (dot-chat's `_presence`). Drawn by its text it
	# was an empty row in the box; drawn by name and text, a bare "Guest 435:", which read
	# as a chat command echoed with its text stripped.
	client._on_chat_message(
		DotChatMessage.make(
			DotChatMessage.Kind.JOIN, PlaygroundServices.CHANNEL_ALL, "k2", "Guest 435", ""
		),
		PlaygroundServices.CHANNEL_ALL
	)
	var rows := window.history()
	var drawn := ""
	for part in (rows[rows.size() - 1] if not rows.is_empty() else []):
		drawn += str((part as Dictionary).get("text", ""))
	_check(
		drawn.contains("Guest 435") and drawn.contains("joined"),
		"a join notice is drawn as a sentence, not as an empty line or a bare name",
		"'%s'" % drawn
	)

	client.presentation = null
	client._on_chat_message(
		DotChatMessage.say(PlaygroundServices.CHANNEL_ALL, "k1", "ada", "still here"),
		PlaygroundServices.CHANNEL_ALL
	)
	_check(
		notice.text.contains("ada") and notice.text.contains("still here"),
		"with no box the notice line carries it, so a line is never lost",
		"notice '%s'" % notice.text
	)

	client.free()
	chat.free()
	hud.queue_free()


func _test_every_sound_has_a_voice() -> void:
	# Both directions go wrong without erroring: an id with no recipe stays silent for ever, and a recipe
	# naming an id the catalogue lacks reaches nothing. A headless run cannot hear; audio_probe.sh is the other half.
	_section("Every sound this game declares has a noise to make")

	var cat := PlaygroundPresentation.sound_catalogue()
	var recipes := PlaygroundPresentation.sound_recipes()

	var uncovered: Array[String] = []
	for id in cat.ids():
		# dot-audio's stock footsteps and beds are files the addon ships: no stand-in needed.
		if not recipes.has(id) and not DotAudioStock.ids().has(id) and not String(id).begins_with(DotAmbience.ID_PREFIX):
			uncovered.append(String(id))
	_check(
		uncovered.is_empty(),
		"every id in the catalogue has a stand-in voice",
		"silent for ever: %s" % str(uncovered)
	)

	var stray: Array[String] = []
	for id in recipes.keys():
		if cat.find(StringName(id)) == null:
			stray.append(String(id))
	_check(stray.is_empty(), "and no recipe names an id that is not there", str(stray))

	# An administrator's beacon: positional and far-reaching, because its whole job is to
	# say WHERE somebody is from across a two-hundred-metre sandbox; and pitched away from
	# the vote's warning, whose voice it shares, so a ping is never heard as a ballot.
	var ping := cat.find(PlaygroundPresentation.BEACON_SOUND)
	_check(
		ping != null and ping.kind == DotAudioDef.Kind.POSITIONAL_3D and ping.max_distance >= 100.0,
		"the beacon's ping is positional and carries across the sandbox"
	)
	_check(
		ping != null and ping.pitch_max < 1.0
		and recipes.get(PlaygroundPresentation.BEACON_SOUND) == recipes.get(PlaygroundVote.CUE_WARNING),
		"and is the vote warning's voice pitched down, so the two are not confused"
	)

	var bank := DotAudioSynth.bank(cat, recipes)
	_check(
		bank.has(&"buy") and bank.has("res://audio/buy.ogg"),
		"the bank answers under both the id and the path the def names"
	)
	_check(
		(
			(bank[&"buy"] as AudioStreamWAV).data
			!= (bank[&"refused"] as AudioStreamWAV).data
		),
		"and buy does not sound like refused",
		"a buy that went through and a buy that was refused are indistinguishable without it, which is the whole reason `refused` has a sound at all"
	)

	_done()


## A stand-in rendezvous: the four routes `DotP2PSignallerHttp` speaks, on a real socket, answering each request
## [member delay] frames after it arrives. The delay is the point: the loopback signaller answers inside the call,
## so a caller that forgot `await` passes against it.
class RendezvousStub:
	extends Node

	var port := 0
	var delay := 4
	## An HTTP status to answer everything with instead of 200, to see a refusal arrive.
	var refuse := 0
	## What arrived, in order: `{route, body}`.
	var seen: Array[Dictionary] = []
	## Per route, the ids that announced themselves, so a join answers with who is here.
	var present: Array[String] = []

	var _server := TCPServer.new()
	var _open: Array[Dictionary] = []
	## Answered requests, erased after the loop so it walks `_open` itself, not a copy.
	var _answered: Array[Dictionary] = []
	## Held as Callables: a stand-in server's per-request work, not a per-frame cost the frame-hazards gate should read.
	var _reply: Callable = _send_reply
	var _route: Callable = _answer

	func start() -> bool:
		for candidate in range(38700, 38760):
			if _server.listen(candidate, "127.0.0.1") == OK:
				port = candidate
				return true
		return false

	func _exit_tree() -> void:
		_server.stop()

	func _process(_delta: float) -> void:
		while _server.is_connection_available():
			_open.append({"peer": _server.take_connection(), "bytes": PackedByteArray(), "wait": -1})

		for c in _open:
			var peer: StreamPeerTCP = c["peer"]
			peer.poll()
			var available := peer.get_available_bytes()
			if available > 0:
				var got := peer.get_data(available)
				if int(got[0]) == OK:
					# Written back: a packed array is a value, so appending to the one read
					# out of the dictionary appends to a copy and the bytes are lost.
					var buffer: PackedByteArray = c["bytes"]
					buffer.append_array(got[1] as PackedByteArray)
					c["bytes"] = buffer

			if int(c["wait"]) < 0:
				var text := (c["bytes"] as PackedByteArray).get_string_from_utf8()
				var split := text.find("\r\n\r\n")
				if split < 0:
					continue
				var length := 0
				for line in text.substr(0, split).split("\r\n"):
					if line.to_lower().begins_with("content-length:"):
						length = line.get_slice(":", 1).strip_edges().to_int()
				if (c["bytes"] as PackedByteArray).size() < split + 4 + length:
					continue
				var first := text.get_slice("\r\n", 0)
				var target := first.get_slice(" ", 1)
				var route := target.get_slice("?", 0).get_file()
				var body: Variant = JSON.parse_string(text.substr(split + 4)) if length > 0 else {}
				c["route"] = route
				c["body"] = body if body is Dictionary else {}
				seen.append({"route": route, "body": c["body"]})
				c["wait"] = delay
				continue

			if int(c["wait"]) > 0:
				c["wait"] = int(c["wait"]) - 1
				continue

			_reply.call(peer, _route.call(String(c["route"]), c["body"] as Dictionary))
			_answered.append(c)

		for c in _answered:
			_open.erase(c)
		_answered.clear()

	func _send_reply(peer: StreamPeerTCP, answer: Dictionary) -> void:
		var status := "200 OK" if refuse == 0 else "%d Refused" % refuse
		var payload := JSON.stringify(answer).to_utf8_buffer()
		var head := "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, payload.size()]
		peer.put_data(head.to_utf8_buffer())
		peer.put_data(payload)
		peer.disconnect_from_host()

	func _answer(route: String, body: Dictionary) -> Dictionary:
		match route:
			"host":
				present.append(str(body.get("id", "")))
				return {}
			"join":
				var here := present.duplicate()
				present.append(str(body.get("id", "")))
				return {"peers": here}
			"poll":
				return {"messages": [], "cursor": 0}
		return {}
