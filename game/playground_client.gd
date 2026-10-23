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
const PlaygroundServices := preload("playground_services.gd")
const PlaygroundProfileScreen := preload("playground_profile_screen.gd")
const PlaygroundSpawnMenu := preload("playground_spawn_menu.gd")
const PlaygroundVoice := preload("client/playground_voice.gd")
const PlaygroundWeapon := preload("weapons/playground_weapon.gd")
const PlaygroundWeapons := preload("playground_weapons.gd")
const PlaygroundZee := preload("playground_zee.gd")
const PlaygroundWeaponDef := preload("weapons/playground_weapon_def.gd")

## Boots a playable playground: one local player, a camera, a HUD, a spawn menu and
## the keys.
##
## [b]Separate from [Playground] on purpose.[/b] The playground is the simulation and
## runs headless — that is what `examples/headless_playground.tscn` drives, and it has
## no camera, no HUD and no input. This is everything a person needs on top of it, and
## a dedicated server simply never loads it.
##
## [b]The bindings are the sandbox ones[/b], because that is the game this one is asking
## to be compared with and a sandbox with its own scheme is a sandbox nobody can pick
## up. Two mouse buttons that mean different things depending on what is in your
## hands, a menu you hold open, and a spawn that happens the moment you click a prop:
##
## [codeblock]
## Q (hold)     the spawn menu. Release to close; tap to pin it open
## Mouse 1      the tool's primary: grab and hold, or punt
## Mouse 2      the tool's secondary: freeze what is held, or pull and carry
## Wheel        how far out the physics gun holds a prop
## Shift+mouse  turn the prop the physics gun is holding
## E            spawn the prop the menu last armed, again
## R            unfreeze everything you have frozen
## Z            undo your last spawn
## 1 / 2 / 3    physics gun / gravity gun / cycle the weapons you have
## T            switch track (with a run timer: the server added dot-timer)
## N            cycle style      M   next map
## C V X G      practice checkpoints, with a run timer: save, go to, cycle, forget
## [/codeblock]

const CHANNEL := "playground.client"

## Where dot-server's client publishes its [DotClientLink] before a game scene loads.
const LINK_SERVICE := &"dot_client_link"

## Ids the tools are addressed by, here and in [PlaygroundSpawnMenu].
const TOOL_PHYS := &"phys"
const TOOL_GRAV := &"grav"
const TOOLGUN := &"toolgun"
## The tool gun mode that edits a selected prop (`game/toolgun/tool_edit.gd`).
const EDIT_MODE := &"edit"

## How long Q may be held before releasing it closes the menu.
##
## [b]A tap pins, a hold does not.[/b] Both are wanted and they are the same key in
## in those sandboxes: holding it is how you glance at the menu without losing your place,
## and tapping it is how you leave it up while you build. A quarter of a second is
## comfortably longer than a click and comfortably shorter than a look.
const MENU_TAP_SECONDS := 0.25

## Where a spawned prop appears, in metres in front of the eye.
const SPAWN_REACH := 3.0

## The map to open on if the configuration names none. A client has to be somewhere.
const FALLBACK_MAP := &"pg_flatgrass"

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"

## Configuration handed to the [Playground] this builds, or null for the defaults.
##
## [b]Forwarded rather than set afterwards.[/b] `Playground._ready` layers the config
## and loads `initial_map` from it, and both happen inside `add_child` — so anything
## assigned after that is assigned to a game that has already booted on the old
## values. It is also the only way a test can boot a real client without it writing
## records into the user's data directory.
@export var config: PlaygroundConfig = null

## A JSON file to layer over [member config]. Passed straight through.
@export var config_file: String = ""

## The dedicated server's client link, when this client is on a server.
##
## [b]Set before this node enters the tree, and it is what decides which client this
## is.[/b] With it, the playground is a mirror: it is not authoritative, it adds no
## player of its own, and every action goes to the server as intent. Without it, this
## is the local sandbox it has always been, which is what `headless_playground` drives.
@export var link: Node = null

var playground: Playground = null
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

## The player asked to leave from the pause menu.
##
## Announced rather than acted on: what "leave" means belongs to whatever loaded this
## client -- a shell goes back to its own menu, an embedded page closes the frame, a
## development scene quits. A client that called `get_tree().quit()` itself would be one
## that cannot be embedded in anything.
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

## The weapon in hand, when [member tool] is neither of the two built-in guns.
##
## [b]Instantiated per equip, not held as a pool.[/b] A weapon is a script with state —
## a charge, a cooldown, what it is holding — and a shared instance would carry one
## player's cooldown into another's hands the moment this becomes a server.
var weapon: PlaygroundWeapon = null

## The hands and the gun, under the first-person camera, while a zee weapon is in them.
var zee_view: Node3D = null

## Fire, alt and reload for a zee weapon offline, as command bits. A connected client sends
## the same bits in [member _net_buttons] instead, and the server runs the shot.
var _zee_buttons: int = 0
## The Aim key held with a zee gun in hand (`PlaygroundBindings.AIM`, right mouse): the hands
## come up and the lens zooms. Presentation only.
var _aiming: bool = false

## Whether the pointer was a look input at the last frame; see the click branch of
## `_unhandled_input`, and the 'Click to play' notice in `_process`.
var _was_driving: bool = false

## Where the style key is in the list.
var _style_index: int = 0

## Whether the physics gun's button is down.
var _holding: bool = false

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

## The tool triggers, as command buttons. Held rather than edge-triggered: the server
## decides what a press and a hold each mean (see PlaygroundNetBridge._drive_tools), and
## a client that sent only the edges would drop one to packet loss and leave a player
## holding a crate they have let go of.
var _net_buttons: int = 0


