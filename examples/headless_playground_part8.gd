extends "res://examples/headless_playground_part7.gd"

var _tcb_client: PlaygroundClient
var _tcb_look_settings: DotSettingsManager
var _tcb_look: DotFpsTunables
var _tcb_net_sampler: DotFpsSampler
var _tcb_released_yaw: float
var _tcb_kept_menu: DotMenu
var _tcb_keys: DotMenuBindings
var _tcb_menu: DotMenu
var _tcb_pg_hud: Node
var _tcb_pg_xh
var _tcb_dead_hidden: bool
var _tcb_sink
var _tcb_edited

func _the_client_mounts_the_downed_arms() -> void:
	if DotAddonApi.build_level("dot_player_char") < 7:
		return
	var arms := _tcb_client.view_arms as DotPlayerViewArms
	_check(arms != null and arms.arms() != null and _tcb_client.arms_pivot != null and arms.get_parent() == _tcb_client.arms_pivot,
		"the client mounts the downed arms under a yaw pivot, not the camera")
	if arms == null:
		return
	_tcb_client.player.downed = false
	_tcb_client._present_view_arms(0.016)
	_check(not arms.arms().visible, "the arms are hidden while on their feet")
	_tcb_client.player.downed = true
	_tcb_client._present_view_arms(0.016)
	_check(arms.arms().visible and arms.shown, "and shown while downed in first person")
	_tcb_client.player.downed = false
	_tcb_client._present_view_arms(0.016)
	_check(not arms.arms().visible, "and hidden again on a revive")


## One weapon of every pose the catalogue ships, in the client's own hands: the arms are up with the
## grip the weapon measured, the hand within 5 cm of where the arms aim it (10 cm for a fore-end, 13 for a long gun's: the arm's reach), and gone again on the holster.
func _the_arms_hold_each_weapon_class() -> void:
	if not PlaygroundViewGrip.available():
		return
	var chosen: Dictionary = {}
	for art in ZeeWeaponArtTable.all():
		if art.has_model() and not chosen.has(art.pose):
			chosen[art.pose] = art.id
	_check(chosen.size() >= 4, "the catalogue offers several weapon poses to hold", str(chosen.keys()))
	var arms := _tcb_client.view_arms as DotPlayerViewArms
	for pose: StringName in chosen:
		_tcb_client._set_tool(StringName("zee_%s" % chosen[pose]))
		for _i in range(8):
			await get_tree().process_frame
		var grip := _tcb_client.held_grip
		_check(grip != null and arms.shown and arms.arms().visible and _tcb_client.arms_pivot.visible,
			"%s (%s): the arms are mounted and shown on the armed weapon" % [chosen[pose], pose])
		var one := pose in PlaygroundViewGrip.ONE_HAND
		_check(grip != null and grip.is_two_hand() != one, "%s: %s hands" % [pose, "one" if one else "two"])
		var err := PlaygroundViewGrip.hand_error(arms, grip)
		var reach := 0.05 if one else (0.13 if pose == &"heavy" else 0.10)
		_check(err >= 0.0 and err < reach, "%s: the hand is within %d cm of the grip" % [pose, roundi(reach * 100.0)], "%.3f m" % err)
		_check(not _tcb_client.zee_view.show_arms, "%s: the view model's own hands are off" % pose)
		_tcb_client._set_tool(&"phys")
		await get_tree().process_frame
		_check(_tcb_client.held_grip == null and not arms.shown, "%s: the arms are gone on the holster" % pose)

func _test_the_client_boots() -> void:
	_section("the client boots")

	_tcb_client = PlaygroundClient.new()
	_tcb_client.name = "Client"

	# Its own config, records in memory. A test must not write into the user's data
	# directory, and this is the only reason `PlaygroundClient.config` exists.
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	_tcb_client.config = config

	add_child(_tcb_client)

	for _i in range(4):
		await get_tree().process_frame

	# The load gate covers the client, and holds its input and its body, until the level, the
	# player and the camera are in and the physics has settled: a test that drives the
	# client waits for it as a player would.
	await _gate_opens(_tcb_client)
	_check(_tcb_client.gate != null and _tcb_client.gate.is_open(), "the load gate opens once the level, player and camera are in",
		"state %s held %s" % [_tcb_client.gate.state(), _tcb_client.gate.reasons()] if _tcb_client.gate != null else "no gate")

	_check(_tcb_client.playground != null, "the client builds a playground")
	_check(
		_tcb_client.playground != null and _tcb_client.playground.booted,
		"which finishes booting"
	)
	_check(
		_tcb_client.playground != null and _tcb_client.playground.maps.current != null,
		"with a map up",
		String(_tcb_client.playground.maps.current.id)
			if _tcb_client.playground != null and _tcb_client.playground.maps.current != null
			else "none"
	)

	# The four things that are all missing together when `_ready` stops halfway.
	_check(_tcb_client.player != null, "the client has a player")
	_check(_tcb_client.camera != null, "and a camera")
	_check(_tcb_client.hud != null, "and a HUD")
	_check(
		_tcb_client.screens != null and _tcb_client.menu != null,
		"and a spawn menu registered on a stack"
	)

	_check(
		_tcb_client.menu != null and _tcb_client.screens != null
		and _tcb_client.screens.screen(_tcb_client.menu.screen_id()) == _tcb_client.menu,
		"which the stack can find by id"
	)
	_check(
		_tcb_client.player != null and _tcb_client.player.samples_input
		and _tcb_client.player.sampler != null,
		"and the player samples input, with a sampler actually built"
	)
	_the_client_mounts_the_downed_arms()
	await _test_the_client_boots_2()
	await _test_the_client_boots_3()
	await _test_the_client_boots_4()
	_test_the_client_boots_5()
	await _test_the_client_boots_6()
	await _test_the_client_boots_7()
	await _test_the_client_boots_8()
	await _test_the_client_boots_12()
	await _test_the_client_boots_13()
	_tcb_client = null
	_tcb_look_settings = null
	_tcb_look = null
	_tcb_net_sampler = null
	_tcb_kept_menu = null
	_tcb_keys = null
	_tcb_menu = null
	_tcb_pg_hud = null
	_tcb_pg_xh = null
	_tcb_sink = null
	_tcb_edited = null

