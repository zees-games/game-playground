extends "res://game/playground_tick.gd"

## What [param player_id] wants their NPCs to carry, or [param fallback].
func npc_weapon_for(player_id: StringName, fallback: StringName = &"") -> StringName:
	var chosen: Variant = npc_weapon_choice.get(player_id, null)

	if chosen == null or StringName(str(chosen)) == &"":
		return fallback

	return StringName(str(chosen))


## Sets what [param player_id]'s next NPCs carry. Refuses a weapon an NPC cannot use.
func set_npc_weapon_choice(player_id: StringName, weapon_id: StringName) -> DotResult:
	if weapon_id == &"" or weapon_id == &"none":
		npc_weapon_choice[player_id] = weapon_id
		return DotResult.success(weapon_id)

	var def := weapon_def(weapon_id)

	if def == null or not PlaygroundZee.npc_can_use(def):
		return DotResult.fail(DotError.CODE_INVALID, "NPCs cannot use that weapon.", String(weapon_id))

	npc_weapon_choice[player_id] = weapon_id
	return DotResult.success(weapon_id)


## How many welds, ropes and no-collides [param player_id] has. For `pg_limits`.
func constraint_count(player_id: StringName) -> int:
	return constraints.count_owned(player_id) if constraints != null else 0


## A player's zee weapon fired: NPCs in earshot hear it, and NPCs it hits are hurt. The third thing a shot does, beside players
## hurting players (the arena's) and `PlaygroundZee.shove_props`.
func player_shots_fired(player_id: StringName, outcome: DotWeaponOutcome) -> void:
	if outcome == null:
		return

	var player: Variant = players.get(player_id)

	if not (player is CollisionObject3D) or not (player as Node3D).is_inside_tree():
		return

	var shooter := player as CollisionObject3D

	# Before the `used` test: what a grenade's release produces is a spawn, and whether a
	# weapon calls that a use is the weapon's business. A spawn left in an outcome is a
	# grenade that cost one and never existed.
	if projectiles != null:
		var _thrown := projectiles.accept(outcome, player_id, shooter)

	if not outcome.used:
		return

	npc_sounds.emit(
		DotNpcAiSounds.Kind.COMBAT, shooter.global_position, GUNFIRE_RADIUS,
		npc_world.now() if npc_world != null else 0.0, 0.5, player_id
	)

	var exclude: Array[RID] = [shooter.get_rid()]

	for hit in PlaygroundZee.trace_outcome(shooter.get_world_3d().direct_space_state, outcome, exclude):
		var collider: Variant = hit["collider"]

		# A toy first: a shot beach ball bounces away, a shot bell rings. The toy box's push,
		# never the prop shove below, whose damage-sized impulse sends a ball off at 40 m/s.
		if shoot_toy(collider, hit):
			continue

		if collider is Node and (collider as Node).has_method("take_damage"):
			(collider as Node).call("take_damage", float(hit["damage"]), player_id)
		elif collider is Node and hurt_pane(collider as Node, float(hit["damage"]), player_id):
			pass
		elif collider is Node:
			var _broke := hurt_prop(collider as Node, float(hit["damage"]), player_id)


## An armed NPC's weapon fired: what it hits is hurt — another NPC always, a player only
## while the arena is on (a sandbox where nobody can be killed stays one) — a loose prop is
## shoved, and everything in earshot hears it.
func npc_shots_fired(entity: Node3D, outcome: DotWeaponOutcome) -> void:
	if outcome == null or entity == null or not entity.is_inside_tree():
		return

	var shooter_id := npc_id_of(entity)

	if projectiles != null:
		var _thrown := projectiles.accept(outcome, shooter_id, entity)

	npc_sounds.emit(
		DotNpcAiSounds.Kind.COMBAT, entity.global_position, GUNFIRE_RADIUS,
		npc_world.now(), 0.5, shooter_id
	)

	var exclude: Array[RID] = [(entity as CollisionObject3D).get_rid()]

	for hit in PlaygroundZee.trace_outcome(entity.get_world_3d().direct_space_state, outcome, exclude):
		var collider: Variant = hit["collider"]
		var damage := float(hit["damage"])

		if shoot_toy(collider, hit):
			continue

		if collider is Node and (collider as Node).has_method("take_damage"):
			(collider as Node).call("take_damage", damage, shooter_id)
		elif collider is PlaygroundPlayer:
			if arena_hurt.is_valid():
				arena_hurt.call(shooter_id, (collider as PlaygroundPlayer).player_id, damage, float(hit["distance"]))
		elif collider is StaticBody3D and hurt_pane(collider as Node, damage, shooter_id):
			pass
		elif collider is RigidBody3D:
			# Hurt first: a shot that breaks a crate leaves nothing to shove.
			var _broke := hurt_prop(collider as Node, damage, shooter_id)
			if not (collider as RigidBody3D).freeze and (collider as Node3D).is_inside_tree():
				(collider as RigidBody3D).apply_impulse(
					(hit["direction"] as Vector3) * damage * SHOT_IMPULSE,
					(hit["point"] as Vector3) - (collider as Node3D).global_position
				)


