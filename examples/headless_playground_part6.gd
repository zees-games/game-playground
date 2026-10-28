extends "res://examples/headless_playground_part5.gd"

## The hand-built maps: every script in res://maps but the generated one and the
## document reader, which are surveyed with their own arguments. Read off the directory so
## a map added is surveyed without anybody adding it here.
func _built_map_ids() -> Array[String]:
	var out: Array[String] = []

	for file in DirAccess.get_files_at("res://maps"):
		if file.ends_with(".gd") and not file.get_basename() in ["pg_generated", "pg_data"]:
			out.append(file.get_basename())

	out.sort()
	return out


# --- A run -----------------------------------------------------------------

## The spawn menu, driven the way a player drives it.
##
## [b]dot-ui's suite cannot reach this and neither can dot-props'.[/b] A menu built
## out of a catalogue is exactly the seam this project exists to run: the screen stack
## is one addon, the catalogue is another, and the code joining them is here. It is
## also a `Control` built entirely in code, which is the shape that produced the
## family's `set_anchors_preset` bug — so the sizes are checked, not just the
## contents.
var _sm_menu: PlaygroundSpawnMenu
var _sm_stack: DotScreenStack
var _sm_servers: PlaygroundBrowser
var _sm_props_shown: Array[StringName]
var _sm_prop_count: int
var _sm_picked: Array[String]

func _test_spawn_menu() -> void:
	_section("the spawn menu")

	_sm_menu = PlaygroundSpawnMenu.new()
	_sm_menu.catalogue = playground.props.catalogue
	_sm_menu.weapons = playground.weapons
	add_child(_sm_menu)

	# Registered on a real stack rather than shown directly: pushing is what calls
	# `_on_push`, and `_on_push` is what fills the grid.
	_sm_stack = DotScreenStack.new()
	add_child(_sm_stack)

	var ready := _sm_stack.setup()
	_check(ready.ok, "the screen stack sets up")

	var registered := _sm_stack.register(_sm_menu)
	_check(registered.ok, "and the menu registers on it")

	var pushed := _sm_stack.push(_sm_menu.screen_id())
	_check(pushed.ok, "and opens")
	_check(_sm_stack.any_open(), "and the stack knows a menu is up")

	await get_tree().process_frame

	_check(
		_sm_menu.size.x > 100.0 and _sm_menu.size.y > 100.0,
		"the menu has a size, which a Control built in code does not get for free",
		"%.0f x %.0f" % [_sm_menu.size.x, _sm_menu.size.y]
	)

	# [b]The server browser, on the same stack and measured the same way.[/b] It is the
	# second screen this game has built in code, and the failure it can have is the one
	# dot-ui had five of: `set_anchors_preset` describes how a rectangle FOLLOWS its
	# parent and changes nothing until something resizes it, so a Control keeps the zero
	# size it was created with — and every child then lays out inside nothing while being,
	# by every property, correctly configured. Only a size says so.
	_sm_servers = PlaygroundBrowser.new()
	add_child(_sm_servers)

	var browser_registered := _sm_stack.register(_sm_servers)
	_check(browser_registered.ok, "the server browser registers too")

	var browser_open := _sm_stack.push(_sm_servers.screen_id())
	_check(browser_open.ok, "and opens")

	await get_tree().process_frame

	_check(
		_sm_servers.size.x > 100.0 and _sm_servers.size.y > 100.0,
		"and has a size rather than being an invisible 0 x 0",
		"%.0f x %.0f" % [_sm_servers.size.x, _sm_servers.size.y]
	)
	_check(
		_sm_servers.browser != null and _sm_servers.browser.count() > 0,
		"with something on the list, so a first run is not an empty box",
		"%d" % (_sm_servers.browser.count() if _sm_servers.browser != null else -1)
	)

	# [b]Filtering is local and always will be.[/b] A server that decided which of its own
	# properties to report is a server that reports whatever gets it listed — so the
	# filter lives on the model, and a screen that filtered its own rows would be a second
	# filter that disagrees with the one favourites are pinned by.
	_check(
		_sm_servers.browser.filter != null,
		"and a filter the client owns rather than one the server answers"
	)
	_test_spawn_menu_2()
	await _test_spawn_menu_3()
	await _test_spawn_menu_4()
	await _test_spawn_menu_5()

