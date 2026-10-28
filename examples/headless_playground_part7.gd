extends "res://examples/headless_playground_part6.gd"

## dot-core's [DotCollisionAudit] over every map as built: visible geometry with no shape
## under it, which a player walks through. The strict pass: every mesh sits on its own body here, and the lenient one
## would let a stray shape nearby cover a missing one. What is passable on purpose (liquids, foliage, panes, trigger
## visuals) carries `dot_no_collision` where the map builds it, with the reason there; a map
## fails on any finding left. Props are dot-props bodies and map toys are built under the
## playground, so neither is in a map node. The audit is structural and needs no tree.
func _test_nothing_drawn_is_walked_through() -> void:
	print("")
	_section("every map's drawn geometry has collision or says it is passable")

	var cases: Array = []
	for id in _built_map_ids():
		cases.append([id, "res://maps/%s.gd" % id, ""])
	cases.append(["pg_generated", "res://maps/pg_generated.gd", "generated"])
	for id in CUSTOM_MAPS:
		cases.append([id, "res://maps/pg_data.gd", "res://maps/custom/%s.json" % id])

	for case: Array in cases:
		var map: Node3D = (load(case[1]) as GDScript).new()
		if case[2] == "generated":
			map.configure(1)
		elif case[2] != "":
			map.configure_doc(case[2])
		else:
			map._build()

		var res := DotCollisionAudit.audit(map)
		var found := 0
		if res.ok:
			var report: DotCollisionAudit = res.value
			found = report.count()
			print("    %s: %d findings of %d examined, %d opted out" % [case[0], found, report.examined, report.opted_out])
			for line in report.describe_lines().slice(1, 12):
				print("      %s" % line)
		_check(res.ok and found == 0 and (res.value as DotCollisionAudit).examined > 0,
			"%s: nothing drawn is walked through" % case[0],
			"" if res.ok else res.error.message)
		map.free()

	_done()


## A map document's `props` and `wires` (2026-10-07): put down by the server on load, owned
## by the map, furniture frozen and loose things loose, and the wires live.
func _test_a_maps_own_props() -> void:
	_section("a map's own props")

	var changed: DotResult = await playground.change_map(&"pgc_town")
	if not changed.ok:
		_check(false, "pgc_town loads", changed.error.message)
		_done()
		return
	await get_tree().physics_frame

	var mine := playground.props.props_of(playground.MAP_OWNER)
	var count := {}
	for p: DotPropInstance in mine:
		count[p.def.id] = int(count.get(p.def.id, 0)) + 1
	_check(int(count.get(&"door", 0)) == 5 and int(count.get(&"button", 0)) == 10 and int(count.get(&"buggy", 0)) == 2,
		"the map puts down its doors, buttons and cars", str(count))
	var doors := mine.filter(func(p: DotPropInstance) -> bool: return p.def.id == &"door")
	var crates := mine.filter(func(p: DotPropInstance) -> bool: return p.def.id == &"crate")
	_check(doors.all(func(p: DotPropInstance) -> bool: return p.frozen) and crates.all(func(p: DotPropInstance) -> bool: return not p.frozen),
		"furniture frozen, and the crates loose")

	# The first house's outside button opens its door, through the wire the document names.
	var buttons := mine.filter(func(p: DotPropInstance) -> bool: return p.def.id == &"button")
	var door: DotPropInstance = doors[0] if not doors.is_empty() else null
	var button: DotPropInstance = buttons[0] if not buttons.is_empty() else null
	if button != null:
		var _pressed: Variant = playground.io.fire(button.instance_id, &"pressed")
	for i in int(playground.DOOR_SECONDS * playground.tick_rate) + 16:
		await get_tree().physics_frame
	_check(door != null and playground.door_is_open(door.instance_id), "and a button opens the door it is wired to")
	var turned := rad_to_deg((door.node as Node3D).global_basis.x.angle_to(Vector3.RIGHT)) if door != null else 0.0
	_check(absf(turned - 90.0) < 3.0, "swinging a quarter turn from where the map stood it", "%.1f degrees" % turned)

	# A document that names a prop this server lacks still loads, without it.
	var entries := [{"id": "crate", "at": [0, 5, 0]}, {"id": "no_such_prop", "at": [2, 5, 0]}]
	var placed := playground.spawn_map_props(entries, [])
	_check(placed == 1, "and a prop the catalogue lacks is left out, not the map", "%d placed" % placed)

	var back: DotResult = await playground.change_map(&"pg_flatgrass")
	_check(back.ok and playground.props.props_of(playground.MAP_OWNER).is_empty(), "a map change takes its props with it")
	_done()


