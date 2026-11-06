extends RefCounted

## The wire format for everything that is not a snapshot or an input.
##
## Encoders and decoders in pairs, exact inverses; the headless net suite round-trips each.
##
## A prop is announced (catalogue id, net id), not spawned by a factory: props are named by path
## in the catalogue so a dot-cloud pack can deliver them.

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
	## Zee gun dropped, settled, or taken or expired; a joiner gets every gun lying about.
	WEAPON_DROP,
	WEAPON_SETTLED,
	WEAPON_GONE,
	## A prop broke: where and what it was made of, to everybody, for the splinters.
	SHATTER,
}

## What a [constant Kind.PROJECTILE] event says.
## BLIND goes to the one player a flash caught: how long.
enum ProjectileTell { LAUNCH, DETONATE, BLIND }
const PROJECTILE_SUB_BITS := 2
## A detonation's utility kind: 0 none, 1 smoke, 2 fire.
const DETONATE_FX_BITS := 2

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
	## Get me into whatever I am standing next to, or out of what I am in. One ask for both, because the
	## player pressed one key: a client guessing which would ask to enter the car it is already in.
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
	## The sixteenth kind, the last four bits hold: later ones go in as a sub-kind, as [constant INVENTORY] does.
	ARM_PROP,
}

## Every decoder returns an `ok` alongside its fields, and every caller checks it.
##
## A reader past its end returns plausible zeros, so a skipped check gets a believable value
## after an overrun and a truncated packet decodes as a valid message about nothing.
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
## The tick rate is in here: a client that counted at its export's 60 against a server running
## 128 had every replicated time wrong by 128/60.
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


## Who is in what, and where. Sent to everybody, because a client draws others sitting in cars.
## [param seat_index] indexes the vehicle definition's seat list, not the seat id: a byte, not sixty-four.
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


# The Ask enum is four bits and full, so tool gun settings, the NPC weapon choice and weapon spawns ride on
# ARM_PROP as sub-kinds after its id. A body with nothing after the id is the original ARM_PROP.

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
## Throw the gun in my hands.
const ARM_DROP_WEAPON := 7

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
## Encoded field by field, not JSON: a JSON body is an unbounded blob a hostile server could inflate.
## The meta field is one bounded number (the player the line belongs to); the kind is an index into
## [constant DotChatMessage.KIND_NAMES], one table both ways.
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
## An event, not a [DotNetVar]: health moves on a hit, not a tick, so a field would send an
## unchanged byte per player at the snapshot rate. A death carries how the body falls
## ([DotPlayerDeath]) last and optional, so a reader of only the fields above still works.
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
## Sent rather than derived: a mirroring client's [DotMatch] never ticks, so its clock never advances.
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
## A token rather than an enum: what an id means is a [DotVoteSource]'s business.
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
## Ids only: the server validates them against a schema and entitlements, and refuses rather
## than repairs a loadout it does not like.
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