func _test_spawn_menu_2() -> void:

	# The site's listing: off unless a site is named, and this game's servers when one is.
	var env_key := "DOT_BROWSER_BACKBONE_URL"
	var had := OS.get_environment(env_key)
	OS.unset_environment(env_key)
	var off: DotResult = PlaygroundBrowser.site_listing()
	_check(
		off.ok and off.value == null
			and not _sm_servers.browser.sources().any(
				func(s: DotBrowserSource) -> bool: return s.source_name() == &"backbone"
			),
		"no site listing is read when none is configured"
	)
	OS.set_environment(env_key, "http://127.0.0.1:9")
	var on: DotResult = PlaygroundBrowser.site_listing()
	var listing: DotBrowserSourceBackbone = on.value if on.ok else null
	_check(
		listing != null and listing.config.page_url(1).contains("app=playground"),
		"and this game's servers are when one is",
		listing.config.page_url(1) if listing != null else str(on.error)
	)
	# Where the site comes from when nobody passed a flag. Web: ?backbone= > page origin;
	# native: argv > env > the exported default (argv over env is DotConfig.load_layered's
	# order and cannot be injected here). Each result is also the one a reversed order
	# would get wrong, so a swap fails a check.
	OS.unset_environment(env_key)
	var web_both := PlaygroundBrowser.resolve_default_site({
		"web": true, "origin": "https://site.example", "query": "https://other.example"
	})
	_check(web_both == "https://other.example", "on the web ?backbone= beats the page origin", web_both)
	var web_origin := PlaygroundBrowser.resolve_default_site({"web": true, "origin": "https://site.example", "query": ""})
	_check(web_origin == "https://site.example", "and with no query the page's own origin is the site", web_origin)
	var web_file := PlaygroundBrowser.resolve_default_site({"web": true, "origin": "null", "query": ""})
	_check(web_file == "", "and a page with no usable origin lists no site", web_file)
	var web_listing: DotResult = PlaygroundBrowser.site_listing({"web": true, "origin": "https://site.example", "query": ""})
	_check(
		web_listing.ok and web_listing.value != null
			and web_listing.value.config.page_url(1).begins_with("https://site.example/api/content/server/list")
			and web_listing.value.config.page_url(1).contains("app=playground"),
		"so a web client lists its own site's servers without a flag"
	)
	var saved_default := PlaygroundBrowser.default_backbone_url
	PlaygroundBrowser.default_backbone_url = "https://deploy.example"
	var native_default := PlaygroundBrowser.resolve_default_site({"web": false, "origin": "https://site.example", "query": "https://other.example"})
	_check(native_default == "https://deploy.example", "on native the exported default is used and the page is never asked", native_default)
	OS.set_environment(env_key, "http://127.0.0.1:9")
	var env_wins: DotResult = PlaygroundBrowser.site_listing({"web": false})
	_check(
		env_wins.ok and env_wins.value != null and env_wins.value.config.backbone_url == "http://127.0.0.1:9",
		"and the environment beats that default",
		str(env_wins.value.config.backbone_url) if env_wins.ok and env_wins.value != null else str(env_wins.error)
	)
	PlaygroundBrowser.default_backbone_url = saved_default
	if had != "":
		OS.set_environment(env_key, had)
	else:
		OS.unset_environment(env_key)

	_sm_stack.pop()
	_sm_servers.queue_free()

	# --- Props tab -----------------------------------------------------------

	_sm_props_shown = _sm_menu.shown()
	_sm_prop_count = 0

func _test_spawn_menu_3() -> void:

	# Hidden entries (debris) are the game's, not the menu's, as the menu's own filter says.
	for def in playground.props.catalogue.props:
		if PlaygroundSpawnables.kind_of(def) == PlaygroundSpawnables.Kind.PROP and not bool(def.meta.get("hidden", false)):
			_sm_prop_count += 1

	_check(
		_sm_props_shown.size() == _sm_prop_count,
		"the props tab shows every prop and no entities",
		"%d of %d" % [_sm_props_shown.size(), _sm_prop_count]
	)
	_check(
		not _sm_props_shown.has(&"npc_wanderer"),
		"and an entity is not among them"
	)
	_check(_sm_menu.card_for(&"crate") != null, "each one has a card that names it")

	# Icons. Nothing here ships art, so every card is drawn from the definition —
	# and a card with no icon at all is the failure that looks like a working menu
	# right up until somebody opens it.
	var crate_card := _sm_menu.card_for(&"crate")
	var ball_card := _sm_menu.card_for(&"ball")

	_check(
		crate_card != null and crate_card.icon != null
		and crate_card.icon.get_width() == PlaygroundIcons.SIZE,
		"with an icon on it"
	)
	_check(
		crate_card != null and ball_card != null
		and crate_card.icon != ball_card.icon,
		"and a box and a sphere do not get the same one"
	)

	# The cache is keyed on the drawing, not on the prop, so two props that draw the
	# same share a texture. That is what stops a four-hundred-prop catalogue building
	# four hundred images every time somebody presses Q.
	_check(
		PlaygroundIcons.generated(PlaygroundIcons.Glyph.BOX, 1.0, Color.RED)
		== PlaygroundIcons.generated(PlaygroundIcons.Glyph.BOX, 1.0, Color.RED),
		"an icon drawn twice is one texture"
	)

	# Clicking spawns. The menu never spawns anything itself — it emits, and the
	# client asks the server — which is what lets this file work unchanged when the
	# spawn becomes a dot-net message.
	var chosen: Array[StringName] = []
	_sm_menu.prop_chosen.connect(
		func(id: StringName) -> void: chosen.append(id)
	)

	_sm_menu.card_for(&"barrel").pressed.emit()

	_check(chosen.size() == 1 and chosen[0] == &"barrel",
		"clicking a prop asks for that prop")
	_check(_sm_menu.selected == &"barrel", "and arms it for the spawn key")

	# Search reaches across every category on the tab, because a player who types
	# "barrel" wants the barrel and not "no such prop, you are on the Toys tab".
	_sm_menu._on_search_changed("boulder")
	await get_tree().process_frame

	var found := _sm_menu.shown()
	_check(found.has(&"boulder"), "searching finds a prop by name")
	_check(found.size() < _sm_props_shown.size(), "and narrows the grid")

	_sm_menu._on_search_changed("zzzz")
	await get_tree().process_frame