## The catalogue id a weapon lies in the world as.
static func pickup_id_of(weapon_id: StringName) -> StringName:
	return StringName("pickup_%s" % String(weapon_id).replace(":", "_"))


## Drops [param weapon_id] at [param at], cleaned up after [param lifetime] seconds. Owned
## by nobody, so it counts against no player's weapons limit.
func drop_weapon(weapon_id: StringName, at: Vector3, lifetime: float = 0.0) -> DotPropInstance:
	if props == null:
		return null

	var prop := props.spawn(pickup_id_of(weapon_id), &"", at)

	if prop != null and prop.node != null:
		prop.node.set("lifetime", lifetime)

	return prop


## A player walked over a weapon. Announced, and the server or the client gives it.
func pick_up_weapon(player_id: StringName, weapon_id: StringName) -> void:
	weapon_picked_up.emit(player_id, weapon_id)


## Reads maps.yml (the game's `res://maps.yml` under [member PlaygroundConfig.map_rotation_file], also looked for in the `--config`
## directory) and applies it; the server module calls it at boot and `sv_map_rotation_file` again. The merge and rules are dot-map's
## [DotMapRotationFile]. A present but unreadable file is an ERROR and changes nothing: rotating every map beats rotating none.
func load_rotation() -> DotResult:
	var stem := config.map_rotation_file if config != null else ""
	var dir := DotMapRotationFile.config_dir_arg()
	var found := DotMapRotationFile.find(stem, dir)

	if found == "" and stem != "" and (dir != "" or stem != PlaygroundConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every map rotates", {
			"file": stem, "config_dir": dir,
		})

	var paths := PackedStringArray()
	for candidate in ["res://maps.yml", found]:
		if candidate != "" and not paths.has(candidate) and FileAccess.file_exists(candidate):
			paths.append(candidate)

	var read := DotMapRotationFile.load_files(paths, "game-playground")

	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every map rotates", {
			"why": read.error.message,
		})
		rotation_file = null
		apply_rotation()
		return read

	rotation_file = read.value
	if rotation_file.has_rotations():
		DotLog.info(CHANNEL, "the map rotation file", {
			"paths": ", ".join(rotation_file.sources), "active": rotation_file.active_name(),
		})

	apply_rotation()
	return read


## Marks every catalogue map in or out of rotation ([member DotMapDef.in_rotation]) from the
## file. With no file, or one with no rotations, every map is in: what this game did before
## maps.yml. The vote's ballot, nominations, `next` and the rotation's draw all read the mark.
func apply_rotation() -> void:
	if maps == null or maps.catalogue == null or maps.rotation == null:
		return

	if rotation_file != null and rotation_file.has_rotations():
		# An empty rotation plays every installed map: the same set as having no file.
		rotation_file.fallback_in = func(_map: DotMapDef) -> bool: return true
		rotation_file.apply(maps.rotation)
		return

	maps.rotation.order = []

	for def in maps.catalogue.maps:
		def.in_rotation = true


## Whether maps.yml's active rotation plays [param id]. A map the catalogue lacks is not.
func in_rotation(id: StringName) -> bool:
	var def: DotMapDef = maps.catalogue.get_map(id) if maps != null and maps.catalogue != null else null

	return def != null and def.in_rotation


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func rotation_commands() -> Dictionary:
	return rotation_file.commands() if rotation_file != null else {}