func _test_the_client_boots_2() -> void:

	# A death draws the server's fall from the body this client draws; connected, the reaction comes on COMBAT.
	# Armed by spawning from the character node instead of its body (the parts check fails) and by
	# ignoring the rules (the topple).
	_tcb_client._build_ragdolls()
	var other := _tcb_client.playground.add_player(&"u66", "Fallen")
	other.teleport(_tcb_client.player.controller.state.position + Vector3(0.0, 0.0, -4.0))
	await get_tree().process_frame
	var crumple := DotPlayerDeath.new()
	crumple.reaction = DotPlayerDeathReactions.CRUMPLE
	var body := _tcb_client.fall(&"u66", crumple)
	_check(body != null and body.reaction.id == DotPlayerDeathReactions.CRUMPLE and body.part_count() > 1
			and not other.character.body().visible,
		"a death falls as the server's reaction, copied from the drawn figure, which is hidden",
		str(body.describe()) if body != null else "no body")
	_tcb_client.rise(&"u66")
	_check(other.character.body().visible, "and a return draws the figure again")
	var gun := Node3D.new()
	var gun_mesh := MeshInstance3D.new()
	gun_mesh.mesh = BoxMesh.new()
	gun.add_child(gun_mesh)
	other.character.body().add_child(gun)
	other.zee_world = gun
	gun.position = Vector3(0.0, 1.0, 0.0)
	var _slain := _tcb_client.fall(&"u66", crumple)
	var dropped := _tcb_client.ragdolls.get_node_or_null("DroppedWeapon") as RigidBody3D
	_check(dropped != null and not gun.visible,
		"a slain player's gun drops as a prop while the hand's copy hides")
	other.zee_world = null
	gun.queue_free()
	_tcb_client.ragdolls.clear()
	_tcb_client.rise(&"u66")
	_tcb_client.ragdolls.clear()
	var _off := _tcb_client.playground.ragdoll_rules.set_cvar("sv_ragdoll", "0")
	var toppled := _tcb_client.fall(&"u66", crumple)
	_check(toppled != null and toppled.style == DotPlayerRagdollRules.Style.TOPPLE,
		"the server's sv_ragdoll 0 is the topple fallback")
	var _on := _tcb_client.playground.ragdoll_rules.set_cvar("sv_ragdoll", "1")
	_tcb_client.ragdolls.clear()
	_tcb_client.rise(&"u66")
	_check(_tcb_client.fall(_tcb_client.player.player_id, crumple) == null,
		"no ragdoll of your own body in first person")
	_tcb_client.playground.remove_player(&"u66")

	# The sensitivity slider reaches the sampler: nothing called `bind_look`, so the view turned at
	# DotFpsTunables' default whatever the player chose. Read off the tunables the sampler turns the
	# view with, offline and connected. Armed: without `_bind_look` all four fail.
	_tcb_look_settings = (
		_tcb_client.presentation.settings if _tcb_client.presentation != null else null
	)
	_tcb_look = (
		_tcb_client.player.sampler.tunables
		if _tcb_client.player != null and _tcb_client.player.sampler != null else null
	)
	_check(
		_tcb_look != null and _tcb_look_settings != null and is_equal_approx(_tcb_look.mouse_sensitivity,
			_tcb_look_settings.get_float(&"sensitivity") * DotMenuApplier.DEGREES_PER_COUNT),
		"the saved sensitivity reaches the offline sampler, at dot-menu's degrees per count",
		"%.4f" % (_tcb_look.mouse_sensitivity if _tcb_look != null else -1.0)
	)
	if _tcb_look_settings != null:
		_tcb_look_settings.set_value(&"sensitivity", 4.0)
	_check(
		_tcb_look != null and is_equal_approx(_tcb_look.mouse_sensitivity, 4.0 * DotMenuApplier.DEGREES_PER_COUNT),
		"and moving the slider changes the turning speed",
		"%.4f" % (_tcb_look.mouse_sensitivity if _tcb_look != null else -1.0)
	)
	_tcb_net_sampler = DotFpsSampler.new(DotFpsTunables.new())
	_tcb_client._sampler = _tcb_net_sampler
	_tcb_client._bind_look()
	if _tcb_look_settings != null:
		_tcb_look_settings.set_value(&"sensitivity", 3.0)