func _ready() -> void:
	# First, before anything can be drawn: the map arrives after this node is in the tree.
	_build_gate()

	playground = Playground.new()
	playground.name = "Playground"

	# [b]A networked client is not authoritative, and this is where that is decided.[/b]
	# Set afterwards it would be assigned to a game that had already booted:
	# `Playground._ready` layers the config and loads the first map inside `add_child`,
	# so a game told at that point that it is a mirror has already spent a map load
	# believing it owned the world.
	if config == null:
		config = PlaygroundConfig.new()

	# zee-dot-weapons' art is this game's copy of it, wherever this game is mounted.
	PlaygroundZee.use_this_games_art()

	# [b]Looked up when nobody handed it over, because in a delivered game nobody does.[/b]
	# The shell sets [member link] on a BUILT-IN client scene, and this game has been a
	# pack since 2026-09-23 — and `DotClientLink._on_load_game` instantiates a pack's
	# client scene itself and sets nothing on it. So every connected client booted as the
	# local sandbox: authoritative, a player of its own, connected to a server it never
	# spoke to, and every person on the server alone in a private copy of the map. Every
	# other game in the family reads the registry; this one only had the export. The
	# export still wins, so two shells in one process keep their own links.
	if link == null and not platform.offline:
		link = platform.link as Node

	if link != null:
		config.authoritative = false

	# [b]Before the playground, and the ordering is what makes the generated map work.[/b]
	# `Playground._ready` loads its first map inside `add_child`, and a generated map asks
	# `DotRegistry` for a seed source at that moment. A randomness manager registered
	# afterwards is one the map did not use -- and nothing would error, because falling
	# back to a fixed seed is a legitimate configuration and therefore indistinguishable
	# from the bug.
	presentation = PlaygroundPresentation.new()
	presentation.name = "Presentation"
	presentation.client = self
	add_child(presentation)
	DotLog.result("playground.client", "the presentation layer", presentation.setup())
	_wire_chat_window()

	playground.config = config
	playground.config_file = config_file
	# The map's toys are heard: a bounce, a knock, a switch, a honk. Before the first map.
	var _toys := playground.toy_sound.connect(func(id: StringName, at: Vector3, strength: float) -> void:
		if presentation != null:
			var _played := presentation.on_toy(id, at, strength))
	add_child(playground)

	# Custom maps the server's game names as dependencies (game-playground-maps): fetched in
	# the same content sync as this game, so mounted by now. Added before any map change can
	# name one, which on a client is the HELLO still to come.
	if link != null:
		for key: Variant in link.get("content_extra") if link.get("content_extra") != null else []:
			var parts := DotGameDescriptor.split_key(str(key))
			var _added := playground.add_map_directory(
				DotCloudClient.mount_prefix_for(StringName(parts[0]), parts[1]).path_join("maps"))
	else:
		# Solo in the client shell: no server named the custom maps, so the shell fetched the
		# packs a server owner would name (its `client/solo.json`) and publishes them under
		# `dot_solo`. Looked up by name and duck-typed: a delivered game may not name a host's
		# class. Absent everywhere else (a run from the repository, a suite).
		var host: Object = DotRegistry.get_service(&"dot_solo")
		if host != null and host.has_method(&"map_dirs"):
			for dir: String in host.call(&"map_dirs", "maps"):
				var _added := playground.add_map_directory(dir)

	# The playground loads its own first map and this waits for it, rather than
	# loading one here.
	#
	# [b]Two reasons, and the second is the one that bites.[/b] `initial_map` is
	# layered configuration, so a client that picked its own would ignore `--pg-map`
	# and every server-side default with it. And loading it twice builds the whole
	# map twice — the second change tears the first down, which frees the geometry
	# anything already placed on it is standing on.
	#
	# By this line `Playground._ready` has run as far as its own `await`, so the
	# config is layered and final while the map is not up yet: waiting on the signal
	# cannot miss it.
	#
	# `booted` is checked BEFORE the await, and that is not defensive. `change_map`
	# can complete without ever suspending — a built-in map is a scene already in the
	# build — in which case the playground finishes booting inside `add_child` above
	# and `ready_for_players` has already been emitted by the time this line runs.
	# Awaiting it then waits for ever, and the symptom is a black screen with no
	# error at all: no camera, no HUD, no player. It is the family's own fan-out trap
	# in its smallest form, and this file had it for exactly one screenshot.
	if not playground.booted:
		await playground.ready_for_players

	if playground.maps.current == null:
		var loaded: DotResult = await playground.change_map(FALLBACK_MAP)

		if not loaded.ok:
			DotLog.error(CHANNEL, "could not load the first map", {
				"why": loaded.error.message
			})
			return

	_wire_gate_to_maps()

	if link != null:
		# The server creates the player and JOIN is what tells this client about it, so
		# there is nobody to adopt yet. Everything below that needs one checks.
		var netcode := _build_netcode()

		if not netcode.ok:
			DotLog.error(CHANNEL, "the netcode would not start", {
				"why": netcode.error.message
			})
			return

		# [b]The view is NOT built here on a networked client, and that is the whole
		# ordering.[/b] The camera is parented to the player, and on a server the player
		# does not exist yet: HELLO names you and JOIN creates you, both of them packets
		# that have not arrived. Building it now calls `add_child` on null, the camera is
		# never in the tree, and `_process` then writes a global transform to a node that
		# has no parent — once a frame, for ever.
		#
		# On desktop that is a red line per frame and a black screen. In a WASM build it
		# is a hard `RuntimeError: null function` with no GDScript trace at all, which is
		# what this cost to find. [method _adopt] builds it the moment JOIN lands.
	else:

		player = playground.add_player(player_id, display_name)
		player.samples_input = true
		gate.freeze(player)

		# The sampler is built in the player's _ready, which has already run — so it is
		# built here instead. Setting the flag alone would leave a player who is
		# supposed to be driving and never samples anything, which reads as the input
		# being broken.
		player.sampler = DotFpsSampler.new(player.controller.tunables)
		DotFpsSampler.register_default_actions(player.sampler)

		_build_view()
		_build_view_switch()

	hud = PlaygroundHud.new()
	hud.name = "Hud"
	hud.key_fn = key_for
	add_child(hud)
	_follow_hud()
	if link == null:
		hud.bind(playground, player_id)
	# The vote's clock, handed over HERE rather than where the bridge is built: the netcode
	# comes up before the HUD exists, so the hand-over there found no HUD and every
	# connected client kept counting its own map session's clock through every extend.
	if bridge != null:
		hud.clock_view = bridge.clock_view
	else:
		# Offline the client IS the server: its own world confirms its hits. Connected, the
		# server's HIT event does (`_build_netcode`), and this world decides nothing.
		playground.hit_landed.connect(func(id: StringName, victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
			if id == player_id:
				_on_hit(victim, amount, point, killed, headshot))
	_sync_hud()

	# After the HUD, because for a CanvasItem tree order is draw order and a menu
	# that renders under the speedometer is one whose bottom row cannot be clicked.
	_build_client_services()
	_build_screens()
	_wire_presentation()

	set_process(true)


## Hands what happened in the world to the presentation layer, which is what turns it into
## a noise, a puff and a shake.
##
## [b]Nothing called these, and the client was silent.[/b] `PlaygroundPresentation` had a
## hook per event, a synthesised voice per sound id, a probe that proved a speaker moved and
## a suite that called the hooks directly — and not one line of the game called any of them,
## so every check about sound passed while the playable client never made one. A value
## produced and consumed by nothing, with the ends swapped: the consumer was there and the
## producer was the suite.
##
## [b]On a networked client only YOUR props make a noise.[/b] A joining client is sent every
## prop already in the world through the same PROP event a new spawn uses, and the wire
## cannot tell the two apart; sounding somebody else's would greet every join with a burst
## of an hour's building. Your own cannot be in that backlog — the session is new — and it
## is the one sound that answers something you just did.
## The load gate: the screen stays covered, and the local body and the input stay still, until
## the level is built, the local player exists and its camera is current.
##
## [b]Without it the player moved before the world was whole.[/b] Offline the player spawns in
## the tick the first map lands, and a connected client draws from the first frame with no
## player, no camera and a HUD that has nobody to read; a map change tore the old level down
## and rebuilt it in front of a body that kept falling through the gap. The gate does not stop
## the simulation by itself: a frozen player is skipped by [method Playground._simulate_tick]
## (`can_process`), and this client's own sampling and keys check [method _covered].
func _build_gate() -> void:
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = link == null and OS.get_cmdline_user_args().has("--offline")
	platform.link = link
	# Not built by the platform: the settings document is PlaygroundPresentation's manager with
	# a DotMenu built round it (the Servers action, the loadout and map menus), handed over by
	# `adopt_menu`, and the console must follow that menu, so `add_console` comes later (see
	# _build_pause). The pointer is the platform's: the first Escape frees it, the second opens
	# the menu, and a click or the menu closing takes it back -- except while the Q menu or the
	# server browser, screens on this client's own stack, are up. Tab is the roster's, not the
	# platform's board.
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


func _wire_presentation() -> void:
	if presentation == null or presentation.settings == null \
			or presentation.audio == null or presentation.fx == null:
		return

	# Both ends: a map change frees the world the live effects are parented into.
	playground.maps.changed.connect(
		func(map: DotMapDef, _loaded: Node) -> void: presentation.on_map_changed(map.id if map != null else &"")
	)
	# Glass breaking is heard on both ends: offline the game breaks it, connected the server's
	# PANE event does, and either way the signal is this end's.
	playground.pane_broken.connect(func(_index: int, at: Vector3, _material: StringName) -> void:
		presentation.on_pane_broken(at)
	)

	if bridge != null:
		bridge.prop_arrived.connect(func(at: Vector3, owner_session: int) -> void:
			if owner_session != 0 and owner_session == bridge.local_player_id:
				presentation.on_prop_spawned(at, true)
		)
		return

	playground.props.spawned.connect(func(prop: DotPropInstance) -> void:
		var body := prop.node as Node3D if prop != null else null
		if body != null:
			presentation.on_prop_spawned(body.global_position, prop.owner_id == player_id)
	)
	playground.props.refused.connect(
		func(id: StringName, _prop: StringName, _reason: String) -> void:
			if id == player_id:
				presentation.on_refused()
	)

	# Offline the client IS the server, so walking over a weapon equips it here. On a
	# server the bridge gives it, and the WEAPON event that follows equips it.
	playground.weapon_picked_up.connect(func(who: StringName, weapon_id: StringName) -> void:
		if who == player_id:
			_set_tool(weapon_id)
	)


## Brings up the netcode and points it at the server's link.
##
## Mirrors [G2GClient]'s, because that is the one in this family proven against a real
## dedicated server over a real socket.
func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var net_config := DotNetConfig.new()
	net_config.tick_rate = playground.tick_rate
	net_config.snapshot_rate = 32
	net_config.enable_prediction = true
	net_config.enable_lag_compensation = false
	net_config.max_entities_per_snapshot = 64
	net_config.world_extent = 512.0
	net.config = net_config
	add_child(net)

	var ready_result := net.setup()

	if not ready_result.ok:
		return ready_result

	bridge = PlaygroundNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(playground, net, link)

	if not attached.ok:
		return attached

	# A restarted server counts revisions from 0 again, so forget the old ones first.
	var link_up := DotNetProfileLink.attach(net, playground.profiles.runtime)
	if link_up != null:
		playground.profiles.runtime.begin_sync()
		link_up.reply.connect(_on_profile_reply)
		_profile_admin = false
		_sync_profiles_entry()
		if presentation != null:
			presentation.profile_link = link_up
			presentation.bind_profile_replies()

	net.messages.seal()

	bridge.hello_received.connect(_on_hello)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.weapon_changed.connect(_on_weapon_changed)
	# [b]dot-server's own `chat_received` is deliberately NOT connected.[/b] The server
	# cancels that path and routes every line through [DotChatRouter] onto this game's own
	# wire instead; connecting both would draw a line twice on a server running the old
	# path and once on one running the new.
	bridge.chat_received.connect(_on_chat_wire)
	bridge.builds_received.connect(func(list: Array) -> void:
		if menu != null:
			menu.set_builds(list)
	)
	bridge.selection_received.connect(func(state: Dictionary) -> void:
		_adopt_selection(bridge.mirror_of(int(state["net_id"])), str(state["name"]),
			state["settings"], str(state["refused"]))
	)
	bridge.combat_received.connect(_on_combat)
	# The server's sv_ragdoll* set: this end draws the bodies. An older shell's link cannot say.
	if link != null:
		var _bodies := playground.ragdoll_rules.follow_cvars(link)
		# And sv_toys*: a client hides the toys a server took away.
		var _toy_rules := playground.toy_rules.follow_cvars(link)
		# The server's mp_forceview and mp_solidplayers: this end places its own camera and
		# predicts its own player.
		var _view := playground.view_rules.follow_cvars(link)
		var _solid := playground.body_rules.follow_cvars(link)
		_follow_arena(link)
	_build_ragdolls()
	bridge.body_fell.connect(func(figure: Node3D, death: DotPlayerDeath) -> void:
		if ragdolls != null and figure.is_inside_tree():
			_land_on_the_world()
			var _fell := ragdolls.spawn(figure, death)
	)
	bridge.hit_received.connect(_on_hit)
	bridge.match_received.connect(_on_match)
	bridge.progress_received.connect(_on_progress)
	bridge.notice_received.connect(func(_pid: int, text: String) -> void:
		if hud != null:
			hud.notice(text)
	)
	# A move in the bag the server refused has already sprung back by the time this fires;
	# the line is what says it was the server and not the grid.
	bridge.inventory_refused.connect(func(reason: String) -> void:
		if hud != null:
			hud.notice("Your bag: %s" % reason)
	)
	# The map's time left is handed to the HUD where the HUD is built, below.
	# The map vote's cue and countdown. The ballot itself arrives as chat; this is what
	# chat cannot carry.
	bridge.vote_cue_received.connect(func(info: Dictionary) -> void:
		var seconds_left := int(info.get("seconds_left", 0))
		if seconds_left > 0 and hud != null:
			hud.notice("%s in %d…" % [
				"Runoff" if bool(info.get("runoff", false)) else "Map vote", seconds_left
			])
		if presentation != null:
			presentation.on_vote_cue(StringName(str(info.get("cue", ""))))
	)

	# Stock tunables until there is a player to ask. The sampler turns the view at the
	# rate the player's style says, and at this point the server has not told us who we
	# are — _adopt swaps them in the moment JOIN does.
	_sampler = DotFpsSampler.new(DotFpsTunables.new())
	DotFpsSampler.register_default_actions(_sampler)

	# [b]Nothing may be sent to a peer before it says it can receive.[/b] dot-server's
	# signon finishes and THEN the client builds its scene, so everything sent in
	# between lands on a node that does not exist and is lost — one "Node not found"
	# per call, and a client that never joins.
	if link.has_method("is_playing") and bool(link.call("is_playing")):
		bridge.ask_ready()
	elif link.has_signal("spawned"):
		link.connect("spawned", bridge.ask_ready, CONNECT_ONE_SHOT)

	# Nothing in dot-net writes an RTT sample: it never touches a transport. A client
	# that feeds none has a clock that believes the link is instant, and every command
	# it stamps arrives after its tick has already been simulated.
	if link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	return net.start()


func _on_hello(id: int) -> void:
	player_id = StringName("u%d" % id)

	if hud != null:
		hud.bind(playground, player_id)

	_adopt()


## [b]HELLO names you and JOIN creates you, in that order.[/b] Looking the player up on
## HELLO alone gets null and never tries again — which is how g2gfast shipped a browser
## client that connected, drew, showed a live HUD and walked around with a dead mouse
## and a dead keyboard, because everything below the `player == null` guard in its input
## handler never ran.
func _on_roster_changed(_id: int) -> void:
	_adopt()


func _adopt() -> void:
	if player != null or bridge == null or bridge.local_player_id == 0:
		return

	var mine: PlaygroundPlayer = playground.players.get(player_id)

	if mine == null:
		return

	player = mine
	gate.freeze(player)

	# Now, and not before: this is the first moment there is a node to parent a camera
	# to. See the note in _ready.
	_build_view()
	_build_view_switch()

	if _sampler != null:
		_sampler.tunables = player.controller.tunables
		# A different tunables object, carrying the addon's default sensitivity again.
		_bind_look()

	_sync_hud()


## The client's tick, driven by the netcode clock rather than by the engine's frame.
##
## The clock is asked how many ticks this frame is worth, because the engine's rate and
## the server's need not agree — though the bridge adopts the server's on HELLO, which
## is the only reason the two ever do.
func _net_physics(delta: float) -> void:
	if net == null or bridge == null or not net.is_running():
		return

	var ticks := net.clock.advance(delta)

	var sampler := active_sampler()

	# The clock above has advanced; only the sampling waits, so the mouse does not pile up
	# a turn behind the cover and the server sees an idle body until it lifts.
	if sampler == null or _covered():
		return

	# [b]Each pass is its own tick.[/b] `advance` has already moved the clock by all of
	# them, so `input_tick()` is the LAST one on every pass: a frame worth two ticks sent
	# the second twice and the first never, the server repeated a stale command for the
	# one it never got, and the predictor's replay stopped at the hole and drew the player
	# short of where they were -- after every hitch, and on every frame the display and
	# the tick rate do not line up. Arithmetic here rather than a new dot-net call,
	# because a pack has to run on whatever client shell the player already has.
	for i in range(ticks):
		if net.clock.is_synced():
			var tick := net.clock.input_tick() - (ticks - 1 - i)
			var command := sampler.sample(delta)
			command.buttons |= _net_buttons
			bridge.client_tick(tick, command)

			# The hands, from the same command the server will run. No authority: what it
			# fires is drawn and heard here and decided there.
			var rig := _zee_rig()
			if rig != null:
				var drawn_command := PlaygroundZee.command_for(
					command.buttons, command.yaw, command.pitch, PlaygroundZee.slot_of(rig)
				)
				var _drawn := rig.simulate_tick(drawn_command, tick)
				# How long it has been quiet, so the server's count may correct it
				# (`PlaygroundPlayerNet._correct_drawn`) without undoing a shot in flight.
				PlaygroundZee.note_drawn(player, rig, drawn_command, 1.0 / float(maxi(playground.tick_rate, 1)))


func _build_view() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 100.0
	camera.current = true
	player.add_child(camera)

	# Somebody walking into the first-person camera is hidden at the lens. The third-person
	# camera is dot-player-controller's rig, which has a fade of its own (`_build_view_switch`).
	var fade := DotCameraFade.new()
	fade.name = "Fade"
	fade.bodies_fn = _other_players
	camera.add_child(fade)

	# The landing dip, the strafe lean and the widening, applied where `_process` writes the
	# camera (`PlaygroundPlayer.present_camera`), at the player's camera motion settings.
	player.enable_camera_motion()
	if presentation != null:
		presentation.bind_camera_motion(player)



## Builds the third-person controller and the switch, on the local player only.
##
## [b]Here rather than in `Playground.add_player`, and the ordering is the whole
## reason.[/b] `samples_input` is set by this client AFTER the player is made — the
## comment above says why — so a switch built inside `add_player` would look at a player
## who is not yet local, decide there was no camera to serve, and build nothing. The
## symptom would be F5 doing nothing, on the one player it is supposed to work for.
func _build_view_switch() -> void:
	if player == null:
		return

	player.samples_input = true

	if not playground.view_rules.changed.is_connected(_on_view_rules_changed):
		playground.view_rules.changed.connect(_on_view_rules_changed)

	if not player.build_view_switch():
		DotLog.warn(CHANNEL, "no view switch for the local player", {
			"player": String(player_id)
		})

## Chat and voice, once the bridge exists.
func _build_client_services() -> void:
	chat = DotChatClient.new()
	chat.name = "Chat"
	# The same channel definitions the server routes with — shared rather than sent, for
	# the reason every constant in this family is shared: a client holding a different set
	# would show a line on a channel it has no colour or prefix for.
	chat.channels = PlaygroundServices.chat_channels()
	chat.rules = PlaygroundServices.chat_rules()
	chat.history_limit = 400
	# Two clients in one process would otherwise collide on the registry name and one of
	# them would be invisible to whatever asked.
	chat.register_as = &""
	add_child(chat)
	chat.start()
	chat.message_received.connect(_on_chat_message)

	if bridge == null:
		return

	voice = PlaygroundVoice.new()
	voice.name = "Voice"
	voice.send_fn = func(bytes: PackedByteArray) -> void:
		if bridge != null and bridge.link != null:
			# Passed as 1 rather than 0: the peer is ignored on a client, and in this
			# family zero has meant "everybody" often enough to be worth never writing by
			# accident.
			bridge.link.send_voice(1, bytes)
	add_child(voice)

	voice.setup(not DotPlatform.is_headless())
	bridge.voice_arrived.connect(voice.receive)

	platform.look_voice = voice.manager
	platform.look_chat = chat
	platform.look_position_fn = _look_position
	platform.build_look_mute()


# --- Chat ------------------------------------------------------------------

## Joins the chat box to the three things it needs.
##
## [b]The sampler is the half that is easy to forget.[/b] `swallows_input` keeps typed keys
## out of `_unhandled_input`, but movement here is POLLED — `DotFpsSampler.sample` reads
## the device every physics frame and does not care what consumed an event. Without
## `suspended`, typing "sw" walks the player backwards through whatever they were building.
##
## [b]dot-server's `chat_received` is connected here for its state and the server's own
## lines.[/b] This game routes every PLAYER's line through its own wire on purpose —
## connecting both would draw one line twice — but the state payload and the server's system
## and admin lines come down dot-server's side and there is nowhere else to hear them.
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


## dot-server's chat payload: what is carrying the conversation, and the server's own lines.
##
## [b]A player's line is never drawn from here[/b]: this game routes those over its own wire,
## and drawing them here as well is the same line twice. [b]The server's own lines are[/b] (a
## vote between games, "Ada joined the game.", an admin's `say`): they come only this way,
## and ignoring them with the players' lines is how this game never showed one.
func _on_server_chat_state(payload: Dictionary) -> void:
	if str(payload.get("kind", "")) != "state":
		var window: DotChatWindow = presentation.chat_window if presentation != null else null
		var _drawn := DotGameChatClient.draw_server_line(window, payload)
		return

	if presentation != null:
		presentation.set_chat_relayed(bool(payload.get("relay", false)))


## What a player typed, on its way to the server.
##
## Nothing is filtered here: the server decides what a line may contain and its answer is
## the only one that counts.
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
## [b]The channel decides how it is drawn, and the channel is a document.[/b] Its prefix
## and colour come off the [DotChatChannel] both ends share, so adding a channel is adding
## a definition rather than a branch somebody has to remember to extend.
func _on_chat_message(message: DotChatMessage, channel_id: StringName) -> void:
	if hud == null:
		return

	var chan := chat.channel(channel_id)
	var prefix := "%s " % chan.prefix if chan != null and chan.prefix != "" else ""

	var window: DotChatWindow = presentation.chat_window if presentation != null else null
	var colour := chan.colour if chan != null else Color(0.88, 0.90, 0.94)

	# [b]In the chat box, and on the notice line only when there is no box.[/b] Both drew
	# every line: a map vote's ballot was printed at the notice line in the middle left and
	# again in the box bottom left, beside the drawn ballot panel. The notice line keeps what
	# is the game's (budget reached, a tool's refusal), which never comes through chat.
	# A join or leave notice is a name and no text (dot-chat's `_presence`): drawn by its
	# text it was an empty line in the box, and by name and text a bare "Guest 435:".
	# `describe()` words it ("Guest 435 joined"); every other kind is drawn by its text.
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


## A hit of this player's the server confirmed: the marker and the number on the body.
func _on_hit(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
	if hud != null:
		hud.confirm_hit(victim, amount, point, killed, headshot)
	_draw_body_hit(_zee_rig(), point)


## The hit drawn on the body the server says was hit: zee's red burst at [param point], for a
## body the client's presentation ray never meets (a target hit through the server's hitboxes). The rig's effects skip a second drawing
## of a hit the ray already drew. Through `has_method`: an older shell's zee has no
## `play_body_hit`.
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

	health = int(state["health"])
	armour = int(state["armour"])

	if bool(state["died"]) and hud != null:
		hud.notice("You were killed.")


# --- Dead bodies -------------------------------------------------------------

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
	return ragdolls.spawn(body, death if death != null else DotPlayerDeath.new(), velocity)


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


## The match clock.
##
## [b]Taken from the wire rather than from a local [DotMatch].[/b] Nothing ticks a
## mirroring client's, so `seconds_remaining()` is derived from a tick that is still zero —
## not a stale value, a value nothing had ever written. game-arena shipped a client that
## showed `IDLE` for ever while the server was playing a round.
func _on_match(state: Dictionary) -> void:
	match_label = str(state["label"])
	match_seconds = float(state["seconds_left"])


## Somebody picked a server in the browser.
##
## [b]Connecting is the host application's, not this scene's.[/b] A client scene that
## reached into its own link and reconnected would be a scene that decides where a person
## plays — and the same scene is instantiated by a shell that already knows. So this
## announces, and a launcher acts; offline it says so rather than pretending.
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


func _build_screens() -> void:
	screens = DotScreenStack.new()
	screens.name = "Screens"
	# Captured whenever nothing is open, which is what puts the mouse back on the
	# view the instant the menu closes. Doing it by hand in the close path means
	# every future screen has to remember to.
	screens.idle_mouse_mode = DotScreen.Mouse.CAPTURED
	add_child(screens)

	var ready := screens.setup()

	if not ready.ok:
		DotLog.error(CHANNEL, "the screen stack could not be set up", {
			"why": ready.error.message
		})
		return

	menu = PlaygroundSpawnMenu.new()
	menu.name = "SpawnMenu"
	menu.catalogue = playground.props.catalogue
	menu.weapons = playground.weapons
	menu.selected = selected_prop
	menu.tool = tool
	menu.key_fn = key_for
	menu.prop_chosen.connect(_on_prop_chosen)
	menu.weapon_chosen.connect(_on_weapon_chosen)
	menu.tool_chosen.connect(_on_tool_chosen)
	menu.action_requested.connect(_on_menu_action)
	menu.tool_mode_chosen.connect(_on_tool_mode_chosen)
	menu.npc_weapon_chosen.connect(_on_npc_weapon_chosen)
	menu.weapon_spawn_requested.connect(_on_weapon_spawn_requested)
	menu.builds_opened.connect(_on_builds_opened)
	menu.build_chosen.connect(_on_build_chosen)
	menu.addon_item_chosen.connect(_on_addon_item_chosen)
	if playground.addons != null:
		menu.addon_items = playground.addons.describe_items()

	# The Workshop, solo only: a connected client's menu is the server's, and its index says online.
	if link == null and bridge == null:
		menu.set_pack_rows(playground.follow_workshop().rows())
		playground.workshop_changed.connect(
			func() -> void: menu.set_pack_rows(playground.workshop.rows())
		)

	var registered := screens.register(menu)
	DotLog.result(CHANNEL, "registering the spawn menu", registered)

	# The server list. [b]Registered even offline[/b], because a person running this
	# locally is exactly the person who wants to find somewhere to play — and a screen that
	# only existed on a connected client would be one nobody could reach from the menu.
	browser = PlaygroundBrowser.new()
	browser.name = "Servers"
	browser.joined.connect(_on_server_chosen)
	DotLog.result(
		CHANNEL, "registering the server browser", screens.register(browser)
	)

	profile_screen = PlaygroundProfileScreen.new()
	profile_screen.name = "ProfileWorkbench"
	profile_screen.profiles = playground.profiles
	profile_screen.submit = func(req: Dictionary) -> DotResult:
		return presentation.profile_submit(req) if presentation != null \
			else DotResult.fail(DotError.CODE_STATE, "no presentation")
	profile_screen.target_requested.connect(_on_profile_target)
	profile_screen.pushed.connect(func() -> void: _mute_profile_replies(true))
	profile_screen.popped.connect(func() -> void: _mute_profile_replies(false))
	DotLog.result(CHANNEL, "registering the profile workbench", screens.register(profile_screen))

	_build_pause()


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


## The escape menu.
##
## [b]dot-menu's since 2026-10-09.[/b] It was dot-ui's pause screen (Resume, Settings,
## Servers, Leave) over a generated settings form; it is the same menu every game here has
## now, with this game's settings on its pages and the server list as a sidebar action.
## The spawn menu (Q) and the server browser stay on this client's screen stack.
##
## [b]Escape keeps its two steps here[/b]: the first releases the pointer, the second opens
## the menu (see KEY_ESCAPE in `_unhandled_input`), so the menu is told not to open on
## Escape itself. It still closes on Escape.
func _build_pause() -> void:
	var settings: DotSettingsManager = presentation.settings if presentation != null else null

	# The keys on the InputMap before anything reads them: the menu's help key, the sampler's
	# movement and this client's own all come from the table now.
	keys = PlaygroundBindings.make()
	if settings != null:
		keys.apply_all(settings)

	game_menu = DotMenu.new()
	game_menu.name = "GameMenu"
	game_menu.settings = settings
	game_menu.bindings = keys
	var config := DotMenuConfig.new()
	config.brand_name = "Playground"
	var _layered := config.load_layered()
	game_menu.config = config
	game_menu.open_on_escape = false
	game_menu.manage_pointer = false
	# Leave is dot-menu's: off the server when connected (the shell takes the player back to
	# its own menu), a quit solo on a desktop. `leave_requested` is still emitted for an
	# embedder; until 2026-10-11 it was all Leave did, and nothing listened.
	game_menu.leave_on_its_own = true
	add_child(game_menu)
	var _set := game_menu.setup()
	# The platform takes the menu (the input block, the pointer, `menu_state_changed`), then
	# builds the console after it, so DotConsoleKit registers it as one of the menu's
	# overlays: opening it then stops the player through `overlays_changed` below.
	platform.board_snapshot_fn = board_snapshot
	platform.board_prepare_fn = _prepare_board
	platform.adopt_menu(game_menu)
	var _platform_up := platform.setup()
	if presentation != null:
		presentation.adopt_console(platform.add_console(presentation.settings) as DotConsoleController)

	add_general_rows(game_menu)
	fill_help(game_menu.help)
	_follow_hud()
	game_menu.screen.actions.insert(0, {"id": &"servers", "text": "Servers"})
	game_menu.screen.restyle(game_menu.kit)
	_sync_profiles_entry()

	# M: the maps (dot-menu's map menu, on the table's MAP row). Solo a choice changes the map
	# here at once; connected the server decides, by the owner's `sv_map_menu_flag`, and
	# anybody without it gets a vote instead (dot-vote's map menu, over this game's map vote).
	# By name, so a client shell older than the map menu still runs the game without it.
	if game_menu.has_method(&"use_maps"):
		var _maps: Variant = game_menu.call(&"use_maps", map_menu_rows, change_from_menu)
	_use_loadout_menu()
	_use_mods_menu()
	game_menu.action_requested.connect(_on_menu_action_chosen)
	game_menu.overlays_changed.connect(func(_open: bool) -> void:
		# At once, not at the platform's next poll: the keys are given back or taken the
		# instant the console or menu opens or closes. The pointer follows through the
		# platform's own menu-state handler.
		platform.refresh_blocked())

	if settings != null:
		applier = DotMenuApplier.new()
		applier.name = "Applier"
		applier.settings = settings
		applier.bindings = keys
		add_child(applier)
		var _applied := applier.setup()
		_bind_look()



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
	help.about = "A sandbox: hold Q, pick a prop, an NPC, a vehicle or a weapon, and click it into the world. Pick things up with the physics gun, freeze them, throw them, weld and wire them, and undo what you made. Timed courses run in the corners, and on the surf and hop maps."
	help.add_text("Building", "With the physics gun, hold the left mouse button on a prop to carry it, roll the wheel to push it away or pull it close (with nothing in hand the wheel changes tool), and press the right button to freeze it where it is. Hold the rotate key to turn what you carry with the mouse. The tool gun's tools are on the spawn menu's Tools tab.")
	help.add_text("Running", "Only on a server that adds the run timer: leave a course's start zone and the timer runs until its end zone. Checkpoints are practice: a run that used one is not a record.")
	help.add_text("Modes", "A server may turn on the arena (players can hurt each other), waves of NPCs with downs and revives, and a shop where everything has a price. Each is a server setting, so the menu tells you what this one has on.")


func _on_menu_action_chosen(id: StringName) -> void:
	match id:
		&"servers":
			game_menu.close()
			screens.push(&"servers")
		&"profiles":
			game_menu.close()
			_open_profiles()
		&"leave":
			# Closed first, so a host with nowhere to send the player is not left showing a
			# menu over a game that carried on behind it.
			game_menu.close()
			leave_requested.emit()


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


func _process(_delta: float) -> void:
	var driving := mouse_drives_view()
	if _was_driving and not driving:
		# The button's release goes to whatever took the pointer, so the aim is let go.
		_aiming = false
		# Freed with nothing open and Escape held: the platform's first Escape.
		if hud != null and not _menu_is_open() and Input.is_physical_key_pressed(KEY_ESCAPE):
			hud.notice("Click to play. Escape again for the menu.")
	_was_driving = driving
	if presentation != null:
		# Once a frame, with where the camera is. dot-audio culls by distance from the
		# listener and dot-fx ages what it spawned, and neither ticks itself -- for the
		# reason everything tickable in this family is explicit: `_process` does not run
		# while a tree is paused, and a pause menu is exactly when nothing finishes.
		var eye := camera.global_position if camera != null and camera.is_inside_tree() \
			else Vector3.ZERO
		var forward := -camera.global_transform.basis.z \
			if camera != null and camera.is_inside_tree() else Vector3.FORWARD
		presentation.present(_delta, eye, forward)
		presentation.keep_walkers(playground.players.values())
		_present_tool_beam(eye, forward)

	var _bodies := present_frame(net, playground, -1.0, player)
	_present_splashes()
	_fit_selection_box()

	# After the interpolation, so a remote player's marker is placed where this frame
	# draws them rather than where the last frame did.
	_present_beacons(_delta)

	# `is_inside_tree`, not just null. A camera whose parent was freed — a player who
	# left, a map change — is a live object that is not in the scene, and writing a
	# global transform to one is an engine error every frame rather than a crash that
	# points anywhere.
	if player == null or camera == null or not camera.is_inside_tree():
		return

	if not player.is_inside_tree():
		return

	var punch := _present_zee()

	# The camera follows the SIMULATED eye position rather than being parented to
	# something the movement drives. Parenting works and hides a real difference: the
	# simulation runs at a fixed tick and the camera is drawn every frame, so a
	# parented camera steps once per tick and judders between them.
	#
	# The shake is added here, on the drawn camera and never to the eye the simulation
	# aims from: a punt that moved the aim would move where the next shot goes, and a
	# player who turned `shake_scale` to zero gets an offset of exactly zero.
	var shake := presentation.camera_shake() \
		if presentation != null and presentation.fx != null else Vector3.ZERO
	# `render_eye_position` inside, not `eye_position`: the blend of the last two ticks,
	# because the simulation moves once a tick and the screen does not (see PlaygroundPlayer).
	# The camera motion, the recoil's punch and the player's field of view on top.
	var fov := float(presentation.settings.get_int(&"field_of_view", 100)) \
		if presentation != null and presentation.settings != null else 100.0
	# The aim's zoom multiplies the lens after the speed widening (`present_camera`), from the
	# player's own field of view, so it never compounds.
	var hands := zee_view as ZeeViewModel if zee_view != null and is_instance_valid(zee_view) and _zee_rig() != null else null
	var zoom := hands.aim_fov_scale() if hands != null else 1.0
	player.present_camera(camera, _delta, fov, shake, punch, zoom)
	if hud != null:
		hud.set_aim(hands.aim_fraction() if hands != null else 0.0, hands != null and hands.is_scoped())


## What a frame draws that a tick does not: the netcode's interpolation, then every
## player's body turned the way they are looking. Returns how many bodies are shown. Static
## so the net suite drives exactly this rather than a copy of it.
##
## [b]Once a frame, not once a tick.[/b] The interpolator blends two snapshots perfectly and
## is then useless if it is only ever asked at a tick boundary: remote players and every
## replicated prop would step at the snapshot rate however smoothly they were interpolated.
## dot-net shipped exactly that.
##
## [b]And the bodies after it[/b], because a remote player's node is moved by that call and
## the body hangs off the node. Until 2026-09-24 there was no body to move — it was hidden
## as if it were the local player's own and parked at the world origin (see
## `PlaygroundPlayer.body_shown`, and dot-player-char's visual seating), so on a networked
## client every other person in the sandbox was a beacon with nobody under it.
##
## [param alpha] is how far through the current tick the frame is; -1 asks the engine,
## which is what a real frame wants and what a suite's frames cannot. [param own] is this
## client's own player, drawn at the netcode clock's render alpha.
static func present_frame(
	p_net: DotNetManager, p_game: Playground, alpha: float = -1.0, own: PlaygroundPlayer = null
) -> int:
	var networked := p_net != null and p_net.is_running()

	if networked:
		p_net.interpolate_frame(alpha)

	# Your own player is drawn at the clock's render alpha, not the engine's fraction: the
	# clock stretches and shrinks its ticks while it settles on the server, so a physics frame
	# now and then runs no tick or two, and drawn at the engine's fraction the eye stood still
	# on one frame and moved double on the next. `DotFpsController.render_state` reads it from
	# `render_clock` (dot-player-controller); by name both ways, so a shell older than either
	# draws as before. Null offline, where every physics frame is one tick.
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


## Draws every beaconed player's marker for one frame, and plays each ripple's ping.
##
## Every player in the world, this client's own included: somebody who has been beaconed
## should see the ring at their feet and hear it too. Here rather than in the game's tick,
## because the game is the SIMULATION and runs on a server that draws nothing — a marker is
## presentation, and a dedicated server that built one would be building meshes for nobody.
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


## Tells the HUD what is in the player's hands.
##
## Pushed rather than polled: the HUD is bound to the simulation and a spectator or a
## replay has no client holding anything, so it cannot go and look.
func _sync_hud() -> void:
	if hud != null:
		hud.set_tool(_tool_name(), selected_prop)


## Whether a menu is up, in which case the mouse belongs to it.
func _menu_is_open() -> bool:
	return (screens != null and screens.any_open()) or (game_menu != null and game_menu.any_open())


# --- Input -----------------------------------------------------------------

## The sampler the next simulated tick will actually read.
##
## [b]There are two of them and which one drives is a property of the deployment.[/b] A
## networked client builds its command from `_sampler` in [method _net_physics], because
## a command has to be stamped for a tick and kept for reconciliation. A local player
## samples through its own `player.sampler` in `PlaygroundPlayer.simulate`, because there
## is no tick to stamp it for.
##
## [b]This exists so the mouse and the tick cannot disagree about which one that is.[/b]
## They did: `_on_mouse_motion` fed `player.sampler` unconditionally, and a networked
## player is not built with a sampler of its own, so every mouse event was dropped by a
## null guard while `_sampler` — the one being sampled — never saw one. Nothing errored
## and nothing else broke, because `DotFpsSampler.sample` polls the `InputMap` rather
## than reading events: the player walked, shot and spawned props with a dead mouse.
## `game-g2gfast` had the right form already; this file was the outlier.
## Set by a headless suite to answer [method mouse_drives_view] without a display
## server. Left null in play, where the real mouse mode is the only honest answer.
var mouse_capture_override: Variant = null


## Whether the pointer is currently a look input rather than a pointer.
##
## [b]A released cursor is not a look input, and [method _menu_is_open] does not answer
## that.[/b] KEY_ESCAPE releases the capture with no screen open, so after one press the
## cursor is free, the menu check is false, and every motion of a pointer the player is
## using as a pointer was still spent turning the view or twisting the prop in the gun.
## `game-arena` has always guarded on the mode here; this file and `game-g2gfast` did
## not, and it is the second half of the same "the mouse and the tick disagree" bug that
## [method active_sampler] fixed the first half of.
##
## [b]A method with an override rather than a read of `Input.mouse_mode` at the call
## site, because that read cannot be tested here.[/b] The dummy display server pins the
## mode to `MOUSE_MODE_VISIBLE` and drops every write to it without erroring, so a suite
## can neither put a client into the state a player plays in nor out of it — which is
## why arena's identical guard has never been exercised by anything, and why this one
## would not have been either.
func mouse_drives_view() -> bool:
	if mouse_capture_override != null:
		return bool(mouse_capture_override)

	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


## Points the applier's look settings (`sensitivity`, at dot-menu's degrees per count) at
## the tunables every sampler this client turns the view with reads, and applies them now.
##
## [b]The slider moved nothing until 2026-10-11.[/b] `sensitivity` was declared, shown on
## dot-menu's page and saved, and nothing ever called `bind_look`, so the view turned at
## `DotFpsTunables`' default whatever the player chose. Called once the applier exists (the
## offline player's sampler is built before it) and again in [method _adopt], because the
## connected sampler is handed the player's tunables there: a new object, at the default.
## Only look fields are written, and `DotFpsTunables.fingerprint` leaves those out, so a
## client writing them cannot disagree with its server.
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


func _unhandled_input(event: InputEvent) -> void:
	if _covered():
		return

	# [b]The console first.[/b] This client reads bare letters -- Q opens the spawn menu,
	# 1 and 2 switch tools, F gets into a car, E spawns -- so without this, typing
	# `seed` at the console opens the menu, switches a tool and spawns a crate. It is the
	# line every game that ships a console forgets.
	if presentation != null and presentation.swallows_input():
		return

	# [b]Voice first, and before the player check.[/b] Somebody with no player yet — mid
	# signon, or spectating — should still be able to talk, and a release swallowed by an
	# early return is a microphone left open. `handle_event` sees both edges, which every
	# branch below this deliberately does not.
	if voice != null and voice.handle_event(event):
		get_viewport().set_input_as_handled()
		return

	# [b]A click on the world with the pointer released takes it back, and does nothing
	# else.[/b] The platform captures it (its `_unhandled_input` runs before this one, so
	# `mouse_drives_view` is already true); `_was_driving` is last frame's answer, which is
	# what says this click was the one that took the pointer. Spent on capturing rather than
	# also firing: the player was pointing, not aiming. Before the `player == null` guard
	# for g2gfast's reason too -- a click while the world is still loading must not be
	# swallowed, or the cursor is never captured at all.
	if (
		event is InputEventMouseButton and (event as InputEventMouseButton).pressed
		and not _menu_is_open() and not _was_driving
	):
		return

	if player == null:
		return

	if event is InputEventMouseMotion:
		_on_mouse_motion(event as InputEventMouseMotion)
		return

	# Everything below moves the world. A menu is up, the mouse is a cursor, and a
	# click on a prop button must not also punt whatever is behind it.
	#
	# Checked here rather than relying on the screen consuming the event: the stack
	# blocks what reaches the GUI, and a click that lands on the menu's own
	# background is unhandled by design and would arrive here.
	if _menu_is_open() and not _is_menu_key(event):
		return

	if event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
		return

	if not (event is InputEventKey):
		return

	var key := event as InputEventKey

	# Every key below is a row of [PlaygroundBindings], matched by its action so a key moved
	# on the Controls page moves what it does here. Escape alone is a keycode: no row has it.
	if key.is_action(PlaygroundBindings.ROTATE):
		# Held, not toggled, and read on both edges: a rotate that stayed on after
		# the key came up would turn the prop every time the player looked around.
		_rotating = key.pressed
		return

	if key.is_action(PlaygroundBindings.SPAWN_MENU):
		_on_menu_key(key)
		return

	if key.is_action(PlaygroundBindings.PROFILES):
		if key.pressed and not key.is_echo():
			_toggle_profiles()
		return

	# The Tab board, held: shown while the key is down, released when it comes up.
	if key.is_action(PlaygroundBindings.SCOREBOARD) and not key.is_echo():
		if game_menu != null:
			if key.pressed:
				game_menu.scoreboard.open()
			else:
				game_menu.scoreboard.close()
		return

	# R reloads while a gun is in hand, as it does in every shooter, and unfreezes
	# everything otherwise. Held and read on both edges like a trigger. The tool gun counts
	# as a gun here: its R is each tool's third button — reset a size, take paint off, cut
	# a rope — and a player resetting a balloon's size must not thaw every crate they own.
	if key.is_action(PlaygroundBindings.RELOAD) and (_zee_rig() != null or tool == TOOLGUN):
		_set_reload(key.pressed)
		return

	# Aim and quick melee moved onto keys, held like the trigger, with a zee gun in hand.
	if _zee_rig() != null and key.is_action(PlaygroundBindings.AIM):
		_aiming = key.pressed
		return
	if _zee_rig() != null and key.is_action(PlaygroundBindings.BASH):
		if key.pressed:
			_secondary_down()
		else:
			_secondary_up()
		return

	if not key.is_pressed() or key.is_echo():
		return

	if key.is_action(PlaygroundBindings.SPAWN):
		_spawn()
	elif key.is_action(PlaygroundBindings.UNDO):
		if bridge != null:
			bridge.ask_undo()
		else:
			playground.props.undo(player_id)
	elif key.is_action(PlaygroundBindings.VEHICLE):
		_use_vehicle()
	elif key.is_action(PlaygroundBindings.RELOAD):
		_unfreeze_all()
	elif key.is_action(PlaygroundBindings.PHYS_GUN):
		_set_tool(TOOL_PHYS)
	elif key.is_action(PlaygroundBindings.GRAV_GUN):
		_set_tool(TOOL_GRAV)
	elif key.is_action(PlaygroundBindings.WEAPONS):
		_cycle_weapon()
	elif _wheel_cycle(key):
		pass
	elif key.is_action(PlaygroundBindings.TRACK):
		_timer_key(&"track")
	elif key.is_action(PlaygroundBindings.STYLE):
		# Tab is the scoreboard, held, as in every game here; the style moved to N.
		_cycle_style()
	elif key.is_action(PlaygroundBindings.CHECKPOINT_SAVE):
		_timer_key(&"checkpoint_save")
	elif key.is_action(PlaygroundBindings.CHECKPOINT_LOAD):
		_timer_key(&"checkpoint_load")
	elif key.is_action(PlaygroundBindings.CHECKPOINT_NEXT):
		_timer_key(&"checkpoint_next")
	elif key.is_action(PlaygroundBindings.CHECKPOINT_CLEAR):
		_timer_key(&"checkpoint_clear")
	elif key.is_action(DotMenuBindings.LOADOUT_ACTION) and loadout_menu != null and not arena_on:
		# B opens the loadout only in the arena (the menu is disabled outside it, so the key
		# reaches here): said, rather than a key that does nothing.
		if hud != null:
			hud.notice(LOADOUT_ARENA_ONLY)
	elif key.is_action(PlaygroundBindings.VIEW):
		# The key every third-person toggle in this genre is on, and the one
		# game-g2gfast already uses for its own. This one hands the player to a
		# different CONTROLLER rather than flipping a camera, which is why the
		# handover carrying position, velocity and look matters: pressing it
		# mid-jump must not stop you dead in the air.
		_toggle_view()

	match key.physical_keycode:
		KEY_ESCAPE:
			# Only when no screen is up. The stack's own back handling pops the menu,
			# and a second handler here would pop it and open the pause menu in one
			# press.
			#
			# [b]Release, THEN open, and never capture.[/b] The release is the platform's
			# (`escape_releases_pointer`: it frees a captured pointer on the first Escape and
			# consumes it, so that press never gets here); this is the second press. Capturing
			# is a click's job, because a browser refuses pointer lock from a key for about a
			# second after Escape.
			if not _menu_is_open() and game_menu != null:
				game_menu.open()


## The key [param action] is on, as the player has it bound: for a sentence on the HUD.
func key_for(action: StringName) -> String:
	if keys != null:
		return keys.key_for(action)
	return str(PlaygroundBindings.make().row_for_action(action).get("default", action))


## The spawn-menu key (Q) is the one key that still means something while the menu is open.
func _is_menu_key(event: InputEvent) -> bool:
	return event is InputEventKey and (event.is_action(PlaygroundBindings.SPAWN_MENU) \
		or (event.is_action(PlaygroundBindings.PROFILES) and screens != null and screens.is_open(&"profiles")))


func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if _menu_is_open():
		return

	if not mouse_drives_view():
		return

	if _rotating and _holding:
		# Turning the prop instead of the view, which is what makes the physics gun
		# a building tool. `DotPhysGun` stores the orientation relative to the view,
		# so this composes with looking around rather than fighting it.
		player.phys_gun.rotate_held(-event.relative.x * 0.4, -event.relative.y * 0.4)
		return

	var sampler := active_sampler()

	if sampler == null:
		return

	# Handed to the sampler, which accumulates it and spends it on the next
	# simulated tick. Applying it to the view here would make the look a function of
	# how many mouse events happened to land in a frame.
	sampler.handle_event(event)


func _on_mouse_button(event: InputEventMouseButton) -> void:
	# A zee gun's aim and quick melee are rows (right and middle by default); with a tool or a
	# toy in hand the buttons below keep what they always did.
	if _zee_rig() != null:
		if event.is_action(PlaygroundBindings.AIM):
			_aiming = event.pressed
			return
		if event.is_action(PlaygroundBindings.BASH):
			if event.pressed:
				_secondary_down()
			else:
				_secondary_up()
			return

	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				_primary_down()
			else:
				_primary_up()
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_secondary_down()
			else:
				_secondary_up()
		MOUSE_BUTTON_WHEEL_UP:
			if _holding:
				player.phys_gun.push(1.0, 0.1)
			elif event.pressed:
				_wheel_cycle(event)
		MOUSE_BUTTON_WHEEL_DOWN:
			if _holding:
				player.phys_gun.push(-1.0, 0.1)
			elif event.pressed:
				_wheel_cycle(event)


## The wheel, on dot-menu's previous and next weapon actions so a rebind works, when no prop
## is held (a held prop keeps the wheel for push and pull). The press path for a row moved
## onto a key is [method _unhandled_input]'s key branch; a wheel event is never a key, so one
## tick cannot cycle on both.
func _wheel_cycle(event: InputEvent) -> bool:
	if event.is_action_pressed(DotMenuBindings.WEAPON_NEXT_ACTION):
		_cycle_tools(1)
		return true
	if event.is_action_pressed(DotMenuBindings.WEAPON_PREVIOUS_ACTION):
		_cycle_tools(-1)
		return true
	return false


## The tools in hand-order: the physics gun, the gravity gun, then every weapon this server
## offers (the tool gun is one of them). Every entry is selectable, so there is no empty slot
## to skip.
func _tool_ring() -> Array[StringName]:
	var ring: Array[StringName] = [TOOL_PHYS, TOOL_GRAV]
	if playground != null:
		for w in playground.weapons:
			if not ring.has(w.id):
				ring.append(w.id)
	return ring


## One step through [method _tool_ring], wrapping. Nothing while a prop is held, and nothing
## with fewer than two tools.
func _cycle_tools(direction: int) -> void:
	if _holding:
		return
	var ring := _tool_ring()
	if ring.size() < 2:
		return
	var at := ring.find(tool)
	_set_tool(ring[posmod((at if at >= 0 else 0) + direction, ring.size())])


## Q down opens the menu; Q up closes it unless the press was a tap.
##
## [b]One key, two behaviours, and they are not a toggle.[/b] Holding shows the menu
## for as long as you hold it — a glance, with your place kept. Tapping leaves it up,
## which is what you want while building; tapping again puts it away. A plain toggle
## loses the glance, and a plain hold means you cannot let go of the mouse.
func _on_menu_key(key: InputEventKey) -> void:
	if screens == null or menu == null or key.is_echo():
		return

	var id := menu.screen_id()

	if key.pressed:
		_menu_down_at = _now()

		if not screens.is_open(id):
			# Whatever the tools were doing, they stop: the mouse is about to become
			# a cursor, and a physics gun still holding a crate would drag it round
			# the world following a pointer the player is aiming at buttons with.
			_primary_up()
			_secondary_up()
			_rotating = false

			menu.selected = selected_prop
			menu.tool = tool
			screens.push(id)
			_menu_pinned = false

		return

	if _now() - _menu_down_at >= MENU_TAP_SECONDS:
		screens.pop(id)
		_menu_pinned = false
		return

	if _menu_pinned:
		screens.pop(id)
		_menu_pinned = false
		return

	_menu_pinned = true


# --- The profile workbench -------------------------------------------------

## Offline this process is the server, so it is an admin; connected, the server decides and
## the answer to [method _probe_profile_admin] is remembered for the connection.
func _may_edit_profiles() -> bool:
	return bridge == null or _profile_admin


func _toggle_profiles() -> void:
	if screens == null or profile_screen == null:
		return
	if screens.is_open(&"profiles"):
		screens.pop(&"profiles")
	elif not _menu_is_open():
		_open_profiles()


func _open_profiles() -> void:
	if not _may_edit_profiles():
		_probe_profile_admin()
		return
	if screens == null:
		return
	_primary_up()
	_secondary_up()
	_rotating = false
	var _pushed := screens.push(&"profiles")


## The server answers a harmless request by who asked: an unknown profile for an admin, "needs
## cvar" for anybody else. There is no "am I an admin" message, and this is the cheapest honest one.
func _probe_profile_admin() -> void:
	var link: DotNetProfileLink = presentation.profile_link if presentation != null else null
	if link == null:
		if hud != null:
			hud.notice("Profile editing is not available on this server.")
		return
	if _profile_probing:
		return
	_profile_probing = true
	_mute_profile_replies(true)
	var sent := link.submit(DotProfileRuntime.make_request("reset_key", "npc", "", ""))
	if not sent.ok:
		_profile_probing = false
		_mute_profile_replies(false)


func _on_profile_reply(ok: bool, text: String) -> void:
	if not _profile_probing:
		if profile_screen != null:
			profile_screen.on_reply(ok, text)
		return
	_profile_probing = false
	_profile_admin = not text.begins_with("profile edits need")
	_mute_profile_replies(screens != null and screens.is_open(&"profiles"))
	if _profile_admin:
		_sync_profiles_entry()
		_open_profiles()
	elif hud != null:
		hud.notice("Editing profiles needs the server's cvar admin flag.")


func _mute_profile_replies(on: bool) -> void:
	if presentation != null:
		presentation.mute_profile_replies = on


## The Escape menu's entry, there only for somebody who may use it.
func _sync_profiles_entry() -> void:
	if game_menu == null or game_menu.screen == null:
		return
	var actions: Array = game_menu.screen.actions
	var at := -1
	for i in actions.size():
		if (actions[i] as Dictionary).get("id") == &"profiles":
			at = i
	if _may_edit_profiles() and at < 0:
		actions.insert(1, {"id": &"profiles", "text": "Profile workbench"})
	elif not _may_edit_profiles() and at >= 0:
		actions.remove_at(at)
	else:
		return
	game_menu.screen.restyle(game_menu.kit)


## The workbench's test-target buttons, through the paths the Q menu uses.
func _on_profile_target(kind: String, id: String) -> void:
	var rows: Array = playground.addons.describe_items() if playground.addons != null else []
	if kind == "npc":
		if playground.props.catalogue.get_prop(StringName(id)) != null:
			_on_prop_chosen(StringName(id))
			return
		for r: Dictionary in rows:
			if str(r.get("kind")) in ["npc", "bot"] and str(r.get("key")).ends_with("/" + id):
				_on_addon_item_chosen(str(r["key"]))
				return
		return
	if playground.weapon_def(StringName(id)) != null:
		_on_weapon_chosen(StringName(id))
		return
	var best := ""
	for r: Dictionary in rows:
		var key := str(r.get("key"))
		if str(r.get("kind")) == "weapon" and key.get_slice("/", 1).ends_with(id) and (best == "" or key.length() < best.length()):
			best = key
	if best != "":
		_on_addon_item_chosen(best)


## Wall-clock seconds. Presentation only — nothing here is timed, compared or ranked,
## which is why this is not the simulated clock the timer counts in.
func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


# --- The tools -------------------------------------------------------------

func _space() -> PhysicsDirectSpaceState3D:
	return player.get_world_3d().direct_space_state


func _view_basis() -> Basis:
	return Basis(Quaternion.from_euler(Vector3(
		0.0, deg_to_rad(player.controller.state.yaw), 0.0
	)))


func _set_tool(id: StringName) -> void:
	if tool == id:
		# The gun already in hand, picked again (the Q menu, or walked over): ammunition. Asked
		# of the server when there is one, which refills its own rig; the drawn gun takes the
		# count once it is quiet (`PlaygroundPlayerNet._correct_drawn`). Offline it is filled here.
		if _zee_rig() != null and PlaygroundZee.is_zee(playground.weapon_def(id)):
			if bridge != null:
				bridge.ask_weapon(id)
			elif PlaygroundZee.refill(_zee_rig()) and hud != null:
				hud.notice("Ammunition refilled.")
		return

	# Everything is let go of on the way out. A gravity gun that kept carrying a
	# crate after the player switched to the physics gun would have two tools
	# holding one prop, which `DotPropInstance.held_by` refuses — so the physics gun
	# would simply do nothing and there would be nothing on screen to say why.
	_primary_up()
	_secondary_up()

	if weapon != null:
		weapon.holster()
		weapon = null

	tool = id

	# The server holds its own copy, because the server is what actuates a tool against
	# somebody else's prop. A client saying which tool it holds is a request, not a fact.
	#
	# [b]A weapon is asked for too, and for a second reason.[/b] `pg_shop` prices every
	# weapon, and `_give_weapon` is the only thing that charges for one — so a client
	# that armed itself and told nobody got every weapon in the catalogue free, and
	# nobody else was told what it was holding either. The request goes for a tool AND
	# for a weapon; only the id differs.
	if bridge != null:
		if id == TOOL_PHYS or id == TOOL_GRAV:
			bridge.ask_tool(id)
		else:
			# What it throws first, so the toy the server builds is already loaded.
			bridge.ask_arm(selected_prop)
			bridge.ask_weapon(id)

	_disarm_zee()

	if PlaygroundZee.is_zee(playground.weapon_def(id)):
		# A real gun: dot-weapon's machinery, drawn here and decided by the server when
		# there is one. Asked for above like any weapon, so the shop still charges.
		if not _arm_zee(playground.weapon_def(id)):
			tool = TOOL_PHYS
			if hud != null:
				hud.notice("That weapon could not be armed.")
	elif id != TOOL_PHYS and id != TOOL_GRAV:
		# A weapon. Built from its definition, which loads its script by path — see
		# PlaygroundWeapons for why a path and not a class.
		var def := playground.weapon_def(id)
		weapon = PlaygroundWeapons.make(def)

		if weapon == null:
			# The reason is already in the log, in more detail than a notice can
			# carry. Falling back to the physics gun rather than leaving the player
			# holding nothing whose buttons silently do nothing.
			tool = TOOL_PHYS

			if hud != null:
				hud.notice("That weapon could not be loaded.")
		else:
			weapon.equip(playground, def)
			weapon.wielder = player_id
			weapon.armed = selected_prop

			if weapon.has_method("set_mode"):
				var _moded: DotResult = weapon.call("set_mode", tool_mode, tool_mode_settings)

	if menu != null:
		menu.tool = tool

	_sync_hud()

	if hud != null:
		hud.notice(_tool_name().capitalize())


## What is in hand, in words. A weapon's own name, or one of the two guns'.
func _tool_name() -> String:
	if tool == TOOLGUN:
		var held := playground.weapon_def(TOOLGUN) if playground != null else null
		return "%s: %s" % [held.name_or_id() if held != null else "Tool gun", _tool_mode_name()]

	if weapon != null and weapon.def != null:
		return weapon.def.name_or_id()

	var held := playground.weapon_def(tool) if playground != null else null
	if held != null:
		return held.name_or_id()

	return PlaygroundSpawnMenu.name_of_tool(tool)


## Steps through the weapons this server offers, and back to the physics gun.
##
## [b]Round-trips through the physics gun rather than cycling weapons only.[/b] The
## physics gun is the tool a sandbox is actually played with; a cycle that could not
## reach it would leave a player who pressed 3 twice holding a remover with no
## obvious way back.
## The tool gun mode in hand, by its own name. Read off the menu's copy of the modes, which
## exists on a connected client where no tool gun runs.
func _tool_mode_name() -> String:
	if menu != null:
		for mode in menu.call("_tools"):
			if mode.get("id") == tool_mode:
				return str(mode.get("display_name"))
	return String(tool_mode)


func _cycle_weapon() -> void:
	if playground.weapons.is_empty():
		if hud != null:
			hud.notice("This server has no weapons.")
		return

	var index := -1

	for i in range(playground.weapons.size()):
		if playground.weapons[i].id == tool:
			index = i
			break

	if index + 1 >= playground.weapons.size():
		_set_tool(TOOL_PHYS)
		return

	_set_tool(playground.weapons[index + 1].id)


func _primary_down() -> void:
	if bridge != null:
		_net_buttons |= DotFpsCommand.BUTTON_USER_0
		return

	if _zee_rig() != null:
		_zee_buttons |= DotFpsCommand.BUTTON_USER_0
		return

	if weapon != null:
		_report(weapon.primary(
			_space(), player.eye_position(), player.aim_direction()
		))
		return

	match tool:
		TOOL_PHYS:
			_grab()
		TOOL_GRAV:
			_punt()


func _primary_up() -> void:
	_zee_buttons &= ~DotFpsCommand.BUTTON_USER_0

	if bridge != null:
		_net_buttons &= ~DotFpsCommand.BUTTON_USER_0
		return

	if tool == TOOL_PHYS and _holding:
		playground.phys_gun_release(player)
		_holding = false


func _secondary_down() -> void:
	if bridge != null:
		_net_buttons |= DotFpsCommand.BUTTON_USER_1
		return

	if _zee_rig() != null:
		_zee_buttons |= DotFpsCommand.BUTTON_USER_1
		return

	if weapon != null:
		_report(weapon.secondary(
			_space(), player.eye_position(), player.aim_direction()
		))
		return

	match tool:
		TOOL_PHYS:
			# Freezing is the physics gun's right-click everywhere it exists, and it lets
			# go of what it froze — which is what makes building one-handed.
			if _holding:
				var frozen := player.phys_gun.freeze_held()
				_holding = false

				if not frozen.ok and hud != null:
					hud.notice(frozen.error.message)
		TOOL_GRAV:
			var pulled := player.grav_gun.pull(
				_space(), player.eye_position(), player.aim_direction(),
				playground.may_touch_others()
			)
			_pulling = pulled.ok

			if not pulled.ok and hud != null:
				hud.notice(pulled.error.message)


func _secondary_up() -> void:
	_zee_buttons &= ~DotFpsCommand.BUTTON_USER_1

	if bridge != null:
		_net_buttons &= ~DotFpsCommand.BUTTON_USER_1
		return

	if tool == TOOL_GRAV and _pulling:
		player.grav_gun.drop()
		_pulling = false


## Puts a refusal on the HUD, and says nothing about a success.
##
## An empty message is a refusal the player has already been told about through
## another route — `DotPropSpawner.refused`, which the HUD is listening to — and
## printing it again would put the same line on screen twice.
## Instance id -> whether it was in a liquid last frame, for players and props on this end.
var _wet: Dictionary = {}


## A splash where a player or a prop crosses into a liquid, from this end's own copy of the
## map's liquids (both ends build them from the document): nothing on the wire, and a mirror's
## drawn position is what is checked, so a connected client hears what it sees.
func _present_splashes() -> void:
	if presentation == null or playground == null or playground.liquids.is_empty():
		_wet.clear()
		return
	var now: Dictionary = {}
	var bodies: Array[Node3D] = []
	for id in playground.players:
		bodies.append(playground.players[id] as Node3D)
	for prop: DotPropInstance in playground.props.all_props():
		if prop.node is Node3D:
			bodies.append(prop.node as Node3D)
	if bridge != null:
		for behaviour: Variant in bridge.get("_prop_nets").values():
			var mirror: Variant = (behaviour as Object).get("prop")
			if mirror is Node3D and is_instance_valid(mirror):
				bodies.append(mirror as Node3D)
	for body in bodies:
		if body == null or not is_instance_valid(body) or not body.is_inside_tree():
			continue
		var at := body.global_position
		var surface := NAN
		for liquid: Dictionary in playground.liquids:
			# Half a metre over the surface counts: a crate floats with its centre above the
			# water, and asked of the box itself it never went in, so nothing ever splashed.
			var box: AABB = liquid["box"]
			if AABB(box.position, box.size + Vector3(0.0, 0.5, 0.0)).has_point(at):
				surface = box.end.y
				break
		var key := body.get_instance_id()
		now[key] = not is_nan(surface)
		if not is_nan(surface) and _wet.has(key) and not bool(_wet[key]):
			presentation.on_splash(Vector3(at.x, surface, at.z))
	_wet = now


## The tool gun's edit mode picked [param node] (null: nothing), and these are its properties.
## They go into the Q menu as the edit mode's settings, so the next slider moved starts from
## what the prop is rather than from whatever the menu last held.
func _adopt_selection(node: Node3D, prop_name: String, settings: Dictionary, refused: String) -> void:
	var before: Node3D = edit_target

	if menu != null and not settings.is_empty():
		menu.set_tool_settings(EDIT_MODE, settings)
	if tool_mode == EDIT_MODE and not settings.is_empty():
		tool_mode_settings = settings.duplicate()

	edit_target = node if node != null and is_instance_valid(node) else null

	if edit_target != before or _selection_box == null:
		_clear_selection_box()
	if menu != null:
		menu.set_edit_target(prop_name if edit_target != null else "")

	if edit_target != null and _selection_box == null:
		_selection_box = selection_box()
		edit_target.add_child(_selection_box)
		_fit_selection_box()

	if hud == null:
		return
	if refused != "":
		hud.notice(refused)
	elif edit_target != null and edit_target != before:
		hud.notice("Editing %s. Hold %s: its properties are on the Tools tab." % [prop_name if prop_name != "" else "a prop", key_for(PlaygroundBindings.SPAWN_MENU)])
	elif edit_target == null and before != null:
		hud.notice("Nothing selected.")


## An outline round the selected prop, so a player can tell which of twenty identical crates
## the sliders are moving.
##
## [b]An outline, not a see-through box over it.[/b] The first version was a translucent fill
## drawn over the prop, and its render showed a crate painted red reading as pink — in the one
## mode whose sliders include the colour. Here only the back faces of a slightly larger box are
## drawn, so the rim shows round the silhouette and the prop's own faces are left alone.
static func selection_box() -> MeshInstance3D:
	var box := MeshInstance3D.new()
	box.name = "EditSelection"
	box.mesh = BoxMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.35, 0.85, 1.0)
	material.cull_mode = BaseMaterial3D.CULL_FRONT
	box.material_override = material
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return box


## Sized to the prop's mesh every frame, because a resize rebuilds that mesh — on a client,
## when the snapshot carrying the new size arrives, which is after the selection did.
func _fit_selection_box() -> void:
	if _selection_box == null:
		return
	if not is_instance_valid(_selection_box) or edit_target == null or not is_instance_valid(edit_target):
		_selection_box = null
		edit_target = null
		return
	if tool != TOOLGUN or tool_mode != EDIT_MODE:
		_clear_selection_box()
		return
	fit_selection_box(_selection_box, edit_target)


## Sizes [param box], a child of [param target], to the target's drawn mesh. Static so a
## render tool draws exactly what the game does.
static func fit_selection_box(box: MeshInstance3D, target: Node3D) -> void:
	var mesh := target.get_node_or_null("Mesh") as MeshInstance3D
	if mesh == null and target is PlaygroundProp and (target as PlaygroundProp).def != null:
		# A model prop's picture is a node tree, centred on the body: its catalogued extent
		# (the box the hull was fitted to) is the box to draw.
		var body := target as PlaygroundProp
		(box.mesh as BoxMesh).size = PlaygroundProp.extent_of(body.def) * body.size_scale * 1.08 + Vector3.ONE * 0.08
		box.transform = Transform3D()
		return
	if mesh == null or mesh.mesh == null:
		return
	var bounds := mesh.get_aabb()
	(box.mesh as BoxMesh).size = bounds.size * 1.08 + Vector3.ONE * 0.08
	box.transform = Transform3D(Basis(), mesh.transform * bounds.get_center())


func _clear_selection_box() -> void:
	if _selection_box != null and is_instance_valid(_selection_box):
		_selection_box.queue_free()
	_selection_box = null


func _report(result: DotResult) -> void:
	# The edit mode answers a click with what it selected. Offline that is the prop's own
	# node; connected the same report arrives as a SELECTION event instead.
	if result.ok and result.value is Dictionary and (result.value as Dictionary).has("settings"):
		var report: Dictionary = result.value
		_adopt_selection(report.get("node") as Node3D, str(report.get("name", "")),
			report.get("settings", {}), str(report.get("refused", "")))
		return

	if result.ok or hud == null or result.error.message == "":
		return

	hud.notice(result.error.message)


func _grab() -> void:
	var grabbed := playground.phys_gun_grab(
		player, _space(), player.eye_position(), player.aim_direction(), _view_basis(),
		playground.may_touch_others()
	)

	_holding = grabbed.ok

	if grabbed.ok and presentation != null and presentation.audio != null:
		presentation.on_tool_grab()

	if not grabbed.ok and hud != null:
		hud.notice(grabbed.error.message)


func _punt() -> void:
	var punted: DotPropInstance = player.grav_gun.punt(
		_space(), player.eye_position(), player.aim_direction(),
		playground.may_touch_others()
	)
	_pulling = false

	var body := punted.node as Node3D if punted != null else null
	if body != null and presentation != null and presentation.fx != null:
		presentation.on_tool_punt(body.global_position, true)


## The physics gun's beam to the prop it holds, once a frame, from the drawn camera.
##
## [b]Offline only, like the grab and punt sounds.[/b] On a server the gun is the
## server's (`PlaygroundNetBridge._drive_tools`) and `_holding` is never set here, so a
## connected client draws no beam: nothing replicates what a player holds yet.
## Connected, the server holds every prop and says who holds what (`Kind.HELD`): a beam for
## each, [param mine]'s from in front of the camera at [param eye], everybody else's from their
## own eye. Static so `tools/screenshot_net.gd` draws exactly this. Returns how many.
static func present_beams(p_bridge: PlaygroundNetBridge, p_presentation: PlaygroundPresentation,
		mine: Node, eye: Vector3, forward: Vector3) -> int:
	var drawn := 0
	for each: Dictionary in p_bridge.holders():
		var who: Node = each["player"]
		var to: Vector3 = (each["prop"] as Node3D).global_position
		if who == mine:
			var _mine := p_presentation.on_tool_beam(eye, forward, to, 1)
		else:
			var their_eye: Vector3 = who.call("eye_position")
			var _theirs := p_presentation.on_tool_beam(their_eye, (to - their_eye).normalized(), to, who.get_instance_id())
		drawn += 1
	return drawn


func _present_tool_beam(eye: Vector3, forward: Vector3) -> void:
	if bridge != null and presentation != null:
		var _drawn := present_beams(bridge, presentation, player, eye, forward)
		return

	if not _holding or tool != TOOL_PHYS or player == null or presentation == null:
		return

	var held: DotPropInstance = player.phys_gun.held
	var body := held.node as Node3D if held != null else null
	if body != null and body.is_inside_tree():
		presentation.on_tool_beam(eye, forward, body.global_position)


func _physics_process(delta: float) -> void:
	# On a server the tools are actuated by the SERVER from the buttons this client
	# sends — see PlaygroundNetBridge._drive_tools. Running them here as well would be a
	# second, disagreeing simulation of somebody else's rigid body, on a copy that is
	# frozen and drawn from snapshots and could not move anyway.
	if link != null:
		_net_physics(delta)
		return

	if player == null or _covered():
		return

	# Held from the physics loop, because the spring writes a velocity the solver
	# consumes on this step. Doing it in _process writes a velocity that a variable
	# number of physics steps then apply, and the prop jitters at exactly the rate
	# the frame time varies.
	if _holding:
		player.phys_gun.hold(
			player.eye_position(), player.aim_direction(), _view_basis(), delta
		)

	if _pulling:
		player.grav_gun.carry(
			player.eye_position(), player.aim_direction(), delta
		)

	# A weapon gets a tick whether or not a button is down: a charge, a cooldown and
	# a beam are all things that have to run between clicks, and a weapon that were
	# only ticked while firing could not have any of them.
	if weapon != null:
		weapon.tick(
			_space(), player.eye_position(), player.aim_direction(), delta
		)

	# Offline the client IS the server: its rig has the authority and its shots shove.
	var rig := _zee_rig()
	if rig != null:
		var state := player.controller.state
		var outcome := rig.simulate_tick(
			PlaygroundZee.command_for(
				_zee_buttons, state.yaw, state.pitch, PlaygroundZee.slot_of(rig)
			),
			Engine.get_physics_frames()
		)
		var _moved := PlaygroundZee.shove_props(player, outcome, playground.may_touch_others())
		# And the NPCs it hits are hurt, and the ones in earshot hear it.
		playground.player_shots_fired(player_id, outcome)


# --- Props -----------------------------------------------------------------

func _spawn() -> void:
	if selected_prop == &"":
		if hud != null:
			hud.notice("Nothing armed. Hold %s and pick something." % key_for(PlaygroundBindings.SPAWN_MENU))
		return

	# On a server the client asks and the server decides. The budget, the cooldown and
	# the undo stack are the spawner's, and a second copy of those rules here is the bug
	# this family has now shipped three times.
	if bridge != null:
		bridge.ask_spawn_prop(selected_prop)
		return

	var at := player.eye_position() + player.aim_direction() * SPAWN_REACH
	playground.props.spawn(selected_prop, player_id, at)


func _on_prop_chosen(prop_id: StringName) -> void:
	selected_prop = prop_id

	# On a server the toy is the server's, so it has to be told; it keeps the choice for
	# the next toy too.
	if bridge != null:
		bridge.ask_arm(prop_id)

	# The weapon follows what the menu armed, which is what makes the launcher fire
	# a beach ball or a boulder without a second list of ammunition.
	if weapon != null:
		weapon.armed = prop_id

	_sync_hud()
	_spawn()


## What the server says we are holding, which is the only answer that counts.
##
## [b]A refused purchase has to take the weapon back.[/b] `_set_tool` arms locally so a
## weapon switch is not a round trip, which is prediction — and prediction that is never
## corrected is just a client disagreeing with the server. `pg_shop` refuses a weapon a
## player cannot afford, and without this the player kept it: the notice said no and the
## thing was in their hands.
##
## Somebody else's weapon is not applied here. This client draws no first-person weapon
## for a remote player, so there is nothing to apply it to yet — but the id now arrives,
## which is what a third-person model would need.
func _on_weapon_changed(pid: int, weapon_id: StringName) -> void:
	if bridge == null or pid != bridge.local_player_id:
		return
	if weapon_id == tool:
		return

	# Not _set_tool: that would ask the server again, and the server is what just spoke.
	_apply_server_tool(weapon_id)


## Adopt a tool without asking for it. The half of [method _set_tool] that is local.
func _apply_server_tool(id: StringName) -> void:
	_primary_up()
	_secondary_up()

	if weapon != null:
		weapon.holster()
		weapon = null

	tool = id
	_disarm_zee()

	if PlaygroundZee.is_zee(playground.weapon_def(id)):
		if not _arm_zee(playground.weapon_def(id)):
			tool = TOOL_PHYS
	elif id != TOOL_PHYS and id != TOOL_GRAV:
		var def := playground.weapon_def(id)
		weapon = PlaygroundWeapons.make(def)

		if weapon == null:
			tool = TOOL_PHYS
		else:
			weapon.equip(playground, def)
			weapon.wielder = player_id
			weapon.armed = selected_prop

	_sync_hud()


func _on_weapon_chosen(weapon_id: StringName) -> void:
	_set_tool(weapon_id)


func _on_tool_chosen(tool_id: StringName) -> void:
	_set_tool(tool_id)


## A tool picked, or a setting changed, on the Q menu's tools tab. The tool gun comes out if
## it is not already in hand, and is told the mode — this client's own offline, the
## server's otherwise (which keeps the choice for the next tool gun it hands out too).
func _on_tool_mode_chosen(mode: StringName, settings: Dictionary) -> void:
	var switched := mode != tool_mode or tool != TOOLGUN
	tool_mode = mode
	tool_mode_settings = settings

	if tool != TOOLGUN:
		_set_tool(TOOLGUN)

	if bridge != null:
		bridge.ask_tool_mode(mode, settings)
	elif weapon != null and weapon.has_method("set_mode"):
		_report(weapon.call("set_mode", mode, settings))
		# Offline the edit lands here and now; what the prop became goes back to the menu.
		var current: Object = weapon.call("current") if weapon.has_method("current") else null
		if current != null and current.has_method("selection_report"):
			var report: Dictionary = current.call("selection_report")
			_adopt_selection(report.get("node") as Node3D, str(report.get("name", "")),
				report.get("settings", {}), str(report.get("refused", "")))

	if switched:
		_clear_selection_box()

	_sync_hud()

	# What the three buttons now do. Said once, on the change rather than on every setting:
	# a tool gun whose left click means something different from a minute ago is a tool gun
	# nobody can use blind, and a slider dragged across the edit panel is not a new tool.
	if switched and hud != null and menu != null:
		for each in menu.call("_tools"):
			if each.get("id") == mode:
				hud.notice("%s   %s" % [str(each.get("display_name")), "   ".join(each.call("help_lines"))])


func _on_npc_weapon_chosen(weapon_id: StringName) -> void:
	if bridge != null:
		bridge.ask_npc_weapon(weapon_id)
		return

	_report(playground.set_npc_weapon_choice(player_id, weapon_id))


## Right click on a weapon: one on the ground in front of the player, counted against their
## weapons limit like anything else they spawn.
func _on_weapon_spawn_requested(weapon_id: StringName) -> void:
	if bridge != null:
		bridge.ask_spawn_weapon(weapon_id)
		return

	var at := player.eye_position() + player.aim_direction() * SPAWN_REACH
	playground.props.spawn(Playground.pickup_id_of(weapon_id), player_id, at)


## The Builds tab opened. Builds are the server's, so offline there are none to show.
func _on_builds_opened() -> void:
	menu.builds_available = bridge != null
	if bridge != null:
		bridge.ask_builds()
	else:
		menu.set_builds([])


## An addon's entry. The server runs it where the authority is; offline this process is it.
## The point is where the camera looks: the first thing it hits, else twelve metres on.
func _on_addon_item_chosen(key: String) -> void:
	var at := Vector3.ZERO
	var camera := get_viewport().get_camera_3d()

	if camera != null:
		var from := camera.global_position
		var to := from - camera.global_basis.z * 60.0
		var hit := camera.get_world_3d().direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(from, to)
		)
		at = hit["position"] if not hit.is_empty() else from - camera.global_basis.z * 12.0

	if bridge != null:
		bridge.ask_addon_item(key, at)
	else:
		var started := playground.activate_addon_item(key, 0, at, player_id)
		DotLog.result(CHANNEL, "starting an addon item", started)