# --- Toys ------------------------------------------------------------------------

func _toy_index(id: String) -> int:
	if playground.toys == null:
		return -1
	for t in playground.toys.toys:
		if String(t.def["id"]) == id:
			return t.index
	return -1


## dot-props' toys on the sandbox, through the game's own paths: a walk pushes a ball, a shot
## from the hit scan sends one off, the use key kicks, a trampoline throws a player, the
## roundabout carries one standing on it, a grenade's blast throws a barrel, sv_toys 0 takes
## them away and a map change takes them with it.
func _test_toys() -> void:
	_section("the sandbox's toys")

	var on_lobby: DotResult = await playground.change_map(&"pg_flatgrass")
	if not on_lobby.ok or playground.toys == null:
		_check(false, "the sandbox loads with its toys", on_lobby.error.message if not on_lobby.ok else "no box")
		_done()
		return
	var box := playground.toys
	var lobby := playground.current_map_node()
	_check(box.count() == (lobby.call("map_toys") as Array).size() and box.count() >= 25 and box.missing.is_empty(),
		"the lobby builds every toy it lists", "%d toys" % box.count())

	var player := playground.add_player(&"toyer", "Toyer")
	await get_tree().physics_frame

	# Walked into: the beach ball goes on ahead of the player.
	var ball := box.toy(_toy_index("beach_ball"))
	var b0 := ball.body.global_position
	player.teleport(Vector3(b0.x - 1.2, 0.05, b0.z), -90.0)
	await get_tree().physics_frame
	for _i in range(16):
		player.controller.state.velocity = Vector3(6.0, 0.0, 0.0)
		await get_tree().physics_frame
	for _i in range(30):
		await get_tree().physics_frame
	_check(ball.body.global_position.x > b0.x + 0.5, "a player walking into the beach ball sends it on ahead",
		"moved %.2f m" % (ball.body.global_position.x - b0.x))

	# Shot through the game's own hit scan (player_shots_fired → PlaygroundZee.trace_outcome):
	# the second ball flies off, and nobody's prop shove sent it at forty metres a second.
	var other := box.toy(_toy_index("beach_ball") + 1)
	var o0 := other.body.global_position
	player.teleport(o0 + Vector3(0, 0, 5.0), 0.0)
	await get_tree().physics_frame
	var outcome := DotWeaponOutcome.new()
	outcome.used = true
	var shot := DotShot.new()
	shot.origin = o0 + Vector3(0, 0.1, 4.0)
	shot.direction = Vector3(0, 0, -1)
	shot.damage = 25.0
	shot.max_range = 50.0
	outcome.shots.append(shot)
	playground.player_shots_fired(&"toyer", outcome)
	var fastest := other.body.linear_velocity.length()
	for _i in range(20):
		await get_tree().physics_frame
		fastest = maxf(fastest, other.body.linear_velocity.length())
	_check(other.body.global_position.z < o0.z - 0.5 and fastest < 12.0, "a shot beach ball bounces away along the shot, at a ball's speed",
		"moved %.2f m, at most %.1f m/s" % [o0.z - other.body.global_position.z, fastest])

	# The use key on the football (the game's F, `use_prop`): kicked along the look.
	var football := box.toy(_toy_index("football"))
	var f0 := football.body.global_position
	player.teleport(f0 + Vector3(0, 0.05, 1.3), 0.0)
	# Down at the ball at the feet: the sign of pitch read off the aim, as the lever's is.
	await _look(&"toyer", 45.0, 4)
	var at_ball := rad_to_deg(atan2(player.eye_position().y - f0.y, player.eye_position().z - f0.z))
	await _look(&"toyer", -at_ball if player.aim_direction().y > 0.0 else at_ball, 4)
	var aimed := playground.toy_aimed(player)
	var used := playground.use_prop(&"toyer")
	for _i in range(20):
		await get_tree().physics_frame
	_check(aimed == football.index and used.ok and football.body.global_position.z < f0.z - 1.0,
		"the use key kicks the football the player looks at", "aimed %d, moved %.2f m; eye %s aim %s ball %s" % [aimed, f0.z - football.body.global_position.z, player.eye_position(), player.aim_direction(), f0])

	# A trampoline under a falling player throws them back up.
	var tramp := box.toy(_toy_index("trampoline"))
	player.teleport(tramp.global_position + Vector3(0.2, 1.4, 0.0), 0.0)
	var top := 0.0
	var bounced_before := tramp.count
	for _i in range(90):
		await get_tree().physics_frame
		top = maxf(top, player.controller.state.position.y - tramp.global_position.y)
	_check(top > 2.0 and tramp.count != bounced_before, "landing on the trampoline throws a player up, and counts the bounce",
		"%.2f m above it, count %d" % [top, tramp.count])

	# Somebody standing on the turning roundabout goes round with it.
	var spinner := box.toy(_toy_index("merry_go_round"))
	var hub := spinner.body.global_position
	var _spun := box.use(spinner.index, hub + Vector3(1.6, 1.0, 0), Vector3(0, 0, 1))
	player.teleport(hub + Vector3(1.0, 0.1, 0.0), 0.0)
	for _i in range(6):
		await get_tree().physics_frame
	var start := player.controller.state.position - hub
	var start_angle := atan2(start.z, start.x)
	for _i in range(40):
		await get_tree().physics_frame
	var now := player.controller.state.position - hub
	var turned := absf(wrapf(atan2(now.z, now.x) - start_angle, -PI, PI))
	var out := Vector2(now.x, now.z).length()
	_check(turned > 0.3 and absf(out - Vector2(start.x, start.z).length()) < 0.3 and player.controller.state.is_grounded(),
		"a player standing on the turning roundabout is carried round with it, still on the deck",
		"turned %.2f rad, %.2f m out" % [turned, out])

	# A grenade's blast (through the projectiles' own detonation, which hands toys to the box).
	var barrel := box.toy(_toy_index("barrel"))
	var r0 := barrel.body.global_position
	var thrown := playground.blast_toys(r0 + Vector3(-1.5, 0.2, 0.0), 5.0)
	for _i in range(20):
		await get_tree().physics_frame
	_check(thrown >= 1 and barrel.body.global_position.distance_to(r0) > 0.2, "a blast throws the barrels beside it",
		"%d thrown, %.2f m" % [thrown, barrel.body.global_position.distance_to(r0)])

	# sv_toys 0: nothing to hit, kick or stand on; 1 brings them back.
	var _off := playground.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "0")
	await get_tree().physics_frame
	var hidden := not ball.visible and playground.toy_aimed(player) == -1
	var _on := playground.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "1")
	_check(hidden and ball.visible, "sv_toys 0 takes the toys away and 1 puts them back")

	playground.remove_player(&"toyer")
	var away: DotResult = await playground.change_map(&"pg_generated")
	await get_tree().process_frame
	_check(away.ok and playground.toys != null and playground.toys.count() == 0 and not is_instance_valid(ball),
		"a map with no toys has none, and the lobby's went with it",
		"%s, %s, ball %s" % [str(away.ok), str(playground.toys.describe()) if playground.toys != null else "no box", str(is_instance_valid(ball))])
	var _back: DotResult = await playground.change_map(&"pg_flatgrass")
	_done()


