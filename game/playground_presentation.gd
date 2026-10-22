extends Node

const PlaygroundBindings := preload("playground_bindings.gd")
const PlaygroundPaths := preload("playground_paths.gd")
const PlaygroundProfiles := preload("playground_profiles.gd")

const PlaygroundServices := preload("playground_services.gd")
const PlaygroundVote := preload("playground_vote.gd")

## Settings, randomness, audio, effects and a console.
##
## [b]This is the only game in the family that holds dot-randomness as well[/b], and the
## reason is the generated map: a sandbox whose layout, whose scattered props and whose
## wave composition all come out of **one** seed is a sandbox two people can compare notes
## about. Three separate generators would be three numbers, and "what seed are you on"
## would stop meaning anything.
##
## The manager is here rather than in `Playground` because it is the thing that owns the
## session's seed, and because `Playground` should be able to run without it — a server
## with no randomness manager falls back to a fixed seed and says so, which is better than
## a sandbox that is a different shape on every boot and cannot say why.

const CHANNEL := "playground.presentation"

const SCHEMA_VERSION := 1
const SOUND_DIR := "res://audio"

## Where the player's settings document lives. Only a suite or a render tool changes it,
## through [method use_scratch_settings]; see that.
const PLAYER_SETTINGS := "user://playground_settings"

## The directory the next [PlaygroundPresentation] stores its settings in.
static var settings_directory: String = PLAYER_SETTINGS

## The ping an administrator's beacon makes. See [method sound_catalogue].
const BEACON_SOUND := &"beacon"
## Where the two effect scenes are: `spawn_puff.tscn` and `tool_beam.tscn`. Neither has a
## script or an external resource, so a delivered pack has nothing in them to rewrite.
static var FX_DIR := PlaygroundPaths.rebase("res://scenes/fx")

## Where the physics gun's beam starts, from the eye, in the aim's frame: right, down,
## forward. A beam from the eye itself is drawn end-on, as a dot in the crosshair.
const BEAM_OFFSET := Vector3(0.14, -0.16, -0.35)

var settings: DotSettingsManager = null
var rng: DotRandomManager = null
var audio: DotAudioManager = null

## Everybody's footsteps by the box's material and a bed per map: dot-audio's stock (Kenney's
## footsteps and generated beds, CC0; the addon's stock/CREDITS.md). A box's `dot_fps_surface`
## meta, which the movement already reads, is what a step on it sounds like.
var steps: DotAudioFootsteps = null
var ambience: DotAudioAmbience = null
var fx: DotFxManager = null
## The player's console, built by [method build_console] once the client has a menu.
var console: DotConsoleController = null
#
var profile_link: DotNetProfileLink = null
## True while the profile workbench or its admin probe owns the link's answers (no console lines).
var mute_profile_replies := false
var console_panel: DotConsolePanel = null

## The physics guns' beams while they are drawn, by whose (0 is this client's own offline
## beam). See [method on_tool_beam].
var _beams: Dictionary = {}

## The in-game chat box. See [method _build_chat].
var chat_window: DotChatWindow = null

## The player whose camera the motion settings move. See [method bind_camera_motion].
var _camera_player: Node = null

var client: Node = null

var _chat_layer: CanvasLayer = null

## Whether the server said something else is carrying chat. See [method set_chat_relayed].
var _chat_relayed: bool = false


func setup() -> DotResult:
	# Randomness first, and the order is load-bearing in the same way `RoomServices`'
	# moderation-before-chat is: the map generator asks `DotRegistry` for a seed source,
	# and a manager registered after the map has been built is a manager the map did not
	# use -- with nothing erroring, because falling back to a fixed seed is a legitimate
	# configuration and therefore indistinguishable from the bug.
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


# --- Settings ---------------------------------------------------------------