func _on_build_chosen(build_name: String) -> void:
	if bridge != null:
		bridge.ask_load_build(build_name)


func _on_menu_action(action: StringName) -> void:
	match action:
		&"undo":
			if bridge != null:
				bridge.ask_undo()
			elif not playground.props.undo(player_id) and hud != null:
				hud.notice("Nothing to undo.")
		&"unfreeze":
			_unfreeze_all()
		&"clear":
			if bridge != null:
				bridge.ask_clear_mine()
				return

			var removed := playground.props.clear_player(
				player_id, DotPropSpawner.REASON_PLAYER
			)

			if hud != null:
				hud.notice("Removed %d prop%s." % [
					removed, "" if removed == 1 else "s"
				])


## Thaws every prop this player has frozen.
##
## [b]Never refused, deliberately.[/b] `DotPropSpawner.may_freeze` gates freezing
## against `per_player_frozen`, and the reverse has no limit to check — a cap that
## stopped somebody tidying up would be a limit fighting its own purpose.
## Gets in, or gets out. One key for both.
##
## [b]F rather than E, because E already spawns here.[/b] Worth saying out loud: the
## sandboxes this copies bind "use" to E, and a player arriving from one of those will
## press it — so the day this game gains a use verb of its own, these two want swapping
## together rather than one at a time.
##
## [b]The client never decides the answer.[/b] It asks; the server owns the seats, the
## exit sweep and the refusal, exactly as it owns a spawn. On a client with no bridge —
## single player, and the suite — the same call goes straight to the simulation, which is
## the same division every other verb in this file makes.
func _use_vehicle() -> void:
	if bridge != null:
		bridge.ask_use_vehicle()
		return

	var used := playground.use_vehicle(player_id)

	if not used.ok:
		_report(used)


