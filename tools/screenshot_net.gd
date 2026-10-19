extends Node

const Playground := preload("../game/playground.gd")
const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundNetBridge := preload("../game/net/playground_net_bridge.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")
const PlaygroundPlayerNet := preload("../game/net/playground_player_net.gd")

## Renders a CONNECTED client looking at another player, and measures how smoothly that
## player moves on screen. The view `tools/screenshot_views.sh` cannot give: offline there is
## nobody else, and the bugs this exists for were all in what a client draws of a player it
## is only told about.
##
## [codeblock]
## tools/screenshot_net.sh                # four consecutive frames, screenshots/net_0..3.png
## tools/screenshot_net.sh --no-interp    # the same with the client's interpolation off
## tools/screenshot_net.sh --walk         # THIS client strafes its own player: is it predicted?
## tools/screenshot_net.sh --downed       # the other player is down (the server's flag): crawling?
## tools/screenshot_net.sh --died         # ... and then bleeds out: the ragdoll starts from the crawl
## [/codeblock]
##
## A server and a client in one process, joined by the loopback `headless_net` uses: the
## server's world is in a SubViewport with its own physics space that is never drawn, and
## the client's is the one on screen. Every frame calls `PlaygroundClient.present_frame`,
## the function the real client's `_process` calls.
##
## [b]The probe.[/b] Once a rendered frame, the other player's drawn position is divided by
## that frame's delta: the apparent speed. Running flat out in a straight line it should be
## the same every frame, and the share of frames far from the typical one is the judder.
## `--no-interp` shows what that share is when it is wrong, because a number with nothing
## to compare it to proves nothing.
##
## [b]`--walk` is the other probe: this client's OWN player.[/b] It stands for three quarters
## of a second, strafes east for 90 ticks, stands, strafes back, through the same `client_tick` the
## real client calls, and reports what a player feels: how many ticks after a key is pressed
## the player's node moves (0 is the tick it was pressed in), the predictor's corrections,
## and the eye's apparent speed per rendered frame while the server has them at full speed.
## Until 2026-09-25 the client predicted nobody — every mirror was owner 0 — and this is where
## that shows as a number: 3 ticks from key to motion, and an eye that moved only on the
## frames a snapshot landed. Snapshots at 32 a second in this mode, as `PlaygroundClient`
## asks for; the remote-player probe keeps the 20 its figures were taken at.
##
## xvfb-run, never --headless: headless gives a null renderer and saves a frame of nothing.

const SESSION := 7
const CLIENT_PEER := 2
const OTHER_SESSION := 8
const OTHER_PEER := 3
const INPUT_LEAD := 2

## A screen faster than the tick; the interpolation fraction only matters between ticks.
const RENDER_FPS := 144

## How far in front of the watcher the other player crosses, and how far either side.
const AHEAD := 7.0
const SWING := 5.0

var _server_game: Playground = null
var _client_game: Playground = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: PlaygroundNetBridge = null
var _client_bridge: PlaygroundNetBridge = null
var _to_client: Array = []
var _to_server: Array = []
var _tick := 0

var _camera: Camera3D = null
var _interp := true
var _placed := false
var _heading := -90.0
var _settle := 0
var _speeds: Array[float] = []
var _last_drawn := Vector3.INF
var _home := Vector3.ZERO

## `--walk`: see the class note. Ticks into the cycle, the tick and place of the current
## press, and what was measured.
var _walk := false
var _walk_tick := 0
var _pressed_at := -1
var _pressed_from := Vector3.ZERO
var _pressed_sign := 1.0
var _latencies: Array[int] = []
var _eye_speeds: Array[float] = []
var _last_eye := Vector3.INF
var _walk_ticks := 0
var _corrections_from := -1

## Long enough to come to rest: friction takes most of a second off a full-speed strafe, and
## a press measured while the last one is still sliding is measured against the slide.
const WALK_IDLE := 96
const WALK_RUN := 90


## `--zee=<id>`: the other player is handed that zee weapon and holds fire, so the frames
## show the gun a client draws in somebody else's hands (`PlaygroundZee.show_held`).
var _zee: StringName = &""

## `--hold`: the other player carries a crate on the physics gun, holding fire on the SERVER's
## tools as a connected player would, so the frames show the beam a client draws for somebody
## else from what `Kind.HELD` told it (`PlaygroundClient.present_beams`).
var _hold := false
## The other player stands in front, downed on the server, instead of running.
var _downed := false
## `--died`: with `--downed`, the server's downs layer then reports the bleed-out. The client
## does what `PlaygroundClient.fall` does (the death rides `Kind.COMBAT`): a ragdoll copied
## from the crawling figure. Frames are saved the instant it spawns and again once it settles.
var _died := false
var _ragdolls: DotPlayerRagdolls = null
var _presentation: PlaygroundPresentation = null


