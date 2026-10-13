extends Node3D

const PlaygroundPlayer := preload("playground_player.gd")

## Grenades and rockets in flight in the sandbox, and what happens where they go off.
##
## [b]This exists because the game used to drop them.[/b] A zee weapon's outcome carries
## its shots and its [DotWeaponSpawn]s. The game resolved the shots and ignored the spawns,
## so a thrown frag left the hand, cost a grenade and never existed. dot-weapon returns a
## spawn because a projectile is an entity with a lifetime, and something has to fly it.
## game-arena's `arena_projectiles.gd` is the same job against that game's analytic map.
## This one is written separately, as the family's rule says, because the sandbox's world
## is Godot physics: crates, welds and whatever somebody built. A grenade has to bounce off
## those as well as the floor.
##
## [b]It flies on the simulation tick, swept with a ray each tick.[/b] A rocket at 40 m/s
## moves 31 cm a tick at 128 Hz, and a plank is thinner than that. A point test would let
## it through about one time in three.
##
## [b]Only the authority decides anything.[/b] The server (or an offline game) detonates,
## hurts and shoves. A connected client is told about each launch and flies its own copy so
## it can draw the arc, and its copy never goes off on its own: the client's physics world
## holds interpolated mirrors of the props, which are not where the server's are, so a
## client deciding its own detonation would put the blast somewhere the server did not.
## It goes off when the server's DETONATE says where.
##
## [b]NPCs flee it while it is live.[/b] Every few ticks each projectile is a DANGER on
## every sound board it was given, reaching as far as its splash plus a margin. That is
## what dot-npc-ai's `flee_danger` acts on: soldiers and wave NPCs get out from under a
## grenade, and they hear the bang as a COMBAT sound.

## One projectile, mid-air, rolling, or stuck to something.
class Flying extends RefCounted:
	var serial: int = 0
	var spawn: DotWeaponSpawn = null
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var age_ticks: int = 0
	## A candidate id: a player (`u3`), an armed NPC, or empty.
	var owner_id: StringName = &""
	## The thrower's body, ignored for the first few ticks.
	var owner_rid: RID = RID()
	var sticks: bool = false
	var resting: bool = false
	var stuck_to: Node3D = null
	var stuck_offset: Vector3 = Vector3.ZERO
	var bounces: int = 0
	var view: MeshInstance3D = null


## Speed a fused grenade keeps off a bounce, into the surface and along it. game-arena's
## numbers, for its reason: low into a wall so it does not read as rubber, higher along it
## so it still rolls into the room it was thrown into.
const RESTITUTION := 0.3
const SURFACE_KEEP := 0.7

## What a bounce off a FLOOR keeps along it, which is less than a wall: the floor is what
## a grenade rubs along. At the wall's 0.7 a frag thrown at the ground three metres ahead
## skipped twenty-two metres down the sandbox in hops, and went off past everything it was
## thrown at.
const FLOOR_KEEP := 0.45

## Below this it stops on a floor rather than hopping on the spot. Metres per second.
const REST_SPEED := 1.2

## Bounces before it simply stops, so one wedged in a corner is not swept every tick.
const MAX_BOUNCES := 12

## Ticks a thrown grenade ignores its thrower, against one for a rocket. A grenade lobbed
## while running forward is overtaken by the thrower's own hull on the second or third tick.
const THROWER_GRACE_TICKS := 8

## How often a live projectile is announced as a DANGER, in ticks, and for how long each
## announcement lasts. Short and repeated rather than one long one, so the danger follows a
## rolling grenade and ends when it goes off.
const DANGER_EVERY_TICKS := 8
const DANGER_SECONDS := 0.25

## How far away an NPC notices a projectile, and how much further than the splash it keeps
## away. An NPC that stops exactly at the splash edge is in it a tick later.
const DANGER_HEARD := 25.0
const DANGER_MARGIN := 1.5

## How far a detonation is heard.
const BLAST_HEARD := 50.0