func _test_spawn_menu_4() -> void:

	_check(
		_sm_menu.shown().is_empty(),
		"a search that matches nothing shows nothing"
	)

	_sm_menu._on_search_changed("")
	await get_tree().process_frame

	# --- Entities tab --------------------------------------------------------

	_sm_menu.show_tab(PlaygroundSpawnMenu.Tab.ENTITIES)
	await get_tree().process_frame

	var entities_shown := _sm_menu.shown()

	_check(not entities_shown.is_empty(), "the entities tab has entities on it")
	_check(
		entities_shown.has(&"npc_wanderer") and not entities_shown.has(&"crate"),
		"and no props"
	)

	# --- Weapons tab ---------------------------------------------------------

	_sm_menu.show_tab(PlaygroundSpawnMenu.Tab.WEAPONS)
	await get_tree().process_frame

	var weapons_shown := _sm_menu.shown()

	_check(
		weapons_shown.size() == playground.weapons.size(),
		"the weapons tab shows every weapon",
		"%d of %d" % [weapons_shown.size(), playground.weapons.size()]
	)

	var equipped: Array[StringName] = []
	_sm_menu.weapon_chosen.connect(
		func(id: StringName) -> void: equipped.append(id)
	)

	_sm_menu.card_for(&"launcher").pressed.emit()

	_check(
		equipped.size() == 1 and equipped[0] == &"launcher",
		"and clicking one asks to equip it rather than to spawn it"
	)

	# Switching tabs clears the filter. Carrying "containers" onto the weapons tab
	# would show nothing and read as the tab being broken.
	_sm_menu.show_tab(PlaygroundSpawnMenu.Tab.PROPS)
	await get_tree().process_frame

	_check(
		_sm_menu.shown().size() == _sm_prop_count,
		"and going back to props shows all of them again"
	)

	# The Builds tab asks the server when it opens, and a click asks for that build.
	var opened := [0]
	_sm_picked = []
	_sm_menu.builds_opened.connect(func() -> void: opened[0] += 1)
	_sm_menu.build_chosen.connect(func(build_name: String) -> void: _sm_picked.append(build_name))
	_sm_menu.show_tab(PlaygroundSpawnMenu.Tab.BUILDS)
	await get_tree().process_frame
	_check(opened[0] == 1 and _sm_menu.shown().is_empty(), "the Builds tab asks for the player's builds, and shows none until they come")
	_sm_menu.set_builds([{"name": "bridge", "props": 6, "custom": false}, {"name": "car", "props": 9, "custom": true}])
	await get_tree().process_frame
	_check(str(_sm_menu.shown()) == str([&"bridge", &"car"]), "then shows each one", str(_sm_menu.shown()))

func _test_spawn_menu_5() -> void:
	_sm_menu.card_for(&"car").pressed.emit()
	_check(str(_sm_picked) == str(["car"]), "and clicking one asks for it by name")
	_check(_sm_menu._categories_for_tab() == PackedStringArray(["builds", "custom props"]),
		"with a welded build filed as a custom prop")
	_sm_menu.show_tab(PlaygroundSpawnMenu.Tab.PROPS)
	await get_tree().process_frame

	_check(
		PlaygroundSpawnMenu.name_of_tool(&"phys") == "physics gun"
		and PlaygroundSpawnMenu.name_of_tool(&"") == "nothing",
		"a tool id has a name, and an empty one is not silently a gravity gun"
	)

	var popped := _sm_stack.pop(_sm_menu.screen_id())
	_check(popped.ok and not _sm_stack.any_open(), "the menu closes")

	_sm_stack.queue_free()
	_done()


