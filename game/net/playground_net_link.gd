extends Node

const PlaygroundNetBridge := preload("playground_net_bridge.gd")
const PlaygroundNetLink := preload("playground_net_link.gd")

## The four remote calls this game needs, on one node that exists on both ends.
##
## A copy of [G2GNetLink] in shape — deliberately, per the family rule that games copy
## what they need rather than growing a shared dependency — because it encodes the one
## thing that cost this family a day: Godot refuses an RPC unless both ends declare the
## same set of @rpc methods, and routes it by the receiver's node path. Using the same
## script on both ends makes the checksum identical by construction; naming the node the
## same on both ends and parenting it to a node that is itself named the same
## ([DotServer] on one side and [DotClientLink] on the other, both called
## [code]Server[/code]) is the whole of the routing.
##
## [codeblock]
## Server            <- DotServer, or DotClientLink named to match
##   Chat            <- DotChatManager / DotClientChat
##   Playground      <- this, on both
## [/codeblock]

const CHANNEL := "playground.link"

## The node name both ends must use. It is the routing, so it is a constant.
const NODE_NAME := &"Playground"

## Everything here rides [constant DotTransport.Channel.STATE], which dot-server reserves
## for exactly this and uses for nothing itself. Sharing chat's channel would make a burst
## of snapshots delay a chat line, and vice versa.
const CHANNEL_STATE := 1

## Voice, and only voice.
##
## [constant DotTransport.Channel.EVENT] is what dot-server reserves for chat and events,
## and this game's chat has moved onto [DotChatRouter] and rides `event` on the state
## channel with everything else — so this one is free. Voice gets it to itself for the
## reason the state channel exists at all: a hundred and twenty-eight snapshots a second
## must not sit behind a talk spurt, and a talk spurt must not sit behind a snapshot.
const CHANNEL_VOICE := 2

## The bridge these calls are delivered to. Set by whoever creates this node.
var bridge: PlaygroundNetBridge = null

## Whether this end is the authority. Only used to refuse an obviously misrouted call
## early, with a log line naming the node rather than a silent no-op.
var is_server: bool = false

## Where calls go instead of onto the network.
##
## Signature: [code]func(method: StringName, peer_id: int, payload: PackedByteArray)[/code],
## with [code]method[/code] one of [code]snapshot[/code], [code]event[/code],
## [code]input[/code] or [code]request[/code].
##
## [b]A test seam, and the only way this netcode can be checked at all.[/b] A real socket
## does not reproduce the same latency, reordering and loss twice, so the integration run
## puts a server and a client in one process and puts a lossy loopback between them
## instead. Unset — which is every real deployment — every send goes out as an RPC.
var loopback: Callable = Callable()

## Counters, for the console and for the self-test.
var snapshots_sent: int = 0
var snapshots_received: int = 0
var events_sent: int = 0
var events_received: int = 0
var inputs_sent: int = 0
var inputs_received: int = 0
var requests_sent: int = 0
var requests_received: int = 0
var voice_sent: int = 0
var voice_received: int = 0


## Makes the link; the caller places it (see [DotGameLink]).
static func attached_to(
	_parent: Node, p_bridge: PlaygroundNetBridge, server: bool
) -> PlaygroundNetLink:
	var link := PlaygroundNetLink.new()
	link.bridge = p_bridge
	link.is_server = server
	return link


func _live() -> bool:
	var live := loopback.is_valid() or (
		is_inside_tree()
		and multiplayer != null
		and multiplayer.has_multiplayer_peer()
	)

	# Every send asks, so this is said when it changes and not per packet: a link with
	# no peer drops snapshots 128 times a second, and one line saying it started is the
	# whole of what anybody needs. DEBUG, because it is also what every clean disconnect
	# looks like.
	if live == _dropping:
		_dropping = not live
		if _dropping:
			DotLog.debug(CHANNEL, "sending stopped: the link has no multiplayer peer", describe())
		else:
			DotLog.debug(CHANNEL, "sending resumed", {"server": is_server})

	return live


## Whether [param peer_id] is somebody a send could still reach: always over the loopback,
## and over a socket only while that peer is connected.
func can_reach(peer_id: int) -> bool:
	if loopback.is_valid():
		return true
	if not is_inside_tree() or multiplayer == null or not multiplayer.has_multiplayer_peer():
		return false
	return multiplayer.get_peers().has(peer_id)


## Whether sends were being dropped at the last [method _live]. See there.
var _dropping := false

## Whether a message has arrived with no bridge to hand it to since one was last set.
var _unbridged := false


## A message with nowhere to go. Said once per stretch rather than per packet.
func _note_unbridged(method: String) -> void:
	if _unbridged:
		return

	_unbridged = true
	DotLog.debug(CHANNEL, "messages are arriving with no bridge to hand them to; dropping", {
		"first": method, "server": is_server,
	})


# --- Sending ---------------------------------------------------------------

## A state snapshot. Server to one client, or to all of them when [param peer_id] is 0.
func send_snapshot(peer_id: int, payload: PackedByteArray) -> void:
	if not _live():
		return

	snapshots_sent += 1

	if loopback.is_valid():
		loopback.call(&"snapshot", peer_id, payload)
	elif peer_id == 0:
		_net_snapshot.rpc(payload)
	else:
		_net_snapshot.rpc_id(peer_id, payload)


