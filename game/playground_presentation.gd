extends "res://game/playground_presentation_base.gd"

func setup() -> DotResult:
	# Randomness first: the map generator asks DotRegistry for a seed source, and one registered
	# after the map is built is silently ignored (a fixed seed is a legitimate fallback).
	var seeded := _build_randomness()
	if not seeded.ok:
		return seeded

	var settled := _build_settings()
	if not settled.ok:
		return settled
	var heard := _build_audio()
	if not heard.ok:
		return heard
	var drawn := _build_fx()
	if not drawn.ok:
		return drawn
	break_fx = BreakFx.new()
	break_fx.name = "BreakFx"
	add_child(break_fx)
	break_fx.setup(settings)
	_build_chat()

	apply_all()
	return DotResult.success(null)


func apply_all() -> void:
	for key in settings.schema.keys():
		_on_setting_changed(key, settings.get_value(key), &"applied")


# --- Randomness -------------------------------------------------------------

func _build_randomness() -> DotResult:
	rng = DotRandomManager.new()
	rng.name = "Random"
	rng.config = DotRandomConfig.new()
	# Zero picks one and logs it, which is what "what seed are you on" needs an answer to.
	rng.config.master_seed = 0
	rng.config.announce_seed = true
	# The scope keeps two games on one seed from being one world. A launcher handing the
	# same number to the sandbox and to the arena should produce two different places.
	rng.config.scope = &"playground"
	add_child(rng)

	var res := rng.setup()
	if not res.ok:
		return res.wrap("the playground's randomness")
	return DotResult.success(null)


func _build_settings() -> DotResult:
	settings = DotSettingsManager.new()
	settings.name = "Settings"
	settings.schema = schema()
	settings.local_store = DotSettingsStoreFile.new(settings_directory)
	settings.app_namespace = &"game_playground"
	settings.shared_namespace = &"tmc_account"
	add_child(settings)

	var res := settings.setup()
	if not res.ok:
		return res.wrap("the playground's settings")
	settings.changed.connect(_on_setting_changed)
	return DotResult.success(null)


func _on_setting_changed(key: StringName, value: Variant, _why: StringName) -> void:
	match key:
		&"master_volume":
			audio.mixer.master = float(value)
			audio.mixer.apply_to_buses()
		&"sfx_volume":
			audio.mixer.sfx = float(value)
			audio.mixer.apply_to_buses()
		&"voice_volume":
			audio.mixer.voice = float(value)
			audio.mixer.apply_to_buses()
		&"shake_scale":
			fx.config.shake_scale = float(value)
		&"allow_flashes":
			fx.config.allow_flashes = bool(value)
		&"fx_quality":
			fx.config.quality = int(value)
			_apply_decal_config()
		&"gore":
			_apply_decal_config()
		&"chat_window":
			_apply_chat_visibility()
		&"camera_landing_dip", &"camera_strafe_roll", &"camera_speed_fov":
			_apply_camera_motion()
		&"chat_open_key":
			_bind_chat(chat_window.open_action if chat_window != null else &"", str(value))
		&"chat_near_key":
			_bind_chat(chat_window.team_action if chat_window != null else &"", str(value))
		_:
			pass


## Points the camera motion settings at [param player]'s camera, and applies them. Called by
## the client when its player gets a camera: a setting nobody applies is a slider that moves
## nothing.
func bind_camera_motion(player: Node) -> void:
	_camera_player = player
	_apply_camera_motion()


func _apply_camera_motion() -> void:
	if settings == null or _camera_player == null or not is_instance_valid(_camera_player):
		return
	_camera_player.call(&"set_camera_motion_scales",
		settings.get_float(&"camera_landing_dip", 1.0),
		settings.get_float(&"camera_strafe_roll", 1.0),
		settings.get_float(&"camera_speed_fov", 1.0)
	)



