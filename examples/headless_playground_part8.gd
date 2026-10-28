extends "res://examples/headless_playground_part7.gd"

func _test_the_client_boots() -> void:
	_section("the client boots")

	var client := PlaygroundClient.new()
	client.name = "Client"

	# Its own config, records in memory. A test must not write into the user's data
	# directory, and this is the only reason `PlaygroundClient.config` exists.
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	client.config = config

	add_child(client)

	for _i in range(4):
		await get_tree().process_frame

	# The load gate covers the client, and holds its input and its body, until the level, the
	# player and the camera are in and the physics has settled: a test that drives the
	# client waits for it as a player would.
	await _gate_opens(client)
	_check(client.gate != null and client.gate.is_open(), "the load gate opens once the level, player and camera are in",
		"state %s held %s" % [client.gate.state(), client.gate.reasons()] if client.gate != null else "no gate")

	_check(client.playground != null, "the client builds a playground")
	_check(
		client.playground != null and client.playground.booted,
		"which finishes booting"
	)
	_check(
		client.playground != null and client.playground.maps.current != null,
		"with a map up",
		String(client.playground.maps.current.id)
			if client.playground != null and client.playground.maps.current != null
			else "none"
	)

	# The four things that are all missing together when `_ready` stops halfway.
	_check(client.player != null, "the client has a player")
	_check(client.camera != null, "and a camera")
	_check(client.hud != null, "and a HUD")
	_check(
		client.screens != null and client.menu != null,
		"and a spawn menu registered on a stack"
	)

	_check(
		client.menu != null and client.screens != null
		and client.screens.screen(client.menu.screen_id()) == client.menu,
		"which the stack can find by id"
	)
	_check(
		client.player != null and client.player.samples_input
		and client.player.sampler != null,
		"and the player samples input, with a sampler actually built"
	)

	# [b]A death draws the server's fall from the body this client draws.[/b] Connected the
	# reaction comes on COMBAT; here it is handed over, which is the half no wire check sees.
	# Armed by spawning from the character node instead of its body (the parts check fails:
	# the capsule-and-marker node is not the figure) and by ignoring the rules (the topple).
	client._build_ragdolls()
	var other := client.playground.add_player(&"u66", "Fallen")
	other.teleport(client.player.controller.state.position + Vector3(0.0, 0.0, -4.0))
	await get_tree().process_frame
	var crumple := DotPlayerDeath.new()
	crumple.reaction = DotPlayerDeathReactions.CRUMPLE
	var body := client.fall(&"u66", crumple)
	_check(body != null and body.reaction.id == DotPlayerDeathReactions.CRUMPLE and body.part_count() > 1
			and not other.character.body().visible,
		"a death falls as the server's reaction, copied from the drawn figure, which is hidden",
		str(body.describe()) if body != null else "no body")
	client.rise(&"u66")
	_check(other.character.body().visible, "and a return draws the figure again")
	client.ragdolls.clear()
	var _off := client.playground.ragdoll_rules.set_cvar("sv_ragdoll", "0")
	var toppled := client.fall(&"u66", crumple)
	_check(toppled != null and toppled.style == DotPlayerRagdollRules.Style.TOPPLE,
		"the server's sv_ragdoll 0 is the topple fallback")
	var _on := client.playground.ragdoll_rules.set_cvar("sv_ragdoll", "1")
	client.ragdolls.clear()
	client.rise(&"u66")
	_check(client.fall(client.player.player_id, crumple) == null,
		"no ragdoll of your own body in first person")
	client.playground.remove_player(&"u66")

	# [b]The sensitivity slider reaches the sampler.[/b] It was declared, shown and saved,
	# and nothing called `bind_look`, so the view turned at DotFpsTunables' default (0.25
	# degrees per count) whatever the player chose. Read off the tunables the sampler turns
	# the view with, offline and for the connected client's own sampler, which `_adopt`
	# hands a fresh tunables object. Armed: without `_bind_look` all four fail.
	var look_settings: DotSettingsManager = (
		client.presentation.settings if client.presentation != null else null
	)
	var look: DotFpsTunables = (
		client.player.sampler.tunables
		if client.player != null and client.player.sampler != null else null
	)
	_check(
		look != null and look_settings != null and is_equal_approx(look.mouse_sensitivity,
			look_settings.get_float(&"sensitivity") * DotMenuApplier.DEGREES_PER_COUNT),
		"the saved sensitivity reaches the offline sampler, at dot-menu's degrees per count",
		"%.4f" % (look.mouse_sensitivity if look != null else -1.0)
	)
	if look_settings != null:
		look_settings.set_value(&"sensitivity", 4.0)
	_check(
		look != null and is_equal_approx(look.mouse_sensitivity, 4.0 * DotMenuApplier.DEGREES_PER_COUNT),
		"and moving the slider changes the turning speed",
		"%.4f" % (look.mouse_sensitivity if look != null else -1.0)
	)
	var net_sampler := DotFpsSampler.new(DotFpsTunables.new())
	client._sampler = net_sampler
	client._bind_look()
	if look_settings != null:
		look_settings.set_value(&"sensitivity", 3.0)
	client._sampler = null
	_check(
		is_equal_approx(net_sampler.tunables.mouse_sensitivity, 3.0 * DotMenuApplier.DEGREES_PER_COUNT),
		"and the connected client's sampler, rebound when it adopts its player, follows it too",
		"%.4f" % net_sampler.tunables.mouse_sensitivity
	)
	if look_settings != null:
		look_settings.set_value(&"invert_mouse", true)
	_check(
		look != null and look.invert_look_y and net_sampler.tunables.invert_look_y,
		"and inverting the vertical look inverts both"
	)
	if look_settings != null:
		look_settings.set_value(&"invert_mouse", false)

	# [b]The mouse, end to end.[/b] Nothing in this family had ever delivered an
	# `InputEventMouseMotion` to a client and looked at what happened, which is how a
	# dead mouse survived: `_on_mouse_motion` fed `player.sampler` and `_net_physics`
	# sampled `_sampler`, two different objects, and `DotFpsSampler.sample` polls the
	# `InputMap` for movement so everything except the view kept working.
	var before_yaw: float = (
		client.player.controller.state.yaw if client.player != null else 0.0
	)

	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(120.0, 0.0)

	# [b]Captured, because a look input is only a look input while it is.[/b] Headless
	# starts VISIBLE, which is the state a player is in after one press of Escape, and
	# the guard in `_on_mouse_motion` is what stops a free cursor from turning the view
	# under itself. Setting it here makes this check model somebody playing rather than
	# somebody with a menu key stuck down.
	client.mouse_capture_override = true
	client._unhandled_input(motion)

	# The sampler accumulates and spends it on the next simulated tick, so the view has
	# not turned yet -- that is the point of accumulating it. Let the game tick.
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(
		client.player != null
		and not is_equal_approx(client.player.controller.state.yaw, before_yaw),
		"a mouse motion turns the view",
		"yaw %.3f -> %.3f" % [
			before_yaw,
			client.player.controller.state.yaw if client.player != null else 0.0
		]
	)

	# [b]And the other half: a released cursor turns nothing.[/b] Escape frees the
	# pointer with no screen open, so `_menu_is_open` is false and every check above
	# still passes while the view spins under a cursor the player is aiming at a
	# spawn menu with. Same event, same client, one property different.
	#
	# Driven through `mouse_capture_override` because `Input.mouse_mode` is a no-op
	# under the dummy display server -- it reads VISIBLE however it is written, so a
	# suite that set it directly would prove nothing and pass anyway.
	var released_yaw: float = client.player.controller.state.yaw

	client.mouse_capture_override = false

	var free_motion := InputEventMouseMotion.new()
	free_motion.relative = Vector2(120.0, 0.0)
	client._unhandled_input(free_motion)

	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(
		is_equal_approx(client.player.controller.state.yaw, released_yaw),
		"and a motion with the cursor released turns nothing",
		"yaw %.3f -> %.3f" % [released_yaw, client.player.controller.state.yaw]
	)

	# [b]Escape releases and never captures; a click captures -- the platform's job now.[/b]
	# game-g2gfast's contract, for the browser. `Input.mouse_mode` is a no-op under the dummy
	# display server, so what is checked is the configuration (dot-game's own suite drives
	# the release), that no screen is up for the pointer rule, and that Escape on a pointer
	# that is not captured is the second press and opens the menu, never a capture.
	var plat: DotGameClient = client.platform
	_check(
		plat != null and plat.escape_releases_pointer and plat.capture_pointer
		and plat.menu == client.game_menu and plat.console != null
		and plat.console == client.presentation.console,
		"the platform owns the pointer and the menu, and built the console after it"
	)
	_check(
		plat.pointer_fn.call() == true and not client._menu_is_open(),
		"a click may take the pointer back while no screen is up"
	)
	var escape := InputEventKey.new()
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	var kept_menu: DotMenu = client.game_menu
	client.mouse_capture_override = false
	client._unhandled_input(escape)
	_check(
		kept_menu != null and kept_menu.is_open() and client.mouse_capture_override == false,
		"Escape with the pointer free is the second press: it opens the menu and never captures"
	)
	kept_menu.close_all()

	# With the menu, the second Escape opens it — dot-menu's, whose own Escape is off so
	# this game keeps its two steps — and Escape closes it again.
	kept_menu.open()
	var opened := kept_menu != null and kept_menu.is_open()
	# The menu swallows an Escape that lands within its grace of opening (a browser's own
	# pointer-lock Escape arriving late must not flash it shut), and this one lands in the
	# same millisecond, so the grace is off for this press.
	var grace := kept_menu.config.escape_grace_ms if kept_menu != null else 0
	if kept_menu != null:
		kept_menu.config.escape_grace_ms = 0
	var shut := kept_menu != null and kept_menu.handle_event(escape) and not kept_menu.is_open()
	if kept_menu != null:
		kept_menu.config.escape_grace_ms = grace
	_check(opened and shut, "the second Escape opens the menu, and Escape closes it")

	# [b]H is help, in every game of the family[/b], every key is a row of the table, and the
	# Escape menu has Help & commands and Leave (the first play test found Help hidden here).
	var keys: DotMenuBindings = client.keys
	_check(keys != null and keys.key_for(DotMenuBindings.HELP_ACTION) == "H" and keys.defaults_on("H").size() == 1,
		"help is on H, and nothing else in the key table is")
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	var helped := kept_menu != null and kept_menu.handle_event(h) and kept_menu.help.is_open()
	_check(helped and kept_menu.help.about != "" and kept_menu.help.heading() == "How to play Playground",
		"H opens the help screen, which says what the game is before the keys")
	if kept_menu != null:
		kept_menu.close_all()
		kept_menu.open()
	var leave_button := kept_menu.screen.find_child("Action_leave", true, false) as Button if kept_menu != null else null
	_check(kept_menu != null and kept_menu.screen.find_child("Action_help", true, false) != null
		and leave_button != null and leave_button.visible, "the Escape menu has Help & commands and Leave")
	if kept_menu != null:
		kept_menu.close_all()

	var menu: DotMenu = kept_menu

	# M, the family's rule since the first play test: the map list, and solo a choice
	# changes it now. The server's half (the owner's flag, the vote) is in `dedicated`.
	_check(keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table is",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	# B is the family's loadout key, the arena's loadout: nothing else here may default to it
	# (Clear checkpoints was B). Solo there is no arena, and B says where the loadouts are.
	var on_b := keys.defaults_on("B")
	_check(on_b.size() <= 1 and on_b.all(func(r: Dictionary) -> bool: return StringName(str(r["action"])) == DotMenuBindings.LOADOUT_ACTION),
		"only the loadout is on B, the family's loadout key",
		str(on_b.map(func(r: Dictionary) -> String: return str(r["label"]))))
	# The right button aims a zee gun (the family's Aim row); its quick melee is the middle one.
	_check(keys.key_for(PlaygroundBindings.AIM) == "Mouse 2" and keys.defaults_on("Mouse 2").size() == 1
		and keys.key_for(PlaygroundBindings.BASH) == "Mouse 3", "a gun aims on the right button, quick melee on the middle",
		"%s %s" % [keys.key_for(PlaygroundBindings.AIM), keys.key_for(PlaygroundBindings.BASH)])
	if client.get("loadout_menu") != null:
		menu.close_all()
		var b_key := InputEventKey.new()
		b_key.physical_keycode = KEY_B
		b_key.keycode = KEY_B
		b_key.pressed = true
		var menu_took := menu.handle_event(b_key)
		client.call("_unhandled_input", b_key)
		var said := ((client.get("hud") as Node).get("_notice") as Label).text
		_check(not menu_took and not bool(client.get("arena_on")) and said == "Loadouts are in the arena.",
			"solo B opens nothing and says the loadouts are in the arena", said)
	# Down a zee gun's sights the HUD hands dot-ui's crosshair the aim; a scope replaces it.
	var pg_hud: Node = client.get("hud")
	pg_hud.call("set_aim", 1.0, true)
	var scoped_ok := float((pg_hud.get("scope") as Control).get("fraction")) == 1.0 and not (pg_hud.get("_crosshair") as Control).visible
	pg_hud.call("set_aim", 0.0, false)
	_check(scoped_ok and (pg_hud.get("_crosshair") as Control).visible and float((pg_hud.get("scope") as Control).get("fraction")) == 0.0,
		"through a scope the HUD shows zee's scope instead of the crosshair, and puts it back at the hip")
	var pg_xh := pg_hud.get("_crosshair") as DotCrosshair
	pg_hud.call("set_alive", false)
	var dead_hidden: bool = DotAddonApi.build_level("dot_ui") < 14 or not pg_xh.is_shown()
	pg_hud.call("set_alive", true)
	_check(dead_hidden and pg_xh.is_shown(), "the HUD hides the crosshair while the viewer is dead and shows it again alive")
	# Closed right before the key: an offline client with no captured pointer (headless) may
	# have put its menu back up, and while anything is open every key is the menu's.
	menu.close_all()
	var map_before: StringName = client.playground.maps.current.id
	var m_key := InputEventKey.new()
	m_key.physical_keycode = KEY_M
	m_key.keycode = KEY_M
	m_key.pressed = true
	_check(menu.handle_event(m_key) and menu.picker.is_open() and menu.picker.items.size() > 1,
		"M opens the map list, more than one to choose", str(menu.picker.items.size()))
	var wanted_map: StringName = &""
	var map_key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted_map = StringName(str((it as Dictionary)["id"]))
			map_key = KEY_0 + row
			break
	var digit_key := InputEventKey.new()
	digit_key.physical_keycode = map_key
	digit_key.keycode = map_key
	digit_key.pressed = true
	var _picked := menu.handle_event(digit_key)
	for _i in 60:
		await get_tree().physics_frame
	_check(wanted_map != &"" and client.playground.maps.current.id == wanted_map and not menu.picker.is_open(),
		"choosing one changes the map now", "%s, now %s" % [wanted_map, client.playground.maps.current.id])
	# Back where it was, for the checks after this one.
	var _back_map: Variant = await menu.maps.change_fn.call(map_before)
	for _i in 60:
		await get_tree().physics_frame
	var spawn_row := keys.row_for_action(&"pg_spawn") if keys != null else {}
	var rebound: DotResult = keys.rebind(spawn_row, "J", client.presentation.settings) if not spawn_row.is_empty() else DotResult.fail(DotError.CODE_STATE, "no row")
	var j := InputEventKey.new()
	j.physical_keycode = KEY_J
	var e := InputEventKey.new()
	e.physical_keycode = KEY_E
	_check(rebound.ok and j.is_action(&"pg_spawn") and not e.is_action(&"pg_spawn"),
		"a key rebound in the menu moves what the client reads (spawn on J, E free)")
	if keys != null:
		keys.reset_all(client.presentation.settings)
	_check(e.is_action(&"pg_spawn"), "and Reset puts it back on E")
	client.mouse_capture_override = true

	# From released, whatever the line above left, so this check stands on its own: the click
	# that takes the pointer back (the platform captures it) is spent on that and punts nothing.
	client.mouse_capture_override = false
	client._was_driving = false
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	var tool_before: Variant = client.get(&"_aiming")
	client._unhandled_input(click)

	_check(
		client.get(&"_aiming") == tool_before and not client._menu_is_open(),
		"a click with the pointer released is spent on taking it back"
	)

	client.mouse_capture_override = true

	# And the routing rule itself, for the deployment this suite does not build. A
	# networked client's mouse must reach `_sampler`, because that is the sampler
	# `_net_physics` stamps a command from; `player.sampler` is null on one and the
	# events went there. Asserted on the accessor rather than by standing a whole
	# networked client up, because the bug was the disagreement between two lines and
	# an accessor both of them go through is what fixed it.
	_check(
		client.active_sampler() == client.player.sampler,
		"a local client's mouse feeds the player's own sampler"
	)

	# Christian's first play test: a darker HUD by default, restyled live by the menu's theme.
	var plate := client.hud.ammo.colour(&"plate")
	_check(client.game_menu.followed_huds().has(client.hud) and plate.get_luminance() < 0.1 and plate.a >= 0.7
		and client.hud.ammo.colour(&"highlight") == PlaygroundGeometry.COLOUR_BOOST,
		"the HUD is dark by default, in the menu's theme, with the boost amber as its accent", str(plate))
	var _themed: Variant = client.game_menu.settings.set_value(&"ui_theme", &"contrast")
	_check(client.hud.ammo.colour(&"plate") == client.game_menu.palette().hud_plate
		and client.hud.hit_marker.colour(&"text") == client.game_menu.palette().hud_text
		and client.hud.ammo.colour(&"highlight") == PlaygroundGeometry.COLOUR_BOOST
		and (client.hud.timer_hud == null
			or client.hud.timer_hud.get("panel_colour") == client.game_menu.palette().hud_plate),
		"a theme picked in the menu reaches the pieces, and a run timer's block when there is one, at once, the accent kept")
	_themed = client.game_menu.settings.set_value(&"ui_theme", &"midnight")

	# [b]Typing at the console must not walk the player.[/b] The sampler polls the keys
	# every tick and a focused line edit does not stop `Input.is_action_pressed`; the
	# console is one of dot-menu's overlays (DotConsoleKit registers it), and the menu's
	# `overlays_changed` is what suspends the sampler. W held, measured in metres.
	var console := client.presentation.console if client.presentation != null else null
	var forward: StringName = client.player.sampler.actions["forward"]
	for _i in range(60):
		await get_tree().physics_frame
	var _opened := console.open() if console != null else false
	await get_tree().process_frame
	_check(console != null and client.game_menu.any_open() and client.player.sampler.suspended,
		"the console opens as one of the menu's overlays and suspends the sampler")
	var typing_from := client.player.global_position
	Input.action_press(forward)
	for _i in range(30):
		await get_tree().physics_frame
	Input.action_release(forward)
	var typed := client.player.global_position.distance_to(typing_from)
	_check(typed < 0.001, "W held with the console open moves nobody", "%.3f m" % typed)
	if console != null:
		console.close()
	await get_tree().process_frame
	_check(not client.player.sampler.suspended and not client.game_menu.any_open(),
		"closing it gives the keys back")
	var walking_from := client.player.global_position
	Input.action_press(forward)
	for _i in range(30):
		await get_tree().physics_frame
	Input.action_release(forward)
	var walked := client.player.global_position.distance_to(walking_from)
	_check(walked > 0.1, "and the same W walks again (the control)", "%.3f m" % walked)
	# The control walk coasts; the checks below expect a player standing still.
	for _i in range(60):
		await get_tree().physics_frame
	# Closing an overlay recaptures the pointer, which moves the override; put it back.
	client.mouse_capture_override = true

	var networked := PlaygroundClient.new()
	networked.link = Node.new()
	networked._sampler = DotFpsSampler.new(DotFpsTunables.new())

	_check(
		networked.active_sampler() == networked._sampler,
		"and a networked client's feeds the one its tick stamps commands from"
	)

	networked.link.free()
	networked.free()

	# [b]A connected client's HUD holds the vote's clock.[/b] The netcode comes up before
	# the HUD in `_ready`, and the hand-over used to sit with the netcode, where it found
	# no HUD — so every connected client counted its own map session's clock through
	# every extend while `headless_net`, which checks the bridge and not the client, said
	# the clock arrived. Booted for real here, with a bare node for a link: the bridge
	# needs one and the client asks every method of it before calling.
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

	# [b]The client makes a noise when something happens, through the game and not
	# through the hooks.[/b] headless_presentation calls `on_prop_spawned` itself, which
	# proved every hook correct while nothing in the game called one and the playable
	# client was silent. This goes through the client's own spawn, the spawner's own
	# refusal and a real map change.
	var sink := client.presentation.audio.sink as DotAudioSinkNull \
		if client.presentation != null and client.presentation.audio != null else null
	_check(sink != null, "the headless client's presentation has a null sink to count on")

	if sink != null:
		# The null sink never reaps and the ambience layer's beds are loops: room for the cue under test.
		sink.capacity = 64
		sink.forget()
		client.selected_prop = &"crate"
		client._spawn()
		_check(
			sink.count_of(&"prop_spawn") == 1,
			"a prop the client spawns through the game makes a noise",
			"%d" % sink.count_of(&"prop_spawn")
		)

		# The physics gun's beam, through the client's own frame: a hook nothing calls is
		# this file's oldest bug. Holding is set by hand, because a grab needs the prop in
		# the crosshair and that is dot-props' suite's question, not this one's.
		var mine := client.playground.props.props_of(client.player_id)
		var crate: DotPropInstance = mine.back() if not mine.is_empty() else null
		var crate_body := crate.node as Node3D if crate != null else null
		if crate_body != null:
			client.player.phys_gun.held = crate
			client._holding = true
			await get_tree().process_frame
			await get_tree().process_frame
			var beam: Node3D = client.presentation._beams.get(0)
			var tip := beam.global_transform * Vector3(0, 0, -1) \
				if beam != null and is_instance_valid(beam) else Vector3.INF
			_check(
				tip.distance_to(crate_body.global_position) < 0.3,
				"the client's own frame draws the physics gun's beam to what it holds",
				"tip %s, prop %s" % [tip, crate_body.global_position]
			)
			client._holding = false
			client.player.phys_gun.held = null
		else:
			_check(false, "the client's own frame draws the physics gun's beam to what it holds",
				"the crate the client spawned is not there to hold")

		sink.forget()
		client.playground.props.spawn(&"no_such_prop", client.player_id, Vector3.ZERO)
		_check(
			sink.count_of(&"refused") == 1,
			"and a spawn the spawner refuses makes the refusal noise",
			"%d" % sink.count_of(&"refused")
		)

		# An administrator's beacon and blind, through the client's OWN frame hooks rather
		# than the player's method: the marker and the ping are presentation, and a hook
		# nothing in the client calls is this file's oldest bug. Stepped by hand, a quarter
		# of a second at a time, so the count is the ripple's and not the frame rate's.
		client.player.beacon = true
		sink.forget()
		# The null sink never ends a sound by itself, so by here pg_flatgrass's toys have
		# filled its 32 voices and the second and third pings were refused as "voices".
		# Emptied first, so what is counted is the beacon's rhythm and not the sink's room.
		sink.stop_all()
		for _i in range(8):
			client._present_beacons(0.25)
		_check(
			sink.count_of(&"beacon") == 3,
			"a beacon pings as it comes on and once a second after, not once a frame",
			"%d pings in two seconds" % sink.count_of(&"beacon")
		)
		var marker := client.player.beacon_marker
		_check(
			marker != null and marker.is_inside_tree()
			and marker.global_position.is_equal_approx(client.player.controller.state.position),
			"its marker stands where the player is simulated"
		)
		_check(
			marker != null and not marker.column_shown(),
			"with no column on the player's own first-person view, which would smear the screen"
		)
		client.player.beacon = false
		client._present_beacons(0.25)
		_check(client.player.beacon_marker == null, "and it goes when the flag does")

		# And through real frames, because the checks above call the hook by hand and would
		# pass with `_process` never calling it — which is the shape every presentation hook
		# in this game once had.
		client.player.beacon = true
		await get_tree().process_frame
		await get_tree().process_frame
		_check(
			client.player.beacon_marker != null,
			"the client's own frame draws a beacon, not only a test calling the hook"
		)
		client.player.beacon = false
		await get_tree().process_frame
		await get_tree().process_frame
		_check(client.player.beacon_marker == null, "and its own frame takes it away")

		client.player.blinded = true
		client.hud.present_blind(0.5)
		var blind := client.hud.blind_overlay
		var viewport := client.hud.get_viewport_rect().size
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
			blind != null and blind.get_index() < client.hud.ammo.get_index(),
			"under the HUD's own widgets, so the counters still say the game is going on"
		)
		client.player.blinded = false
		client.hud.present_blind(0.5)
		_check(blind != null and not blind.visible, "and lifts when the flag does")

		client.presentation.fx.shake.add(1.0)
		_check(client.presentation.fx.shake.active(), "a shake is live before a map change")
		await client.playground.change_map(&"pg_generated")
		_check(
			not client.presentation.fx.shake.active(),
			"and a map change clears it, because the effects' world has gone"
		)

	# zee-dot-weapons, offline, through the client's own key handlers and its own tick.
	client._set_tool(&"zee_smg")
	await get_tree().process_frame

	var hand_rig: Variant = client.player.zee_rig if client.player != null else null
	_check(
		hand_rig is ZeeWeaponRig and client.zee_view != null
			and client.zee_view.get_parent() == client.camera,
		"a zee weapon from the menu puts hands under the camera"
	)
	_check(
		hand_rig is ZeeWeaponRig and (hand_rig as ZeeWeaponRig).authority,
		"and offline the client's rig is the one that decides"
	)
	var body_gun: Variant = client.player.zee_world if client.player != null else null
	_check(
		body_gun is ZeeWorldModel and (body_gun as ZeeWorldModel).equipped() == &"smg",
		"and the body a third-person camera shows holds it too"
	)

	# Counted through the signal into an Array: a lambda captures a scalar by value.
	var uses: Array[int] = []
	if hand_rig is ZeeWeaponRig:
		(hand_rig as ZeeWeaponRig).used.connect(func(_o: DotWeaponOutcome) -> void: uses.append(1))

	client._primary_down()
	for _i in range(120):
		await get_tree().physics_frame
	client._primary_up()

	_check(uses.size() > 1, "held fire through the client's own tick fires it, again and again",
		"%d uses in 120 ticks" % uses.size())

	client._set_tool(&"phys")
	_check(
		client.player.zee_rig == null and client.zee_view == null and client.player.zee_world == null,
		"and the physics gun takes it back out of their hands"
	)

	# Water splashes: a crate dropped into Nature's pond, heard on the client's own frames.
	var _wet_map: DotResult = await client.playground.change_map(&"pgc_nature")
	client.playground.props.limits.spawn_interval = 0.0
	var before_splash := client.presentation.splashes
	var _dropped := client.playground.props.spawn(&"crate", client.player.player_id, Vector3(60.0, 4.0, 50.0))
	# Physics ticks, not frames: a headless frame is unthrottled, and ninety of them passed
	# before the crate had fallen at all.
	for _i in range(256):
		await get_tree().physics_frame
	_check(client.presentation.splashes > before_splash, "a crate dropped into the pond splashes",
		"%d splashes" % (client.presentation.splashes - before_splash))
	var _dry_map: DotResult = await client.playground.change_map(&"pg_flatgrass")
	await get_tree().physics_frame

	# The tool gun's edit mode, through the client's own buttons and menu.
	var eye := client.player.eye_position()
	var edited := client.playground.props.spawn(&"crate", client.player.player_id,
		eye + client.player.aim_direction() * 2.5)
	if edited != null:
		DotPhysGun.set_frozen(edited, true)
		(edited.node as Node3D).call("set_tint", Color.html("e05252"))
	client._on_tool_mode_chosen(&"edit", {})
	client.menu.tool_mode = &"edit"
	await get_tree().physics_frame
	client._primary_down()
	client._primary_up()
	await get_tree().process_frame
	var box: Node = (edited.node as Node).get_node_or_null("EditSelection") if edited != null else null
	_check(edited != null and client.edit_target == edited.node and box is MeshInstance3D,
		"the edit mode selects what the client points at, and draws a box round it")
	_check(str((client.menu.tool_settings.get(&"edit", {}) as Dictionary).get("colour", "")) == "e05252",
		"and the Q menu's edit settings become that prop's own", str(client.menu.tool_settings.get(&"edit")))
	client.menu._set_setting("size", 2.0)
	await get_tree().process_frame
	_check(edited != null and is_equal_approx(float((edited.node as Node3D).get("size_scale")), 2.0),
		"a slider in the menu resizes it")
	_check(box is MeshInstance3D and is_instance_valid(box) and ((box as MeshInstance3D).mesh as BoxMesh).size.x > 1.9,
		"and the box grows with it",
		str(((box as MeshInstance3D).mesh as BoxMesh).size) if box is MeshInstance3D and is_instance_valid(box) else "no box")
	client._secondary_down()
	client._secondary_up()
	await get_tree().process_frame
	_check(client.edit_target == null and (edited == null or (edited.node as Node).get_node_or_null("EditSelection") == null),
		"right click lets go, and the box goes with it")
	client._set_tool(&"phys")

	client.queue_free()

	await get_tree().process_frame
	await get_tree().process_frame
	_done()


