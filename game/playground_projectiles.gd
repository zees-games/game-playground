extends Node3D

const PlaygroundPlayer := preload("playground_player.gd")
const PlaygroundGrenades := preload("playground_grenades.gd")
const PlaygroundZee := preload("playground_zee.gd")

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
## [b]A fused grenade is arena_weapons' [AwGrenade], and every blast is its [AwGrenadeBlast].[/b]
## This layer only supplies the world: the swept ray, the thrower's grace, what a crate does
## to a stuck grenade, and who stands in the splash. Bounce, stick and fuse are the addon's,
## tuned by `sv_grenade_*`.
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
	## Null for a rocket: it flies straight and goes off on the first thing it meets.
	var grenade: AwGrenade = null
	## Bounces so far, the grenade's count (0 for a rocket).
	var bounces: int:
		get: return grenade.bounces if grenade != null else 0
	## What the last sweep met, for [member stuck_to].
	var last_hit: Dictionary = {}
	var view: MeshInstance3D = null


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

## `sv_grenade_*`: bounce, friction and how long smoke, fire and a flash last.
var rules := AwGrenadeRules.new()

## What a utility grenade leaves behind: smoke, fire and blindness. Built with this layer.
var effects: PlaygroundGrenades = null

## A smoke cloud, a fire or a blind to draw, as [method AwGrenadeFx.show] reads it: from this
## end's own blast offline, from the server's word on a client. A dedicated server has no listener.
signal utility(info: Dictionary)

var _live: Array[Flying] = []
## The thrower's own launches flown before the server said (negative serials), until it does.
var _predicted: Array[Flying] = []
var _next_predicted: int = -1
var _next_serial: int = 1
var _gravity: float = 9.8
var _flashes: Array = []
## serial -> `{fx, seconds}` of a smoke or fire that went off, until the bridge sends it.
var _told: Dictionary = {}

## A projectile left a weapon. What the server tells clients about.
signal launched(flying: Flying)

## One went off at [param at]. On a client, when the server said so.
signal detonated(serial: int, at: Vector3, radius: float)


func _init() -> void:
	name = "Projectiles"
	effects = PlaygroundGrenades.new()
	effects.bind(self)
	effects.effect.connect(utility.emit)
	add_child(effects)
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

	if spawn.fuse_ticks > 0 or spawn.velocity == Vector3.ZERO:
		f.grenade = AwGrenade.from_spawn(spawn, _def_of(spawn), rules)
		f.grenade.sticks = f.sticks

	_live.append(f)
	_draw(f)
	launched.emit(f)
	return f


## A client flies its own throw now rather than after the round trip. [method launch_told] adopts it.
func predict(spawn: DotWeaponSpawn, owner_id: StringName, owner_rid: RID = RID()) -> Flying:
	var f := launch(spawn, owner_id, owner_rid)
	f.serial = _next_predicted
	_next_predicted -= 1
	_predicted.append(f)
	return f


## The server's launch on a client. [param mine] adopts the thrower's predicted copy of the same
## spawn (taking the server's serial) instead of flying a second one.
func launch_told(spawn: DotWeaponSpawn, owner_id: StringName, serial: int, mine: bool) -> Flying:
	if mine:
		for i in _predicted.size():
			var p := _predicted[i]
			if p.spawn.id == spawn.id and _live.has(p):
				_predicted.remove_at(i)
				p.serial = serial
				return p

	return launch(spawn, owner_id, RID(), serial)


## A prediction the server never confirmed (it refused the throw) goes after two seconds.
func _expire_predicted(rate: int) -> void:
	for i in range(_predicted.size() - 1, -1, -1):
		var p := _predicted[i]

		if p.age_ticks > rate * 2 or not _live.has(p):
			_undraw(p)
			_live.erase(p)
			_predicted.remove_at(i)


func _sticks(spawn: DotWeaponSpawn) -> bool:
	if spawn.meta.has(&"sticks"):
		return bool(spawn.meta[&"sticks"])

	var def := _def_of(spawn)
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


