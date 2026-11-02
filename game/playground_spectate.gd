extends DotSpectatorHost

const Playground := preload("playground.gd")
const PlaygroundArena := preload("playground_arena.gd")
const PlaygroundPlayer := preload("playground_player.gd")

## Watching somebody else build, or fight, or drive into a wall.
##
## [b]A sandbox is the one place where watching is not about being dead.[/b] The
## interesting thing on a physics-sandbox server is usually what somebody else is making,
## and the answer to "what is that noise in the corner" is a camera. So the policy here
## is the loosest of the three games that have one: anybody, alive or dead, may watch
## anybody, and roaming is on — a free camera is how you look at a contraption from the
## outside, which is the whole reason to look at one.
##
## It tightens the moment the arena is on. A living player watching a living one while
## they are shooting at each other is a wallhack, and `PlaygroundArena` turning on is
## exactly the moment that stops being a sandbox.

const CHANNEL := "playground.spectate"

var game: Playground = null

## The arena, when the module has built one. Null on a plain sandbox.
##
## Held rather than reached for through the game: a layer that went looking for it through
## `Playground` would find nothing, which reads as "nobody is ever dead".
var arena: PlaygroundArena = null

var _fighting: bool = false


## Binds the game and builds the manager. [method setup] itself takes no game.
func bind(p_game: Playground) -> DotResult:
	game = p_game
	authoritative = game.authoritative
	tick_rate = game.tick_rate
	chase_distance = 4.5
	chase_height = 1.4
	history_seconds = 4.0
	eye_height = 1.6
	_apply_fighting(false)

	var res := setup()
	if not res.ok:
		return res.wrap("playground spectate")

	if not game.player_removed.is_connected(_on_player_removed):
		game.player_removed.connect(_on_player_removed)

	return DotResult.success(null)


func _channel() -> String:
	return CHANNEL


func _apply_fighting(fighting: bool) -> void:
	_fighting = fighting
	var seconds := 1.0 if fighting else 0.0
	death_cam_seconds = seconds
	freeze_cam_seconds = seconds


func _tune_rules(r: DotSpectatorRules) -> DotSpectatorRules:
	r.force_camera = 1 if _fighting else 0
	r.allow_while_alive = not _fighting
	r.allow_roaming = not _fighting
	r.cycle_includes_dead = not _fighting
	return r


## The arena went on or off; the camera policy is re-derived whole, not patched by field.
func set_fighting(fighting: bool) -> void:
	if manager == null:
		return
	_apply_fighting(fighting)
	manager.rules = tune_rules(DotSpectatorRules.new())
	var res := manager.setup()
	if not res.ok:
		DotLog.warn(CHANNEL, "the camera policy was refused", {
			"why": res.error.message
		})


func _participants() -> PackedStringArray:
	var out := PackedStringArray()
	var ids: Array = game.players.keys()
	ids.sort()
	for id: Variant in ids:
		out.append(String(id))
	return out


## The side they are actually on: dot-spectate reads 0 as "no team", and the stack is
## built before anything can spectate.
func _team_of(key: String) -> int:
	return game.player_stack.team_index_of(key) if game.player_stack != null else 0


func _is_alive(key: String) -> bool:
	if arena == null or not arena.enabled:
		return true
	var health := arena.health_of(StringName(key))
	return health == null or health.alive


func _pose_of(key: String) -> Transform3D:
	var player: PlaygroundPlayer = game.players.get(StringName(key), null)
	if player == null or player.controller == null:
		return Transform3D.IDENTITY
	var state := player.controller.state
	return eye_pose(state.position, state.pitch, state.yaw)


func _current_tick() -> int:
	return game.current_tick()


func tick(_delta: float) -> void:
	advance_live()


func target_of(viewer: StringName) -> StringName:
	return StringName(watching(String(viewer)))


func on_death(victim: StringName, at: Vector3, by: StringName) -> void:
	death(String(victim), at, String(by))


func on_spawn(id: StringName) -> void:
	spawned(String(id))


func _on_player_removed(id: StringName) -> void:
	left(String(id))