func _test_the_wheel_cycles_tools() -> void:
	_section("the wheel cycles tools")

	var keys := PlaygroundBindings.make()
	var prev_row := {}
	var next_row := {}
	var jump_wheel := 0
	for row in keys.rows:
		var action := StringName(str(row["action"]))
		if action == DotMenuBindings.WEAPON_PREVIOUS_ACTION:
			prev_row = row
		elif action == DotMenuBindings.WEAPON_NEXT_ACTION:
			next_row = row
		elif action == DotMenuBindings.JUMP_ACTION and str(row["default"]).begins_with("Wheel"):
			jump_wheel += 1
	_check(str(prev_row.get("default", "")) == "Wheel up" and str(next_row.get("default", "")) == "Wheel down",
		"the weapon actions default to Wheel up and Wheel down", "%s / %s" % [prev_row.get("default"), next_row.get("default")])
	_check(jump_wheel == 0, "and the wheel is on no jump row", str(jump_wheel))

	var client := PlaygroundClient.new()
	client.name = "WheelClient"
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	client.config = config
	add_child(client)
	for _i in range(4):
		await get_tree().process_frame
	await _gate_opens(client)

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true

	var ring := client._tool_ring()
	_check(ring.size() >= 2 and ring[0] == &"phys", "a client has two or more tools to cycle", str(ring))

	client.mouse_capture_override = true
	client._was_driving = true
	client._set_tool(ring[0])
	client.call("_unhandled_input", down)
	_check(client.tool == ring[1], "a wheel-down press moves one slot on", str(client.tool))
	client.call("_unhandled_input", up)
	_check(client.tool == ring[0], "and a wheel-up press moves one back", str(client.tool))
	client.call("_unhandled_input", up)
	_check(client.tool == ring[ring.size() - 1], "wrapping round past the first", str(client.tool))

	client._set_tool(ring[0])
	var before_holding: bool = client._holding
	client._holding = true
	client.call("_unhandled_input", down)
	_check(client.tool == ring[0], "while holding a prop the wheel does not change tools", str(client.tool))
	client._holding = before_holding

	client.queue_free()
	await get_tree().process_frame
	_done()


# --- The circuit -----------------------------------------------------------
