extends SceneTree

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")
const PlaygroundHud := preload("../game/playground_hud.gd")
const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundServices := preload("../game/playground_services.gd")
const PlaygroundZee := preload("../game/playground_zee.gd")

## Renders the sandbox in first person and in third, so a person can look at both.
##
## [b]A camera is the one thing in this repository no assertion reaches.[/b] Every check
## on the view switch is a check on an id — `active_id()`answers "tp" — and an id is equally
## happy when the rig is inside the player's head, behind a wall, or looking at the sky.
## Four of the bugs in this family's list were found by looking at a frame.
##
## The last two frames put the HUD over first person, with the map's time left as a
## server's vote would describe it: `hud_clock` after an extend, `hud_no_clock` under the
## deployed `trigger: rtv_only` with no limit, where the slot must be gone rather than
## showing the local session's thirty minutes.
##
## The last three are an administrator's marks, from first person through the real HUD:
## `admin_beacon` a beaconed player on open floor ahead, `admin_beacon_wall` the same
## player behind a wall with only the through-walls column showing, and `admin_blind` the
## local player blinded, where the world must be gone to the edges and the HUD still on top.
##
## [codeblock]
## tools/screenshot_views.sh
## [/codeblock]
##
## [b]Not `--headless`[/b]: that gives a null renderer and every frame it saves is empty,
## which is worse than no screenshot because it looks like one.

const OUT_DIR := "res://screenshots"

## Frames to let the rig settle. `DotTpsCameraRig` is on a spring arm and springs take
## time, so a capture on the tick of the switch is a picture of the camera mid-flight.
const SETTLE := 12

var _game: Playground = null
var _player: PlaygroundPlayer = null

## The other player the admin frames beacon. See [method _arrange_admin].
var _other: PlaygroundPlayer = null

## A wall between the camera and [member _other], for `admin_beacon_wall`. Visual only:
## the beacon's column is drawn without a depth test, and a mesh is all that needs.
var _wall: MeshInstance3D = null
var _hud: PlaygroundHud = null

## `chat_ballot`'s pieces: the client's presentation (its chat box), a client never added to
## the tree whose chat handler draws the ballot's line, and the shell's ballot panel.
var _presentation: PlaygroundPresentation = null
var _chat_client = null
var _ballot: DotBallotPanel = null
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _arranged := false
var _done := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	DotFpsSampler.register_default_actions()

	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.initial_map = &"pg_flatgrass"
	config.map_seconds = 0.0

	_game = Playground.new()
	_game.name = "Playground"
	_game.config = config
	root.add_child(_game)


