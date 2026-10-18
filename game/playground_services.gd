extends DotGameServices

const Playground := preload("playground.gd")
const PlaygroundNetBridge := preload("net/playground_net_bridge.gd")
const PlaygroundPlayer := preload("playground_player.gd")

## Chat, moderation and voice, wired to this sandbox's people and this game's wire.
##
## [b]The same three addons the other games join, and the third set of proximity
## answers.[/b] game-hungario is an arena, so its voice is proximity. A sandbox is a room
## and an arena at once —
## people build together in one corner and fight or race in another — so **text has a
## near channel and voice is the whole server**, which is the arrangement every sandbox
## server has ever shipped with, and for the reason they all found: a builder shouting for
## a hand should be heard, and somebody in the corner reading should be able to stop
## reading the shouting.
##
## [b]The sequence is [DotGameServices]'s.[/b] Moderation first, because it publishes the
## mute source both routers look up when they start; then chat, the website relay, voice.
## This was 557 lines of its own until 2026-09-27; what is left is what is this game's:
##
## - the channels, the rules and the voice format, as statics a CLIENT reads too;
## - where a person is standing, off the controller's state rather than the node;
## - **the bridge is who is in the game**, not dot-server's session list. A peer is only
##   sent a line once it has said it can receive ([method _chat_peers]), a line is
##   attributed to the bridge's player id ([method _key_of]), and a punishment falls back
##   to a `local:` subject when there is no session — which is what lets `headless_net`
##   run the real sequence with no [DotServer] at all;
## - the one meta field this wire carries, `x.p`, stamped on every line
##   ([method _send_chat]);
## - [b]the backlog is the module's[/b] ([method _peer_can_receive] answers false): it is
##   sent from `PlaygroundModule._welcome` once the peer is ready, never at seating;
## - [b]the live tools are the module's too[/b] ([member DotGameServices.mod_tools_enabled]
##   is off): `PlaygroundModTools` needs the arena's health, which is built after this,
##   and the module clears their return history on every map change. A second set built
##   here would bind the same command names to the same console.
##
## [b]dot-server's own chat is cancelled, not run beside this.[/b] [DotChatRouter] has the
## rules now, and [PlaygroundModule] cancels `player_chat` so there is exactly one path.
## Two would be two sets of rules to keep in step, and the one that skipped the filter
## would be the one that leaked admin chat.

# No `const CHANNEL` and no `RELAY_CONFIG_PATH`: [DotGameServices] declares both, and
# GDScript refuses a redeclaration. The relay reads `user://chat_relay.json` as it did.

const CHANNEL_ALL := &"all"
const CHANNEL_NEAR := &"near"
const CHANNEL_ADMIN := &"admin"
const CHANNEL_WHISPER := &"whisper"

## How far "near" reaches, in metres.
##
## A sandbox is measured in tens of metres and a build is a few across; twenty-five is far
## enough to include everybody working on one thing and short enough that the other corner
## is a different conversation.
const NEAR_RANGE := 25.0

## Where punishments are kept unless a host says otherwise. The same file the hand-written
## layer used, and what [method _services_name] produces by default.
const PUNISHMENTS_PATH := "user://playground_punishments.json"


## The bridge: who is in the game, what their player id is, and the wire. Set before
## [method setup], and passed to it as the link as well.
var bridge: PlaygroundNetBridge = null

## Where punishments are written. The module assigns it from its static seam before setup,
## and `dedicated` reads it back; both go through the base's `punishments_file`.
var punishments_path: String:
	get:
		return _punishments_path()
	set(value):
		punishments_file = value


## Builds all four layers, in the base's order.
##
## [b]Not a coroutine.[/b] [method DotModuleHost.load_module] calls `_module_load()` with a
## bare call and reads `result.ok` on the next line, so a module whose load suspends
## returns null there and the host crashes on a module that was working.
func setup(p_server: DotServer, p_game: Object, p_link: Object) -> DotResult:
	if bridge == null or not (p_game is Playground):
		return DotResult.fail(
			DotError.CODE_STATE, "The services need a bridge and a game."
		)

	# The module's, not the base's. See the class note.
	mod_tools_enabled = false

	return super.setup(p_server, p_game, p_link)


func _services_name() -> String:
	return "playground"


# --- What this sandbox says and how ----------------------------------------

