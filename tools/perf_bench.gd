extends DotGamePerfBench

const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## The offline sandbox benchmark: dot-game's DotGamePerfBench (flags, recording, sidecar; see it) on the playground client. Run it
## windowed with `tools/perf_bench.sh --box staging02` (gamedev, from a checkout).
## `--bots N` NPCs (wanderers, chasers, soldiers) and `--props N` props (crates, barrels, balls) dropped in a pile in front of the
## player, so the run has physics, NPC brains and draw work; `--map ID` another map first (default pg_flatgrass).

const NPC_IDS: Array[StringName] = [&"npc_wanderer", &"npc_chaser", &"npc_soldier"]
const PROP_IDS: Array[StringName] = [&"crate", &"barrel", &"beach_ball", &"plank"]

var _scratch: Variant = null


func _configure() -> void:
	client_scene = "res://game/playground.tscn"
	map = "pg_flatgrass"
	mode = "sandbox"
	bots = 8
	_scratch = PlaygroundPresentation.use_scratch_settings("perf_bench")


func _setup_client(c: Node) -> void:
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	c.set("config", config)
	c.set("fetch_content", false)
	c.set("mouse_capture_override", true)


func _select(_game: Object) -> void:
	var pg: Node = client.get("playground")
	var player: Node3D = client.get("player")
	if pg == null or player == null:
		say("no playground or player")
		return
	if map != "" and map != "pg_flatgrass":
		var changed: DotResult = pg.call("change_map", StringName(map))
		say("change_map %s: %s" % [map, "ok" if changed.ok else changed.error.message])
		await wait(3.0)
		player = client.get("player")
	var props_n := int(args.get("props", 60))
	var eye: Vector3 = player.call("eye_position")
	var ahead: Vector3 = player.call("aim_direction")
	ahead.y = 0.0
	ahead = ahead.normalized() if ahead.length() > 0.01 else Vector3.FORWARD
	var side := ahead.cross(Vector3.UP)
	var centre := eye + ahead * 10.0
	var spawner: Object = pg.get("props")
	# The spawn rate limit is for players clicking; the pile arrives in one frame, as a map's props do (PlaygroundWorld.spawn_map_props).
	var limits: Object = spawner.get("limits")
	var interval: float = limits.get("spawn_interval") if limits != null else 0.0
	if limits != null:
		limits.set("spawn_interval", 0.0)
	var made := 0
	for i in props_n:
		var at := centre + side * float(i % 6 - 3) * 1.2 + Vector3.UP * (1.0 + floorf(i / 6.0) * 1.1)
		if spawner.call("spawn", PROP_IDS[i % PROP_IDS.size()], &"map", at) != null:
			made += 1
	var npcs := 0
	for i in bots:
		var at := centre + ahead * (4.0 + float(i % 4) * 2.0) + side * (floorf(i / 4.0) - 1.0) * 3.0
		if spawner.call("spawn", NPC_IDS[i % NPC_IDS.size()], client.get("player_id"), at) != null:
			npcs += 1
	if limits != null:
		limits.set("spawn_interval", interval)
	say("spawned %d props, %d npcs" % [made, npcs])
	# `--still-figures 1`: the NPCs' people stop animating themselves, to price their animation (an ablation, not a game setting).
	if str(args.get("still-figures", "0")) == "1":
		await wait(0.5)
		var stilled := 0
		for figure: Node in pg.find_children("Figure", "", true, false):
			if "auto_animate" in figure:
				figure.set("auto_animate", false)
				stilled += 1
		say("stilled %d figures" % stilled)


func _sidecar_extra(_game: Object) -> Dictionary:
	return {"props": int(args.get("props", 60)), "npcs": bots}
