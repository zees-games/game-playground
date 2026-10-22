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
const PlaygroundWeapons := preload("../playground_weapons.gd")
const PlaygroundZee := preload("../playground_zee.gd")
const PlaygroundWaves := preload("../playground_waves.gd")

## Joins a [Playground] to a [DotNetManager]. The netcode seam, and the only file in
## this project that names both.
##
## [b]The ordering is the whole file.[/b] dot-net drives simulation per entity, and this
## game's tick is a whole-game property: every NPC moves, then every player, then every
## timer is fed the position its move produced. [method ensure_game_ticked] reconciles
## the two — the first behaviour through on a tick runs the whole game, the rest find it
## done.
##
## [codeblock]
## # server
## bridge.attach(game, net, server)      # `server` is the node the link mirrors
## bridge.add_player(peer_id, session_id, "Ada")
## bridge.server_tick(tick)              # instead of the game's own loop
##
## # client
## bridge.attach(game, net, client_link)
## bridge.ask_ready()
## bridge.client_tick(tick, command)
## [/codeblock]
##
## [b]What is predicted and what is not.[/b] A player's own movement is predicted, like
## every other first-person game in this family. Props, NPCs and everything the physics
## gun touches are server-authoritative and NOT predicted, because Godot's rigid-body
## solver is not reproducible across machines — see [PlaygroundPropNet]. That division
## is why the spawn menu emits rather than spawning and the tools send intent: the
## client half was built for this bridge before the bridge existed.

const CHANNEL := "pg.net"
const ACK_BYTES := 4

## Commands in every input packet: this tick's and the four before it, so a lost packet
## costs the server no tick unless the next four are lost too. Over WebSocket nothing is
## ever lost; over ENet (the desktop client, since servers went dual-stack) one command a
## packet was a tick the server ran on the previous command for every packet dropped.
## game-arena measured it first: 80% of ticks with the right command at 20% loss with one
## copy, 99-100% with three, and five closed the rest (2026-10-09).
const INPUT_COPIES := 5

## The client has been told who it is. [param player_id] is the session id.
signal hello_received(player_id: int)
signal roster_changed(player_id: int)
## A prop or entity appeared or went away, on a client. For the HUD's counter.
signal props_changed()

## A mirrored prop arrived, on a client: where, and whose session spawned it. For the
## presentation layer, which [signal props_changed] cannot serve because it carries
## neither. A joining client is sent the whole world's props through the same event, so
## this fires for those too — a listener that makes a noise has to decide which it wants.
signal prop_arrived(at: Vector3, owner_session: int)
signal notice_received(player_id: int, text: String)

## A player got into or out of a vehicle. Client side; the HUD and the camera read it.
signal seat_changed(player_id: int, seated: bool)

## What the SERVER says a player is holding — the tool or the weapon, by id.
##
## [b]The server decides this, not the client that asked.[/b] A weapon is a purchase:
## `_give_weapon` charges for it and only broadcasts once it is paid for, so a client
## that armed itself the moment the button was pressed would be holding something it
## had been refused. This is the answer, and the client corrects itself to it.
signal weapon_changed(player_id: int, weapon_id: StringName)

## Somebody pressed Enter. Server side, and the only thing this bridge does with chat.
##
## [b]The bridge carries chat and decides nothing about it.[/b] Who may say what, on which
## channel, how often and who hears it are [DotChatRouter]'s.
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

## A peer said READY for the first time and has been told the world. Server side.
##
## [b]The one moment anything else may be sent to it.[/b] dot-server's `client_spawn` comes
## BEFORE this on every real join (the client says READY only once its scene is up), so
## anything a module gates on [method peer_is_ready] at spawn finds the peer not ready and
## has to be sent from here instead.
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

## Where the clock learns how long the link is, in milliseconds. dot-net never touches a
## transport and cannot measure it; dot-server's heartbeat already does
## ([method DotClientLink.ping_ms]), and a client that feeds nothing has a clock that
## assumes an instant connection and stamps every command for a tick the server has
## already simulated. Read on every snapshot.
##
## Nothing in dot-net writes a sample. It was shipped without one in two games before
## anybody noticed the clock was reading a median of an empty set.
var rtt_source: Callable = Callable()

## [code]func() -> Dictionary[/code], in [method DotVoteClockView.state_of]'s shape. What a
## joining peer is told about the map's time left. Server side; empty sends nothing, and
## the client then shows its own map session's clock — which on a server with no vote is
## the one that ends the map.
var clock_fn: Callable = Callable()

## The map's time left as the server last described it. Client side; what the HUD draws.
## Never adopted means never told, which the HUD answers with the local clock.
var clock_view: DotVoteClockView = DotVoteClockView.new()

## dot-inventory's half of the wire. See [PlaygroundInventoryNet]; null when the game has
## no inventory.
var inventory_net: PlaygroundInventoryNet = null

## [code](session_id: int) -> String[/code]: who a session IS, for a bag that should outlast
## the connection. Server side. Empty or unset means the bag is the session's and goes with
## it — which is right on a LAN, where nothing identifies anybody twice. The module sets it
## to the same key the statistics are filed under.
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

## Server: session id -> the net id of the prop that player's physics gun holds. Client: the
## same, as the server last said. What a joiner is told and what a client draws beams from.
var held_props: Dictionary = {}

## session_id -> the buttons that player's previous command carried, so a press can be
## told from a hold. A physics gun grabs on the press and holds every tick after it;
## grabbing every tick instead would re-target continuously and drag whatever the
## crosshair crossed.
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
## Server: peers whose READY came before their seat ([method add_player]). A client sends READY
## when its link says PLAYING, which the link decides itself after sending `loaded` on another
## channel; over ENet with loss the READY can overtake `loaded`, and a READY dropped here left
## that client waiting for a world for ever. Admitted when seated.
var _ready_unseated: Dictionary = {}
var _tick: int = 0
var _game_ticked_for: int = -1
var _client_ticked_for: int = -1

## A style index -> id table both ends build identically, so a style travels as one
## byte rather than as a string on every join.
var _style_ids: Array[StringName] = []


# --- Wiring ----------------------------------------------------------------

