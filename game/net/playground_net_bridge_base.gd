extends Node


const Playground := preload("../playground.gd")
const PlaygroundEvent := preload("playground_event.gd")
const PlaygroundEvents := preload("playground_events.gd")
const PlaygroundInventoryNet := preload("playground_inventory_net.gd")
const PlaygroundNetCommand := preload("playground_net_command.gd")
const PlaygroundNetLink := preload("playground_net_link.gd")
const PlaygroundPlayer := preload("../playground_player.gd")
const PlaygroundPlayerNet := preload("playground_player_net.gd")
const PlaygroundProp := preload("../playground_prop.gd")
const PlaygroundPropNet := preload("playground_prop_net.gd")
const PlaygroundNpcNet := preload("playground_npc_net.gd")
const PlaygroundRequest := preload("playground_request.gd")
const PlaygroundSpawnables := preload("../playground_spawnables.gd")
const PlaygroundVehicleNet := preload("playground_vehicle_net.gd")
const PlaygroundToyNet := preload("playground_toy_net.gd")
const PlaygroundWeapon := preload("../weapons/playground_weapon.gd")
const PlaygroundWeaponNet := preload("playground_weapon_net.gd")
const PlaygroundWeapons := preload("../playground_weapons.gd")
const PlaygroundZee := preload("../playground_zee.gd")
const PlaygroundWaves := preload("../playground_waves.gd")

## Joins a [Playground] to a [DotNetManager]; the only file here that names both. dot-net drives
## simulation per entity but this game's tick is whole-game, so [method ensure_game_ticked] makes
## the first behaviour through run it. Movement is predicted; props and NPCs are server-authoritative.

const CHANNEL := "pg.net"
const ACK_BYTES := 4

## Commands in every input packet: this tick's and the four before it, so a lost packet costs the
## server no tick unless the next four are lost too. Matters over ENet (the desktop client); over
## WebSocket nothing is lost. Measured at 20% loss: 80% of ticks right with one copy, 99-100% with three.
const INPUT_COPIES := 5

## The client has been told who it is. [param player_id] is the session id.
signal hello_received(player_id: int)
signal roster_changed(player_id: int)
## A prop or entity appeared or went away, on a client. For the HUD's counter.
signal props_changed()

## A mirrored prop arrived, on a client: where, and whose session spawned it. For the presentation
## layer, which [signal props_changed] cannot serve. A joining client is sent every prop through
## the same event, so a listener that makes a noise has to decide which it wants.
signal prop_arrived(at: Vector3, owner_session: int)
signal notice_received(player_id: int, text: String)

## A player got into or out of a vehicle. Client side; the HUD and the camera read it.
signal seat_changed(player_id: int, seated: bool)

## What the SERVER says a player is holding, the tool or weapon by id. Not what the client asked
## for: a weapon is a purchase, `_give_weapon` only broadcasts once paid, and the client corrects
## itself to this answer.
signal weapon_changed(player_id: int, weapon_id: StringName)

## Somebody pressed Enter. Server side, and the only thing this bridge does with chat: who may say
## what, on which channel, how often and who hears it are [DotChatRouter]'s.
signal say_requested(peer_id: int, channel_id: StringName, text: String)

## Somebody typed a vote command, or published a loadout. Server side.
signal vote_requested(peer_id: int, token: String)
signal loadout_requested(peer_id: int, pairs: Array)
## A player asked for their saved builds, or to put one down. Server side; the module owns
## the builds and answers with [method send_builds].
signal builds_requested(peer_id: int)
signal build_load_requested(peer_id: int, name: String)
## This player's saved builds arrived, for the Q menu. Client side.
signal builds_received(builds: Array)

## The tool gun's edit mode picked a prop, or let go of one: `{net_id, name, settings,
## refused}`, net id 0 for nothing. Client side, to this player only.
signal selection_received(state: Dictionary)
## Client side: this player's hit landed (see [signal Playground.hit_landed]). Only ever sent
## to the shooter; what the hit marker and the damage numbers are drawn from.
signal hit_received(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool)

## A voice frame arrived. Server side; the payload is unparsed and must not be trusted —
## [method DotVoiceRouter.relay] is what stamps the speaker.
signal voice_requested(peer_id: int, payload: PackedByteArray)

## A peer said READY for the first time and has been told the world. Server side. The one moment
## anything else may be sent to it: dot-server's `client_spawn` comes BEFORE this on every real
## join, so anything gated on [method peer_is_ready] at spawn must be sent from here instead.
signal peer_admitted(peer_id: int)