func _ready() -> void:
	# Settings to a scratch directory emptied first (see
	# `PlaygroundPresentation.use_scratch_settings`): a render must not save into a player's
	# file, nor draw from whatever the player last saved there.
	var _scratch := PlaygroundPresentation.use_scratch_settings("screenshot_net")
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.max_fps = RENDER_FPS
	_run.call_deferred()


func _run() -> void:
	var seconds := 6.0
	var out := "res://screenshots/net.png"

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seconds="):
			seconds = float(arg.substr(10))
		elif arg.begins_with("--out="):
			out = arg.substr(6)
		elif arg == "--no-interp":
			_interp = false
		elif arg == "--walk":
			_walk = true
		elif arg.begins_with("--zee="):
			_zee = StringName("zee_" + arg.substr(6))
		elif arg == "--hold":
			_hold = true
		elif arg == "--downed":
			_downed = true
		elif arg == "--died":
			_downed = true
			_died = true

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots"))
	await _build()

	var elapsed := 0.0
	while elapsed < seconds:
		elapsed += get_process_delta_time()
		await get_tree().process_frame

	var base := out.get_basename()
	if _died:
		await _bleed_out(base)
	for i in range(4):
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var path := "%s_%d.png" % [base, i]
		image.save_png(ProjectSettings.globalize_path(path))
		print("saved %s" % path)

	_report()
	if _walk:
		_report_walk()
	# Stalls and extrapolations are frames the interpolator had nothing newer than its render
	# time to blend toward and guessed instead, out of `samples`. Near zero on this loopback.
	# Until 2026-09-24 it was most frames — 1,684 stalls in six seconds — because dot-net
	# subtracted a buffer counted in SNAPSHOTS from a tick number (dot-net's docs/history.md, #18).
	print("interpolator: ", _client_net.interpolator.describe())
	get_tree().quit()


## The downed player bleeds out: the client copies a ragdoll from the figure it draws (the
## crawl pose), exactly `PlaygroundClient.fall`. Saves `<base>_died_0` on the spawn frame and
## `_died_1`..`_3` as it falls.
func _bleed_out(base: String) -> void:
	var theirs: PlaygroundPlayer = _client_game.players.get(&"u%d" % OTHER_SESSION)
	var body := theirs.character.body() if theirs != null and theirs.character != null else null
	if body == null:
		print("died: no body drawn")
		return
	_ragdolls = DotPlayerRagdolls.new()
	_ragdolls.name = "Ragdolls"
	_ragdolls.rules = _client_game.ragdoll_rules
	add_child(_ragdolls)
	var made := _ragdolls.spawn(body, DotPlayerDeath.new(), Vector3.ZERO)
	print("died: ragdoll ", "spawned" if made != null else "NOT spawned")
	for i in range(4):
		for _f in range(1 if i == 0 else 20):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := "%s_died_%d.png" % [base, i]
		get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
		print("saved %s" % path)


func _build() -> void:
	var server_view := SubViewport.new()
	server_view.name = "ServerView"
	server_view.own_world_3d = true
	server_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(server_view)

	var server_side := Node.new()
	server_side.name = "ServerSide"
	server_view.add_child(server_side)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)

	_server_game = _make_game(true, &"server", server_side)
	_client_game = _make_game(false, &"client", client_side)

	for _i in range(240):
		await get_tree().process_frame
		if _server_game.maps.current != null and _client_game.maps.current != null:
			break

	_server_net = _make_manager(true, &"server", 1, server_side, _server_game.tick_rate)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, _client_game.tick_rate)
	# This tool stamps every command itself (`_tick + INPUT_LEAD`), not from the client's
	# clock, so the client must not ask for dot-net's input-lead report: steered by reports
	# about commands it never stamped, the clock runs away from them and the other player is
	# drawn in uneven steps, which is the thing this tool is for looking at (headless_net,
	# c903760). By the constant map, so this parses against a dot-net from before the report.
	var lead_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = PlaygroundNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)
	_client_bridge = PlaygroundNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var _a := _server_bridge.attach(_server_game, _server_net, _server_net)
	var _b := _client_bridge.attach(_client_game, _client_net, _client_net)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_server_bridge.link.loopback = func(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
		if peer_id == 0 or peer_id == CLIENT_PEER:
			_to_client.append([method, payload])
	_client_bridge.link.loopback = func(method: StringName, _peer: int, payload: PackedByteArray) -> void:
		_to_server.append([method, payload])
	# The loopback delivers within the frame, so the honest round trip is next to nothing;
	# the suite's 40 ms is a clock-lead test, and here it would only push the render time
	# further past the newest snapshot.
	_client_bridge.rtt_source = func() -> float: return 1.0
	var _s := _server_net.start()
	var _c := _client_net.start()

	var _ada := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_client_bridge.ask_ready()
	var _bea := _server_bridge.add_player(OTHER_PEER, OTHER_SESSION, "Bea")

	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.current = true
	add_child(_camera)


func _make_game(server: bool, scope: StringName, parent: Node) -> Playground:
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"pg_flatgrass"
	config.authoritative = server

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
	if _walk:
		config.snapshot_rate = 32
	config.enable_lag_compensation = false
	config.enable_prediction = true
	config.world_extent = 512.0
	manager.config = config

	parent.add_child(manager)
	manager.setup()
	return manager


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry[0], 1, entry[1])
	for entry in to_server:
		_server_bridge.link.deliver(entry[0], CLIENT_PEER, entry[1])


