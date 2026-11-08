extends Node


const Playground := preload("playground.gd")
const PlaygroundBindings := preload("playground_bindings.gd")
const PlaygroundProp := preload("playground_prop.gd")
const PlaygroundBrowser := preload("client/playground_browser.gd")
const PlaygroundConfig := preload("playground_config.gd")
const PlaygroundHud := preload("playground_hud.gd")
const PlaygroundNetBridge := preload("net/playground_net_bridge.gd")
const PlaygroundPlayer := preload("playground_player.gd")
const PlaygroundPresentation := preload("playground_presentation.gd")
const PlaygroundIcons := preload("playground_icons.gd")
const PlaygroundViewGrip := preload("playground_view_grip.gd")
const PlaygroundServices := preload("playground_services.gd")
const PlaygroundProfileScreen := preload("playground_profile_screen.gd")
const PlaygroundMapEditView := preload("playground_map_edit_view.gd")
const PlaygroundSpawnMenu := preload("playground_spawn_menu.gd")
const PlaygroundVoice := preload("client/playground_voice.gd")
const PlaygroundWeapon := preload("weapons/playground_weapon.gd")
const PlaygroundWeapons := preload("playground_weapons.gd")
const PlaygroundZee := preload("playground_zee.gd")
const PlaygroundWeaponDef := preload("weapons/playground_weapon_def.gd")

## Boots a playable playground: one local player, a camera, a HUD, a spawn menu and the keys
## (listed in docs/client.md). Separate from [Playground], the simulation: a dedicated server
## never loads this.

const CHANNEL := "playground.client"

## Where dot-server's client publishes its [DotClientLink] before a game scene loads.
const LINK_SERVICE := &"dot_client_link"

## Ids the tools are addressed by, here and in [PlaygroundSpawnMenu].
const TOOL_PHYS := &"phys"
const TOOL_GRAV := &"grav"
const TOOLGUN := &"toolgun"
## The tool gun mode that edits a selected prop (`game/toolgun/tool_edit.gd`).
const EDIT_MODE := &"edit"

## How long Q may be held before releasing it closes the menu: a tap pins it open, a hold is a
## glance. A quarter of a second is longer than a click and shorter than a look.
const MENU_TAP_SECONDS := 0.25

## Where a spawned prop appears, in metres in front of the eye.
const SPAWN_REACH := 3.0

## The map to open on if the configuration names none. A client has to be somewhere.
const FALLBACK_MAP := &"pg_flatgrass"

@export var player_id: StringName = &"local"

## What the last undo cue asked of the audio (tests read it).
var last_undo_cue: Dictionary = {}
@export var display_name: String = "Player"

## Configuration handed to the [Playground] this builds, or null for the defaults. Forwarded, not
## set afterwards: `Playground._ready` layers it and loads `initial_map` inside `add_child`.
@export var config: PlaygroundConfig = null

## A JSON file to layer over [member config]. Passed straight through.
@export var config_file: String = ""

## The dedicated server's client link, when this client is on a server. Set before this node enters
## the tree; with it the playground is a mirror (not authoritative, no player of its own, every
## action sent as intent), without it the local sandbox `headless_playground` drives.
@export var link: Node = null

var playground: Playground = null
## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var workbench_remote: DotGameWorkbenchRemoteClient = null
var net: DotNetManager = null
var bridge: PlaygroundNetBridge = null
var player: PlaygroundPlayer = null
var hud: PlaygroundHud = null

## The client half of chat: the channels, the history, the unread counts and the gap
## detection. It decides nothing — every rule is the server's.
var chat: DotChatClient = null

## The client half of voice. Every call on it is guarded, because "there is no microphone"
## is a legitimate machine rather than an error.
var voice: PlaygroundVoice = null

## What this client is on: health, armour, and the match clock. Drawn, never decided.
var health: int = 100
var armour: int = 0
var match_label: String = ""
var match_seconds: float = 0.0
var camera: Camera3D = null
## Keeps the screen covered, and the local body and the input still, until the level, the
## player and the camera are all in. See [method _build_gate].
var gate: DotLoadGate = null

## dot-game's platform layer: builds the gate, answers link and offline, flushes the browser's
## filesystem, and says when input is blocked. Not its settings, console, pointer or board.
var platform: DotGameClient = null
## Whether an offline client fetches the world's art slices and the locked pack; a suite sets it false so it needs no network.
var fetch_content: bool = true