## Each live projectile as a launch a joining client can fly on from where it is now: `{serial, spawn, owner_id, sticks}`,
## with the fuse and life left rather than the ones it left the hand with.
func join_launches() -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	for f in _live:
		var s := DotWeaponSpawn.new()
		s.id = f.spawn.id
		s.origin = f.position
		s.velocity = f.velocity
		s.gravity_scale = f.spawn.gravity_scale
		s.radius = f.spawn.radius
		s.splash_radius = f.spawn.splash_radius
		s.fuse_ticks = maxi(f.grenade.fuse, 0) if f.grenade != null else 0
		s.life_ticks = maxi(f.spawn.life_ticks - f.age_ticks, 1)
		out.append({"serial": f.serial, "spawn": s, "owner_id": f.owner_id, "sticks": f.sticks})

	return out


## Takes everything out of the air without detonating any of it. For a map change: the
## geometry they are flying through is about to stop existing.
func clear() -> void:
	for f in _live:
		_undraw(f)

	_live.clear()
	_predicted.clear()
	_told.clear()
	effects.clear()


## One tick: fly, bounce, stick, detonate what is due, and announce the danger.
##
## Iterated backwards so a detonation can remove its own entry without skipping the next.
func tick(delta: float) -> void:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	var rate := maxi(roundi(1.0 / delta), 1)
	_expire_predicted(rate)

	for i in range(_live.size() - 1, -1, -1):
		var f: Flying = _live[i]
		f.age_ticks += 1

		if f.grenade != null:
			if _fly_grenade(space, f, rate) and authority:
				_detonate(f, f.position)
				_live.remove_at(i)
				continue
		elif _fly_rocket(space, f, delta) and authority:
			_detonate(f, f.position)
			_live.remove_at(i)
			continue

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

	effects.tick(delta)
	_age_flashes(delta)


## A client's half of a detonation: the server said serial [param serial] went off at
## [param at]. The local copy goes and the flash is drawn where the server put it.
func detonate_remote(serial: int, at: Vector3, radius: float, fx: int = 0, seconds: float = 0.0) -> void:
	for i in range(_live.size() - 1, -1, -1):
		if _live[i].serial == serial:
			_undraw(_live[i])
			_live.remove_at(i)
			break

	_flash(at, radius)

	# The wire's fx is [enum AwUtilityZones.Fx] plus one, so 0 is a blast that leaves nothing.
	if fx > 0:
		utility.emit({"fx": fx - 1, "position": at, "radius": radius, "seconds": seconds, "victim": 0})

	detonated.emit(serial, at, radius)


## The server said this client was blinded for [param seconds]. Only ever the local player.
func blind_remote(seconds: float, strength: float = 1.0) -> void:
	utility.emit({"fx": AwUtilityZones.Fx.BLIND, "position": Vector3.ZERO, "radius": 0.0, "seconds": seconds, "victim": 0, "strength": strength})


## What serial [param serial]'s smoke or fire told, once: `{fx, seconds}` with fx as on the wire, else empty.
func take_told(serial: int) -> Dictionary:
	var told: Dictionary = _told.get(serial, {})
	var _gone := _told.erase(serial)
	return told


## One step of a fused projectile by [AwGrenade]. True when its fuse has run out. A client's
## copy goes on past that, because only the server's DETONATE ends it.
func _fly_grenade(space: PhysicsDirectSpaceState3D, f: Flying, rate: int) -> bool:
	var g := f.grenade
	var was_stuck := g.stuck
	var done := g.step(_tracer(space, f), rate)

	if g.stuck and not was_stuck:
		_stick_to(f)

	if g.stuck and f.stuck_to != null:
		_follow(f)

	f.position = g.position
	f.velocity = g.velocity
	f.resting = g.stuck or (g.bounces > 0 and g.velocity == Vector3.ZERO)
	return done