## Push on a loose prop per point of splash damage at the centre, falling off to nothing at
## the edge. More than a bullet's (`Playground.SHOT_IMPULSE`), because an explosion should
## throw the crate it went off under.
const BLAST_IMPULSE := 1.2

## Things one blast can reach. Ignores past this in a very crowded sandbox, rather than
## spending a frame finding all of them.
const BLAST_MAX_RESULTS := 64

## How long a detonation's flash is drawn, in seconds.
const FLASH_SECONDS := 0.3

## Whether this end decides detonations: the server, or an offline game.
var authority: bool = true

## The game: for players, arena damage and the NPC clock. Set by [Playground].
var game: Node = null

## The sound boards a live projectile is a danger on and a blast is heard on, each with
## the clock it keeps: `[board, now_fn]`. Each with its own because the armed NPCs' board
## is on the NPC world's clock and the waves' is on their spawner's, and a sound stamped in
## the wrong clock is one that expired before it was made or never does.
var _boards: Array = []

## Where the `sticks` rule is read from, by the spawn's id. Null leaves every fused spawn a
## bouncer.
var catalogue: DotWeaponCatalogue = null

var _live: Array[Flying] = []
var _next_serial: int = 1
var _gravity: float = 9.8
var _flashes: Array = []

## A projectile left a weapon. What the server tells clients about.
signal launched(flying: Flying)

## One went off at [param at]. On a client, when the server said so.
signal detonated(serial: int, at: Vector3, radius: float)


func _init() -> void:
	name = "Projectiles"
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))


## Makes every live projectile a danger on [param board], and every blast heard on it.
## [param now_fn] is `func() -> float`, the clock that board keeps.
func add_board(board: DotNpcAiSounds, now_fn: Callable) -> void:
	if board != null:
		_boards.append([board, now_fn])


## Takes every spawn in [param outcome], thrown by [param owner_id] from [param owner_body].
## Returns how many it launched. Does nothing on a client: a client is told.
func accept(outcome: DotWeaponOutcome, owner_id: StringName, owner_body: Node = null) -> int:
	if not authority or outcome == null:
		return 0

	var rid := RID()

	if owner_body is CollisionObject3D:
		rid = (owner_body as CollisionObject3D).get_rid()

	# Flown as given: a spawn's fuse and life arrive in this server's ticks, because
	# dot-weapon scales a row written at 64 Hz (the pack's) to the arsenal's rate before
	# the behaviour hands it over. Rescaling here as well would halve every fuse again.
	for spawn: DotWeaponSpawn in outcome.spawns:
		var _flying := launch(spawn, owner_id, rid)

	return outcome.spawns.size()


## Puts one projectile in the air. [param serial] 0 allocates one, which is what the
## authority does; a client passes the server's.
func launch(spawn: DotWeaponSpawn, owner_id: StringName, owner_rid: RID = RID(), serial: int = 0) -> Flying:
	var f := Flying.new()
	f.serial = serial if serial > 0 else _next_serial
	_next_serial = maxi(_next_serial, f.serial) + 1
	f.spawn = spawn
	f.position = spawn.origin
	f.velocity = spawn.velocity
	f.owner_id = owner_id
	f.owner_rid = owner_rid
	f.sticks = _sticks(spawn)
	_live.append(f)
	_draw(f)
	launched.emit(f)
	return f


func _sticks(spawn: DotWeaponSpawn) -> bool:
	if spawn.meta.has(&"sticks"):
		return bool(spawn.meta[&"sticks"])

	if catalogue == null:
		return false

	var def := catalogue.get_def(spawn.id)
	return def != null and bool(def.params.get(&"sticks", false))


func live_count() -> int:
	return _live.size()


## Everything in the air or on the ground.
func flying() -> Array[Flying]:
	return _live


## Every live projectile, as `[position, splash_radius]`.
func in_flight() -> Array:
	var out: Array = []

	for f in _live:
		out.append([f.position, f.spawn.splash_radius])

	return out


## Takes everything out of the air without detonating any of it. For a map change: the
## geometry they are flying through is about to stop existing.
func clear() -> void:
	for f in _live:
		_undraw(f)

	_live.clear()


