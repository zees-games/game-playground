extends Node

const PlaygroundNetBridge := preload("../game/net/playground_net_bridge.gd")
const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPlatform := preload("../game/playground_platform.gd")

## Headless dedicated playground with sv_maxplayers raised; prints one STAT line per second
## for tools/load_swarm.gd's clients to be measured against (driver: tools/load100.sh).
## [code]phys_ms[/code] is the whole physics frame, so phys minus tick is physics and the rest.

const CHANNEL := "load_server"

var server: DotServer = null
var game: Playground = null
var platform: PlaygroundPlatform = null
var module: Object = null

var _samples: PackedFloat64Array = PackedFloat64Array()
var _phys: PackedFloat64Array = PackedFloat64Array()
var _last := {}
var _costs := {}
var _sim_usec := 0.0
var _send_usec := 0.0
var _tick_n := 0
var _second_at := 0.0
var _cpu_last := 0.0
var _wall_last := 0.0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	DotFrameCost.enabled = true
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _run() -> void:
	var dir := ProjectSettings.globalize_path("user://load_server")
	DotPaths.remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var slots := int(_arg("--slots", "128"))

	var config := DotServerConfig.new()
	config.autoexec_config = ""
	config.hostname = "load test"
	config.max_players = slots
	config.hibernate_when_empty = false
	config.rcon_password = ""
	config.query_enabled = false
	config.port = int(_arg("--port", "27399"))
	config.admins_path = "%s/admins.json" % dir
	config.bans_path = "%s/bans.json" % dir
	config.audit_log_path = "%s/audit.jsonl" % dir
	config.stdin_console_enabled = false

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)
	for _i in 60:
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	# The hardcoded 10-burst, 2/s per-address connect limit would refuse a swarm that shares 127.0.0.1
	# (a LAN party behind one NAT meets the same wall; filed with the results).
	server._connect_limiter = DotRateLimiter.new(10000.0, 10000.0)
	# server.cfg sets sv_maxplayers 32 after boot and wins over config.max_players.
	var slots_cvar: DotConVar = server.console.find_cvar("sv_maxplayers")
	if slots_cvar != null:
		slots_cvar.set_value(str(slots))

	var pg_config := PlaygroundConfig.new()
	pg_config.records_directory = ""
	pg_config.initial_map = &"pg_flatgrass"
	pg_config.map_seconds = 0.0
	game = Playground.new()
	game.name = "Playground"
	game.config = pg_config
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame

	platform = PlaygroundPlatform.new()
	platform.name = "Identity"
	platform.directory = "%s/identity" % dir
	add_child(platform)
	var _identity: DotResult = await platform.setup()
	var _p: DotResult = await server.modules.load_module("res://addons/dot_platform/dot_platform_module.gd")
	(load("res://game/playground_module.gd") as GDScript).set("punishments_path", "%s/punishments.json" % dir)
	var loaded: DotResult = await server.modules.load_module("res://game/playground_module.gd")
	for n in server.modules.loaded_names():
		var m: Object = server.modules.get_module(n)
		if m != null and m.get("net") != null:
			module = m
	var tuned: DotNetManager = module.get("net") if module != null else null
	if tuned != null:
		tuned.config.snapshot_workers = int(_arg("--workers", "0"))
		var far_every := int(_arg("--far-every", "1"))
		if far_every > 1 and tuned.interest is DotNetInterestDistance:
			(tuned.interest as DotNetInterestDistance).far_every = far_every
			(tuned.interest as DotNetInterestDistance).far_distance = float(_arg("--far-distance", "40"))
	var cvar: DotConVar = server.console.find_cvar("sv_maxplayers")
	print("load_server: module loaded=%s port=%d slots=%d sv_maxplayers=%s" % [
		loaded.ok, config.port, slots, cvar.get_int() if cvar != null else "?"])
	_second_at = Time.get_ticks_msec() / 1000.0
	_cpu_last = _cpu_seconds()
	_wall_last = _second_at


func _cpu_seconds() -> float:
	var out := []
	OS.execute("cat", ["/proc/%d/stat" % OS.get_process_id()], out)
	var line: String = out[0] if not out.is_empty() else ""
	if line.rfind(")") < 0:
		return 0.0
	var rest := line.substr(line.rfind(")") + 2).split(" ")
	return (float(rest[11]) + float(rest[12])) / 100.0


