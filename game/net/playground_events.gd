extends RefCounted

## The wire format for everything that is not a snapshot or an input.
##
## Encoders and decoders in pairs, because they have to be exact inverses and nothing
## checks that for you — the headless net suite round-trips every one of them. This
## family has already shipped a serialisation whose two ends never met: dot-moderation
## wrote [code]"voice muted"[/code] and read back a warning, and the one thing that
## addon existed for silently did nothing.
##
## [b]A prop is announced, not spawned by a factory.[/b] The server sends a PROP event
## carrying the catalogue id and the net id it registered, and the client builds the
## same prop and mirrors that id — the same shape [PlaygroundEvents.Kind.JOIN] uses for
## players. A spawner factory would have to name a script, and this game's props are
## named by PATH in the catalogue precisely so a dot-cloud pack can deliver them.

enum Kind {
	## Tick rate, who you are, the map, the server tick.
	HELLO,
	## A player joined, or changed: name, net id, style.
	JOIN,
	LEAVE,
	## The map changed. Clients load it from their own build.
	MAP,
	## A prop or an entity now exists: net id, catalogue id, owner.
	PROP,
	## It is gone. Net id and why.
	PROP_GONE,
	## A player's held prop changed — what the physics gun has, for the beam.
	HELD,
	## What a player is carrying, so the client draws the right viewmodel.
	WEAPON,
	## Reserved: a run timer's run state, before the timer became optional. Never sent now
	## (`addons/pg_timer` speaks through ADDON); kept so no later kind is renumbered.
	TIMER,
	## Reserved, as TIMER: a finish. Never sent now.
	FINISH,
	## Text for everyone, or for one player: a refusal, a budget, a vote result.
	NOTICE,
	## A player got into or out of a vehicle.
	SEAT,
	## One chat line, already routed, sanitised and addressed by [DotChatRouter].
	CHAT,
	## A player's health, armour or death. See [PlaygroundArena].
	COMBAT,
	## The match clock: warmup, a round starting, a score.
	MATCH,
	## Something somebody earned: an achievement or a personal best.
	PROGRESS,
	## The map vote: a sound cue to play, or a second of the countdown before a ballot.
	## Last, because a kind is its index on the wire.
	VOTE,
	## The map's time left, from the vote's clock: sent when it changes rather than
	## counted, so an extend reaches the HUD. Last, for the same reason.
	CLOCK,
	## The player's OWN inventory: an answer to one op they sent, or the whole bag. Only
	## ever to the owner's peer — see [PlaygroundInventoryNet]. Last, for the same reason.
	INVENTORY,
	## A grenade or a rocket: launched (everything a client needs to fly its own copy), or
	## gone off (where, and how big). One kind with a sub-kind, [enum ProjectileTell].
	PROJECTILE,
	## The builds this player has saved, for the Q menu's Builds tab: a name, a size and
	## whether it is one welded piece (a custom prop). Sent only to the player who asked.
	## Last, because a kind is its index on the wire; an older client refuses it as unknown.
	BUILDS,
	## The prop this player's tool gun has selected to edit, and its properties as the edit
	## mode's settings, so the Q menu shows what the prop IS. Net id 0 is "nothing selected".
	## Sent only to the player whose gun it is. Last, for the same reason.
	SELECTION,
	## A breakable map box broke (glass): its index in the map document. To everybody, and
	## every one broken so far to a joiner. Last, for the same reason as the others.
	PANE,
	## Your hit landed: on what, how much, where, and whether it killed or was a head. Only
	## ever to the shooter's peer, for the hit marker and the damage numbers, which are drawn
	## from this and never from the local prediction. Last, for the same reason.
	HIT,
	## The map's toys' net ids in toy order, and which map they are for (both ends build the
	## toys in the same order from the map). After MAP, and to a joiner after HELLO. Last, for
	## the same reason.
	TOYS,
	## A message from an addon's hook to its own client half: the addon's folder name and
	## a dictionary as JSON. To everybody. Last, for the same reason.
	ADDON,
}

## What a [constant Kind.PROJECTILE] event says.
enum ProjectileTell { LAUNCH, DETONATE }
const PROJECTILE_SUB_BITS := 2

enum Ask {
	## I have loaded and can receive. Tell me everything.
	READY,
	## Spawn this prop from the catalogue, in front of me.
	SPAWN_PROP,
	## Give me this weapon.
	GIVE_WEAPON,
	## Select this tool — physics gun, gravity gun, remover.
	SELECT_TOOL,
	## Remove the last thing I spawned.
	UNDO,
	## Remove everything I spawned.
	CLEAR_MINE,
	## Put me back at the start of the course.
	RESTART,
	## Save a checkpoint (0), teleport to it (1), clear them (2). A run timer's practice
	## checkpoints; ignored by a server without one.
	CHECKPOINT,
	## Rock the vote.
	RTV,
	## Put me on this style (index into the server's ordered table).
	STYLE,
	## Get me into whatever I am standing next to, or out of what I am in.
	##
	## [b]One ask for both, because the player pressed one key.[/b] Two asks would put a
	## client in charge of deciding which it is, and a client that guesses wrong asks to
	## get into the car it is already sitting in — which the server then refuses, so the
	## symptom is a use key that stops working once you are in something.
	USE_VEHICLE,
	## I typed a line. The server decides what channel it lands on and who hears it.
	SAY,
	## Rock the vote, nominate, or cast one. The body is a token a [DotVoteSource] resolves.
	VOTE,
	## Here is what I want to spawn with.
	LOADOUT,
	## Something about my inventory: an op I have already predicted, a request for the
	## whole bag, or a purchase into it. One kind with a sub-kind, because this enum is
	## [constant PlaygroundRequest.KIND_BITS] wide and three would have filled it.
	INVENTORY,
	## Load this prop into the toy in my hand: what the launcher throws.
	##
	## [b]The sixteenth kind, and the last one four bits hold.[/b] Anything after this
	## goes in as a sub-kind of an existing one, the way [constant INVENTORY] does. An
	## older server refuses it as an unknown kind and nothing else happens.
	ARM_PROP,
}