func send_event(peer_id: int, payload: PackedByteArray) -> void:
	if not _live():
		return

	events_sent += 1

	if loopback.is_valid():
		loopback.call(&"event", peer_id, payload)
	elif peer_id == 0:
		_net_event.rpc(payload)
	else:
		_net_event.rpc_id(peer_id, payload)


func send_input(payload: PackedByteArray) -> void:
	if not _live():
		return

	inputs_sent += 1

	if loopback.is_valid():
		loopback.call(&"input", 1, payload)
	else:
		_net_client_input.rpc_id(1, payload)


## One encoded [DotVoicePacket], in whichever direction this end is.
##
## [b]One call for both transports.[/b] On ENet `unreliable` is a UDP datagram that is
## never retransmitted, which is what voice wants — a frame that arrives late is one the
## jitter buffer has already concealed. On a WebSocket every transfer mode is TCP
## underneath and it is delivered reliably whether or not that was asked for. That is a
## property of the transport rather than a gap here.
##
## [param peer_id] is the recipient on a server and is ignored on a client. **Zero is not
## "everybody"** — the router names its listeners one at a time.
func send_voice(peer_id: int, payload: PackedByteArray) -> void:
	if not _live():
		return

	voice_sent += 1

	if loopback.is_valid():
		loopback.call(&"voice", peer_id if is_server else 1, payload)
	elif is_server:
		if peer_id > 0:
			_net_voice.rpc_id(peer_id, payload)
	else:
		_net_voice.rpc_id(1, payload)


func send_request(payload: PackedByteArray) -> void:
	if not _live():
		return

	requests_sent += 1

	if loopback.is_valid():
		loopback.call(&"request", 1, payload)
	else:
		_net_request.rpc_id(1, payload)


# --- Receiving -------------------------------------------------------------

## State from the authority. Unreliable: a newer snapshot supersedes a lost one, and
## resending a hundred-millisecond-old position is worse than useless.
@rpc("authority", "unreliable", "call_remote", CHANNEL_STATE)
func _net_snapshot(payload: PackedByteArray) -> void:
	snapshots_received += 1

	if bridge == null:
		_note_unbridged("snapshot")
		return

	_unbridged = false

	bridge.receive_snapshot(payload)


## Anything from the authority that must arrive: spawns, removals, the roster, a prop
## appearing, a tool's answer.
@rpc("authority", "reliable", "call_remote", CHANNEL_STATE)
func _net_event(payload: PackedByteArray) -> void:
	events_received += 1

	if bridge == null:
		_note_unbridged("event")
		return

	_unbridged = false

	bridge.receive_event(payload)


## A client's intent. Unreliable, and not resent: the next tick's packet carries the
## newer command anyway, and a retransmit would arrive after its tick had passed.
@rpc("any_peer", "unreliable", "call_remote", CHANNEL_STATE)
func _net_client_input(payload: PackedByteArray) -> void:
	inputs_received += 1

	if bridge == null:
		_note_unbridged("client_input")
		return

	_unbridged = false

	# The sender comes from the transport, never from inside the payload. A peer id
	# in a body is a claim; this is a fact.
	bridge.receive_input(multiplayer.get_remote_sender_id(), payload)


## A client asking for something: spawn this prop, hold that one, change map, restart.
@rpc("any_peer", "reliable", "call_remote", CHANNEL_STATE)
func _net_request(payload: PackedByteArray) -> void:
	requests_received += 1

	if bridge == null:
		_note_unbridged("request")
		return

	_unbridged = false

	bridge.receive_request(multiplayer.get_remote_sender_id(), payload)


## Hands a payload to this end as though it had arrived over the wire.
##
## What the other end's [member loopback] calls. It goes through the same counters and
## the same bridge entry points the RPCs do, so a test exercises the real path minus the
## socket.
## A voice frame, either way.
##
## `any_peer`, so on the server the sender is a claim until the transport is asked.
## [method DotVoiceRouter.relay] stamps it over whatever the packet's own speaker field
## said — without that any client can put words in any other player's mouth.
@rpc("any_peer", "unreliable", "call_remote", CHANNEL_VOICE)
func _net_voice(payload: PackedByteArray) -> void:
	voice_received += 1

	if bridge == null:
		_note_unbridged("voice")
		return

	_unbridged = false

	bridge.receive_voice(multiplayer.get_remote_sender_id(), payload)


func deliver(method: StringName, from_peer_id: int, payload: PackedByteArray) -> void:
	if bridge == null:
		_note_unbridged(String(method))
		return

	_unbridged = false

	match method:
		&"snapshot":
			snapshots_received += 1
			bridge.receive_snapshot(payload)
		&"event":
			events_received += 1
			bridge.receive_event(payload)
		&"input":
			inputs_received += 1
			bridge.receive_input(from_peer_id, payload)
		&"voice":
			voice_received += 1
			bridge.receive_voice(from_peer_id, payload)
		&"request":
			requests_received += 1
			bridge.receive_request(from_peer_id, payload)


func describe() -> Dictionary:
	return {
		"server": is_server,
		"snapshots": [snapshots_sent, snapshots_received],
		"events": [events_sent, events_received],
		"inputs": [inputs_sent, inputs_received],
		"requests": [requests_sent, requests_received],
		"voice": [voice_sent, voice_received],
	}