## A rocket: straight, and off on the first thing it meets. True when it did, and a client's
## stops there to wait for the server.
func _fly_rocket(space: PhysicsDirectSpaceState3D, f: Flying, delta: float) -> bool:
	if f.resting:
		return false

	if f.spawn.gravity_scale > 0.0:
		f.velocity.y -= _gravity * f.spawn.gravity_scale * delta

	var step := f.velocity * delta
	var hit := _cast(space, f, f.position, f.position + step, 1)

	if hit.is_empty():
		f.position += step
		return false

	f.position = hit["position"]

	if not authority:
		f.velocity = Vector3.ZERO
		f.resting = true
		return false

	return true


## Stuck to a crate it rides the crate, and stuck to a person it is on the person.
func _stick_to(f: Flying) -> void:
	var collider: Variant = f.last_hit.get("collider")

	if collider is Node3D and not (collider is StaticBody3D):
		f.stuck_to = collider as Node3D
		f.stuck_offset = f.grenade.position - f.stuck_to.global_position


func _follow(f: Flying) -> void:
	if not is_instance_valid(f.stuck_to) or not f.stuck_to.is_inside_tree():
		# What it stuck to is gone. It falls from where it was rather than hanging in air.
		f.stuck_to = null
		f.grenade.stuck = false
		return

	f.grenade.position = f.stuck_to.global_position + f.stuck_offset


## [AwGrenade]'s world: a ray that remembers what it met, and skips the thrower at first.
func _tracer(space: PhysicsDirectSpaceState3D, f: Flying) -> Callable:
	return func(from: Vector3, to: Vector3) -> Dictionary:
		f.last_hit = _cast(space, f, from, to, THROWER_GRACE_TICKS)
		return f.last_hit


func _cast(space: PhysicsDirectSpaceState3D, f: Flying, from: Vector3, to: Vector3, grace: int) -> Dictionary:
	if space == null or from == to:
		return {}

	var query := PhysicsRayQueryParameters3D.create(from, to)

	if f.owner_rid.is_valid() and f.age_ticks <= grace:
		query.exclude = [f.owner_rid]

	return space.intersect_ray(query)


## What a blast does, on the authority. [AwGrenadeBlast] decides who is hurt, blinded or
## burned (linear falloff, nothing through cover); this applies it: an armed NPC through
## `take_damage`, a player through the arena (unset when the arena is off, so nobody dies in
## a sandbox), a loose prop shoved away from the centre. The thrower is not spared.
func _detonate(f: Flying, at: Vector3) -> void:
	var def := _blast_def(f)
	var radius := float(def.params.get(&"effect_radius", f.spawn.splash_radius))
	var space := get_world_3d().direct_space_state if is_inside_tree() else null

	if space != null and radius > 0.0:
		var colliders := colliders_in(at, radius)
		var g := f.grenade if f.grenade != null else AwGrenade.from_spawn(f.spawn, def, rules)
		g.position = at
		var events := AwGrenadeBlast.detonate(g, def, _victims(colliders), _clear_to.bind(space, at))
		_apply(events, colliders, f, at)

		if AwUtilityZones.is_utility(def):
			var told := effects.detonate(g, def, f.owner_id, radius)
			if not told.is_empty():
				_told[f.serial] = {"fx": int(told["fx"]) + 1, "seconds": float(told["seconds"])}

		# Map panes too (glass), which the blast's shape query does not return: they are world.
		if game != null and game.has_method("hurt_panes_in"):
			game.call("hurt_panes_in", at, radius, f.spawn.splash_damage, f.owner_id)
		# And the map's toys, by dot-props' own blast: a damage-sized impulse sends a beach
		# ball off at a hundred metres a second (see [method _apply], which skips them).
		if game != null and game.has_method("blast_toys"):
			var _thrown: int = game.call("blast_toys", at, radius)

	_hear(DotNpcAiSounds.Kind.COMBAT, at, BLAST_HEARD, 0.5, f.owner_id)
	_undraw(f)
	_flash(at, radius)
	detonated.emit(f.serial, at, radius)