func _build_audio() -> DotResult:
	audio = DotAudioManager.new()
	audio.name = "Audio"
	audio.catalogue = sound_catalogue()
	audio.mixer = DotAudioMixer.new()
	audio.mixer.master = settings.get_float(&"master_volume", 0.8)
	audio.voices = 24
	# Measured toward the family's -17 LUFS (dot-audio docs/loudness.md) with tools/loudness_pilot.gd:
	# +6 read -22.5 LUFS, +12 read -17.5.
	audio.loudness_trim_db = 12.0
	# Deterministic: the pitch of a crate landing comes out of the session's own seed, so
	# two people watching the same sandbox hear the same thing. It costs nothing and it is
	# what makes an audio bug reproducible.
	audio.roll_source = rng.stream(&"audio")
	add_child(audio)

	var res := audio.setup()
	if not res.ok:
		return res.wrap("the playground's audio")

	steps = DotAudioFootsteps.new()
	steps.name = "Footsteps"
	steps.manager = audio
	add_child(steps)
	ambience = DotAudioAmbience.new()
	ambience.name = "Ambience"
	ambience.manager = audio
	add_child(ambience)
	ambient = DotAmbienceDirector.new()
	ambient.name = "Ambient"
	ambient.manager = audio
	ambient.default_mood = PlaygroundAmbience.DEFAULT_MOOD
	ambient.prefix_moods = PlaygroundAmbience.PREFIX_MOODS
	ambient.rules = PlaygroundAmbience.make_rules()
	ambient.beds = ambience
	add_child(ambient)
	var _moods := ambient.setup()
	ambient.follow_settings(settings)
	if ambient.has_moods():
		ambient.on_map(&"")
	else:
		ambience.set_map_bed(bed_for(&""))

	# Only on a real sink, after setup: a headless server has nothing to bake for.
	var godot_sink := audio.sink as DotAudioSinkGodot
	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(audio.catalogue, sound_recipes())
		DotLog.info(
			CHANNEL,
			"no audio files; synthesised stand-ins are in use",
			{"ids": sound_recipes().size(), "dir": SOUND_DIR}
		)

	return DotResult.success(null)


func _apply_decal_config() -> void:
	if blood != null:
		blood.apply_settings(settings)


func _build_fx() -> DotResult:
	fx = DotFxManager.new()
	fx.name = "Fx"
	fx.catalogue = fx_catalogue()
	fx.config = DotFxConfig.new()
	fx.config.quality = settings.get_int(&"fx_quality", 3)
	fx.config.shake_scale = settings.get_float(&"shake_scale", 1.0)
	fx.config.allow_flashes = settings.get_bool(&"allow_flashes", true)
	# No decals: nothing in a sandbox marks a wall, and a decal ring on a map where the
	# geometry is generated is a hole in a wall that will not exist next map.
	fx.config.max_decals = 0
	add_child(fx)

	blood = DotFxBlood.new()
	add_child(blood)
	decals = blood.decals
	_apply_decal_config()

	var res := fx.setup()
	if not res.ok:
		return res.wrap("the playground's effects")

	# Said out loud, because a missing scene is otherwise a DEBUG line; headless_presentation asserts none is missing.
	var missing := fx.catalogue.missing_scenes()
	if not missing.is_empty():
		DotLog.warn(CHANNEL, "effect scenes missing; those effects will not draw", {
			"paths": ", ".join(missing),
		})
	return DotResult.success(null)


# --- Console ----------------------------------------------------------------

# --- Chat -------------------------------------------------------------------

## The box a player types in, and the three settings that decide it. The channels come from
## `PlaygroundServices.chat_channels`, not a copy here; the admin channel is filtered out because a player
## cannot send on it.
func _build_chat() -> void:
	_chat_layer = CanvasLayer.new()
	_chat_layer.name = "ChatLayer"
	_chat_layer.layer = 100
	add_child(_chat_layer)

	var offered: Array[Dictionary] = []

	# Typed, not inferred: see [method PlaygroundServices.chat_channels].
	for channel: DotChatChannel in PlaygroundServices.chat_channels():
		if channel.admin_only or channel.server_only:
			continue

		offered.append({
			"id": channel.id,
			"label": "Say" if channel.display_name == "" else "Say (%s)" % channel.display_name,
			"colour": channel.colour,
			# The proximity channel is what the second key opens here. A sandbox has no
			# teams; what it has is the difference between telling the server and telling
			# whoever is standing beside your build.
			"team": channel.scope == DotChatChannel.Scope.RADIUS,
		})

	chat_window = DotChatWindow.new()
	chat_window.name = "ChatWindow"
	chat_window.open_action = &"playground_chat"
	chat_window.team_action = &"playground_chat_near"
	chat_window.channels = offered
	_chat_layer.add_child(chat_window)


