extends RefCounted

const Playground := preload("playground.gd")
const PlaygroundArena := preload("playground_arena.gd")
const PlaygroundPlayer := preload("playground_player.gd")

## What dot-moderation's live tools mean in a sandbox that may carry a run timer.
##
## Movement is `DotFpsAdminModifiers`, so the owning client predicts it. Health belongs to
## the arena layer and exists only while `pg_arena` is on, so god, buddha, hp and slay say
## "not on this server" when it is off rather than being absent — whether they mean
## anything is a cvar, not a build. A run belongs to the timer when a server links one
## ([code]addons/pg_timer[/code]), and its rule is that an admin's help can never make a time. Noclip abandons the run
## in progress, `PlaygroundPlayer` taints any run made while noclipped or on a speed or
## gravity step, and a teleport by an admin ends the run.
##
## Blind and beacon are the two that are about a SCREEN rather than a body, and each is one
## flag on [PlaygroundPlayer] that `PlaygroundPlayerNet` replicates — the blind to its owner
## alone, the beacon to everybody — and that the client draws: `PlaygroundHud` blacks the
## owner's screen out, `DotFxBeacon` rings the player on every screen and pings. The
## server decides; nothing about either is a client's to choose. Neither touches the timer:
## a blinded run is harder, not assisted, and a beacon is a thing other people see.
##
## [b]Both outlive a respawn here without being told to[/b], and so does everything else:
## a respawn in this game — the admin's, the course's, the arena's — is a teleport of the
## same body (`Playground.spawn_player`), so nothing a handler set on the player is lost
## and `DotModTools.respawned` is never called. That is the right answer for blind and
## beacon, which are about the person rather than the body, and a death is exactly what a
## player being punished would otherwise use to end one.

## Ids are the session userid as a string; this game's player key is `u<userid>`.
static func key_of(id: StringName) -> StringName:
	return StringName("u%s" % String(id))


