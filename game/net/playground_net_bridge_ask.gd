extends "res://game/net/playground_net_bridge_mid.gd"


func _connect_projectiles() -> void:
	if game.projectiles == null:
		return
	game.projectiles.launched.connect(_on_projectile_launched)
	game.projectiles.detonated.connect(_on_projectile_detonated)
	game.projectiles.effects.blinded.connect(_on_flash_blinded)


## Spawns in front of the player who asked. The budget, cooldown and undo stack are the SPAWNER's:
## a refusal comes back through `refused` and goes to that player alone. A bridge checking them
## itself would be a second copy of a rule.
func _spawn_for(id: StringName, prop_id: StringName) -> void:
	var player: PlaygroundPlayer = game.players.get(id)
	if player == null or game.props.catalogue == null:
		return

	var def := game.props.catalogue.get_prop(prop_id)
	if def == null:
		_tell(peer_for_player(session_of(id)), PlaygroundEvents.Kind.NOTICE,
			PlaygroundEvents.write_notice(session_of(id), "No such prop: %s" % prop_id))
		return

		# Carried first: something in the bag was paid for when it went in, so spawning it costs
		# nothing and takes it out (else every spawn was charged again). Taken only once the spawner
		# has said yes, so a spawn the prop budget refuses leaves the bag as it was.
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

	# Asked, spawned, and only then charged: a refused spawn must not have been paid for, and a refund can itself be refused (dot-economy's refund is policy).
	# "Can they afford it" is one read that changes nothing; refuse with a reason so a silent button is not mistaken for a broken menu.
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


## Somebody walked over a weapon on the server. It is given exactly as one from the menu
## is — charged, armed on a server rig — so a pickup cannot be a way round either.
func _on_weapon_picked_up(player_id: StringName, weapon_id: StringName) -> void:
	if net == null or not net.is_server:
		return
	_give_weapon(session_of(player_id), player_id, weapon_id)


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


## A flash caught [param player_id]: only they are told, because only they see white.
func _on_flash_blinded(player_id: StringName, seconds: float, strength: float) -> void:
	_tell(peer_for_player(session_of(player_id)), PlaygroundEvents.Kind.PROJECTILE, PlaygroundEvents.write_blind(seconds, strength))


## One chat line to one peer. Server side, and what [member DotChatRouter.send_fn] points at.
## Peer by peer, never a broadcast: the router has already worked out who may hear a line
## (everybody, a radius, a whisper) and a broadcast would throw that away.
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


## The match clock. Server side. Sent rather than derived, because a mirroring client's [DotMatch]
## never runs: `seconds_remaining()` would be computed from a tick nothing ever wrote, and the
## client showed `IDLE` for ever while the server played a round.
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


## Everybody who has said they can receive. Server side. The set chat and voice are addressed
## against, not [method DotServer.sessions]: a session exists from the moment a socket connects,
## a ready peer has built its scene and can be sent to.
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
