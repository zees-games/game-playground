extends "playground_client_ui.gd"


func _wire_presentation() -> void:
	if presentation == null or presentation.settings == null \
			or presentation.audio == null or presentation.fx == null:
		return

	if presentation.ambient != null:
		presentation.ambient.map_lookup = func(id: StringName) -> Variant: return playground.maps.catalogue.get_map(id)

	# Both ends: a map change frees the world the live effects are parented into.
	playground.maps.changed.connect(
		func(map: DotMapDef, _loaded: Node) -> void: presentation.on_map_changed(map.id if map != null else &"")
	)
	# Glass breaking is heard on both ends: offline the game breaks it, connected the server's
	# PANE event does, and either way the signal is this end's.
	playground.pane_broken.connect(func(_index: int, at: Vector3, _material: StringName) -> void:
		presentation.on_pane_broken(at)
	)

	playground.prop_shattered.connect(presentation.break_fx.shatter)

	playground.undone.connect(_on_undone)

	if playground.projectiles != null:
		var layer := playground.projectiles
		layer.utility.connect(presentation.on_grenade_fx)
		# Connected, the server's BLIND says it; offline this world decides who a flash caught.
		if bridge == null:
			layer.effects.blinded.connect(func(id: StringName, seconds: float, strength: float) -> void:
				if id == player_id:
					layer.blind_remote(seconds, strength))

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


func _on_hello(id: int) -> void:
	player_id = StringName("u%d" % id)

	if hud != null:
		hud.bind(playground, player_id)

	_adopt()


## [b]HELLO names you and JOIN creates you, in that order.[/b] Looking the player up on HELLO
## alone gets null and never tries again, which leaves a client with a dead mouse and keyboard.
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


## The client's tick, driven by the netcode clock rather than the engine's frame: the engine's
## rate and the server's need not agree (the bridge adopts the server's on HELLO).
func _net_physics(delta: float) -> void:
	if net == null or bridge == null or not net.is_running():
		return

	var ticks := net.clock.advance(delta)

	var sampler := active_sampler()

	# The clock above has advanced; only the sampling waits, so the mouse does not pile up
	# a turn behind the cover and the server sees an idle body until it lifts.
	if sampler == null or _covered():
		return

	# Each pass is its own tick: `advance` has already moved the clock by all of them, so `input_tick()` is the LAST one on every pass; subtract the passes still to come.
	# Arithmetic here, not a new dot-net call, so a pack runs on any client shell.
	for i in range(ticks):
		if net.clock.is_synced():
			var tick := net.clock.input_tick() - (ticks - 1 - i)
			var command := sampler.sample(delta)
			command.buttons |= _net_buttons
			bridge.client_tick(tick, command, _aim_sent())

			# The hands, from the same command the server will run. No authority: what it
			# fires is drawn and heard here and decided there.
			var rig := _zee_rig()
			if rig != null:
				var drawn_command := PlaygroundZee.command_for(
					command.buttons, command.yaw, command.pitch, PlaygroundZee.slot_of(rig), _aim_sent()
				)
				var drawn := rig.simulate_tick(drawn_command, tick)
				var _flown := bridge.predict_launches(drawn, player)
				# How long it has been quiet, so the server's count may correct it
				# (`PlaygroundPlayerNet._correct_drawn`) without undoing a shot in flight.
				PlaygroundZee.note_drawn(player, rig, drawn_command, 1.0 / float(maxi(playground.tick_rate, 1)))


func _build_view() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 100.0
	camera.current = true
	player.add_child(camera)
	_build_view_arms()
	_arm_toy_view(tool)

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


## Builds the third-person controller and the switch, on the local player only. Not in
## `Playground.add_player`: `samples_input` is set by this client after the player is made, so a
## switch built there would see a non-local player and build nothing (F5 does nothing).
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