func attach(p_game: Playground, p_net: DotNetManager, link_parent: Node) -> DotResult:
	if p_game == null or p_net == null or link_parent == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs all three.")

	if p_game.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The game and the manager disagree about who is authoritative.",
			"game=%s net.is_server=%s" % [p_game.authoritative, p_net.is_server]
		)

	game = p_game
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	# [b]The styles' declared ordering, NOT a sort of the ids.[/b] The first draft
	# collected `game.movement_styles`' keys and called `Array.sort()` on them — and
	# Godot compares StringNames by their INTERNED POINTER, not lexicographically. Two
	# peers therefore build two different tables, and a style index means a different
	# style on each end: this client joined a server that said index 0 and put itself on
	# "Sideways". It is the same bug that gave two peers two different wire ids for one
	# message type in dot-net, and it is invisible in any one-process test, because one
	# process has one intern table and both ends agree by construction.
	#
	# `style_order` is dot-player-controller's declared list, the same on every machine.
	_style_ids.assign(game.style_order)

	net.send_fn = _send

	var event := net.messages.register(
		PlaygroundEvent.NAME, PlaygroundEvent,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)
	if not event.ok:
		return event
	var request := net.messages.register(
		PlaygroundRequest.NAME, PlaygroundRequest,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)
	if not request.ok:
		return request

	net.messages.on(PlaygroundEvent.NAME, _on_event)
	net.messages.on(PlaygroundRequest.NAME, _on_request)

	link = PlaygroundNetLink.attached_to(link_parent, self, net.is_server)
	# Not parent.add_child: the link sits under the server (RPCs route by path) but must die
	# with this bridge. A bare add_child left a second link after a module reload and Godot
	# renamed the live one `@Node@n`, so RPCs to clients were lost. DotGameLink frees it with
	# the bridge without remove_child, which errors on a busy parent.
	DotGameLink.attach(link, link_parent, self, PlaygroundNetLink.NODE_NAME)

	_attach_inventory()

	# Both ends: the server's tick is server_tick, and the client's is client_tick,
	# which simulates what it predicts and leaves the rest to interpolation. A client
	# game still running its own loop would simulate the local player twice a tick and
	# dead-reckon every remote one from stale state.
	game.external_tick = true

	# The map's toys: the server's leave the registry before their nodes go and the new ones are
	# named; a client's mirrors stay registered and are handed this end's toys when they exist.
	if net.is_server:
		game.toys_clearing.connect(_release_toys)
	else:
		game.toys_clearing.connect(_unpair_toys)
		game.toys_built.connect(_pair_pending_toys)

	if net.is_server:
		game.player_added.connect(_on_player_added)
		game.player_removed.connect(_on_player_removed)
		game.props.spawned.connect(_on_prop_spawned)
		game.props.removed.connect(_on_prop_removed)
		game.props.refused.connect(_on_prop_refused)
		game.map_ready.connect(_on_map_ready)
		game.vehicles.ride.entered.connect(_on_ride_entered)
		game.vehicles.ride.exited.connect(_on_ride_exited)
		game.pickup.changed.connect(_on_pickup_changed)
		game.held_changed.connect(_on_held_changed)
		game.pane_broken.connect(_on_pane_broken)
		game.addon_message.connect(func(addon: String, body: Dictionary) -> void:
			_broadcast(PlaygroundEvents.Kind.ADDON, PlaygroundEvents.write_addon(addon, body)))
		# To the one who hit, and nobody else: a confirmation is about what YOU did.
		game.hit_landed.connect(func(id: StringName, victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
			_tell(peer_for_player(session_of(id)), PlaygroundEvents.Kind.HIT,
				PlaygroundEvents.write_hit(victim, amount, point, killed, headshot)))
		game.weapon_picked_up.connect(_on_weapon_picked_up)

		if game.projectiles != null:
			game.projectiles.launched.connect(_on_projectile_launched)
			game.projectiles.detonated.connect(_on_projectile_detonated)

		# A map loaded before the bridge was attached has its toys already.
		if game.toys != null:
			_register_toys()

	return DotResult.success(true)


## Builds the inventory's half of the wire, when the game has an inventory.
##
## [b]Through [method _tell] and never [method _broadcast], and the callables are why that
## cannot drift.[/b] [PlaygroundInventoryNet] is given a way to reach ONE peer and no way to
## reach everybody, so a bag cannot be broadcast by a later edit that picks the wrong helper.
func _attach_inventory() -> void:
	if game.inventory == null:
		return

	inventory_net = PlaygroundInventoryNet.new()
	inventory_net.name = "Inventory"
	add_child(inventory_net)

	if net.is_server:
		inventory_net.bind_server(game.inventory)
		inventory_net.tell_fn = func(peer_id: int, body: PackedByteArray) -> void:
			_tell(peer_id, PlaygroundEvents.Kind.INVENTORY, body)
		inventory_net.notice_fn = func(peer_id: int, text: String) -> void:
			_tell(peer_id, PlaygroundEvents.Kind.NOTICE,
				PlaygroundEvents.write_notice(player_for_peer(peer_id), text))
		inventory_net.charge_fn = _charge
		inventory_net.bag_key_fn = inventory_key_fn
	else:
		inventory_net.bind_client(game.inventory)
		inventory_net.ask_fn = func(body: PackedByteArray) -> void:
			_ask(PlaygroundEvents.Ask.INVENTORY, body)
		inventory_net.refused.connect(func(reason: String) -> void:
			inventory_refused.emit(reason))


## How every dot-net message reaches a peer.
##
## [b]Routed by DELIVERY, not by kind.[/b] Snapshots are unreliable and go on the
## snapshot call; everything else is reliable, and which reliable call it is depends on
## which end is sending — the server has events, the client has requests. Sending them
## all as events works on a server and silently drops every client request, which is a
## client that connects, draws, and can never ask for anything.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return
	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


# --- Identity helpers ------------------------------------------------------

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


# --- Server: players -------------------------------------------------------

## What a session wears, as [face, top, legs] kit skins (see `playground_avatars.gd`), or an
## empty array for the stock look. Set by the module from dot-platform; asked as a player is
## added, before their JOIN.
var skin_fn: Callable = Callable()


## Re-dresses a player whose avatar changed after they joined, and tells everybody.
func refresh_skins(session_id: int) -> void:
	if net == null or not net.is_server or not skin_fn.is_valid():
		return
	var player: PlaygroundPlayer = game.players.get(_player_key(session_id))
	var dressed: Variant = skin_fn.call(session_id)
	if player == null or not (dressed is PackedInt32Array) or (dressed as PackedInt32Array) == player.skins:
		return
	player.set_skins(dressed)
	_broadcast(PlaygroundEvents.Kind.JOIN, _join_body(session_id))


func add_player(
	peer_id: int, session_id: int, display_name: String, record_key: StringName = &""
) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var id := _player_key(session_id)

	if peer_id > 0:
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	# add_player emits player_added, which _on_player_added answers by building the
	# entity and announcing the JOIN. The peer mapping is set FIRST so that handler
	# can find the peer this player belongs to.
	var player := game.add_player(id, display_name, record_key)

	if player == null:
		_player_of_peer.erase(peer_id)
		_peer_of_player.erase(session_id)
		return DotResult.fail(DotError.CODE_STATE, "The game refused the player.")

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		_admit(peer_id)

	return DotResult.success(player)


func remove_peer(peer_id: int) -> void:
	_ready_unseated.erase(peer_id)

	if _player_of_peer.has(peer_id):
		remove_player(int(_player_of_peer[peer_id]))


## Removes a player whether or not a peer is behind it — a bot has none.
func remove_player(session_id: int) -> void:
	if not _behaviours.has(session_id):
		return

	var peer_id := peer_for_player(session_id)
	var was_ready := _ready_peers.has(peer_id)
	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)
	_tool_of.erase(session_id)
	held_props.erase(session_id)
	_prev_buttons.erase(session_id)
	_drop_toy(session_id)
	_armed_of.erase(session_id)

	# Released BEFORE the game is told: game.remove_player emits player_removed, which
	# _on_player_removed answers by releasing the entity and broadcasting LEAVE.
	# Releasing first empties _behaviours, so that handler finds nothing and this
	# function stays the one place a leaving player is announced.
	_release_entity(session_id)

	if inventory_net != null:
		inventory_net.release(peer_id, session_id)

	game.remove_player(_player_key(session_id))

	if net != null and peer_id > 0:
		# By whether dot-net has the peer, not by `was_ready`: a real disconnect reaches
		# here through the module, which has already called [method mark_not_ready] (so
		# chat and LEAVE skip a closed socket), and keying this on the ready set left
		# every disconnected peer in `net.peers()`, built a snapshot for and holding its
		# input buffer, acks and per-behaviour records for the life of the server.
		if net.peers().has(peer_id):
			net.remove_peer(peer_id)
		if net.interest != null:
			net.interest.forget_peer(peer_id)

	_broadcast(PlaygroundEvents.Kind.LEAVE, PlaygroundEvents.write_player(session_id))
	# They are off the ready set by now, so the broadcast skipped them. A player removed
	# while still connected — a kick that has not closed the socket yet, the loopback —
	# is told they are gone as they always were; one whose socket is already closed is
	# not sent to at all, which `rpc_id` would log as an unknown peer.
	if was_ready and link != null and link.can_reach(peer_id):
		_tell(peer_id, PlaygroundEvents.Kind.LEAVE, PlaygroundEvents.write_player(session_id))
	roster_changed.emit(session_id)


## A player the game made itself — a bot, a test — gets an entity exactly like one a
## peer asked for. Its peer id is zero, and that is not the broadcast address by
## accident: [method _tell] refuses zero, because `net.send(msg, 0)` IS a broadcast and
## game-hungario once sent every player's private message to everybody through exactly
## this hole.
func _on_player_added(id: StringName) -> void:
	if net == null or not net.is_server:
		return

	var session_id := session_of(id)

	if _behaviours.has(session_id):
		return

	var player: PlaygroundPlayer = game.players.get(id)
	if player == null:
		return

	# Dressed before the JOIN that describes them goes out, so nobody sees the stock look
	# first and the member's own a moment later.
	if skin_fn.is_valid():
		var dressed: Variant = skin_fn.call(session_id)
		if dressed is PackedInt32Array:
			player.set_skins(dressed)

	var identity := _build_entity(player, peer_for_player(session_id))
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a player", {"error": str(registered.error)})
		return

	_broadcast(PlaygroundEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)


func _on_player_removed(id: StringName) -> void:
	var session_id := session_of(id)
	if _behaviours.has(session_id):
		# The game removed it itself; the entity and the LEAVE are still ours.
		_release_entity(session_id)
		_broadcast(PlaygroundEvents.Kind.LEAVE, PlaygroundEvents.write_player(session_id))
		roster_changed.emit(session_id)


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


# --- Server: props ---------------------------------------------------------

## Every prop the spawner creates becomes a replicated entity.
##
## [b]Announced reliably AND replicated by snapshot, and it needs both.[/b] The snapshot
## moves it; the event says what it is, because a client cannot build a barrel from a
## position. A spawner factory would have to name a script, and this game's props are
## named by PATH in the catalogue precisely so a dot-cloud pack can deliver them — a
## mounted pack's `class_name` globals are not registered in the host.
func _on_prop_spawned(prop: DotPropInstance) -> void:
	if net == null or not net.is_server or prop == null or prop.node == null:
		return

	var body := prop.node as Node3D
	if body == null:
		return

	# A vehicle replicates through DotVehicleNetSync — its wheels' angle and which seats
	# are full cannot be derived from a position — so which behaviour a body gets is
	# decided by the catalogue, once, here. The table below is the same on both ends and
	# `_apply_prop` reads it the same way.
	var behaviour := _behaviour_for(prop.def)
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var as_vehicle := behaviour as PlaygroundVehicleNet

	if as_vehicle != null and game.vehicles != null:
		as_vehicle.vehicle = game.vehicles.vehicle_for_node(body)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	# SERVER, not SHARED: nothing about a rigid body is predicted, so there is no owner
	# to share with. See PlaygroundPropNet for why that is a decision and not a gap.
	identity.authority = DotNetIdentity.Authority.SERVER
	body.add_child(identity)

	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a prop", {"error": str(registered.error)})
		return

	_prop_nets[prop.instance_id] = behaviour
	behaviour.net_id_of = net_id_of_node
	behaviour.pull()

	_broadcast(PlaygroundEvents.Kind.PROP, PlaygroundEvents.write_prop(
		identity.net_id,
		prop.def.id,
		session_of(prop.owner_id),
		PlaygroundSpawnables.kind_of(prop.def) == PlaygroundSpawnables.Kind.ENTITY,
		body.global_position
	))


# --- Server: wave NPCs ------------------------------------------------------

## Replicates everything [param spawner] spawns, as props are: a PROP event says what it is
## and a [PlaygroundPropNet] moves it. Called by the module once the waves exist.
##
## [b]Through the prop path, not a second one.[/b] A wave NPC was never replicated at all —
## a connected client saw the waves' effects (stress, the director's pacing, players going
## down) and not one NPC. What a client needs is a body where the server's is, which is
## exactly what the prop path already does for any body; its definition is found in
## [member npc_catalogue] when the prop catalogue does not have it.
func watch_npc_spawner(spawner: DotNpcSpawner, catalogue: DotNpcCatalogue) -> void:
	npc_catalogue = catalogue

	if spawner == null or net == null or not net.is_server:
		return

	spawner.spawned.connect(_on_npc_spawned)
	spawner.removed.connect(_on_npc_removed)
	# Before `removed`, while the body is there: how it falls, sent with the PROP_GONE.
	spawner.died.connect(func(npc: DotNpcInstance, by: StringName) -> void:
		var _fall := game.decide_npc_death(npc.node as Node3D, by, npc.def.max_health if npc.def != null else 0.0))


func _on_npc_spawned(npc: DotNpcInstance) -> void:
	var body := npc.node as Node3D

	if body == null or net == null or not net.is_server:
		return

	var behaviour := PlaygroundPropNet.new()
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	body.add_child(identity)

	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate an NPC", {"error": str(registered.error)})
		return

	_prop_nets[npc.instance_id] = behaviour
	_npc_kinds[npc.instance_id] = npc.def.id
	behaviour.net_id_of = net_id_of_node
	behaviour.pull()

	_broadcast(PlaygroundEvents.Kind.PROP, PlaygroundEvents.write_prop(
		identity.net_id, npc.def.id, 0, true, body.global_position
	))