## The player asked to leave from the pause menu. Announced, not acted on: what "leave" means
## belongs to whatever loaded this client (a shell, an embedded page, a development scene).
signal leave_requested()

var screens: DotScreenStack = null

## The escape menu: dot-menu's, with the settings behind it, help, the server list and
## Leave. See [method _build_pause]. Also holds the Tab scoreboard.
var game_menu: DotMenu = null

## What pushes the window, frame-rate and theme settings at the engine. The presentation
## applies its own (volumes, view, effects) as it always did.
var applier: DotMenuApplier = null
## Every key this client reads ([PlaygroundBindings]), as the player has it bound.
var keys: DotMenuBindings = null
var menu: PlaygroundSpawnMenu = null

## The server list, on the same stack as the spawn menu.
var browser: PlaygroundBrowser = null

## The admin workbench (F6): live NPC and weapon profile edits. Only an admin is let in.
var profile_screen: PlaygroundProfileScreen = null
## Staff's spawn point markers and form; null until first used.
var map_edit_view: PlaygroundMapEditView = null
var _profile_admin := false
var _profile_probing := false

## Settings, randomness, audio, effects and the console.
var presentation: PlaygroundPresentation = null

## Somebody picked a server in the browser. What a launcher connects to.
signal server_chosen(address: String)

## Which prop the spawn key places. Armed by the menu.
var selected_prop: StringName = &"crate"

## The tool gun mode and its settings, as last picked on the Q menu's tools tab.
var tool_mode: StringName = &"resize"
var tool_mode_settings: Dictionary = {}

## The prop the tool gun's edit mode has selected — this client's own copy of it, the mirror
## when connected — or null. Highlighted by [member _selection_box].
var edit_target: Node3D = null
var _selection_box: MeshInstance3D = null

## Which tool is in hand: [constant TOOL_PHYS], [constant TOOL_GRAV], or a weapon id.
var tool: StringName = TOOL_PHYS

## The weapon in hand, when [member tool] is neither built-in gun. Instantiated per equip, not
## pooled: a weapon has state (charge, cooldown) a shared instance would carry between hands.
var weapon: PlaygroundWeapon = null

## The hands and the gun, under the first-person camera, while a zee weapon is in them.
var zee_view: Node3D = null

## The model of a toy or tool in hand (physics gun, launcher, tool gun, ...); null with a zee gun.
var toy_view: Node3D = null

## Fire, alt and reload for a zee weapon offline, as command bits. A connected client sends
## the same bits in [member _net_buttons] instead, and the server runs the shot.
var _zee_buttons: int = 0
## The Aim key held with a zee gun in hand (`PlaygroundBindings.AIM`, right mouse): the hands
## come up and the lens zooms. Presentation only.
var _aiming: bool = false

## Whether the pointer was a look input at the last frame; see the click branch of
## `_unhandled_input`, and the 'Click to play' notice in `_process`.
var _was_driving: bool = false

## Whether the physics gun's button is down.
var _holding: bool = false
var _wheel: DotWeaponWheel

## Whether the gravity gun is pulling.
var _pulling: bool = false

## Whether Shift is down, which turns mouse motion into prop rotation.
var _rotating: bool = false

## When Q went down, so a release can tell a tap from a hold.
var _menu_down_at: float = 0.0

## Whether the menu is up because it was tapped rather than because Q is still down.
var _menu_pinned: bool = false

## Input sampling, on a networked client only. A local player samples through their own
## [DotFpsSampler]; a networked one is handed a command by this loop instead, because
## the command has to be stamped for a tick and kept for reconciliation.
var _sampler: DotFpsSampler = null

## The phone's on-screen buttons; null off a touch device.
var _touch: PlaygroundTouch = null

## The tool triggers, as command buttons. Held rather than edge-triggered: the server decides what
## a press and a hold each mean (PlaygroundNetBridge._drive_tools), and a client sending only
## edges would drop one to packet loss and leave a player holding a crate they let go of.
var _net_buttons: int = 0


