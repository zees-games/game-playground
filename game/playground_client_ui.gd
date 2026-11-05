extends "res://game/playground_client_base.gd"


## Shows the arms only while downed in first person, and drives them at the player's speed.
func _present_view_arms(delta: float) -> void:
	if view_arms == null or not is_instance_valid(view_arms):
		return
	var first := view_id() == &"fp"
	# set_downed re-fits the held arms every call, so only on a change.
	var down: bool = player.downed and first
	if down != _arms_down:
		_arms_down = down
		view_arms.call("set_downed", down)
	var hands := zee_view as ZeeViewModel if zee_view != null and is_instance_valid(zee_view) else null
	arms_pivot.visible = first and (hands == null or not hands.is_scoped())
	arms_pivot.global_position = camera.global_position
	arms_pivot.global_rotation = Vector3(0.0, camera.global_rotation.y, 0.0)
	view_arms.call("tick", player.speed(), delta)


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


## Tells the HUD what is in the player's hands. Pushed, not polled: the HUD is bound to the
## simulation, and a spectator or replay has no client holding anything to look at.
func _sync_hud() -> void:
	if hud != null:
		hud.set_tool(_tool_name(), selected_prop)


## The phone's buttons over the HUD, on a touch device only. Fire and alt are the click's two buttons; Q is the
## spawn-menu key fed the same press and release, so hold-to-open and tap-to-pin are the keyboard's own; the
## tool arrows step the weapon wheel's actions, TAB holds the scoreboard and CHAT opens the chat box.
func _build_touch() -> void:
	if not DotPlatform.has_touch() or hud == null:
		return
	_touch = PlaygroundTouch.new()
	var _built := _touch.build(hud, active_sampler, {
		PlaygroundTouch.FIRE: func(down: bool) -> void:
			if down:
				call(&"_primary_down")
			else:
				_primary_up(),
		PlaygroundTouch.ALT: func(down: bool) -> void:
			if down:
				call(&"_secondary_down")
			else:
				_secondary_up(),
		PlaygroundTouch.MENU: func(down: bool) -> void:
			var key := InputEventKey.new()
			key.pressed = down
			_on_menu_key(key),
		PlaygroundTouch.PREV: func(down: bool) -> void: _touch_step(-1, down),
		PlaygroundTouch.NEXT: func(down: bool) -> void: _touch_step(1, down),
		PlaygroundTouch.BOARD: func(down: bool) -> void:
			if game_menu != null:
				if down:
					game_menu.scoreboard.open()
				else:
					game_menu.scoreboard.close(),
		PlaygroundTouch.CHAT: func(down: bool) -> void:
			var window: DotChatWindow = presentation.chat_window if presentation != null else null
			if down and window != null and not _menu_is_open():
				window.open(),
	})


## A tool step through the same wheel the keyboard's previous/next-weapon actions drive.
func _touch_step(step: int, down: bool) -> void:
	if not down or _menu_is_open():
		return
	var _ignored: Variant = call(&"_wheel_cycle", InputEventKey.new())
	var ev := InputEventAction.new()
	ev.action = _wheel.next_action if step > 0 else _wheel.previous_action
	ev.pressed = true
	_ignored = call(&"_wheel_cycle", ev)


func _touch_ignores(position: Vector2) -> bool:
	return _touch != null and _touch.buttons != null and _touch.buttons.contains_point(position)


## A finger on the look or move half goes to the touch sampler; with a menu open it is the menu's.
func _on_screen_touch(event: InputEvent) -> void:
	if _menu_is_open():
		return
	var sampler := active_sampler()
	if sampler is DotFpsTouchSampler:
		(sampler as DotFpsTouchSampler).set_screen_width(get_viewport().get_visible_rect().size.x)
	if sampler != null:
		sampler.handle_event(event)


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


## Q down opens the menu; Q up closes it unless the press was a tap.
##
## Not a toggle: holding is a glance with your place kept, tapping leaves it up while building.
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


## Wall-clock seconds. Presentation only — nothing here is timed, compared or ranked,
## which is why this is not the simulated clock the timer counts in.
func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


func _space() -> PhysicsDirectSpaceState3D:
	return player.get_world_3d().direct_space_state


func _view_basis() -> Basis:
	return Basis(Quaternion.from_euler(Vector3(
		0.0, deg_to_rad(player.controller.state.yaw), 0.0
	)))


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


## Steps through the weapons this server offers, and back to the physics gun (a cycle that could
## not reach it would strand a player). Also the tool gun mode in hand, read off the menu's copy
## of the modes, which exists on a connected client where no tool gun runs.
func _tool_mode_name() -> String:
	if menu != null:
		for mode in menu.call("_tools"):
			if mode.get("id") == tool_mode:
				return str(mode.get("display_name"))
	return String(tool_mode)