func _chat_channels() -> Array:
	return chat_channels()


func _chat_rules() -> Object:
	return chat_rules()


func _voice_config() -> Object:
	return voice_config()


## [b]Everybody, and the near channel is text's.[/b] Text you can read two of at once and
## choose; voice you cannot, and a sandbox where you walk out of earshot of the person
## helping you build is a sandbox where nobody uses voice. The proximity machinery is wired
## and reachable — the base sets `position_fn` — so a deployment that wants it changes one
## line.
func _voice_default_channel() -> int:
	return DotVoiceRouter.Channel.ALL


## The channels, as a static a client builds its chat box from without building this.
##
## [b]Callers name the element type[/b] (`for channel: DotChatChannel in …`) rather than
## inferring it: a script whose base class lives in the HOST build cannot hand its return
## type to a script in a mounted pack — mg-buses-from-hell measured that as a client scene
## that would not load on a real server.
static func chat_channels() -> Array[DotChatChannel]:
	var out: Array[DotChatChannel] = []

	var everyone := DotChatChannel.make(CHANNEL_ALL, "All", DotChatChannel.Scope.EVERYONE)
	everyone.colour = Color(0.93, 0.94, 0.96)
	# A sandbox is a place people arrive at mid-conversation more than any other kind of
	# server, because there is no round to wait for.
	everyone.backlog = 20
	everyone.history_limit = 300
	out.append(everyone)

	var near := DotChatChannel.make(CHANNEL_NEAR, "Near", DotChatChannel.Scope.RADIUS)
	near.prefix = "[near]"
	near.colour = Color(0.68, 0.83, 0.62)
	near.radius = NEAR_RANGE
	# [b]No backlog on a proximity channel.[/b] A backlog is handed to whoever joins, and
	# a line somebody said quietly beside their build is exactly the line that must not be
	# replayed to a stranger who was not standing there.
	near.backlog = 0
	near.history_limit = 150
	out.append(near)

	var admin := DotChatChannel.make(CHANNEL_ADMIN, "Admin", DotChatChannel.Scope.EVERYONE)
	admin.prefix = "[ADMIN]"
	admin.colour = Color(0.98, 0.72, 0.35)
	admin.admin_only = true
	# A gag is about a player's speech; an admin who has been gagged has a bigger problem
	# than chat.
	admin.ignores_gag = true
	admin.backlog = 0
	out.append(admin)

	var whisper := DotChatChannel.make(
		CHANNEL_WHISPER, "Whisper", DotChatChannel.Scope.DIRECT
	)
	whisper.prefix = "[w]"
	whisper.colour = Color(0.78, 0.71, 0.93)
	whisper.backlog = 0
	out.append(whisper)

	return out


## What a line may be.
##
## Longer and chattier than a shooter's, because a sandbox is a place people talk in while
## they build — and `!` and `/` are both command prefixes, because this game's console
## surface is the largest in the family and half of it is meant to be reachable from chat.
static func chat_rules() -> DotChatRules:
	var rules := DotChatRules.new()
	rules.max_length = 200
	rules.refuse_over_length = false
	rules.allow_newlines = false
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true
	rules.rate_per_minute = 30
	rules.burst = 5.0
	rules.flood_penalty_sec = 10.0
	rules.duplicate_window_sec = 8.0
	rules.duplicate_depth = 3
	rules.command_prefixes = PackedStringArray(["!", "/"])
	# An unclaimed `!command` is not broadcast: a player typing `!ban` at a server with no
	# such command would otherwise say "!ban" to the whole server, which is worse than
	# nothing happening.
	rules.broadcast_unknown_commands = false
	rules.history_limit = 400
	return rules


## The voice format, which both ends must agree on exactly.
##
## Static, and read by the client too: [method DotVoiceConfig.format_fingerprint] exists
## because a sample rate or a frame length that differs between two peers is a stream of
## packets the router refuses for being the wrong length, counted and said to nobody.
static func voice_config() -> DotVoiceConfig:
	var config := DotVoiceConfig.new()
	config.sample_rate = 16000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"
	config.push_to_talk = true
	config.activation_rms = 0.02
	config.hangover_ms = 250.0
	config.jitter_ms = 60.0
	config.jitter_max_ms = 400.0
	config.proximity_range = NEAR_RANGE
	config.max_bytes_per_second = 6144
	return config


