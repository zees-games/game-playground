extends SceneTree

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")

## Loads custom maps through the real game and says what their props did: how many of each
## the server put down, and every one that moved more than half a metre or fell out of the
## world in five seconds. Furniture that drifts on load, a stack that topples, a crate placed
## inside a wall and thrown out of it: none of those is a box the survey reads.
##
##   godot --headless --path . --script tools/map_props.gd -- pgc_town pgc_site
##   godot --headless --path . --script tools/map_props.gd          # every maps/custom/*.json

const SETTLE_TICKS := 128 * 5

var _game: Playground
var _maps: Array = []
var _i := 0
var _f := 0
var _start := {}
var _failed := false


func _initialize() -> void:
	_maps = OS.get_cmdline_user_args()
	if _maps.is_empty():
		for file in DirAccess.get_files_at("res://maps/custom"):
			if file.ends_with(".json"):
				_maps.append(file.get_basename())
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.initial_map = &"pg_flatgrass"
	config.map_seconds = 0.0
	_game = Playground.new()
	_game.config = config
	root.add_child(_game)


func _physics_process(_d: float) -> bool:
	_f += 1
	if _f == 10:
		# Not awaited: a frame callback cannot wait, and the props are checked ticks later.
		_game.change_map(StringName(_maps[_i]))
	if _f == 14:
		_start.clear()
		for p in _game.props.props_of(_game.MAP_OWNER):
			_start[p.instance_id] = (p.node as Node3D).global_position
	if _f == 14 + SETTLE_TICKS:
		var counts := {}
		var moved: PackedStringArray = []
		for p in _game.props.props_of(_game.MAP_OWNER):
			counts[String(p.def.id)] = int(counts.get(String(p.def.id), 0)) + 1
			var now := (p.node as Node3D).global_position
			var from: Vector3 = _start.get(p.instance_id, now)
			if now.distance_to(from) > 0.5 or now.y < -40.0:
				moved.append("%s %s -> %s" % [p.def.id, from.snapped(Vector3.ONE * 0.1), now.snapped(Vector3.ONE * 0.1)])
		print("%s: %d props %s" % [_maps[_i], _start.size(), str(counts)])
		for line in moved:
			print("  MOVED %s" % line)
		_failed = _failed or not moved.is_empty()
		_i += 1
		_f = 0
		if _i >= _maps.size():
			quit(1 if _failed else 0)
			return true
	return false