func _on_npc_removed(npc: DotNpcInstance, reason: StringName) -> void:
	var behaviour: PlaygroundPropNet = _prop_nets.get(npc.instance_id)
	_prop_nets.erase(npc.instance_id)
	_npc_kinds.erase(npc.instance_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	var net_id := behaviour.identity.net_id
	net.registry.unregister(net_id)
	_broadcast(PlaygroundEvents.Kind.PROP_GONE, PlaygroundEvents.write_prop_gone(
		net_id, reason, _death_of(npc.node, reason)))


## The fall [method Playground.decide_npc_death] left on a killed body, or null.
static func _death_of(node: Object, reason: StringName) -> DotPlayerDeath:
	if reason != DotNpcSpawner.REASON_KILLED or node == null or not is_instance_valid(node):
		return null
	var death: Variant = node.get_meta(&"pg_death") if node.has_meta(&"pg_death") else null
	return death as DotPlayerDeath


func _on_prop_removed(prop: DotPropInstance, reason: StringName) -> void:
	if net == null or not net.is_server or prop == null:
		return

	var behaviour: PlaygroundPropNet = _prop_nets.get(prop.instance_id)
	_prop_nets.erase(prop.instance_id)

	if behaviour == null or behaviour.identity == null:
		return

	var net_id := behaviour.identity.net_id
	net.registry.unregister(net_id)

	_broadcast(PlaygroundEvents.Kind.PROP_GONE, PlaygroundEvents.write_prop_gone(
		net_id, reason, _death_of(prop.node, reason)))


## A refusal goes to the one player who asked, not to everybody. A budget message is
## the most common thing this server says and it is nobody else's business.
func _on_prop_refused(player_id: StringName, prop_id: StringName, reason: String) -> void:
	var session_id := session_of(player_id)
	_tell(peer_for_player(session_id), PlaygroundEvents.Kind.NOTICE,
		PlaygroundEvents.write_notice(session_id, "Cannot spawn %s: %s" % [prop_id, reason]))


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


## The body a client draws for [param net_id], or null. What a rope's far end is found by.
func _mirror_node(net_id: int) -> Node3D:
	var behaviour: PlaygroundPropNet = _prop_nets.get(net_id)
	return behaviour.prop if behaviour != null else null


## Somebody's physics gun took hold of a prop or let go of one: everybody is told, so every
## client can draw the beam. Until 2026-10-07 `write_held`/`read_held` existed and nothing
## sent or read them, so a connected player saw nobody else's beam and not their own either.
func _on_held_changed(id: StringName, prop: DotPropInstance, held: bool) -> void:
	if net == null or not net.is_server:
		return
	var session := session_of(id)
	var net_id := net_id_of_node(prop.node) if held and prop != null and prop.node != null else 0
	if net_id > 0:
		held_props[session] = net_id
	else:
		held_props.erase(session)
	_broadcast(PlaygroundEvents.Kind.HELD, PlaygroundEvents.write_held(session, net_id, prop.frozen if prop != null else false))


## A pane broke on the server: everybody removes their own copy of it. The shards are props
## and travel as props; this is only the box, which every client built itself.
func _on_pane_broken(index: int, _at: Vector3, _material: StringName) -> void:
	if net == null or not net.is_server:
		return
	_broadcast(PlaygroundEvents.Kind.PANE, PlaygroundEvents.write_pane(index))


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


## Tells everybody that somebody got in or out.
##
## [b]Everybody, not just the rider.[/b] The other clients are the ones who have to stop
## drawing a player walking and start drawing them sitting in a car, and it is the same
## reasoning the occupancy mask already carries: a "get in" prompt over a full seat is a
## prompt that lies.
func announce_seat(
	vehicle: DotVehicleInstance, rider_id: StringName, seat: DotVehicleSeat, seated: bool
) -> void:
	if net == null or not net.is_server or vehicle == null:
		return

	var index := 0

	for i in vehicle.def.seats.size():
		if vehicle.def.seats[i].id == seat.id:
			index = i
			break

	_broadcast(PlaygroundEvents.Kind.SEAT, PlaygroundEvents.write_seat(
		session_of(rider_id), net_id_of_node(vehicle.node), index, seated
	))


# --- Server: the tick ------------------------------------------------------

func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1
	if net != null:
		net.server_tick(tick)
	ensure_game_ticked(tick)


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return
	_game_ticked_for = tick

	for session_id in _behaviours:
		var behaviour: PlaygroundPlayerNet = _behaviours[session_id]
		# Only what a peer sent. A bot has no peer and is driven by something else — a
		# test, an AI — and an empty command applied over the top of that would stand
		# it still.
		if behaviour.player != null and behaviour.identity != null \
				and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())

	game.tick_once(tick)

	# The tools, from the buttons the commands carried. After the movement, because a
	# gun is aimed from where the player ENDED the tick.
	for session_id in _behaviours:
		_drive_tools(int(session_id), _behaviours[session_id])

	# After the game moved them, before the snapshot is built. A prop pulled before the
	# physics step would replicate where it was last tick, which is the whole family's
	# "produced correctly and consumed by nothing" one step along: correct data, wrong
	# instant, and nothing errors.
	for instance_id in _prop_nets:
		(_prop_nets[instance_id] as PlaygroundPropNet).pull()

	# Every bag the server changed this tick, to its owner, once. After the game ticked,
	# because a spawn from the bag happens inside it.
	if inventory_net != null:
		inventory_net.flush()


## Runs one player's physics gun or gravity gun from the buttons their command carried.
##
## [b]The triggers are BUTTONS, not requests.[/b] They are per-tick and continuous —
## holding a prop is a thing you do every tick, not an event — so they ride in
## [member DotFpsCommand.buttons] beside jump and crouch. Sending them as reliable
## requests would put every grab a round trip behind the mouse and would reorder against
## the movement they are aimed with.
##
## [b]And the server actuates them, not the client.[/b] The client's own copy of a prop
## is frozen and drawn from snapshots; it could not move one if it tried. That is the
## same decision [PlaygroundPropNet] documents, seen from the input end.
func _drive_tools(session_id: int, behaviour: PlaygroundPlayerNet) -> void:
	if behaviour == null or behaviour.player == null or behaviour.identity == null:
		return
	if behaviour.identity.owner_peer_id <= 0:
		return

	var player := behaviour.player
	var buttons := behaviour.last_move.buttons
	var before := int(_prev_buttons.get(session_id, 0))
	_prev_buttons[session_id] = buttons

	var primary := (buttons & DotFpsCommand.BUTTON_USER_0) != 0
	var secondary := (buttons & DotFpsCommand.BUTTON_USER_1) != 0
	var primary_pressed := primary and (before & DotFpsCommand.BUTTON_USER_0) == 0
	var secondary_pressed := secondary and (before & DotFpsCommand.BUTTON_USER_1) == 0

	var space := player.get_world_3d().direct_space_state if player.is_inside_tree() else null
	var origin := player.eye_position()
	var aim := player.aim_direction()
	var view := Basis()
	var delta := 1.0 / float(maxi(game.tick_rate, 1))
	var may_touch := game.may_touch_others()

	var tool_id: StringName = _tool_of.get(session_id, &"phys")

	# A zee weapon owns all three buttons while it is in hand, and the physics gun none of
	# them: falling through to it would grab a crate with every shot.
	var rig := player.zee_rig as ZeeWeaponRig
	if rig != null and is_instance_valid(rig):
		var command := PlaygroundZee.command_for(
			buttons, behaviour.last_move.yaw, behaviour.last_move.pitch,
			PlaygroundZee.slot_of(rig)
		)
		var outcome := rig.simulate_tick(command, game.current_tick())
		var _moved := PlaygroundZee.shove_props(player, outcome, may_touch)
		# NPCs hear it, and the ones it hits are hurt.
		game.player_shots_fired(player.player_id, outcome)

		if shot_fn.is_valid():
			for shot: DotShot in outcome.shots:
				shot_fn.call(player.player_id, shot)
		return

	# [b]A toy is run here too, for the zee weapons' reason.[/b] Its buttons went to the
	# physics gun, so a connected player holding the launcher grabbed crates with it: the
	# toys only ever ran on the client that held them, which on a server is a client that
	# decides what it spawned and removed. Pressed edges for primary and secondary, a tick
	# every tick (a charge, a cooldown, a beam). A prop it spawns is charged like one from
	# the menu, after the spawn, and taken back out if the purse refuses.
	var toy: PlaygroundWeapon = _toy_of.get(session_id)
	if toy != null:
		var reload_pressed := (buttons & DotFpsCommand.BUTTON_USER_2) != 0 \
			and (before & DotFpsCommand.BUTTON_USER_2) == 0
		if primary_pressed:
			_toy_result(session_id, player.player_id, toy, toy.primary(space, origin, aim))
		if secondary_pressed:
			_toy_result(session_id, player.player_id, toy, toy.secondary(space, origin, aim))
		if reload_pressed:
			_toy_result(session_id, player.player_id, toy, toy.reload(space, origin, aim))
		toy.tick(space, origin, aim, delta)
		return

	if tool_id == &"grav":
		if primary_pressed:
			player.grav_gun.punt(space, origin, aim, may_touch)
		if secondary_pressed:
			player.grav_gun.pull(space, origin, aim, may_touch)
		elif secondary:
			player.grav_gun.carry(origin, aim, delta)
		elif not secondary and player.grav_gun.is_carrying():
			player.grav_gun.drop()
		return

	if primary_pressed:
		var grabbed := game.phys_gun_grab(player, space, origin, aim, view, may_touch)
		# A refusal to pick somebody up says why; a prop refusal is already reported by
		# the spawner's own signal, and a miss is not worth a notice.
		if not grabbed.ok and grabbed.error.context.has("pickup"):
			_tell(peer_for_player(session_id), PlaygroundEvents.Kind.NOTICE,
				PlaygroundEvents.write_notice(session_id, grabbed.error.message))
	elif primary:
		player.phys_gun.hold(origin, aim, view, delta)
	elif not primary:
		game.phys_gun_release(player)

	if secondary_pressed:
		player.phys_gun.freeze_held()


# --- The client tick -------------------------------------------------------