## One tick per physics frame, which is what a client on the server's rate does: the bridge
## puts the engine there on HELLO.
func _physics_process(delta: float) -> void:
	if _server_bridge == null or _client_net == null:
		return

	_drive_other()

	_tick += 1
	var _ticks := _client_net.clock.advance(delta)
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, _local_command())
	_flush()

	if _walk:
		_watch_the_press()


## What this client's own keys say this tick: nothing, or with `--walk` the cycle in the
## class note. Facing north, as the camera does, and strafing, so the view never turns and
## what moves on screen is the eye.
func _local_command() -> DotFpsCommand:
	var command := DotFpsCommand.new()

	if not _walk or not _placed or _settle > 0:
		return command

	var cycle := WALK_IDLE + WALK_RUN
	var at := _walk_tick % cycle
	var east := (_walk_tick / cycle) % 2 == 0
	_walk_tick += 1
	_walk_ticks += 1

	command.yaw = 0.0
	if at >= WALK_IDLE:
		command.move = Vector2(1.0 if east else -1.0, 0.0)

		if at == WALK_IDLE:
			var mine: PlaygroundPlayer = _client_game.players.get(&"u%d" % SESSION)
			if mine != null:
				_pressed_at = _tick
				_pressed_from = mine.global_position
				_pressed_sign = 1.0 if east else -1.0

	if _corrections_from < 0:
		var d := _client_net.predictor.describe()
		_corrections_from = int(d["corrections"]) + int(d["snaps"])

	return command


## The first tick after a press on which this client's player NODE has moved the way the key
## says: the node is what the camera's eye and the body are drawn from. Along the key's axis,
## so the tail of the previous strafe — the other way — is not counted as the answer.
func _watch_the_press() -> void:
	if _pressed_at < 0:
		return

	var mine: PlaygroundPlayer = _client_game.players.get(&"u%d" % SESSION)
	if mine == null:
		return

	if (mine.global_position.x - _pressed_from.x) * _pressed_sign > 0.001:
		_latencies.append(_tick - _pressed_at)
		_pressed_at = -1


## Bea runs back and forth across Ada's view, driven the way her client would drive her: the
## command her input would have carried, applied by the server.
func _drive_other() -> void:
	var ada: PlaygroundPlayer = _server_game.players.get(&"u%d" % SESSION)
	var bea: PlaygroundPlayer = _server_game.players.get(&"u%d" % OTHER_SESSION)

	if ada == null or bea == null:
		return

	if not _placed:
		_home = ada.controller.state.position
		ada.teleport(_home, 0.0)
		bea.teleport(_home + (Vector3(0.0, 0.0, -AHEAD * 0.5) if _downed else Vector3(-SWING, 0.0, -AHEAD)), -90.0)
		_placed = true
		_settle = 30
		if _zee != &"":
			_server_bridge._give_weapon(OTHER_SESSION, &"u%d" % OTHER_SESSION, _zee)
		if _hold:
			# A crate in front of her eye, for the press below to take hold of.
			var _crate := _server_game.props.spawn(&"crate", bea.player_id, bea.eye_position() + bea.aim_direction() * 2.5)

	if _downed:
		# What `PlaygroundDowns.tick` sets every tick on the server; still, as a downed player is.
		bea.downed = true
		(bea.get_node("Net") as PlaygroundPlayerNet).last_move = DotFpsCommand.new()
		return

	var offset := bea.controller.state.position.x - _home.x
	if offset > SWING:
		_heading = 90.0
	elif offset < -SWING:
		_heading = -90.0

	var run := DotFpsCommand.new()
	run.move = Vector2(0.0, 1.0)
	run.yaw = _heading
	if _zee != &"" or (_hold and _settle < 26):
		run.set_button(DotFpsCommand.BUTTON_USER_0, true)
	(bea.get_node("Net") as PlaygroundPlayerNet).last_move = run