## One tick: fly, bounce, stick, detonate what is due, and announce the danger.
##
## Iterated backwards so a detonation can remove its own entry without skipping the next.
func tick(delta: float) -> void:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null

	for i in range(_live.size() - 1, -1, -1):
		var f: Flying = _live[i]
		f.age_ticks += 1

		if authority and _due(f):
			_detonate(f, f.position)
			_live.remove_at(i)
			continue

		if f.resting:
			_follow(f)
		else:
			if f.spawn.gravity_scale > 0.0:
				f.velocity.y -= _gravity * f.spawn.gravity_scale * delta

			var step := f.velocity * delta
			var hit := _sweep(space, f, step)

			if hit.is_empty():
				f.position += step
			elif f.spawn.fuse_ticks <= 0 and authority:
				_detonate(f, hit["position"])
				_live.remove_at(i)
				continue
			elif f.spawn.fuse_ticks <= 0:
				# A client's rocket stops where it met something and waits to be told.
				f.position = hit["position"]
				f.velocity = Vector3.ZERO
				f.resting = true
			else:
				_touch(f, hit)

		if f.age_ticks >= f.spawn.life_ticks:
			if authority:
				_detonate(f, f.position)
				_live.remove_at(i)
				continue
			elif f.age_ticks >= f.spawn.life_ticks + THROWER_GRACE_TICKS * 8:
				# Told about nothing for a long time: the DETONATE was lost with a
				# connection, so stop drawing it.
				_undraw(f)
				_live.remove_at(i)
				continue

		if authority and f.age_ticks % DANGER_EVERY_TICKS == 1:
			_announce_danger(f)

		_place(f)

	_age_flashes(delta)


## A client's half of a detonation: the server said serial [param serial] went off at
## [param at]. The local copy goes and the flash is drawn where the server put it.
func detonate_remote(serial: int, at: Vector3, radius: float) -> void:
	for i in range(_live.size() - 1, -1, -1):
		if _live[i].serial == serial:
			_undraw(_live[i])
			_live.remove_at(i)
			break

	_flash(at, radius)
	detonated.emit(serial, at, radius)


## Whether [param f] goes off this tick without touching anything: a fuse run out, or a
## spawn with no fuse and no speed, which is dot-weapon's grenade cooked past its fuse.
func _due(f: Flying) -> bool:
	if f.spawn.fuse_ticks > 0:
		return f.age_ticks >= f.spawn.fuse_ticks

	return f.age_ticks <= 1 and f.velocity == Vector3.ZERO


func _touch(f: Flying, hit: Dictionary) -> void:
	var normal: Vector3 = hit["normal"]

	if normal.length_squared() < 0.0001:
		normal = -f.velocity.normalized()

	f.position = (hit["position"] as Vector3) + normal * maxf(f.spawn.radius, 0.02)

	if f.sticks:
		f.velocity = Vector3.ZERO
		f.resting = true

		# Stuck to a crate it rides the crate, and stuck to a person it is on the person.
		var collider: Variant = hit["collider"]
		if collider is Node3D and not (collider is StaticBody3D):
			f.stuck_to = collider as Node3D
			f.stuck_offset = f.position - f.stuck_to.global_position
		return

	var into := f.velocity.dot(normal)
	var along := f.velocity - normal * into
	f.velocity = along * (FLOOR_KEEP if normal.y > 0.7 else SURFACE_KEEP) - normal * into * RESTITUTION
	f.bounces += 1

	if (normal.y > 0.7 and f.velocity.length() < REST_SPEED) or f.bounces >= MAX_BOUNCES:
		f.velocity = Vector3.ZERO
		f.resting = true


func _follow(f: Flying) -> void:
	if f.stuck_to == null:
		return

	if not is_instance_valid(f.stuck_to) or not f.stuck_to.is_inside_tree():
		# What it stuck to is gone. It falls from where it was rather than hanging in air.
		f.stuck_to = null
		f.resting = false
		return

	f.position = f.stuck_to.global_position + f.stuck_offset