func _unfreeze_all() -> void:
	var thawed := 0

	for prop in playground.props.props_of(player_id):
		if not prop.frozen:
			continue

		DotPhysGun.set_frozen(prop, false)
		thawed += 1

	if hud != null:
		hud.notice("Unfroze %d prop%s." % [thawed, "" if thawed == 1 else "s"])


# --- A run timer's keys ------------------------------------------------------
#
# The track and the practice checkpoints are a run timer's, and none ships: the keys are
# handed to `addons/pg_timer` when a server added dot-timer, and say so when it did not.

func _timer_key(action: StringName) -> void:
	if playground.run_timer != null and playground.run_timer.has_method("on_key"):
		playground.run_timer.call("on_key", action, player_id, hud)
	elif hud != null:
		hud.notice("No run timer on this server.")


# --- Styles, tracks and maps -----------------------------------------------

func _cycle_style() -> void:
	var styles := playground.style_order

	if styles.is_empty():
		return

	_style_index = (_style_index + 1) % styles.size()

	var chosen: DotFpsStyle = playground.movement_styles[styles[_style_index]]

	if bridge != null:
		# The server owns which style a player is on: it decides what the movement IS,
		# and both ends have to derive the same tunables or prediction diverges.
		bridge.ask_style(chosen.id)
		return

	if playground.set_player_style(player_id, chosen.id) and hud != null:
		hud.notice("Style: %s" % chosen.display_name)