## Every map with toys, built: each toy one dot-props has, none inside the map's geometry or
## another toy's footprint, and two seconds of physics later every loose one still where the
## map put it (not through a floor, not flung off an overlap the solver pushed apart).
func _test_every_maps_toys_stand_clear() -> void:
	_section("every map's toys stand clear")
	var ids: Array[StringName] = []
	for def: DotMapDef in playground.maps.catalogue.maps:
		ids.append(def.id)
	var with_toys := 0
	var bad: Array = []
	for id: StringName in ids:
		if String(id).begins_with("pg_generated"):
			continue
		var changed: DotResult = await playground.change_map(id)
		if not changed.ok or playground.toys == null:
			continue
		var box := playground.toys
		var listed := playground.current_map_node().call("map_toys") as Array if playground.current_map_node().has_method("map_toys") else []
		if listed.is_empty():
			continue
		with_toys += 1
		if box.count() != listed.size() or not box.missing.is_empty():
			bad.append("%s: %d of %d built, missing %s" % [id, box.count(), listed.size(), ", ".join(box.missing)])
		var own: Array[RID] = []
		for toy in box.toys:
			for part: CollisionObject3D in [toy.fixed, toy.body]:
				if part != null:
					own.append(part.get_rid())
		var layout := playground.player_stack.physics.layout
		var space := playground.get_world_3d().direct_space_state
		for toy in box.toys:
			var hit := _toy_inside(space, toy, own, layout.mask_of([&"world", &"frozen_prop", &"prop"] as Array[StringName]))
			if hit != "":
				bad.append("%s: %s %d at %s inside %s" % [id, toy.def["id"], toy.index, toy.global_position.snapped(Vector3.ONE * 0.1), hit])
		# Footprints against each other, seen from above.
		for a in box.toys:
			for b in box.toys:
				if a.index >= b.index:
					continue
				var fa := _flat(a)
				var fb := _flat(b)
				if fa.size != Vector3.ZERO and fb.size != Vector3.ZERO and fa.grow(-0.05).intersects(fb.grow(-0.05)):
					bad.append("%s: %s %d and %s %d overlap" % [id, a.def["id"], a.index, b.def["id"], b.index])
		for _i in range(240):
			await get_tree().physics_frame
		for toy in box.toys:
			if toy.body != null and toy.body.global_position.distance_to(toy.rest.origin) > 0.6:
				bad.append("%s: %s %d strayed %s to %s" % [id, toy.def["id"], toy.index, toy.rest.origin.snapped(Vector3.ONE * 0.1), toy.body.global_position.snapped(Vector3.ONE * 0.1)])
	_check(with_toys >= 1 and bad.is_empty(), "every map's toys are dot-props', stand clear and stay put",
		"%d maps with toys; %s" % [with_toys, "; ".join(bad.slice(0, 8))])
	var _back: DotResult = await playground.change_map(&"pg_flatgrass")
	_done()