## Client side.
signal chat_received(wire: Dictionary)
signal voice_arrived(payload: PackedByteArray)
signal combat_received(state: Dictionary)

## A killed NPC's drawn figure and how it falls (the server's pick), just before its mirror
## goes. Client side; the client copies a ragdoll from it.
signal body_fell(figure: Node3D, death: DotPlayerDeath)
signal match_received(state: Dictionary)
signal progress_received(state: Dictionary)
## The map vote's cue and countdown second, from [method PlaygroundEvents.read_vote_cue].
signal vote_cue_received(state: Dictionary)
## The vote's clock changed: [member clock_view] has just adopted [param state]. Client
## side.
signal clock_received(state: Dictionary)

## An inventory op this client predicted was refused, and has been rolled back. Client
## side; the HUD says why, because a drag that springs back with no reason reads as a
## broken grid.
signal inventory_refused(reason: String)

var game: Playground = null
var net: DotNetManager = null
var link: PlaygroundNetLink = null

## Which session this process is. Zero on a server.
var local_player_id: int = 0

## Where the clock learns the link's length in milliseconds. dot-net cannot measure it;
## dot-server's heartbeat does ([method DotClientLink.ping_ms]). A client that feeds nothing
## assumes an instant link and stamps commands for a tick the server already simulated.
var rtt_source: Callable = Callable()

## [code]func() -> Dictionary[/code], in [method DotVoteClockView.state_of]'s shape: what a joining
## peer is told about the map's time left. Server side; empty sends nothing, and the client then
## shows its own map session's clock.
var clock_fn: Callable = Callable()

## The map's time left as the server last described it. Client side; what the HUD draws.
## Never adopted means never told, which the HUD answers with the local clock.
var clock_view: DotVoteClockView = DotVoteClockView.new()

## dot-inventory's half of the wire. See [PlaygroundInventoryNet]; null when the game has
## no inventory.
var inventory_net: PlaygroundInventoryNet = null

## [code](session_id: int) -> String[/code]: who a session IS, for a bag that should outlast the
## connection. Server side. Unset means the bag is the session's and goes with it, which is right
## on a LAN. The module sets it to the key the statistics are filed under.
var inventory_key_fn: Callable = Callable():
	set(value):
		inventory_key_fn = value
		if inventory_net != null:
			inventory_net.bag_key_fn = value

var _entities: Node = null
var _behaviours: Dictionary = {}
var _prop_nets: Dictionary = {}

## session_id -> which tool that player is holding. The server's copy, because the
## server is what acts: a client saying "I am holding the gravity gun" is a claim, and
## the tool decides what a trigger DOES to somebody else's prop.
var _tool_of: Dictionary = {}
var weapon_net := PlaygroundWeaponNet.new()

## Server: session id -> the net id of the prop that player's physics gun holds. Client: the
## same, as the server last said. What a joiner is told and what a client draws beams from.
var held_props: Dictionary = {}

## session_id -> the buttons that player's previous command carried, so a press can be told from a
## hold. A physics gun grabs on the press and holds after; grabbing every tick would re-target
## continuously and drag whatever the crosshair crossed.
var _prev_buttons: Dictionary = {}

## Session id -> the toy (launcher, remover, impulse gun) the server runs for that player,
## and the prop each one has armed. See [method _give_weapon].
var _toy_of: Dictionary = {}
var _armed_of: Dictionary = {}

## Wave NPCs replicated through the prop table: instance id -> their catalogue id. They are
## not props, so the spawner cannot be asked what they are when a late joiner arrives.
var _npc_kinds: Dictionary = {}

## The catalogue a client builds a wave NPC's body from. Set by the module with the waves.
var npc_catalogue: DotNpcCatalogue = null

## session id -> [mode, settings] for the tool gun, kept so a tool gun given later — or
## given again — starts in the mode the player last chose rather than the default one.
var _tool_settings_of: Dictionary = {}
var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
## Server: peers whose READY came before their seat ([method add_player]). Over ENet with loss the
## READY can overtake `loaded`, and a READY dropped here left that client waiting for a world for
## ever. Admitted when seated.
var _ready_unseated: Dictionary = {}
var _tick: int = 0
var _game_ticked_for: int = -1
var _client_ticked_for: int = -1