## First person to third and back, through the controller switch.
##
## [b]A different motor, not a moved camera[/b] — which is the distinction that decides
## where this feature belongs. game-g2gfast has a third-person view and keeps one motor
## under it on purpose: a run set in third person has to be comparable with one set in
## first. A sandbox ranks nothing, so it can afford the better third-person movement —
## camera-relative input, an orbit rig on a spring arm, coyote time and a jump buffer.
func _toggle_view() -> void:
	if player == null or player.controller_switch == null:
		return

	# Where the server's `mp_forceview` allows: the other view, or a line saying why not.
	var third := player.view_mode() == &"tp"
	var wanted := playground.view_rules.toggled(third)
	if wanted == third:
		if hud != null and playground.view_rules.refusal() != "":
			hud.notice(playground.view_rules.refusal())
		return

	var now := player.set_view_mode(wanted)
	_guard_rig()
	if hud != null:
		hud.notice("View: %s" % ("third person" if now == &"tp" else "first person"))


## The server changed `mp_forceview`: the view it allows now.
func _on_view_rules_changed() -> void:
	if player == null or player.controller_switch == null:
		return
	var third := player.view_mode() == &"tp"
	var allowed := playground.view_rules.resolve(third)
	if allowed != third:
		var _now := player.set_view_mode(allowed)
		_guard_rig()