func _process(delta: float) -> void:
	if _client_game == null or _client_net == null:
		return

	var mine: PlaygroundPlayer = _client_game.players.get(&"u%d" % SESSION)

	if mine != null and not mine.samples_input:
		# What `PlaygroundClient._build_view_switch` does the moment the client knows which
		# player is its own: that one is looked out of, so its body is hidden.
		mine.samples_input = true
		var _switch := mine.build_view_switch()

	var _shown := PlaygroundClient.present_frame(_client_net if _interp else null, _client_game)

	if _hold:
		if _presentation == null:
			_presentation = PlaygroundPresentation.new()
			_presentation.name = "Presentation"
			add_child(_presentation)
			_presentation.setup()
		var eye_at := _camera.global_position if _camera != null else Vector3.ZERO
		_presentation.present(delta, eye_at, -_camera.global_transform.basis.z if _camera != null else Vector3.FORWARD)
		var _beams := PlaygroundClient.present_beams(_client_bridge, _presentation, mine, eye_at, Vector3.FORWARD)

	if mine != null:
		# Where the real client draws its eye (`PlaygroundClient._process`).
		var eye := mine.render_eye_position()
		_camera.global_position = eye
		_camera.look_at(eye + Vector3(0.0, -0.2, -1.0), Vector3.UP)

		# The eye's apparent speed while the SERVER has this player strafing flat out: the
		# same measurement as the other probe, on the one player nobody sees from outside.
		if _walk and delta > 0.0:
			var server_mine: PlaygroundPlayer = _server_game.players.get(&"u%d" % SESSION)
			var flat := 0.0
			if server_mine != null:
				flat = Vector2(
					server_mine.controller.state.velocity.x, server_mine.controller.state.velocity.z
				).length()
			if _last_eye != Vector3.INF and flat > 5.0 and _settle <= 0:
				_eye_speeds.append(eye.distance_to(_last_eye) / delta)
			_last_eye = eye

	var theirs: PlaygroundPlayer = _client_game.players.get(&"u%d" % OTHER_SESSION)
	var bea: PlaygroundPlayer = _server_game.players.get(&"u%d" % OTHER_SESSION)

	if theirs == null or theirs.character == null or bea == null or delta <= 0.0:
		return

	var at := theirs.character.rig.global_position
	# Only while the SERVER has her running flat out: the turn at each end is supposed to
	# slow her down, and a frame across a teleport is not motion.
	var server_speed := Vector2(bea.controller.state.velocity.x, bea.controller.state.velocity.z).length()

	if _settle > 0:
		_settle -= 1
	elif _last_drawn != Vector3.INF and server_speed > 5.0:
		_speeds.append(at.distance_to(_last_drawn) / delta)

	_last_drawn = at


func _report_walk() -> void:
	var d := _client_net.predictor.describe()
	var seconds := float(_walk_ticks) / float(maxi(_client_game.tick_rate, 1))
	var corrections := int(d["corrections"]) + int(d["snaps"]) - maxi(_corrections_from, 0)

	var lat := "none seen"
	if not _latencies.is_empty():
		var sorted := _latencies.duplicate()
		sorted.sort()
		lat = "%d presses, %d..%d ticks (median %d)" % [
			sorted.size(), sorted[0], sorted[sorted.size() - 1], sorted[sorted.size() / 2]
		]

	var eye := "nothing sampled"
	if not _eye_speeds.is_empty():
		var sorted_eye := _eye_speeds.duplicate()
		sorted_eye.sort()
		var median: float = sorted_eye[sorted_eye.size() / 2]
		var still := 0
		var off := 0
		for v in _eye_speeds:
			if v < 0.01:
				still += 1
			if absf(v - median) / maxf(median, 0.001) > 0.2:
				off += 1
		eye = "%d frames, median %.2f m/s, %d standing still, %d more than 20%% off (%.0f%%)" % [
			_eye_speeds.size(), median, still, off, 100.0 * off / float(_eye_speeds.size())
		]

	print("walk: predicted %d of %d players; key to motion: %s" % [
		_client_net.registry.predicted().size(), _client_game.players.size(), lat
	])
	print("walk: %.1f s walking, %d corrections and snaps; predictor %s" % [
		seconds, corrections, str(d)
	])
	print("walk: this client's eye: %s" % eye)


func _report() -> void:
	if _speeds.is_empty():
		print("probe: nothing sampled")
		return

	var sorted := _speeds.duplicate()
	sorted.sort()
	var median: float = sorted[sorted.size() / 2]

	var still := 0
	var off := 0
	var worst := 0.0
	for v in _speeds:
		if v < 0.01:
			still += 1
		var ratio := absf(v - median) / maxf(median, 0.001)
		worst = maxf(worst, ratio)
		if ratio > 0.2:
			off += 1

	print("probe (%s): %d frames at full speed, median %.2f m/s, %d standing still, %d more than 20%% off (%.0f%%), worst %.0f%% off" % [
		"interpolated" if _interp else "NOT interpolated",
		_speeds.size(), median, still, off, 100.0 * off / float(_speeds.size()), 100.0 * worst,
	])
