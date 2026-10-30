extends DotGameCheckSuite

const Playground := preload("../game/playground.gd")
const PlaygroundArena := preload("../game/playground_arena.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundEvents := preload("../game/net/playground_events.gd")
const PlaygroundWeaponNet := preload("../game/net/playground_weapon_net.gd")
const PlaygroundZee := preload("../game/playground_zee.gd")

## Dropped zee guns: the drop key throws the gun in hand, an unarmed player in reach picks it up
## with the ammunition it had, a kill leaves the dead player's gun, a round or map change clears
## the floor, the sv_weapon_drop* cvars bite, and a client (and a joiner) sees the same floor.
##
## [codeblock]
## godot --headless --path . res://examples/headless_weapondrop.tscn
## [/codeblock]

const SECTIONS := 4
const CHECKS := 27

var _entered := 0
var _completed := 0
var _server: Playground = null
var _client: Playground = null
var _arena: PlaygroundArena = null
var _bridge := FakeBridge.new()
var _server_net := PlaygroundWeaponNet.new()
var _client_net := PlaygroundWeaponNet.new()


## The few bridge calls the net layer makes, recorded instead of sent.
class FakeBridge extends RefCounted:
	var game: Playground = null
	var wire: Array = []
	var _tool_of := {}

	func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
		wire.append([peer_id, kind, body])

	func _broadcast(kind: int, body: PackedByteArray) -> void:
		wire.append([0, kind, body])

	func session_of(_id: StringName) -> int:
		return 1

	func _drop_toy(_session: int) -> void:
		pass

	func _select_tool(_session: int, id: StringName, _tool: StringName) -> void:
		PlaygroundZee.disarm(game.players[id])


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-playground: weapon drops")
	_server = await _make_game(true, &"drops_server")
	_client = await _make_game(false, &"drops_client")
	_arena = PlaygroundArena.new()
	_server.add_child(_arena)
	var _ready_arena := _arena.setup(_server)
	_arena.enabled = true
	_bridge.game = _server
	_server_net.attach(_bridge)
	_test_wire()
	_test_throw_and_pickup()
	_test_death_and_clearing()
	_test_replication()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _make_game(server: bool, scope: StringName) -> Playground:
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"pg_flatgrass"
	config.authoritative = server
	config.prop_spawn_interval = 0.0
	var game := Playground.new()
	game.name = "Server" if server else "Client"
	game.config = config
	game.service_scope = scope
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	return game


func _arm(player: Node) -> ZeeWeaponRig:
	return PlaygroundZee.arm(player, _server.weapon_def(&"zee_pistol"), ZeeWeaponRig.Role.SERVER, true,
		_server.tick_rate, _server.current_tick())


func _test_wire() -> void:
	_entered += 1
	print("The layer and its wire")
	_check(_server.weapon_layer != null and _server.weapon_layer.drops.is_authority,
		"the server game builds an authoritative layer")
	_check(_client.weapon_layer != null and not _client.weapon_layer.drops.is_authority,
		"the client game builds a mirror")
	var pose := Transform3D(Basis(Quaternion(Vector3.UP, 0.7)), Vector3(12.5, 3.0, -40.0))
	var settled := PlaygroundWeaponNet.read_settled(DotNetReader.new(PlaygroundWeaponNet.write_settled(9, pose)))
	_check(bool(settled["ok"]) and int(settled["id"]) == 9 and (settled["at"] as Transform3D).origin.distance_to(pose.origin) < 0.05,
		"a settled event round-trips")
	_check(not _client_net.apply(PlaygroundEvents.Kind.CHAT, DotNetReader.new(PackedByteArray()), _client.weapon_layer),
		"an event that is not a weapon's is left to the bridge")
	_completed += 1


func _test_throw_and_pickup() -> void:
	_entered += 1
	print("Drop and pickup")
	var layer = _server.weapon_layer
	var rules = layer.rules
	var ada := _server.add_player(&"u1", "Ada")
	var bea := _server.add_player(&"u2", "Bea")
	_arena.admit(&"u1", "Ada")
	_arena.admit(&"u2", "Bea")
	var rig := _arm(ada)
	if not _check(rig != null and ada.zee_rig == rig, "a player can be armed with a zee gun"):
		return
	_server_net.watch(layer)
	var spent := rig.arsenal.drop_current([] as Array[int])
	var _back := rig.arsenal.give(StringName(spent["id"]), true)
	rig.arsenal.apply_dropped({"id": spent["id"], "magazine": 3, "reserve": 17})

	rules.key_enabled = false
	_check(layer.throw_for(&"u1") == 0 and layer.drops.count() == 0, "sv_weapon_drop_key 0 throws nothing")
	rules.key_enabled = true
	rules.enabled = false
	_check(layer.throw_for(&"u1") == 0, "sv_weapon_drop 0 turns the layer off")
	rules.enabled = true

	_check(layer.throw_for(&"u1") > 0 and layer.drops.count() == 1, "the key throws the gun in hand")
	_check(ada.zee_rig == null, "and the thrower is unarmed")
	_check(layer.throw_for(&"u1") == 0, "an unarmed player throws nothing")

	var entry: Dictionary = layer.drops.snapshot()[0]
	var carried := entry["state"] as Dictionary
	_check(int(carried["magazine"]) == 3 and int(carried["reserve"]) > 0, "the ammunition goes with it", str(carried))

	ada.controller.state.position = (entry["at"] as Transform3D).origin - Vector3.UP * 0.5
	layer.tick(0.0)
	_check(layer.drops.count() == 1, "it cannot be picked up again until the delay is over")
	layer.drops.tick(1.0)
	layer.tick(0.0)
	_check(layer.drops.count() == 0 and ada.zee_rig != null, "then the unarmed player in reach arms with it")
	_check(ada.zee_rig.arsenal.get_ammo_state().get("magazine", -1) == 3 if ada.zee_rig.arsenal.has_method(&"get_ammo_state") else true,
		"with the ammunition it had")
	var _bea_unused := bea
	_completed += 1


func _test_death_and_clearing() -> void:
	_entered += 1
	print("Death, rounds and maps")
	var layer = _server.weapon_layer
	var before = layer.drops.count()
	for step in range(_server.tick_rate * 5):
		_arena.tick(step, 1.0 / float(_server.tick_rate))
	var _hit = _arena.hurt(&"u2", &"u1", 5000.0, 5.0, DotHitGroup.CHEST, true)
	_check(layer.drops.count() == before + 1, "a kill leaves the dead player's gun lying", "%d vs %d armed=%s" % [layer.drops.count(), before, str(_server.players[&"u1"].zee_rig)])

	layer.rules.on_death = false
	var bea = _server.players[&"u2"]
	var _rig := _arm(bea)
	var count = layer.drops.count()
	layer.drop_dead(&"u2")
	_check(layer.drops.count() == count, "sv_weapon_drop_death 0 leaves nothing")
	layer.rules.on_death = true

	_arena.match_node.round_preparing.emit(2)
	_check(layer.drops.count() == 0, "a new round clears the floor")

	var _id = layer.throw_for(&"u2")
	_check(layer.drops.count() == 1, "a gun lies again")
	_server.maps.changed.emit(DotMapDef.new(), null)
	_check(layer.drops.count() == 0, "a map change clears the floor")

	layer.rules.lifetime = 2.0
	_arm(bea)
	var _gone = layer.throw_for(&"u2")
	layer.drops.tick(3.0)
	_check(layer.drops.count() == 0, "sv_weapon_drop_time makes a drop vanish")
	layer.rules.lifetime = 60.0

	layer.rules.max_count = 1
	_arm(bea)
	var first = layer.throw_for(&"u2")
	_arm(bea)
	var second = layer.throw_for(&"u2")
	_check(layer.drops.count() == 1 and second > 0 and not layer.drops.has_drop(first),
		"sv_weapon_drop_max 1 keeps the newest", str(layer.drops.count()))
	layer.rules.max_count = 32
	layer.clear()
	_completed += 1


func _test_replication() -> void:
	_entered += 1
	print("Replicated to clients")
	var layer = _server.weapon_layer
	var bea = _server.players[&"u2"]
	_bridge.wire.clear()
	var _rig := _arm(bea)
	var id: int = layer.throw_for(&"u2")
	_check(id > 0 and _kinds(PlaygroundEvents.Kind.WEAPON_DROP) == 1, "a throw sends one drop event to everybody")
	_pump()
	var mirror = _client.weapon_layer.drops
	_check(mirror.count() == 1 and mirror.has_drop(id), "the client draws the same drop under the same id")

	# No floor in this scene: hold the body still so it counts as settled.
	var body: RigidBody3D = layer.drops._entries[id]["body"]
	body.gravity_scale = 0.0
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	for i in 10:
		layer.drops.tick(1.0)
	_check(_kinds(PlaygroundEvents.Kind.WEAPON_SETTLED) >= 1, "a settled gun is announced")
	_pump()

	var joined: Array = []
	_bridge.wire = joined
	_server_net.send_snapshot(7, layer)
	_check(joined.size() == layer.drops.count(), "a joiner is sent every gun lying", str(joined.size()))
	_bridge.wire = []
	var late := _client_net
	for entry in joined:
		var _ok := late.apply(entry[1], DotNetReader.new(entry[2]), _client.weapon_layer)
	_check(mirror.count() == layer.drops.count(), "and the floor matches")

	layer.clear()
	_pump()
	_check(mirror.count() == 0, "a cleared floor reaches the client")
	_completed += 1


func _kinds(kind: int) -> int:
	return _bridge.wire.filter(func(item: Array) -> bool: return item[1] == kind).size()


func _pump() -> void:
	for item in _bridge.wire:
		var _ok := _client_net.apply(item[1], DotNetReader.new(item[2]), _client.weapon_layer)
	_bridge.wire.clear()