## Puts one binding from the settings document onto its action.
##
## Empty is left alone: applying it would unbind chat with no way back from inside the game.
func _bind_chat(action: StringName, text: String) -> void:
	if action == &"" or text.strip_edges() == "":
		return

	var bound := DotInputBinding.apply(action, text)

	if bound == "":
		DotLog.warn(CHANNEL, "a chat key was not understood", {
			"action": String(action), "binding": text
		})


## The server said whether anything else is carrying this conversation.
func set_chat_relayed(relayed: bool) -> void:
	if _chat_relayed == relayed:
		return

	_chat_relayed = relayed
	_apply_chat_visibility()


## Resolves the three-way setting against what the server said.
##
## `on` is a relayed server AND a box in front of the game, `off` a player who chats elsewhere,
## `auto` draws it unless the server already puts these lines where the player can see them.
func _apply_chat_visibility() -> void:
	if chat_window == null or settings == null:
		return

	match StringName(str(settings.get_value(&"chat_window"))):
		&"on":
			chat_window.enabled = true
		&"off":
			chat_window.enabled = false
		_:
			chat_window.enabled = not _chat_relayed


## dot-console's kit, registered with [param menu]; this game adds `quit` and `seed`, ahead of the server's console.
## Called by [PlaygroundClient] after its [DotMenu] exists, not from [method setup]: the kit makes the console a
## menu overlay, which is what stops the player walking while they type.
func build_console(menu: Object = null) -> void:
	adopt_console(DotConsoleKit.build(self, settings, menu))


## Takes a console built elsewhere (the client's platform builds it, after the menu) and gives
## it this game's commands. Its panel is found beside it, wherever the kit put the layer.
func adopt_console(built: DotConsoleController) -> void:
	console = built
	if console == null:
		return

	var server_sources := console.sources().slice(1)
	for s in server_sources:
		console.remove_source(s)
	var local := _local_commands()
	var _icons_bound := PlaygroundWeaponIcons.shared.bind_console(local)
	console.add_source(local)
	for s in server_sources:
		console.add_source(s)
	bind_profile_replies()

	console_panel = console.get_parent().get_node_or_null(^"ConsoleLayer/ConsolePanel") as DotConsolePanel


## Shows the server's answers to `profile_edit` in the console, once both the link and the console exist.
func bind_profile_replies() -> void:
	if console != null and profile_link != null and not profile_link.reply.is_connected(_on_profile_reply):
		profile_link.reply.connect(_on_profile_reply)


func _on_profile_reply(ok: bool, text: String) -> void:
	if console != null and not mute_profile_replies:
		console.print_line(text if ok else "profile_edit refused: " + text)


func profile_submit(req: Dictionary) -> DotResult:
	if profile_link != null:
		return profile_link.submit(req)
	var game: Object = client.get("playground") if client != null else null
	var profiles: Object = game.get("profiles") if game != null else null
	if profiles == null:
		return DotResult.fail(DotError.CODE_STATE, "no profiles here")
	return profiles.runtime.handle_request(PlaygroundProfiles.LOCAL_ACTOR, req)


## This game's own commands; the kit has `help`, `clear`, `settings` and every setting.
func _local_commands() -> DotConsoleLocal:
	var local := DotConsoleLocal.new()
	local.add_command(&"quit", "Leave", func(_a: PackedStringArray) -> Variant:
		get_tree().quit()
		return null
	)
	local.add_command(&"seed", "Show this session's seed", func(_a: PackedStringArray) -> Variant:
		# The one command this game needs more than the others: a generated map nobody can
		# name the seed of is a map nobody can share, and "play the map I played" is the
		# most-requested feature every generated world gets.
		return rng.describe_lines()
	)
	DotConsoleProfileEdit.register(local, profile_submit)
	return local


# --- What the game asks for -------------------------------------------------