## A hit of this player's the server confirmed: the marker and the number on the body.
func _on_hit(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
	if hud != null:
		hud.confirm_hit(victim, amount, point, killed, headshot)
	_draw_body_hit(_zee_rig(), point)
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	if presentation != null and presentation.decals != null and camera != null:
		var _blood := presentation.on_body_hit(victim, point, camera.global_position)


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


## The wheel on dot-menu's previous and next weapon actions (so a rebind works) and the pad
## shoulders. A held prop keeps the wheel for push and pull; a wheel event is never a key, so
## one tick cannot cycle on both paths.
func _wheel_cycle(event: InputEvent) -> bool:
	if _wheel == null:
		_wheel = DotWeaponWheel.new()
		_wheel.ring_provider = _tool_ring
		_wheel.current_provider = func() -> Variant: return tool
		_wheel.blocked = func() -> bool: return _holding
		_wheel.chosen.connect(func(id: Variant) -> void: _set_tool(id))
	return _wheel.handle_event(event)


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

	# Everything is let go of on the way out: a gravity gun still carrying a crate after the switch
	# to the physics gun would mean two tools holding one prop, which `DotPropInstance.held_by`
	# refuses, so the physics gun would do nothing with nothing on screen to say why.
	_primary_up()
	_secondary_up()

	if weapon != null:
		weapon.holster()
		weapon = null

	tool = id

	# The server holds its own copy: it actuates a tool against somebody else's prop, so a client
	# saying which tool it holds is a request, not a fact. A weapon is asked for too: `pg_shop`
	# prices every weapon and `_give_weapon` is the only thing that charges for one.
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

	_arm_toy_view(tool)
	_sync_hud()

	if hud != null:
		hud.notice(_tool_name().capitalize())


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
	if toy_view != null and is_instance_valid(toy_view):
		(toy_view as DotToolView).kick()
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


func _physics_process(delta: float) -> void:
	# On a server the SERVER actuates the tools from this client's buttons (PlaygroundNetBridge.
	# _drive_tools). Running them here too would be a second, disagreeing simulation of a rigid body
	# that is frozen and drawn from snapshots here.
	if link != null:
		_net_physics(delta)
		return

	if player == null or _covered():
		return

	# Held from the physics loop, because the spring writes a velocity the solver consumes on this
	# step. In _process a variable number of physics steps apply it, and the prop jitters at the
	# rate the frame time varies.
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
				_zee_buttons, state.yaw, state.pitch, PlaygroundZee.slot_of(rig), _aim_sent()
			),
			Engine.get_physics_frames()
		)
		var _moved := PlaygroundZee.shove_props(player, outcome, playground.may_touch_others())
		# And the NPCs it hits are hurt, and the ones in earshot hear it.
		playground.player_shots_fired(player_id, outcome)


## What the server says we are holding, the only answer that counts. A refused purchase has to
## take the weapon back (`_set_tool` arms locally as prediction, `pg_shop` may refuse). Another
## player's weapon is not applied: no first-person weapon is drawn for a remote player.
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

	_arm_toy_view(tool)
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


## B: the arena's loadout, which weapon an arena spawn puts in your hands. Connected the server
## answers (dot-loadout's `/loadout`); enabled only while the arena is on, and guarded on the
## host's dot-menu and dot-loadout levels. Escape's Mods action: the player's own look override.
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
		# Connected, the menu asks the server's `/loadout locked`; there is no solo loadout here.
		if DotAddonApi.build_level("dot_game") >= 40:
			platform.add_loadout_store(loadout_menu, func() -> Object: return null, func() -> String: return "")
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


## The rig in this client's own player's hands, or null.
## Whether the sights are up in the command. Overridden by the client half that owns the key and the view (`playground_client_fx.gd`).
func _aim_sent() -> bool:
	return false


func _zee_rig() -> ZeeWeaponRig:
	if player == null or not is_instance_valid(player):
		return null
	var rig: Variant = player.zee_rig
	if rig is ZeeWeaponRig and is_instance_valid(rig):
		return rig as ZeeWeaponRig
	return null