## The definition [AwGrenadeBlast] reads: the weapon's own params (`kind`, `effect_radius`) over
## the splash this spawn carries, which is what the weapon's modifiers left of it.
func _blast_def(f: Flying) -> DotWeaponDef:
	var def := DotWeaponDef.new()
	def.id = f.spawn.id
	var source := _def_of(f.spawn)

	if source != null:
		def.params = source.params

	var b := DotWeaponBallistics.new()
	b.splash_radius = f.spawn.splash_radius
	b.splash_damage = f.spawn.splash_damage
	def.tuning = b
	return def


## The weapon definition behind [param spawn], from this game's catalogue or a pack's.
func _def_of(spawn: DotWeaponSpawn) -> DotWeaponDef:
	var def: DotWeaponDef = catalogue.get_def(spawn.id) if catalogue != null else null
	return def if def != null else PlaygroundZee.pack_def(spawn.id)


## What a blast can reach: bodies that are not the map, and not a toy, which is the toy box's.
func colliders_in(at: Vector3, radius: float) -> Array:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	var out: Array = []

	if space == null:
		return out

	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis(), at)
	query.collide_with_areas = false

	for result in space.intersect_shape(query, BLAST_MAX_RESULTS):
		var collider: Variant = result.get("collider")

		if collider is Node3D and not (collider is StaticBody3D) and not out.has(collider) \
				and DotPropToyBox.toy_of(collider) == null:
			out.append(collider)

	return out


func _victims(colliders: Array) -> Array:
	var out: Array = []

	for i in colliders.size():
		var body: Node3D = colliders[i]
		var target := _centre(body)
		out.append({"id": i, "position": target, "eye": target, "forward": -body.global_basis.z})

	return out


func _centre(body: Node3D) -> Vector3:
	return body.global_position + (Vector3.UP * 0.9 if body is PlaygroundPlayer else Vector3.ZERO)


## Whether nothing static stands between the blast and [param to]. A crate between a
## grenade and a soldier takes the blast; a wall does more than that. Only static geometry
## blocks, so a blast is not stopped by the prop it is about to throw.
func _clear_to(_from: Vector3, to: Vector3, space: PhysicsDirectSpaceState3D, at: Vector3) -> bool:
	var found := space.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.05, to))
	return found.is_empty() or not (found["collider"] is StaticBody3D)


func _apply(events: Array[Dictionary], colliders: Array, f: Flying, at: Vector3) -> void:
	for event in events:
		var index := int(event.get("victim", -1))

		if index < 0 or index >= colliders.size() or not is_instance_valid(colliders[index]):
			continue

		var body: Node3D = colliders[index]

		match String(event["event"]):
			"damage":
				hurt(body, float(event["damage"]), f.owner_id, at.distance_to(_centre(body)))
				_shove(body, float(event["damage"]), at)


## Damage to [param body] from [param owner_id]: an armed NPC takes it, a player takes it through
## the arena, a breakable prop takes it as a prop.
func hurt(body: Node3D, damage: float, owner_id: StringName, distance: float) -> void:
	if body.has_method("take_damage"):
		body.call("take_damage", damage, owner_id)
	elif body is PlaygroundPlayer:
		var arena: Variant = game.get("arena_hurt") if game != null else null
		if arena is Callable and (arena as Callable).is_valid():
			(arena as Callable).call(owner_id, StringName(str(body.get("player_id"))), damage, distance)

	if body is RigidBody3D and game != null and game.has_method("hurt_prop"):
		var _hurt: bool = game.call("hurt_prop", body, damage, owner_id)


func _shove(body: Node3D, damage: float, at: Vector3) -> void:
	# One a breakable prop broke is not there to throw.
	if not is_instance_valid(body) or body.is_queued_for_deletion():
		return

	if body is RigidBody3D and not (body as RigidBody3D).freeze:
		var away := _centre(body) - at
		away = away.normalized() if away.length_squared() > 0.0001 else Vector3.UP
		(body as RigidBody3D).apply_central_impulse((away + Vector3.UP * 0.3).normalized() * damage * BLAST_IMPULSE)


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