## [param toy]'s footprint in world space, flattened to the floor, or empty for a loose one.
static func _flat(toy: DotPropToy) -> AABB:
	var f := toy.footprint()
	if f.size == Vector3.ZERO:
		return AABB()
	var world := toy.global_transform * f
	world.position.y = 0.0
	world.size.y = 1.0
	return world


## What [param toy]'s own shapes, lifted five centimetres off their floor, are inside of, or "".
func _toy_inside(space: PhysicsDirectSpaceState3D, toy: DotPropToy, own: Array[RID], mask: int) -> String:
	for part: CollisionObject3D in [toy.fixed, toy.body]:
		if part == null:
			continue
		for child in part.get_children():
			var shape := child as CollisionShape3D
			if shape == null or shape.shape == null:
				continue
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = shape.shape
			query.transform = shape.global_transform.translated(Vector3(0, 0.05, 0))
			query.collision_mask = mask
			query.exclude = own
			var hits := space.intersect_shape(query, 1)
			if not hits.is_empty():
				var other: Object = hits[0].get("collider")
				return str(other.name) if other is Node else "something"
	return ""


## What a map box is made of, on the real game (pgc_nature): ice keeps a player sliding,
## mud slows them, rubber throws them higher, lava sends them back to the spawn and melts a
## crate, and water is a volume with nothing to stand on. Measured, and printed.
func _test_map_materials() -> void:
	_section("map materials: ice, mud, rubber, lava, water")

	var changed: DotResult = await playground.change_map(&"pgc_nature")
	if not changed.ok:
		_check(false, "pgc_nature loads", changed.error.message)
		_done()
		return
	playground.props.limits.spawn_interval = 0.0
	var bot: PlaygroundPlayer = playground.players.get(&"bot")
	if bot == null:
		bot = playground.add_player(&"bot", "Bot")

	# --- A box knows what it is made of ------------------------------------------------
	var ice_box: StaticBody3D = null
	var stack: Array[Node] = [playground.current_map_node()]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is StaticBody3D and PlaygroundMaterials.material_of(n) == &"ice":
			ice_box = n
	_check(ice_box != null and ice_box.get_meta(&"dot_fps_surface") == &"ice"
		and ice_box.physics_material_override != null and ice_box.physics_material_override.friction < 0.1,
		"an ice box is ice to a player's feet and to the solver")
	_check(not playground.liquids.is_empty() and playground.liquids.any(func(l: Dictionary) -> bool: return l["material"] == &"water")
		and playground.liquids.any(func(l: Dictionary) -> bool: return l["material"] == &"lava"),
		"the map's water and lava are liquid volumes", str(playground.liquids.size()))

	# --- Ice keeps its speed; grass takes it off ----------------------------------------
	var grass_kept: float = await _coast(bot, Vector3(-30.0, 1.0, 15.0))
	var ice_kept: float = await _coast(bot, Vector3(-55.0, 1.0, -41.0))
	print("    speed kept after 24 ticks with no input: grass %.0f%%, ice %.0f%%" % [grass_kept * 100.0, ice_kept * 100.0])
	_check(ice_kept > 0.6 and ice_kept > grass_kept * 2.0, "a player lets go on ice and keeps sliding; on grass they stop",
		"grass %.2f, ice %.2f" % [grass_kept, ice_kept])

	# --- Mud slows a run --------------------------------------------------------------
	var grass_top: float = await _top_speed(bot, Vector3(-30.0, 1.0, 15.0))
	var mud_top: float = await _top_speed(bot, Vector3(0.0, 1.0, -2.0))
	print("    top speed: grass %.2f m/s, mud %.2f m/s" % [grass_top, mud_top])
	_check(mud_top < grass_top * 0.8, "mud slows a running player", "grass %.2f, mud %.2f" % [grass_top, mud_top])

	# --- Rubber throws higher -----------------------------------------------------------
	var grass_jump: float = await _jump_height(bot, Vector3(-30.0, 1.0, 15.0))
	var rubber_jump: float = await _jump_height(bot, Vector3(-15.0, 1.3, 30.0))
	print("    jump height: grass %.2f m, rubber %.2f m" % [grass_jump, rubber_jump])
	_check(rubber_jump > grass_jump * 1.4, "a jump off rubber goes higher", "grass %.2f, rubber %.2f" % [grass_jump, rubber_jump])

	# --- Lava ---------------------------------------------------------------------------
	var spawn: Vector3 = playground.current_map_node().fallback_spawn
	bot.teleport(Vector3(-50.0, 0.3, 46.0), 0.0)
	await _drive(&"bot", DotFpsCommand.new(), 4)
	_check(bot.controller.state.position.distance_to(spawn) < 5.0, "walking into lava puts a player back at the spawn, with the arena off",
		str(bot.controller.state.position))
	# South of the rock bridge, which crosses the pit at z 50.
	var crate := playground.props.spawn(&"crate", &"bot", Vector3(-46.0, 1.5, 45.0))
	await _drive(&"bot", DotFpsCommand.new(), int(playground.tick_rate * 2.0))
	_check(crate != null and not crate.is_alive(), "and a crate that falls in melts")

	# --- Water is a volume, not a floor: a crate floats on it ------------------------------
	var floater := playground.props.spawn(&"crate", &"bot", Vector3(60.0, 3.0, 50.0))
	await _drive(&"bot", DotFpsCommand.new(), int(playground.tick_rate * 3.0))
	var settled: float = (floater.node as Node3D).global_position.y if floater != null and floater.is_alive() else INF
	var pond_top := 0.0
	for liquid: Dictionary in playground.liquids:
		var box: AABB = liquid["box"]
		if liquid["material"] == &"water" and box.has_point(Vector3(60.0, box.get_center().y, 50.0)):
			pond_top = box.end.y
	_check(absf(settled - (pond_top + 0.5)) < 0.3, "a crate dropped on the pond floats on it",
		"y %.2f, surface %.2f" % [settled, pond_top])

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var _back: DotResult = await playground.change_map(&"pg_flatgrass")
	_done()