## Builds the hands under the camera and a rig to drive them. The rig has the authority only
## offline; connected, the server holds the deciding rig (`PlaygroundNetBridge._give_weapon`)
## and this one is the gun that moves.
func _arm_zee(def: PlaygroundWeaponDef) -> bool:
	if player == null or camera == null:
		return false

	zee_view = ZeeViewModel.new()
	zee_view.name = "ZeeViewModel"
	var own_hands := PlaygroundViewGrip.available() and view_arms is DotPlayerViewArms
	(zee_view as ZeeViewModel).show_arms = not own_hands
	if own_hands:
		(zee_view as ZeeViewModel).hands_reached.connect(_on_hands_reached)
	camera.add_child(zee_view)
	if own_hands:
		# The viewmodel_fov lens scales the weapon 2.5x and pushes it past the arms' reach.
		zee_view.remove_from_group(&"dot_view_model")
		(zee_view as ZeeViewModel).hands_fov = 0.0

	var rig := PlaygroundZee.arm(
		player, def, ZeeWeaponRig.Role.LOCAL, bridge == null,
		playground.tick_rate, Engine.get_physics_frames(), zee_view, playground.ads_rules
	)

	if rig == null:
		_disarm_zee()
		return false

	# Connected, the server's WEAPON event draws it (`PlaygroundNetBridge`); offline nobody
	# sends one, and the gun still belongs in the hands a third-person camera shows.
	if bridge == null:
		PlaygroundZee.show_held(player, def)

	return true


## The weapon's own measured grip and fore-end, onto the arms.
func _on_hands_reached(anchor: Node3D, grip: Vector3, fore: Vector3, pose: StringName) -> void:
	var made := PlaygroundViewGrip.update(held_grip, anchor, grip, fore, pose)
	if made != held_grip:
		held_grip = made
		(view_arms as DotPlayerViewArms).set_held(held_grip)


func _disarm_zee() -> void:
	if player != null and is_instance_valid(player):
		PlaygroundZee.disarm(player)
		if bridge == null:
			PlaygroundZee.show_held(player, null)

	if zee_view != null and is_instance_valid(zee_view):
		# queue_free is deferred: the dying model would emit once more and re-seat the arms.
		if (zee_view as ZeeViewModel).hands_reached.is_connected(_on_hands_reached):
			(zee_view as ZeeViewModel).hands_reached.disconnect(_on_hands_reached)
		zee_view.queue_free()
	zee_view = null
	held_grip = null
	if view_arms is DotPlayerViewArms:
		(view_arms as DotPlayerViewArms).set_held(null)

	_zee_buttons = 0
	_net_buttons &= ~DotFpsCommand.BUTTON_USER_2


## Builds the first-person model for a toy or tool, after [method _disarm_zee] cleared the last.
func _arm_toy_view(id: StringName) -> void:
	if toy_view != null and is_instance_valid(toy_view):
		toy_view.queue_free()
	toy_view = null
	if zee_view != null or camera == null or id == &"":
		return
	var def := playground.weapon_def(id) if playground != null else null
	var colour := def.colour if def != null else (Color(0.55, 0.4, 0.9) if id == TOOL_GRAV else Color(0.9, 0.55, 0.2))
	toy_view = DotToolView.make(colour, id == &"impulse", camera)


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


## The figure an avatar action plays on: that peer's player, or the local one offline.
func _avatar_figure(peer_id: int) -> Object:
	var who: PlaygroundPlayer = null
	if bridge != null and peer_id != 0:
		who = playground.players.get(StringName("u%d" % bridge.player_for_peer(peer_id)), null)
	if who == null and player != null and (net == null or peer_id == net.local_peer_id):
		who = player
	if who == null or who.character == null or who.character.body() == null:
		return null
	return who.character.body().get_node_or_null(^"Figure")