func _sweep(space: PhysicsDirectSpaceState3D, f: Flying, step: Vector3) -> Dictionary:
	if space == null or step.length_squared() <= 0.0:
		return {}

	var query := PhysicsRayQueryParameters3D.create(f.position, f.position + step)
	var grace := 1 if f.spawn.fuse_ticks <= 0 else THROWER_GRACE_TICKS

	if f.owner_rid.is_valid() and f.age_ticks <= grace:
		query.exclude = [f.owner_rid]

	return space.intersect_ray(query)


## What a blast does, on the authority. Everything inside the splash and in sight of its
## centre is hurt by linear falloff: an armed NPC through `take_damage`, a player through
## the arena (unset when the arena is off, so nobody dies in a sandbox), a loose prop shoved
## away from the centre. The thrower is not spared, which is a grenade.
func _detonate(f: Flying, at: Vector3) -> void:
	var radius := f.spawn.splash_radius
	var space := get_world_3d().direct_space_state if is_inside_tree() else null

	if space != null and radius > 0.0:
		for collider in _in_blast(space, at, radius):
			_blast(space, f, at, radius, collider)
		# Map panes too (glass), which the blast's shape query does not return: they are world.
		if game != null and game.has_method("hurt_panes_in"):
			game.call("hurt_panes_in", at, radius, f.spawn.splash_damage, f.owner_id)
		# And the map's toys, by dot-props' own blast: a damage-sized impulse sends a beach
		# ball off at a hundred metres a second (see [method _blast], which skips them).
		if game != null and game.has_method("blast_toys"):
			var _thrown: int = game.call("blast_toys", at, radius)

	_hear(DotNpcAiSounds.Kind.COMBAT, at, BLAST_HEARD, 0.5, f.owner_id)
	_undraw(f)
	_flash(at, radius)
	detonated.emit(f.serial, at, radius)


func _in_blast(space: PhysicsDirectSpaceState3D, at: Vector3, radius: float) -> Array:
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis(), at)
	query.collide_with_areas = false

	var out: Array = []

	for result in space.intersect_shape(query, BLAST_MAX_RESULTS):
		var collider: Variant = result.get("collider")

		if collider is Node3D and not (collider is StaticBody3D) and not out.has(collider):
			out.append(collider)

	return out


func _blast(space: PhysicsDirectSpaceState3D, f: Flying, at: Vector3, radius: float, collider: Node3D) -> void:
	# A toy is the toy box's to push ([method _detonate]), never this impulse.
	if DotPropToyBox.toy_of(collider) != null:
		return

	var target := collider.global_position

	if collider is PlaygroundPlayer:
		target += Vector3.UP * 0.9

	var distance := at.distance_to(target)

	if distance > radius or not _in_sight(space, at, collider, target):
		return

	var falloff := clampf(1.0 - distance / radius, 0.0, 1.0)
	var damage := f.spawn.splash_damage * falloff

	if collider.has_method("take_damage"):
		collider.call("take_damage", damage, f.owner_id)
	elif collider is PlaygroundPlayer:
		var hurt: Variant = game.get("arena_hurt") if game != null else null
		if hurt is Callable and (hurt as Callable).is_valid():
			(hurt as Callable).call(f.owner_id, StringName(str(collider.get("player_id"))), damage, distance)

	# A breakable prop takes the blast too (`destruction`); one it breaks is not there to throw.
	if collider is RigidBody3D and game != null and game.has_method("hurt_prop"):
		var _hurt: bool = game.call("hurt_prop", collider, damage, f.owner_id)
		if not is_instance_valid(collider) or collider.is_queued_for_deletion():
			return

	if collider is RigidBody3D and not (collider as RigidBody3D).freeze:
		var away := (target - at)
		away = away.normalized() if away.length_squared() > 0.0001 else Vector3.UP
		(collider as RigidBody3D).apply_central_impulse(
			(away + Vector3.UP * 0.3).normalized() * f.spawn.splash_damage * falloff * BLAST_IMPULSE
		)