# --- The sandbox, and the course in the corner of it ------------------------

## A car spawned from the prop catalogue, driven, ridden in and got out of.
##
## [b]The whole point of this test is that a vehicle here is BOTH things at once.[/b]
## dot-vehicle's own 122 checks drive real bodies through real physics, and every one of
## them spawns through [method DotVehicleSpawner.spawn] into a world with nothing else in
## it. What has never run anywhere is a vehicle that is also a [DotPropInstance] — on a
## prop budget, on an undo stack, adopted rather than spawned, with its wheels built by
## the game after the body was created by somebody else.
var _v_driver: PlaygroundPlayer
var _v_at: Vector3
var _v_spawned: DotPropInstance
var _v_vehicle: DotVehicleInstance
var _v_forward: DotFpsCommand
var _v_passenger: PlaygroundPlayer

func _test_vehicles() -> void:
	_section("vehicles")

	var changed: DotResult = await playground.change_map(&"pg_flatgrass")
	_check(changed.ok, "the sandbox loads")

	# The sandbox test above lets its player leave, so this one brings the bot back.
	_v_driver = playground.add_player(&"bot", "Bot")
	playground.props.limits.spawn_interval = 0.0

	# The corner of the plate opposite the jump course and the tower, which is the one
	# part of this map that is flat and empty for sixty metres in every direction. A car
	# is not a player: it covers the width of the sandbox in a few seconds, and the first
	# version of this test drove into the scenery and measured a stationary car.
	_v_at = Vector3(-60.0, 1.2, -60.0)
	_v_driver.teleport(_v_at + Vector3(2.5, 0.0, 0.0), 0.0)

	_v_spawned = playground.props.spawn(&"buggy", &"bot", _v_at)

	_check(_v_spawned != null, "a buggy spawns out of the PROP catalogue")

	if _v_spawned == null:
		return

	_check(
		PlaygroundSpawnables.kind_of(_v_spawned.def) == PlaygroundSpawnables.Kind.VEHICLE,
		"and the catalogue says it is a vehicle"
	)

	_v_vehicle = playground.vehicles.vehicle_for_node(_v_spawned.node)

	_check(_v_vehicle != null, "and it was adopted by the vehicle spawner")

	if _v_vehicle == null:
		return

	_check(_v_vehicle.chassis is DotVehicleWheeled, "with Godot's raycast wheels under it")

	var body := _v_spawned.node as PlaygroundVehicle
	_check(body != null and body.wheel_count() == 4, "and four wheels actually built")
	_check(
		body != null and is_equal_approx(body.mass, _v_vehicle.def.tuning().mass),
		"and one mass, read off the tunables by both catalogues",
		"%.1f vs %.1f" % [
			body.mass if body != null else -1.0, _v_vehicle.def.tuning().mass
		]
	)

	# Let it settle onto its suspension before anything is measured. A raycast vehicle
	# spawned in the air is falling, and a "did it drive forward" measured through the
	# drop is measuring the drop.
	for _i in range(40):
		await get_tree().physics_frame

	_check(
		playground.use_vehicle(&"bot").ok,
		"the bot standing beside it gets in"
	)
	_check(_v_driver.riding, "and stops being a player who walks")
	_check(_v_vehicle.driver() == &"bot", "in the driving seat")
	_check(
		_v_driver.get_parent() != playground and _v_driver.is_inside_tree(),
		"with the rider's node carried by the vehicle",
		"which is what puts a rider's camera on it without a line about cameras"
	)

	# Forward. `move.y` is forward for a walking player and it is forward here.
	_v_forward = DotFpsCommand.new()
	_v_forward.move = Vector2(0.0, 1.0)
	await _test_vehicles_2()
	await _test_vehicles_3()
	await _test_vehicles_4()