## Hands world events to the presentation layer. On a networked client only YOUR props make a noise:
## the join backlog replays every existing prop through the same PROP event.
## The load gate: the screen stays covered, and the body and input stay still, until the level, player and camera are ready.
func _build_gate() -> void:
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = link == null and OS.get_cmdline_user_args().has("--offline")
	platform.link = link
	platform.use_standalone_content = fetch_content
	platform.use_locked_content = fetch_content
	# Not built by the platform: the settings document is PlaygroundPresentation's (handed over by `adopt_menu`) and the console follows that menu.
	# The pointer is the platform's except while the Q menu or server browser is up; Tab is the roster's, not the platform's board.
	platform.use_settings = false
	platform.use_console = false
	platform.escape_releases_pointer = true
	platform.pointer_fn = func() -> bool:
		return screens == null or not screens.any_open()
	platform.scoreboard_action = &""
	platform.spawned_fn = func() -> bool:
		return player != null and camera != null and camera.is_inside_tree()
	# The chat box, the console and the menu have the keyboard; polled by the platform each
	# frame, so there is no signal to forward from each of them.
	platform.busy_fn = _input_busy
	add_child(platform)
	gate = platform.gate
	gate.name = "LoadGate"
	gate.hold(&"map", "Loading the map")
	platform.input_blocked_changed.connect(_suspend_input)


## Releases the map hold once the first level is in, and holds again for each map change.
## Connected to `changing` (before the old level goes) and `changed` (the new one is built).
func _wire_gate_to_maps() -> void:
	gate.release(&"map")
	playground.maps.changing.connect(
		func(_from: DotMapDef, _to: DotMapDef) -> void: gate.hold(&"map", "Loading the map")
	)
	playground.maps.changed.connect(
		func(_map: DotMapDef, _loaded: Node) -> void: gate.release(&"map")
	)


## True while the load gate covers the screen: no input, no tool, no prediction.
func _covered() -> bool:
	return gate != null and not gate.is_open()


const VIEW_NAMES := {&"fp": "first person", &"tp": "third person", &"selfie": "selfie"}

const VIEW_ARMS_SCRIPT := "res://addons/dot_player_char/nodes/dot_player_view_arms.gd"

## The camera of the `selfie` view, left standing where the player was.
var selfie_camera: Camera3D = null
## Yaw-only pivot at the eye; the downed first-person arms hang under it, not the pitching camera.
var arms_pivot: Node3D = null
var view_arms: Node = null
## Where the arms hold the zee weapon in hand (dot-player-char API 8); null with nothing held.
var held_grip: DotViewGrip = null
var _arms_down := false


## The downed player's own arms (dot-player-char API 7); nothing on an older build.
func _build_view_arms() -> void:
	if DotAddonApi.build_level("dot_player_char") < 7 or not ResourceLoader.exists(VIEW_ARMS_SCRIPT):
		return
	arms_pivot = Node3D.new()
	arms_pivot.name = "ArmsYaw"
	arms_pivot.top_level = true
	player.add_child(arms_pivot)
	view_arms = load(VIEW_ARMS_SCRIPT).new()
	view_arms.name = "ViewArms"
	arms_pivot.add_child(view_arms)
	view_arms.call("build")


## Joins the chat box to the three things it needs, the sampler too: movement is POLLED, so
## without `suspended` typing "sw" walks the player back. dot-server's `chat_received` feeds only
## the server's own lines; a PLAYER's line goes through this game's wire, so both would draw twice.
func _wire_chat_window() -> void:
	var window: DotChatWindow = presentation.chat_window if presentation != null else null

	if window == null:
		return

	window.submitted.connect(_on_chat_submitted)
	window.opened.connect(func(_channel: StringName) -> void: platform.refresh_blocked())
	window.closed.connect(func() -> void: platform.refresh_blocked())

	var client_link := DotRegistry.get_service(&"dot_client_link")

	if client_link != null and client_link.has_signal("chat_received"):
		client_link.connect("chat_received", _on_server_chat_state)


## dot-server's chat payload: the server's own lines (a vote between games, "Ada joined the game.",
## an admin's `say`) come only this way. A player's line is never drawn from here; this game
## routes those over its own wire.
func _on_server_chat_state(payload: Dictionary) -> void:
	if str(payload.get("kind", "")) != "state":
		var window: DotChatWindow = presentation.chat_window if presentation != null else null
		var _drawn := DotGameChatClient.draw_server_line(window, payload)
		return

	if presentation != null:
		presentation.set_chat_relayed(bool(payload.get("relay", false)))