func present(delta: float, eye: Vector3, forward: Vector3) -> void:
	audio.listener_position = eye
	fx.viewer_position = eye
	fx.viewer_forward = forward
	fx.advance(delta)
	blood.advance(delta)


func camera_shake() -> Vector3:
	return fx.shake.offset()


## Whether something on screen owns the keyboard right now.
##
## The chat box belongs here as the console does: movement and tool fire must stop while somebody types.
func swallows_input() -> bool:
	if console != null and console.is_open():
		return true
	if console_panel != null and console_panel.has_keyboard_focus():
		return true

	return chat_window != null and chat_window.is_open()


func on_prop_spawned(at: Vector3, mine: bool) -> void:
	if not mine and not settings.get_bool(&"prop_sounds", true):
		# The one sandbox-specific setting, and it is about somebody else's building.
		# A busy server is a permanent noise otherwise.
		return
	var t := Transform3D.IDENTITY
	t.origin = at
	audio.play_at(&"prop_spawn", at)
	fx.spawn(&"prop_spawn", t)


## A transform at [param at] whose -Z points along [param direction].
static func facing(at: Vector3, direction: Vector3) -> Transform3D:
	var forward := direction.normalized() if direction.length_squared() > 0.0 else Vector3.FORWARD
	# Straight up or down has no yaw to keep; any other up vector will do.
	var up := Vector3.RIGHT if absf(forward.dot(Vector3.UP)) > 0.99 else Vector3.UP
	return Transform3D(Basis.looking_at(forward, up), at)


## A transform that stretches `tool_beam.tscn` -- one metre down -Z -- from [param from]
## to [param to]. Only Z is scaled, so the beam is as thin at thirty metres as at one.
static func beam_between(from: Vector3, to: Vector3) -> Transform3D:
	var t := facing(from, to - from)
	var length := maxf(from.distance_to(to), 0.001)
	t.basis = Basis(t.basis.x, t.basis.y, t.basis.z * length)
	return t


## The physics gun's beam, from in front of the eye to what it holds, this frame. One node moved every frame,
## not one spawned per frame: `tool_beam` lives 100 ms, and a spawn a frame would stack beams. Call it after
## [method present]. [param key] says whose: a connected client draws one beam per player holding something.
func on_tool_beam(eye: Vector3, aim: Vector3, to: Vector3, key: int = 0) -> Node3D:
	if fx == null:
		return null

	var from := facing(eye, aim).translated_local(BEAM_OFFSET).origin
	var at := beam_between(from, to)
	var beam: Node3D = _beams.get(key)

	if beam != null and is_instance_valid(beam) and not beam.is_queued_for_deletion():
		beam.global_transform = at
		return beam

	beam = fx.spawn(&"tool_beam", at) as Node3D
	_beams[key] = beam
	return beam


## How many splashes this has made. For the suites and `describe`.
var splashes: int = 0


## Something crossed into a liquid at [param at] (on the surface): the splash and a puff.
func on_splash(at: Vector3) -> void:
	splashes += 1
	audio.play_at(&"splash", at)
	var t := Transform3D.IDENTITY
	t.origin = at
	fx.spawn(&"prop_spawn", t)


## A player or NPC took a hit at [param point], seen from [param from]: blood on the first
## surface behind it along that line, within [param reach] metres. Returns the splatter, or
## null when there is no victim of that kind, no surface, or gore is off.
func on_body_hit(victim: int, point: Vector3, from: Vector3, reach: float = 4.0) -> Node3D:
	var kind := DotEntity.kind_of(victim)
	if kind != DotEntity.KIND_PLAYER and kind != DotEntity.KIND_NPC:
		return null
	return blood.splat_behind(from, point, reach)


func on_pane_broken(at: Vector3) -> void:
	audio.play_at(&"glass_break", at)
	break_fx.shatter(at, 0)


func on_prop_landed(at: Vector3) -> void:
	if not settings.get_bool(&"prop_sounds", true):
		return
	audio.play_at(&"prop_land", at)


func on_tool_grab() -> void:
	audio.play(&"tool_grab")


func on_tool_punt(at: Vector3, mine: bool) -> void:
	audio.play_at(&"tool_punt", at)
	if mine:
		fx.spawn(&"punt_shake", Transform3D.IDENTITY)