## Every name a command of this game's own answers to (the first is the one help shows), from
## maps.yml's `commands: names:` block; the role's own name with no file. Lets `pg_rtv` and its
## siblings be renamed the way dot-vote's roles are.
func command_names(role: String) -> PackedStringArray:
	var names: Dictionary = rotation_commands().get("names", {})

	if not names.has(role):
		return PackedStringArray([role])

	return DotCommandNames.all_of("", names, {}, role)


## Adds the map documents in [param dir] to this game's live catalogue, and puts them in
## the rotation. For a mounted maps pack: the module calls it with each dependency's mount
## prefix on a server, the client with each pack the server told it to fetch.
func add_map_directory(dir: String) -> int:
	if maps == null or maps.catalogue == null:
		return 0
	var added := add_map_docs(maps.catalogue, dir)
	if added > 0:
		maps.rotation = DotMapRotation.of(maps.catalogue)
		maps.rotation.cooldown = 1
		# A new rotation object has forgotten the file's order and its in/out marks.
		apply_rotation()
		DotLog.info(CHANNEL, "custom maps added", {"dir": dir, "maps": added})
	return added


## Reads the prop folders again and adds what is new, so a model dropped in while the game
## runs appears in the next menu. Returns the ids added.
func rescan_props() -> PackedStringArray:
	if props == null or props.catalogue == null:
		return PackedStringArray()

	return PlaygroundSpawnables.add_drop_ins(
		props.catalogue, config.props_dir if config != null else "user://props"
	)


## The key a run timer, its records and the boards know a player by: the account's `session.uid()` (a guest's is per device),
## given to [method add_player]. Not the match id, which is server-local, names a seat for one connection and is handed to strangers
## after a restart. A player added without one (solo, a client's copy, a test) is known by the match id. A display name is never a key.
func record_key(id: StringName) -> StringName:
	return _record_keys.get(id, id)


## The match id a record key belongs to; the key itself when none does.
func match_id(key: StringName) -> StringName:
	return _match_ids.get(key, key)


## True for a key that is a server-local session number (`u<digits>`): the keying records
## carried before they were keyed by account. A run timer moves such records aside.
static func is_legacy_key(key: StringName) -> bool:
	var text := String(key)
	return text.length() > 1 and text.begins_with("u") and text.substr(1).is_valid_int() and not text.contains("-")


func _claim_record_key(id: StringName, key: StringName) -> void:
	if key == &"" or key == id:
		return
	if _match_ids.has(key) and _match_ids[key] != id:
		# The same account twice at once would share one timer, and the second seat's
		# runs would be filed under the first's. It keeps its match id as its key: a
		# legacy-shaped key, which is never ranked.
		DotLog.warn(CHANNEL, "an account is already playing; this seat has no records", {
			"player": String(id), "key": String(key),
		})
		return
	_record_keys[id] = key
	_match_ids[key] = id


func _release_record_key(id: StringName) -> void:
	var key: StringName = _record_keys.get(id, &"")
	_record_keys.erase(id)
	if key != &"":
		_match_ids.erase(key)