func client_tick(tick: int, command: DotFpsCommand) -> void:
	if net == null or net.is_server or game == null:
		return

	_tick = tick

	var packet := PlaygroundNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()

	# Into the local history BEFORE predicting: reconciliation replays it.
	net.local_inputs().push(packet)

	# The behaviour simulates from last_move, on a fresh tick and on a replayed one
	# alike — the predictor's replay sets it through _net_apply_input, and this is the
	# fresh tick's equivalent.
	var mine: PlaygroundPlayerNet = _behaviours.get(local_player_id)
	if mine != null:
		mine.last_move = packet.move

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
		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				behaviour._net_simulate(tick, net.clock.tick_duration())
		game.tick_timers_only(tick)


# --- Receiving -------------------------------------------------------------

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


## A voice frame off [method PlaygroundNetLink.send_voice], in whichever direction.
##
## [b]Not a [PlaygroundEvent].[/b] Voice is fifty packets a second and every event here is
## reliable, so a talk spurt would put a hundred retransmittable messages in front of a
## prop spawn. It also does not go through [DotNetManager]: the registry seals a message
## set and hashes it, and adding a fifty-hertz opaque blob buys nothing — the packet has
## its own header, sequence and validation in [DotVoicePacket].
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


# --- Server: what a joining peer is told -----------------------------------

func _admit(peer_id: int) -> void:
	if peer_id <= 0:
		return

	if not _player_of_peer.has(peer_id):
		_ready_unseated[peer_id] = true
		return

	var fresh := not _ready_peers.has(peer_id)
	_ready_peers[peer_id] = true
	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	var session_id := int(_player_of_peer[peer_id])

	_tell(peer_id, PlaygroundEvents.Kind.HELLO, PlaygroundEvents.write_hello(
		session_id, game.tick_rate, net.clock.tick,
		game.maps.current.id if game.maps.current != null else &""
	))

	for other in _behaviours.keys():
		_tell(peer_id, PlaygroundEvents.Kind.JOIN, _join_body(int(other)))

	# Who is being carried. A joiner who missed the SEAT would predict a held player.
	for id in game.players:
		if game.pickup.is_held(id):
			_tell(peer_id, PlaygroundEvents.Kind.SEAT, PlaygroundEvents.write_seat(session_of(id), 0, 0, true))

	# What everybody is already holding. A WEAPON event is sent once, when it changes, so a
	# joiner would otherwise see nobody's gun until its holder switched.
	for other in _tool_of.keys():
		_tell(peer_id, PlaygroundEvents.Kind.WEAPON, PlaygroundEvents.write_weapon(
			int(other), _tool_of[other]
		))
	# And every pane broken on this map, so the joiner's copy of the map has the same holes.
	for index: int in game.broken_panes:
		_tell(peer_id, PlaygroundEvents.Kind.PANE, PlaygroundEvents.write_pane(index))
	# And what everybody is holding, for the same reason: HELD is sent when it changes.
	for holder in held_props.keys():
		_tell(peer_id, PlaygroundEvents.Kind.HELD, PlaygroundEvents.write_held(int(holder), int(held_props[holder]), false))

	# The map's toys, by net id in toy order: the joiner's own copies are paired with them.
	if not _toys_body.is_empty():
		_tell(peer_id, PlaygroundEvents.Kind.TOYS, _toys_body)

	# The time left now, rather than at the clock's next change — which on a quiet map is
	# never, and a joiner would count down nothing until it came.
	if clock_fn.is_valid():
		_tell(peer_id, PlaygroundEvents.Kind.CLOCK, PlaygroundEvents.write_clock(clock_fn.call()))

	# And everything already in the world. A player who joins a sandbox that has been
	# running for an hour has to be told about the hour's worth of props, or they walk
	# into things they cannot see.
	for instance_id in _prop_nets.keys():
		var prop := game.props.get_prop(int(instance_id))
		var behaviour: PlaygroundPropNet = _prop_nets[instance_id]
		if behaviour == null or behaviour.identity == null:
			continue
		# A wave NPC: in the table, not in the prop spawner. Without this a late joiner saw
		# none of a wave that had already arrived.
		if prop == null and _npc_kinds.has(instance_id):
			_tell(peer_id, PlaygroundEvents.Kind.PROP, PlaygroundEvents.write_prop(
				behaviour.identity.net_id, _npc_kinds[instance_id], 0, true, behaviour.net_position
			))
			continue
		if prop == null:
			continue
		_tell(peer_id, PlaygroundEvents.Kind.PROP, PlaygroundEvents.write_prop(
			behaviour.identity.net_id,
			prop.def.id,
			session_of(prop.owner_id),
			PlaygroundSpawnables.kind_of(prop.def) == PlaygroundSpawnables.Kind.ENTITY,
			behaviour.net_position
		))

	# And their own bag, whole — to them and to nobody else. A player who reconnects is
	# somebody with a bag already, and a client that waited for the next change to learn
	# what it is carrying would show an empty grid until it bought something.
	if inventory_net != null:
		inventory_net.admit(peer_id, session_id)

	# Once, so a READY said twice does not replay the backlog and the join line.
	if fresh:
		peer_admitted.emit(peer_id)


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


func _on_map_ready(map: DotMapDef) -> void:
	_broadcast(PlaygroundEvents.Kind.MAP, PlaygroundEvents.write_map(map.id))
	_register_toys()
	# Re-announced after a map change: a client rebuilt its world and needs to be told
	# who is in it again. dot-map's own sync replaces the world and nothing else.
	for session_id in _behaviours.keys():
		_broadcast(PlaygroundEvents.Kind.JOIN, _join_body(int(session_id)))


# --- Both ends: the map's toys ---------------------------------------------------

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


## Server: an entity for each of the map's toys, and TOYS naming them.
func _register_toys() -> void:
	if net == null or not net.is_server or game == null:
		return
	_release_toys()
	var ids := PackedInt64Array()
	if game.toys != null:
		for toy in game.toys.toys:
			var behaviour := _toy_entity(toy, toy, 0)
			if behaviour == null:
				break
			ids.append(behaviour.identity.net_id)
	_toys_body = PlaygroundEvents.write_toys(game.maps.current.id if game.maps.current != null else &"", ids)
	_broadcast(PlaygroundEvents.Kind.TOYS, _toys_body)


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


## Client, on TOYS: a mirror for every id at once, under the holder, whether this end's toys
## for that map exist yet or not. [b]A client must know every entity a snapshot carries[/b]:
## dot-net stops reading a snapshot at the first one it does not know (a body cannot be skipped
## without its declarations), so a toy mirror missing while the client loads the map, or ever,
## on a client left on another map, was every player after it frozen. Paired with its toy
## by index as soon as both are here.
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


# --- Client: asking --------------------------------------------------------

func ask_ready() -> void:
	_ask(PlaygroundEvents.Ask.READY, PackedByteArray())


func ask_spawn_prop(prop_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.SPAWN_PROP, PlaygroundEvents.write_id(prop_id))


func ask_weapon(weapon_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.GIVE_WEAPON, PlaygroundEvents.write_id(weapon_id))


## What the toy in hand should throw. See [constant PlaygroundEvents.Ask.ARM_PROP].
func ask_arm(prop_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_id(prop_id))


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


# --- Server: answering -----------------------------------------------------

func _on_request(message: DotNetMessage) -> void:
	var ask := message as PlaygroundRequest
	if ask == null or net == null or not net.is_server:
		return

	var peer_id := ask.sender_peer_id

	# Before the seat check: a READY can come before the seat (see `_ready_unseated`), and
	# `_admit` keeps it rather than drop it.
	if ask.kind == PlaygroundEvents.Ask.READY:
		_admit(peer_id)
		return

	var session_id := player_for_peer(peer_id)
	if session_id == 0:
		return

	var id := _player_key(session_id)
	var reader := ask.reader()

	match ask.kind:
		PlaygroundEvents.Ask.SPAWN_PROP:
			_spawn_for(id, PlaygroundEvents.read_id(reader))
		PlaygroundEvents.Ask.GIVE_WEAPON:
			_give_weapon(session_id, id, PlaygroundEvents.read_id(reader))
		PlaygroundEvents.Ask.SELECT_TOOL:
			_select_tool(session_id, id, PlaygroundEvents.read_id(reader))
		PlaygroundEvents.Ask.ARM_PROP:
			var arm := PlaygroundEvents.read_arm(reader)
			if not bool(arm["ok"]):
				return
			match int(arm["sub"]):
				PlaygroundEvents.ARM_TOOL:
					_set_tool_mode(session_id, arm["id"] as StringName, str(arm["payload"]))
				PlaygroundEvents.ARM_NPC_WEAPON:
					var chosen := game.set_npc_weapon_choice(id, arm["id"] as StringName)
					if not chosen.ok:
						_tell(peer_id, PlaygroundEvents.Kind.NOTICE,
							PlaygroundEvents.write_notice(session_id, chosen.error.message))
				PlaygroundEvents.ARM_SPAWN_WEAPON:
					var weapon_id := arm["id"] as StringName
					if game.weapon_def(weapon_id) != null:
						_spawn_for(id, Playground.pickup_id_of(weapon_id))
				PlaygroundEvents.ARM_BUILDS:
					builds_requested.emit(peer_id)
				PlaygroundEvents.ARM_LOAD_BUILD:
					build_load_requested.emit(peer_id, String(arm["id"]))
				PlaygroundEvents.ARM_ADDON_ITEM:
					var looked: Variant = JSON.parse_string(str(arm["payload"])) if str(arm["payload"]) != "" else null
					var at := Vector3.ZERO
					if looked is Array and (looked as Array).size() == 3:
						at = Vector3(float(looked[0]), float(looked[1]), float(looked[2]))
					var started := game.activate_addon_item(String(arm["id"]), session_id, at, id)
					DotLog.result(CHANNEL, "an addon item was asked for", started)
					if not started.ok:
						_tell(peer_id, PlaygroundEvents.Kind.NOTICE,
							PlaygroundEvents.write_notice(session_id, started.error.message))
				_:
					var prop_id := arm["id"] as StringName
					if game.props.catalogue != null and game.props.catalogue.get_prop(prop_id) != null:
						_armed_of[session_id] = prop_id
						var toy: PlaygroundWeapon = _toy_of.get(session_id)
						if toy != null:
							toy.armed = prop_id
		PlaygroundEvents.Ask.UNDO:
			game.props.undo(id)
		PlaygroundEvents.Ask.CLEAR_MINE:
			game.props.clear_player(id)
		PlaygroundEvents.Ask.RESTART:
			game.spawn_player(id)
		PlaygroundEvents.Ask.CHECKPOINT:
			# A run timer's practice checkpoints; nothing to do without one.
			var action := PlaygroundEvents.read_index(reader)
			if game.run_timer != null:
				game.run_timer.call("checkpoint", id, action)
		PlaygroundEvents.Ask.RTV:
			game.rock_the_vote(id)
		PlaygroundEvents.Ask.SAY:
			var said := PlaygroundEvents.read_say(reader)

			if bool(said["ok"]):
				# Emitted rather than acted on. Everything about what a line means is
				# [DotChatRouter]'s, and the router is [PlaygroundModule]'s.
				say_requested.emit(
					peer_id, StringName(str(said["channel"])), str(said["text"])
				)
		PlaygroundEvents.Ask.VOTE:
			vote_requested.emit(peer_id, PlaygroundEvents.read_vote(reader))
		PlaygroundEvents.Ask.LOADOUT:
			var wanted := PlaygroundEvents.read_loadout(reader)

			if bool(wanted["ok"]):
				loadout_requested.emit(peer_id, wanted["pairs"])
		PlaygroundEvents.Ask.USE_VEHICLE:
			var used := game.use_vehicle(id)

			# A refusal goes back to the one player who asked. "There is nowhere to
			# stand" is the single most confusing thing this system can do silently: the
			# player presses the key, nothing happens, and there is no way to tell it
			# from a key that is not bound.
			if not used.ok:
				_tell(peer_id, PlaygroundEvents.Kind.NOTICE,
					PlaygroundEvents.write_notice(session_id, used.error.message))
		PlaygroundEvents.Ask.STYLE:
			if game.set_player_style(id, _style_id(PlaygroundEvents.read_index(reader))):
				_broadcast(PlaygroundEvents.Kind.JOIN, _join_body(session_id))
		PlaygroundEvents.Ask.INVENTORY:
			if inventory_net != null:
				inventory_net.on_ask(peer_id, session_id, reader)