func _process(_delta: float) -> bool:
	if _done:
		return true

	if _player == null:
		if _game.maps == null or _game.maps.current == null:
			return false

		_player = _game.add_player(&"local", "gamemann")
		_player.samples_input = true
		# The sampler reads real input and there is none behind xvfb; the player is left
		# standing, which is what makes the two frames comparable.
		_player.sampler = null

		var camera := Camera3D.new()
		camera.name = "Camera"
		camera.fov = 100.0
		camera.current = true
		_player.add_child(camera)

		if not _player.build_view_switch():
			push_error("no view switch was built; there is nothing to photograph")
			_done = true
			return true

		_hud = PlaygroundHud.new()
		_hud.name = "Hud"
		root.add_child(_hud)
		_hud.bind(_game, &"local")
		_hud.visible = false

		_shots = [
			{"name": "view_first_person", "third": false},
			{"name": "view_third_person", "third": true},
			{
				"name": "hud_clock", "third": false,
				"clock": {"has_clock": true, "seconds_left": 2700, "running": true},
			},
			{"name": "hud_no_clock", "third": false, "clock": {"has_clock": false}},
			{"name": "admin_beacon", "third": false, "beacon": true},
			{"name": "admin_beacon_wall", "third": false, "beacon": true, "wall": true},
			{"name": "admin_blind", "third": false, "blind": true},
			{"name": "hud_creative", "third": false, "creative": true},
			# The tool gun's edit mode: three crates ahead, the middle one selected, painted and
			# half again as big, with the box the client draws round a selection.
			{"name": "edit_selection", "third": false, "edit": true},
			{"name": "body_standing", "third": false, "other": true},
			{"name": "rider_seated", "third": false, "other": true, "seated": true},
			# A zee weapon in hand and two confirmed hits on Bea, the second a kill: the ammunition
			# counter bottom right, the marker round the crosshair and the number on her body.
			{"name": "hud_hits", "third": false, "other": true, "hits": true},
			# A map vote as a connected player sees it: the ballot's chat line, through the
			# client's own chat handler, and the drawn panel a client shell puts top right. The
			# line must be in the chat box once and not on the notice line as well.
			{"name": "chat_ballot", "third": false, "ballot": true},
		]
		return false

	# The first-person camera at the simulated eye, as `PlaygroundClient._process` puts it.
	var eye_camera := _player.get_node_or_null("Camera") as Camera3D
	if eye_camera != null and eye_camera.current:
		eye_camera.global_position = _player.eye_position()
		eye_camera.global_rotation = Vector3(
			deg_to_rad(_player.controller.state.pitch),
			deg_to_rad(_player.controller.state.yaw),
			0.0
		)

	# Every frame, as `PlaygroundClient._present_beacons` does: the ripple is an animation.
	for body: PlaygroundPlayer in [_player, _other]:
		if body != null:
			var _pinged := body.present_beacon(_delta, body == _player)

	if _at >= _shots.size():
		print("[views] %d frames in screenshots/" % _shots.size())
		_done = true
		return true

	var shot: Dictionary = _shots[_at]

	if not _arranged:
		var now := _player.set_view_mode(bool(shot["third"]))
		print("[views] %s -> %s" % [String(shot["name"]), String(now)])

		# [b]Back to the first-person camera, which nothing else does.[/b] The rig's
		# camera makes itself current when third person starts and nothing hands the view
		# back, so every first-person frame after `view_third_person` used to be taken from
		# four metres behind the player with the body hidden — which reads as first person
		# until something stands in front of the player. The beacon frames are what showed
		# it: Bea's ring was behind the local player's own (hidden) position, out of shot.
		if not bool(shot["third"]):
			(_player.get_node("Camera") as Camera3D).make_current()

		_arrange_admin(shot)
		if bool(shot.get("edit", false)):
			_arrange_edit()
		_player.creative = bool(shot.get("creative", false))
		if bool(shot.get("ballot", false)):
			_arrange_ballot()
		if bool(shot.get("hits", false)):
			_arm_for_hits()
		else:
			_hud.damage_numbers.clear()
		_hud.visible = shot.has("clock") or shot.has("beacon") or shot.has("blind") or shot.has("creative") or shot.has("ballot") or shot.has("hits")
		if shot.has("clock"):
			var view := DotVoteClockView.new()
			view.adopt(shot["clock"], Time.get_ticks_msec() / 1000.0)
			_hud.clock_view = view
		_arranged = true
		_wait = SETTLE
		return false

	if _wait > 0:
		# The hits a few frames before the capture: the marker fades in a quarter of a second.
		if _wait == 3 and bool(shot.get("hits", false)) and _other != null:
			var on_her := _other.controller.state.position + Vector3.UP * 1.3
			var her := Playground.hit_victim_id(DotEntity.KIND_PLAYER, 2)
			_hud.confirm_hit(her, 18.0, on_her, false, false)
			_hud.confirm_hit(her, 24.0, on_her, true, true)
		_wait -= 1
		return false

	_capture(String(shot["name"]))
	_at += 1
	_arranged = false
	return false


## Puts the second player eight metres ahead of the camera for a beacon frame, a wall
## between the two for the wall frame, and the blind on the local player for the last.
func _arrange_admin(shot: Dictionary) -> void:
	var beaconing := bool(shot.get("beacon", false))

	# Her body is drawn: dot-player-char seats the rig on the player it belongs to (b04a9ac),
	# so it stands where she does. Until then it stood at the world origin and these frames
	# could show the marker alone. `body_standing` and `rider_seated` are about the body itself.
	if (beaconing or shot.has("other")) and _other == null:
		_other = _game.add_player(&"other", "Bea")

	if _other != null:
		_other.beacon = beaconing
		_other.set_riding(bool(shot.get("seated", false)))
		var flat := _player.aim_direction()
		flat.y = 0.0
		flat = flat.normalized() if flat.length() > 0.01 else Vector3.FORWARD
		# A little to the side as well as ahead: the ring is a flat band at her feet, and
		# eight metres dead ahead from eye height it sits edge-on behind her own legs.
		var side := flat.cross(Vector3.UP)
		var at := _player.controller.state.position + flat * 7.0 + side * 1.5
		_other.teleport(at, _player.controller.state.yaw + 180.0)

		if bool(shot.get("wall", false)) and _wall == null:
			var box := BoxMesh.new()
			box.size = Vector3(6.0, 4.0, 0.4)
			var material := StandardMaterial3D.new()
			material.albedo_color = Color(0.45, 0.47, 0.5)
			box.material = material
			_wall = MeshInstance3D.new()
			_wall.name = "Wall"
			_wall.mesh = box
			root.add_child(_wall)
			_wall.global_position = _player.controller.state.position + flat * 4.0 \
				+ Vector3.UP * 2.0
			_wall.look_at(_wall.global_position + flat, Vector3.UP)
		elif not bool(shot.get("wall", false)) and _wall != null:
			_wall.queue_free()
			_wall = null

	_player.blinded = bool(shot.get("blind", false))