# --- The people, as this game's bridge knows them ----------------------------

## Who a peer is, for a punishment: the durable account uid.
##
## [b]Deliberately not the same answer [method _key_of] gives dot-chat.[/b] A punishment is
## against a person who will come back, so it is keyed by something that survives a
## reconnect. With no session (no server, or a peer the bridge seated directly) it falls
## back to a `local:` subject for the bridge's player id, where the base would answer "".
func _subject_for_peer(peer_id: int) -> String:
	var session := _session_for(peer_id)

	if session != null:
		return DotPunishmentSubject.for_uid(session.uid())

	var player_id := bridge.player_for_peer(peer_id) if bridge != null else 0
	return DotPunishmentSubject.for_uid("local:%d" % player_id) if player_id != 0 else ""


## The key a chat line is attributed to: the bridge's player id, as a string.
##
## The player id IS the session's userid on a server (the module seats people with it), so
## this is the base's answer there — and it is also an answer with no [DotServer], which
## the base's is not. [b]Not the account uid[/b]: two guests behind one device id share one.
func _key_of(peer_id: int) -> String:
	var session_id := bridge.player_for_peer(peer_id) if bridge != null else 0
	return str(session_id) if session_id != 0 else ""


## The peers a line may go to: the ones the bridge knows can receive.
##
## [b]Not dot-server's playing sessions.[/b] A peer is playing from the moment signon
## finishes, and its client builds the node a CHAT event lands on after that; a line sent
## in between is one "Node not found" and is lost. The bridge's ready set is the one that
## waits for the client to say so.
func _chat_peers() -> PackedInt32Array:
	return bridge.ready_peers() if bridge != null else PackedInt32Array()


## The session id, lifted into the one meta field this wire carries, so a client can
## colour a line by whose it is. The key IS the session id — see [method _key_of].
func _send_chat(wire: Dictionary, recipients: PackedInt32Array) -> void:
	var addressed := wire.duplicate()
	var key := str(wire.get("s", ""))

	if key.is_valid_int() and key.to_int() > 0:
		addressed["x"] = {"p": key.to_int()}

	super._send_chat(addressed, recipients)


## Voice rides the bridge's link rather than the bridge itself, which has no voice method.
##
## [b]To a READY peer only, like every other send.[/b] The module adds a peer to the voice
## router at `client_spawn`, so a frame relayed in the window before its client has built
## `Server/Playground` is addressed to it — and over a socket that is one "Failed to get
## path from RPC" per frame for as long as anybody talks while somebody joins. The router
## keeps the peer (it is a listener the moment it can hear); the link is what waits. A
## dropped frame is speech the joiner was not there for, which is what it would be anyway.
## `pg-rpc-before-scene`.
func _send_voice(peer_id: int, payload: PackedByteArray) -> void:
	if bridge == null or bridge.link == null:
		return
	if bridge.net != null and bridge.net.is_server and not bridge.peer_is_ready(peer_id):
		voice_held += 1
		return
	bridge.link.send_voice(peer_id, payload)


## Voice frames addressed to a peer that had not said READY, and so not sent.
var voice_held: int = 0


## False: the backlog is sent by `PlaygroundModule._welcome`, once the bridge says the peer
## is ready, and a second copy from `add_peer` would replay it twice.
func _peer_can_receive(_peer_id: int) -> bool:
	return false


## Where somebody is standing, as dot-chat and dot-voice both ask for it.
##
## [b]The controller's state, not the node.[/b] A player riding a vehicle is reparented
## into the seat, and the node's global position is then the seat's — which is right for a
## camera and wrong for everything that asks where the *person* is.
## [method Playground._carry_riders] copies the position back onto the state for exactly
## this class of reader, and the state is what everything else in this game uses.
func _position_of(peer_id: int) -> Vector3:
	var playground := game as Playground

	if bridge == null or playground == null:
		return Vector3.ZERO

	var session_id := bridge.player_for_peer(peer_id)

	if session_id == 0:
		return Vector3.ZERO

	var found: Variant = playground.players.get(StringName(str(session_id)))
	var player := found as PlaygroundPlayer

	if player == null or player.controller == null or player.controller.state == null:
		return Vector3.ZERO

	return player.controller.state.position