## Asked before anything is spawned or given, and charged for if it is allowed.
##
## [code](player_id: StringName, thing_id: StringName) -> DotResult[/code]
##
## [b]A callable rather than a reference to the shop.[/b] The bridge is dot-net's half of
## this game and knows nothing about prices; the shop lives on the module beside the
## arena and the waves. Unset means everything is free, which is the sandbox this game
## was before there was a price list — so a caller never has to branch on whether a shop
## exists, and there is no second code path to keep in step.
var charge_fn: Callable = Callable()

## Asked before something is spawned, and charges nothing. The shop's `may_have`.
##
## [code](player_id: StringName, thing_id: StringName) -> DotResult[/code]
##
## What lets a spawn be paid for AFTER it happened without spawning things nobody can
## afford — see [method _spawn_for]. Unset answers yes, and the charge after the spawn is
## then the only check.
var may_charge_fn: Callable = Callable()

## Handed every shot a zee weapon fires on this server, once the props it hit are shoved.
##
## [code](player_id: StringName, shot: DotShot) -> void[/code]
##
## The arena's dot-combat, set by the module while `pg_arena` is on. A callable for the
## shop's reason: health is the arena layer's, which is the module's, and the bridge must
## not know whether there is a fight. Unset, a shot moves props and hurts nobody.
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


## Spawns in front of the player who asked, which is what the menu means by "spawn".
##
## The budget, the cooldown and the undo stack are the SPAWNER's, not this bridge's: a
## refusal comes back through `refused` and is forwarded to that player alone. A bridge
## that checked them itself would be a second copy of a rule, which is the bug this
## family has now shipped three times.
func _spawn_for(id: StringName, prop_id: StringName) -> void:
	var player: PlaygroundPlayer = game.players.get(id)
	if player == null or game.props.catalogue == null:
		return

	var def := game.props.catalogue.get_prop(prop_id)
	if def == null:
		_tell(peer_for_player(session_of(id)), PlaygroundEvents.Kind.NOTICE,
			PlaygroundEvents.write_notice(session_of(id), "No such prop: %s" % prop_id))
		return

	# [b]Carried first.[/b] Something in the bag was paid for when it went in, so spawning
	# it costs nothing and takes it out — which is what the bag is FOR: without this a
	# purchase into it bought a grid cell and nothing else, and every spawn was charged
	# again. Taken only once the spawner has said yes, so a spawn the prop budget refuses
	# leaves the bag as it was.
	var bag := inventory_net.bag_key(session_of(id)) if inventory_net != null else &""
	if bag != &"" and game.inventory.carries(bag, def.id) > 0:
		var at_bag := player.eye_position() + player.aim_direction() * 3.0
		if game.props.spawn(def.id, id, at_bag) != null:
			var taken := game.inventory.take(bag, def.id)
			if not taken.ok:
				DotLog.warn(CHANNEL, "a prop spawned from a bag that then refused to give it up", {
					"player": String(id), "prop": String(def.id), "why": taken.error.message,
				})
		return

	# [b]Asked, spawned, and only THEN charged.[/b] It was charged first, so a spawn the
	# prop budget refused had already been paid for: credits gone and nothing in the world,
	# which is the one bug report a shop must not produce (and which `PlaygroundShop.charge`
	# says in as many words). Refunding on a refusal is the other order and it is not
	# atomic: dot-economy's refund is a POLICY — off on a server with `refund_ticks` 0, off
	# for an item that is not refundable, closed with the buy window — so a refund can itself
	# be refused, on exactly the servers that turned refunds off. The spawner's refusals, on
	# the other hand, are many (budget, interval, size, entitlement, missing content, no
	# world) and only known by trying, while "can they afford it" is one read that changes
	# nothing. So: that read, then the spawn, then the charge.
	#
	# Refused with a reason. A refusal that says nothing is the one thing a price list must
	# not do: the player presses the button, nothing appears, and there is no way to tell it
	# from a broken menu.
	var affordable := _may_charge(id, def.id)

	if not affordable.ok:
		_tell(peer_for_player(session_of(id)), PlaygroundEvents.Kind.NOTICE,
			PlaygroundEvents.write_notice(session_of(id), affordable.error.message))
		return

	# Three metres in front of the eye, the same distance `pg_prop` uses. A player who
	# spawns a crate expects it where they are looking, not at their feet.
	var at := player.eye_position() + player.aim_direction() * 3.0
	var spawned := game.props.spawn(def.id, id, at)

	if spawned == null:
		# Refused by the spawner, which has already told the player why through `refused`
		# (see _on_prop_refused). Nothing has been charged.
		return

	var paid := _charge(id, def.id)

	if not paid.ok:
		# The question said yes and the purse said no — nothing runs between the two on
		# this thread, so this is a charge_fn with no may_charge_fn beside it, or two that
		# disagree. Taken back out rather than left standing for free.
		game.props.remove(spawned.instance_id, DotPropSpawner.REASON_CLEANUP)
		_tell(peer_for_player(session_of(id)), PlaygroundEvents.Kind.NOTICE,
			PlaygroundEvents.write_notice(session_of(id), paid.error.message))
		DotLog.warn(CHANNEL, "a spawn was refused its charge after it had been placed", {
			"player": String(id), "prop": String(def.id), "why": paid.error.message,
		})


func _give_weapon(session_id: int, id: StringName, weapon_id: StringName) -> void:
	var player: PlaygroundPlayer = game.players.get(id)
	if player == null or game.weapon_def(weapon_id) == null:
		return

	var paid := _charge(id, weapon_id)

	if not paid.ok:
		_tell(peer_for_player(session_id), PlaygroundEvents.Kind.NOTICE,
			PlaygroundEvents.write_notice(session_id, paid.error.message))
		return

	# [b]A zee weapon is run HERE, and that is the difference.[/b] The toys are actuated by
	# the client that holds them; a gun the server did not run is a client deciding what
	# it hit. So the server holds a rig of its own, and `_drive_tools` ticks it.
	var def := game.weapon_def(weapon_id)

	# [b]The gun already in hand, asked for again, is ammunition[/b], not a fresh rig: a fresh
	# one would redraw it and say nothing. The client's drawn gun is not told; it takes the
	# count from the owner's snapshot once quiet (`PlaygroundPlayerNet._correct_drawn`).
	if PlaygroundZee.is_zee(def) and _tool_of.get(session_id, &"") == weapon_id \
			and player.zee_rig is ZeeWeaponRig and is_instance_valid(player.zee_rig):
		if PlaygroundZee.refill(player.zee_rig):
			_tell(peer_for_player(session_id), PlaygroundEvents.Kind.NOTICE,
				PlaygroundEvents.write_notice(session_id, "Ammunition refilled."))
		return

	_drop_toy(session_id)
	if PlaygroundZee.is_zee(def):
		game.phys_gun_release(player)
		player.grav_gun.drop()
		if PlaygroundZee.arm(
			player, def, ZeeWeaponRig.Role.SERVER, true, game.tick_rate, game.current_tick()
		) != null:
			_tool_of[session_id] = weapon_id
	else:
		PlaygroundZee.disarm(player)
		var toy := PlaygroundWeapons.make(def)
		if toy != null:
			game.phys_gun_release(player)
			player.grav_gun.drop()
			toy.equip(game, def)
			toy.wielder = id
			toy.armed = _armed_of.get(session_id, &"")
			_restore_tool_mode(session_id, toy)
			_toy_of[session_id] = toy
			_tool_of[session_id] = weapon_id

	_broadcast(PlaygroundEvents.Kind.WEAPON, PlaygroundEvents.write_weapon(session_id, weapon_id))


## The tool gun's mode and settings, from the Q menu's tools tab. JSON, capped on the wire
## and parsed here; the mode clamps every value to its own schema, because these numbers
## come from a client.
func _set_tool_mode(session_id: int, mode: StringName, payload: String) -> void:
	var parsed: Variant = JSON.parse_string(payload) if payload != "" else {}
	var settings: Dictionary = parsed if parsed is Dictionary else {}
	_tool_settings_of[session_id] = [mode, settings]

	var toy: PlaygroundWeapon = _toy_of.get(session_id)
	if toy != null and toy.has_method("set_mode"):
		var set: DotResult = toy.call("set_mode", mode, settings)
		if not set.ok:
			_tell(peer_for_player(session_id), PlaygroundEvents.Kind.NOTICE,
				PlaygroundEvents.write_notice(session_id, set.error.message))
			return
		# An edit lands on the selected prop as it arrives; the answer is what the prop now
		# is, so a value clamped or refused (a freeze over the limit) springs back in the menu.
		var tool: Object = toy.call("current") if toy.has_method("current") else null
		if tool != null and tool.has_method("selection_report"):
			var report: Dictionary = tool.call("selection_report")
			if report.get("node") != null or str(report.get("refused", "")) != "":
				_tell_selection(session_id, report)