## Adds a player and puts them on the current map's spawn. [param p_record_key] is the
## account uid the player's records are filed under; see [method record_key].
func add_player(id: StringName, display_name: String, p_record_key: StringName = &"") -> PlaygroundPlayer:
	if players.has(id):
		return players[id]

	_claim_record_key(id, p_record_key)

	var player := PlaygroundPlayer.new()
	player.name = "Player_" + String(id)
	player.player_id = id
	player.display_name = display_name
	player.authoritative = authoritative
	player.tick_rate = tick_rate

	add_child(player)

	player.carry = carry
	player.carry_enabled_fn = func() -> bool: return config == null or config.prop_surfing
	# The map's toys: the trampolines and pads that throw them, the roundabout that carries
	# them. Both ends; the box is the current map's (see [method _build_toys]).
	player.toys = toys
	player.bounced_fn = _on_bounced

	var _styled := player.set_style(movement_styles[&"normal"])

	player.phys_gun = DotPhysGun.new()
	player.phys_gun.spawner = props
	player.phys_gun.wielder = id

		# A held prop, a frozen prop and a loose one are three rows in the layout: `sandbox_3d` carries `held_prop` and `frozen_prop`
		# for this. Without dot-props' three signals a layer could only be set at spawn, and a carried crate collided with its carrier.
	player.phys_gun.grabbed.connect(
		func(prop: DotPropInstance, who: StringName) -> void:
			reclassify_prop(prop.node, false, true)
			held_changed.emit(who, prop, true)
	)
	player.phys_gun.released.connect(
		func(prop: DotPropInstance, who: StringName) -> void:
			reclassify_prop(prop.node, prop.frozen, false)
			held_changed.emit(who, prop, false)
	)
	player.phys_gun.freeze_changed.connect(
		func(prop: DotPropInstance, frozen: bool) -> void:
			reclassify_prop(prop.node, frozen, prop.held_by != &"")
	)

	player.grav_gun = DotGravGun.new()
	player.grav_gun.spawner = props
	player.grav_gun.wielder = id

	# The layout's player mask rather than the magic 1. With props, entities and
	# vehicles on their own layers, a mask of 1 is a player who walks through all three.
	if player_stack != null:
		_apply_body_mask(player)
		# And a body other people can see. Built for every player, local or not: the one
		# who does not need it is the LOCAL player in first person, and that is a
		# `set_shown(false)` rather than a missing model.
		player.build_character(player_stack.character(), _colour_for(id))
		# And the body itself, now that a player IS a CharacterBody3D — it is in the
		# physics space whether or not the movement uses it, and a body on layer 1 is a
		# body every other sweep treats as level geometry.
		var _put := player_stack.classify(player, &"player")


	players[id] = player
	player.set_water(water_boxes())

	# Given a timer before the first spawn, which asks it which track the player is on.
	if run_timer != null:
		run_timer.call("add_player", id, player)

	spawn_player(id)

	# Their entity id, before anything that might want one. Opened here rather than in
	# a layer so every layer sees the same id whether or not the others are switched
	# on; `PlaygroundDowns` and `PlaygroundArena` would otherwise each mint their own.
	var opened := entity_table.open(
		DotEntity.KIND_PLAYER,
		player,
		&"",
		id,
		float(_tick) / float(maxi(tick_rate, 1))
	)

	if not opened.ok:
		# Guarded above by the `players.has(id)` early return, so a refusal means this
		# id is already an entity and something removed a player without closing them.
		DotLog.error(CHANNEL, "could not open an entity for a player", {
			"player": String(id), "why": opened.error.message,
		})

	# After the player is fully built and in the dictionary: a listener answers this
	# by replicating them, and an entity built over a half-constructed player would
	# replicate a controller that has no style and no timer.
	apply_pass_through()
	player_added.emit(id)

	return player


func remove_player(id: StringName) -> void:
	if not players.has(id):
		return

	# Before anything is torn down, so a listener can still read what they were.
	player_removed.emit(id)

	# Let go of them, and of whoever they hold: a beam from a player who is gone holds a
	# player who can never walk again.
	pickup.forget(players, id)

	# Closed after the signal and before the node goes: a listener asking the table
	# who this was must still get an answer, and anything holding the id afterwards
	# gets nothing rather than getting whoever joins next -- serials are not reused.
	entity_table.close(entity_table.id_for_key(id), DotEntityTable.REASON_OWNER_LEFT)

	# Their rock-the-vote goes with them. Without it a server whose players trickle
	# away keeps their votes while the threshold falls with the player count, so a
	# map ends on the votes of people who are no longer there.
	maps.time_limit.unrock(id)

		# Out of the car before anything else, and forced: a player who disconnects while riding leaves a node stowed in a vehicle and
		# a rider id that never clears, so the seat stays occupied for the round. Forced because there may be nowhere legal to stand.
	if vehicles != null and vehicles.ride.is_riding(id):
		var riding := vehicles.vehicle_of_rider(id)

		if riding != null:
			vehicles.ride.exit(riding, id, true)

		# Their vehicles are DISOWNED rather than removed (dot-vehicle's rule, the opposite of dot-props'): a prop is something somebody
		# built, a vehicle something somebody parked, and deleting it deletes the car three passengers are riding in.
	if vehicles != null:
		vehicles.owner_left(id)

	# The prop spawner first: it may free nodes, and doing it after the player's own
	# teardown means a physics gun holding one of them is already gone.
	props.player_left(id)

	if run_timer != null:
		run_timer.call("remove_player", id)

	(players[id] as PlaygroundPlayer).queue_free()

	players.erase(id)
	if block_rules != null:
		block_rules.call(&"forget", id)
	apply_pass_through()
	_release_record_key(id)