func _rss_mb() -> float:
	var out := []
	OS.execute("cat", ["/proc/%d/statm" % OS.get_process_id()], out)
	var parts: PackedStringArray = (out[0] as String).split(" ") if not out.is_empty() else PackedStringArray()
	return float(parts[1]) * 4096.0 / 1048576.0 if parts.size() > 1 else 0.0


func _p(values: PackedFloat64Array, q: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[mini(sorted.size() - 1, int(q * sorted.size()))]


func _physics_process(_delta: float) -> void:
	_gather_costs()
	if module == null:
		return
	var net: DotNetManager = module.get("net")
	if net == null:
		return
	# The swarm cannot say READY (that needs the game's message schema on its end), so the
	# harness admits each seated peer, which is all the request does.
	var bridge: PlaygroundNetBridge = module.get("bridge")
	if bridge != null:
		for pid in bridge._player_of_peer.keys():
			if not bridge._ready_peers.has(pid):
				bridge._admit(pid)
	var c := net.perf_counters()
	if not _last.is_empty():
		var ticks: int = int(c[&"server_ticks"]) - int(_last[&"server_ticks"])
		if ticks > 0:
			var usec: float = (float(c[&"server_sim_usec"]) - float(_last[&"server_sim_usec"])
				+ float(c[&"server_send_usec"]) - float(_last[&"server_send_usec"]))
			_samples.append(usec / ticks / 1000.0)
			_sim_usec += float(c[&"server_sim_usec"]) - float(_last[&"server_sim_usec"])
			_send_usec += float(c[&"server_send_usec"]) - float(_last[&"server_send_usec"])
			_tick_n += ticks
			_phys.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_last = c

	var now := Time.get_ticks_msec() / 1000.0
	if now - _second_at < 1.0:
		return
	var wall := now - _wall_last
	var cpu := _cpu_seconds()
	var d := net.describe()
	var peers: int = int(d.get("peers", 0))
	print("STAT peers=%d tick_avg=%.3f tick_p99=%.3f phys_avg=%.3f phys_p99=%.3f sim_ms=%.3f send_ms=%.3f cpu_pct=%.0f rss_mb=%.0f out_kBps=%.1f bytes_per_client_s=%.0f split=%d largest_part=%d warned_parts=%s ents=%d tps=%.0f" % [
		peers, _mean(_samples), _p(_samples, 0.99), _mean(_phys), _p(_phys, 0.99),
		_sim_usec / maxf(1.0, _tick_n) / 1000.0, _send_usec / maxf(1.0, _tick_n) / 1000.0,
		(cpu - _cpu_last) / wall * 100.0, _rss_mb(),
		net.stats.bytes_sent_per_sec / 1024.0,
		net.stats.bytes_sent_per_sec / maxf(1.0, peers),
		int(d.get("snapshots_split", 0)), int(d.get("largest_part_bytes", 0)),
		str(net.get("_warned_parts")), int(d.get("entities", 0)), float(_samples.size()) / wall,
	])
	_print_costs()
	_sim_usec = 0.0
	_send_usec = 0.0
	_tick_n = 0
	_samples.clear()
	_phys.clear()
	_second_at = now
	_wall_last = now
	_cpu_last = cpu


func _mean(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return 0.0
	var sum := 0.0
	for v in values:
		sum += v
	return sum / values.size()


func _gather_costs() -> void:
	var taken := DotFrameCost.take()
	for system: StringName in taken:
		_costs[system] = float(_costs.get(system, 0.0)) + float(taken[system]["ms"])
	_costs[&"frames"] = float(_costs.get(&"frames", 0.0)) + 1.0


func _print_costs() -> void:
	var frames := maxf(1.0, float(_costs.get(&"frames", 1.0)))
	var rows := []
	for system: StringName in _costs:
		if system != &"frames":
			rows.append([float(_costs[system]) / frames, system])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var parts := PackedStringArray()
	for row in rows:
		if row[0] >= 0.05:
			parts.append("%s=%.2f" % [row[1], row[0]])
	print("COST ", " ".join(parts))
	_costs.clear()