## Tells one player what their tool gun has selected. The prop is named by the net id it
## replicates under, so the client can find its own mirror of it.
func _tell_selection(session_id: int, report: Dictionary) -> void:
	var node: Variant = report.get("node")
	var net_id := net_id_of_node(node) if node is Node else 0
	_tell(peer_for_player(session_id), PlaygroundEvents.Kind.SELECTION, PlaygroundEvents.write_selection(
		net_id, str(report.get("name", "")), report.get("settings", {}), str(report.get("refused", ""))
	))


## The body a client draws for [param net_id], or null. Client side.
func mirror_of(net_id: int) -> Node3D:
	return _mirror_node(net_id)


func _restore_tool_mode(session_id: int, toy: PlaygroundWeapon) -> void:
	var saved: Variant = _tool_settings_of.get(session_id)
	if saved is Array and toy.has_method("set_mode"):
		var _set: DotResult = toy.call("set_mode", saved[0], saved[1])


## Somebody walked over a weapon on the server. It is given exactly as one from the menu
## is — charged, armed on a server rig — so a pickup cannot be a way round either.
func _on_weapon_picked_up(player_id: StringName, weapon_id: StringName) -> void:
	if net == null or not net.is_server:
		return
	_give_weapon(session_of(player_id), player_id, weapon_id)


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


## Puts one of this player's saved builds down in front of them. Client side.
func ask_load_build(build_name: String) -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_arm(
		PlaygroundEvents.ARM_LOAD_BUILD, StringName(build_name)
	))


## Asks the server to start an addon's menu entry, [param key] being `addon/item`, with the
## point the player is looking at. Client side.
func ask_addon_item(key: String, at: Vector3) -> void:
	_ask(PlaygroundEvents.Ask.ARM_PROP, PlaygroundEvents.write_arm(
		PlaygroundEvents.ARM_ADDON_ITEM, StringName(key), JSON.stringify([at.x, at.y, at.z])
	))


## A player's saved builds, to that player. Server side.
func send_builds(peer_id: int, list: Array) -> void:
	_tell(peer_id, PlaygroundEvents.Kind.BUILDS, PlaygroundEvents.write_builds(list))


## A line on one player's HUD. Server side.
func tell_notice(peer_id: int, text: String) -> void:
	_tell(peer_id, PlaygroundEvents.Kind.NOTICE,
		PlaygroundEvents.write_notice(player_for_peer(peer_id), text))


func _drop_toy(session_id: int) -> void:
	var toy: PlaygroundWeapon = _toy_of.get(session_id)
	if toy != null:
		toy.holster()
	_toy_of.erase(session_id)


## What a toy's button did: a prop it spawned is paid for, and a refusal with a reason is
## told to the player, who otherwise pressed a button and saw nothing.
func _toy_result(session_id: int, id: StringName, toy: PlaygroundWeapon, res: DotResult) -> void:
	if res == null:
		return
	if not res.ok:
		if res.error != null and res.error.message != "":
			_tell(peer_for_player(session_id), PlaygroundEvents.Kind.NOTICE,
				PlaygroundEvents.write_notice(session_id, res.error.message))
		return
	# The tool gun's edit mode answers with what it selected.
	if res.value is Dictionary and (res.value as Dictionary).has("settings"):
		_tell_selection(session_id, res.value)
		return
	# The remover answers with a count, the launcher with what it spawned.
	if not (res.value is DotPropInstance):
		return
	var spawned: DotPropInstance = res.value
	var paid := _charge(id, spawned.def.id if spawned.def != null else toy.armed)
	if not paid.ok:
		game.props.remove(spawned.instance_id, DotPropSpawner.REASON_CLEANUP)
		_tell(peer_for_player(session_id), PlaygroundEvents.Kind.NOTICE,
			PlaygroundEvents.write_notice(session_id, paid.error.message))


func _select_tool(session_id: int, id: StringName, tool_id: StringName) -> void:
	if not game.players.has(id):
		return
	if tool_id != &"phys" and tool_id != &"grav":
		return

	# Whatever the old tool was holding is let go. A player who swaps to the gravity gun
	# with a crate on the end of the physics gun would otherwise leave it hanging in the
	# air, owned by a tool they are no longer using and released by nothing.
	var player: PlaygroundPlayer = game.players.get(id)
	if player != null:
		game.phys_gun_release(player)
		player.grav_gun.drop()
		PlaygroundZee.disarm(player)
	_drop_toy(session_id)

	_tool_of[session_id] = tool_id
	_broadcast(PlaygroundEvents.Kind.WEAPON, PlaygroundEvents.write_weapon(session_id, tool_id))


# --- Client: applying ------------------------------------------------------

func _on_event(message: DotNetMessage) -> void:
	var event := message as PlaygroundEvent
	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		PlaygroundEvents.Kind.HELLO:
			_apply_hello(reader)
		PlaygroundEvents.Kind.JOIN:
			_apply_join(reader)
		PlaygroundEvents.Kind.LEAVE:
			var session_id := PlaygroundEvents.read_player(reader)
			_release_entity(session_id)
			game.remove_player(_player_key(session_id))
			roster_changed.emit(session_id)
		PlaygroundEvents.Kind.MAP:
			var map_id := PlaygroundEvents.read_map(reader)
			if game.maps.current == null or game.maps.current.id != map_id:
				game.change_map(map_id)
		PlaygroundEvents.Kind.ADDON:
			var said_by := PlaygroundEvents.read_addon(reader)
			if bool(said_by["ok"]) and game.addons != null:
				game.addons.deliver(str(said_by["addon"]), said_by["body"])
		PlaygroundEvents.Kind.TOYS:
			var told := PlaygroundEvents.read_toys(reader)
			if bool(told["ok"]):
				_apply_toys(told)
		PlaygroundEvents.Kind.PROP:
			_apply_prop(reader)
		PlaygroundEvents.Kind.PROP_GONE:
			_apply_prop_gone(reader)
		PlaygroundEvents.Kind.WEAPON:
			var held := PlaygroundEvents.read_weapon(reader)
			if bool(held["ok"]):
				PlaygroundZee.show_held(
					game.players.get(_player_key(int(held["player_id"]))),
					game.weapon_def(held["weapon_id"] as StringName)
				)
				weapon_changed.emit(
					int(held["player_id"]), held["weapon_id"] as StringName
				)
		PlaygroundEvents.Kind.PANE:
			var pane := PlaygroundEvents.read_pane(reader)
			if bool(pane["ok"]):
				game.break_pane(int(pane["index"]))
		PlaygroundEvents.Kind.HELD:
			var holding := PlaygroundEvents.read_held(reader)
			if bool(holding["ok"]):
				if int(holding["net_id"]) > 0:
					held_props[int(holding["player_id"])] = int(holding["net_id"])
				else:
					held_props.erase(int(holding["player_id"]))
		PlaygroundEvents.Kind.NOTICE:
			var notice := PlaygroundEvents.read_notice(reader)
			if bool(notice["ok"]):
				notice_received.emit(int(notice["player_id"]), str(notice["text"]))
		PlaygroundEvents.Kind.SEAT:
			_apply_seat(reader)
		PlaygroundEvents.Kind.CHAT:
			var wire := PlaygroundEvents.read_chat(reader)

			if bool(wire["ok"]):
				chat_received.emit(wire)
		PlaygroundEvents.Kind.COMBAT:
			var hit := PlaygroundEvents.read_combat(reader)

			if bool(hit["ok"]):
				combat_received.emit(hit)
		PlaygroundEvents.Kind.MATCH:
			var clock := PlaygroundEvents.read_match(reader)

			if bool(clock["ok"]):
				match_received.emit(clock)
		PlaygroundEvents.Kind.PROGRESS:
			var earned := PlaygroundEvents.read_progress(reader)

			if bool(earned["ok"]):
				progress_received.emit(earned)
		PlaygroundEvents.Kind.VOTE:
			var cue := PlaygroundEvents.read_vote_cue(reader)

			if bool(cue["ok"]):
				vote_cue_received.emit(cue)
		PlaygroundEvents.Kind.CLOCK:
			var clock := PlaygroundEvents.read_clock(reader)

			if bool(clock["ok"]):
				clock_view.adopt(clock, Time.get_ticks_msec() / 1000.0)
				clock_received.emit(clock)
		PlaygroundEvents.Kind.INVENTORY:
			if inventory_net != null:
				inventory_net.on_tell(reader)
		PlaygroundEvents.Kind.PROJECTILE:
			_apply_projectile(reader)
		PlaygroundEvents.Kind.BUILDS:
			var listed := PlaygroundEvents.read_builds(reader)
			if bool(listed["ok"]):
				builds_received.emit(listed["builds"])
		PlaygroundEvents.Kind.SELECTION:
			var picked := PlaygroundEvents.read_selection(reader)
			if bool(picked["ok"]):
				selection_received.emit(picked)
		PlaygroundEvents.Kind.HIT:
			var hit := PlaygroundEvents.read_hit(reader)
			if bool(hit["ok"]):
				hit_received.emit(int(hit["victim"]), float(hit["amount"]), hit["point"],
					bool(hit["killed"]), bool(hit["headshot"]))


# --- Projectiles ---------------------------------------------------------------

## Every launch to every client, so each flies a copy and draws the arc. Sent once rather
## than replicated as an entity: a grenade lives two or three seconds, its path is a pure
## function of where it left and how fast, and an entity per grenade would be an identity,
## an interest-grid cell and a snapshot field for something the client can work out.
func _on_projectile_launched(flying: RefCounted) -> void:
	_broadcast(PlaygroundEvents.Kind.PROJECTILE, PlaygroundEvents.write_launch(
		int(flying.get("serial")), flying.get("spawn"), flying.get("owner_id"), bool(flying.get("sticks"))
	))


## Where it went off, which the client's copy does not decide for itself — see
## PlaygroundProjectiles.
func _on_projectile_detonated(serial: int, at: Vector3, radius: float) -> void:
	_broadcast(PlaygroundEvents.Kind.PROJECTILE, PlaygroundEvents.write_detonate(serial, at, radius))