## The third-person rig's boom stops at the level and props, never people, and its fade is
## handed the other players (they have no collider the fade's query would find while
## mp_solidplayers is 0).
func _guard_rig() -> void:
	var rig: DotTpsCameraRig = player.tps.rig if player != null and player.tps != null else null
	if rig == null or rig.arm == null:
		return
	var layout: DotPhysicsLayout = playground.player_stack.physics.layout \
		if playground.player_stack != null and playground.player_stack.physics != null else null
	if layout != null:
		rig.arm.collision_mask = layout.mask_of([&"world", &"prop"])
	if rig.fade != null:
		rig.fade.bodies_fn = _other_players


## Everybody but this player, for the camera fades.
func _other_players() -> Array:
	var out: Array = []
	if playground == null:
		return out
	for id in playground.players:
		var other: Node3D = playground.players[id]
		if other != player and is_instance_valid(other):
			out.append(other)
	return out


## What M lists solo: every map in the catalogue, the kind as the mode and the tier under it.
## Connected the server's own list is drawn instead (dot-vote's map menu).
func map_menu_rows() -> Array:
	var out: Array = []
	if playground == null or playground.maps == null or playground.maps.catalogue == null:
		return out
	var here := playground.maps.current.id if playground.maps.current != null else &""
	for def in playground.maps.catalogue.available():
		out.append({"id": String(def.id), "name": def.name_or_id(), "mode": String(def.kind).capitalize(),
			"detail": "tier %d" % def.tier if def.tier > 0 else "", "current": def.id == here})
	return out


