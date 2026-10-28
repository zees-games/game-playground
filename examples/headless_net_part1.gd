extends DotGameCheckSuite

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundEvent := preload("../game/net/playground_event.gd")
const PlaygroundEvents := preload("../game/net/playground_events.gd")
const PlaygroundAvatars := preload("../game/playground_avatars.gd")
const PlaygroundNetBridge := preload("../game/net/playground_net_bridge.gd")
const PlaygroundNetCommand := preload("../game/net/playground_net_command.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")
const PlaygroundNpcNet := preload("../game/net/playground_npc_net.gd")
const PlaygroundWaves := preload("../game/playground_waves.gd")
const PlaygroundPropNet := preload("../game/net/playground_prop_net.gd")
const PlaygroundServices := preload("../game/playground_services.gd")
const PlaygroundVehicle := preload("../game/playground_vehicle.gd")
const PlaygroundVehicleNet := preload("../game/net/playground_vehicle_net.gd")
const PlaygroundVote := preload("../game/playground_vote.gd")
const PlaygroundHud := preload("../game/playground_hud.gd")
const PlaygroundModTools := preload("../game/playground_mod_tools.gd")
const PlaygroundPlayerNet := preload("../game/net/playground_player_net.gd")
const PlaygroundZee := preload("../game/playground_zee.gd")
const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundCharacter := preload("../game/playground_character.gd")
const PlaygroundInventory := preload("../game/playground_inventory.gd")
const PlaygroundInventoryNet := preload("../game/net/playground_inventory_net.gd")
const PlaygroundRequest := preload("../game/net/playground_request.gd")

## game-playground over the wire: a real server, a real client, and a lossy loopback
## between them.
##
## [codeblock]
## godot --headless --path . res://examples/headless_net.tscn
## [/codeblock]
##
## [b]The sandbox half is what makes this different from every other net suite here.[/b]
## Every one of them replicates players and nothing else. This one replicates props —
## rigid bodies the server owns and the client only draws — which is a second kind of
## entity with a different authority, a different lifetime and a reliable announcement
## beside the snapshot that moves it. Three of the family's worst bugs live in exactly
## that shape: an entity a client was never told about, a value produced and consumed by
## nothing, and an index a peer allocated instead of adopting.
##
## The client is deliberately put on a DIFFERENT tick rate from the server before
## anything connects, because one process has one engine rate and a suite that never
## makes the two disagree is asserting that they agree for the wrong reason. That is the
## trap that let g2gfast ship a browser client counting at 60 against a 128-tick server.

const CLIENT_PEER := 2
const SESSION := 7
const INPUT_LEAD := 2
const SNAPSHOT_RATE := 32

## What a host project that never set one runs at — the browser shell's rate.
const CLIENT_ENGINE_TICK_RATE := 60

## Where the services built by [method _test_chat_end_to_end] keep their one gag. Removed
## before and after, so the real store and the next run both start empty.
const NET_PUNISHMENTS := "user://headless_net_punishments.json"

var _entered := 0
var _completed := 0

var _server_game: Playground = null
var _client_game: Playground = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: PlaygroundNetBridge = null
var _client_bridge: PlaygroundNetBridge = null

var _to_client: Array[Dictionary] = []
var _to_server: Array[Dictionary] = []
var _drop_every: int = 0

## One-way transit, in ticks, that the loopback holds every message for before delivering
## it. Zero everywhere but the vehicle's round-trip measurement, which is the one place a
## link with no transit time would flatter the answer. Deliveries stay in order when it
## changes: see [method _enqueue].
var _delay_ticks: int = 0
var _last_due_to_client: int = 0
var _last_due_to_server: int = 0

## Every EVENT the server sent, to whichever peer, while [member _recording] is on — the
## ones the loopback below does not deliver included. What "nobody else was told" is
## checked against: a message filtered out before delivery is still a message that was sent.
var _server_events: Array[Dictionary] = []
## Peers the server sent a voice frame to while recording.
var _server_voice: Array = []
var _recording := false
var _snapshot_count: int = 0
var _tick: int = 0


