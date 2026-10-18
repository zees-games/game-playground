extends SceneTree

## The third-person camera (dot-player-controller's orbit rig on dot-core's boom) flown round
## the walls of every built-in map, armed; `mp_solidplayers` both ways with two players
## walked into each other; `mp_forceview` through the view rules the client asks. Headless:
##
##   godot --headless --path . --script tools/camera_check.gd
##
## The two views themselves are drawn by `tools/screenshot_views.sh` (view_first_person,
## view_third_person).

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")

var _game: Playground = null
var _failed := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DotFpsSampler.register_default_actions()
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.initial_map = &"pg_flatgrass"
	config.map_seconds = 0.0
	_game = Playground.new()
	_game.name = "Playground"
	_game.config = config
	root.add_child(_game)
	_run.call_deferred()


func _run() -> void:
	while _game.maps == null or _game.maps.current == null:
		await process_frame
	for i in 6:
		await physics_frame

	var tunables := DotTpsTunables.new()
	var offset := Vector3(tunables.shoulder_offset, 0.0, tunables.camera_distance)
	var mask: int = _game.player_stack.physics.layout.mask_of([&"world", &"prop"])
	var pivots := DotCameraCheck.pivots_near_walls(root.get_world_3d(), AABB(Vector3(-80, -20, -80), Vector3(160, 60, 160)), mask, tunables.camera_height, 3.0, 3.0, 40)
	var got := {}
	for pivot in pivots:
		got = DotCameraCheck.add(got, DotCameraCheck.fly(root.get_world_3d(), DotCameraCheck.orbit_path(pivot), offset, mask))
	_check(not got.is_empty() and DotCameraCheck.passed(got), "third person round %d places by the walls of %s: %s" % [pivots.size(), String(_game.maps.current.id) if "id" in _game.maps.current else "the map", DotCameraCheck.summary(got) if not got.is_empty() else "no places"])

	var view := _game.view_rules
	_check(view.may_toggle() and view.toggled(false), "the view key may go to third person by default")
	view.force_view = DotPlayerViewRules.FIRST_ONLY
	_check(not view.toggled(false), "mp_forceview 1 refuses it")
	view.force_view = DotPlayerViewRules.ANY

	var a := _game.add_player(&"a", "A")
	var b := _game.add_player(&"b", "B")
	for i in 4:
		await physics_frame
	var loose := await _walk(a, b, false)
	var solid := await _walk(a, b, true)
	_check(solid > 0.6 and solid < 1.0, "mp_solidplayers 1: walking into another player stops at them (closest %.2f m apart)" % solid)
	_check(loose < 0.3, "armed: mp_solidplayers 0, the same walk goes through them (closest %.2f m)" % loose)

	print("all passed" if not _failed else "FAILED")
	quit(1 if _failed else 0)


## A walks at B, held still, for a second and a half; the closest their axes came.
func _walk(a: PlaygroundPlayer, b: PlaygroundPlayer, solid: bool) -> float:
	_game.body_rules.solid = solid
	var spot := b.controller.state.position
	var from := spot + Vector3(0.0, 0.0, 2.6)
	a.controller.teleport(from, 0.0, 0.0)
	var go := DotFpsCommand.new()
	go.yaw = 0.0
	go.move = Vector2(0, 1)
	var closest := INF
	for i in 90:
		b.controller.teleport(spot, NAN, NAN)
		a.controller.apply_command(go)
		await physics_frame
		var at := a.controller.state.position
		closest = minf(closest, Vector2(at.x - spot.x, at.z - spot.z).length())
	print("    %s: closest %.2f m" % ["solid" if solid else "pass-through", closest])
	return closest


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed = true
