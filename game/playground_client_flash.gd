extends "playground_client_net.gd"

## The flashlight's presentation, split out of the client: the light on the eye and the others' beams (dot-flashlight); the server owns on/off. No `class_name`; the fx half extends this.

## The light on the eye and the others' beams.
var flash: DotFlashlight = null
var flash_crowd: DotFlashlightCrowd = null
var _flash_msec := -100000
var _flash_retain := 0.0


## The sound manager the flashlight clicks play through, or null before audio is up.
func _flash_audio_ref() -> DotNodeRef:
	if presentation == null or presentation.audio == null or not presentation.audio.is_inside_tree():
		return null
	return DotNodeRef.of_path(presentation.audio.get_path())


## The light on the eye follows the server's state (but not for 0.4 s after our own switch, which is shown at once); everybody else's beam, and ours when the camera is not our eye, comes from the crowd.
func _present_flashlights(delta: float) -> void:
	if camera == null or not camera.is_inside_tree() or player == null or playground == null:
		return

	var cfg := playground.flashlight_conf()
	var allowed := DotFlashlightRules.allowed_on(cfg, playground.flashlight_map_id())

	if flash == null or not is_instance_valid(flash):
		flash = DotFlashlight.new()
		flash.name = "Flashlight"
		flash.config = cfg
		flash.handle_input = false
		flash.authoritative = false
		flash.audio = _flash_audio_ref()
		flash.switch_requested.connect(_on_flash_switch)
		camera.add_child(flash)

	flash.allowed = allowed

	if flash_crowd == null:
		flash_crowd = DotFlashlightCrowd.new()
		flash_crowd.name = "Flashlights"
		flash_crowd.config = cfg
		flash_crowd.audio = _flash_audio_ref()
		add_child(flash_crowd)

	var own_eye := view_id() == &"fp"
	var lit := player.flashlight and not player.downed

	if own_eye and Time.get_ticks_msec() - _flash_msec > 400:
		flash.apply_state({"on": lit})
	elif not own_eye:
		flash.apply_state({"on": false})

	flash_crowd.set_viewer(camera.global_position)

	for key: Variant in playground.players:
		var other := playground.players[key] as PlaygroundPlayer
		var shown := allowed and other.flashlight and not other.downed and (other != player or not own_eye)
		flash_crowd.set_lit(key, shown)
		if shown:
			flash_crowd.place(key, other.eye_position(), other.aim_direction())

	_flash_retain -= delta
	if _flash_retain <= 0.0:
		_flash_retain = 2.0
		flash_crowd.retain(playground.players.keys())


## The flashlight key: shown at once, asked of the server.
func _toggle_flashlight() -> void:
	if flash != null and player != null and not player.downed:
		var _asked := flash.toggle()


## Our own switch: asked of the server (or done here, offline).
func _on_flash_switch(_want: bool) -> void:
	_flash_msec = Time.get_ticks_msec()
	if bridge != null:
		bridge.ask_flashlight()
	elif playground != null and player != null:
		var _switched := playground.toggle_flashlight(player_id)