## Runs [param player] north (-Z) from [param at] for a second, lets go, and returns the
## share of its speed it still has 24 ticks later.
func _coast(player: PlaygroundPlayer, at: Vector3) -> float:
	player.teleport(at, 0.0)
	await _drive(player.player_id, DotFpsCommand.new(), 16)
	var run := DotFpsCommand.new()
	run.move = Vector2(0.0, 1.0)
	await _drive(player.player_id, run, 128)
	var before := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
	await _drive(player.player_id, DotFpsCommand.new(), 24)
	var after := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
	return after / maxf(before, 0.001)


func _top_speed(player: PlaygroundPlayer, at: Vector3) -> float:
	player.teleport(at, 0.0)
	await _drive(player.player_id, DotFpsCommand.new(), 16)
	var run := DotFpsCommand.new()
	run.move = Vector2(0.0, 1.0)
	await _drive(player.player_id, run, 96)
	return Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()


func _jump_height(player: PlaygroundPlayer, at: Vector3) -> float:
	player.teleport(at, 0.0)
	# Long enough to land: a teleport puts a player in the air, and 24 ticks from a metre up
	# is still falling, which the first version measured as a jump of nothing.
	await _drive(player.player_id, DotFpsCommand.new(), 96)
	var floor_y := player.controller.state.position.y
	var top := floor_y
	var airborne := 0
	for i in 200:
		# Held until it leaves the ground: one press is read on the tick the controller reads it.
		var command := DotFpsCommand.new()
		command.set_button(DotFpsCommand.BUTTON_JUMP, airborne == 0)
		await _drive(player.player_id, command, 1)
		top = maxf(top, player.controller.state.position.y)
		if not player.controller.state.is_grounded():
			airborne += 1
		elif airborne > 2:
			break
	return top - floor_y