## What a player typed, on its way to the server. Nothing is filtered here: the server decides
## what a line may contain and its answer is the only one that counts.
func _on_chat_submitted(text: String, channel: StringName) -> void:
	if bridge != null:
		bridge.say(channel, text)
		return

	# No bridge is a single-player sandbox, where there is no server to decide anything.
	# Drawing it locally is better than a box that swallows what you type.
	if presentation != null and presentation.chat_window != null:
		presentation.chat_window.add_said("You", text, Color(0.62, 0.78, 1.0))


## A routed line off this game's own wire, filed by [DotChatClient] — which drops a
## duplicate and reports a gap.
func _on_chat_wire(wire: Dictionary) -> void:
	if chat != null:
		chat.receive(wire)


## A line [DotChatClient] accepted: in sequence, not a duplicate, on a known channel.
##
## The channel, a [DotChatChannel] both ends share, decides the prefix and colour.
func _on_chat_message(message: DotChatMessage, channel_id: StringName) -> void:
	if hud == null:
		return

	var chan := chat.channel(channel_id)
	var prefix := "%s " % chan.prefix if chan != null and chan.prefix != "" else ""

	var window: DotChatWindow = presentation.chat_window if presentation != null else null
	var colour := chan.colour if chan != null else Color(0.88, 0.90, 0.94)

	# In the chat box, and on the notice line only when there is no box: the notice line keeps what
	# is the game's (budget reached, a tool's refusal), never chat. A join or leave notice is a name
	# and no text, so `describe()` words it ("Guest 435 joined"); other kinds are drawn by their text.
	var text := message.describe() \
		if message.kind in [DotChatMessage.Kind.JOIN, DotChatMessage.Kind.LEAVE] \
		else message.text

	if message.is_from_server() or message.sender_name == "":
		if window != null:
			window.add_text("%s%s" % [prefix, text], Color(0.80, 0.82, 0.86))
		else:
			hud.notice("%s%s" % [prefix, text])

		return

	if window != null:
		window.add_said("%s%s" % [prefix, message.sender_name], message.text, colour)
	else:
		hud.notice("%s%s: %s" % [prefix, message.sender_name, message.text])


## The hit drawn on the body the server says was hit: zee's red burst at [param point], for a body
## the presentation ray never meets (a target hit through the server's hitboxes). The rig skips a
## second drawing of a hit the ray drew. Via `has_method`: an older shell's zee has no `play_body_hit`.
func _draw_body_hit(rig: Object, point: Vector3) -> void:
	if rig == null or not is_instance_valid(rig) or not rig.has_method(&"shot_fx"):
		return
	var fx: Object = rig.call(&"shot_fx")
	if fx == null or not fx.has_method(&"play_body_hit"):
		return
	var from: Vector3 = point + Vector3.UP
	if player != null and is_instance_valid(player):
		from = player.global_position + Vector3(0.0, 1.6, 0.0)
	fx.call(&"play_body_hit", point, point - from)


## Somebody's health changed, or they died. Drawn, never decided.
func _on_combat(state: Dictionary) -> void:
	# Anybody's body: down the way the server picked, up again with their health.
	var key := PlaygroundNetBridge._player_key(int(state["player_id"]))
	if bool(state["died"]):
		var _fell := fall(key, state.get("death"))
	elif int(state["health"]) > 0:
		rise(key)

	if int(state["player_id"]) != bridge.local_player_id:
		return

	if int(state["health"]) < health:
		platform.note_hit(float(health - int(state["health"])))
	health = int(state["health"])
	armour = int(state["armour"])
	if hud != null:
		hud.set_alive(health > 0)

	if bool(state["died"]) and hud != null:
		hud.notice("You were killed.")


## Where the dead lie: dot-player-char's ragdolls under the server's rules. Connected only:
## a solo sandbox has no arena and nobody dies.
var ragdolls: DotPlayerRagdolls = null


func _build_ragdolls() -> void:
	if ragdolls != null:
		return
	ragdolls = DotPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = playground.ragdoll_rules
	ragdolls.sound_fn = func(id: StringName, at: Vector3, volume: float) -> void:
		if presentation != null:
			var _played := presentation.on_body(id, at, volume)
	add_child(ragdolls)
	# A body on the old map's floor would hang in the new one's air.
	playground.map_ready.connect(func(_map: DotMapDef) -> void:
		ragdolls.clear()
		for id: Variant in playground.players.keys():
			rise(StringName(id))
	)