func _test_vehicles_2() -> void:

	var before := _v_vehicle.position()
	await _drive(&"bot", _v_forward, 200)

	var travelled := _v_vehicle.position() - before

	_check(travelled.length() > 4.0, "it drives", "%.2f m" % travelled.length())
	_check(
		_v_vehicle.forward_speed() > 0.5,
		"FORWARDS, which is the one dot-vehicle says a car gets wrong",
		"%.2f m/s along its own -Z" % _v_vehicle.forward_speed()
	)
	_check(
		_v_driver.controller.state.position.distance_to(_v_vehicle.position()) < 4.0,
		"and the driver's replicated position went with it",
		"a passenger drawn where they got in is invisible in one process"
	)

	# Steering. Both directions, because a check that only measured "it turned" would
	# pass for a car that turns the wrong way — which is exactly the bug dot-vehicle
	# found in itself.
	var right := DotFpsCommand.new()
	right.move = Vector2(1.0, 1.0)

	var heading_before := -(_v_vehicle.node as Node3D).global_basis.z
	await _drive(&"bot", right, 160)
	var heading_after := -(_v_vehicle.node as Node3D).global_basis.z

	# Positive Y in a cross product of before × after means the turn was to the LEFT in
	# Godot's left-handed-looking convention, so a right turn is negative.
	var turn := heading_before.cross(heading_after).y

	_check(turn < -0.05, "steering right turns it right", "cross.y = %.3f" % turn)

	# A passenger, which is the case that only breaks with two people in it.
	_v_passenger = playground.add_player(&"rider", "Rider")
	_v_passenger.teleport(_v_vehicle.position() + Vector3(0.0, 0.0, 4.0))

	_check(
		playground.vehicles.ride.enter(_v_vehicle, &"rider", _v_passenger).ok,
		"a second player gets in as a passenger"
	)
	_check(_v_vehicle.occupant_count() == 2, "and the car has two people in it")
	_check(_v_vehicle.driver() == &"bot", "with the driver unchanged")

	var passenger_before := _v_passenger.controller.state.position
	await _drive(&"bot", _v_forward, 120)

	_check(
		_v_passenger.controller.state.position.distance_to(passenger_before) > 1.0,
		"the passenger is carried too",
		"%.2f m" % _v_passenger.controller.state.position.distance_to(passenger_before)
	)

	# Getting out, which is the half dot-vehicle says the bugs are in.
	#
	# Asserted on the SPEED first. A refusal test run against a car that happens to be
	# stationary passes without testing anything, which is how the first version of this
	# read: "not ok, or slow enough" is true for a car nobody managed to move.
	# Put back on a clean patch and pointed down the plate before anything about SPEED is
	# measured. Not tidiness: everything up to here has been steering it, and a test that
	# measures a speed at the end of a drive it did not control is a test that measures
	# whatever it happened to hit.
	(_v_vehicle.node as Node3D).global_transform = Transform3D(Basis.IDENTITY, _v_at)
	_v_vehicle.body().linear_velocity = Vector3.ZERO
	_v_vehicle.body().angular_velocity = Vector3.ZERO

func _test_vehicles_3() -> void:

	for _i in range(30):
		await get_tree().physics_frame

	await _drive(&"bot", _v_forward, 220)

	_check(
		_v_vehicle.speed() > _v_vehicle.def.tuning().max_exit_speed,
		"the car is going fast enough for the exit rule to have something to say",
		"%.2f m/s vs %.1f" % [_v_vehicle.speed(), _v_vehicle.def.tuning().max_exit_speed]
	)

	var moving := playground.vehicles.ride.exit(_v_vehicle, &"rider")
	_check(
		not moving.ok,
		"and getting out at that speed is refused",
		"speed %.1f, limit %.1f" % [_v_vehicle.speed(), _v_vehicle.def.tuning().max_exit_speed]
	)

	var stop := DotFpsCommand.new()
	stop.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	await _drive(&"bot", stop, 200)

	_check(_v_vehicle.speed() < 2.0, "the brake stops it", "%.2f m/s" % _v_vehicle.speed())

	var out := playground.vehicles.ride.exit(_v_vehicle, &"rider")
	_check(out.ok, "and then the passenger can get out", str(out.error) if not out.ok else "")
	_check(not _v_passenger.riding, "and is walking again")
	_check(
		_v_passenger.global_position.distance_to(_v_vehicle.position()) > 0.9,
		"put down beside the car rather than inside it",
		"%.2f m" % _v_passenger.global_position.distance_to(_v_vehicle.position())
	)
	_check(
		_v_passenger.get_parent() == playground,
		"and handed back to whoever had them before"
	)

	# How far it takes to stop, which "the brake stops it" never said. dot-vehicle handed
	# Godot's wheels the brake in newtons where Godot reads an impulse per physics step, so
	# the buggy stopped from 50 km/h within a couple of metres on either brake, at this
	# project's 128 ticks as at 60. Since dot-vehicle 4f4afaf they are forces.
	var foot := await _stopping(_v_vehicle, _v_at, &"bot", DotFpsCommand.BUTTON_CROUCH)
	var hand := await _stopping(_v_vehicle, _v_at, &"bot", DotFpsCommand.BUTTON_JUMP)
	print("  ..    the buggy from 50 km/h: brake (crouch) %.2f m, handbrake (jump) %.2f m" % [foot, hand])
	_check(foot > 7.0 and foot < 14.0, "the brake stops the buggy from 50 km/h in metres, not on the spot",
		"%.2f m" % foot)
	_check(hand > 6.8 and hand < 16.0, "and so does the handbrake", "%.2f m" % hand)
	# S: the brake while the buggy still rolls forward, reverse once it has stopped
	# (dot-vehicle's `brake_then_reverse`). On reverse thrust alone it was the engine's 35 %
	# against a brake several times that.
	var back := await _stopping(_v_vehicle, _v_at, &"bot", BACK_KEY)
	var reverse := DotFpsCommand.new()
	reverse.move = Vector2(0.0, -1.0)
	var stopped_at := _v_vehicle.position()
	await _drive(&"bot", reverse, 192)
	var heading := -(_v_vehicle.node as Node3D).global_transform.basis.z
	var backed := -(_v_vehicle.position() - stopped_at).dot(heading)
	print("  ..    the buggy from 50 km/h on S: %.2f m to a stop, then %.2f m back at %.2f m/s after 1.5 s more" % [back, backed, _v_vehicle.forward_speed()])
	_check(back < foot + 1.5, "S stops the buggy like the brake while it rolls forward, not on reverse thrust",
		"%.2f m against the brake's %.2f m" % [back, foot])
	_check(_v_vehicle.forward_speed() < -1.0 and backed > 1.0, "and once it has stopped, S held reverses it",
		"%.2f m/s, %.2f m back" % [_v_vehicle.forward_speed(), backed])
	# Stood still again, or it rolls away from the passenger put down beside it below.
	await _drive(&"bot", stop, 128)
	# Back beside the car, which those runs drove 60 m from where the passenger got out.
	_v_passenger.teleport(_v_vehicle.position() + Vector3(2.5, 0.0, 0.0))