## Glass in a map breaks (pgc_nature's greenhouse): a real pistol through the game's shot
## handling, a blast, a crate thrown into it; not a crate nudged into it, not a player running
## alongside it, and nothing at all with `pg_breakable_glass` off. Shards fly and the
## signal every client's sound hangs off fires.
func _test_glass() -> void:
	_section("glass breaks")

	var changed: DotResult = await playground.change_map(&"pgc_nature")
	if not changed.ok:
		_check(false, "pgc_nature loads", changed.error.message)
		_done()
		return
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var player: PlaygroundPlayer = playground.players[&"bot"]

	var pane_at := func(centre: Vector3) -> int:
		for index: int in playground.panes.keys():
			var node := (playground.panes[index] as Dictionary)["node"] as Node3D
			if Playground._pane_bounds(node).get_center().distance_to(centre) < 1.0:
				return index
		return -1
	var glass_panes := playground.panes.values().filter(func(p: Dictionary) -> bool: return p["material"] == &"glass")
	_check(glass_panes.size() == 6, "the greenhouse's six glass boxes are breakable", str(glass_panes.size()))
	var west: int = pane_at.call(Vector3(-7.95, 1.75, 50.0))
	var east: int = pane_at.call(Vector3(7.95, 1.75, 50.0))
	var north: int = pane_at.call(Vector3(0.0, 1.75, 45.05))

	var heard: Array = []
	var on_broken := func(index: int, _at: Vector3, material: StringName) -> void: heard.append([index, material])
	playground.pane_broken.connect(on_broken)

	# --- Running alongside a pane at full speed is not running into it ---------------------
	# Starting past the north wall's end: the first version started south of it, ran into
	# that wall's edge at full speed, and broke it, which is right and was not the question.
	player.teleport(Vector3(8.6, 1.0, 45.8), 180.0)
	var facing_south := DotFpsCommand.new()
	facing_south.yaw = 180.0
	await _drive(&"bot", facing_south, 64)
	var run := DotFpsCommand.new()
	run.move = Vector2(0.0, 1.0)
	run.yaw = 180.0
	await _drive(&"bot", run, 100)
	_check(playground.panes.has(east) and heard.is_empty(), "a player running alongside a pane does not break it",
		"%.2f m/s, at %s" % [player.controller.state.velocity.length(), str(player.controller.state.position)])

	# --- Off, nothing breaks it -----------------------------------------------------------------
	player.teleport(Vector3(-14.0, 1.0, 50.0), -90.0)
	# Facing the pane while it settles: a command carries absolute angles, so an empty one
	# turns the bot to yaw 0, which put the first version's shots into the north wall.
	var facing_west_pane := DotFpsCommand.new()
	facing_west_pane.yaw = -90.0
	await _drive(&"bot", facing_west_pane, 64)
	var rig := PlaygroundZee.arm(player, playground.weapon_def(&"zee_pistol"), ZeeWeaponRig.Role.SERVER, true,
		playground.tick_rate, playground.current_tick())
	playground.panes_break = false
	var _off := _fire_at_crates(rig, player, 160)
	_check(playground.panes.has(west), "with pg_breakable_glass off, shots break no glass")
	playground.panes_break = true

	# --- A pistol breaks it ------------------------------------------------------------------------
	var before := playground.props.all_props().size()
	# One burst: the helper counts ticks itself, and calling it a tick at a time with no frame
	# between hands the rig the same tick each time, which fires once.
	var _shots := _fire_at_crates(rig, player, 240)
	PlaygroundZee.disarm(player)
	await get_tree().physics_frame
	var shards := playground.props.all_props().filter(func(p: DotPropInstance) -> bool: return p.def.id == &"debris")
	_check(not playground.panes.has(west) and playground.broken_panes.has(west), "a pistol shoots a pane out")
	_check(shards.size() >= 3 and playground.props.all_props().size() > before, "and it leaves shards", "%d shards" % shards.size())
	_check(heard.size() == 1 and heard[0][0] == west and heard[0][1] == &"glass", "and says so, once, for the sound", str(heard))
	await get_tree().physics_frame
	var through := playground.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
		Vector3(-14.0, 1.7, 50.0), Vector3(-2.0, 1.7, 50.0)))
	_check(through.is_empty() or not ((through["collider"] as Node).get_meta(&"pg_box", -1) == west),
		"and nothing is left where it stood")

	# --- A blast ---------------------------------------------------------------------------------
	var standing := playground.panes.has(north)
	playground.hurt_panes_in(Vector3(0.0, 1.75, 43.0), 4.0, 100.0, &"bot")
	_check(standing and not playground.panes.has(north), "a blast beside a pane breaks it")

	# --- A crate thrown into it, and one nudged into it -----------------------------------------------
	var nudged := playground.props.spawn(&"crate", &"bot", Vector3(10.5, 0.6, 52.0))
	await get_tree().physics_frame
	(nudged.node as RigidBody3D).linear_velocity = Vector3(-2.0, 0.0, 0.0)
	await _drive(&"bot", DotFpsCommand.new(), 128)
	_check(playground.panes.has(east), "a crate nudged into a pane leaves it standing")
	var thrown := playground.props.spawn(&"crate", &"bot", Vector3(11.0, 1.2, 48.0))
	await get_tree().physics_frame
	(thrown.node as RigidBody3D).linear_velocity = Vector3(-12.0, 0.0, 0.0)
	await _drive(&"bot", DotFpsCommand.new(), 64)
	_check(not playground.panes.has(east), "and one thrown into it breaks it")

	playground.pane_broken.disconnect(on_broken)
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var back: DotResult = await playground.change_map(&"pgc_nature")
	_check(back.ok and playground.panes.size() == 7 and playground.broken_panes.is_empty(), "a map change puts every pane back (the glass and the lake's ice)")
	var _lobby: DotResult = await playground.change_map(&"pg_flatgrass")
	_done()