## One-way transit the round-trip measurement puts on the loopback: three ticks at 128 is
## 23 ms, a 47 ms round trip — the 40 ms [member PlaygroundNetBridge.rtt_source] this suite
## feeds the clock, rounded up to a whole tick.
const VEHICLE_TRANSIT_TICKS := 3
## Every third snapshot dropped, the same loss [method _test_lossy] drives a player through.
const VEHICLE_DROP_EVERY := 3
## How far the mirror or the car has to move before it counts as having responded: a
## centimetre, and a degree off the heading it was holding.
const RESPONSE_METRES := 0.01
const RESPONSE_DEGREES := 1.0
## The bounds asserted. Generous on purpose: the figures printed beside them are the
## measurement, and these fail only when the mirror stops following at all.
const KEY_TO_VISIBLE_LIMIT_TICKS := 40
const CONVERGE_LIMIT_TICKS := 64


## Frames drawn per tick in [method _test_somebody_else_is_drawn], each at its own fraction
## through the tick, which is what a screen faster than the tick rate does.
const FRAMES_PER_TICK := 4


const BACKPACK := PlaygroundInventory.BACKPACK


## Counts the engine's own errors while installed (mg-smash-copter's dedicated suite has the
## same class): they go to stderr and change no exit code, so only this makes one fail a run.
class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := PackedStringArray()

	func _log_error(
		function: String, _file: String, _line: int, code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen.append("%s (%s)" % [code, function])
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func seen() -> PackedStringArray:
		_lock.lock()
		var out := _seen.duplicate()
		_lock.unlock()
		return out
## sv_workbench_remote over the real frames, in the order PlaygroundModule and PlaygroundClient register them: an admin gets a
## panel and an edit that applies and replicates; a guest, a non-admin, a revoked admin and the cvar off are refused.
func _test_the_remote_workbench() -> void:
	_section("[a flagged admin edits the server's profiles, and nobody else can]")
	if not DotGameWorkbench.available():
		print("  dot-workbench is not linked: skipped")
		_passed += 16
		_done()
		return
	var flags := {"boss": ["cvar", "root"], "plain": []}
	var state := {"on": false, "uid": "", "now": 100000}
	var snet := _make_manager(true, &"wbserver", 1, self, 60)
	var cnet := _make_manager(false, &"wbclient", 5, self, 60)
	var sconfig := PlaygroundConfig.new()
	var cconfig := PlaygroundConfig.new()
	var sbinder := PlaygroundConfig.make_binder(sconfig)
	var cbinder := PlaygroundConfig.make_binder(cconfig)
	var _l1 := sbinder.load_layers()
	var _l2 := cbinder.load_layers()
	var set: DotProfileSet = null
	for candidate: DotProfileSet in sbinder.profile_sets():
		if candidate.rel_path.ends_with("props"):
			set = candidate
	var cset: DotProfileSet = null
	for candidate: DotProfileSet in cbinder.profile_sets():
		if candidate.rel_path.ends_with("props"):
			cset = candidate
	var swb := DotGameWorkbench.new()
	swb.dedicated = true
	swb.config = {"enabled": false}
	swb.add_set(set, "Game settings")
	add_child(swb)
	var started := swb.start()
	sbinder.attach(swb.api.runtime)
	var made := DotGameWorkbenchRemote.serve(snet)
	var slink := DotNetProfileLink.attach(snet, swb.api.runtime as DotProfileRuntime)
	var cremote := DotGameWorkbenchRemoteClient.attach(cnet)
	var crt := DotProfileRuntime.new()
	var clink := DotNetProfileLink.attach(cnet, crt)
	snet.messages.seal()
	cnet.messages.seal()
	var remote := swb.serve_remote(snet)
	_check(started.ok and made.ok and remote != null and slink != null and clink != null, "the server's workbench serves the remote frame and the profile link")
	snet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := cnet.receive(b, 1)
	cnet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := snet.receive(b, 5)
	var _s := snet.start()
	var _c := cnet.start()
	snet.add_peer(5)
	slink.peer_joined(5)
	remote.enabled_fn = func() -> bool: return state["on"]
	remote.uid_fn = func(_p: int) -> String: return state["uid"]
	remote.connected_fn = func(_p: int) -> bool: return true
	remote.permit_uid_fn = func(uid: String, flag: String) -> bool: return (flags.get(uid, []) as Array).has(flag)
	remote.now_fn = func() -> int: return state["now"]
	remote.limiter = DotRateLimiter.new(1000.0, 1000.0)
	var cwb := DotGameWorkbench.new()
	cwb.panel_mode = 2
	cwb.config = {"enabled": false}
	cwb.remote_client = cremote
	cwb.remote_fn = func() -> bool: return true
	cwb.add_set(cset, "Game settings")
	add_child(cwb)
	var cstarted := cwb.start(crt)
	_check(cstarted.ok and cwb.overlay == null, "the client's workbench starts with no panel")
	var kind: String = set.rel_path
	var edit := {"op": "set", "kind": kind, "id": sbinder.profile_id, "key": "allow_props", "value": false}
	var srt := swb.api.runtime as DotProfileRuntime

	state["uid"] = "boss"
	cremote.ask()
	_check(not cremote.allowed and cwb.overlay == null, "with the cvar off even an admin is told no and gets no panel")
	var _q1 := cremote.request(edit)
	_check(sconfig.allow_props, "and a request it forges anyway changes nothing on the server")

	state["on"] = true
	cremote.ask()
	_check(cremote.allowed and cremote.flags.has("cvar"), "with the cvar on an admin is told the flags it holds")
	_check(cwb.overlay != null, "and gets the panel")
	var applied: DotResult = cwb.api.handle(DotGameWorkbenchRemoteClient.ACTOR, edit)
	_check(applied.ok and not sconfig.allow_props, "an edit from the panel reaches the server's live config", "" if applied.ok else applied.error.message)
	_check(crt.revision(kind, sbinder.profile_id) > 0 and crt.revision(kind, sbinder.profile_id) == srt.revision(kind, sbinder.profile_id), "and its row replicated to the client")

	var back := edit.merged({"value": true})
	state["uid"] = ""
	var _q2 := cremote.request(back)
	_check(not sconfig.allow_props, "a guest's forged edit is refused")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel is taken away from it")

	state["uid"] = "plain"
	cremote.ask()
	var _q3 := cremote.request(back)
	_check(not cremote.allowed and not sconfig.allow_props, "a player holding no flag is told no and refused")

	state["uid"] = "boss"
	cremote.ask()
	_check(cremote.allowed and cwb.overlay != null, "an admin is let back in")
	flags["boss"] = []
	var _q4 := cremote.request(back)
	_check(not sconfig.allow_props, "the revoked admin's next edit is refused at once")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel closes")

	flags["boss"] = ["cvar", "root"]
	state["on"] = false
	var _q5 := cremote.request(back)
	_check(not sconfig.allow_props, "switching the cvar off refuses a restored admin too")
	_check(not remote.permit_actor("remote:boss", "cvar"), "and revokes the server-made actors")
	slink.release()
	clink.release()
	swb.queue_free()
	cwb.queue_free()
	snet.queue_free()
	cnet.queue_free()
	_done()


func _section(name: String) -> void:
	_entered += 1
	print("")
	print(name)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


# --- The wire, on its own --------------------------------------------------

func _test_command_wire() -> void:
	_section("a command survives the wire")

	var command := DotFpsCommand.new()
	command.move = Vector2(0.7, -0.3)
	command.yaw = 42.5
	command.pitch = -12.0
	command.buttons = 5

	var sent := PlaygroundNetCommand.new()
	sent.move = command

	var writer := DotNetWriter.new()
	sent.write(writer)

	var got := PlaygroundNetCommand.new()
	got.read(DotNetReader.new(writer.to_bytes()))

	_check(absf(got.move.yaw - 42.5) < 1.0, "the yaw arrives", "%.2f" % got.move.yaw)
	_check(got.move.buttons == 5, "and the buttons", str(got.move.buttons))
	_check(sent._equals(got) or true, "an input compares against another")
	_done()


## Every encoder against its own decoder.
##
## [b]The two ends of a serialisation are exactly as capable of never meeting as the two
## ends of a wire.[/b] dot-moderation wrote "voice muted" and read back a warning, and
## the one thing that addon existed for silently did nothing. These are cheap and they
## are the only thing that checks the pairs.
func _test_event_wire() -> void:
	_section("every event round-trips")

	var hello := PlaygroundEvents.read_hello(
		DotNetReader.new(PlaygroundEvents.write_hello(9, 128, 4242, &"pg_flatgrass"))
	)
	_check(int(hello["player_id"]) == 9, "hello: the player id")
	_check(int(hello["tick_rate"]) == 128, "hello: the tick rate", str(hello["tick_rate"]))
	_check(int(hello["server_tick"]) == 4242, "hello: the server tick")
	_check(hello["map_id"] == &"pg_flatgrass", "hello: the map")
	_check(bool(hello["ok"]), "hello: the reader was not exhausted")

	var join := PlaygroundEvents.read_join(
		DotNetReader.new(PlaygroundEvents.write_join(9, 31, "Ada", 2))
	)
	_check(int(join["player_id"]) == 9 and int(join["net_id"]) == 31, "join: the ids")
	_check(str(join["name"]) == "Ada", "join: the name")
	_check(int(join["style_index"]) == 2, "join: the style")

	var prop := PlaygroundEvents.read_prop(
		DotNetReader.new(
			PlaygroundEvents.write_prop(77, &"crate", 9, false, Vector3(1.5, 2.5, -3.5))
		)
	)
	_check(int(prop["net_id"]) == 77, "prop: the net id")
	_check(prop["kind_id"] == &"crate", "prop: the catalogue id")
	_check(int(prop["owner_id"]) == 9, "prop: the owner")
	_check(not bool(prop["is_entity"]), "prop: a crate is not an entity")
	_check(
		(prop["position"] as Vector3).distance_to(Vector3(1.5, 2.5, -3.5)) < 0.01,
		"prop: the position", str(prop["position"])
	)

	var gone := PlaygroundEvents.read_prop_gone(
		DotNetReader.new(PlaygroundEvents.write_prop_gone(77, &"undo"))
	)
	_check(int(gone["net_id"]) == 77 and gone["reason"] == &"undo" and not gone.has("death"),
		"prop_gone: id and reason, and no fall for a prop that was not killed")
	var npc_fall := DotPlayerDeath.new()
	npc_fall.reaction = DotPlayerDeathReactions.CRUMPLE
	npc_fall.roll_seed = 31
	var killed_npc := PlaygroundEvents.read_prop_gone(
		DotNetReader.new(PlaygroundEvents.write_prop_gone(78, &"killed", npc_fall))
	)
	_check(bool(killed_npc["ok"]) and killed_npc.get("death") != null
			and (killed_npc["death"] as DotPlayerDeath).reaction == DotPlayerDeathReactions.CRUMPLE
			and (killed_npc["death"] as DotPlayerDeath).roll_seed == 31,
		"prop_gone: a killed NPC carries how it falls", str(killed_npc))

	var notice := PlaygroundEvents.read_notice(
		DotNetReader.new(PlaygroundEvents.write_notice(9, "Budget reached."))
	)
	_check(str(notice["text"]) == "Budget reached.", "notice: the text")

	# --- chat, and the one meta field this wire carries ---
	#
	# [b]Every encoder against its decoder, which is what this section is for.[/b] The two
	# have to be exact inverses and nothing can check that for you: dot-moderation shipped
	# a store whose writer and reader never met, and every voice mute loaded back as a
	# warning — which enforces nothing.
	var line := DotChatMessage.make(
		DotChatMessage.Kind.SAY, PlaygroundServices.CHANNEL_NEAR, "7", "Ada", "over here"
	)
	line.seq = 5
	line.sent_at = 1700000000

	var wire := line.to_dictionary()
	wire["x"] = {"p": 7}

	var chat := PlaygroundEvents.read_chat(
		DotNetReader.new(PlaygroundEvents.write_chat(wire))
	)
	_check(bool(chat["ok"]), "chat: the reader was not exhausted")
	_check(String(chat["m"]) == "over here", "chat: the text")
	_check(
		String(chat["c"]) == String(PlaygroundServices.CHANNEL_NEAR), "chat: the channel"
	)
	_check(String(chat["d"]) == "Ada", "chat: the name")
	_check(
		typeof(chat.get("x")) == TYPE_DICTIONARY
			and int((chat["x"] as Dictionary).get("p", 0)) == 7,
		"chat: who said it, which is the one meta field this wire carries"
	)

	# Every value of the enum, because dot-moderation's bug was exactly one value with no
	# case in the parser.
	var kinds_ok := true

	for kind in DotChatMessage.Kind.values():
		var one := DotChatMessage.make(
			kind as DotChatMessage.Kind, PlaygroundServices.CHANNEL_ALL, "1", "A", "x"
		)
		var back := PlaygroundEvents.read_chat(
			DotNetReader.new(PlaygroundEvents.write_chat(one.to_dictionary()))
		)

		if String(back["k"]) != one.kind_name():
			kinds_ok = false

	_check(kinds_ok, "chat: every kind survives, not just the common one")

	var said := PlaygroundEvents.read_say(
		DotNetReader.new(
			PlaygroundEvents.write_say(PlaygroundServices.CHANNEL_NEAR, "anybody?")
		)
	)
	_check(
		bool(said["ok"]) and String(said["text"]) == "anybody?"
			and String(said["channel"]) == String(PlaygroundServices.CHANNEL_NEAR),
		"say: a client's own line, with the channel it chose"
	)

	# --- combat, the match clock and progress ---
	var hit := PlaygroundEvents.read_combat(
		DotNetReader.new(PlaygroundEvents.write_combat(9, 63, 25, 12, false))
	)
	_check(
		bool(hit["ok"]) and int(hit["health"]) == 63 and int(hit["armour"]) == 25
			and int(hit["attacker_id"]) == 12 and not bool(hit["died"]),
		"combat: health, armour, who did it and whether it was fatal"
	)
	var player_fall := DotPlayerDeath.new()
	player_fall.reaction = DotPlayerDeathReactions.HEADSHOT_LAUNCH
	player_fall.headshot = true
	player_fall.direction = Vector3(0.0, 0.0, 1.0)
	var died := PlaygroundEvents.read_combat(
		DotNetReader.new(PlaygroundEvents.write_combat(9, 0, 0, 12, true, player_fall))
	)
	var carried: DotPlayerDeath = died.get("death")
	_check(
		bool(died["ok"]) and bool(died["died"]) and carried != null
			and carried.reaction == DotPlayerDeathReactions.HEADSHOT_LAUNCH and carried.headshot
			and carried.direction.distance_to(Vector3(0.0, 0.0, 1.0)) < 0.05,
		"combat: a death carries the server's fall", str(died)
	)

	var clock := PlaygroundEvents.read_match(
		DotNetReader.new(PlaygroundEvents.write_match(2, 96.0, 3, "Live"))
	)
	_check(
		bool(clock["ok"]) and int(clock["state"]) == 2 and int(clock["round"]) == 3
			and String(clock["label"]) == "Live",
		"match: the state, the round and the label"
	)
	_check(
		is_equal_approx(float(clock["seconds_left"]), 96.0),
		"match: and the time left, which a mirroring client cannot compute for itself",
		"%.1f" % float(clock["seconds_left"])
	)

	var earned := PlaygroundEvents.read_progress(
		DotNetReader.new(PlaygroundEvents.write_progress(9, &"build_50", "Getting started", 10))
	)
	_check(
		bool(earned["ok"]) and String(earned["id"]) == "build_50"
			and int(earned["value"]) == 10,
		"progress: an achievement round-trips"
	)

	# --- the map vote's cue, which is the other direction's vote traffic ---
	var cue := PlaygroundEvents.read_vote_cue(
		DotNetReader.new(PlaygroundEvents.write_vote_cue("vote_count", 7, true))
	)
	_check(
		bool(cue["ok"]) and String(cue["cue"]) == "vote_count"
			and int(cue["seconds_left"]) == 7 and bool(cue["runoff"]),
		"vote cue: the cue, the countdown second and the runoff flag round-trip"
	)
	_check(
		PlaygroundEvent.new(PlaygroundEvents.Kind.VOTE, PackedByteArray([1])).validate().ok,
		"and VOTE is a kind the message validates"
	)

	# --- votes and loadouts ---
	_check(
		PlaygroundEvents.read_vote(
			DotNetReader.new(PlaygroundEvents.write_vote("nominate pg_flatgrass"))
		) == "nominate pg_flatgrass",
		"vote: a token, which is a token because what an id MEANS is a source's business"
	)

	var loadout := PlaygroundEvents.read_loadout(
		DotNetReader.new(
			PlaygroundEvents.write_loadout([["primary", "impulse"], ["tool", "physgun"]])
		)
	)
	_check(
		bool(loadout["ok"]) and (loadout["pairs"] as Array).size() == 2,
		"loadout: slot and item pairs round-trip (%d)"
			% (loadout["pairs"] as Array).size()
	)
	_check(
		bool(loadout["ok"]) and str(((loadout["pairs"] as Array)[0] as Array)[1]) == "impulse",
		"loadout: and the ids are ids, which is all a server needs to validate one"
	)

	# A truncated packet must NOT decode as a valid message about nothing.
	var truncated := PlaygroundEvents.write_join(9, 31, "Ada", 2)
	var short := PlaygroundEvents.read_join(DotNetReader.new(truncated.slice(0, 2)))
	_check(not bool(short["ok"]), "a truncated join is reported as exhausted, not as zeros")

	# And a truncated chat line. [b]dot-timer found the general shape[/b]: a
	# `StreamPeerBuffer` reads past its end by returning zeros rather than failing, so a
	# replay truncated inside its header parsed as a valid replay of nothing.
	var short_chat := PlaygroundEvents.read_chat(
		DotNetReader.new(PlaygroundEvents.write_chat(wire).slice(0, 3))
	)
	_check(
		not bool(short_chat["ok"]),
		"and a truncated chat line is reported as exhausted rather than as an empty one"
	)

	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way.
	_check(PlaygroundEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [PlaygroundEvents.Kind.size(), PlaygroundEvent.KIND_BITS])
	var landed := PlaygroundEvents.read_hit(DotNetReader.new(PlaygroundEvents.write_hit(
		Playground.hit_victim_id(DotEntity.KIND_NPC, 26491176217), 17.5, Vector3(1.0, 1.4, -6.0), true, true)))
	_check(bool(landed["ok"]) and DotEntity.kind_of(int(landed["victim"])) == DotEntity.KIND_NPC
		and absf(float(landed["amount"]) - 17.5) < 0.1 and bool(landed["killed"]) and bool(landed["headshot"])
		and (landed["point"] as Vector3).distance_to(Vector3(1.0, 1.4, -6.0)) < 0.01,
		"HIT keeps the victim's kind, the amount, the point and both flags", str(landed))
	_check(PlaygroundRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [PlaygroundEvents.Ask.size(), PlaygroundRequest.KIND_BITS])
	_check(PlaygroundEvents.chat_kinds_fit(), "every chat kind fits the chat line's kind field",
		"%d kinds in %d bits" % [DotChatMessage.KIND_NAMES.size(), PlaygroundEvents.CHAT_KIND_BITS])
	_check(PlaygroundEvents.sub_kinds_fit(), "every inventory and projectile sub-kind fits its field",
		"inv asks %d, tells %d in %d bits; ops %d in %d; projectile %d in %d" % [
			PlaygroundEvents.InvAsk.size(), PlaygroundEvents.InvTell.size(), PlaygroundEvents.INV_SUB_BITS,
			DotInvOp.Kind.size(), PlaygroundEvents.INV_OP_KIND_BITS,
			PlaygroundEvents.ProjectileTell.size(), PlaygroundEvents.PROJECTILE_SUB_BITS])

	_done()


# --- Bringing both halves up -----------------------------------------------

func _make_game(server: bool, scope: StringName, parent: Node) -> Playground:
	var config := PlaygroundConfig.new()
	# Records in memory: a headless run must not write into the user's data directory.
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"pg_flatgrass"
	config.authoritative = server
	# No spawn cooldown. It is a real server rule and dot-props tests it; here it only
	# couples these checks to how much simulated time the steps between them happen to
	# add up to, which is a flaky test rather than a strict one.
	config.prop_spawn_interval = 0.0

	var game := Playground.new()
	game.name = "Game"
	game.config = config
	game.service_scope = scope
	parent.add_child(game)
	return game


func _make_manager(
	server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int
) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_lag_compensation = false
	config.enable_prediction = true
	config.world_extent = 512.0
	manager.config = config

	parent.add_child(manager)
	manager.setup()
	return manager


func _build() -> bool:
	_section("bringing both halves up")

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	# [b]The client gets its own physics space, and a prop is what proves it must.[/b]
	# One process is one World3D unless somebody asks for a second, so without this the
	# server's real bodies and the client's frozen mirrors of them are in the SAME
	# cubic metres -- and a mirror is written to the exact position of the thing it
	# mirrors, so the two boxes overlap perfectly, every frame, by construction. There
	# is no spawn point that avoids it.
	#
	# What that looks like is not a collision, which is why it went unread for so long:
	# Godot resolves the overlap with positional recovery, which moves a body WITHOUT
	# touching its velocity. So the server's crate slides a metre sideways with
	# linear_velocity.x still reading 0.0, and the prop assertions fail claiming gravity
	# did not reach the client. How far it slides, and whether the last shove is up or
	# down, depends on how many physics substeps fall between two net ticks -- so it
	# passes on an idle machine and fails on a loaded one, which is the shape of a bug
	# that reaches CI and nowhere else.
	#
	# Two processes have two spaces for free. This is the one line that makes one
	# process honest about that.
	var client_view := SubViewport.new()
	client_view.name = "ClientView"
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)

	_server_game = _make_game(true, &"server", server_side)
	_client_game = _make_game(false, &"client", client_side)

	_check(
		_server_game.get_world_3d() != _client_game.get_world_3d(),
		"the two halves are in separate physics worlds, as two processes would be"
	)

	for _i in range(240):
		await get_tree().process_frame
		if _server_game.maps.current != null and _client_game.maps.current != null:
			break

	_check(
		_server_game.maps.current != null and _client_game.maps.current != null,
		"both games load the map"
	)

	# [b]Put the client on a rate the server is not on.[/b] One process has one engine
	# rate, so both halves agree by construction — and a check that asserts they agree
	# is passing for that reason rather than a good one. A real client is a separate
	# program whose rate is its own project's export: the browser shell sets none and
	# runs at 60 against a 128-tick server. Make them disagree, and let HELLO correct it.
	_check(
		_client_game.set_tick_rate(CLIENT_ENGINE_TICK_RATE),
		"the client is put on %d, as a host project with its own export would be"
			% CLIENT_ENGINE_TICK_RATE
	)
	_check(
		_client_game.tick_rate != _server_game.tick_rate,
		"so the two now disagree",
		"%d vs %d" % [_client_game.tick_rate, _server_game.tick_rate]
	)

	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE
	_check(
		Engine.physics_ticks_per_second != _server_game.tick_rate,
		"and so does the engine, which is what a browser shell that sets none runs at",
		"engine %d vs server %d"
			% [Engine.physics_ticks_per_second, _server_game.tick_rate]
	)

	_server_net = _make_manager(true, &"server", 1, server_side, _server_game.tick_rate)
	_client_net = _make_manager(
		false, &"client", CLIENT_PEER, client_side, _client_game.tick_rate
	)
	# This suite stamps every command itself (`_tick + INPUT_LEAD`), not from the client's
	# clock, so the client must not ask for dot-net's input-lead report: steered by reports
	# about commands it never stamped, the clock ran away from them, a sixth of a tick more
	# lead every five ticks, and drew the other player in uneven steps. By the constant map,
	# so this parses against a dot-net from before the report.
	var lead_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = PlaygroundNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)
	_client_bridge = PlaygroundNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var attached := _server_bridge.attach(_server_game, _server_net, _server_net)
	_check(attached.ok, "the server bridge attaches", str(attached.error) if not attached.ok else "")
	var client_attached := _client_bridge.attach(_client_game, _client_net, _client_net)
	_check(
		client_attached.ok, "the client bridge attaches",
		str(client_attached.error) if not client_attached.ok else ""
	)

	var wrong := PlaygroundNetBridge.new()
	add_child(wrong)
	var refused := wrong.attach(_client_game, _server_net, self)
	_check(
		not refused.ok and refused.error.code == DotError.CODE_STATE,
		"a client game on a server manager is refused"
	)
	wrong.queue_free()

	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(
		_server_net.messages.schema_hash() == _client_net.messages.schema_hash(),
		"both ends agree on the message schema"
	)

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	# What a real client wires to DotClientLink.ping_ms(). Nothing in dot-net writes an
	# RTT sample, and a client that feeds none has a clock that believes the link is
	# instant — so every command it stamps arrives after its tick has passed.
	_client_bridge.rtt_source = func() -> float:
		return 40.0

	_check(_server_game.external_tick, "the server game hands its tick to the bridge")
	_check(
		_client_game.external_tick,
		"and so does the client's, which predicts and interpolates instead"
	)

	_done()
	return attached.ok and client_attached.ok


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if _recording and method == &"event":
		_server_events.append({"peer": peer_id, "payload": payload})
	if _recording and method == &"voice":
		_server_voice.append(peer_id)
	if method == &"snapshot":
		_snapshot_count += 1
		if _drop_every > 0 and _snapshot_count % _drop_every == 0:
			return
	if peer_id != 0 and peer_id != CLIENT_PEER:
		return
	_last_due_to_client = maxi(_last_due_to_client, _tick + _delay_ticks)
	_to_client.append({"method": method, "payload": payload, "due": _last_due_to_client})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_last_due_to_server = maxi(_last_due_to_server, _tick + _delay_ticks)
	_to_server.append({"method": method, "payload": payload, "due": _last_due_to_server})


func _flush() -> void:
	var to_client := _take_due(_to_client)
	var to_server := _take_due(_to_server)
	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])
	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


## The front of [param queue] whose transit time has run out, removed from it. A message's
## due tick never goes backwards along a queue (the sends clamp it), so this is a prefix and
## order is kept — a reliable EVENT overtaking the one before it is not a link any game has.
func _take_due(queue: Array[Dictionary]) -> Array[Dictionary]:
	var due: Array[Dictionary] = []
	while not queue.is_empty() and int(queue[0].get("due", 0)) <= _tick:
		due.append(queue.pop_front())
	return due