## Every decoder returns an `ok` alongside its fields, and every caller checks it.
##
## [b]A reader past its end returns plausible zeros rather than failing.[/b] dot-net
## shipped with exhaustion that was not sticky, so a decoder that skipped this check got
## a believable value for the field AFTER the overrun — and a truncated packet decodes
## as a valid message about nothing. dot-timer's replay format had the same hole:
## a replay truncated inside its header parsed as a valid replay of zero frames.
const NAME_BYTES := 64
const ID_BYTES := 64
const TEXT_BYTES := 256

## Where a prop may be, in metres. Generous: a punted barrel leaves any sane map.
const WORLD_EXTENT := 8192.0
const POS_BITS := 26


static func kind_name(kind: int) -> String:
	var names := Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?"


static func ask_name(ask: int) -> String:
	var names := Ask.keys()
	return String(names[ask]) if ask >= 0 and ask < names.size() else "?"


static func _w() -> DotNetWriter:
	return DotNetWriter.new()


# --- Hello -----------------------------------------------------------------

## What a client needs before it can build anything, in one message.
##
## [b]The tick rate is in here and it is not decoration.[/b] game-g2gfast shipped
## without reading the one HELLO already carried, so a browser client counted at the 60
## its export declared against a server running 128: correction rate 0.96, and every
## replicated time wrong by 128/60. A client adopts this or it is wrong about
## everything.
static func write_hello(
	player_id: int, tick_rate: int, server_tick: int, map_id: StringName
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_uint(tick_rate, 9)
	w.write_varint(server_tick)
	w.write_string(String(map_id), ID_BYTES)
	return w.to_bytes()


static func read_hello(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var tick_rate := r.read_uint(9)
	var server_tick := r.read_varint()
	var map_id := r.read_string(ID_BYTES)
	return {
		"player_id": player_id,
		"tick_rate": tick_rate,
		"server_tick": server_tick,
		"map_id": StringName(map_id),
		"ok": r.ok(),
	}


# --- Players ---------------------------------------------------------------

## [param skins] is what the player wears, [face, top, legs] as kit indices, written last as
## index + 1 so 0 is "the stock look": appended, so a JOIN without them -- from a server
## older than avatars here -- still reads, with no skins.
static func write_join(
	player_id: int, net_id: int, display_name: String, style_index: int,
	skins: PackedInt32Array = PackedInt32Array()
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(net_id)
	w.write_string(display_name, NAME_BYTES)
	w.write_uint(maxi(style_index, 0), 8)
	for i in range(3):
		w.write_uint(clampi(skins[i] + 1, 0, 255) if i < skins.size() else 0, 8)
	return w.to_bytes()


static func read_join(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var net_id := r.read_varint()
	var display_name := r.read_string(NAME_BYTES)
	var style_index := r.read_uint(8)
	var skins := PackedInt32Array()
	if not r.at_end():
		var any := false
		for i in range(3):
			var v := r.read_uint(8) - 1
			skins.append(v)
			any = any or v >= 0
		if not any:
			skins = PackedInt32Array()
	return {
		"player_id": player_id,
		"net_id": net_id,
		"name": display_name,
		"style_index": style_index,
		"skins": skins,
		"ok": r.ok(),
	}


static func write_player(player_id: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	return w.to_bytes()


static func read_player(r: DotNetReader) -> int:
	return r.read_varint()


# --- Props and entities ----------------------------------------------------

## A prop the authority has created. [param kind_id] is the catalogue id, which is how
## the client knows what to build; [param net_id] is what the snapshot will move.
static func write_prop(
	net_id: int, kind_id: StringName, owner_id: int, is_entity: bool, at: Vector3
) -> PackedByteArray:
	var w := _w()
	w.write_varint(net_id)
	w.write_string(String(kind_id), ID_BYTES)
	w.write_varint(owner_id)
	w.write_bool(is_entity)
	w.write_vector3_range(at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return w.to_bytes()


static func read_prop(r: DotNetReader) -> Dictionary:
	var net_id := r.read_varint()
	var kind_id := r.read_string(ID_BYTES)
	var owner_id := r.read_varint()
	var is_entity := r.read_bool()
	var at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return {
		"net_id": net_id,
		"kind_id": StringName(kind_id),
		"owner_id": owner_id,
		"is_entity": is_entity,
		"position": at,
		"ok": r.ok(),
	}


## [param death] is how a killed NPC's body falls (the server's pick), last and optional.
static func write_prop_gone(net_id: int, reason: StringName, death: DotPlayerDeath = null) -> PackedByteArray:
	var w := _w()
	w.write_varint(net_id)
	w.write_string(String(reason), ID_BYTES)
	if death != null:
		death.write_to(w)
	return w.to_bytes()


static func read_prop_gone(r: DotNetReader) -> Dictionary:
	var net_id := r.read_varint()
	var reason := r.read_string(ID_BYTES)
	var out := {"net_id": net_id, "reason": StringName(reason)}
	# A byte or more left is the fall; less is the padding to the last byte.
	if r.bits_remaining() >= 8:
		out["death"] = DotPlayerDeath.read_from(r)
	out["ok"] = r.ok()
	return out


## What a player's physics gun is holding, or 0 for nothing. The beam is drawn from
## this: a client cannot see a server-side grab any other way, and a physics gun with
## no visible beam reads as a broken gun.
static func write_held(player_id: int, net_id: int, frozen: bool) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(net_id)
	w.write_bool(frozen)
	return w.to_bytes()


static func read_held(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var net_id := r.read_varint()
	var frozen := r.read_bool()
	return {"player_id": player_id, "net_id": net_id, "frozen": frozen, "ok": r.ok()}


static func write_weapon(player_id: int, weapon_id: StringName) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_string(String(weapon_id), ID_BYTES)
	return w.to_bytes()


static func read_weapon(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var weapon_id := r.read_string(ID_BYTES)
	return {"player_id": player_id, "weapon_id": StringName(weapon_id), "ok": r.ok()}


## Who is in what, and where. Sent to everybody, because a client draws other people
## sitting in cars and has to stop drawing them walking.
##
## [param seat_index] is the index into the vehicle definition's own seat list rather
## than the seat's id: the client has the same catalogue and a byte is a byte, where an
## id is up to sixty-four of them per player per journey.
static func write_seat(
	player_id: int, vehicle_net_id: int, seat_index: int, seated: bool
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(vehicle_net_id)
	w.write_uint(clampi(seat_index, 0, 255), 8)
	w.write_bool(seated)
	return w.to_bytes()


static func read_seat(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var vehicle_net_id := r.read_varint()
	var seat_index := r.read_uint(8)
	var seated := r.read_bool()
	return {
		"player_id": player_id,
		"vehicle_net_id": vehicle_net_id,
		"seat_index": seat_index,
		"seated": seated,
		"ok": r.ok(),
	}


# --- Maps ------------------------------------------------------------------

static func write_map(map_id: StringName) -> PackedByteArray:
	var w := _w()
	w.write_string(String(map_id), ID_BYTES)
	return w.to_bytes()


static func read_map(r: DotNetReader) -> StringName:
	return StringName(r.read_string(ID_BYTES))


# --- Notices ---------------------------------------------------------------

## [param player_id] 0 means everybody.
static func write_notice(player_id: int, text: String) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_string(text, TEXT_BYTES)
	return w.to_bytes()


static func read_notice(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var text := r.read_string(TEXT_BYTES)
	return {"player_id": player_id, "text": text, "ok": r.ok()}


# --- Asks ------------------------------------------------------------------

static func write_id(id: StringName) -> PackedByteArray:
	var w := _w()
	w.write_string(String(id), ID_BYTES)
	return w.to_bytes()


static func read_id(r: DotNetReader) -> StringName:
	return StringName(r.read_string(ID_BYTES))


# --- ARM_PROP and its sub-kinds ---------------------------------------------------
#
# The Ask enum is four bits and full, so the tool gun's settings, the NPC weapon choice and
# spawning a weapon into the world ride on ARM_PROP as sub-kinds after its id — the way
# INVENTORY carries its own. A body with nothing after the id is the original ARM_PROP,
# which is what an older client sends and an older server reads.

const ARM_PROP_SUB := 0
## The tool gun: id is the mode, payload its settings as JSON.
const ARM_TOOL := 1
## What my NPCs carry: id is the weapon, or `none`, or empty for the catalogue's choice.
const ARM_NPC_WEAPON := 2
## Put this weapon on the ground in front of me: id is the weapon.
const ARM_SPAWN_WEAPON := 3
## Send me my saved builds (a [constant Kind.BUILDS] back). id is empty.
const ARM_BUILDS := 4
## Put my saved build down in front of me: id is its name.
const ARM_LOAD_BUILD := 5
## Start an addon's menu entry: id is `addon/item`, payload the point the player looks at as
## three numbers in JSON, `[x, y, z]`, or empty.
const ARM_ADDON_ITEM := 6

## The most a tool's settings may take on the wire. A tool has a handful of numbers.
const TOOL_SETTINGS_BYTES := 512


static func write_arm(sub: int, id: StringName, payload: String = "") -> PackedByteArray:
	var w := _w()
	w.write_string(String(id), ID_BYTES)

	if sub != ARM_PROP_SUB:
		w.write_uint(sub, 8)
		w.write_string(payload, TOOL_SETTINGS_BYTES)

	return w.to_bytes()


static func read_arm(r: DotNetReader) -> Dictionary:
	var id := StringName(r.read_string(ID_BYTES))
	var out := {"id": id, "sub": ARM_PROP_SUB, "payload": ""}

	if r.has_more():
		out["sub"] = r.read_uint(8)
		out["payload"] = r.read_string(TOOL_SETTINGS_BYTES)

	out["ok"] = r.ok()
	return out


static func write_index(index: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(maxi(index, 0), 8)
	return w.to_bytes()


static func read_index(r: DotNetReader) -> int:
	return r.read_uint(8)


# --- CHAT ------------------------------------------------------------------

const CHAT_BYTES := 200
const CHAT_CHANNEL_BYTES := 24
const CHAT_KEY_BYTES := 48
const CHAT_KIND_BITS := 4


## Whether every [enum DotChatMessage.Kind] fits in [constant CHAT_KIND_BITS]. dot-chat owns
## that enum, so it can grow under this game; headless_net reads this.
static func chat_kinds_fit() -> bool:
	return DotChatMessage.KIND_NAMES.size() <= (1 << CHAT_KIND_BITS)


## One chat line, from [method DotChatMessage.to_dictionary], plus who said it.
##
## [b]Encoded field by field rather than as JSON.[/b] A JSON body is a variable-length blob
## a reader cannot bound and a hostile server could make enormous, and it costs about three
## times the bytes for a message whose whole point is that it is small and frequent.
##
## The `x` (meta) field is not carried as a dictionary — what this game needs from it is one
## number, the player the line belongs to, so that is a bounded field and the reader puts it
## back where [method DotChatMessage.from_dictionary] finds it. The kind travels as an
## **index into [constant DotChatMessage.KIND_NAMES]**, one table used in both directions,
## which is the lesson dot-moderation paid for when a stored voice mute loaded as a warning.
static func write_chat(wire: Dictionary) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(int(wire.get("n", 0)))
	writer.write_uint(int(wire.get("t", 0)), 32)
	writer.write_string(str(wire.get("c", "")), CHAT_CHANNEL_BYTES)
	writer.write_uint(
		maxi(0, DotChatMessage.kind_from_name(str(wire.get("k", "say")))), CHAT_KIND_BITS
	)
	writer.write_string(str(wire.get("s", "")), CHAT_KEY_BYTES)
	writer.write_string(str(wire.get("d", "")), NAME_BYTES)
	writer.write_string(str(wire.get("w", "")), CHAT_KEY_BYTES)
	writer.write_string(str(wire.get("m", "")), CHAT_BYTES)

	var meta: Variant = wire.get("x")
	var player_id: int = 0

	if typeof(meta) == TYPE_DICTIONARY:
		player_id = int((meta as Dictionary).get("p", 0))

	writer.write_varint(maxi(0, player_id))
	return writer.to_bytes()


static func read_chat(reader: DotNetReader) -> Dictionary:
	var out := {
		"n": reader.read_varint(),
		"t": reader.read_uint(32),
		"c": reader.read_string(CHAT_CHANNEL_BYTES),
	}

	var kind := reader.read_uint(CHAT_KIND_BITS)
	out["k"] = DotChatMessage.KIND_NAMES[kind] \
		if kind >= 0 and kind < DotChatMessage.KIND_NAMES.size() else "say"

	out["s"] = reader.read_string(CHAT_KEY_BYTES)
	out["d"] = reader.read_string(NAME_BYTES)
	out["w"] = reader.read_string(CHAT_KEY_BYTES)
	out["m"] = reader.read_string(CHAT_BYTES)

	var player_id := reader.read_varint()

	if player_id > 0:
		out["x"] = {"p": player_id}

	out["ok"] = reader.ok()
	return out


static func write_say(channel_id: StringName, text: String) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_string(String(channel_id), CHAT_CHANNEL_BYTES)
	writer.write_string(text, CHAT_BYTES)
	return writer.to_bytes()


static func read_say(reader: DotNetReader) -> Dictionary:
	var out := {
		"channel": reader.read_string(CHAT_CHANNEL_BYTES),
		"text": reader.read_string(CHAT_BYTES),
	}
	out["ok"] = reader.ok()
	return out


# --- COMBAT ----------------------------------------------------------------

## Health and armour are 0..255 here, which is a shooter's whole range.
const HEALTH_BITS := 8


## Somebody's health changed, or they died.
##
## [b]Health is replicated as an event rather than as a [DotNetVar].[/b] It changes on a
## hit and not on a tick, so a per-tick field would send an unchanged byte at the snapshot
## rate for every player — and dot-net's delta encoding would still have to look at it.
## What matters about health is the moment it moves.
##
## A death carries how the body falls (dot-player-char's [DotPlayerDeath], the server's pick),
## last and optional, so a client that reads only the fields above reads the rest.
static func write_combat(
	player_id: int, health: int, armour: int, attacker_id: int, died: bool,
	death: DotPlayerDeath = null
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(player_id)
	writer.write_uint(clampi(health, 0, 255), HEALTH_BITS)
	writer.write_uint(clampi(armour, 0, 255), HEALTH_BITS)
	writer.write_varint(maxi(0, attacker_id))
	writer.write_bool(died)
	if died and death != null:
		death.write_to(writer)
	return writer.to_bytes()


static func read_combat(reader: DotNetReader) -> Dictionary:
	var out := {
		"player_id": reader.read_varint(),
		"health": reader.read_uint(HEALTH_BITS),
		"armour": reader.read_uint(HEALTH_BITS),
		"attacker_id": reader.read_varint(),
		"died": reader.read_bool(),
	}
	# A byte or more left is the fall; less is the padding to the last byte.
	if bool(out["died"]) and reader.bits_remaining() >= 8:
		out["death"] = DotPlayerDeath.read_from(reader)
	out["ok"] = reader.ok()
	return out


# --- MATCH -----------------------------------------------------------------

const MATCH_STATE_BITS := 4
const MATCH_LABEL_BYTES := 48


## The match clock, once a second and on every transition.
##
## [b]Sent rather than derived, because a mirroring client's [DotMatch] never runs.[/b]
## Nothing ticks it, so `seconds_remaining()` is computed from a `_current_tick` that is
## still zero — not a stale value, a value nothing had ever written. game-arena shipped a
## client showing `IDLE` for ever while the server was playing a round.
static func write_match(
	state: int, seconds_left: float, round_number: int, label: String
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_uint(clampi(state, 0, 15), MATCH_STATE_BITS)
	writer.write_uint(clampi(int(seconds_left), 0, 65535), 16)
	writer.write_uint(clampi(round_number, 0, 255), 8)
	writer.write_string(label, MATCH_LABEL_BYTES)
	return writer.to_bytes()


static func read_match(reader: DotNetReader) -> Dictionary:
	var out := {
		"state": reader.read_uint(MATCH_STATE_BITS),
		"seconds_left": float(reader.read_uint(16)),
		"round": reader.read_uint(8),
		"label": reader.read_string(MATCH_LABEL_BYTES),
	}
	out["ok"] = reader.ok()
	return out


# --- PROGRESS --------------------------------------------------------------

const PROGRESS_ID_BYTES := 40
const PROGRESS_TEXT_BYTES := 96


## Something a player earned. Text, not a rule — the rules stay on the server, because a
## client that held them could tell a player they had earned something the server disagreed
## about, and the server is the one filing it.
static func write_progress(
	player_id: int, id: StringName, title: String, value: int
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(player_id)
	writer.write_string(String(id), PROGRESS_ID_BYTES)
	writer.write_string(title, PROGRESS_TEXT_BYTES)
	writer.write_varint(maxi(0, value))
	return writer.to_bytes()


static func read_progress(reader: DotNetReader) -> Dictionary:
	var out := {
		"player_id": reader.read_varint(),
		"id": reader.read_string(PROGRESS_ID_BYTES),
		"title": reader.read_string(PROGRESS_TEXT_BYTES),
		"value": reader.read_varint(),
	}
	out["ok"] = reader.ok()
	return out


# --- VOTES AND LOADOUTS ----------------------------------------------------

const VOTE_TOKEN_BYTES := 48
const LOADOUT_SLOT_BYTES := 32
const LOADOUT_MAX_SLOTS := 8
const LOADOUT_COUNT_BITS := 4


## What a client asks the vote for: `rtv`, `nominate <id>`, `vote <n>`, `extend`.
##
## A token rather than an enum, because the thing voted for is an id and what an id means
## is a [DotVoteSource]'s business — which is what lets one engine drive dot-server's games
## and dot-map's maps without this file naming either.
static func write_vote(token: String) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_string(token, VOTE_TOKEN_BYTES)
	return writer.to_bytes()


static func read_vote(reader: DotNetReader) -> String:
	return reader.read_string(VOTE_TOKEN_BYTES)


## Bytes a vote cue id may occupy. An id, never a path.
const CUE_BYTES := 32


## A map-vote cue id (empty for none) and a countdown second (0 for none). Named `_cue`
## because [method write_vote] is the other direction's: a player's token to the server.
static func write_vote_cue(cue: String, seconds_left: int, runoff: bool) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_string(cue, CUE_BYTES)
	writer.write_uint(clampi(seconds_left, 0, 255), 8)
	writer.write_bool(runoff)
	return writer.to_bytes()


static func read_vote_cue(reader: DotNetReader) -> Dictionary:
	var out := {
		"cue": reader.read_string(CUE_BYTES),
		"seconds_left": reader.read_uint(8),
		"runoff": reader.read_bool(),
	}
	out["ok"] = reader.ok()
	return out


## The vote's clock as [method DotVoteClockView.state_of] describes it: whether there is
## one, the whole seconds left, and whether it is counting. A client counts it down
## itself between messages; the server sends another only when that count would be wrong.
static func write_clock(state: Dictionary) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_bool(bool(state.get("has_clock", false)))
	writer.write_varint(maxi(int(state.get("seconds_left", 0)), 0))
	writer.write_bool(bool(state.get("running", false)))
	return writer.to_bytes()


static func read_clock(reader: DotNetReader) -> Dictionary:
	var out := {
		"has_clock": reader.read_bool(),
		"seconds_left": reader.read_varint(),
		"running": reader.read_bool(),
	}
	out["ok"] = reader.ok()
	return out


## What a player wants to spawn with, as slot/item pairs.
##
## [b]Ids only, and the server validates them against a schema and an entitlement set
## without loading anything.[/b] That is dot-loadout's one idea, and it is why this is a
## handful of strings rather than a document. A client that could make the server *repair*
## its way to a legal loadout could put anything in any slot and have the server pick the
## nearest legal thing, so the server refuses rather than conforms on this direction.
static func write_loadout(pairs: Array) -> PackedByteArray:
	var writer := DotNetWriter.new()
	var count := mini(pairs.size(), LOADOUT_MAX_SLOTS)
	writer.write_uint(count, LOADOUT_COUNT_BITS)

	for index in count:
		var pair: Array = pairs[index]
		writer.write_string(str(pair[0]), LOADOUT_SLOT_BYTES)
		writer.write_string(str(pair[1]), LOADOUT_SLOT_BYTES)

	return writer.to_bytes()


static func read_loadout(reader: DotNetReader) -> Dictionary:
	var count := reader.read_uint(LOADOUT_COUNT_BITS)
	var pairs: Array = []

	for _index in mini(count, LOADOUT_MAX_SLOTS):
		var slot := reader.read_string(LOADOUT_SLOT_BYTES)
		var item := reader.read_string(LOADOUT_SLOT_BYTES)

		# Read past the end returns zeros rather than failing — dot-timer found that with
		# a truncated replay that parsed as a valid replay of nothing — so the loop stops
		# on the reader rather than on the count.
		if not reader.ok():
			break

		pairs.append([slot, item])

	return {"pairs": pairs, "ok": reader.ok()}


# --- Inventory -------------------------------------------------------------

## What an [constant Ask.INVENTORY] carries.
enum InvAsk {
	## An op the client has already applied to its own copy: a sequence number and the op.
	OP,
	## "Send me the whole bag": the newest sequence number this client has used.
	RESYNC,
	## Buy one of this into the bag, through the shop.
	BUY,
}

## What a [constant Kind.INVENTORY] carries.
enum InvTell {
	## The answer to one op: its sequence number, yes or no, and why not.
	ACK,
	## The whole bag, and the newest sequence number it already reflects.
	DOC,
}

const INV_SUB_BITS := 2
const INV_CONTAINER_BYTES := 48
const INV_REASON_BYTES := 120
## A JSON document. A full 10x6 bag of one-cell items is about five kilobytes, inside
## [constant PlaygroundEvent.MAX_BODY]; see [method write_inv_doc] for what happens past it.
const INV_DOC_BYTES := 12000
const INV_OP_KIND_BITS := 3
const INV_CELL_MIN := -1
const INV_CELL_MAX := 254


## Whether every sub-kind fits its field: [enum InvAsk] and [enum InvTell] in
## [constant INV_SUB_BITS], dot-inventory's [enum DotInvOp.Kind] (an enum that grows outside
## this game, written clamped) in [constant INV_OP_KIND_BITS], and [enum ProjectileTell] in
## [constant PROJECTILE_SUB_BITS]. What headless_net reads.
static func sub_kinds_fit() -> bool:
	return int(InvAsk.values().max()) < (1 << INV_SUB_BITS) \
		and int(InvTell.values().max()) < (1 << INV_SUB_BITS) \
		and int(DotInvOp.Kind.values().max()) < (1 << INV_OP_KIND_BITS) \
		and int(ProjectileTell.values().max()) < (1 << PROJECTILE_SUB_BITS)


## One op, and its sequence number.
##
## [b]Field by field, and deliberately without [code]state[/code].[/b] `DotInvOp.state`
## is "whatever a game wants to carry with an ADD — durability, an enchantment, a
## serial", which is exactly what a client must not get to write: a client ADD is refused
## anyway, and a state that crossed the wire on a MOVE would be a way to stamp a serial
## on something. The [code]actor[/code] is absent too, as dot-inventory insists — the
## server sets it from the peer the request arrived on.
static func write_inv_op(seq: int, op: Dictionary) -> PackedByteArray:
	var w := _w()
	w.write_uint(InvAsk.OP, INV_SUB_BITS)
	w.write_varint(maxi(seq, 0))
	w.write_uint(clampi(int(op.get("kind", 0)), 0, (1 << INV_OP_KIND_BITS) - 1), INV_OP_KIND_BITS)
	w.write_string(str(op.get("from", "")), INV_CONTAINER_BYTES)
	w.write_varint(maxi(int(op.get("from_uid", 0)), 0))
	w.write_string(str(op.get("to", "")), INV_CONTAINER_BYTES)
	var cell: Variant = op.get("cell", [0, 0])
	var cx := 0
	var cy := 0
	if cell is Array and (cell as Array).size() >= 2:
		cx = int(cell[0])
		cy = int(cell[1])
	w.write_svarint(clampi(cx, INV_CELL_MIN, INV_CELL_MAX))
	w.write_svarint(clampi(cy, INV_CELL_MIN, INV_CELL_MAX))
	w.write_bool(bool(op.get("rotated", false)))
	w.write_varint(maxi(int(op.get("to_uid", 0)), 0))
	w.write_varint(maxi(int(op.get("count", 1)), 0))
	w.write_string(str(op.get("item", "")), ID_BYTES)
	return w.to_bytes()


## Reads the sub-kind every [constant Ask.INVENTORY] starts with.
static func read_inv_ask(r: DotNetReader) -> int:
	return r.read_uint(INV_SUB_BITS)


## The rest of an [constant InvAsk.OP], after [method read_inv_ask]. The op comes back as
## the dictionary [method DotInvOp.from_dictionary] reads.
static func read_inv_op(r: DotNetReader) -> Dictionary:
	var seq := r.read_varint()
	var op := {
		"kind": r.read_uint(INV_OP_KIND_BITS),
		"from": r.read_string(INV_CONTAINER_BYTES),
		"from_uid": r.read_varint(),
		"to": r.read_string(INV_CONTAINER_BYTES),
		"cell": [r.read_svarint(), r.read_svarint()],
		"rotated": r.read_bool(),
		"to_uid": r.read_varint(),
		"count": r.read_varint(),
		"item": r.read_string(ID_BYTES),
		"state": {},
	}
	return {"seq": seq, "op": op, "ok": r.ok()}


static func write_inv_resync(seq: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(InvAsk.RESYNC, INV_SUB_BITS)
	w.write_varint(maxi(seq, 0))
	return w.to_bytes()


static func read_inv_resync(r: DotNetReader) -> Dictionary:
	var seq := r.read_varint()
	return {"seq": seq, "ok": r.ok()}


static func write_inv_buy(item_id: StringName) -> PackedByteArray:
	var w := _w()
	w.write_uint(InvAsk.BUY, INV_SUB_BITS)
	w.write_string(String(item_id), ID_BYTES)
	return w.to_bytes()


static func read_inv_buy(r: DotNetReader) -> Dictionary:
	var item := StringName(r.read_string(ID_BYTES))
	return {"item": item, "ok": r.ok()}


static func write_inv_ack(seq: int, ok: bool, reason: String) -> PackedByteArray:
	var w := _w()
	w.write_uint(InvTell.ACK, INV_SUB_BITS)
	w.write_varint(maxi(seq, 0))
	w.write_bool(ok)
	w.write_string(reason, INV_REASON_BYTES)
	return w.to_bytes()


## Reads the sub-kind every [constant Kind.INVENTORY] starts with.
static func read_inv_tell(r: DotNetReader) -> int:
	return r.read_uint(INV_SUB_BITS)


static func read_inv_ack(r: DotNetReader) -> Dictionary:
	var seq := r.read_varint()
	var accepted := r.read_bool()
	var reason := r.read_string(INV_REASON_BYTES)
	return {"seq": seq, "accepted": accepted, "reason": reason, "ok": r.ok()}


## The whole bag, as the JSON [method DotInvDoc.to_dictionary] was written to survive.
##
## [b]JSON rather than a field-by-field encoding, on purpose.[/b] `DotInvDoc` and
## `DotInvContainer` write cells as two numbers because "a Vector2i does not survive JSON",
## which makes JSON the format they claim — and the format a saved bag will be in. Sending
## the same bytes a save would hold is what puts that claim through a real round trip every
## time somebody joins, rather than a second encoding beside it that could drift.
##
## [b]Refused, not truncated, when it is too big.[/b] [method DotNetWriter.write_string]
## truncates, and a truncated JSON document is one the client cannot parse — so it would
## arrive as a bag the client silently fails to adopt. An empty result here is one
## [method PlaygroundNetBridge._tell] refuses to send, and the caller logs it.
static func write_inv_doc(through_seq: int, doc: Dictionary) -> PackedByteArray:
	var text := JSON.stringify(doc)
	if text.to_utf8_buffer().size() > INV_DOC_BYTES:
		return PackedByteArray()
	var w := _w()
	w.write_uint(InvTell.DOC, INV_SUB_BITS)
	w.write_varint(maxi(through_seq, 0))
	w.write_string(text, INV_DOC_BYTES)
	return w.to_bytes()


static func read_inv_doc(r: DotNetReader) -> Dictionary:
	var through := r.read_varint()
	var text := r.read_string(INV_DOC_BYTES)
	if not r.ok():
		return {"ok": false}
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false}
	return {"through": through, "doc": parsed as Dictionary, "ok": true}


# --- Projectiles ----------------------------------------------------------------

## A projectile left a weapon. Floats in full for the velocity and the fuse numbers: a client
## flies its copy from these, and a quantised velocity is an arc that lands somewhere else.
static func write_launch(
	serial: int, spawn: DotWeaponSpawn, owner_id: StringName, sticks: bool
) -> PackedByteArray:
	var w := _w()
	w.write_uint(ProjectileTell.LAUNCH, PROJECTILE_SUB_BITS)
	w.write_varint(serial)
	w.write_string(String(spawn.id), ID_BYTES)
	w.write_string(String(owner_id), ID_BYTES)
	w.write_vector3_range(spawn.origin, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_float32(spawn.velocity.x)
	w.write_float32(spawn.velocity.y)
	w.write_float32(spawn.velocity.z)
	w.write_float32(spawn.gravity_scale)
	w.write_float32(spawn.radius)
	w.write_float32(spawn.splash_radius)
	w.write_varint(maxi(spawn.fuse_ticks, 0))
	w.write_varint(maxi(spawn.life_ticks, 0))
	w.write_bool(sticks)
	return w.to_bytes()


## Reads what [method write_launch] wrote, after the sub-kind, as a [DotWeaponSpawn] a
## client can fly. Damage is not sent: a client's copy hurts nobody.
static func read_launch(r: DotNetReader) -> Dictionary:
	var serial := r.read_varint()
	var spawn := DotWeaponSpawn.new()
	spawn.id = StringName(r.read_string(ID_BYTES))
	var owner_id := StringName(r.read_string(ID_BYTES))
	spawn.origin = r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	spawn.velocity = Vector3(r.read_float32(), r.read_float32(), r.read_float32())
	spawn.gravity_scale = r.read_float32()
	spawn.radius = r.read_float32()
	spawn.splash_radius = r.read_float32()
	spawn.fuse_ticks = r.read_varint()
	spawn.life_ticks = r.read_varint()
	spawn.meta[&"sticks"] = r.read_bool()
	return {"serial": serial, "spawn": spawn, "owner_id": owner_id, "ok": r.ok()}


static func write_detonate(serial: int, at: Vector3, radius: float) -> PackedByteArray:
	var w := _w()
	w.write_uint(ProjectileTell.DETONATE, PROJECTILE_SUB_BITS)
	w.write_varint(serial)
	w.write_vector3_range(at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_float32(radius)
	return w.to_bytes()


static func read_detonate(r: DotNetReader) -> Dictionary:
	var serial := r.read_varint()
	var at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	var radius := r.read_float32()
	return {"serial": serial, "position": at, "radius": radius, "ok": r.ok()}


# --- ADDON ---------------------------------------------------------------------

const ADDON_NAME_BYTES := 48
const ADDON_BODY_BYTES := 900


static func write_addon(addon: String, body: Dictionary) -> PackedByteArray:
	var w := _w()
	w.write_string(addon, ADDON_NAME_BYTES)
	w.write_string(JSON.stringify(body), ADDON_BODY_BYTES)
	return w.to_bytes()


## [code]ok[/code] is false for a body that is not a JSON object, so a hook is never handed
## something it did not expect to be a dictionary.
static func read_addon(r: DotNetReader) -> Dictionary:
	var addon := r.read_string(ADDON_NAME_BYTES)
	var parsed: Variant = JSON.parse_string(r.read_string(ADDON_BODY_BYTES))
	return {"addon": addon, "body": parsed if parsed is Dictionary else {},
		"ok": r.ok() and parsed is Dictionary}


# --- BUILDS --------------------------------------------------------------------

## The most builds one list carries. A player with more sees the first this many by name;
## `pg_builds` in chat still lists all of them.
const BUILDS_MAX := 64
const BUILD_NAME_BYTES := 32


## [param list] is [method PlaygroundBuilds.summaries]: `{name, props, custom}` each.
static func write_builds(list: Array) -> PackedByteArray:
	var w := _w()
	var count := mini(list.size(), BUILDS_MAX)
	w.write_uint(count, 7)
	for i in count:
		var entry: Dictionary = list[i]
		w.write_string(str(entry.get("name", "")), BUILD_NAME_BYTES)
		w.write_uint(clampi(int(entry.get("props", 0)), 0, 255), 8)
		w.write_bool(bool(entry.get("custom", false)))
	return w.to_bytes()


static func read_builds(r: DotNetReader) -> Dictionary:
	var out: Array[Dictionary] = []
	var count := mini(r.read_uint(7), BUILDS_MAX)
	for i in count:
		var name := r.read_string(BUILD_NAME_BYTES)
		var props := r.read_uint(8)
		var custom := r.read_bool()
		out.append({"name": name, "props": props, "custom": custom})
	return {"builds": out, "ok": r.ok()}


# --- SELECTION -----------------------------------------------------------------

## The settings travel as JSON, for the reason a tool's settings do on the way in: they are
## one mode's schema, and a field-by-field encoding is a second copy of that schema.
const SELECTION_SETTINGS_BYTES := 512


static func write_selection(net_id: int, prop_name: String, settings: Dictionary, refused: String) -> PackedByteArray:
	var w := _w()
	w.write_varint(maxi(net_id, 0))
	w.write_string(prop_name, NAME_BYTES)
	w.write_string(JSON.stringify(settings), SELECTION_SETTINGS_BYTES)
	w.write_string(refused, TEXT_BYTES)
	return w.to_bytes()


static func read_selection(r: DotNetReader) -> Dictionary:
	var net_id := r.read_varint()
	var prop_name := r.read_string(NAME_BYTES)
	var text := r.read_string(SELECTION_SETTINGS_BYTES)
	var refused := r.read_string(TEXT_BYTES)
	if not r.ok():
		return {"ok": false}
	var parsed: Variant = JSON.parse_string(text) if text != "" else {}
	if not (parsed is Dictionary):
		return {"ok": false}
	return {"net_id": net_id, "name": prop_name, "settings": parsed, "refused": refused, "ok": true}


# --- PANE ----------------------------------------------------------------------

static func write_pane(index: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(maxi(index, 0))
	return w.to_bytes()


static func read_pane(r: DotNetReader) -> Dictionary:
	var index := r.read_varint()
	return {"index": index, "ok": r.ok()}


# --- TOYS ----------------------------------------------------------------------

## The toys of [param map_id], by their net ids in toy order.
static func write_toys(map_id: StringName, net_ids: PackedInt64Array) -> PackedByteArray:
	var w := _w()
	w.write_string(String(map_id), ID_BYTES)
	w.write_varint(net_ids.size())
	for id in net_ids:
		w.write_varint(maxi(int(id), 0))
	return w.to_bytes()


static func read_toys(r: DotNetReader) -> Dictionary:
	var map_id := StringName(r.read_string(ID_BYTES))
	var count := r.read_varint()
	var ids := PackedInt64Array()
	if count < 0 or count > 256:
		return {"map_id": map_id, "ids": ids, "ok": false}
	for i in count:
		ids.append(r.read_varint())
	return {"map_id": map_id, "ids": ids, "ok": r.ok()}


# --- HIT -----------------------------------------------------------------------

## Your hit landed ([signal Playground.hit_landed]). The victim as its kind (4 bits) and the
## low 32 bits of its serial, which only group hits on one body for the damage numbers: a
## whole id is a kind times 10^12 and does not fit a field worth sending.
static func write_hit(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> PackedByteArray:
	var w := _w()
	w.write_uint(clampi(victim / DotEntity.STRIDE, 0, 15), 4)
	w.write_uint(posmod(victim, DotEntity.STRIDE) & 0xFFFFFFFF, 32)
	w.write_float_range(clampf(amount, 0.0, 1000.0), 0.0, 1000.0, 14)
	w.write_vector3_range(point, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_uint((1 if killed else 0) | (2 if headshot else 0), 2)
	return w.to_bytes()


static func read_hit(r: DotNetReader) -> Dictionary:
	var kind := r.read_uint(4)
	var serial := r.read_uint(32)
	var amount := r.read_float_range(0.0, 1000.0, 14)
	var point := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	var flags := r.read_uint(2)
	return {"victim": kind * DotEntity.STRIDE + serial, "amount": amount, "point": point,
		"killed": flags & 1 != 0, "headshot": flags & 2 != 0, "ok": r.ok()}