func _primary_up() -> void:
	_zee_buttons &= ~DotFpsCommand.BUTTON_USER_0

	if bridge != null:
		_net_buttons &= ~DotFpsCommand.BUTTON_USER_0
		return

	if tool == TOOL_PHYS and _holding:
		playground.phys_gun_release(player)
		_holding = false


func _secondary_up() -> void:
	_zee_buttons &= ~DotFpsCommand.BUTTON_USER_1

	if bridge != null:
		_net_buttons &= ~DotFpsCommand.BUTTON_USER_1
		return

	if tool == TOOL_GRAV and _pulling:
		player.grav_gun.drop()
		_pulling = false


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


## An outline round the selected prop, so a player can tell which of twenty identical crates the
## sliders are moving. Back faces of a slightly larger box only: a translucent fill read as pink.
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


## The physics gun's beam to the prop it holds, once a frame, from the drawn camera. Offline the
## gun is local; connected the server holds every prop (`Kind.HELD`) and a beam is drawn per holder.
## Static so `tools/screenshot_net.gd` draws exactly this. Returns how many.
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


## The cue for this player's own undo; the others' undos are not their business.
func _on_undone(who: StringName, at: Vector3) -> void:
	var cfg: PlaygroundConfig = playground.config
	if who != player_id or presentation == null or (cfg != null and not cfg.undo_sound):
		return
	last_undo_cue = presentation.on_undo(at, cfg.undo_sound_volume if cfg != null else 1.0, cfg != null and cfg.undo_sound_spatial)


func _on_menu_action(action: StringName) -> void:
	match action:
		&"undo":
			if bridge != null:
				bridge.ask_undo()
			elif not playground.undo(player_id) and hud != null:
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


## Thaws every prop this player has frozen. Never refused: a cap on tidying up would fight its own purpose.
## Gets in, or gets out, on one key. F rather than E, because E spawns here; the client only asks and the
## server owns the seats, the exit sweep and the refusal (no bridge: the same call goes to the simulation).
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


## First person to third and back, through the controller switch. A different motor, not a moved
## camera: a sandbox ranks nothing, so it can afford the better third-person movement (camera-
## relative input, spring-arm orbit rig, coyote time, jump buffer).
func _toggle_view() -> void:
	if player == null or player.controller_switch == null:
		return

	# The next view in `mp_viewcycle` that `mp_forceview` allows, or a line saying why not.
	var current := view_id()
	var wanted := playground.view_rules.next_mode(current)
	if wanted == current:
		if hud != null and playground.view_rules.refusal() != "":
			hud.notice(playground.view_rules.refusal())
		return

	apply_view(wanted)


## Shows [param mode] (`fp`, `tp` or `selfie`) and says which.
func apply_view(mode: StringName) -> void:
	var selfie := mode == &"selfie"
	player.detached_view = selfie
	var now := player.set_view_mode(mode == &"tp")
	_guard_rig()
	if selfie:
		_place_selfie_camera()
	else:
		_adopt_view_camera(now)
	if hud != null:
		hud.notice("View: %s" % VIEW_NAMES.get(mode, str(mode)))


## The view on screen: `selfie` is the first-person motor seen from a camera left standing in front of the player.
func view_id() -> StringName:
	if player == null:
		return &"fp"
	return &"selfie" if player.detached_view else player.view_mode()


## Leaves a camera standing 3 m in front of the player, looking back at them, and keeps it there while they move.
func _place_selfie_camera() -> void:
	if selfie_camera == null or not is_instance_valid(selfie_camera):
		selfie_camera = Camera3D.new()
		selfie_camera.name = "SelfieCamera"
		selfie_camera.top_level = true
		add_child(selfie_camera)
	var eye := player.render_eye_position()
	var forward := -camera.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length() > 0.001 else Vector3.FORWARD
	selfie_camera.fov = 75.0
	selfie_camera.global_position = eye + forward * 3.0 + Vector3.UP * 0.4
	selfie_camera.look_at(eye - Vector3.UP * 0.3, Vector3.UP)
	selfie_camera.make_current()


## The server changed `mp_forceview`: the view it allows now.
func _on_view_rules_changed() -> void:
	if player == null or player.controller_switch == null:
		return
	var current := view_id()
	var third := current != &"fp"
	var allowed := playground.view_rules.resolve(third)
	if allowed != third:
		apply_view(&"tp" if allowed else &"fp")


## The first-person camera holds the hands, so it must be the current one again on the way back
## from third person (the rig took the viewport's camera and nothing gave it back).
func _adopt_view_camera(mode: StringName) -> void:
	if mode == &"fp" and camera != null and is_instance_valid(camera):
		camera.make_current()


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


## Solo: [param id] now. A client does not change the map when connected: one client loading
## a different world from everybody else is not a map change, it is a client playing alone in
## a world nobody else is in; the server's map menu decides there.
func change_from_menu(id: StringName) -> DotResult:
	if bridge != null:
		return DotResult.fail(DotError.CODE_STATE, "The server changes the map.")
	return await playground.change_map(id)