func on_bought() -> void:
	audio.play(&"buy")


## The undo cue. Returns what was asked of the audio, so a test can see the request without ears.
func on_undo(at: Vector3, volume: float, spatial: bool) -> Dictionary:
	if volume <= 0.0:
		return {}
	if spatial and at != Vector3.ZERO:
		audio.play_at(&"undo_at", at, volume)
	else:
		audio.play(&"undo", volume)
	return {"id": &"undo", "at": at if spatial else Vector3.ZERO, "volume": volume}


func on_refused() -> void:
	audio.play(&"refused")


## A map-vote cue from the server. Empty is silence, and an id this catalogue does not
## have is dot-audio's silent refusal rather than an error.
func on_vote_cue(id: StringName) -> int:
	if id == &"" or audio == null:
		return 0

	return audio.play(id)


## A dead body's sound (dot-player-char's ragdolls), where it landed. Returns the voice.
func on_body(id: StringName, at: Vector3, volume: float) -> int:
	if audio == null:
		return 0

	return audio.play_at(id, at, clampf(volume, 0.3, 1.0))


## A toy's sound (dot-props' toys): a bounce, a knock, a switch, a honk, where it happened.
func on_toy(id: StringName, at: Vector3, strength: float) -> int:
	if audio == null:
		return 0

	return audio.play_at(id, at, clampf(strength, 0.25, 1.0))


## A beacon's ripple went out from [param at]. From `PlaygroundClient._process`, on every
## client, for every beaconed player — the beaconed one included, who hears their own.
## Returns the voice, 0 for none.
func on_beacon(at: Vector3) -> int:
	if audio == null:
		return 0

	return audio.play_at(BEACON_SOUND, at)


## A utility grenade's cloud, fire or blind; the blind is the local player's, so [param info]'s victim is 0.
func on_grenade_fx(info: Dictionary) -> void:
	var _shown := AwGrenadeFx.show(fx, get_tree(), info, 0)


func on_wave_incoming() -> void:
	audio.play(&"wave_incoming")
	fx.flash(&"wave_flash")


func on_map_changed(map_id: StringName = &"") -> void:
	fx.clear()
	blood.clear()
	if ambient != null and ambient.has_moods():
		ambient.on_map(map_id)
	elif ambience != null:
		ambience.set_map_bed(bed_for(map_id))


## A map's bed, from its name: a surf map is ramps in the air (wind), a climb map is rock, the
## sandbox and everything else is outdoors. By prefix (after this game's `pg_`), because an
## imported or custom map is named by its author.
static func bed_for(map_id: StringName) -> StringName:
	var id := String(map_id).to_lower().trim_prefix("pg_")
	if id.begins_with("surf_"):
		return &"amb_wind"
	if id.begins_with("kz_") or id.begins_with("climb_"):
		return &"amb_cave"
	return &"amb_outdoor"


## The roof probe the weapon's shot sounds read (`ZeeShotFx.roof`): roofed means a room tail follows a shot.
var shot_roof := DotAmbienceRoof.new()


## The listener's roof, once a frame: under one the ambience crosses to its indoor mood.
func follow_roof(delta: float, eye: Vector3, space: PhysicsDirectSpaceState3D, world_mask: int) -> void:
	shot_roof.mask = world_mask
	var _changed := shot_roof.step(delta, eye, space)
	if ambient != null:
		ambient.follow_roof(delta, eye, space, world_mask)


## Everybody on the map steps, once a frame: players and bots alike.
func keep_walkers(bodies: Array) -> void:
	if steps != null:
		steps.keep(bodies)


func on_server_clamps(request: Dictionary) -> PackedStringArray:
	return settings.apply_server_clamps(request)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("the playground's presentation layer")
	out.append_array(rng.describe_lines())
	out.append_array(settings.describe_lines())
	out.append_array(audio.describe_lines())
	if ambient != null:
		out.append("ambience: %s" % str(ambient.describe()))
	out.append_array(fx.describe_lines())

	if chat_window != null:
		out.append("chat box: %s" % str(chat_window.describe()))
	return out
