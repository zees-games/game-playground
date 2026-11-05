extends "res://game/playground_client_fx.gd"



func _ready() -> void:
	# First, before anything can be drawn: the map arrives after this node is in the tree.
	_build_gate()

	playground = Playground.new()
	playground.name = "Playground"

	# A networked client is not authoritative, and this is where that is decided: set afterwards,
	# `Playground._ready` would already have spent a map load believing it owned the world.
	if config == null:
		config = PlaygroundConfig.new()

	# zee-dot-weapons' art is this game's copy of it, wherever this game is mounted.
	PlaygroundZee.use_this_games_art()

	# Looked up when nobody handed it over: a pack's client scene is instantiated by
	# `DotClientLink._on_load_game`, which sets nothing on it. The export still wins, so two shells
	# in one process keep their own links.
	if link == null and not platform.offline:
		link = platform.link as Node

	if link != null:
		config.authoritative = false

	# Before the playground: `Playground._ready` loads its first map inside `add_child`, and a
	# generated map asks `DotRegistry` for a seed source then. One registered afterwards is silently
	# ignored (a fixed seed is a legitimate fallback).
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

	# The playground loads its own first map and this waits for it: `initial_map` is layered config, so loading
	# one here would ignore --pg-map. `booted` is checked BEFORE the await: change_map can finish without
	# suspending, ready_for_players is then already emitted, and awaiting it hangs on a black screen.
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

		# The view is NOT built here on a networked client: the camera is parented to the player, which does not
		# exist until JOIN lands (HELLO names you, JOIN creates you), so add_child would run on null.
		# In a WASM build that is a hard `RuntimeError: null function`. [method _adopt] builds it on JOIN.
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
	hud.flash_source = presentation.fx if presentation != null else null
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


## Brings up the netcode and points it at the server's link, as the proven sibling client does.
func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var net_config := DotNetConfig.new()
	net_config.tick_rate = playground.tick_rate
	net_config.snapshot_rate = Playground.snapshot_rate_for(playground.tick_rate)
	net_config.enable_prediction = true
	net_config.enable_lag_compensation = false
	net_config.max_entities_per_snapshot = 0
	net_config.world_extent = 512.0
	# Both default off, else every snapshot replays the whole input lead. By name: a pack runs on its shell's dot-net.
	if &"reconcile_once_per_frame" in net_config:
		net_config.set(&"reconcile_once_per_frame", true)
	if &"skip_matching_replays" in net_config:
		net_config.set(&"skip_matching_replays", true)
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

	# Before the seal and in the server's order (after the bridge), or the actions stay local.
	DotLog.result("playground.client", "avatar action message", DotGameAvatarActionMessage.register(net))
	workbench_remote = DotGameWorkbenchRemoteClient.attach(net)
	net.messages.seal()

	bridge.hello_received.connect(_on_hello)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.weapon_changed.connect(_on_weapon_changed)
	# dot-server's `chat_received` is NOT connected: [DotChatRouter] routes every line, and both would draw it twice.
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
	# The server's sv_ragdoll* set: this end draws the bodies.
	if link != null:
		var _bodies := playground.ragdoll_rules.follow_cvars(link)
		var _drops = playground.weapon_layer.rules.follow_cvars(link)
		var _toy_rules := playground.toy_rules.follow_cvars(link)
		# The server's mp_forceview and mp_solidplayers: this end places its own camera and
		# predicts its own player.
		var _view := playground.view_rules.follow_cvars(link)
		var _solid := playground.body_rules.follow_cvars(link)
		var _ambient := playground.ambient_rules.follow_cvars(link)
		_follow_arena(link)
	# The server's pg_ambient* set drives the quiet layer; the player's sliders multiply on top.
	if presentation != null and presentation.ambient != null:
		presentation.ambient.follow_settings(presentation.settings, playground.ambient_rules)
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

	# Stock tunables until there is a player to ask; _adopt swaps them in when JOIN arrives.
	_sampler = DotFpsSampler.new(DotFpsTunables.new())
	DotFpsSampler.register_default_actions(_sampler)

	# Nothing may be sent before the peer says it can receive: dot-server's signon ends before
	# this scene exists, so earlier sends hit a missing node and the client never joins.
	if link.has_method("is_playing") and bool(link.call("is_playing")):
		bridge.ask_ready()
		workbench_remote.ask()
	elif link.has_signal("spawned"):
		link.connect("spawned", bridge.ask_ready, CONNECT_ONE_SHOT)
		link.connect("spawned", workbench_remote.ask, CONNECT_ONE_SHOT)

	# Nothing in dot-net writes an RTT sample; without one the clock believes the link is instant.
	if link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	return net.start()


func _unhandled_input(event: InputEvent) -> void:
	if _covered():
		return

	# The console first: this client reads bare letters (Q, 1, 2, F, E), so typing `seed` at the console would act.
	if presentation != null and presentation.swallows_input():
		return

	# Voice first, before the player check: somebody mid-signon or spectating can still talk, and a swallowed
	# release leaves the microphone open. `handle_event` sees both edges.
	if voice != null and voice.handle_event(event):
		get_viewport().set_input_as_handled()
		return

	# A click on the world with the pointer released takes it back and does nothing else: the
	# platform captures it first, and `_was_driving` (last frame's answer) says this click took the
	# pointer. Before the `player == null` guard, so a click while the world loads is not swallowed.
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

	# Everything below moves the world; a click on a menu's own background would arrive here.
	if _menu_is_open() and not _is_menu_key(event):
		return

	if event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
		return

	if event is InputEventJoypadButton:
		_wheel_cycle(event)
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

	if key.is_action(PlaygroundBindings.DROP_WEAPON) and key.pressed and not key.is_echo() and _zee_rig() != null:
		bridge.ask_drop_weapon()
		return
	# R reloads a gun (the tool gun's R is its third button), else unfreezes; read on both edges.
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
			playground.undo(player_id)
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
	elif key.is_action(PlaygroundBindings.STYLE):
		# Tab is the scoreboard, held, as in every game here; the style moved to N.
		_cycle_style()
	elif key.is_action(DotMenuBindings.LOADOUT_ACTION) and loadout_menu != null and not arena_on:
		# B opens the loadout only in the arena (the menu is disabled outside it, so the key
		# reaches here): said, rather than a key that does nothing.
		if hud != null:
			hud.notice(LOADOUT_ARENA_ONLY)
	elif key.is_action(PlaygroundBindings.VIEW):
		# The usual third-person toggle. It hands the player to a different CONTROLLER, so the
		# handover carries position, velocity and look: pressing it mid-jump must not stop you dead.
		_toggle_view()

	match key.physical_keycode:
		KEY_ESCAPE:
			# Only when no screen is up (the stack pops menus itself). Release, THEN open, never capture:
			# a browser refuses pointer lock just after Escape.
			if not _menu_is_open() and game_menu != null:
				game_menu.open()
