extends Node

const PlaygroundNetBridge := preload("../game/net/playground_net_bridge.gd")
const PlaygroundNetCommand := preload("../game/net/playground_net_command.gd")
const PlaygroundNetLink := preload("../game/net/playground_net_link.gd")

## N synthetic clients in one process against tools/load_server.tscn, each a real [DotClientLink]
## on its own ENet connection; sends acks and random-walk inputs at the tick rate, decodes nothing.
## Driver: tools/load100.sh.

## Stands in for the game bridge: acks the tick at the head of each snapshot, drops the rest.
class Stub extends PlaygroundNetBridge:
	var ack_tick := 0
	var snapshots := 0
	var bytes := 0
	var events := 0

	func receive_snapshot(payload: PackedByteArray) -> DotResult:
		snapshots += 1
		bytes += payload.size()
		var tick := DotNetReader.new(payload).read_uint(32)
		ack_tick = maxi(ack_tick, tick)
		return DotResult.success(true)

	func receive_event(_payload: PackedByteArray) -> DotResult:
		events += 1
		return DotResult.success(true)


class Client extends RefCounted:
	var root: Node = null
	var link: DotClientLink = null
	var net_link: PlaygroundNetLink = null
	var stub: Stub = null
	var last_tick := 0
	var history: Array = []
	var yaw := 0.0
	var move := Vector2.ZERO
	var retarget := 0


var _clients: Array[Client] = []
var _hz := 64
var _port := 27399
var _seconds := 30.0
var _board_rows := -1
var _board_bytes := -1
var _started := 0.0
var _sent := 0
var _last_report := 0.0


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_hz = int(_arg("--hz", "64"))
	_port = int(_arg("--port", "27399"))
	_seconds = float(_arg("--seconds", "30"))
	set_physics_process(false)
	_run.call_deferred(int(_arg("--clients", "16")))


func _run(count: int) -> void:
	for i in count:
		var c := Client.new()
		c.root = Node.new()
		c.root.name = "c%d" % i
		add_child(c.root)
		get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), c.root.get_path())
		var holder := Node.new()
		holder.name = "LoadServer"
		c.root.add_child(holder)
		c.link = DotClientLink.new()
		c.link.name = "Server"
		c.link.player_name = "Load%d" % i
		c.link.transport_preference = "udp"
		c.link.udp_address = "127.0.0.1:%d" % _port
		holder.add_child(c.link)
		c.stub = Stub.new()
		c.net_link = PlaygroundNetLink.attached_to(c.link, c.stub, false)
		c.net_link.name = "Playground"
		c.link.add_child(c.net_link)
		# The game scene is what makes a real client expensive and is not what is measured.
		c.link.envelope.handle(DotEnvelope.LOAD_GAME, _stub_load.bind(c))
		_clients.append(c)
		if i == 0:
			c.link.scoreboard_received.connect(_on_board)
		c.link.connect_to_server("127.0.0.1:%d" % _port)
		if i % 8 == 7:
			await get_tree().create_timer(0.1).timeout

	var waited := 0.0
	while _playing() < count and waited < 60.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	print("SWARM joined=%d/%d after %.1f s" % [_playing(), count, waited])
	_clients[0].link.send_kind(DotEnvelope.SCOREBOARD_WANT, {"open": true})
	_started = Time.get_ticks_msec() / 1000.0
	_last_report = _started
	set_physics_process(true)


func _stub_load(_peer: int, _info: Dictionary, c: Client) -> void:
	c.link.send_kind(DotEnvelope.LOADED)
	c.link._enter_playing()

func _playing() -> int:
	var n := 0
	for c in _clients:
		if c.link.is_playing():
			n += 1
	return n


func _on_board(snap: Dictionary) -> void:
	_board_rows = (snap.get("players", snap.get("rows", [])) as Array).size()
	_board_bytes = var_to_bytes(snap).size()


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for c in _clients:
		if c.link.is_playing() and c.stub.ack_tick > 0:
			_send(c)
	if now - _last_report >= 5.0:
		var snaps := 0
		var bytes := 0
		for c in _clients:
			snaps += c.stub.snapshots
			bytes += c.stub.bytes
		print("SWARM playing=%d snapshots=%d recv_bytes=%d inputs=%d board_rows=%d board_bytes=%d" % [
			_playing(), snaps, bytes, _sent, _board_rows, _board_bytes])
		_last_report = now
	if now - _started >= _seconds:
		print("SWARM done")
		get_tree().quit()


func _send(c: Client) -> void:
	c.retarget -= 1
	if c.retarget <= 0:
		c.retarget = randi_range(_hz / 4, _hz * 2)
		c.move = Vector2.from_angle(randf() * TAU) if randf() < 0.8 else Vector2.ZERO
	c.yaw = fmod(c.yaw + 1.5, 360.0)
	var packet := PlaygroundNetCommand.new()
	packet.tick = maxi(c.last_tick + 1, c.stub.ack_tick + 3)
	c.last_tick = packet.tick
	packet.delta = 1.0 / float(_hz)
	packet.move = DotFpsCommand.new()
	packet.move.move = c.move
	packet.move.yaw = c.yaw
	c.history.append(packet)
	if c.history.size() > 5:
		c.history.pop_front()
	var payload := DotNetWriter.new()
	payload.write_uint(c.stub.ack_tick, 32)
	DotNetInput.write_batch(payload, c.history)
	c.net_link.send_input(payload.to_bytes())
	_sent += 1