## A style index -> id table both ends build identically, so a style travels as one
## byte rather than as a string on every join.
var _style_ids: Array[StringName] = []


## How every dot-net message reaches a peer. Routed by DELIVERY, not by kind: snapshots are
## unreliable, everything else reliable, and the server has events where the client has requests.
## Sending all as events silently drops every client request.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return
	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


static func _player_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


static func session_of(id: StringName) -> int:
	return String(id).trim_prefix("u").to_int()


func peer_for_player(session_id: int) -> int:
	return int(_peer_of_player.get(session_id, 0))


func player_for_peer(peer_id: int) -> int:
	return int(_player_of_peer.get(peer_id, 0))


func _style_index(style_id: StringName) -> int:
	var at := _style_ids.find(style_id)
	return at if at >= 0 else 0


func _style_id(index: int) -> StringName:
	if index < 0 or index >= _style_ids.size():
		return &"normal"
	return _style_ids[index]


## What a session wears, as [face, top, legs] kit skins (see `playground_avatars.gd`), or an
## empty array for the stock look. Set by the module from dot-platform; asked as a player is
## added, before their JOIN.
var skin_fn: Callable = Callable()


func _build_entity(player: PlaygroundPlayer, peer_id: int) -> DotNetIdentity:
	# The behaviour is added BEFORE the identity: DotNetIdentity collects behaviours in
	# _ready by walking the subtree, and one added afterwards would never be found.
	var behaviour := PlaygroundPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. SERVER would put a player's own
	# movement a round trip behind their keys.
	identity.authority = DotNetIdentity.Authority.SHARED
	identity.always_relevant = true
	player.add_child(identity)

	_behaviours[session_of(player.player_id)] = behaviour
	return identity


func _release_entity(session_id: int) -> void:
	var behaviour: PlaygroundPlayerNet = _behaviours.get(session_id)
	_behaviours.erase(session_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	net.registry.unregister(behaviour.identity.net_id)


## The fall [method Playground.decide_npc_death] left on a killed body, or null.
static func _death_of(node: Object, reason: StringName) -> DotPlayerDeath:
	if reason != DotNpcSpawner.REASON_KILLED or node == null or not is_instance_valid(node):
		return null
	var death: Variant = node.get_meta(&"pg_death") if node.has_meta(&"pg_death") else null
	return death as DotPlayerDeath


## Which replicated behaviour a definition wants. One table, read by both ends.
static func _behaviour_for(def: DotPropDef) -> PlaygroundPropNet:
	# A wave NPC has no prop definition at all; it is a body to move, like any prop.
	if def == null:
		return PlaygroundPropNet.new()
	if PlaygroundSpawnables.kind_of(def) == PlaygroundSpawnables.Kind.VEHICLE:
		return PlaygroundVehicleNet.new()
	# An armed NPC replicates its weapon too: which one, and the fire counter a watcher's
	# world model kicks on. Same catalogue reading on both ends, so both pick this.
	if bool(def.meta.get("armed", false)):
		return PlaygroundNpcNet.new()
	return PlaygroundPropNet.new()


## The body a client draws for [param net_id], or null..
func _mirror_node(net_id: int) -> Node3D:
	var behaviour: PlaygroundPropNet = _prop_nets.get(net_id)
	return behaviour.prop if behaviour != null else null


## Client: every player holding something, as `[{player, prop}]` with this client's own
## nodes (the player's mirror and the prop's), skipping any it has not built yet.
func holders() -> Array:
	var out: Array = []
	if game == null:
		return out
	for session: int in held_props.keys():
		var who: Variant = game.players.get(_player_key(session))
		var prop := _mirror_node(int(held_props[session]))
		if who != null and is_instance_valid(who) and prop != null and is_instance_valid(prop):
			out.append({"player": who, "prop": prop})
	return out


## The net id a vehicle's body replicates under, or 0.
func net_id_of_node(node: Node) -> int:
	for instance_id in _prop_nets:
		var behaviour: PlaygroundPropNet = _prop_nets[instance_id]

		if behaviour.prop == node and behaviour.identity != null:
			return behaviour.identity.net_id

	return 0


func client_tick(tick: int, command: DotFpsCommand, aim: bool = false) -> void:
	if net == null or net.is_server or game == null:
		return

	_tick = tick

	var packet := PlaygroundNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()
	packet.aim = aim

	# Into the local history BEFORE predicting: reconciliation replays it.
	net.local_inputs().push(packet)

	# The behaviour simulates from last_move, on a fresh tick and on a replayed one
	# alike — the predictor's replay sets it through _net_apply_input, and this is the
	# fresh tick's equivalent.
	var mine: PlaygroundPlayerNet = _behaviours.get(local_player_id)
	if mine != null:
		mine.last_move = packet.move
		mine.last_aim = aim

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		DotNetInput.write_batch(writer, _input_copies(packet))
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	# The client game ticks once: predicted players simulate through their behaviours,
	# and every timer — including remote players' — is fed afterwards. Props are not
	# simulated here at all; they are drawn from snapshots.
	if inventory_net != null:
		inventory_net.poll()

	if _client_ticked_for != tick:
		_client_ticked_for = tick
		# Through the predictor, which remembers each tick: a snapshot can only skip its replay when the
		# tick it describes was remembered.
		net.predict_tick(tick, packet)
		game.tick_timers_only(tick)


func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")
	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))
	return net.receive_snapshot(payload)