func _test_vehicles_4() -> void:

	# The hovercraft, which is the only thing proving the chassis is a subclass point
	# rather than a promise.
	var skiff_prop := playground.props.spawn(&"skiff", &"bot", Vector3(-24.0, 1.5, 24.0))
	_check(skiff_prop != null, "a skiff spawns")

	if skiff_prop != null:
		var skiff := playground.vehicles.vehicle_for_node(skiff_prop.node)
		_check(skiff != null and skiff.chassis is DotVehicleHover, "on the hover chassis")
		_check(
			(skiff_prop.node as PlaygroundVehicle).wheel_count() == 0,
			"with no wheels built for it"
		)

		for _i in range(120):
			await get_tree().physics_frame

		_check(
			skiff != null and skiff.position().y > 0.55,
			"and it is still off the ground a second later",
			# Above its own half-height plus a margin: a skiff whose hover did nothing
			# would come to rest with its box on the floor at exactly 0.35.
			"y = %.2f" % (skiff.position().y if skiff != null else -1.0)
		)

	# Deleting the car with somebody in it. A rider left inside a freed vehicle is a
	# player parented to nothing: invisible, unkillable, and unable to enter anything
	# else for the rest of the round, with no error anywhere.
	_check(playground.use_vehicle(&"rider").ok, "the passenger gets back in")

	playground.props.remove(_v_spawned.instance_id, DotPropSpawner.REASON_ADMIN)
	await get_tree().physics_frame

	_check(
		not playground.vehicles.ride.is_riding(&"rider")
		and not playground.vehicles.ride.is_riding(&"bot"),
		"removing the PROP evacuates everybody in the vehicle"
	)
	_check(not _v_driver.riding, "and the driver is a walking player again")
	_check(
		playground.vehicles.world_count() == 1,
		"and the vehicle spawner has let go of it, leaving only the skiff",
		"%d left" % playground.vehicles.world_count()
	)

	playground.remove_player(&"rider")
	_done()


## Metres [param vehicle] takes from 50 km/h to a standstill, put back at [param at] facing
## +Z first, with [param button] held by [param id] (crouch the brake, jump the handbrake,
## [constant BACK_KEY] for S, which stops at the moment it stops rolling forward).
func _stopping(vehicle: DotVehicleInstance, at: Vector3, id: StringName, button: int) -> float:
	# Facing +Z, into the plate: -Z from here meets the plate's edge at about z = -72, which
	# a buggy reaching 50 km/h gets to first.
	(vehicle.node as Node3D).global_transform = Transform3D(Basis(Vector3.UP, PI), at)
	vehicle.body().linear_velocity = Vector3.ZERO
	vehicle.body().angular_velocity = Vector3.ZERO
	for _i in range(30):
		await get_tree().physics_frame

	var player: PlaygroundPlayer = playground.players[id]
	var go := DotFpsCommand.new()
	go.move = Vector2(0.0, 1.0)
	var guard := 1200
	while vehicle.forward_speed() < 13.89 and guard > 0:
		player.controller.apply_command(go.duplicate_command())
		await get_tree().physics_frame
		guard -= 1

	print("  ..    %s: %.1f m/s after %d ticks of throttle" % [{DotFpsCommand.BUTTON_CROUCH: "brake", BACK_KEY: "S"}.get(button, "handbrake"), vehicle.forward_speed(), 1200 - guard])
	var start := vehicle.position()
	var stop := DotFpsCommand.new()
	if button == BACK_KEY:
		stop.move = Vector2(0.0, -1.0)
	else:
		stop.set_button(button, true)
	guard = 1200
	while (vehicle.forward_speed() > 0.0 if button == BACK_KEY else vehicle.speed() > 0.3) and guard > 0:
		player.controller.apply_command(stop.duplicate_command())
		await get_tree().physics_frame
		guard -= 1

	var end := vehicle.position()
	return Vector2(end.x - start.x, end.z - start.z).length()