static func handlers(game: Playground, arena: PlaygroundArena) -> Dictionary:
	return {
		DotModTools.ACTION_NOCLIP: func(id: StringName, args: Dictionary) -> DotResult:
			var p := _player(game, id)
			if p == null:
				return _absent(id)
			var on := bool(args["on"])
			if on:
				p.stop_run(&"noclip")
			return DotFpsAdminModifiers.set_noclip(p.controller, on),

		DotModTools.ACTION_FREEZE: func(id: StringName, args: Dictionary) -> DotResult:
			var p := _player(game, id)
			return _absent(id) if p == null else DotFpsAdminModifiers.set_frozen(p.controller, bool(args["on"])),

		DotModTools.ACTION_SPEED: func(id: StringName, args: Dictionary) -> DotResult:
			var p := _player(game, id)
			return _absent(id) if p == null else DotFpsAdminModifiers.set_speed(p.controller, float(args["scale"])),

		DotModTools.ACTION_GRAVITY: func(id: StringName, args: Dictionary) -> DotResult:
			var p := _player(game, id)
			return _absent(id) if p == null else DotFpsAdminModifiers.set_gravity(p.controller, float(args["scale"])),

		DotModTools.ACTION_RESPAWN: func(id: StringName, _args: Dictionary) -> DotResult:
			if _player(game, id) == null:
				return _absent(id)
			game.spawn_player(key_of(id))
			return DotResult.success(null),

		DotModTools.ACTION_RENAME: func(id: StringName, args: Dictionary) -> DotResult:
			var p := _player(game, id)
			if p == null:
				return _absent(id)
			p.display_name = str(args["name"]).strip_edges().substr(0, 32)
			return DotResult.success(p.display_name),

		DotModTools.ACTION_GOD: func(id: StringName, args: Dictionary) -> DotResult:
			var health := _health(arena, id)
			if health == null:
				return _no_health()
			health.invulnerable = bool(args["on"])
			return DotResult.success(health.invulnerable),

		DotModTools.ACTION_BUDDHA: func(id: StringName, args: Dictionary) -> DotResult:
			var health := _health(arena, id)
			if health == null:
				return _no_health()
			health.cannot_die = bool(args["on"])
			return DotResult.success(health.cannot_die),

		DotModTools.ACTION_HEALTH: func(id: StringName, args: Dictionary) -> DotResult:
			var health := _health(arena, id)
			if health == null:
				return _no_health()
			if not health.alive:
				return DotResult.fail(DotError.CODE_STATE, "They are dead.")
			health.health = minf(float(args["value"]), 250.0)
			return DotResult.success(health.health),

		DotModTools.ACTION_SLAY: func(id: StringName, _args: Dictionary) -> DotResult:
			var health := _health(arena, id)
			if health == null:
				return _no_health()
			if not health.alive:
				return DotResult.fail(DotError.CODE_STATE, "They are already dead.")
			var was_god := health.invulnerable
			var was_buddha := health.cannot_die
			health.invulnerable = false
			health.cannot_die = false
			health.invulnerable_until_tick = -1
			var damage := arena.hurt(&"", key_of(id), health.health + 1000.0, 0.0, DotHitGroup.CHEST, true)
			health.invulnerable = was_god
			health.cannot_die = was_buddha
			if damage == null or not damage.lethal:
				return DotResult.fail(DotError.CODE_STATE, "The slay was refused.",
					damage.refusal if damage != null else "")
			return DotResult.success(null),

		DotModTools.ACTION_SLAP: func(id: StringName, args: Dictionary) -> DotResult:
			var p := _player(game, id)
			if p == null:
				return _absent(id)
			# A shove is movement, which every server here has; the damage is the arena's.
			p.controller.state.velocity += Vector3(3.0, 5.0, 3.0)
			p.controller.state.mode = DotFpsState.Mode.AIR
			# Speed nobody earned: an admin's help, which a course time must not carry.
			p.taint_run()
			var amount := float(args.get("damage", 0.0))
			if amount > 0.0 and _health(arena, id) != null:
				var _hurt := arena.hurt(&"", key_of(id), amount, 0.0, DotHitGroup.CHEST, true)
			return DotResult.success(null),

		DotModTools.ACTION_BLIND: func(id: StringName, args: Dictionary) -> DotResult:
			var p := _player(game, id)
			if p == null:
				return _absent(id)
			# The screen and nothing else. A blinded player still moves, builds and runs
			# the course; an admin who wants them to stop as well has freeze, and one verb
			# that did both would be a verb nobody could use for only the first.
			p.blinded = bool(args["on"])
			return DotResult.success(p.blinded),

		DotModTools.ACTION_BEACON: func(id: StringName, args: Dictionary) -> DotResult:
			var p := _player(game, id)
			if p == null:
				return _absent(id)
			p.beacon = bool(args["on"])
			return DotResult.success(p.beacon),
	}


static func unsupported() -> Dictionary:
	return {
		DotModTools.ACTION_GIVE: "what a player holds here is the physics gun, the gravity gun and a loadout they choose",
		DotModTools.ACTION_STRIP: "a sandbox player without the physics gun has no game",
		DotModTools.ACTION_BURN: "nothing here burns a player",
	}


static func position_of(game: Playground, id: StringName) -> Variant:
	var p := _player(game, id)
	return p.controller.state.position if p != null and not p.riding else null


## An admin moving somebody is a player leaving the course, so the run ends.
static func teleport(game: Playground, id: StringName, to: Variant) -> void:
	var p := _player(game, id)

	if p == null or p.riding or not (to is Vector3):
		return

	# `teleport` stops a run itself.
	p.teleport(to as Vector3, p.controller.state.yaw)


static func _player(game: Playground, id: StringName) -> PlaygroundPlayer:
	return game.players.get(key_of(id)) if game != null else null


static func _health(arena: PlaygroundArena, id: StringName) -> DotHealth:
	if arena == null or not arena.enabled:
		return null
	return arena.health_of(key_of(id))


static func _absent(id: StringName) -> DotResult:
	return DotResult.fail(DotError.CODE_STATE, "Player %s is not in the world." % String(id))


static func _no_health() -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED,
		"The arena is off, so nobody has health.",
		"pg_arena on"
	)