## [param packet] and the commands before it from the local replay history, oldest first,
## for one input packet. See [constant INPUT_COPIES].
func _input_copies(packet: DotNetInput) -> Array:
	var batch: Array = Array(net.local_inputs().recent(INPUT_COPIES, packet.tick - 1))
	batch = batch.slice(maxi(0, batch.size() - (INPUT_COPIES - 1)))
	batch.append(packet)
	return batch


func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")
	if not _player_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")
	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	# A batch: this tick's command and the ones before it (see [constant INPUT_COPIES]).
	# Copies of ticks already simulated are skipped rather than pushed, or each would count
	# as a late input; the packet's own tick is always pushed, so a late one still counts.
	var batch := DotNetInput.read_batch(
		DotNetReader.new(payload.slice(ACK_BYTES)),
		func() -> DotNetInput: return PlaygroundNetCommand.new()
	)
	if batch.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "Input packet carries no command.")
	var buffer := net.input_buffer_for(peer_id)
	var newest := batch[batch.size() - 1]
	var pushed := DotResult.success(false)
	for input in batch:
		if input != newest and input.tick <= buffer.last_consumed_tick():
			continue
		pushed = buffer.push(input)
	return pushed


## A voice frame off [method PlaygroundNetLink.send_voice], either direction. Not a
## [PlaygroundEvent]: voice is fifty packets a second and events are reliable, so a talk spurt
## would queue behind prop spawns. Nor through [DotNetManager]: the packet has its own header in [DotVoicePacket].
func receive_voice(peer_id: int, payload: PackedByteArray) -> DotResult:
	if payload.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "An empty voice frame.")

	if net != null and net.is_server:
		if peer_id <= 0 or player_for_peer(peer_id) == 0:
			# A peer with nobody in the world. Refused rather than relayed: the router
			# stamps the speaker from this id, so relaying one that belongs to nobody
			# puts a voice in the game with no name on it.
			return DotResult.fail(
				DotError.CODE_FORBIDDEN, "That peer has nobody in the world."
			)

		voice_requested.emit(peer_id, payload)
		return DotResult.success(null)

	voice_arrived.emit(payload)
	return DotResult.success(null)


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")
	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")
	return net.receive(payload, peer_id)


func _join_body(session_id: int) -> PackedByteArray:
	var behaviour: PlaygroundPlayerNet = _behaviours.get(session_id)
	if behaviour == null or behaviour.identity == null or behaviour.player == null:
		return PackedByteArray()

	var player := behaviour.player
	return PlaygroundEvents.write_join(
		session_id,
		behaviour.identity.net_id,
		player.display_name,
		_style_index(player.movement_style.id if player.movement_style != null else &"normal"),
		player.skins
	)


## The map's toys on the wire, one behaviour per toy in toy order, and the TOYS event that names
## their net ids (kept for a joiner).
var _toy_nets: Array = []
var _toys_body: PackedByteArray = PackedByteArray()

## Client: which map the last TOYS was for. Its mirrors are registered at once and handed their
## toys when this end's toys for that map exist ([method _pair_pending_toys]).
var _toys_map: StringName = &""

## Client: where the mirrors live, which is not under the toys: a client registers them the
## moment TOYS arrives, before its own map may be built, and keeps them through a map change.
var _toy_holder: Node3D = null