## Water (pgc_harbour's basin): a player in it swims, floats with the head out, swims
## forward at swim speed; a crate and a barrel float, a boulder sinks to the bed.
func _test_water() -> void:
	_section("water: swimming and floating")

	var changed: DotResult = await playground.change_map(&"pgc_harbour")
	if not changed.ok:
		_check(false, "pgc_harbour loads", changed.error.message)
		_done()
		return
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var player: PlaygroundPlayer = playground.players[&"bot"]
	var boxes := playground.water_boxes()
	_check(boxes.size() == 1 and player.swim.volumes.size() == 1, "the basin is water, and the player is told", str(boxes))
	var surface: float = boxes[0].end.y if not boxes.is_empty() else 0.0

	# Into the basin, clear of the piers.
	player.teleport(Vector3(-70.0, -1.0, -60.0), 0.0)
	var idle := DotFpsCommand.new()
	await _drive(&"bot", idle, 384)
	var head := player.controller.state.position.y + player.swim.float_depth
	print("    floating: feet %.2f, head %.2f, surface %.2f" % [player.controller.state.position.y, head, surface])
	_check(player.controller.state.mode == player.swim.mode_id, "a player who falls in swims")
	_check(absf(head - surface) < 0.3, "and floats with the head at the surface", "head %.2f, surface %.2f" % [head, surface])

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _drive(&"bot", forward, 256)
	var flat := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
	print("    swimming: %.2f m/s" % flat)
	_check(flat > 2.5 and flat <= player.swim.swim_speed + 0.01, "and swims forward, slower than a run", "%.2f m/s" % flat)

	# Props: two that float, one that sinks.
	var crate := playground.props.spawn(&"crate", &"bot", Vector3(-40.0, 1.0, -70.0))
	var barrel := playground.props.spawn(&"barrel", &"bot", Vector3(-35.0, 1.0, -70.0))
	var boulder := playground.props.spawn(&"boulder", &"bot", Vector3(-25.0, 1.0, -70.0))
	# And a beach ball let go on the bed: the lightest thing in the catalogue, and the one
	# a lift added after the damping launched out of the basin to y 2081.
	var bed_y: float = boxes[0].position.y if not boxes.is_empty() else -4.0
	var ball := playground.props.spawn(&"beach_ball", &"bot", Vector3(-30.0, bed_y + 0.6, -60.0))
	var ball_top := -INF
	for _i in range(40):
		await _drive(&"bot", idle, 16)
		ball_top = maxf(ball_top, (ball.node as Node3D).global_position.y)
	# Measured at its bottom: 2 kg in a 2.4 m ball floats on the water, not in it.
	var ball_half: float = PlaygroundProp.extent_of(ball.def).y * 0.5
	var y_ball: float = (ball.node as Node3D).global_position.y - ball_half
	ball_top -= ball_half
	print("    a beach ball from the bed: bottom highest %.2f, after 5 s %.2f (surface %.2f)" % [ball_top, y_ball, surface])
	_check(ball_top < surface + 1.0 and absf(y_ball - surface) < 0.3,
		"a beach ball let go on the bed comes up and floats, and is not launched out",
		"highest %.2f, now %.2f, surface %.2f" % [ball_top, y_ball, surface])
	var y_crate: float = (crate.node as Node3D).global_position.y
	var y_barrel: float = (barrel.node as Node3D).global_position.y
	var y_boulder: float = (boulder.node as Node3D).global_position.y
	var bed := boxes[0].position.y if not boxes.is_empty() else -4.0
	print("    after 5 s: crate %.2f, barrel %.2f, boulder %.2f (surface %.2f, bed %.2f)" % [y_crate, y_barrel, y_boulder, surface, bed])
	_check(absf(y_crate - surface) < 0.6 and absf(y_barrel - surface) < 0.8, "a crate and a barrel float at the surface")
	_check(y_boulder < bed + 2.0, "and a boulder sinks to the bed", "%.2f" % y_boulder)
	_check(absf((crate.node as RigidBody3D).linear_velocity.y) < 0.5, "and what floats has settled, not bobbing for ever",
		"%.2f m/s" % (crate.node as RigidBody3D).linear_velocity.y)

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	var _lobby: DotResult = await playground.change_map(&"pg_flatgrass")
	_check(player.swim.volumes.is_empty() and player.controller.state.mode != player.swim.mode_id,
		"a map with no water leaves nobody swimming")
	_done()