## Solo: [param id] now. A client does not change the map when connected: one client loading
## a different world from everybody else is not a map change, it is a client playing alone in
## a world nobody else is in; the server's map menu decides there.
func change_from_menu(id: StringName) -> DotResult:
	if bridge != null:
		return DotResult.fail(DotError.CODE_STATE, "The server changes the map.")
	return await playground.change_map(id)


# --- The loadout menu (B) -----------------------------------------------------

## What B says outside the arena (the server's `closed_fn` says the same).
const LOADOUT_ARENA_ONLY := "Loadouts are in the arena."

## dot-menu's loadout menu, or null on a host whose dot-menu predates it (API 6).
var loadout_menu: Object = null

## Whether the server's arena is on (`pg_arena_on`, replicated). Never offline: the arena is a
## server's mode, and the loadout manager lives in it.
var arena_on: bool = false


## B: the arena's loadout, which weapon an arena spawn puts in your hands. Connected the server
## answers (dot-loadout's `/loadout`); the menu is enabled only while the arena is on, and
## outside it B says "Loadouts are in the arena" (the lead's call, 2026-10-12). Guarded on the
## host's dot-menu and dot-loadout levels.
## Escape's Mods action: the player's own override of the console's look, solo or listen host only
## (the platform turns the user tier on). By name, so an older client shell just has no action.
func _use_mods_menu() -> void:
	if platform == null or not platform.user_tier_on or game_menu == null or not game_menu.has_method(&"use_mods"):
		return
	var console_node: Object = platform.console
	if console_node != null and console_node.get(&"config") is DotConsoleConfig:
		var _applied := (console_node.get(&"config") as DotConsoleConfig).apply_cfg_file()
	var base := DotConsoleConfig.new()
	var schema: Array = [
		DotProfileSet.field("height_fraction", "float", base.height_fraction, {"min": 0.1, "max": 1.0}),
		DotProfileSet.field("background_opacity", "float", base.background_opacity, {"min": 0.0, "max": 1.0}),
		DotProfileSet.field("font_size", "int", base.font_size, {"min": 6, "max": 48}),
	]
	var editor := DotAddonConfigEditorScreen.new()
	editor.add_file(DotConsoleConfig.CFG_ADDON, "console.yml", schema, "Console")
	game_menu.call(&"use_mods", editor)
	# After use_mods: a form built while the editor is outside the tree leaks at exit.
	var _opened := editor.open(DotConsoleConfig.CFG_ADDON, "console.yml")