## [param id]'s body falls the way the server picked ([param death]; null is a plain drop),
## copied from the body this client draws, which stays hidden until [method rise]. Null when
## the style hides bodies or nobody here draws that body: your own in first person.
func fall(id: StringName, death: DotPlayerDeath) -> DotPlayerRagdoll:
	var who: PlaygroundPlayer = playground.players.get(id, null) if playground != null else null
	if who == null or ragdolls == null or who.character == null:
		return null
	var body := who.character.body()
	if body == null or not body.is_inside_tree() or not who.body_shown():
		return null
	_land_on_the_world()
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	var fell := ragdolls.spawn(body, death if death != null else DotPlayerDeath.new(), velocity)
	# The gun in the hand falls as a short-lived prop (sv_ragdoll_weapon_drop); the hand's copy hides.
	var held := who.zee_world as Node3D
	if held != null and is_instance_valid(held) and held.is_inside_tree() and held.visible:
		if ragdolls.drop_prop(held, velocity) != null:
			held.visible = false
	return fell


## The level is on `world` and props on their two layers; a body lands on those and on no
## player, so nobody trips on a corpse.
func _land_on_the_world() -> void:
	var stack := playground.player_stack
	if stack != null and stack.physics != null and stack.physics.layout != null:
		playground.ragdoll_rules.collision_mask = stack.physics.layout.mask_of(
			[&"world", &"prop", &"frozen_prop"] as Array[StringName])


## [param id] is alive again: the body a fall hid is drawn again where they now stand.
func rise(id: StringName) -> void:
	var who: PlaygroundPlayer = playground.players.get(id, null) if playground != null else null
	if who != null and who.character != null and who.character.body() != null:
		who.character.body().visible = true


## The match clock, taken from the wire: nothing ticks a mirroring client's [DotMatch], so
## `seconds_remaining()` would derive from a tick still zero.
func _on_match(state: Dictionary) -> void:
	match_label = str(state["label"])
	match_seconds = float(state["seconds_left"])


## Somebody picked a server in the browser. Announced, not acted on: connecting is the host
## application's, since a shell instantiating this scene already knows where a person plays.
func _on_server_chosen(address: String) -> void:
	server_chosen.emit(address)

	if hud != null:
		hud.notice("Chosen: %s" % address)


func _on_progress(state: Dictionary) -> void:
	if hud == null:
		return

	var mine := int(state["player_id"]) == bridge.local_player_id

	hud.notice("%s %s (%d)" % [
		"You earned" if mine else "Somebody earned",
		str(state["title"]),
		int(state["value"]),
	])


## Something other than the cover has the keyboard or the screen: the chat box, the console,
## or dot-menu's menu.
func _input_busy() -> bool:
	return (presentation != null and presentation.swallows_input()) \
		or (game_menu != null and game_menu.any_open())


## Movement stops while the cover, the chat box, the console or dot-menu's menu is up. Only
## when none is is it given back, so the console closing while the chat box is still open
## does not walk the player. Also called when a sampler is built, which starts unsuspended.
func _suspend_input(blocked: bool) -> void:
	var sampler := active_sampler()
	if sampler != null:
		sampler.suspended = blocked


## dot-team's block rules followed from the server, and the F9 tuning panel where this process hosts the game.
func _add_noblock_and_workbench() -> void:
	if link != null:
		DotLog.result(CHANNEL, "noblock", platform.add_noblock(playground, Callable(playground, "team_of_side")))
		_start_remote_workbench()
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.listen_host_fn = func() -> bool: return true
	PlaygroundWorkbenchSets.add_sets(wb, playground, func() -> bool: return arena_on)
	add_child(wb)
	var started := wb.start(playground.profiles.runtime)
	DotLog.result(CHANNEL, "the workbench", started)
	if started.ok and playground.config_binder != null:
		playground.config_binder.attach(playground.profiles.runtime)
	if started.ok and playground.flashlight_binder != null:
		playground.flashlight_binder.attach(playground.profiles.runtime)
	platform.add_workbench(wb)


## Online: no local trust and no panel until the server names this player an admin (sv_workbench_remote).
func _start_remote_workbench() -> void:
	if workbench_remote == null:
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.remote_client = workbench_remote
	wb.remote_fn = func() -> bool: return true
	wb.config = {"enabled": false}
	PlaygroundWorkbenchSets.add_sets(wb, playground, func() -> bool: return arena_on)
	add_child(wb)
	var started := wb.start(playground.profiles.runtime)
	DotLog.result(CHANNEL, "the remote workbench", started)
	if not started.ok:
		wb.queue_free()
		return
	platform.add_workbench(wb)