## Puts a player at the current map's spawn for their track.

## A stable colour for a player, derived from their id. Derived rather than assigned, so two machines agree with no field on the
## wire and nothing to be out of step in a reconnect. Full saturation and a fixed value, because brightness alone does not
## tell two players apart at a distance.
func _colour_for(id: StringName) -> Color:
	var hue := float(hash(String(id)) % 360) / 360.0
	return Color.from_hsv(hue, 0.62, 0.92)


## Puts a player on a movement style. A run timer hears it through the player's
## `style_changed` and moves the ranking half with it.
func set_player_style(id: StringName, style_id: StringName) -> bool:
	var player: PlaygroundPlayer = players.get(id)

	if player == null or not movement_styles.has(style_id):
		return false

	return player.set_style(movement_styles[style_id]).ok


## Starts offering what the player subscribed to (the Workshop) on the spawn menu and the map list: pack weapons, props, NPCs,
## entities and maps of the kinds `provides.json` accepts. Solo only, and the caller decides: the offline client calls it and a
## dedicated server or connected client never does. [param index] defaults to the shared one.
func follow_workshop(index: DotContentIndex = null) -> PlaygroundWorkshop:
	var shared := index if index != null else DotContentIndex.shared()
	if workshop == null:
		workshop = PlaygroundWorkshop.new()
		workshop.changed.connect(func() -> void: workshop_changed.emit())
	workshop.follow(shared, props.catalogue, weapons)
	if maps != null and maps.catalogue != null:
		maps.catalogue.follow_content(shared, PlaygroundWorkshop.accepted_map_kinds())
	return workshop


## Stops [method follow_workshop]: the pack rows leave the catalogue and the weapon list.
func unfollow_workshop() -> void:
	if workshop != null:
		workshop.unfollow()
	if maps != null and maps.catalogue != null:
		maps.catalogue.unfollow_content()


## The definition of one weapon, or null.
func weapon_def(id: StringName) -> PlaygroundWeaponDef:
	return PlaygroundWeapons.find(weapons, id)


## Whether a player may act on somebody else's props, from the configuration: asked of the game, not decided in a tool, so a gun and
## a remover cannot disagree. The physics gun's primary press: a player in the beam first, then a prop. A player refused (immune,
## already held) is an answer, not a miss, so the prop behind is not grabbed; a beam that meets nobody falls through to the gun.
func phys_gun_grab(
	player: PlaygroundPlayer, space: Variant, origin: Vector3, aim: Vector3, view: Basis, may_touch: bool
) -> DotResult:
	var target := pickup.player_in_beam(players, player, space, origin, aim) if pickup.enabled else null
	if target != null:
		return pickup.pick_up(player, target, origin)
	return player.phys_gun.grab(space, origin, aim, view, may_touch)


## Lets go of whatever the physics gun holds, a player or a prop. A player is thrown with
## the beam's velocity.
func phys_gun_release(player: PlaygroundPlayer) -> void:
	pickup.release(players, player.player_id, true)
	player.phys_gun.release()


## Turns creative mode on or off for [param id]: their props protected in dot-props, out of anybody's beam, and the arena's damage
## refused both ways (a player nobody can hurt who could hurt everybody would win the arena). Refused when the server does not allow it.
func set_creative(id: StringName, on: bool) -> DotResult:
	var player: PlaygroundPlayer = players.get(id)

	if player == null:
		return DotResult.fail(DotError.CODE_INVALID, "No such player.")

	if on and config != null and not config.allow_creative:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Creative mode is off on this server.")

	if player.creative == on:
		return DotResult.success(on)

	player.creative = on

	if props != null:
		props.set_protected(id, on)

	if on:
		# Out of anybody's hands now, and out of their own grip on anybody else.
		pickup.forget(players, id)

		# A prop of theirs somebody else is holding is let go: protection that waited for
		# the holder to let go first would not be protection.
		for other_id in players:
			if other_id == id:
				continue
			var other: PlaygroundPlayer = players[other_id]
			var held: DotPropInstance = other.phys_gun.held if other.phys_gun != null else null
			if held != null and held.owner_id == id:
				other.phys_gun.release()
			var carried: DotPropInstance = other.grav_gun.carried if other.grav_gun != null else null
			if carried != null and carried.owner_id == id:
				var _dropped := other.grav_gun.drop()

	DotLog.info(CHANNEL, "creative mode", {"player": String(id), "on": on})
	creative_changed.emit(id, on)
	return DotResult.success(on)


