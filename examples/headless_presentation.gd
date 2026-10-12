extends Node

const PlaygroundInventory := preload("../game/playground_inventory.gd")
const PlaygroundParty := preload("../game/playground_party.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundVote := preload("../game/playground_vote.gd")
const PlaygroundServices := preload("../game/playground_services.gd")
const PlaygroundSpawnables := preload("../game/playground_spawnables.gd")
const PlaygroundWorldGen := preload("../game/playground_worldgen.gd")
const PlaygroundHud := preload("../game/playground_hud.gd")
const PlaygroundClient := preload("../game/playground_client.gd")
const Playground := preload("../game/playground.gd")
const PlaygroundZee := preload("../game/playground_zee.gd")

## The five addons this game gained at once: settings, randomness, audio, effects and a
## console — plus the generated map, the carried inventory, and the party.
##
## [codeblock]
## godot --headless --path . res://examples/headless_presentation.tscn
## [/codeblock]
##
## [b]This is the only game in the family that holds all eight[/b], and the checks worth
## having are the ones about them meeting: one seed behind the map and the audio, one list
## behind the spawn menu and the backpack, and a generated map that is refused rather than
## shipped when nobody could cross it.
##
## Exits non-zero on any failure.

const CHECKS := 126

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

## The player's own settings directory as it was before this run: every file's name,
## modification time and digest. Checked at the end; see
## [method PlaygroundPresentation.use_scratch_settings].
var _player_files_were: String = ""


func _ready() -> void:
	# Before anything builds a presentation layer: the Escape menu section drags the volume
	# to 0.15 and that used to land in this machine's real `user://playground_settings`, so
	# the next real session started nearly silent. Everything goes to a scratch directory
	# emptied first, never the player's.
	_player_files_were = _player_files_stamp()
	var _scratch := PlaygroundPresentation.use_scratch_settings("headless_presentation")
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-playground: the presentation layer")

	_test_one_seed()
	_test_generated_map_is_walkable()
	_test_generation_refuses_rather_than_ships()
	_test_the_backpack_is_the_prop_catalogue()
	_test_carrying_is_a_refusal()
	_test_sounds_and_effects()
	_test_effects_draw()
	_test_console()
	_test_party_does_not_migrate()
	await _test_party_over_http()
	await _test_escape_menu()
	_test_chat_box()
	await _test_glance_pieces()

	_test_every_sound_has_a_voice()
	_test_the_vote_is_heard()

	# A settings manager writes on a debounce, and a freed one writes in `_exit_tree`:
	# the Escape menu section's presentation is queued for freeing and only reaches the
	# disk at the end of this frame. Without these the check below looked before the
	# write and passed on the code that wrote the player's file.
	await get_tree().process_frame
	await get_tree().process_frame
	print("")
	_check(
		_player_files_stamp() == _player_files_were,
		"the player's own settings files were not touched",
		PlaygroundPresentation.PLAYER_SETTINGS
	)
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  %s" % f)
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


## Every file in the player's own settings directory, as name, modification time and MD5,
## or "" when there is no directory. A digest as well as a time, because a write within
## the same second as the stamp leaves the time where it was.
static func _player_files_stamp() -> String:
	var dir := ProjectSettings.globalize_path(PlaygroundPresentation.PLAYER_SETTINGS)
	if not DirAccess.dir_exists_absolute(dir):
		return ""
	var lines := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		var path := dir.path_join(f)
		lines.append("%s %d %s" % [f, FileAccess.get_modified_time(path), FileAccess.get_md5(path)])
	return "\n".join(lines)


func _make() -> PlaygroundPresentation:
	var p := PlaygroundPresentation.new()
	p.name = "P%d" % _entered
	add_child(p)
	p.setup()
	# The client builds the console after its menu; there is no menu here.
	p.build_console()
	p.settings.local_store = DotSettingsStoreMemory.new()
	p.settings.load_now()
	p.apply_all()
	return p


# --- 1 ----------------------------------------------------------------------

func _test_one_seed() -> void:
	_section("One seed behind the map, the props and the noises")

	var p := _make()
	_check(p.rng != null, "there is a randomness manager")
	_check(p.rng.current_seed() != 0, "with a seed, picked and announced")
	_check(
		DotRegistry.has(DotRandomManager.SERVICE),
		"published, which is how a generated map finds it without naming the addon"
	)

	# The property that makes one seed usable by four things: two named streams never
	# disturb each other, so adding a fourth consumer cannot change the map.
	var map_a := p.rng.stream(&"map")
	var audio_a := p.rng.stream(&"audio")
	var expected: Array[float] = []
	for _i in range(4):
		expected.append(map_a.unit_at(_i))
	for _i in range(500):
		audio_a.next()
	var same := true
	for i in range(4):
		if not is_equal_approx(map_a.unit_at(i), expected[i]):
			same = false
	_check(same, "500 draws for audio leave the map's stream exactly where it was")

	_check(
		p.rng.seed_for(&"map") != p.rng.seed_for(&"waves"),
		"and two subsystems derive different seeds from the one number"
	)
	_check(
		p.audio.roll_source != null,
		"the audio takes its variation from the session's seed, so two people watching "
		+ "the same sandbox hear the same thing"
	)

	p.queue_free()
	_done()


# --- 2 ----------------------------------------------------------------------

func _test_generated_map_is_walkable() -> void:
	_section("A generated sandbox nobody could cross is not shipped")

	var res := PlaygroundWorldGen.generate(4242)
	_check(res.ok, "a sandbox generates")
	if not res.ok:
		_done()
		return

	var doc := res.value as DotProcGenDoc
	_check(doc.rooms.size() >= 5, "with rooms in it (%d)" % doc.rooms.size())
	_check(
		doc.links.size() > doc.rooms.size() - 1,
		"and more corridors than a spanning tree, so it has loops rather than being a "
		+ "sequence (%d links for %d rooms)" % [doc.links.size(), doc.rooms.size()]
	)

	var spawns := doc.markers_of(&"spawn")
	_check(spawns.size() == 1, "there is a spawn")
	var spawn: Vector2i = spawns[0]["cell"]

	# The check that matters, and the one every other kind passes without: everything
	# placed can actually be walked to.
	var reached := doc.reachable_from(spawn)
	var reachable := {}
	for idx in reached:
		reachable[idx] = true

	var stranded := 0
	for m in doc.markers:
		var cell: Vector2i = m.get("cell", Vector2i.ZERO)
		if not reachable.has(cell.y * doc.width + cell.x):
			stranded += 1
	_check(stranded == 0, "and every prop point can be reached from it")

	# Two runs of one seed are one map, which is what lets a server and a client agree
	# without sending a map.
	var again := PlaygroundWorldGen.generate(4242)
	_check(
		(again.value as DotProcGenDoc).fingerprint() == doc.fingerprint(),
		"two runs of one seed produce the same map, to the byte"
	)
	var other := PlaygroundWorldGen.generate(4243)
	_check(
		(other.value as DotProcGenDoc).fingerprint() != doc.fingerprint(),
		"and a different seed a different one"
	)

	_done()


# --- 3 ----------------------------------------------------------------------

func _test_generation_refuses_rather_than_ships() -> void:
	_section("What a map that cannot be generated leaves behind")

	# Too small for the rooms the pipeline asks for. A generator that shipped this anyway
	# would produce one room and call it a sandbox.
	var tiny := PlaygroundWorldGen.pipeline(12, 12)
	tiny.max_attempts = 2
	var res := tiny.generate(1)
	_check(not res.ok, "a map too small to satisfy the pipeline fails rather than shipping")
	_check(
		res.error.message != "",
		"saying which step refused it, rather than producing something unplayable"
	)

	# And what the map does about it: a plate with walls, and a spawn on it. A partially
	# generated sandbox is a room with no way out, which is worse than an empty plate.
	var map := load("res://maps/pg_generated.gd").new() as Node3D
	add_child(map)
	map.call("configure", 4242, null)
	_check(
		map.get("document") != null,
		"a generated map that succeeded holds its document, for a console command"
	)
	var spawn: Vector3 = map.get("fallback_spawn")
	_check(spawn.y > 0.0, "and a spawn above the floor")
	# The lesson from the surf maps: a capsule that starts within a unit or two of a seam
	# is a coin toss whichever way the collision backend rounds.
	_check(spawn.y >= 1.0, "clear of the floor rather than resting exactly on it")
	_check(map.get_child_count() > 2, "with geometry under it")
	map.queue_free()
	_done()


# --- 4 ----------------------------------------------------------------------

func _test_the_backpack_is_the_prop_catalogue() -> void:
	_section("What you can carry is what this server can make")

	var props := PlaygroundSpawnables.catalogue()
	var items := PlaygroundInventory.build_catalogue(props)
	_check(items.validate().ok, "the item catalogue validates")

	# One list. A second table of what can be carried would go stale the first time
	# somebody added a prop, which is this tree's most repeated bug.
	_check(
		items.ids().size() == props.props.size(),
		"one item per prop (%d against %d)" % [items.ids().size(), props.props.size()]
	)

	var heavy: DotPropDef = null
	for d in props.props:
		if heavy == null or d.mass > heavy.mass:
			heavy = d
	var item := items.find(heavy.id)
	_check(item != null, "the heaviest prop has an item")
	_check(
		is_equal_approx(item.weight, maxf(heavy.mass, 1.0)),
		"whose weight is the prop's own mass, which until now exactly one thing read"
	)
	_check(
		item.kind == DotInvItem.Kind.UNIQUE,
		"and which does not stack, because every prop carries its own state once spawned"
	)

	_done()


# --- 5 ----------------------------------------------------------------------

func _test_carrying_is_a_refusal() -> void:
	_section("Buying holds something; spawning takes it out")

	var inv := PlaygroundInventory.new()
	inv.name = "Inventory"
	add_child(inv)
	var res := inv.setup(PlaygroundSpawnables.catalogue())
	_check(res.ok, "the inventory sets up")
	if not res.ok:
		_done()
		return

	var who := &"player_one"
	var id := inv.catalogue.ids()[0]

	# The whole feature: before this, the shop charged per spawn and nothing was ever
	# held, so "buy three crates" and "buy one crate three times" were the same thing.
	_check(
		not inv.take(who, id).ok,
		"taking something you are not carrying is refused"
	)
	_check(inv.give(who, id).ok, "buying puts one in the bag")
	_check(inv.carries(who, id) == 1, "and you are carrying it")
	_check(inv.take(who, id).ok, "spawning takes it out")
	_check(inv.carries(who, id) == 0, "leaving nothing")
	_check(not inv.take(who, id).ok, "and a second spawn is refused")

	# The grid and the weight are two different limits, and a refusal has to say which.
	var given := 0
	for _i in range(60):
		if inv.give(who, id).ok:
			given += 1
		else:
			break
	_check(given > 0, "a bag holds several")
	_check(given < 60, "and stops (%d), rather than being a list with no end" % given)

	var q := inv.query(who)
	_check(q.size() > 0, "and what is in it can be listed")
	_check(
		q.size() == inv.carries(who, id),
		"with the query agreeing with the count, because both read one document"
	)

	inv.queue_free()
	_done()


# --- 6 ----------------------------------------------------------------------

func _test_sounds_and_effects() -> void:
	_section("Somebody else's building, and the switch for it")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	p.audio.listener_position = Vector3.ZERO

	sink.forget()
	p.on_prop_spawned(Vector3(4, 0, 4), true)
	_check(sink.count_of(&"prop_spawn") == 1, "a prop you spawned makes a noise")

	sink.forget()
	for _i in range(10):
		p.on_prop_spawned(Vector3(4, 0, 4), true)
	_check(
		sink.count_of(&"prop_spawn") <= 3,
		"and ten in one tick make at most three (%d), because a dozen people emptying a "
		% sink.count_of(&"prop_spawn") + "spawn menu is a building site rather than a fault"
	)

	# The sandbox's own setting, and it is about somebody else's work rather than yours.
	p.settings.set_value(&"prop_sounds", false)
	sink.forget()
	p.on_prop_spawned(Vector3(4, 0, 4), false)
	_check(
		sink.count_of(&"prop_spawn") == 0,
		"somebody else's prop is silent for a player who turned that off"
	)
	# Past the cooldown the burst above used. A check that measures a sound while it is
	# being refused for a cooldown measures the cooldown, and reads as the setting being
	# broken in the other direction.
	OS.delay_msec(100)
	sink.forget()
	p.on_prop_spawned(Vector3(4, 0, 4), true)
	_check(
		sink.count_of(&"prop_spawn") == 1,
		"while your own still is, because it is the answer to something you just did"
	)

	sink.forget()
	p.on_refused()
	var refused := p.audio.catalogue.find(&"refused")
	var landed := p.audio.catalogue.find(&"prop_land")
	_check(sink.count_of(&"refused") == 1, "a refusal makes a noise")
	_check(
		refused.priority > landed.priority,
		"and outranks a crate hitting the floor, because it answers something you did"
	)

	p.settings.set_value(&"shake_scale", 0.0)
	p.on_tool_punt(Vector3.ZERO, true)
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(
		p.camera_shake() == Vector3.ZERO,
		"and a player who turned shake off gets exactly none of it"
	)

	p.queue_free()
	_done()


## [b]Every effect scene the catalogue names exists, and the effects actually spawn.[/b]
## Until 2026-09-27 `scenes/fx/` did not exist, dot-fx refused both scenes at DEBUG, and
## no check noticed because none asked whether anything was drawn.
func _test_effects_draw() -> void:
	_section("The effects this game names are drawn")

	var p := _make()
	var missing := p.fx.catalogue.missing_scenes()
	_check(missing.is_empty(), "every effect scene the catalogue names exists",
		", ".join(missing))

	# Looking at where the prop appears: dot-fx culls an effect behind the viewer.
	var at := Vector3(0, 1, -6)
	p.present(0.016, Vector3(0, 1.7, 0), Vector3.FORWARD)
	var drawn: Array[Node] = []
	p.fx.spawned.connect(func(id: StringName, node: Node, _why: StringName) -> void:
		if id == &"prop_spawn" and node != null:
			drawn.append(node)
	)
	p.on_prop_spawned(at, true)
	_check(drawn.size() == 1, "a prop you spawned puffs")
	_check(
		not drawn.is_empty() and (drawn[0] as Node3D).global_position.is_equal_approx(at),
		"where the prop appeared"
	)

	var eye := Vector3(0, 1.7, 0)
	var aim := Vector3(0, 0, -1)
	var held := Vector3(2, 1, -8)
	var beam := p.on_tool_beam(eye, aim, held)
	_check(beam != null, "the physics gun draws a beam")
	var start := beam.global_position if beam != null else eye
	_check(
		(start - eye).dot(aim) > 0.2 and start.y < eye.y,
		"starting in front of and below the eye, not in it",
		str(start)
	)
	var tip := beam.global_transform * Vector3(0, 0, -1) if beam != null else Vector3.ZERO
	_check(
		tip.distance_to(held) < 0.001,
		"and ending on what it holds",
		"%s against %s" % [tip, held]
	)
	var moved := Vector3(-3, 2, -5)
	var again := p.on_tool_beam(eye, aim, moved)
	_check(
		again == beam and (again.global_transform * Vector3(0, 0, -1)).distance_to(moved) < 0.001,
		"a held prop that moves moves the same beam, rather than stacking another"
	)

	# Past its 100 ms ceiling dot-fx retires it; the next frame's call draws a new one.
	OS.delay_msec(130)
	p.present(0.016, eye, aim)
	var fresh := p.on_tool_beam(eye, aim, held)
	_check(
		fresh != null and fresh != beam and not fresh.is_queued_for_deletion(),
		"and a beam past its ceiling is replaced in the same frame, so a hold never flickers"
	)

	p.queue_free()
	_done()


func _test_the_vote_is_heard() -> void:
	_section("The map vote is heard: every cue its rules name is a sound here")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	var rules := PlaygroundVote.vote_rules()

	var named: Array[StringName] = []
	for id in [
		rules.cue_vote_start, rules.cue_vote_end, rules.cue_warning,
		rules.cue_runoff_warning, rules.countdown_cue_id(3),
	]:
		named.append(StringName(id))

	var missing: Array[String] = []
	for id in named:
		if id == &"" or not p.audio.catalogue.has(id):
			missing.append(String(id))
	_check(
		missing.is_empty(),
		"the rules name a cue for every moment, and each is in the catalogue (missing: %s)"
			% str(missing)
	)

	sink.forget()
	_check(p.on_vote_cue(StringName(rules.cue_vote_start)) != 0, "a ballot opening plays")
	p.on_vote_cue(&"")
	p.on_vote_cue(&"not_in_this_build")
	_check(
		sink.count_of(StringName(rules.cue_vote_start)) == 1
			and sink.count_of(&"not_in_this_build") == 0,
		"once, and an empty or unknown cue is silence"
	)

	p.queue_free()
	_done()


# --- 7 ----------------------------------------------------------------------

func _test_console() -> void:
	_section("The console, and the command this game needs most")

	var p := _make()
	_check(p.console != null and p.console_panel != null, "there is a console and a panel")
	_check(
		p.console.all_names().has("seed"),
		"with `seed` in it -- a generated map nobody can name the seed of is a map "
		+ "nobody can share"
	)

	var missing := PackedStringArray()
	for key in PlaygroundPresentation.schema().keys():
		if not p.console.all_names().has(String(key)):
			missing.append(String(key))
	_check(missing.is_empty(), "every setting is reachable (%s)" % ", ".join(missing))

	var res := p.console.submit("seed")
	_check(res.ok, "asking for the seed works")

	p.console.submit("fx_quality 0")
	_check(p.fx.config.quality == 0, "a console line reaches the effects config")

	p.console.submit("rcon_password hunter2")
	_check(
		not p.console.buffer.to_text().contains("hunter2"),
		"a credential never reaches the scrollback"
	)

	p.queue_free()
	_done()


# --- 8 ----------------------------------------------------------------------

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


# --- 8b ---------------------------------------------------------------------

## A stand-in rendezvous: the four routes `DotP2PSignallerHttp` speaks, on a real socket,
## answering each request [member delay] frames after it arrives.
##
## [b]The delay is the point.[/b] Every other party check here uses the loopback
## signaller, which answers inside the call — and a coroutine that never suspends is
## indistinguishable from a function, so a caller that forgot `await` passes against it.
## A rendezvous that answers frames later is the shape the real one has.
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

		for c in _open.duplicate():
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

			var answer := _answer(str(c["route"]), c["body"] as Dictionary)
			var status := "200 OK" if refuse == 0 else "%d Refused" % refuse
			var payload := JSON.stringify(answer).to_utf8_buffer()
			var head := "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, payload.size()]
			peer.put_data(head.to_utf8_buffer())
			peer.put_data(payload)
			peer.disconnect_from_host()
			_open.erase(c)

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


## `[p2p-await-games]`: a party over the HTTP rendezvous, host and join, each awaited
## end to end — through `PlaygroundParty`, `DotP2PSession` and `DotP2PSignallerHttp` to a
## socket and back.
##
## [b]What "awaited" is asserted as.[/b] The answer the caller gets back is the one the
## stub sent, and it arrives at least [member RendezvousStub.delay] frames after the call:
## a link in the chain that dropped its `await` hands its caller null (GDScript refuses a
## coroutine called as a function at runtime) or returns before the stub has answered,
## and either fails here. Armed 2026-09-25 by taking the `await` off `DotP2PSession.join`'s
## call to its signaller (typed as the base, so nothing at compile time can see it): a
## runtime "async function without await", join back in 0 frames, three checks fire. The
## same edit in `PlaygroundParty` is a parse error instead — the compiler guards that link.
func _test_party_over_http() -> void:
	_section("A party that meets over HTTP waits for the answer")

	var stub := RendezvousStub.new()
	stub.name = "Rendezvous"
	add_child(stub)
	var listening := stub.start()
	_check(listening, "a stand-in rendezvous listens on a local port", str(stub.port))

	if not listening:
		stub.queue_free()
		_done()
		return

	var url := "http://127.0.0.1:%d/p2p" % stub.port
	var ada := PlaygroundParty.new()
	ada.name = "PartyAda"
	ada.signalling_url = url
	add_child(ada)
	var bob := PlaygroundParty.new()
	bob.name = "PartyBob"
	bob.signalling_url = url
	add_child(bob)

	_check(
		ada.setup().ok and bob.setup().ok
			and ada.session.signaller is DotP2PSignallerHttp
			and bob.session.signaller is DotP2PSignallerHttp,
		"two parties set up with a URL, and both meet over HTTP rather than the loopback"
	)

	var opened: Array[String] = []
	ada.open.connect(func(code: String) -> void: opened.append(code))

	var before := Engine.get_process_frames()
	var hosted: DotResult = await ada.host("Ada")
	var took := Engine.get_process_frames() - before
	var code := str(hosted.value) if hosted != null and hosted.ok else ""

	_check(
		hosted != null and hosted.ok and DotP2PLobby.is_code_shaped(code, ada.session.config.code_length),
		"host() hands back a join code",
		str(hosted.error.message) if hosted != null and not hosted.ok else "null"
	)
	_check(took >= stub.delay,
		"only once the rendezvous has answered: %d frames, the stub waits %d" % [took, stub.delay])
	_check(
		stub.seen.size() >= 1 and stub.seen[0]["route"] == "host"
			and str((stub.seen[0]["body"] as Dictionary).get("code", "")) == code
			and str(((stub.seen[0]["body"] as Dictionary).get("info", {}) as Dictionary).get("name", "")) == "Ada",
		"and it is the code the rendezvous was told, under the host's name",
		str(stub.seen)
	)
	_check(ada.active() and ada.session.is_host() and opened == [code],
		"the party is open, hosted, and says so once",
		"state %s, opened %s" % [ada.session.state(), str(opened)])

	before = Engine.get_process_frames()
	var joined: DotResult = await bob.join(code.to_lower(), "Bob")
	took = Engine.get_process_frames() - before

	_check(joined != null and joined.ok and took >= stub.delay,
		"join() waits for the rendezvous too (%d frames) and succeeds" % took,
		str(joined.error.message) if joined != null and not joined.ok else "null")
	_check(
		stub.seen.size() >= 2 and stub.seen[1]["route"] == "join"
			and str((stub.seen[1]["body"] as Dictionary).get("code", "")) == code,
		"under the code as the host has it, not as it was typed",
		str(stub.seen)
	)
	_check(
		bob.session.lobby.has(ada.session.local_id) and not bob.session.is_host(),
		"and the joiner learns who is already there from the answer, and does not elect itself",
		str(bob.session.lobby.member_ids())
	)

	# A refusal arrives as a failure the caller can read, not as null and not as success.
	bob.leave()
	var carol := PlaygroundParty.new()
	carol.name = "PartyCarol"
	carol.signalling_url = url
	add_child(carol)
	var _set := carol.setup()
	stub.refuse = 403
	var refused: DotResult = await carol.host("Carol")
	_check(refused != null and not refused.ok and not carol.active(),
		"and a rendezvous that refuses leaves the party closed with a reason",
		"null" if refused == null else ("ok" if refused.ok else refused.error.message))

	ada.leave()
	for node: Node in [ada, bob, carol, stub]:
		node.queue_free()
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


## Every chat line is drawn once: in the box when there is one, on the notice line only
## when there is not. Both drew it, so a map vote's ballot was printed at the notice line
## and again in the box, beside the drawn ballot panel. The client is never added to the
## tree (its `_ready` builds the netcode); only the handler and the three fields it reads
## are used.
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


## The ammunition counter, the hit marker and the damage numbers are dot-ui's glance pieces,
## handed this game's numbers, out of the chat box's way and under a ballot's.
func _test_glance_pieces() -> void:
	_section("What is in hand, and what a shot did")

	var p := _make()
	var hud := PlaygroundHud.new()
	hud.name = "GlanceHud"
	add_child(hud)

	# A real rig, holding the first zee weapon with a magazine, on a stand-in body.
	var body := Node3D.new()
	body.name = "Holder"
	add_child(body)
	var rig: ZeeWeaponRig = null
	for def in PlaygroundZee.defs():
		var weapon := PlaygroundZee.catalogue().get_def(PlaygroundZee.zee_id(def)) if PlaygroundZee.is_zee(def) else null
		if weapon != null and weapon.magazine > 0 and weapon.ammo_type != &"":
			rig = PlaygroundZee.arm(body, def, ZeeWeaponRig.Role.SERVER, true, 64, 0)
			break
	_check(rig != null, "a zee weapon is armed for the counter to read")
	if rig == null:
		hud.queue_free()
		body.queue_free()
		_done()
		return

	var slot := rig.arsenal.current()
	slot.magazine = 3
	hud.show_weapon(rig)
	var reserve := rig.arsenal.ammo().count(slot.def.ammo_type)
	_check(
		hud.ammo.count_text() == "3 | %d" % reserve and hud.ammo.low,
		"the counter shows the magazine and the reserve, low at a quarter",
		"'%s' low=%s for %d of %d" % [hud.ammo.count_text(), str(hud.ammo.low), slot.magazine, slot.def.magazine]
	)
	hud.show_weapon(null)
	_check(hud.ammo.count_text() == "" and not hud.ammo.footprint().has_area(),
		"and nothing at all with a toy or empty hands", hud.ammo.count_text())
	hud.show_weapon(rig)

	hud.confirm_hit(Playground.hit_victim_id(DotEntity.KIND_NPC, 41), 26.0, Vector3(0, 1, -5), true, false)
	_check(
		hud.hit_marker.alpha() > 0.0 and hud.hit_marker.kill and Array(hud.damage_numbers.texts()).has("26"),
		"a confirmed hit flashes the marker and puts the number up",
		"%s %s" % [str(hud.hit_marker.describe()), str(hud.damage_numbers.texts())]
	)

	# Out of the chat box's way: both are bottom-anchored, the box from the left and the
	# counter from the right, so the test is the narrowest frame a client shell draws.
	await get_tree().process_frame
	var window := p.chat_window
	var plate := hud.ammo.get_global_transform() * hud.ammo.footprint()
	var box := window.get_global_rect()
	_check(not plate.intersects(box), "the counter does not meet the chat box",
		"counter %s, box %s" % [str(plate), str(box)])
	var narrow := 854.0
	var plate_w := hud.ammo.footprint().size.x
	_check(
		window.margin_left + window.width + 8.0 <= narrow + hud.ammo.offset_right - plate_w,
		"nor at 854 wide, the smallest frame",
		"box to %.0f, counter from %.0f" % [window.margin_left + window.width, narrow + hud.ammo.offset_right - plate_w]
	)

	# A ballot where a shell draws one, top right, leaves it alone; one over it dims it.
	var ballot := DotBallotPanel.new()
	ballot.name = "GlanceBallot"
	ballot.panel_width = 360.0
	add_child(ballot)
	ballot.show_state({"open": true, "title": "Next map", "command": "nominate", "seconds": 30,
		"options": [{"id": "a", "label": "Lobby", "votes": 0}, {"id": "b", "label": "Canyon", "votes": 0}],
		"voters": {}})
	var view := get_viewport().get_visible_rect().size
	ballot.position = Vector2(view.x - 360.0 - 24.0, 120.0)
	await get_tree().process_frame
	hud.ammo.refresh_cover()
	_check(not hud.ammo.covered, "a ballot top right leaves the counter alone",
		"ballot %s, counter %s" % [str(ballot.get_global_rect()), str(plate)])
	ballot.position = Vector2(view.x - 360.0 - 24.0, view.y - 140.0)
	await get_tree().process_frame
	hud.ammo.refresh_cover()
	_check(hud.ammo.covered and hud.ammo.self_modulate.a < 1.0, "and one over it dims it",
		"ballot %s" % str(ballot.get_global_rect()))

	# The camera motion settings reach the player they are bound to, live.
	var stub := GDScript.new()
	stub.source_code = "extends Node\nvar got: Array = []\nfunc set_camera_motion_scales(a: float, b: float, c: float) -> void:\n\tgot = [a, b, c]\n"
	var _compiled := stub.reload()
	var holder := Node.new()
	holder.set_script(stub)
	add_child(holder)
	p.bind_camera_motion(holder)
	var bound: Array = holder.get(&"got")
	p.settings.set_value(&"camera_strafe_roll", 0.0)
	p.settings.set_value(&"camera_speed_fov", 1.5)
	var moved: Array = holder.get(&"got")
	_check(bound == [1.0, 1.0, 1.0] and moved == [1.0, 0.0, 1.5],
		"the camera motion settings reach the camera: bound at the picks, then each slider on its own",
		"%s then %s" % [str(bound), str(moved)])
	_check(p.settings.schema.find(&"camera_landing_dip") != null
		and p.settings.schema.find(&"camera_landing_dip").scope == DotSettingsDef.Scope.ACCOUNT,
		"and they belong to the person, not the machine")
	holder.queue_free()

	# A pack naming these classes does not parse on a shell whose dot-ui predates them, so the
	# requires.json dot-ci derives must ask for dot-ui 4, and nothing may lower it.
	var asks := DotAddonApi.derive()
	_check(
		int(asks.get("dot_ui", 0)) >= 4 and not FileAccess.file_exists("res://" + DotAddonApi.FLOOR_FILE),
		"the pack asks a shell for dot-ui level 4, the glance pieces",
		str(asks.get("dot_ui"))
	)

	ballot.queue_free()
	hud.queue_free()
	body.queue_free()
	_done()


# --- Harness ---------------------------------------------------------------

func _test_escape_menu() -> void:
	_section("Escape reaches a setting, which it could not before")

	var p := PlaygroundPresentation.new()
	p.name = "MenuP"
	add_child(p)
	if not _check(p.setup().ok, "a presentation layer to read the settings from"):
		_done()
		return
	# This section writes through the real file store (the menu's Apply is what it is
	# about), so the store must be the scratch one `_ready` chose, not the player's.
	_check(
		PlaygroundPresentation.settings_directory.begins_with("user://scratch/"),
		"its settings are a scratch document, not the player's",
		PlaygroundPresentation.settings_directory
	)

	var stack := DotScreenStack.new()
	stack.name = "Stack"
	stack.register_service = false
	stack.manage_mouse = false
	add_child(stack)
	stack.setup()

	var pause := DotPauseScreen.new()
	pause.name = "Pause"
	_check(
		pause.build(PackedStringArray(["Resume", "Settings", "Servers", "Leave"])).ok,
		"a pause menu builds"
	)
	stack.register(pause)

	var screen := DotSettingsScreen.new()
	screen.name = "Settings"
	_check(screen.build(p.settings).ok, "and a settings screen onto the real settings")
	stack.register(screen)

	stack.push(&"pause")
	await get_tree().process_frame
	await get_tree().process_frame

	# THAT THE PUSH LANDED, which is the check this section shipped without.
	#
	# `DotScreen`'s default id is the NODE NAME, so a screen called `Pause` registered as
	# `&"Pause"` and `push(&"pause")` answered "no such screen" -- reported, not fatal, so
	# this game's pause menu never opened at all. Every check below passed anyway: a
	# REGISTERED screen is sized and focusable whether or not it is on screen. A rendered
	# frame in dot-ui is what found it, and this is the assertion that would have.
	_check(stack.top_id() == &"pause", "the menu OPENS, rather than registering under its node name")
	_check(pause.visible, "so it is actually on screen")

	# The one thing an assertion reaches about a Control, and this family has shipped a
	# 0 x 0 one twice.
	_check(pause.size.x > 0.0 and pause.size.y > 0.0, "the menu has a size")
	_check(
		pause.get_node_or_null(pause.initial_focus) != null,
		"and something focused, or it cannot be used with a gamepad at all"
	)
	_check(pause.button(&"settings") != null, "with a way to reach the settings")

	stack.push(&"settings")
	await get_tree().process_frame

	# The check this section exists for: `to_config()` is a SNAPSHOT and
	# `absorb_config()` is the way back. A screen that called only the panel's apply would
	# report success and change nothing, for ever, and every check above passes either way.
	p.settings.set_value(&"master_volume", 0.9)
	screen._on_push()
	screen.panel._edited("master_volume", 0.15)
	screen.apply()
	_check(
		is_equal_approx(p.settings.get_float(&"master_volume"), 0.15),
		"Apply reaches the settings manager rather than the snapshot it was bound to"
	)
	_check(
		is_equal_approx(p.audio.mixer.master, 0.15),
		"and carries on to the mixer, which is what a player actually hears"
	)

	stack.clear()
	stack.queue_free()
	p.queue_free()

	# A document saved when Clear checkpoints was on B: it follows to G, and a key the player
	# chose stays where they put it.
	var back := PlaygroundPresentation.new()
	back.name = "Returning"
	add_child(back)
	back.setup()
	var old_doc := DotSettingsStoreMemory.new()
	var _saved_old := old_doc.save_document(back.settings.app_namespace, back.settings.profile, {"version": 1, "values": {
		"bind_checkpoint_clear": "B", "bind_style": "J",
	}})
	back.settings.local_store = old_doc
	var _loaded := back.settings.load_now()
	back.apply_all()
	_check(back.settings.get_string(&"bind_checkpoint_clear") == "G",
		"an old settings file with Clear checkpoints on B: it moves to G", back.settings.get_string(&"bind_checkpoint_clear"))
	_check(back.settings.get_string(&"bind_style") == "J", "and a key the player chose is kept", back.settings.get_string(&"bind_style"))
	back.queue_free()
	_done()


func _test_every_sound_has_a_voice() -> void:
	# This game shipped a complete catalogue pointing at files nobody has produced, and
	# was therefore silent while every check about its audio passed. The two directions
	# below are the ones that go wrong without erroring: an id with no recipe is one sound
	# that stays silent for ever, and a recipe naming an id the catalogue does not have is
	# a decision that reaches nothing. Neither is visible from any assertion about the
	# catalogue on its own -- and a headless run cannot hear the result, so this is as
	# close as an assertion gets. game-arena/tools/audio_probe.sh is the other half.
	_section("Every sound this game declares has a noise to make")

	var cat := PlaygroundPresentation.sound_catalogue()
	var recipes := PlaygroundPresentation.sound_recipes()

	var uncovered: Array[String] = []
	for id in cat.ids():
		# dot-audio's stock footsteps and beds are files the addon ships: no stand-in needed.
		if not recipes.has(id) and not DotAudioStock.ids().has(id):
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


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
	return condition