# --- The jump course -------------------------------------------------------

## Every hand-built map, swept for closed slots, standable ground no spawn reaches, and
## ground a spawn reaches that leads nowhere (`[gate-sweep-2]`). `pg_generated` is not in
## it: it is not hand-built, and `PlaygroundWorldGen`'s own validator floods it from its
## spawn on every seed.
##
## [b]The survey is asked about a fixture first, so a sweep that finds nothing is known to
## be looking.[/b] Three maps passing clean says nothing about a detector that cannot fire;
## the fixture has one of each thing it looks for, and each is asserted found.
var _tmas_data_script: GDScript

func _test_the_maps_are_surveyed() -> void:
	print("")
	_section("the hand-built maps, surveyed for slots, unreached ground and traps")

	_the_survey_sees_what_it_looks_for()

	for id in _built_map_ids():
		var script := load("res://maps/%s.gd" % id) as GDScript
		var map: Node3D = script.new()
		map._build()

		# The map brings its light with it (`PlaygroundGeometry.light`): exactly one sun and
		# one environment, or the second is silently ignored by the renderer. dot-lighting's
		# shadowless `Fill` (painted()) is not a second sun.
		var suns := map.get_children().filter(func(n: Node) -> bool: return n is DirectionalLight3D and n.name != "Fill").size()
		var skies := map.get_children().filter(func(n: Node) -> bool: return n is WorldEnvironment).size()
		_check(suns == 1 and skies == 1, "%s: carries one sun and one sky (its dot-lighting document)" % id,
			"%d suns, %d environments" % [suns, skies])

		# A hand-built map here declares no zones (a run timer's, when a server has one,
		# come from the map document or zone file), so its ways out are its walls and
		# floor alone.
		var spawns: Array[Vector3] = [map.fallback_spawn]

		var declared: Array = map.survey_declared()
		var started := Time.get_ticks_msec()
		var found: Dictionary = PlaygroundMapSurvey.survey(map, [], spawns, declared)
		map.free()

		print("    %s: %d standable cells in %d regions, %d spawns, %d declared, %d falls into nothing, %d ms" % [
			id, int(found["cells"]), int(found["regions"]), spawns.size(), declared.size(),
			int(found["void_falls"]), Time.get_ticks_msec() - started,
		])

		_check((found["spawnless"] as Array).is_empty(),
			"%s: every spawn stands on standable ground" % id,
			", ".join(found["spawnless"]))
		_check((found["slots"] as Array).is_empty(),
			"%s: no two boxes leave a slot narrower than a player" % id,
			"; ".join(found["slots"]))
		_check((found["unreached"] as Array).is_empty(),
			"%s: nothing standable is out of reach of every spawn, but what it declares" % id,
			"; ".join(found["unreached"]))
		_check((found["trapped"] as Array).is_empty(),
			"%s: and nowhere a spawn reaches is a place with no way out" % id,
			"; ".join(found["trapped"]))

	# The custom maps game-playground-maps delivers, linked in as `maps/custom`. Named rather
	# than listed off the directory, so a checkout without the link fails here instead of
	# surveying nothing and passing.
	_tmas_data_script = load("res://maps/pg_data.gd") as GDScript
	_test_the_maps_are_surveyed_2()