func is_creative(id: StringName) -> bool:
	var player: PlaygroundPlayer = players.get(id)
	return player != null and player.creative


## The toy [param player] is looking at within reach, or -1. Both ends.
func toy_aimed(player: PlaygroundPlayer) -> int:
	if toys == null or player == null or not player.is_inside_tree():
		return -1
	return toys.aimed(player.eye_position(), player.aim_direction(), TOY_REACH)


## A hit scan's hit on a toy: dot-props pushes it by the damage (a shot bell rings). True when
## the collider was a toy's, so the caller does not also hurt or shove it. Server side.
func shoot_toy(collider: Variant, hit: Dictionary) -> bool:
	if toys == null or not authoritative or not (collider is Object):
		return false
	return toys.shot(collider as Object, hit["point"], hit["direction"], float(hit["damage"])) >= 0 \
		or DotPropToyBox.toy_of(collider) != null


## A player thrown by a toy: its count goes up, which every client hears. Server side.
func _on_bounced(index: int) -> void:
	if authoritative and toys != null:
		toys.launched(index)


func may_touch_others() -> bool:
	return config == null or config.touch_others_props


## Which tracks this map has something on, main track (0) first: the run timer's answer from its zones when there is one,
## else [code][0][/code], because a sandbox is a legitimate track and every map has it.
func tracks_on_this_map() -> Array[int]:
	var out: Array[int] = [0]

	if run_timer != null:
		out.assign(run_timer.call("tracks"))

	return out


## Called by a run timer's hook to plug itself in. See [member run_timer].
func attach_run_timer(timer: Object) -> void:
	run_timer = timer
	DotLog.info(CHANNEL, "a run timer is attached", {"by": str(timer.get_script().resource_path)})


## A time as `m:ss.mmm`, the way every run timer shows one: thousandths, always, because
## runs are decided by them. A copy of dot-timer's format, so the HUD and the logs can say a
## time with the timer absent.
static func format_time(seconds: float) -> String:
	var total := absf(seconds)
	var hours := int(total / 3600.0)
	var minutes := int(fmod(total, 3600.0) / 60.0)
	var rest := fmod(total, 60.0)
	var text := "%d:%02d:%06.3f" % [hours, minutes, rest] if hours > 0 else "%d:%06.3f" % [minutes, rest]
	return ("-" if seconds < 0.0 else "") + text


## The nearest vehicle a player could get into, or null. Measured from the eye, not the feet: a player beside a car is about 1.7 m
## above the point their body reports, and a reach from there fails while they look straight at the door.
func vehicle_near(player_id: StringName, reach: float = 3.5) -> DotVehicleInstance:
	var player: PlaygroundPlayer = players.get(player_id)

	if player == null or vehicles == null:
		return null

	return vehicles.nearest_free(player.eye_position(), reach)


## What F does: presses the button, throws the lever or swings the door in front of the player, otherwise gets in or out of a
## vehicle. One entry point for both, because the player pressed one key and a client guessing enter versus exit asks to enter the car
## it is already in; the bridge already carries it (`ask_use_vehicle`), so a button needs no new message.
func use_vehicle(player_id: StringName) -> DotResult:
	var player: PlaygroundPlayer = players.get(player_id)

	if player == null or vehicles == null:
		return DotResult.fail(DotError.CODE_STATE, "No such player.")

	if vehicles.vehicle_of_rider(player_id) == null:
		var used := use_prop(player_id)
		if used.ok:
			return used

	var riding := vehicles.vehicle_of_rider(player_id)

	if riding != null:
		return vehicles.ride.exit(riding, player_id)

	var near := vehicle_near(player_id)

	if near == null:
		return DotResult.fail(DotError.CODE_STATE, "There is nothing to get into.")

	return vehicles.ride.enter(near, player_id, player)