static func schema() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION

	s.add(DotSettingsDef.number(&"master_volume", 0.8, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"sfx_volume", 1.0, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"voice_volume", 1.0, 0.0, 1.0, &"audio"))

	s.add(DotSettingsDef.number(&"sensitivity", 2.5, 0.05, 20.0, &"controls").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.boolean(&"hold_to_open_menu", true, &"controls").with_description(
		"Hold the spawn-menu key for the spawn menu, or press it to pin it open."
	).with_scope(DotSettingsDef.Scope.ACCOUNT))

	s.add(DotSettingsDef.integer(&"field_of_view", 100, 70, 130, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))
	s.add(DotSettingsDef.integer(&"fx_quality", 3, 0, 3, &"video"))

	s.add(DotSettingsDef.number(&"shake_scale", 1.0, 0.0, 2.0, &"accessibility")
		.with_description("Zero turns camera shake off entirely."))
	s.add(DotSettingsDef.boolean(&"allow_flashes", true, &"accessibility"))

	# Camera motion, each 0 (off) to 2, 1 being the game's pick
	# (`PlaygroundPlayer.camera_motion_picks`). ACCOUNT: whether motion makes somebody sick is
	# about the person, not the machine. One each, because a player who cannot take the lean
	# may still want the dip.
	for key: StringName in CAMERA_MOTION_KEYS:
		s.add(DotSettingsDef.number(key, 1.0, 0.0, 2.0, &"accessibility", 0.05).with_scope(
			DotSettingsDef.Scope.ACCOUNT
		).with_description(CAMERA_MOTION_KEYS[key]))

	# Chat. ACCOUNT scope for all three: which key opens chat and whether a player wants
	# the box at all is about the person, not about this machine.
	s.add(DotSettingsDef.choice(
		&"chat_window",
		&"auto",
		[&"auto", &"on", &"off"] as Array[StringName],
		&"chat"
	).with_scope(DotSettingsDef.Scope.ACCOUNT).with_description(
		"auto hides the box on a server already carrying chat somewhere the player can "
		+ "see it; on always draws it; off never does."
	))
	s.add(DotSettingsDef.binding(&"chat_open_key", "Y", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.binding(&"chat_near_key", "U", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	).with_description("Opens chat on the proximity channel rather than on all."))

	# A sandbox's own: how much of somebody else's building you want to be told about.
	s.add(DotSettingsDef.boolean(&"prop_sounds", true, &"sandbox").with_description(
		"Whether other people's props make a noise when they land."
	))
	# The window, the frame rate, the theme and the frame-rate counter: dot-menu's stock
	# settings, applied by the client's DotMenuApplier and its DotMenu. The keys above that
	# are also stock (volumes, field of view, effects, shake) stay as declared here.
	# GROUP_CONTROLS for `invert_mouse` (sensitivity is declared above, so it is skipped):
	# the Controls page drew its row only once the key existed, and the applier inverts the
	# sampler's look with it.
	DotMenuStock.declare(s, [DotMenuStock.GROUP_VIDEO, DotMenuStock.GROUP_INTERFACE, DotMenuStock.GROUP_CONTROLS] as Array[StringName])
	# One binding setting per key the client reads ([PlaygroundBindings]), so the Controls page
	# can move every one and the help screen shows where each is now.
	PlaygroundBindings.make().add_to_schema(s)
	return s


## The camera motion settings, in [method PlaygroundPlayer.set_camera_motion_scales]' order,
## with what each moves. No wall-run lean: no movement style here runs on walls.
const CAMERA_MOTION_KEYS := {
	&"camera_landing_dip": "How far the view dips when you land from a height. All the way left is off.",
	&"camera_strafe_roll": "How far the view leans into a strafe. All the way left is off.",
	&"camera_speed_fov": "How much the view widens when you go faster than a run. All the way left is off.",
}


## Points every [PlaygroundPresentation] made after this at a fresh, empty settings
## directory named [param tag], and returns it.
##
## [b]For a suite or a render tool, never a player.[/b] `headless_presentation` drove the
## Escape menu's volume to 0.15 through the real `user://playground_settings`, so every
## real session after a test run started nearly silent. Swapping the store after
## [method setup] is too late for a tool, which has already drawn from what the player
## saved; a scratch directory emptied first means a run starts from the defaults.
static func use_scratch_settings(tag: String) -> String:
	var dir := "user://scratch/%s" % tag
	var abs_dir := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(abs_dir):
		for f in DirAccess.get_files_at(abs_dir):
			var _gone := DirAccess.remove_absolute(abs_dir.path_join(f))
	else:
		var _made := DirAccess.make_dir_recursive_absolute(abs_dir)
	settings_directory = dir
	return dir


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


# --- Audio ------------------------------------------------------------------

## What a sandbox makes a noise about, which is mostly other people building.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()
	DotAudioStock.add_to(c)

	var spawn := DotAudioDef.new()
	spawn.id = &"prop_spawn"
	spawn.path = "%s/prop_spawn.ogg" % SOUND_DIR
	spawn.kind = DotAudioDef.Kind.POSITIONAL_3D
	spawn.bus = &"SFX"
	spawn.max_distance = 60.0
	# A player emptying a Q menu spawns several a second, and a sandbox server has a
	# dozen people doing it. Three at once is a building site; twelve is a fault.
	spawn.max_concurrent = 3
	spawn.cooldown_ms = 80
	spawn.priority = 40
	spawn.pitch_min = 0.92
	spawn.pitch_max = 1.08
	c.add(spawn)

	var land := DotAudioDef.new()
	land.id = &"prop_land"
	land.path = "%s/prop_land.ogg" % SOUND_DIR
	land.kind = DotAudioDef.Kind.POSITIONAL_3D
	land.bus = &"SFX"
	land.max_distance = 45.0
	land.max_concurrent = 4
	land.cooldown_ms = 50
	land.priority = 30
	c.add(land)

	# Something going into a liquid: a person jumping in, a crate thrown in.
	var splash := DotAudioDef.new()
	splash.id = &"splash"
	splash.path = "%s/splash.ogg" % SOUND_DIR
	splash.kind = DotAudioDef.Kind.POSITIONAL_3D
	splash.bus = &"SFX"
	splash.max_distance = 50.0
	splash.max_concurrent = 3
	splash.cooldown_ms = 80
	splash.priority = 35
	splash.pitch_min = 0.55
	splash.pitch_max = 0.75
	c.add(splash)

	# A pane of glass going: loud, far, and never more than two at once, because a blast
	# through a greenhouse breaks a dozen panes in one tick.
	var glass := DotAudioDef.new()
	glass.id = &"glass_break"
	glass.path = "%s/glass_break.ogg" % SOUND_DIR
	glass.kind = DotAudioDef.Kind.POSITIONAL_3D
	glass.bus = &"SFX"
	glass.max_distance = 70.0
	glass.max_concurrent = 2
	glass.cooldown_ms = 60
	glass.priority = 50
	glass.pitch_min = 1.3
	glass.pitch_max = 1.7
	c.add(glass)

	var grab := DotAudioDef.new()
	grab.id = &"tool_grab"
	grab.path = "%s/tool_grab.ogg" % SOUND_DIR
	grab.bus = &"UI"
	grab.cooldown_ms = 120
	grab.priority = 60
	c.add(grab)

	var punt := DotAudioDef.new()
	punt.id = &"tool_punt"
	punt.path = "%s/tool_punt.ogg" % SOUND_DIR
	punt.bus = &"SFX"
	punt.kind = DotAudioDef.Kind.POSITIONAL_3D
	punt.max_distance = 70.0
	punt.priority = 70
	c.add(punt)

	var buy := DotAudioDef.new()
	buy.id = &"buy"
	buy.path = "%s/buy.ogg" % SOUND_DIR
	buy.bus = &"UI"
	buy.priority = 80
	c.add(buy)

	var refused := DotAudioDef.new()
	refused.id = &"refused"
	refused.path = "%s/refused.ogg" % SOUND_DIR
	refused.bus = &"UI"
	refused.cooldown_ms = 200
	# Above a prop landing, because a refusal is the answer to something the player just
	# did and a crate hitting the floor is not.
	refused.priority = 85
	c.add(refused)

	# The map vote's cues. Flat, on the interface bus: a ballot is about the server, not
	# about a place in it. The ids are PlaygroundVote's, which its rules name too.
	for vote_id in [
		PlaygroundVote.CUE_START, PlaygroundVote.CUE_END,
		PlaygroundVote.CUE_WARNING, PlaygroundVote.CUE_COUNT,
	]:
		var cue := DotAudioDef.new()
		cue.id = vote_id
		cue.path = "%s/%s.ogg" % [SOUND_DIR, String(vote_id)]
		cue.bus = &"UI"
		cue.max_concurrent = 1
		cue.priority = 70
		c.add(cue)

	# An administrator's beacon: a ping once a second from the beaconed player, heard by
	# everybody. Positional, because the beacon's whole job is to say WHERE somebody is and
	# a flat ping would say only that somebody somewhere is beaconed. And the furthest
	# reach in this table — a sandbox is two hundred metres across and a beacon that went
	# quiet halfway would fail in the one case it is for. Pitched an octave under the vote's
	# warning, which shares its voice, so a ping is never heard as a ballot closing.
	var ping := DotAudioDef.new()
	ping.id = BEACON_SOUND
	ping.path = "%s/beacon.ogg" % SOUND_DIR
	ping.kind = DotAudioDef.Kind.POSITIONAL_3D
	ping.bus = &"SFX"
	ping.unit_size = 20.0
	ping.max_distance = 160.0
	ping.max_concurrent = 4
	ping.priority = 45
	ping.pitch_min = 0.5
	ping.pitch_max = 0.5
	c.add(ping)

	var wave := DotAudioDef.new()
	wave.id = &"wave_incoming"
	wave.path = "%s/wave.ogg" % SOUND_DIR
	wave.bus = &"UI"
	wave.priority = 100
	c.add(wave)

	# A body landing: dot-player-char's stock death sounds (Kenney, CC0), shipped in the addon.
	for row: Dictionary in DotPlayerDeathSounds.rows():
		var fall := DotAudioDef.new()
		fall.id = row["id"]
		fall.path = row["path"]
		fall.variants = row["variants"]
		fall.kind = DotAudioDef.Kind.POSITIONAL_3D
		fall.bus = &"SFX"
		fall.unit_size = 8.0
		fall.max_distance = 45.0
		fall.max_concurrent = 3
		fall.priority = 50
		fall.gain_db = float(row["gain_db"])
		fall.pitch_min = float(row["pitch_min"])
		fall.pitch_max = float(row["pitch_max"])
		fall.cooldown_ms = int(row["cooldown_ms"])
		c.add(fall)

	# The map's toys: dot-props' stock toy sounds (Kenney, CC0, and a horn made for it), shipped
	# in the addon, each carrying as far as its row says.
	for row: Dictionary in DotPropToySounds.rows():
		var toy := DotAudioDef.new()
		toy.id = row["id"]
		toy.path = row["path"]
		toy.variants = row["variants"]
		toy.kind = DotAudioDef.Kind.POSITIONAL_3D
		toy.bus = &"SFX"
		toy.unit_size = 6.0
		toy.max_distance = float(row["distance"])
		toy.max_concurrent = 4
		toy.priority = 40
		toy.gain_db = float(row["gain_db"])
		toy.pitch_min = float(row["pitch_min"])
		toy.pitch_max = float(row["pitch_max"])
		toy.cooldown_ms = int(row["cooldown_ms"])
		c.add(toy)

	return c


## Which synthesised voice stands in for each id until real audio is dropped into
## [constant SOUND_DIR].
##
## [b]A sandbox makes noise for a different reason than a shooter does.[/b] Almost nothing
## here is information a player has to act on — it is confirmation that the thing they just
## did happened, which is why `refused` gets a voice of its own rather than silence: a buy
## that does nothing and a buy that was refused are indistinguishable without it.
##
## `wave_incoming` is the exception and is the only ominous sound in the table, because it
## is the one thing in this game that arrives whether the player asked for it or not.
static func sound_recipes() -> Dictionary:
	return {
		&"prop_spawn": DotAudioSynth.Voice.SPAWN,
		&"prop_land": DotAudioSynth.Voice.IMPACT,
		&"glass_break": DotAudioSynth.Voice.SHOT_TIGHT,
		&"splash": DotAudioSynth.Voice.SHOT_HEAVY,
		&"tool_grab": DotAudioSynth.Voice.CLICK,
		&"tool_punt": DotAudioSynth.Voice.SHOT,
		&"buy": DotAudioSynth.Voice.PICKUP,
		&"refused": DotAudioSynth.Voice.DENY,
		&"wave_incoming": DotAudioSynth.Voice.BOOM,
		# Voices nothing else in the table uses, so a ballot opening is never heard as a
		# prop arriving or a refusal.
		PlaygroundVote.CUE_START: DotAudioSynth.Voice.SHOT_TIGHT,
		PlaygroundVote.CUE_END: DotAudioSynth.Voice.DIE,
		PlaygroundVote.CUE_WARNING: DotAudioSynth.Voice.BLIP,
		PlaygroundVote.CUE_COUNT: DotAudioSynth.Voice.STEP,
		BEACON_SOUND: DotAudioSynth.Voice.BLIP,
		# Stand-ins only for a build without dot-props' toy files.
		DotPropToySounds.BOUNCE: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.THUMP: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.KNOCK: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.PIN: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.WOOD: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.RUBBER: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.PUNCH: DotAudioSynth.Voice.HURT,
		DotPropToySounds.METAL: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.BELL: DotAudioSynth.Voice.PICKUP,
		DotPropToySounds.CLICK: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.WATER: DotAudioSynth.Voice.STEP,
		DotPropToySounds.BOING: DotAudioSynth.Voice.SPAWN,
		DotPropToySounds.HORN: DotAudioSynth.Voice.BLIP,
		# Stand-ins only for a build without dot-player-char's files.
		DotPlayerDeathReactions.SOUND_THUD: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_FACE_PLANT: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_SLUMP: DotAudioSynth.Voice.STEP,
		DotPlayerDeathReactions.SOUND_WHOOSH: DotAudioSynth.Voice.SPAWN,
	}


func _build_audio() -> DotResult:
	audio = DotAudioManager.new()
	audio.name = "Audio"
	audio.catalogue = sound_catalogue()
	audio.mixer = DotAudioMixer.new()
	audio.mixer.master = settings.get_float(&"master_volume", 0.8)
	audio.voices = 24
	# Measured toward the family's -17 LUFS (dot-audio docs/loudness.md) with the local player
	# driven by tools/loudness_pilot.gd: walking the lobby, spawning crates, barrels and balls
	# and punting them with the gravity gun. At +6 that read -22.5 LUFS; at +12 two runs read
	# -17.5. The +6 before came from a stand-in that built nothing (-24.6, the empty room).
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
	# Held back under the trim: a sandbox is mostly somebody building, and the bed is the
	# room it happens in, not the thing to listen to.
	ambience.level = 0.8
	add_child(ambience)
	ambience.set_map_bed(bed_for(&""))

	# Only on a real sink, and only after setup: the manager decides whether there is a
	# device, and on a headless server there is nothing to bake for. Building the bank
	# anyway would be arithmetic per dedicated-server startup for streams no process on
	# that machine can play.
	var godot_sink := audio.sink as DotAudioSinkGodot
	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(audio.catalogue, sound_recipes())
		DotLog.info(
			CHANNEL,
			"no audio files; synthesised stand-ins are in use",
			{"ids": sound_recipes().size(), "dir": SOUND_DIR}
		)

	return DotResult.success(null)


# --- Effects ----------------------------------------------------------------

static func fx_catalogue() -> DotFxCatalogue:
	var c := DotFxCatalogue.new()

	var puff := DotFxDef.new()
	puff.id = &"prop_spawn"
	puff.scene_path = "%s/spawn_puff.tscn" % FX_DIR
	puff.lifetime_ms = 450
	puff.cost = 2
	puff.priority = 40
	puff.max_distance = 60.0
	puff.max_concurrent = 8
	puff.min_quality = 1
	c.add(puff)

	var beam := DotFxDef.new()
	beam.id = &"tool_beam"
	beam.kind = DotFxDef.Kind.BEAM
	beam.scene_path = "%s/tool_beam.tscn" % FX_DIR
	beam.lifetime_ms = 100
	beam.cost = 1
	beam.priority = 75
	beam.max_distance = 0.0
	c.add(beam)

	var punt := DotFxDef.new()
	punt.id = &"punt_shake"
	punt.kind = DotFxDef.Kind.SHAKE
	punt.shake_trauma = 0.22
	c.add(punt)

	var wave := DotFxDef.new()
	wave.id = &"wave_flash"
	wave.kind = DotFxDef.Kind.SCREEN
	wave.flash_peak = 0.2
	wave.flash_colour = Color(0.95, 0.55, 0.2)
	wave.flash_decay_ms = 450
	c.add(wave)

	return c


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

	var res := fx.setup()
	if not res.ok:
		return res.wrap("the playground's effects")

	# [b]Said out loud, because a missing scene is otherwise a DEBUG line.[/b] Until
	# 2026-09-27 neither scene this catalogue names existed, and every spawn puff was
	# refused in silence. `headless_presentation` asserts the list is empty; this is for
	# a build that lost one anyway.
	var missing := fx.catalogue.missing_scenes()
	if not missing.is_empty():
		DotLog.warn(CHANNEL, "effect scenes missing; those effects will not draw", {
			"paths": ", ".join(missing),
		})
	return DotResult.success(null)


# --- Console ----------------------------------------------------------------

# --- Chat -------------------------------------------------------------------

## The box a player types in, and the three settings that decide it.
##
## [b]The channels come from [code]PlaygroundServices.chat_channels[/code], not from a
## list here.[/b] Two copies of one list is this tree's most repeated bug; the server
## routes with those definitions and the composer offers exactly what it routes. The
## admin channel is filtered out because it is admin-only and a channel a player cannot
## send on is a channel that should not be in the cycle.
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
## Empty is left alone rather than applied: a settings file somebody cleared the field in
## would otherwise unbind chat with no way to get it back from inside the game.
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
## `on` is both halves at once — a relayed server AND a box in front of the game. `off` is
## a player who chats somewhere else. `auto` draws it unless this server is already putting
## these lines somewhere this player can see them. In every case the log keeps drawing what
## other people said.
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


## dot-console's kit: `help`, `clear`, `settings`, every setting by its own name, the
## in-process server's console, and the panel on layer 128, registered with [param menu].
## This game adds `quit` and `seed`, ahead of the server's console so a listen server's own
## `quit` is not the one that answers.
##
## Called by [PlaygroundClient] after its [DotMenu] exists, not from [method setup]: the
## menu is built from this layer's settings, and the kit makes the console one of the
## menu's overlays, which is what stops the player. A console that is not an overlay walks
## the player while they type: the sampler polls the keys, and a focused line edit does
## not stop `Input.is_action_pressed`.
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
	console.add_source(_local_commands())
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


func camera_shake() -> Vector3:
	return fx.shake.offset()


## Whether something on screen owns the keyboard right now.
##
## [b]The chat box belongs here for the reason the console does.[/b] A client that keeps
## reading movement while somebody types walks them across the map, and in a sandbox it
## also fires whatever tool they are holding at whatever they were building.
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


## The physics gun's beam, from in front of the eye to what it holds, this frame.
##
## [b]One node, moved every frame, not one spawned per frame.[/b] `tool_beam` lives
## 100 ms, and a spawn a frame would stack six additive beams at 60 fps and a different
## number at every other frame rate. The 100 ms is still the ceiling: when it retires the
## node, the next frame spawns another, so a beam nobody updates is gone within it. Call
## it after [method present], which is where the retiring happens, and there is no gap.
##
## [param key] says whose: a connected client draws one per player holding something, each
## moved every frame on its own node, so two people building side by side are two beams.
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


func on_pane_broken(at: Vector3) -> void:
	audio.play_at(&"glass_break", at)


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


func on_wave_incoming() -> void:
	audio.play(&"wave_incoming")
	fx.flash(&"wave_flash")


func on_map_changed(map_id: StringName = &"") -> void:
	fx.clear()
	if ambience != null:
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
	out.append_array(fx.describe_lines())

	if chat_window != null:
		out.append("chat box: %s" % str(chat_window.describe()))
	return out
