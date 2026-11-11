extends Node

const PlaygroundWeaponIcons := preload("playground_weapon_icons.gd")
const PlaygroundAmbience := preload("playground_ambience.gd")
const PlaygroundBindings := preload("playground_bindings.gd")
const PlaygroundPaths := preload("playground_paths.gd")
const PlaygroundProfiles := preload("playground_profiles.gd")

const PlaygroundServices := preload("playground_services.gd")
const PlaygroundVote := preload("playground_vote.gd")

## Settings, randomness, audio, effects and a console. This is the only game that holds dot-randomness as well:
## the generated map, props and wave composition come from one seed. The manager is here rather than in
## `Playground` because it owns the session's seed, and `Playground` must run without it.

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

## Quiet moods under the map (dot-audio's stock set); the old bed plays only when none loaded.
var ambient: DotAmbienceDirector = null
const BreakFx := preload("playground_break_fx.gd")

## Splinters and shards where props and panes break.
var break_fx: Node = null
var fx: DotFxManager = null
## Blood on the surface behind a hit body. Visual only; the player's `gore` setting and `fx_quality` scale it.
var blood: DotFxBlood = null
## [member blood]'s decal pool.
var decals: DotFxDecals = null
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


# --- Settings ---------------------------------------------------------------

static func schema() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION

	s.add(DotSettingsDef.number(&"master_volume", 0.8, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"sfx_volume", 1.0, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"voice_volume", 1.0, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.boolean(&"ambient", true, &"audio").with_description("Quiet sounds under the map."))
	s.add(DotSettingsDef.number(&"ambient_volume", 1.0, 0.0, 1.0, &"audio"))

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
	s.add(DotSettingsDef.boolean(&"gore", true, &"video").with_description(
		"Blood splatters on the walls behind a hit player or NPC."
	))

	s.add(DotSettingsDef.number(&"shake_scale", 1.0, 0.0, 2.0, &"accessibility")
		.with_description("Zero turns camera shake off entirely."))
	s.add(DotSettingsDef.boolean(&"allow_flashes", true, &"accessibility"))

	# Camera motion, each 0 (off) to 2, 1 the game's pick (`PlaygroundPlayer.camera_motion_picks`).
	# ACCOUNT: motion sickness is about the person; one each, as the lean and the dip differ.
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
	# The window, the frame rate, the theme and the counter: dot-menu's stock settings, applied by the client's
	# DotMenuApplier and DotMenu. GROUP_CONTROLS adds `invert_mouse` (sensitivity is declared above), which the
	# applier inverts the sampler's look with.
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


## Points every [PlaygroundPresentation] made after this at a fresh, empty settings directory named [param tag], and
## returns it. For a suite or a render tool, never a player: a suite once drove the real
## `user://playground_settings` volume to 0.15 and left every real session nearly silent.
static func use_scratch_settings(tag: String) -> String:
	# One directory per process: user:// is shared by every run on the machine, and a concurrent run wiping or rewriting
	# a shared directory re-binds keys and resets values under the other run. Directories of dead processes are swept.
	_sweep_dead_scratch()
	var dir := "user://scratch/%s_%d" % [tag, OS.get_process_id()]
	var abs_dir := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(abs_dir):
		for f in DirAccess.get_files_at(abs_dir):
			var _gone := DirAccess.remove_absolute(abs_dir.path_join(f))
	else:
		var _made := DirAccess.make_dir_recursive_absolute(abs_dir)
	settings_directory = dir
	return dir


## Removes the scratch settings directories (`<tag>_<pid>`) whose process has exited.
static func _sweep_dead_scratch() -> void:
	var root := ProjectSettings.globalize_path("user://scratch")
	for name in DirAccess.get_directories_at(root):
		var pid_text := name.get_slice("_", name.get_slice_count("_") - 1)
		if not pid_text.is_valid_int() or DirAccess.dir_exists_absolute("/proc/%s" % pid_text):
			continue
		var abs_dir := root.path_join(name)
		for f in DirAccess.get_files_at(abs_dir):
			var _gone := DirAccess.remove_absolute(abs_dir.path_join(f))
		var _removed := DirAccess.remove_absolute(abs_dir)


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

	_add_tool_cues(c)
	_add_service_cues(c)
	_add_body_sounds(c)
	return c


## The grab, undo, punt, buy and refusal cues, split out of [method sound_catalogue].
static func _add_tool_cues(c: DotAudioCatalogue) -> void:
	var grab := DotAudioDef.new()
	grab.id = &"tool_grab"
	grab.path = "%s/tool_grab.ogg" % SOUND_DIR
	grab.bus = &"UI"
	grab.cooldown_ms = 120
	grab.priority = 60
	c.add(grab)

	_add_undo_cues(c)

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


## The vote, beacon and wave cues, split out of [method sound_catalogue].
static func _add_service_cues(c: DotAudioCatalogue) -> void:
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

	# An administrator's beacon: a ping a second from the beaconed player, heard by everybody and positional, because
	# it says WHERE somebody is. The furthest reach in this table, an octave under the vote's warning, which shares
	# its voice, so a ping is never heard as a ballot closing.
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


## Falling bodies and map toys, split out of [method sound_catalogue].
static func _add_body_sounds(c: DotAudioCatalogue) -> void:
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
	for row: Dictionary in DotPropBodySounds.rows():
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


## The undo cue and its positional twin, split out of [method sound_catalogue] to keep it short.
static func _add_undo_cues(c: DotAudioCatalogue) -> void:
	var undo := DotAudioDef.new()
	undo.id = &"undo"
	undo.path = "%s/undo.ogg" % SOUND_DIR
	undo.bus = &"UI"
	undo.cooldown_ms = 120
	undo.priority = 60
	undo.pitch_min = 0.7
	undo.pitch_max = 0.8
	c.add(undo)

	var undo_at := DotAudioDef.new()
	undo_at.id = &"undo_at"
	undo_at.path = "%s/undo.ogg" % SOUND_DIR
	undo_at.kind = DotAudioDef.Kind.POSITIONAL_3D
	undo_at.bus = &"SFX"
	undo_at.cooldown_ms = 120
	undo_at.priority = 60
	undo_at.pitch_min = 0.7
	undo_at.pitch_max = 0.8
	c.add(undo_at)


## Which synthesised voice stands in for each id until real audio is dropped into [constant SOUND_DIR].
## Almost nothing here is information to act on, only confirmation, so `refused` gets a voice of its own; `wave_incoming`
## is the only ominous one, because it arrives whether the player asked or not.
static func sound_recipes() -> Dictionary:
	return {
		&"prop_spawn": DotAudioSynth.Voice.SPAWN,
		&"prop_land": DotAudioSynth.Voice.IMPACT,
		&"glass_break": DotAudioSynth.Voice.SHOT_TIGHT,
		&"splash": DotAudioSynth.Voice.SHOT_HEAVY,
		&"tool_grab": DotAudioSynth.Voice.CLICK,
		&"undo": DotAudioSynth.Voice.SPAWN,
		&"undo_at": DotAudioSynth.Voice.SPAWN,
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
		DotPropBodySounds.BOUNCE: DotAudioSynth.Voice.IMPACT,
		DotPropBodySounds.THUMP: DotAudioSynth.Voice.IMPACT,
		DotPropBodySounds.KNOCK: DotAudioSynth.Voice.IMPACT,
		DotPropBodySounds.PIN: DotAudioSynth.Voice.CLICK,
		DotPropBodySounds.WOOD: DotAudioSynth.Voice.IMPACT,
		DotPropBodySounds.RUBBER: DotAudioSynth.Voice.IMPACT,
		DotPropBodySounds.PUNCH: DotAudioSynth.Voice.HURT,
		DotPropBodySounds.METAL: DotAudioSynth.Voice.CLICK,
		DotPropBodySounds.BELL: DotAudioSynth.Voice.PICKUP,
		DotPropBodySounds.CLICK: DotAudioSynth.Voice.CLICK,
		DotPropBodySounds.WATER: DotAudioSynth.Voice.STEP,
		DotPropBodySounds.BOING: DotAudioSynth.Voice.SPAWN,
		DotPropBodySounds.HORN: DotAudioSynth.Voice.BLIP,
		# Stand-ins only for a build without dot-player-char's files.
		DotPlayerDeathReactions.SOUND_THUD: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_FACE_PLANT: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_SLUMP: DotAudioSynth.Voice.STEP,
		DotPlayerDeathReactions.SOUND_WHOOSH: DotAudioSynth.Voice.SPAWN,
	}

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

	AwGrenadeFx.add_defs(c)

	return c


## Pushes the player's `gore` and `fx_quality` into the decals; env and command line
## (`DOT_FX_DECAL_*`, `--decal-*`) layer under them through the config's own loader.