func _use_loadout_menu() -> void:
	if DotAddonApi.build_level("dot_menu") < 6 or DotAddonApi.build_level("dot_loadout") < 2:
		return
	if game_menu == null or not game_menu.has_method(&"use_loadout"):
		return
	loadout_menu = game_menu.call(&"use_loadout",
		func() -> Variant: return DotResult.fail(DotError.CODE_STATE, LOADOUT_ARENA_ONLY),
		func(_picks: Dictionary) -> Variant: return DotResult.fail(DotError.CODE_STATE, LOADOUT_ARENA_ONLY),
		decorate_loadout_choice)
	if loadout_menu != null:
		loadout_menu.set(&"title", "Arena loadout")
		# Remembered on this device and sent again on the next join, never under a suite's or a
		# render's scratch settings.
		var scratch := PlaygroundPresentation.settings_directory.begins_with("user://scratch/")
		loadout_menu.call(&"remember_as", "" if scratch else "playground", "local")
		loadout_menu.set(&"enabled", arena_on)


## Follows the server's `pg_arena_on` through [param source] (the client link).
func _follow_arena(source: Object) -> void:
	if source == null or not source.has_method(&"replicated_cvar") or not source.has_signal(&"replicated_cvar_changed"):
		return
	_set_arena_on(String(source.call(&"replicated_cvar", "pg_arena_on", "0")) == "1")
	source.connect(&"replicated_cvar_changed", func(cvar_name: String, value: String) -> void:
		if cvar_name == "pg_arena_on":
			_set_arena_on(value.strip_edges() == "1"))


func _set_arena_on(on: bool) -> void:
	var was := arena_on
	arena_on = on
	if loadout_menu != null:
		loadout_menu.set(&"enabled", on)
		if on and not was:
			# Into the arena: the choice made last time, sent again once.
			var _sent: Variant = loadout_menu.call(&"restore")


## A card's picture (the spawn menu's weapon icon) and, for a zee gun, zee's numbers.
func decorate_loadout_choice(_slot_id: String, choice: Dictionary) -> Dictionary:
	var def := playground.weapon_def(StringName(str(choice.get("id", "")))) if playground != null else null
	if def == null:
		return {}
	var out: Dictionary = {}
	var icon := PlaygroundIcons.for_weapon(def)
	if icon != null:
		out["icon"] = icon
	if PlaygroundZee.is_zee(def) and DotAddonApi.build_level("zee_weapons") >= 3:
		var cards_path := "res://addons/zee_weapons/content/zee_weapon_cards.gd"
		var zee_def: DotWeaponDef = PlaygroundZee.catalogue().get_def(PlaygroundZee.zee_id(def))
		if zee_def != null and ResourceLoader.exists(cards_path):
			var card: Variant = (load(cards_path) as Script).call(&"card", zee_def)
			if card is Dictionary:
				out.merge(card as Dictionary)
	return out


# --- zee-dot-weapons --------------------------------------------------------

## The rig in this client's own player's hands, or null.
func _zee_rig() -> ZeeWeaponRig:
	if player == null or not is_instance_valid(player):
		return null
	var rig: Variant = player.zee_rig
	if rig is ZeeWeaponRig and is_instance_valid(rig):
		return rig as ZeeWeaponRig
	return null


## Builds the hands under the camera and a rig to drive them.
##
## [b]The rig has the authority only offline.[/b] Connected, the server holds the rig that
## decides (`PlaygroundNetBridge._give_weapon`) and this one is the gun that moves: a
## player whose weapon never deploys, kicks or reloads cannot tell one that is ready from
## one that is not.
func _arm_zee(def: PlaygroundWeaponDef) -> bool:
	if player == null or camera == null:
		return false

	zee_view = ZeeViewModel.new()
	zee_view.name = "ZeeViewModel"
	camera.add_child(zee_view)

	var rig := PlaygroundZee.arm(
		player, def, ZeeWeaponRig.Role.LOCAL, bridge == null,
		playground.tick_rate, Engine.get_physics_frames(), zee_view
	)

	if rig == null:
		_disarm_zee()
		return false

	# Connected, the server's WEAPON event draws it (`PlaygroundNetBridge`); offline nobody
	# sends one, and the gun still belongs in the hands a third-person camera shows.
	if bridge == null:
		PlaygroundZee.show_held(player, def)

	return true


func _disarm_zee() -> void:
	if player != null and is_instance_valid(player):
		PlaygroundZee.disarm(player)
		if bridge == null:
			PlaygroundZee.show_held(player, null)

	if zee_view != null and is_instance_valid(zee_view):
		zee_view.queue_free()
	zee_view = null

	_zee_buttons = 0
	_net_buttons &= ~DotFpsCommand.BUTTON_USER_2


func _set_reload(down: bool) -> void:
	# Offline, a toy's reload — the tool gun's third button — is run here, on the press.
	# Online it rides the same bit the zee weapons' reload does, and the server runs it.
	if down and bridge == null and weapon != null and _zee_rig() == null:
		_report(weapon.reload(_space(), player.eye_position(), player.aim_direction()))

	if down:
		_zee_buttons |= DotFpsCommand.BUTTON_USER_2
		_net_buttons |= DotFpsCommand.BUTTON_USER_2
	else:
		_zee_buttons &= ~DotFpsCommand.BUTTON_USER_2
		_net_buttons &= ~DotFpsCommand.BUTTON_USER_2


## Sway, bob and the hands hidden in third person, once a frame. Returns the camera's half
## of the recoil (degrees, x pitch y yaw), which the camera write adds: presentation only, the
## command's angles and so the shot are untouched. It went to a `DotFpsView` that nothing ran
## until 2026-10-11, so no zee gun ever kicked the view here.
func _present_zee() -> Vector2:
	var rig := _zee_rig()

	if rig == null or zee_view == null:
		return Vector2.ZERO

	zee_view.visible = player.view_mode() != &"tp"
	# Down the sights: only first person, with the pointer on the view and no menu up.
	var hands := zee_view as ZeeViewModel
	if hands != null:
		hands.aim(_aiming and mouse_drives_view() and not _menu_is_open() and player.view_mode() != &"tp")
	var state := player.controller.state
	rig.drive_view(Vector2.ZERO, player.speed(), state.is_grounded(), state.is_crouched())
	return rig.view_punch()


func _exit_tree() -> void:
	if presentation != null and presentation.profile_link != null:
		presentation.profile_link.release()
		presentation.profile_link = null
	# A static outlives the game: the next one the shell loads must not look for its art here.
	PlaygroundZee.release_art()


## Where a roster row's player stands, for dot-game's look-to-gag key (J, L).
func _look_position(row: Dictionary) -> Variant:
	if playground == null:
		return null
	for who: PlaygroundPlayer in playground.players.values():
		if who != player and who.display_name == row["name"]:
			return who.global_position + Vector3.UP * 1.5
	return null