## Nature's newer pieces: thin ice over a lake holds a walker and gives under a drop off the
## diving board (and the player swims), slime sends a player to the spawn with the arena off,
## and a bush is walked straight through.
func _test_ice_slime_foliage() -> void:
	_section("thin ice, slime and foliage")

	var changed: DotResult = await playground.change_map(&"pgc_nature")
	if not changed.ok:
		_check(false, "pgc_nature loads", changed.error.message)
		_done()
		return
	var player: PlaygroundPlayer = playground.players[&"bot"]
	var ice := -1
	for index: int in playground.panes.keys():
		if (playground.panes[index] as Dictionary)["material"] == &"thin_ice":
			ice = index
	_check(ice >= 0, "the lake's ice is breakable")

	var still := DotFpsCommand.new()
	player.teleport(Vector3(4.0, 2.6, -80.0), 0.0)
	await _drive(&"bot", still, 256)
	_check(playground.panes.has(ice) and player.controller.state.position.y > 1.8, "a walker stands on it, and it holds",
		"y %.2f" % player.controller.state.position.y)

	# Off the end of the diving board: 3 m onto the ice.
	player.teleport(Vector3(18.0, 5.1, -80.0), 0.0)
	await _drive(&"bot", still, 200)
	_check(not playground.panes.has(ice), "a drop off the diving board goes through it")
	await _drive(&"bot", still, 200)
	_check(player.controller.state.mode == player.swim.mode_id, "into the water under it, swimming",
		"mode %d at y %.2f" % [player.controller.state.mode, player.controller.state.position.y])

	var spawn: Vector3 = playground.current_map_node().fallback_spawn
	player.teleport(Vector3(-95.0, 0.3, 14.0), 0.0)
	await _drive(&"bot", still, 4)
	_check(player.controller.state.position.distance_to(spawn) < 5.0, "slime puts a player back at the spawn, with the arena off")

	player.teleport(Vector3(-38.0, 1.0, 30.0), -90.0)
	var east := DotFpsCommand.new()
	east.yaw = -90.0
	await _drive(&"bot", east, 32)
	east.move = Vector2(0.0, 1.0)
	await _drive(&"bot", east, 256)
	_check(player.controller.state.position.x > -28.0, "a bush is walked straight through", "x %.2f" % player.controller.state.position.x)

	var _lobby: DotResult = await playground.change_map(&"pg_flatgrass")
	_done()


## Frames until [member PlaygroundClient.gate] is open (physics frames, because it settles on them).
func _gate_opens(client: PlaygroundClient) -> void:
	for _i in range(240):
		if client.gate == null or client.gate.is_open():
			return
		await get_tree().physics_frame
