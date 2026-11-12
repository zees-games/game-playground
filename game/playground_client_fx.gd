extends "playground_client_net.gd"


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


## The escape menu: dot-menu's, with this game's settings on its pages and the server list as a
## sidebar action. Escape keeps its two steps (first releases the pointer, second opens the menu;
## see KEY_ESCAPE in `_unhandled_input`), so the menu does not open on Escape but still closes on it.
func _build_pause() -> void:
	var settings: DotSettingsManager = presentation.settings if presentation != null else null

	# Keys on the InputMap before anything reads them: help key, movement and this client's own.
	keys = PlaygroundBindings.make()
	if settings != null:
		keys.apply_all(settings)

	game_menu = DotMenu.new()
	game_menu.name = "GameMenu"
	game_menu.settings = settings
	game_menu.bindings = keys
	var config := DotMenuConfig.new()
	config.brand_name = "Playground"
	# By name: an older dot-menu has no such property, and assigning it would stop this function.
	if &"menu_button_corner" in config:
		config.set(&"menu_button_corner", &"top_left")
	var _layered := config.load_layered()
	game_menu.config = config
	game_menu.open_on_escape = false
	game_menu.manage_pointer = false
	# Leave is dot-menu's: off the server when connected, a quit solo on a desktop.
	game_menu.leave_on_its_own = true
	add_child(game_menu)
	var _set := game_menu.setup()
	# The platform takes the menu, then builds the console after it so DotConsoleKit registers
	# it as one of the menu's overlays.
	platform.board_snapshot_fn = board_snapshot
	platform.board_prepare_fn = _prepare_board
	platform.adopt_menu(game_menu)
	var _platform_up := platform.setup()
	if DotAddonApi.build_level("dot_game") >= 38:
		platform.add_store_panel(game_menu, func() -> String:
			var auth: Object = DotRegistry.get_node_service(&"dot_auth_client")
			if auth == null or not is_instance_valid(auth) or not auth.has_method(&"account_key"):
				return ""
			return str(auth.call(&"account_key")))
	var _flinch := platform.add_hit_flinch(
		active_sampler,
		func() -> Variant: return camera if view_id() == &"fp" else null,
		func() -> bool: return _aiming and mouse_drives_view() and not _menu_is_open() and view_id() == &"fp")
	# The starter set: the equipped list needs a credential the client does not hold (the server reads it).
	DotLog.result("playground.client", "avatar actions", platform.add_avatar_actions(net, _avatar_figure))
	_add_noblock_and_workbench()
	if presentation != null:
		presentation.adopt_console(platform.add_console(presentation.settings) as DotConsoleController)

	add_general_rows(game_menu)
	fill_help(game_menu.help)
	_follow_hud()
	game_menu.screen.actions.insert(0, {"id": &"servers", "text": "Servers"})
	game_menu.screen.restyle(game_menu.kit)
	_sync_profiles_entry()

	# M: the maps. Solo a choice changes the map at once; connected the server decides by
	# `sv_map_menu_flag`, and anybody without it gets a vote. By name, so an older shell still runs.
	if game_menu.has_method(&"use_maps"):
		var _maps: Variant = game_menu.call(&"use_maps", map_menu_rows, change_from_menu)
	_use_loadout_menu()
	_use_mods_menu()
	game_menu.action_requested.connect(_on_menu_action_chosen)
	game_menu.overlays_changed.connect(func(_open: bool) -> void:
		# At once, not at the platform's next poll.
		platform.refresh_blocked())

	if settings != null:
		applier = DotMenuApplier.new()
		applier.name = "Applier"
		applier.settings = settings
		applier.bindings = keys
		add_child(applier)
		var _applied := applier.setup()
		_bind_look()


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
	# Once a frame, with the camera position: dot-audio and dot-fx do not tick themselves,
	# and `_process` does not run while paused.
		var eye := camera.global_position if camera != null and camera.is_inside_tree() \
			else Vector3.ZERO
		var forward := -camera.global_transform.basis.z \
			if camera != null and camera.is_inside_tree() else Vector3.FORWARD
		if platform != null and platform.slide_sounds != null and presentation.steps != null:
			presentation.steps.surf_rules = platform.slide_sounds.get(&"surf_rules")
		presentation.present(_delta, eye, forward)
		presentation.keep_walkers(playground.players.values())
		var stack_now := playground.player_stack
		if stack_now != null and stack_now.physics != null and stack_now.physics.layout != null and camera != null:
			presentation.follow_roof(_delta, eye, camera.get_world_3d().direct_space_state, stack_now.physics.layout.mask_of([&"world"]))
			var shot_rig: Object = _zee_rig()
			if shot_rig != null and is_instance_valid(shot_rig) and shot_rig.has_method(&"shot_fx"):
				var shot_fx: Object = shot_rig.call(&"shot_fx")
				if shot_fx != null:
					shot_fx.set(&"roof", presentation.shot_roof)
		_present_tool_beam(eye, forward)

	var _bodies := present_frame(net, playground, -1.0, player)
	_present_splashes()
	_fit_selection_box()

	# After the interpolation, so a remote player's marker is placed where this frame
	# draws them rather than where the last frame did.
	_present_beacons(_delta)

	# `is_inside_tree`, not just null: a camera whose parent was freed is live but out of the
	# scene, and writing its transform errors every frame.
	if player == null or camera == null or not camera.is_inside_tree():
		return

	if not player.is_inside_tree():
		return

	var punch := _present_zee()

	# The camera follows the SIMULATED eye, not a parented node: the sim steps per tick and a
	# parented camera would judder. Shake is added on the drawn camera, never to the aim.
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
	_present_view_arms(_delta)
	if hud != null:
		hud.follow_hands(hands)


## Sway, bob and the hands hidden in third person, once a frame. Returns the camera's half of the
## recoil (degrees, x pitch y yaw), which the camera write adds: presentation only, the command's
## angles and so the shot are untouched.
## Whether the sights may come up: only first person, with the pointer on the view, no menu up, a zee gun in hand and the player alive.
func _aim_may() -> bool:
	return _zee_rig() != null and mouse_drives_view() and not _menu_is_open() and view_id() == &"fp" and player != null and not player.downed


## What the command says about the sights: the view model's own state (a toggle in the rules reaches the server's spread and pace as it does the
## picture), and nothing when the sights may not come up.
func _aim_sent() -> bool:
	var hands := zee_view as ZeeViewModel if zee_view != null and is_instance_valid(zee_view) else null
	return _aim_may() and (hands.is_aim_held() if hands != null else _aiming)


func _present_zee() -> Vector2:
	if toy_view != null and is_instance_valid(toy_view):
		toy_view.visible = view_id() == &"fp"

	var rig := _zee_rig()

	if rig == null or zee_view == null:
		return Vector2.ZERO

	zee_view.visible = view_id() == &"fp"
	# Down the sights: only first person, with the pointer on the view and no menu up.
	var hands := zee_view as ZeeViewModel
	if hands != null:
		hands.aim_input(_aiming and _aim_may())
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