func _apply_projectile(reader: DotNetReader) -> void:
	if game.projectiles == null:
		return

	match reader.read_uint(PlaygroundEvents.PROJECTILE_SUB_BITS):
		PlaygroundEvents.ProjectileTell.LAUNCH:
			var launch := PlaygroundEvents.read_launch(reader)
			if bool(launch["ok"]):
				var _flying: Variant = game.projectiles.launch(
					launch["spawn"], launch["owner_id"], RID(), int(launch["serial"])
				)
		PlaygroundEvents.ProjectileTell.DETONATE:
			var blast := PlaygroundEvents.read_detonate(reader)
			if bool(blast["ok"]):
				game.projectiles.detonate_remote(
					int(blast["serial"]), blast["position"], float(blast["radius"])
				)


func _apply_hello(reader: DotNetReader) -> void:
	var hello := PlaygroundEvents.read_hello(reader)
	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])

	# Before anything else arrives for it: the bag that follows is this identity's.
	if inventory_net != null:
		inventory_net.on_hello(local_player_id)

	# [b]The server's tick rate, before anything is derived from it.[/b] game-g2gfast
	# shipped with HELLO carrying this and nothing reading it: a browser client counted
	# at the 60 its export declared against a server on 128, so the correction rate was
	# 0.96 and every replicated time was out by 128/60. Produced correctly and consumed
	# by nothing, which is this family's most repeated bug — and invisible to a
	# one-process suite, because one process has one engine rate and both ends agree no
	# matter what the wire says.
	#
	# Before sync_from_server, because the clock converts its error and its lead
	# through tick_rate and would otherwise do that arithmetic at the old rate.
	_adopt_tick_rate(int(hello["tick_rate"]))

	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	var map_id: StringName = hello["map_id"]
	if map_id != &"" and (game.maps.current == null or game.maps.current.id != map_id):
		game.change_map(map_id)

	_claim_local_player()

	hello_received.emit(local_player_id)


## Puts the whole client — game, timers, netcode clock and the ENGINE — on the server's
## tick rate.
##
## Four places hold this number and all four have to move together. `game.tick_rate` is
## the step the simulation and every reconstituted run time use; `net.config.tick_rate`
## is what [method DotNetInput.sanitise] and the interpolator's extrapolation budget
## read; `net.clock.tick_rate` is the live one, built from the config back at `setup()`
## and therefore NOT updated by writing the config alone; and
## `Engine.physics_ticks_per_second` is the one that decides whether it LOOKS right.
##
## That last one is not cosmetic. Measured in g2gfast at 60 against 128: the simulation
## stayed correct, because the clock is asked how many ticks a frame is worth — it just
## ran them in bursts of two and three, and the camera advanced 74 mm on six frames out
## of seven and 112 mm on the seventh. A 47% change in apparent speed, eight times a
## second. Interpolating between ticks does not fix it on its own and neither does this;
## the fraction a renderer interpolates at is a fraction through a PHYSICS frame, which
## is a fraction through a tick only while the two rates agree.
##
## A server never calls this: its rate is `sv_tickrate`, and adopting a peer's would be
## a client telling the server how fast to run.
func _adopt_tick_rate(rate: int) -> void:
	if net == null or net.is_server or game == null or rate <= 0 or rate == game.tick_rate:
		return

	var before := game.tick_rate

	if not game.set_tick_rate(rate):
		return

	net.config.tick_rate = game.tick_rate
	net.clock.tick_rate = game.tick_rate
	# dot-net API 7 has DotNetClock.adopt_tick_rate(), which also raises the engine's step cap
	# to a quarter second of ticks (8 steps are 62.5 ms at 128 Hz, so a client under 16 fps ran
	# fewer ticks than the server). A shell built before it gets the same rule here, as
	# game-g2gfast does; remove this branch when the oldest shell is API 7.
	if DotAddonApi.build_level("dot_net") >= 7:
		DotNetClock.adopt_tick_rate(game.tick_rate)
	else:
		Engine.max_physics_steps_per_frame = maxi(Engine.max_physics_steps_per_frame, ceili(0.25 * float(game.tick_rate)))
		Engine.physics_ticks_per_second = game.tick_rate

	DotLog.info(CHANNEL, "adopted the server's tick rate", {
		"was": before, "now": game.tick_rate, "engine": Engine.physics_ticks_per_second,
	})


func _apply_join(reader: DotNetReader) -> void:
	var join := PlaygroundEvents.read_join(reader)
	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var id := _player_key(session_id)

	var player: PlaygroundPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]))
		if player == null:
			return
		# A client never samples: the client loop hands it commands.
		player.sampler = null
		player.samples_input = false

		# [b]This client's own player is owned by this client, and nobody else is.[/b] Until
		# 2026-09-25 every mirror was built with owner 0, the local one included — so on a
		# connected client `is_owner` was false for it, `registry.predicted()` was empty,
		# `client_tick` simulated nobody, and the player moved only when a snapshot came
		# back: INPUT_LEAD + 1 ticks behind the key. No check saw it, because "it moves" and
		# "the server agrees" both hold for a client that adopts every snapshot, and the
		# correction rate is lowest of all for a predictor that never runs. headless_net's
		# "this client predicts its own player" is the section that sees it.
		var identity := _build_entity(player, _mirror_owner(session_id))
		var registered := net.registry.register(
			identity, int(join["net_id"]), net.clock.tick, net.config
		)
		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			game.remove_player(id)
			return
	else:
		player.display_name = str(join["name"])

	game.set_player_style(id, _style_id(int(join["style_index"])))
	var mirrored: PlaygroundPlayer = game.players.get(id)
	if mirrored != null:
		mirrored.set_skins(join.get("skins", PackedInt32Array()))
	roster_changed.emit(session_id)


## Who owns a mirrored player on this client: this client, if it is this client's own
## player, and the server's 0 otherwise.
##
## [b]Matched by session id, not sent on the wire.[/b] game-g2gfast and game-arena put the
## owner's peer id in JOIN instead; that changes the JOIN format, and then a client can only
## predict if its own `local_peer_id` is exactly the number the server knows it by. Here the
## session id HELLO already carries is the whole answer, the wire is unchanged, and the
## owner on this side is `net.local_peer_id` whatever that turns out to be — `is_owner` is
## owner == local peer, so the two can never disagree. The server's own `until_acked` rule
## uses the server's copy of the owner, which was always right.
##
## [b]Never the local peer for anybody else[/b], or this client would predict somebody whose
## keys it never had. And a client whose local peer is 0 claims nothing: 0 is the server's
## owner id, and on such a registry dot-net's `is_owner` is already true of every owner-0
## mirror — which this cannot undo, and which no client here runs into, because
## `PlaygroundClient` takes its id from the multiplayer API and that never answers 0.
func _mirror_owner(session_id: int) -> int:
	if net == null or net.local_peer_id <= 0:
		return 0

	if local_player_id != 0 and session_id == local_player_id:
		return net.local_peer_id

	return 0


## The local player's mirror, claimed if it arrived before HELLO said whose it was.
##
## Not the order `_admit` sends in, which is why this is belt and braces rather than a path
## this game takes: a JOIN broadcast that reached this peer before its HELLO would otherwise
## leave the local player unpredicted for the rest of the session, with every other check
## still passing — which is the bug [method _apply_join] documents. A vehicle is never
## claimed: it is not a player mirror, and a rigid body is not predicted (family decision).
func _claim_local_player() -> void:
	var mine: PlaygroundPlayerNet = _behaviours.get(local_player_id)

	if mine == null or mine.identity == null or not mine.identity.is_registered():
		return

	var claimed := _mirror_owner(local_player_id)

	if claimed == 0 or mine.identity.owner_peer_id == claimed:
		return

	DotLog.debug(CHANNEL, "claimed the local player after HELLO", {
		"session": local_player_id, "net_id": mine.identity.net_id,
	})
	var _changed := net.registry.change_owner(mine.identity.net_id, claimed)


## Builds the client's copy of a prop and mirrors the net id it was given.
##
## [b]Adopted, never allocated.[/b] A receiving peer has to take the id it was sent —
## dot-2d's scatter had exactly this bug and could not be mirrored at all until it grew
## an `adopt()`. Registering with 0 here would give the prop a different id on every
## client and every snapshot for it would land on nothing.
func _apply_prop(reader: DotNetReader) -> void:
	var info := PlaygroundEvents.read_prop(reader)
	if not bool(info["ok"]):
		return

	var net_id := int(info["net_id"])

	if _prop_nets.has(net_id):
		return

	if game.props.catalogue == null:
		return

	var def := game.props.catalogue.get_prop(info["kind_id"])
	var scene_path := def.scene_path if def != null else ""

	# A wave NPC: drawn from the waves' catalogue, as a bare body with no brain — the server
	# thinks for it, exactly as it does for an NPC entity.
	if npc_catalogue == null:
		# A client never runs the module that sets it. The waves' catalogue is a static of
		# the game's own, the same on both ends — which is what makes a kind id meaningful.
		npc_catalogue = PlaygroundWaves.shared_catalogue()

	if def == null and npc_catalogue != null:
		var npc_def := npc_catalogue.get_npc(info["kind_id"])
		if npc_def != null:
			scene_path = npc_def.scene_path

	if def == null and scene_path == "":
		# Not an error: a server may run a catalogue this build does not have, and the
		# honest answer is to draw nothing rather than to guess.
		DotLog.debug(CHANNEL, "a prop this build does not have", {"id": str(info["kind_id"])})
		return

	var scene: PackedScene = load(scene_path) if scene_path != "" else null
	if scene == null:
		DotLog.warn(CHANNEL, "a prop's scene would not load", {"path": scene_path})
		return

	var body := scene.instantiate() as Node3D
	if body == null:
		return

	# [b]Frozen before it enters the tree, not on its first draw.[/b]
	# `PlaygroundPropNet._draw` freezes a mirror too, but only once an interpolated
	# frame arrives — and until then the mirror was a live rigid body falling under the
	# client's own physics, which is exactly the movement `headless_net`'s "it falls on
	# the client because the server's physics moved it" exists to rule out.
	var rigid := body as RigidBody3D
	if rigid != null:
		rigid.freeze = true

	var world := game.world if game.world != null else game
	world.add_child(body)
	body.global_position = info["position"]

	var as_prop := body as PlaygroundProp
	if as_prop != null and def != null:
		as_prop.configure(def)
	elif def == null:
		# A wave NPC's mirror, dressed by the rule the server's own copy was.
		PlaygroundWaves.dress(body, str(info["kind_id"]))

	# [b]On the layout's layer, not the scene's 1/1.[/b] The server classifies every
	# spawned body (`Playground._classify_spawned`) and a mirror used to keep whatever the
	# scene had — layer 1 masking 1, the world's — so a crate was scenery to this client
	# and a prop to the server. That matters now the client predicts its own player: its
	# sweeps run against its own copy of the world, and a copy whose props sit on another
	# layer is a world the server does not move that player through. A client has a
	# layout even though it applies no physics (see `PlaygroundPlayerStack._build_physics`).
	#
	# The PROP event carries no frozen state, so a mirror is classified as the spawn left
	# it on the server only when that is unfrozen; a prop frozen or held later is
	# reclassified on the server and not here. See docs/netcode.md on `[prop-mirror-layer-1]`.
	if game.player_stack != null and def != null:
		var _put := game.player_stack.classify(body, Playground.layer_for(def, false))

	# An NPC's script is attached on the server and its behaviour runs there. A client
	# copy is a body being drawn where the server says it is, so the script is
	# deliberately NOT attached here: it would run a second, disagreeing AI.

	var behaviour := _behaviour_for(def)
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	body.add_child(identity)

	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not mirror a prop", {"error": str(registered.error)})
		body.queue_free()
		return

	_prop_nets[net_id] = behaviour
	behaviour.mirror_of = _mirror_node
	behaviour.tick_seconds_fn = func() -> float: return net.clock.tick_duration()
	props_changed.emit()
	prop_arrived.emit(body.global_position, int(info["owner_id"]))