## Three crates in a row ahead of the camera, the middle one selected by the edit mode.
func _arrange_edit() -> void:
	if _other != null:
		_other.teleport(_player.controller.state.position + Vector3(0, 0, 60), 0.0)
	var flat := _player.aim_direction()
	flat.y = 0.0
	flat = flat.normalized() if flat.length() > 0.01 else Vector3.FORWARD
	var side := flat.cross(Vector3.UP)
	var ahead := _player.controller.state.position + flat * 5.0 + Vector3.UP * 0.6
	var picked: Node3D = null
	var reasons: Array = []
	var on_refused := func(_p: StringName, _id: StringName, reason: String) -> void: reasons.append(reason)
	_game.props.refused.connect(on_refused)
	for i in 3:
		# One owner each: the spawner's rate limit refuses a second spawn by one player in the
		# same frame ("Slow down."), which no player clicking can reach.
		var crate := _game.props.spawn(&"crate", StringName("builder%d" % i), ahead + side * (float(i) - 1.0) * 2.4)
		if crate == null:
			print("[views] crate %d refused: %s" % [i, str(reasons)])
			continue
		DotPhysGun.set_frozen(crate, true)
		if i == 1:
			picked = crate.node as Node3D
			picked.call("set_size_scale", 1.5)
			picked.call("set_tint", Color.html("e05252"))
			picked.global_position += Vector3.UP * 0.25
	if picked != null:
		var box := PlaygroundClient.selection_box()
		picked.add_child(box)
		PlaygroundClient.fit_selection_box(box, picked)


## The `hud_hits` frame's weapon: a zee SMG in the hands under the first-person camera, as
## `PlaygroundClient._arm_zee` builds it, with a magazine a third gone.
func _arm_for_hits() -> void:
	PlaygroundZee.use_this_games_art()
	var camera := _player.get_node("Camera") as Camera3D
	var hands := ZeeViewModel.new()
	hands.name = "ZeeViewModel"
	camera.add_child(hands)
	var rig := PlaygroundZee.arm(_player, _game.weapon_def(&"zee_smg"), ZeeWeaponRig.Role.LOCAL, true,
		_game.tick_rate, 0, hands)
	if rig != null and rig.arsenal.current() != null:
		rig.arsenal.current().magazine = 21
	_hud.set_tool("SMG", &"")


## The `chat_ballot` frame: the presentation's chat box, the ballot's line through
## `PlaygroundClient._on_chat_message` (the handler a connected client runs), and the drawn
## panel where a client shell's notice overlay puts it.
func _arrange_ballot() -> void:
	PlaygroundPresentation.use_scratch_settings("screenshot_views")
	_presentation = PlaygroundPresentation.new()
	_presentation.name = "Presentation"
	root.add_child(_presentation)
	var _built := _presentation.setup()
	_presentation.settings.local_store = DotSettingsStoreMemory.new()
	_presentation.settings.load_now()
	_presentation.apply_all()

	var chat := DotChatClient.new()
	chat.channels = PlaygroundServices.chat_channels()
	_chat_client = PlaygroundClient.new()
	_chat_client.hud = _hud
	_chat_client.chat = chat
	_chat_client.presentation = _presentation

	var maps := ["Surf: Introduction", "Bhop: Introduction", "Lobby", "Canyon"]
	_chat_client._on_chat_message(
		DotChatMessage.system(PlaygroundServices.CHANNEL_ALL, "Vote: %s (30s)" % ", ".join(maps)),
		PlaygroundServices.CHANNEL_ALL
	)

	var options := []
	for i in maps.size():
		options.append({"id": "m%d" % i, "label": maps[i], "votes": [1, 0, 2, 0][i]})
	_ballot = DotBallotPanel.new()
	_ballot.name = "Ballot"
	_ballot.ui_theme = DotUiTheme.space()
	_ballot.panel_width = 360.0
	_ballot.position = Vector2(root.size.x - 360.0 - 24.0, 120.0)
	root.add_child(_ballot)
	_ballot.show_state({
		"open": true, "title": "Next map", "command": "nominate", "seconds": 30,
		"options": options, "voters": {"u1": 0, "u2": 2, "u3": 2},
	})


func _capture(shot_name: String) -> void:
	var image := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]

	if image.save_png(path) != OK:
		push_error("could not write %s" % path)
		return

	# Reported at CAPTURE time, not at arrange time. `DotTpsCameraRig.follow` runs once a
	# frame from `DotTpsController._process`, so everything about the rig is still at its
	# starting value on the frame the switch happens — printing it there says the camera
	# never moved when what it means is that it has not moved YET.
	var where := "first person"

	if _player.tps != null and _player.tps.rig != null and _player.tps.rig.camera != null:
		if _player.tps.active:
			where = "cam=%s behind body=%s arm=%.2f" % [
				str(_player.tps.rig.camera.global_position.round()),
				str(_player.global_position.round()),
				_player.tps.rig.arm.get_hit_length()
			]

	print("[views] %s  %dx%d  %s" % [
		path, image.get_width(), image.get_height(), where
	])