## A toy's behaviour and identity under [param parent], registered under [param net_id] (0
## allocates: the server); null when the registry refused it. The behaviour before the
## identity, which collects behaviours in its `_ready`.
func _toy_entity(toy: DotPropToy, parent: Node, net_id: int) -> PlaygroundToyNet:
	var behaviour := PlaygroundToyNet.new()
	behaviour.name = "Net"
	behaviour.toy = toy
	var holder := Node3D.new() if parent != toy else null
	if holder != null:
		holder.name = "Toy%d" % _toy_nets.size()
		parent.add_child(holder)
	var at: Node = holder if holder != null else toy
	at.add_child(behaviour)
	if net.is_server:
		behaviour.pull()
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	at.add_child(identity)
	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a toy", {"toy": _toy_nets.size(), "error": str(registered.error)})
		at.remove_child(behaviour)
		at.remove_child(identity)
		behaviour.queue_free()
		identity.queue_free()
		if holder != null:
			parent.remove_child(holder)
			holder.queue_free()
		return null
	_toy_nets.append(behaviour)
	return behaviour


## Every toy entity out of the registry and out of the tree at once: a new identity on the same
## toy collects every behaviour under it in its `_ready`, and a freed one found there broke the
## next snapshot. The server's, on a map change or a new set.
func _release_toys() -> void:
	for behaviour: PlaygroundToyNet in _toy_nets:
		if not is_instance_valid(behaviour):
			continue
		if behaviour.identity != null and net != null and net.registry.has(behaviour.identity.net_id):
			net.registry.unregister(behaviour.identity.net_id)
		var at := behaviour.get_parent()
		for node: Node in [behaviour.identity, behaviour]:
			if node != null and is_instance_valid(node) and node.get_parent() != null:
				node.get_parent().remove_child(node)
				node.queue_free()
		if at != null and at.get_parent() == _toy_holder and _toy_holder != null:
			_toy_holder.remove_child(at)
			at.queue_free()
	_toy_nets.clear()


## Client, on TOYS: a mirror for every id at once, under the holder, whether this end's toys exist
## yet or not. A client must know every entity a snapshot carries: dot-net stops reading at the
## first unknown one, so a missing mirror froze every player after it. Paired with its toy by index.
func _apply_toys(told: Dictionary) -> void:
	if net == null or net.is_server:
		return
	_release_toys()
	if _toy_holder == null:
		_toy_holder = Node3D.new()
		_toy_holder.name = "ToyMirrors"
		add_child(_toy_holder)
	_toys_map = told["map_id"]
	for id in (told["ids"] as PackedInt64Array):
		var _mirror := _toy_entity(null, _toy_holder, int(id))
	_pair_pending_toys()


## Client: each mirror handed this end's toy at its index, once this end's toys are for the map
## TOYS named; none while they are not (a map change on the way, or another map).
func _pair_pending_toys() -> void:
	if net == null or net.is_server or game == null:
		return
	var box := game.toys if game.toys != null and game.maps.current != null and game.maps.current.id == _toys_map else null
	if box != null and box.count() != _toy_nets.size():
		DotLog.warn(CHANNEL, "the server's map has a different number of toys", {"server": _toy_nets.size(), "here": box.count()})
	for i in range(_toy_nets.size()):
		var behaviour: PlaygroundToyNet = _toy_nets[i]
		behaviour.toy = box.toy(i) if box != null else null


## Client: the old map's toys are about to go; the mirrors stay registered, without them.
func _unpair_toys() -> void:
	for behaviour: PlaygroundToyNet in _toy_nets:
		if is_instance_valid(behaviour):
			behaviour.toy = null


## How many toys this end replicates (a client: mirrors paired with a toy). For a check.
func toy_count() -> int:
	var n := 0
	for behaviour: PlaygroundToyNet in _toy_nets:
		if is_instance_valid(behaviour) and (net.is_server or behaviour.toy != null):
			n += 1
	return n


func ask_ready() -> void:
	_ask(PlaygroundEvents.Ask.READY, PackedByteArray())


func ask_spawn_prop(prop_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.SPAWN_PROP, PlaygroundEvents.write_id(prop_id))


func ask_weapon(weapon_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.GIVE_WEAPON, PlaygroundEvents.write_id(weapon_id))


## What the toy in hand should throw. See [constant PlaygroundEvents.Ask.ARM_PROP].
func ask_arm(prop_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_id(prop_id))


## Switch the flashlight. The server owns on/off and answers in the player's replicated state.
func ask_flashlight() -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_arm(PlaygroundEvents.ARM_FLASHLIGHT, &""))