## Presses what [param player_id] is looking at within [constant USE_REACH]: a button fires
## `pressed`, a lever switches and fires `switched` with its new state, a door swings. Fails
## when there is nothing usable in front of them. On the authority only.
func use_prop(player_id: StringName) -> DotResult:
	var player: PlaygroundPlayer = players.get(player_id)

	if player == null or io == null or not authoritative or player.grav_gun == null or not player.is_inside_tree():
		return DotResult.fail(DotError.CODE_STATE, "Nothing to use.")

	# A toy looked at, before any prop: a kick, a push, a switch, a honk.
	var toy := toy_aimed(player)

	if toy >= 0 and toys.use(toy, player.eye_position(), player.aim_direction()):
		return DotResult.success(toys.toy(toy))

	var gun := player.grav_gun
	var reach := gun.reach
	gun.reach = USE_REACH
	var prop := gun.target(player.get_world_3d().direct_space_state, player.eye_position(), player.aim_direction())
	gun.reach = reach

	if prop == null or prop.def == null:
		return DotResult.fail(DotError.CODE_STATE, "Nothing to use.")

	if _doors.has(prop.instance_id):
		_set_door(prop, not bool(_doors[prop.instance_id]["open"]))
		return DotResult.success(prop)

	var outputs := DotPropIO.outputs_of(prop.def)

	if outputs.has("pressed"):
		var _heard := io.fire(prop.instance_id, &"pressed")
		return DotResult.success(prop)

	if outputs.has("switched"):
		var on := not bool(_levers.get(prop.instance_id, false))
		_levers[prop.instance_id] = on
		if prop.node is PlaygroundProp:
			(prop.node as PlaygroundProp).set_tint(Color(0.3, 0.8, 0.35) if on else Color(0.8, 0.3, 0.3))
		var _heard := io.fire(prop.instance_id, &"switched", on)
		return DotResult.success(prop)

	return DotResult.fail(DotError.CODE_STATE, "Nothing to use.")


## Whether the door [param instance_id] is open (or opening). For the suites and `describe`.
func door_is_open(instance_id: int) -> bool:
	return bool(_doors.get(instance_id, {}).get("open", false))


func door_swing(instance_id: int) -> float:
	return float(_doors.get(instance_id, {}).get("t", 0.0))


func rock_the_vote(player_id: StringName) -> bool:
	return maps.rock_the_vote(player_id, players.size())


func describe() -> Dictionary:
	return {
		"map": String(maps.current.id) if maps != null and maps.current != null else "-",
		"players": players.size(),
		"props": props.world_count() if props != null else 0,
		"tick_rate": tick_rate,
		"time_left": time_left_text(),
		"run_timer": run_timer.call("describe") if run_timer != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("map          %s" % (
		String(maps.current.id) if maps != null and maps.current != null else "-"
	))
	out.append("players      %d" % players.size())
	out.append("props        %d" % (props.world_count() if props != null else 0))
	out.append("tick rate    %d%s" % [
		tick_rate,
		"" if run_timer == null or tick_rate == Engine.physics_ticks_per_second
			else " (DISAGREES with the engine's %d)" % Engine.physics_ticks_per_second,
	])
	out.append("time left    %s" % time_left_text())

	for id in players:
		out.append("  %s" % str((players[id] as PlaygroundPlayer).describe()))

	return out


## The map's time left as an operator should read it: the vote's clock when there is a vote ("no limit" when it has none, "stopped"
## while a ballot holds it or it ran out), else the map session's. "no limit" here where the HUD shows nothing: an absent row reads
## as a diagnostic that forgot to say.
func time_left_text() -> String:
	if clock_fn.is_valid():
		var state: Dictionary = clock_fn.call()

		if not bool(state.get("has_clock", false)):
			return "no limit"

		var total := int(state.get("seconds_left", 0))
		return "%d:%02d%s" % [
			total / 60, total % 60, "" if bool(state.get("running", false)) else " (stopped)"
		]

	return maps.time_limit.formatted_remaining() if maps != null else "-"


func _exit_tree() -> void:
	DotRegistry.unregister_instance(DotRegistry.scoped_name(SERVICE, service_scope), self)
	if addons != null:
		addons.release()
	if profiles != null:
		profiles.release()


## The side a player is on for dot-team's block rules. A sandbox has none, so everybody is an enemy and blocks until they ask to pass (`!noblock`).
func team_of_side(_id: Variant) -> Variant:
	return ""