func _on_ride_entered(
	vehicle: DotVehicleInstance, rider_id: StringName, seat: DotVehicleSeat
) -> void:
	announce_seat(vehicle, rider_id, seat, true)


## Somebody was picked up or let go. A SEAT with no vehicle: the held client stops
## predicting and adopts the server's position, which is all being carried needs — and
## exactly what a client older than picking up does with it.
func _on_pickup_changed(_holder_id: StringName, target_id: StringName, held: bool) -> void:
	if net == null or not net.is_server:
		return
	_broadcast(PlaygroundEvents.Kind.SEAT, PlaygroundEvents.write_seat(session_of(target_id), 0, 0, held))


func _on_ride_exited(
	vehicle: DotVehicleInstance,
	rider_id: StringName,
	seat: DotVehicleSeat,
	_at: Vector3
) -> void:
	announce_seat(vehicle, rider_id, seat, false)


## A client's copy of "that player is in a car".
##
## [b]The client does not run the ride at all.[/b] It has no vehicle spawner, no exit
## sweep and no seats — the server owns every one of those — so what arrives is the
## answer rather than the question. What the client does with it is stop predicting a
## player who is no longer walking, which is the one thing it would otherwise get wrong
## on its own screen: a predicted controller simulating a passenger fights the position
## the snapshots are putting them at, every tick, at a metre a time.
func _apply_seat(reader: DotNetReader) -> void:
	var info := PlaygroundEvents.read_seat(reader)

	if not bool(info["ok"]):
		return

	var behaviour: PlaygroundPlayerNet = _behaviours.get(int(info["player_id"]))

	if behaviour == null or behaviour.player == null:
		return

	# The vehicle too, when this client has it, so the body sits facing the car's way.
	var vehicle_net: PlaygroundPropNet = _prop_nets.get(int(info["vehicle_net_id"]))
	var vehicle_node: Node3D = null
	if vehicle_net != null and is_instance_valid(vehicle_net.prop):
		vehicle_node = vehicle_net.prop as Node3D
	if int(info["vehicle_net_id"]) == 0:
		# Vehicle 0 is a player held by a physics gun (PlaygroundPickup): not predicted,
		# not seated, and no seat_changed, because nobody got into anything.
		behaviour.player.set_held(bool(info["seated"]))
		return
	behaviour.player.set_riding(bool(info["seated"]), vehicle_node)
	seat_changed.emit(int(info["player_id"]), bool(info["seated"]))


func _apply_prop_gone(reader: DotNetReader) -> void:
	var info := PlaygroundEvents.read_prop_gone(reader)
	if not bool(info["ok"]):
		return

	var net_id := int(info["net_id"])

	var behaviour: PlaygroundPropNet = _prop_nets.get(net_id)
	_prop_nets.erase(net_id)

	if behaviour == null:
		return

	if net != null:
		net.registry.unregister(net_id)

	if behaviour.prop != null and is_instance_valid(behaviour.prop):
		# A killed NPC goes down the way the server picked, copied from its drawn figure
		# before the mirror goes.
		var figure := behaviour.prop.get_node_or_null(^"Figure") as Node3D
		if info.has("death") and figure != null:
			body_fell.emit(figure, info["death"])
		behaviour.prop.queue_free()

	props_changed.emit()


# --- Sending ---------------------------------------------------------------

## To every READY peer, one at a time, and never to peer 0.
##
## [b]Not `net.send(msg, 0)`, which is an `rpc()` to every socket.[/b] A peer is connected
## — and dot-server fires `client_spawn` for it — as soon as [DotClientLink] has added the
## game scene, but this game's client builds its `Server/Playground` node only once its
## first map is up. The JOIN that `client_spawn` produces went out in that gap, and every
## real join logged "Failed to get path from RPC: Server/Playground" and "Requested node
## was not found" once. The joining peer loses nothing: [method _admit] tells it every
## player, itself included, when it says READY. `pg-rpc-before-scene`.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or body.is_empty():
		return
	for peer_id in _ready_peers.keys():
		net.send(PlaygroundEvent.new(kind, body), int(peer_id))


## To one peer, and never to peer 0.
##
## [b]Zero is the broadcast address.[/b] game-hungario gave a bot peer id 0, and every
## private per-player message sent to that bot went to every client on the server. A
## player with no peer — a bot, a test — simply is not told, which is correct: there is
## nobody there to tell.
func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or peer_id <= 0 or body.is_empty():
		return
	net.send(PlaygroundEvent.new(kind, body), peer_id)


## One chat line to one peer. Server side, and what [member DotChatRouter.send_fn] points
## at.
##
## [b]Peer by peer, never a broadcast, and that is the router's decision rather than this
## one's.[/b] It has already worked out exactly who may hear a line — everybody, a radius,
## two people in a whisper — and handing the result to a broadcast would throw that away.
func send_chat(peer_id: int, wire: Dictionary) -> void:
	_tell(peer_id, PlaygroundEvents.Kind.CHAT, PlaygroundEvents.write_chat(wire))


## Somebody's health changed, or they died. Server side.
func broadcast_combat(
	player_id: int, health: int, armour: int, attacker_id: int, died: bool,
	death: DotPlayerDeath = null
) -> void:
	_broadcast(
		PlaygroundEvents.Kind.COMBAT,
		PlaygroundEvents.write_combat(player_id, health, armour, attacker_id, died, death)
	)


## The match clock. Server side.
##
## [b]Sent rather than derived, because a mirroring client's [DotMatch] never runs.[/b]
## Nothing ticks it, so `seconds_remaining()` is computed from a tick that is still zero —
## not a stale value, a value nothing had ever written. game-arena shipped a client that
## showed `IDLE` for ever while the server was playing a round.
func broadcast_match(
	state: int, seconds_left: float, round_number: int, label: String
) -> void:
	_broadcast(
		PlaygroundEvents.Kind.MATCH,
		PlaygroundEvents.write_match(state, seconds_left, round_number, label)
	)


## The map vote's cue or countdown second. Server side.
func broadcast_vote_cue(cue: StringName, seconds_left: int, runoff: bool) -> void:
	_broadcast(
		PlaygroundEvents.Kind.VOTE,
		PlaygroundEvents.write_vote_cue(String(cue), seconds_left, runoff)
	)


## The vote's clock, to every ready peer. Server side.
func broadcast_clock(state: Dictionary) -> void:
	_broadcast(PlaygroundEvents.Kind.CLOCK, PlaygroundEvents.write_clock(state))


## Something somebody earned. Server side.
func broadcast_progress(
	player_id: int, id: StringName, title: String, value: int
) -> void:
	_broadcast(
		PlaygroundEvents.Kind.PROGRESS,
		PlaygroundEvents.write_progress(player_id, id, title, value)
	)


## Client side: say something.
func say(channel_id: StringName, text: String) -> void:
	if net == null or net.is_server or text.strip_edges() == "":
		return

	_ask(PlaygroundEvents.Ask.SAY, PlaygroundEvents.write_say(channel_id, text))


## Client side: rock the vote, nominate, or cast one.
func vote(token: String) -> void:
	if net == null or net.is_server or token.strip_edges() == "":
		return

	_ask(PlaygroundEvents.Ask.VOTE, PlaygroundEvents.write_vote(token))


## Client side: publish what to spawn with.
func publish_loadout(pairs: Array) -> void:
	if net == null or net.is_server:
		return

	_ask(PlaygroundEvents.Ask.LOADOUT, PlaygroundEvents.write_loadout(pairs))


## Everybody who has said they can receive. Server side.
##
## [b]The set chat and voice are addressed against, and deliberately not
## [method DotServer.sessions].[/b] A session exists from the moment a socket connects; a
## ready peer is one that has built its scene and can be sent to.
func ready_peers() -> PackedInt32Array:
	var out := PackedInt32Array()

	for peer_id in _ready_peers.keys():
		out.append(int(peer_id))

	return out


func peer_is_ready(peer_id: int) -> bool:
	return _ready_peers.has(peer_id)


## Takes a peer off the broadcast set without touching anything else. Server side.
func mark_not_ready(peer_id: int) -> void:
	_ready_peers.erase(peer_id)


## The ordered style table, for a test that has to check how it was BUILT rather than
## what it contains — see the note in `attach`.
func style_table() -> Array[StringName]:
	return _style_ids.duplicate()


func describe() -> Dictionary:
	return {
		"server": net.is_server if net != null else false,
		"players": _behaviours.size(),
		"props": _prop_nets.size(),
		"ready_peers": _ready_peers.size(),
		"local": local_player_id,
		"tick": _tick,
		"link": link.describe() if link != null else {},
		"inventory": inventory_net.describe() if inventory_net != null else {},
	}