func ask_drop_weapon() -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_arm(PlaygroundEvents.ARM_DROP_WEAPON, &""))


func ask_tool(tool_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.SELECT_TOOL, PlaygroundEvents.write_id(tool_id))


func ask_undo() -> void:
	_ask(PlaygroundEvents.Ask.UNDO, PackedByteArray())


func ask_clear_mine() -> void:
	_ask(PlaygroundEvents.Ask.CLEAR_MINE, PackedByteArray())


func ask_restart() -> void:
	_ask(PlaygroundEvents.Ask.RESTART, PackedByteArray())


func ask_checkpoint(action: int) -> void:
	_ask(PlaygroundEvents.Ask.CHECKPOINT, PlaygroundEvents.write_index(action))


func ask_use_vehicle() -> void:
	_ask(PlaygroundEvents.Ask.USE_VEHICLE, PackedByteArray())


func ask_rtv() -> void:
	_ask(PlaygroundEvents.Ask.RTV, PackedByteArray())


## Buys one of [param item_id] into this client's bag. Client side.
func ask_buy(item_id: StringName) -> void:
	if inventory_net != null and not net.is_server:
		inventory_net.ask_buy(item_id)


## This client's own bag, to predict ops on — `apply` sends them — or null before the
## server has said whose it is. Client side.
func inventory_manager() -> DotInvManager:
	return inventory_net.local_manager() if inventory_net != null and not net.is_server else null


func ask_style(style_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.STYLE, PlaygroundEvents.write_index(_style_index(style_id)))


func _ask(kind: int, body: PackedByteArray) -> void:
	if net != null and not net.is_server:
		net.send(PlaygroundRequest.new(kind, body), 1)


## Asked before anything is spawned or given, and charged for if allowed:
## [code](player_id: StringName, thing_id: StringName) -> DotResult[/code]. A callable rather than
## a shop reference: the bridge knows nothing about prices. Unset means everything is free.
var charge_fn: Callable = Callable()

## Asked before something is spawned, and charges nothing (the shop's `may_have`):
## [code](player_id: StringName, thing_id: StringName) -> DotResult[/code]. Lets a spawn be paid
## for AFTER it happened (see [method _spawn_for]). Unset answers yes.
var may_charge_fn: Callable = Callable()

## Handed every shot a zee weapon fires on this server, once the props it hit are shoved:
## [code](player_id: StringName, shot: DotShot) -> void[/code]. The arena's dot-combat sets it
## while `pg_arena` is on; unset, a shot moves props and hurts nobody.
var shot_fn: Callable = Callable()


## Charge for something, or say why not. Success when nothing is charging.
func _charge(id: StringName, thing_id: StringName) -> DotResult:
	if not charge_fn.is_valid():
		return DotResult.success(null)
	return charge_fn.call(id, thing_id) as DotResult


## Whether [method _charge] would succeed, charging nothing. Success when nothing is asking.
func _may_charge(id: StringName, thing_id: StringName) -> DotResult:
	if not may_charge_fn.is_valid():
		return DotResult.success(null)
	return may_charge_fn.call(id, thing_id) as DotResult


## The body a client draws for [param net_id], or null. Client side.
func mirror_of(net_id: int) -> Node3D:
	return _mirror_node(net_id)


func _restore_tool_mode(session_id: int, toy: PlaygroundWeapon) -> void:
	var saved: Variant = _tool_settings_of.get(session_id)
	if saved is Array and toy.has_method("set_mode"):
		var _set: DotResult = toy.call("set_mode", saved[0], saved[1])


## Asks for the tool gun's mode and settings. Client side.
func ask_tool_mode(mode: StringName, settings: Dictionary) -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_arm(
		PlaygroundEvents.ARM_TOOL, mode, JSON.stringify(settings)
	))


## Says what this player's NPCs should carry. Client side.
func ask_npc_weapon(weapon_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_arm(
		PlaygroundEvents.ARM_NPC_WEAPON, weapon_id
	))


## Puts a weapon on the ground in front of this player. Client side.
func ask_spawn_weapon(weapon_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_arm(
		PlaygroundEvents.ARM_SPAWN_WEAPON, weapon_id
	))


## Asks for this player's saved builds; [signal builds_received] answers. Client side.
func ask_builds() -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_arm(
		PlaygroundEvents.ARM_BUILDS, &""
	))