## Whether nothing static stands between the blast and [param target]. A crate between a
## grenade and a soldier takes the blast; a wall does more than that. Only static geometry
## blocks, so a blast is not stopped by the prop it is about to throw.
func _in_sight(space: PhysicsDirectSpaceState3D, at: Vector3, collider: Node3D, target: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.05, target)

	if collider is CollisionObject3D:
		query.exclude = [(collider as CollisionObject3D).get_rid()]

	var found := space.intersect_ray(query)
	return found.is_empty() or not (found["collider"] is StaticBody3D)


func _announce_danger(f: Flying) -> void:
	var reach := maxf(f.spawn.splash_radius, 1.0) + DANGER_MARGIN
	_hear(DotNpcAiSounds.Kind.DANGER, f.position, DANGER_HEARD, DANGER_SECONDS, f.owner_id, reach)


func _hear(kind: int, at: Vector3, radius: float, duration: float, owner_id: StringName, extent: float = -1.0) -> void:
	for entry in _boards:
		var board: DotNpcAiSounds = entry[0]
		var now_fn: Callable = entry[1]
		var now := float(now_fn.call()) if now_fn.is_valid() else 0.0
		var _id := board.emit(kind as DotNpcAiSounds.Kind, at, radius, now, duration, owner_id, extent)


# --- Drawing ------------------------------------------------------------------

## A small dark sphere per projectile, and a flash per blast. Cheap enough to build on a
## dedicated server too, where nobody sees it: one mesh per grenade in the air.

const BODY_COLOUR := Color(0.22, 0.26, 0.2)
const FLASH_COLOUR := Color(1.0, 0.62, 0.2)


func _draw(f: Flying) -> void:
	var mesh := SphereMesh.new()
	var r := maxf(f.spawn.radius, 0.06)
	mesh.radius = r
	mesh.height = r * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4

	var material := StandardMaterial3D.new()
	material.albedo_color = BODY_COLOUR
	mesh.material = material

	f.view = MeshInstance3D.new()
	f.view.mesh = mesh
	f.view.top_level = true
	f.view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(f.view)
	_place(f)


func _place(f: Flying) -> void:
	if f.view != null and f.view.is_inside_tree():
		f.view.global_position = f.position


func _undraw(f: Flying) -> void:
	if f.view != null and is_instance_valid(f.view):
		f.view.queue_free()
	f.view = null


func _flash(at: Vector3, radius: float) -> void:
	if not is_inside_tree():
		return

	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 16
	mesh.rings = 8

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = FLASH_COLOUR
	mesh.material = material

	var flash := MeshInstance3D.new()
	flash.mesh = mesh
	flash.top_level = true
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(flash)
	flash.global_position = at
	flash.scale = Vector3.ONE * 0.1
	_flashes.append({"node": flash, "age": 0.0, "radius": maxf(radius, 1.0), "material": material})


func _age_flashes(delta: float) -> void:
	for i in range(_flashes.size() - 1, -1, -1):
		var entry: Dictionary = _flashes[i]
		var node: MeshInstance3D = entry["node"]
		entry["age"] = float(entry["age"]) + delta
		var t := float(entry["age"]) / FLASH_SECONDS

		if t >= 1.0 or not is_instance_valid(node):
			if is_instance_valid(node):
				node.queue_free()
			_flashes.remove_at(i)
			continue

		node.scale = Vector3.ONE * float(entry["radius"]) * (0.3 + 0.7 * t)
		(entry["material"] as StandardMaterial3D).albedo_color.a = 1.0 - t


func flashes_live() -> int:
	return _flashes.size()


func describe() -> Dictionary:
	var resting := 0
	for f in _live:
		if f.resting:
			resting += 1
	return {"live": _live.size(), "resting": resting, "authority": authority}


func describe_lines() -> PackedStringArray:
	var d := describe()
	return PackedStringArray([
		"projectiles: %d live, %d resting (%s)" % [d["live"], d["resting"], "authority" if authority else "mirror"]
	])