## The HUD in the menu's theme and at the player's HUD size, live (dot-menu's `follow_hud`,
## by name for a client shell older than it): Christian's first play test asked for a darker
## HUD a player can restyle in the menu. Whichever of the HUD and the menu comes second calls it.
func _follow_hud() -> void:
	if hud == null or game_menu == null:
		return
	if game_menu.has_method(&"follow_hud"):
		game_menu.call(&"follow_hud", hud, PlaygroundHud.piece_theme())
	# dot-timer's block is not a dot-ui piece: it takes the palette on every theme change.
	hud.apply_theme(game_menu.palette())
	if not game_menu.theme_changed.is_connected(hud.apply_theme):
		game_menu.theme_changed.connect(hud.apply_theme)


## This game's rows on dot-menu's General page: the sandbox's own, and the camera motion.
## Static so `tools/screenshot_menus` draws the page the client builds rather than a copy.
static func add_general_rows(game_menu: DotMenu) -> void:
	var settings := game_menu.settings
	var video := game_menu.page(&"video")
	DotMenuStock.add_gore_row(video)
	var general := game_menu.page(&"general")
	if general != null:
		general.section("Playground") \
			.add(DotMenuRow.toggle(&"hold_to_open_menu", "Hold the spawn-menu key", "Off: pressing it opens the spawn menu and pressing it again closes it.")) \
			.add(DotMenuRow.toggle(&"prop_sounds", "Prop sounds", "Crates, barrels and everything else you knock about."))
		# Camera motion beside the sandbox's own rows: the dip, the lean and the widening, each a
		# slider to Off for a player whom motion makes sick. The words are the settings' own.
		var motion := general.section("Camera motion")
		for row: Array in [
			[&"camera_landing_dip", "Landing dip"],
			[&"camera_strafe_roll", "Strafe lean"],
			[&"camera_speed_fov", "Speed widening"],
		]:
			var def: DotSettingsDef = settings.schema.find(row[0]) if settings != null else null
			var _added := motion.add(DotMenuRow.slider(row[0], row[1], def.description if def != null else "")
				.formatted(func(v: float) -> String: return "Off" if v <= 0.0 else "%d%%" % roundi(v * 100.0)))


## The help screen's goal and modes; the keys come from [PlaygroundBindings]. Static so
## `tools/screenshot_menus` draws what the client builds.
static func fill_help(help: DotMenuHelp) -> void:
	if help == null:
		return
	help.about = "A sandbox: hold Q, pick a prop, an NPC, a vehicle or a weapon, and click it into the world. Pick things up with the physics gun, freeze them, throw them, weld and wire them, and undo what you made."
	help.add_text("Building", "With the physics gun, hold the left mouse button on a prop to carry it, roll the wheel to push it away or pull it close (with nothing in hand the wheel changes tool), and press the right button to freeze it where it is. Hold the rotate key to turn what you carry with the mouse. The tool gun's tools are on the spawn menu's Tools tab.")
	help.add_text("Modes", "A server may turn on the arena (players can hurt each other), waves of NPCs with downs and revives, and a shop where everything has a price. Each is a server setting, so the menu tells you what this one has on.")