func _test_the_maps_are_surveyed_2() -> void:
	for id in CUSTOM_MAPS:
		var path := "res://maps/custom/%s.json" % id
		var map: Node3D = _tmas_data_script.new()
		var configured: DotResult = map.configure_doc(path)
		_check(configured.ok, "%s: the document loads" % id, str(configured.error) if not configured.ok else "")
		var spawns: Array[Vector3] = [map.fallback_spawn]
		var declared: Array = map.survey_declared()
		var started := Time.get_ticks_msec()
		var found: Dictionary = PlaygroundMapSurvey.survey(map, [], spawns, declared)
		map.free()
		print("    %s: %d standable cells in %d regions, %d declared, %d falls into nothing, %d ms" % [
			id, int(found["cells"]), int(found["regions"]), declared.size(),
			int(found["void_falls"]), Time.get_ticks_msec() - started,
		])
		_check((found["spawnless"] as Array).is_empty(), "%s: the spawn stands on standable ground" % id,
			", ".join(found["spawnless"]))
		_check((found["slots"] as Array).is_empty(), "%s: no slot narrower than a player" % id,
			"; ".join(found["slots"]))
		_check((found["unreached"] as Array).is_empty(), "%s: nothing standable out of reach, but what it declares" % id,
			"; ".join(found["unreached"]))
		_check((found["trapped"] as Array).is_empty(), "%s: and no place with no way out" % id,
			"; ".join(found["trapped"]))

	_done()


# --- The collision audit ---------------------------------------------------------

## A floor with one of everything on it: a 0.5 m slot between two walls, a platform 5 m
## up, and a cellar a player drops into and cannot climb out of.
func _the_survey_sees_what_it_looks_for() -> void:
	var boxes: Array = [
		PlaygroundMapSurvey.solid(Vector3(0.0, -0.5, 0.0), Vector3(20.0, 1.0, 20.0)),
		# The slot: two walls 0.5 m apart.
		PlaygroundMapSurvey.solid(Vector3(-5.0, 1.5, -6.0), Vector3(2.0, 3.0, 1.0)),
		PlaygroundMapSurvey.solid(Vector3(-2.5, 1.5, -6.0), Vector3(2.0, 3.0, 1.0)),
		# Out of reach: 5 m up, 4 m across, nothing to climb.
		PlaygroundMapSurvey.solid(Vector3(-6.0, 5.0, 6.0), Vector3(4.0, 0.5, 4.0)),
		# The cellar: 3 m under the floor's east edge, walled in on its other three sides.
		PlaygroundMapSurvey.solid(Vector3(13.0, -3.5, 0.0), Vector3(6.0, 1.0, 6.0)),
		PlaygroundMapSurvey.solid(Vector3(16.5, 0.0, 0.0), Vector3(1.0, 8.0, 8.0)),
		PlaygroundMapSurvey.solid(Vector3(13.0, 0.0, 3.5), Vector3(6.0, 8.0, 1.0)),
		PlaygroundMapSurvey.solid(Vector3(13.0, 0.0, -3.5), Vector3(6.0, 8.0, 1.0)),
	]
	var solids: Array[PlaygroundMapSurvey.Solid] = []
	for box: Variant in boxes:
		solids.append(box)

	# The walls' own tops are out of reach too, which is right and is not what this asks
	# about, so the fixture declares them the way a map declares its walls.
	var walls: Array = []
	for i in [1, 2, 5, 6, 7]:
		var wall: PlaygroundMapSurvey.Solid = solids[i]
		walls.append({"box": wall.bounds.grow(0.1), "why": "a fixture wall's top"})

	var spawns: Array[Vector3] = [Vector3(0.0, 1.0, 0.0)]
	var found: Dictionary = PlaygroundMapSurvey.survey_solids(solids, [], spawns, walls)

	_check((found["slots"] as Array).size() == 1,
		"the survey finds the fixture's one slot", "; ".join(found["slots"]))
	_check((found["unreached"] as Array).size() == 1
			and str((found["unreached"] as Array)[0]).contains(", 5.2, "),
		"and the platform nobody can reach", "; ".join(found["unreached"]))
	_check((found["trapped"] as Array).size() == 1
			and str((found["trapped"] as Array)[0]).contains("-3.0"),
		"and the cellar nobody can leave", "; ".join(found["trapped"]))

	# Declared, the platform is not reported; a reset in the cellar is a way out of it.
	var declared: Array = walls.duplicate()
	declared.append({"box": AABB(Vector3(-8.0, 4.0, 4.0), Vector3(4.0, 2.0, 4.0)), "why": "fixture"})
	# A way out as `PlaygroundMapSurvey.ways_out_of` reads one off a timer's RESPAWN zone.
	var reset: Array = [{"box": AABB(Vector3(10.0, -3.5, -3.0), Vector3(6.0, 3.5, 6.0)), "pit": true}]
	var quiet: Dictionary = PlaygroundMapSurvey.survey_solids(solids, reset, spawns, declared)

	_check((quiet["unreached"] as Array).is_empty() and (quiet["trapped"] as Array).is_empty(),
		"and neither once the platform is declared and the cellar has a reset",
		"unreached %s; trapped %s" % [str(quiet["unreached"]), str(quiet["trapped"])])