func _test_the_client_boots_3() -> void:
	_tcb_client._sampler = null
	_check(
		is_equal_approx(_tcb_net_sampler.tunables.mouse_sensitivity, 3.0 * DotMenuApplier.DEGREES_PER_COUNT),
		"and the connected client's sampler, rebound when it adopts its player, follows it too",
		"%.4f" % _tcb_net_sampler.tunables.mouse_sensitivity
	)
	if _tcb_look_settings != null:
		_tcb_look_settings.set_value(&"invert_mouse", true)
	_check(
		_tcb_look != null and _tcb_look.invert_look_y and _tcb_net_sampler.tunables.invert_look_y,
		"and inverting the vertical look inverts both"
	)
	if _tcb_look_settings != null:
		_tcb_look_settings.set_value(&"invert_mouse", false)

	# The mouse, end to end. `_on_mouse_motion` fed `player.sampler` while `_net_physics` sampled `_sampler`,
	# two objects, and `DotFpsSampler.sample` polls the `InputMap` for movement, so only the view died.
	var before_yaw: float = (
		_tcb_client.player.controller.state.yaw if _tcb_client.player != null else 0.0
	)

	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(120.0, 0.0)

	# Captured, because a look input is only a look while it is: headless starts VISIBLE, as after one
	# Escape, and `_on_mouse_motion` ignores a free cursor. Setting it models somebody playing.
	_tcb_client.mouse_capture_override = true
	_tcb_client._unhandled_input(motion)

	# The sampler accumulates and spends it on the next simulated tick, so the view has
	# not turned yet -- that is the point of accumulating it. Let the game tick.
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(
		_tcb_client.player != null
		and not is_equal_approx(_tcb_client.player.controller.state.yaw, before_yaw),
		"a mouse motion turns the view",
		"yaw %.3f -> %.3f" % [
			before_yaw,
			_tcb_client.player.controller.state.yaw if _tcb_client.player != null else 0.0
		]
	)

	# The other half: a released cursor turns nothing. Escape frees the pointer with no screen open,
	# so `_menu_is_open` is false. Driven through `mouse_capture_override`, because `Input.mouse_mode`
	# is a no-op under the dummy display server and a suite setting it would prove nothing.
	_tcb_released_yaw = _tcb_client.player.controller.state.yaw

func _test_the_client_boots_4() -> void:

	_tcb_client.mouse_capture_override = false

	var free_motion := InputEventMouseMotion.new()
	free_motion.relative = Vector2(120.0, 0.0)
	_tcb_client._unhandled_input(free_motion)

	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(
		is_equal_approx(_tcb_client.player.controller.state.yaw, _tcb_released_yaw),
		"and a motion with the cursor released turns nothing",
		"yaw %.3f -> %.3f" % [_tcb_released_yaw, _tcb_client.player.controller.state.yaw]
	)

	# Escape releases and never captures; a click captures (game-g2gfast's contract, for the browser).
	# `Input.mouse_mode` is a no-op under the dummy display server, so this checks the configuration,
	# that no screen is up, and that Escape on an uncaptured pointer opens the menu.
	var plat: DotGameClient = _tcb_client.platform
	_check(
		plat != null and plat.escape_releases_pointer and plat.capture_pointer
		and plat.menu == _tcb_client.game_menu and plat.console != null
		and plat.console == _tcb_client.presentation.console,
		"the platform owns the pointer and the menu, and built the console after it"
	)
	_check(
		plat.pointer_fn.call() == true and not _tcb_client._menu_is_open(),
		"a click may take the pointer back while no screen is up"
	)
	var escape := InputEventKey.new()
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	_tcb_kept_menu = _tcb_client.game_menu
	_tcb_client.mouse_capture_override = false
	_tcb_client._unhandled_input(escape)
	_check(
		_tcb_kept_menu != null and _tcb_kept_menu.is_open() and _tcb_client.mouse_capture_override == false,
		"Escape with the pointer free is the second press: it opens the menu and never captures"
	)
	_tcb_kept_menu.close_all()

	# With the menu, the second Escape opens it — dot-menu's, whose own Escape is off so
	# this game keeps its two steps — and Escape closes it again.
	_tcb_kept_menu.open()
	var opened := _tcb_kept_menu != null and _tcb_kept_menu.is_open()
	# The menu swallows an Escape that lands within its grace of opening (a browser's own
	# pointer-lock Escape arriving late must not flash it shut), and this one lands in the
	# same millisecond, so the grace is off for this press.
	var grace := _tcb_kept_menu.config.escape_grace_ms if _tcb_kept_menu != null else 0
	if _tcb_kept_menu != null:
		_tcb_kept_menu.config.escape_grace_ms = 0
	var shut := _tcb_kept_menu != null and _tcb_kept_menu.handle_event(escape) and not _tcb_kept_menu.is_open()
	if _tcb_kept_menu != null:
		_tcb_kept_menu.config.escape_grace_ms = grace
	_check(opened and shut, "the second Escape opens the menu, and Escape closes it")