## The Tab board: everybody in the sandbox, their score, how long they have been on and their
## ping. Online the server's roster; offline, this world's players.
func _prepare_board(made: Object) -> void:
	# Typed: `columns` is a typed array, which an untyped Object will not assign to.
	var board := made as DotMenuScoreboard
	board.title_text = "Playground"
	board.columns = [
		{"key": &"name", "title": "Player", "width": 3.0},
		{"key": &"score", "title": "Score", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]


## The board offline. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var rows: Array = []
	if playground != null:
		for id in playground.players:
			var who: Object = playground.players[id]
			rows.append({"id": str(id), "name": str(who.get("display_name")) if who.get("display_name") != null else str(id),
				"seconds": int((Time.get_ticks_msec() - _started_msec) / 1000) if who == player else -1,
				"ping": -1, "you": who == player})
	return {"server": {"name": "Playground", "game": "offline"}, "players": rows}


## When this client started, for an offline board's "time".
var _started_msec: int = Time.get_ticks_msec()


## What a frame draws that a tick does not: the netcode's interpolation, then every player's body
## turned the way they look. Per frame, not per tick, or remote players step at the snapshot rate.
## [param alpha] is how far through the tick the frame is (-1 asks the engine). Returns the body count.
static func present_frame(
	p_net: DotNetManager, p_game: Playground, alpha: float = -1.0, own: PlaygroundPlayer = null
) -> int:
	var networked := p_net != null and p_net.is_running()

	if networked:
		p_net.interpolate_frame(alpha)

	# Your own player is drawn at the clock's render alpha, not the engine's fraction: the clock
	# stretches its ticks while it settles on the server, so at the engine's fraction the eye stood
	# still then moved double. By name both ways, so an older shell draws as before; null offline.
	if own != null and is_instance_valid(own) and own.controller != null:
		own.controller.set(&"render_clock", p_net.clock if networked else null)

	if p_game == null:
		return 0

	var shown := 0

	for id: Variant in p_game.players:
		var body: PlaygroundPlayer = p_game.players[id]

		if body == null or not is_instance_valid(body) or not body.is_inside_tree():
			continue

		body.face_body()

		if body.character != null and body.character.is_body_visible():
			shown += 1

	return shown


## Draws every beaconed player's marker for one frame, and plays each ripple's ping, this client's
## own included. Here, not in the game's tick: a dedicated server would build meshes for nobody.
func _present_beacons(delta: float) -> void:
	if playground == null:
		return

	for id: Variant in playground.players:
		var body: PlaygroundPlayer = playground.players[id]

		if body == null or not body.is_inside_tree():
			continue

		# The column is hidden for the one player the camera is behind, and only in first
		# person: from behind a third-person rig the column is a mark over your own head
		# like anybody else's, and a camera outside it sees no smear.
		var own_eyes := body == player and body.view_mode() != &"tp"

		if body.present_beacon(delta, own_eyes) and presentation != null:
			var _voice := presentation.on_beacon(body.controller.state.position)


## Whether a menu is up, in which case the mouse belongs to it.
func _menu_is_open() -> bool:
	return (screens != null and screens.any_open()) or (game_menu != null and game_menu.any_open()) \
		or (map_edit_view != null and map_edit_view.panel_open())


## The sampler the next simulated tick will actually read. A networked player has no sampler of its
## own, so mouse events must feed this one. Left null in play, where the real mouse mode is the answer.
var mouse_capture_override: Variant = null


## Whether the pointer is currently a look input rather than a pointer.
## An override rather than a read of `Input.mouse_mode` at the call site, because the dummy display server
## pins the mode to VISIBLE and a suite could not put a client into the state a player plays in.
func mouse_drives_view() -> bool:
	if mouse_capture_override != null:
		return bool(mouse_capture_override)

	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


## Points the applier's look settings (`sensitivity`) at the tunables every sampler reads, and
## applies them now. Called again in [method _adopt]. Only look fields are written, which
## `DotFpsTunables.fingerprint` leaves out, so a client cannot disagree with its server.
func _bind_look() -> void:
	if applier == null:
		return
	for sampler: DotFpsSampler in [_sampler, player.sampler if player != null else null]:
		if sampler != null and sampler.tunables != null:
			applier.bind_look(sampler.tunables)


func active_sampler() -> DotFpsSampler:
	if link != null:
		return _sampler

	return player.sampler if player != null else null


## The key [param action] is on, as the player has it bound: for a sentence on the HUD.
func key_for(action: StringName) -> String:
	if keys != null:
		return keys.key_for(action)
	return str(PlaygroundBindings.make().row_for_action(action).get("default", action))


## Puts a refusal on the HUD, and says nothing about a success. An empty message is a refusal
## already told through `DotPropSpawner.refused`; printing it again would show the line twice.
var _wet: Dictionary = {}


## What B says outside the arena (the server's `closed_fn` says the same).
const LOADOUT_ARENA_ONLY := "Loadouts are in the arena."

## dot-menu's loadout menu, or null on a host whose dot-menu predates it (API 6).
var loadout_menu: Object = null

## Whether the server's arena is on (`pg_arena_on`, replicated). Never offline: the arena is a
## server's mode, and the loadout manager lives in it.
var arena_on: bool = false