func _test_the_client_boots_5() -> void:

	# [b]H is help, in every game of the family[/b], every key is a row of the table, and the
	# Escape menu has Help & commands and Leave (the first play test found Help hidden here).
	_tcb_keys = _tcb_client.keys
	_check(_tcb_keys != null and _tcb_keys.key_for(DotMenuBindings.HELP_ACTION) == "H" and _tcb_keys.defaults_on("H").size() == 1,
		"help is on H, and nothing else in the key table is")
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	var helped := _tcb_kept_menu != null and _tcb_kept_menu.handle_event(h) and _tcb_kept_menu.help.is_open()
	_check(helped and _tcb_kept_menu.help.about != "" and _tcb_kept_menu.help.heading() == "How to play Playground",
		"H opens the help screen, which says what the game is before the keys")
	if _tcb_kept_menu != null:
		_tcb_kept_menu.close_all()
		_tcb_kept_menu.open()
	var leave_button := _tcb_kept_menu.screen.find_child("Action_leave", true, false) as Button if _tcb_kept_menu != null else null
	_check(_tcb_kept_menu != null and _tcb_kept_menu.screen.find_child("Action_help", true, false) != null
		and leave_button != null and leave_button.visible, "the Escape menu has Help & commands and Leave")
	if _tcb_kept_menu != null:
		_tcb_kept_menu.close_all()

	_tcb_menu = _tcb_kept_menu

	# M, the family's rule since the first play test: the map list, and solo a choice
	# changes it now. The server's half (the owner's flag, the vote) is in `dedicated`.
	_check(_tcb_keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and _tcb_keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table is",
		str(_tcb_keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	# B is the family's loadout key, the arena's loadout: nothing else here may default to it
	# (Clear checkpoints was B). Solo there is no arena, and B says where the loadouts are.
	var on_b := _tcb_keys.defaults_on("B")
	_check(on_b.size() <= 1 and on_b.all(func(r: Dictionary) -> bool: return StringName(str(r["action"])) == DotMenuBindings.LOADOUT_ACTION),
		"only the loadout is on B, the family's loadout key",
		str(on_b.map(func(r: Dictionary) -> String: return str(r["label"]))))
	# The right button aims a zee gun (the family's Aim row); its quick melee is the middle one.
	_check(_tcb_keys.key_for(PlaygroundBindings.AIM) == "Mouse 2" and _tcb_keys.defaults_on("Mouse 2").size() == 1
		and _tcb_keys.key_for(PlaygroundBindings.BASH) == "Mouse 3", "a gun aims on the right button, quick melee on the middle",
		"%s %s" % [_tcb_keys.key_for(PlaygroundBindings.AIM), _tcb_keys.key_for(PlaygroundBindings.BASH)])
	if _tcb_client.get("loadout_menu") != null:
		_tcb_menu.close_all()
		var b_key := InputEventKey.new()
		b_key.physical_keycode = KEY_B
		b_key.keycode = KEY_B
		b_key.pressed = true
		var menu_took := _tcb_menu.handle_event(b_key)
		_tcb_client.call("_unhandled_input", b_key)
		var said := ((_tcb_client.get("hud") as Node).get("_notice") as Label).text
		_check(not menu_took and not bool(_tcb_client.get("arena_on")) and said == "Loadouts are in the arena.",
			"solo B opens nothing and says the loadouts are in the arena", said)
	# Down a zee gun's sights the HUD hands dot-ui's crosshair the aim; a scope replaces it.
	_tcb_pg_hud = _tcb_client.get("hud")
	_tcb_pg_hud.call("set_aim", 1.0, true)
	var scoped_ok := float((_tcb_pg_hud.get("scope") as Control).get("fraction")) == 1.0 and not (_tcb_pg_hud.get("_crosshair") as Control).visible
	_tcb_pg_hud.call("set_aim", 0.0, false)
	_check(scoped_ok and (_tcb_pg_hud.get("_crosshair") as Control).visible and float((_tcb_pg_hud.get("scope") as Control).get("fraction")) == 0.0,
		"through a scope the HUD shows zee's scope instead of the crosshair, and puts it back at the hip")
	_tcb_pg_xh = _tcb_pg_hud.get("_crosshair") as DotCrosshair
	_tcb_pg_hud.call("set_alive", false)
	_tcb_dead_hidden = DotAddonApi.build_level("dot_ui") < 14 or not _tcb_pg_xh.is_shown()

func _test_the_client_boots_6() -> void:
	_tcb_pg_hud.call("set_alive", true)
	_check(_tcb_dead_hidden and _tcb_pg_xh.is_shown(), "the HUD hides the crosshair while the viewer is dead and shows it again alive")
	# Closed right before the key: an offline client with no captured pointer (headless) may
	# have put its menu back up, and while anything is open every key is the menu's.
	_tcb_menu.close_all()
	var map_before: StringName = _tcb_client.playground.maps.current.id
	var m_key := InputEventKey.new()
	m_key.physical_keycode = KEY_M
	m_key.keycode = KEY_M
	m_key.pressed = true
	_check(_tcb_menu.handle_event(m_key) and _tcb_menu.picker.is_open() and _tcb_menu.picker.items.size() > 1,
		"M opens the map list, more than one to choose", str(_tcb_menu.picker.items.size()))
	var wanted_map: StringName = &""
	var map_key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = _tcb_menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted_map = StringName(str((it as Dictionary)["id"]))
			map_key = KEY_0 + row
			break
	var digit_key := InputEventKey.new()
	digit_key.physical_keycode = map_key
	digit_key.keycode = map_key
	digit_key.pressed = true
	var _picked := _tcb_menu.handle_event(digit_key)
	for _i in 60:
		await get_tree().physics_frame
	_check(wanted_map != &"" and _tcb_client.playground.maps.current.id == wanted_map and not _tcb_menu.picker.is_open(),
		"choosing one changes the map now", "%s, now %s" % [wanted_map, _tcb_client.playground.maps.current.id])
	# Back where it was, for the checks after this one.
	var _back_map: Variant = await _tcb_menu.maps.change_fn.call(map_before)
	for _i in 60:
		await get_tree().physics_frame
	var spawn_row := _tcb_keys.row_for_action(&"pg_spawn") if _tcb_keys != null else {}
	var rebound: DotResult = _tcb_keys.rebind(spawn_row, "J", _tcb_client.presentation.settings) if not spawn_row.is_empty() else DotResult.fail(DotError.CODE_STATE, "no row")
	var j := InputEventKey.new()
	j.physical_keycode = KEY_J
	var e := InputEventKey.new()
	e.physical_keycode = KEY_E
	_check(rebound.ok and j.is_action(&"pg_spawn") and not e.is_action(&"pg_spawn"),
		"a key rebound in the menu moves what the client reads (spawn on J, E free)")
	if _tcb_keys != null:
		_tcb_keys.reset_all(_tcb_client.presentation.settings)
	_check(e.is_action(&"pg_spawn"), "and Reset puts it back on E")
	_tcb_client.mouse_capture_override = true

	# From released, whatever the line above left, so this check stands on its own: the click
	# that takes the pointer back (the platform captures it) is spent on that and punts nothing.
	_tcb_client.mouse_capture_override = false
	_tcb_client._was_driving = false
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	var tool_before: Variant = _tcb_client.get(&"_aiming")
	_tcb_client._unhandled_input(click)

	_check(
		_tcb_client.get(&"_aiming") == tool_before and not _tcb_client._menu_is_open(),
		"a click with the pointer released is spent on taking it back"
	)

func _test_the_client_boots_7() -> void:

	_tcb_client.mouse_capture_override = true

	# The routing rule for the deployment this suite does not build: a networked client's mouse must reach
	# `_sampler`, which `_net_physics` stamps from, while `player.sampler` is null there. Asserted on the
	# accessor both lines go through, not by standing a whole networked client up.
	_check(
		_tcb_client.active_sampler() == _tcb_client.player.sampler,
		"a local client's mouse feeds the player's own sampler"
	)

	# Christian's first play test: a darker HUD by default, restyled live by the menu's theme.
	var plate := _tcb_client.hud.ammo.colour(&"plate")
	_check(_tcb_client.game_menu.followed_huds().has(_tcb_client.hud) and plate.get_luminance() < 0.1 and plate.a >= 0.7
		and _tcb_client.hud.ammo.colour(&"highlight") == PlaygroundGeometry.COLOUR_BOOST,
		"the HUD is dark by default, in the menu's theme, with the boost amber as its accent", str(plate))
	var _themed: Variant = _tcb_client.game_menu.settings.set_value(&"ui_theme", &"contrast")
	_check(_tcb_client.hud.ammo.colour(&"plate") == _tcb_client.game_menu.palette().hud_plate
		and _tcb_client.hud.hit_marker.colour(&"text") == _tcb_client.game_menu.palette().hud_text
		and _tcb_client.hud.ammo.colour(&"highlight") == PlaygroundGeometry.COLOUR_BOOST
		and (_tcb_client.hud.timer_hud == null
			or _tcb_client.hud.timer_hud.get("panel_colour") == _tcb_client.game_menu.palette().hud_plate),
		"a theme picked in the menu reaches the pieces, and a run timer's block when there is one, at once, the accent kept")
	_themed = _tcb_client.game_menu.settings.set_value(&"ui_theme", &"midnight")

	# Typing at the console must not walk the player: the sampler polls keys every tick and a focused
	# line edit does not stop `Input.is_action_pressed`; dot-menu's `overlays_changed` suspends the
	# sampler. W held, measured in metres.
	var console := _tcb_client.presentation.console if _tcb_client.presentation != null else null
	var forward: StringName = _tcb_client.player.sampler.actions["forward"]
	for _i in range(60):
		await get_tree().physics_frame
	var _opened := console.open() if console != null else false
	await get_tree().process_frame
	_check(console != null and _tcb_client.game_menu.any_open() and _tcb_client.player.sampler.suspended,
		"the console opens as one of the menu's overlays and suspends the sampler")
	var typing_from := _tcb_client.player.global_position
	Input.action_press(forward)
	for _i in range(30):
		await get_tree().physics_frame
	Input.action_release(forward)
	var typed := _tcb_client.player.global_position.distance_to(typing_from)
	_check(typed < 0.001, "W held with the console open moves nobody", "%.3f m" % typed)
	if console != null:
		console.close()
	await get_tree().process_frame
	_check(not _tcb_client.player.sampler.suspended and not _tcb_client.game_menu.any_open(),
		"closing it gives the keys back")
	var walking_from := _tcb_client.player.global_position
	Input.action_press(forward)
	for _i in range(30):
		await get_tree().physics_frame
	Input.action_release(forward)
	var walked := _tcb_client.player.global_position.distance_to(walking_from)
	_check(walked > 0.1, "and the same W walks again (the control)", "%.3f m" % walked)

func _test_the_client_boots_8() -> void:
	# The control walk coasts; the checks below expect a player standing still.
	for _i in range(60):
		await get_tree().physics_frame
	# Closing an overlay recaptures the pointer, which moves the override; put it back.
	_tcb_client.mouse_capture_override = true

	var networked := PlaygroundClient.new()
	networked.link = Node.new()
	networked._sampler = DotFpsSampler.new(DotFpsTunables.new())

	_check(
		networked.active_sampler() == networked._sampler,
		"and a networked client's feeds the one its tick stamps commands from"
	)

	networked.link.free()
	networked.free()

	# A connected client's HUD holds the vote's clock. The netcode comes up before the HUD in `_ready`,
	# so the hand-over must not sit with the netcode, where it finds no HUD. Booted for real, with a bare
	# node for a link.
	var connected := PlaygroundClient.new()
	connected.name = "ConnectedClient"
	connected.link = Node.new()
	# The bare link cannot replicate cvars, so noblock logs its refusal; that is the stub, not the client.
	var mirrored_link := DotLog.mirror_to_engine
	DotLog.mirror_to_engine = false
	add_child(connected)
	for _i in range(4):
		await get_tree().process_frame
	DotLog.mirror_to_engine = mirrored_link
	_check(
		connected.hud != null and connected.bridge != null
			and connected.hud.clock_view == connected.bridge.clock_view,
		"a connected client's HUD draws the clock its bridge adopts from the server",
		"hud %s, bridge %s" % [connected.hud != null, connected.bridge != null]
	)
	var stub_link: Node = connected.link
	connected.queue_free()
	stub_link.queue_free()
	await get_tree().process_frame

	# The client makes a noise when something happens, through the game and not through the hooks:
	# `headless_presentation` calls `on_prop_spawned` itself, so a hook nothing calls stayed silent.
	# This goes through the client's own spawn, the spawner's refusal and a real map change.
	_tcb_sink = _tcb_client.presentation.audio.sink as DotAudioSinkNull \
		if _tcb_client.presentation != null and _tcb_client.presentation.audio != null else null
	_check(_tcb_sink != null, "the headless client's presentation has a null sink to count on")

	if _tcb_sink != null:
		await _test_the_client_boots_9()

	# zee-dot-weapons, offline, through the client's own key handlers and its own tick.
	_tcb_client._set_tool(&"zee_smg")
	await get_tree().process_frame

func _test_the_client_boots_9() -> void:
	# The null sink never reaps and the ambience layer's beds are loops: room for the cue under test.
	_tcb_sink.capacity = 64
	_tcb_sink.forget()
	_tcb_client.selected_prop = &"crate"
	_tcb_client._spawn()
	_check(
		_tcb_sink.count_of(&"prop_spawn") == 1,
		"a prop the client spawns through the game makes a noise",
		"%d" % _tcb_sink.count_of(&"prop_spawn")
	)

	# The physics gun's beam, through the client's own frame: a hook nothing calls is
	# this file's oldest bug. Holding is set by hand, because a grab needs the prop in
	# the crosshair and that is dot-props' suite's question, not this one's.
	var mine := _tcb_client.playground.props.props_of(_tcb_client.player_id)
	var crate: DotPropInstance = mine.back() if not mine.is_empty() else null
	var crate_body := crate.node as Node3D if crate != null else null
	if crate_body != null:
		_tcb_client.player.phys_gun.held = crate
		_tcb_client._holding = true
		await get_tree().process_frame
		await get_tree().process_frame
		var beam: Node3D = _tcb_client.presentation._beams.get(0)
		var tip := beam.global_transform * Vector3(0, 0, -1) \
			if beam != null and is_instance_valid(beam) else Vector3.INF
		_check(
			tip.distance_to(crate_body.global_position) < 0.3,
			"the client's own frame draws the physics gun's beam to what it holds",
			"tip %s, prop %s" % [tip, crate_body.global_position]
		)
		_tcb_client._holding = false
		_tcb_client.player.phys_gun.held = null
	else:
		_check(false, "the client's own frame draws the physics gun's beam to what it holds",
			"the crate the client spawned is not there to hold")

	_tcb_sink.forget()
	_tcb_client.playground.props.spawn(&"no_such_prop", _tcb_client.player_id, Vector3.ZERO)
	_check(
		_tcb_sink.count_of(&"refused") == 1,
		"and a spawn the spawner refuses makes the refusal noise",
		"%d" % _tcb_sink.count_of(&"refused")
	)

	# An administrator's beacon and blind, through the client's OWN frame hooks rather than the
	# player's method. Stepped by hand, a quarter of a second at a time, so the count is the ripple's
	# and not the frame rate's.
	_tcb_client.player.beacon = true
	_tcb_sink.forget()
	# The null sink never ends a sound by itself, so by here pg_flatgrass's toys have
	# filled its 32 voices and the second and third pings were refused as "voices".
	# Emptied first, so what is counted is the beacon's rhythm and not the sink's room.
	_tcb_sink.stop_all()
	for _i in range(8):
		_tcb_client._present_beacons(0.25)
	await _test_the_client_boots_10()
	await _test_the_client_boots_11()

func _test_the_client_boots_10() -> void:
	_check(
		_tcb_sink.count_of(&"beacon") == 3,
		"a beacon pings as it comes on and once a second after, not once a frame",
		"%d pings in two seconds" % _tcb_sink.count_of(&"beacon")
	)
	var marker := _tcb_client.player.beacon_marker
	_check(
		marker != null and marker.is_inside_tree()
		and marker.global_position.is_equal_approx(_tcb_client.player.controller.state.position),
		"its marker stands where the player is simulated"
	)
	_check(
		marker != null and not marker.column_shown(),
		"with no column on the player's own first-person view, which would smear the screen"
	)
	_tcb_client.player.beacon = false
	_tcb_client._present_beacons(0.25)
	_check(_tcb_client.player.beacon_marker == null, "and it goes when the flag does")

	# And through real frames, because the checks above call the hook by hand and would
	# pass with `_process` never calling it — which is the shape every presentation hook
	# in this game once had.
	_tcb_client.player.beacon = true
	await get_tree().process_frame
	await get_tree().process_frame
	_check(
		_tcb_client.player.beacon_marker != null,
		"the client's own frame draws a beacon, not only a test calling the hook"
	)
	_tcb_client.player.beacon = false
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_tcb_client.player.beacon_marker == null, "and its own frame takes it away")

	_tcb_client.player.blinded = true
	_tcb_client.hud.present_blind(0.5)
	var blind := _tcb_client.hud.blind_overlay
	var viewport := _tcb_client.hud.get_viewport_rect().size
	_check(
		blind != null and blind.visible and is_equal_approx(blind.modulate.a, 1.0),
		"a blind comes down over the HUD's player"
	)
	# The whole viewport. Headless it is 64 x 64 (docs/testing.md), which is still a
	# real size to compare against: an overlay never sized is 0 x 0 at any resolution.
	_check(
		blind != null and blind.get_global_rect().position.is_equal_approx(Vector2.ZERO)
		and blind.get_global_rect().size.is_equal_approx(viewport),
		"and covers the whole viewport",
		"%s against %s" % [str(blind.get_global_rect()) if blind != null else "-", str(viewport)]
	)
	_check(
		blind != null and blind.get_index() < _tcb_client.hud.ammo.get_index(),
		"under the HUD's own widgets, so the counters still say the game is going on"
	)
	_tcb_client.player.blinded = false
	_tcb_client.hud.present_blind(0.5)
	_check(blind != null and not blind.visible, "and lifts when the flag does")

	_tcb_client.presentation.fx.shake.add(1.0)
	_check(_tcb_client.presentation.fx.shake.active(), "a shake is live before a map change")

func _test_the_client_boots_11() -> void:
	await _tcb_client.playground.change_map(&"pg_generated")
	_check(
		not _tcb_client.presentation.fx.shake.active(),
		"and a map change clears it, because the effects' world has gone"
	)

func _test_the_client_boots_12() -> void:

	var hand_rig: Variant = _tcb_client.player.zee_rig if _tcb_client.player != null else null
	_check(
		hand_rig is ZeeWeaponRig and _tcb_client.zee_view != null
			and _tcb_client.zee_view.get_parent() == _tcb_client.camera,
		"a zee weapon from the menu puts hands under the camera"
	)
	_check(
		hand_rig is ZeeWeaponRig and (hand_rig as ZeeWeaponRig).authority,
		"and offline the client's rig is the one that decides"
	)
	var body_gun: Variant = _tcb_client.player.zee_world if _tcb_client.player != null else null
	_check(
		body_gun is ZeeWorldModel and (body_gun as ZeeWorldModel).equipped() == &"smg",
		"and the body a third-person camera shows holds it too"
	)

	# Counted through the signal into an Array: a lambda captures a scalar by value.
	var uses: Array[int] = []
	if hand_rig is ZeeWeaponRig:
		(hand_rig as ZeeWeaponRig).used.connect(func(_o: DotWeaponOutcome) -> void: uses.append(1))

	_tcb_client._primary_down()
	for _i in range(120):
		await get_tree().physics_frame
	_tcb_client._primary_up()

	_check(uses.size() > 1, "held fire through the client's own tick fires it, again and again",
		"%d uses in 120 ticks" % uses.size())

	await _the_arms_hold_each_weapon_class()

	_tcb_client._set_tool(&"phys")
	_check(
		_tcb_client.player.zee_rig == null and _tcb_client.zee_view == null and _tcb_client.player.zee_world == null,
		"and the physics gun takes it back out of their hands"
	)
	var toy_in_hand: Node3D = _tcb_client.toy_view
	_check(
		toy_in_hand != null and toy_in_hand.get_parent() == _tcb_client.camera
			and toy_in_hand.is_in_group(&"dot_view_model"),
		"a toy in hand draws a first-person model under the camera, in the viewmodel_fov group"
	)
	_tcb_client._set_tool(&"launcher")
	_check(_tcb_client.toy_view != null and _tcb_client.toy_view != toy_in_hand,
		"and picking another toy swaps the model")
	(_tcb_client.toy_view as DotToolView).set_hands_fov_at_4_3(40.0)
	(_tcb_client.toy_view as DotToolView)._process(0.016)
	_check(_tcb_client.toy_view.scale.x != 1.0, "and viewmodel_fov scales it like a gun")
	_tcb_client._set_tool(&"phys")

	# Water splashes: a crate dropped into Nature's pond, heard on the client's own frames.
	var _wet_map: DotResult = await _tcb_client.playground.change_map(&"pgc_nature")
	_tcb_client.playground.props.limits.spawn_interval = 0.0
	var before_splash := _tcb_client.presentation.splashes
	var _dropped := _tcb_client.playground.props.spawn(&"crate", _tcb_client.player.player_id, Vector3(60.0, 4.0, 50.0))
	# Physics ticks, not frames: a headless frame is unthrottled, and ninety of them passed
	# before the crate had fallen at all.
	for _i in range(256):
		await get_tree().physics_frame
	_check(_tcb_client.presentation.splashes > before_splash, "a crate dropped into the pond splashes",
		"%d splashes" % (_tcb_client.presentation.splashes - before_splash))
	var _dry_map: DotResult = await _tcb_client.playground.change_map(&"pg_flatgrass")
	await get_tree().physics_frame

	# The tool gun's edit mode, through the client's own buttons and menu.
	var eye := _tcb_client.player.eye_position()
	_tcb_edited = _tcb_client.playground.props.spawn(&"crate", _tcb_client.player.player_id,
		eye + _tcb_client.player.aim_direction() * 2.5)
	if _tcb_edited != null:
		DotPhysGun.set_frozen(_tcb_edited, true)
		(_tcb_edited.node as Node3D).call("set_tint", Color.html("e05252"))
	_tcb_client._on_tool_mode_chosen(&"edit", {})
	_tcb_client.menu.tool_mode = &"edit"
	await get_tree().physics_frame

func _test_the_client_boots_13() -> void:
	_tcb_client._primary_down()
	_tcb_client._primary_up()
	await get_tree().process_frame
	var box: Node = (_tcb_edited.node as Node).get_node_or_null("EditSelection") if _tcb_edited != null else null
	_check(_tcb_edited != null and _tcb_client.edit_target == _tcb_edited.node and box is MeshInstance3D,
		"the edit mode selects what the client points at, and draws a box round it")
	_check(str((_tcb_client.menu.tool_settings.get(&"edit", {}) as Dictionary).get("colour", "")) == "e05252",
		"and the Q menu's edit settings become that prop's own", str(_tcb_client.menu.tool_settings.get(&"edit")))
	_tcb_client.menu._set_setting("size", 2.0)
	await get_tree().process_frame
	_check(_tcb_edited != null and is_equal_approx(float((_tcb_edited.node as Node3D).get("size_scale")), 2.0),
		"a slider in the menu resizes it")
	_check(box is MeshInstance3D and is_instance_valid(box) and ((box as MeshInstance3D).mesh as BoxMesh).size.x > 1.9,
		"and the box grows with it",
		str(((box as MeshInstance3D).mesh as BoxMesh).size) if box is MeshInstance3D and is_instance_valid(box) else "no box")
	_tcb_client._secondary_down()
	_tcb_client._secondary_up()
	await get_tree().process_frame
	_check(_tcb_client.edit_target == null and (_tcb_edited == null or (_tcb_edited.node as Node).get_node_or_null("EditSelection") == null),
		"right click lets go, and the box goes with it")
	_tcb_client._set_tool(&"phys")

	_tcb_client.queue_free()

	await get_tree().process_frame
	await get_tree().process_frame
	_done()
