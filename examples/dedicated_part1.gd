extends "res://examples/dedicated_base.gd"
## The middle sections of the dedicated-server suite.


## Profiles and avatars: ids and a schema, and no art anywhere.
func _test_identity() -> void:
	print("")
	print("identity")

	_check(platform.hub != null and platform.hub.is_ready(), "the platform is up")
	_check(
		server.modules.get_module("platform") != null,
		"and its module is loaded beside the game's"
	)

	var schema := PlaygroundPlatform.avatar_schema()
	var problems := schema.validate_schema()

	# [b]A schema that validates is not a formality.[/b] game-hungario shipped a part that
	# was its own fallback — a resolution loop that cannot terminate — and its suite never
	# noticed, because it never validated a schema.
	_check(problems.ok, "the avatar schema is valid", str(problems.error))

	var legal := DotAvatar.make(&"pg_builder")
	legal.set_part(&"body", &"body_overalls")
	legal.set_part(&"hat", &"hat_cap")

	_check(
		schema.validate(legal, DotAvatarEntitlements.none()).ok,
		"a free avatar is accepted with no entitlements at all"
	)

	var locked := DotAvatar.make(&"pg_builder")
	locked.set_part(&"body", &"body_plain")
	locked.set_part(&"hat", &"hat_hard")

	# [b]Entitlements default to nothing and that default is the important one.[/b] A
	# server that granted everything would work perfectly in every test, ship, and quietly
	# be a game where every unlock is free — which nobody reports as a bug.
	_check(
		not schema.validate(locked, DotAvatarEntitlements.none()).ok,
		"and one nobody has unlocked is refused"
	)
	_check(
		schema.validate(locked, DotAvatarEntitlements.of([&"hat_hard"])).ok,
		"until they hold it"
	)

	# [b]The key a statistic is filed under, and the reason dot-platform is here at
	# all.[/b] dot-stats refuses an account id as a player key before it leaves the
	# server, and a board is exactly the same kind of record — so the one function that
	# decides has to give a scoped id when there is an identity stack and something
	# honest when there is not.
	var key := PlaygroundPlatform.key_for_session(server, null)
	_check(key == "", "no session is no key rather than a guessed one")

	_check(
		PlaygroundProgress.stats_schema().has(&"props"),
		"the stats schema declares what the game reports"
	)
	_section_done()


## An administrator's blind and beacon, typed at the console of a real server.
##
## What is asserted is the flag on the player and on the entity the netcode sends, because
## that is the whole of what the server decides; whether the owner's client — and only the
## owner's — receives it is `headless_net`'s, and what it looks like is
## `tools/screenshot_views.sh`'s.
func _test_blind_and_beacon() -> void:
	print("")
	print("[blind and beacon]")

	var player := game.add_player(&"u78", "Quin")
	var session := DotClientSession.new()
	session.peer_id = 7808
	session.userid = 78
	session.display_name = "Quin"
	var _adopted := server.adopt_session(session)

	var blinded := await _run_command_later("blind Quin")
	_check(player.blinded, "`blind Quin` blacks their screen out", " | ".join(blinded))

	# The flag reaching the replicated field is the half of this the server owns. `pull`
	# is what the netcode's tick calls; this suite drives no net tick, so it is called here.
	var net := player.get_node_or_null("Net")
	if net != null:
		net.call("pull")
	_check(
		net != null and bool(net.get("net_blind")),
		"and it is on the entity the netcode sends them"
	)

	var _lift := await _run_command_later("blind Quin off")
	_check(not player.blinded, "`blind Quin off` lifts it")

	# A blind is a spell. dot-moderation lifts it through the same handler when the time
	# is up, so what is checked is the flag, not the timer.
	var _spell := await _run_command_later("blind Quin 0.2")
	_check(player.blinded, "`blind Quin 0.2` blinds them for a fifth of a second")
	await get_tree().create_timer(0.4).timeout
	_check(not player.blinded, "and it lifts on its own when the time is up")

	var lit := await _run_command_later("beacon Quin")
	_check(player.beacon, "`beacon Quin` marks them for everybody", " | ".join(lit))

	var _dark := await _run_command_later("blind Quin")
	var _back := await _run_command_later("respawn Quin")
	_check(
		player.blinded and player.beacon,
		"a respawn keeps both: they are about the person, not the body"
	)

	var described := _run_command("modtools")
	var abilities := ""
	var refused := ""
	for line in described:
		if line.begins_with("abilities"):
			abilities = line
		elif line.begins_with("refused"):
			refused = line
	_check(
		abilities.contains("blind") and abilities.contains("beacon")
		and not refused.contains("blind") and not refused.contains("beacon"),
		"`modtools` lists both as abilities and refuses neither",
		"%s / %s" % [abilities, refused]
	)

	var _dark_off := await _run_command_later("blind Quin off")
	var _unlit := await _run_command_later("beacon Quin off")
	var tools: DotModTools = _module().get("mod_tools")
	_check(
		not player.blinded and not player.beacon
		and not tools.is_active(&"78", DotModTools.ACTION_BLIND)
		and not tools.is_active(&"78", DotModTools.ACTION_BEACON),
		"and both come off, with the tools' record agreeing with the world"
	)

	var _released := server.release_session(session.peer_id)
	game.remove_player(&"u78")
	_section_done()


## [method _run_command] as a player: what `!creative` in chat arrives as.
func _run_as(session: DotClientSession, line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := DotCmdContext.console("", PackedStringArray())
	template.session = session
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	return PackedStringArray(captured)


## dot-team's block rules through dot-game's DotGameNoblock: strangers block by default, `!noblock` lets the caller's pairs pass, `!block` takes it back, and the cvars decide.
func _test_noblock() -> void:
	print("")
	print("[noblock]")
	var teamblock := server.console.find_cvar("mp_teamblock")
	var enemyblock := server.console.find_cvar("mp_enemyblock")
	_check(teamblock != null and teamblock.get_string() == "0" and enemyblock != null and enemyblock.get_string() == "1",
		"mp_teamblock is 0 and mp_enemyblock is 1 by default")
	_check(server.console.find_cvar("mp_blockstate") != null and server.console.has_name("pg_arena_round_sec"),
		"mp_blockstate and the config cvars are bound")
	var _a := game.add_player(&"u81", "Walker")
	var _b := game.add_player(&"u82", "Other")
	var session := DotClientSession.new()
	session.peer_id = 8109
	session.userid = 81
	session.display_name = "Walker"
	var _adopted := server.adopt_session(session)
	_check(game.body_rules.blocks(&"u81", &"u82"), "two players with no side block each other")
	var said := _run_as(session, "noblock")
	_check(not game.body_rules.blocks(&"u81", &"u82") and not game.body_rules.blocks(&"u82", &"u81"), "`!noblock` lets the pair pass, both ways", " | ".join(said))
	said = _run_as(session, "block")
	_check(game.body_rules.blocks(&"u81", &"u82"), "`!block` takes the request back", " | ".join(said))
	enemyblock.set_value("0")
	_check(not game.body_rules.blocks(&"u81", &"u82"), "mp_enemyblock 0 lets everybody pass")
	enemyblock.set_value("1")
	var _released := server.release_session(session.peer_id)
	game.remove_player(&"u81")
	game.remove_player(&"u82")
	_section_done()


## Creative mode: `!creative` from a player, their props protected, out of the fight both
## ways, and `pg_creative 0` ending it for everybody.
func _test_creative() -> void:
	print("")
	print("[creative mode]")

	var builder := game.add_player(&"u79", "Builder")
	var other := game.add_player(&"u80", "Other")
	var session := DotClientSession.new()
	session.peer_id = 7909
	session.userid = 79
	session.display_name = "Builder"
	var _adopted := server.adopt_session(session)

	var said := _run_as(session, "creative")
	_check(builder.creative and _said(said, "on"), "`!creative` switches it on for the caller", " | ".join(said))
	_check(game.props.is_protected(&"u79"), "and protects their props in dot-props")

	var crate := game.props.spawn(&"crate", &"u79", Vector3(0.0, 40.0, 0.0))
	var tool := DotPropTool.new()
	tool.spawner = game.props
	tool.wielder = &"u80"
	_check(crate != null and not tool.may_act_on(crate).ok, "nobody else's tool may touch what they build")

	var net := builder.get_node_or_null("Net")
	if net != null:
		net.call("pull")
	_check(net != null and bool(net.get("net_creative")), "and it is on the entity everybody is sent")

	var arena: PlaygroundArena = _module().get("arena")
	_run_command("pg_arena on")
	arena.admit(&"u79", "Builder")
	arena.admit(&"u80", "Other")
	for step in range(game.tick_rate * 5):
		arena.tick(step, 1.0 / float(game.tick_rate))
	# What the shooter's hit marker hears: only a hit that landed, and only theirs.
	var confirmed: Array = []
	var on_hit := func(by: StringName, victim: int, amount: float, _at: Vector3, _killed: bool, _head: bool) -> void:
		confirmed.append([by, victim, amount])
	game.hit_landed.connect(on_hit)
	var at_them := arena.hurt(&"u80", &"u79", 30.0, 5.0)
	var by_them := arena.hurt(&"u79", &"u80", 30.0, 5.0)
	_check(confirmed.is_empty(), "and a refused hit confirms nothing to the shooter", str(confirmed))
	_check(at_them != null and at_them.refused, "nobody can hurt them", str(at_them))
	_check(by_them != null and by_them.refused, "and they cannot hurt anybody", str(by_them))

	said = _run_as(session, "creative")
	var lands := arena.hurt(&"u80", &"u79", 30.0, 5.0)
	_check(not builder.creative and lands != null and not lands.refused, "`!creative` again turns it off, and a hit lands", str(lands))
	_check(confirmed.size() == 1 and confirmed[0][0] == &"u80" and int(confirmed[0][1]) == arena.entity_id_of(&"u79")
		and lands != null and absf(float(confirmed[0][2]) - lands.health_lost) < 0.01,
		"and the one that lands is confirmed to its shooter, for what it took", str(confirmed))
	game.hit_landed.disconnect(on_hit)

	var _on := _run_as(session, "creative")
	_run_command("pg_creative 0")
	_check(not builder.creative and not game.props.is_protected(&"u79"), "`pg_creative 0` ends it for everybody")
	said = _run_as(session, "creative")
	_check(not builder.creative and _said(said, "off on this server"), "and refuses it after", " | ".join(said))
	_run_command("pg_creative 1")
	_check(game.config.allow_creative, "`pg_creative 1` allows it again")

	arena.release(&"u79")
	arena.release(&"u80")
	_run_command("pg_arena off")
	if crate != null:
		var _gone := game.props.remove(crate.instance_id)
	var _released := server.release_session(session.peer_id)
	game.remove_player(&"u79")
	game.remove_player(&"u80")
	_section_done()


## `pg_save`, `pg_builds`, `pg_load` and `pg_build_delete`, typed by a player.
func _test_saved_builds() -> void:
	print("")
	print("[saved builds]")

	var module := _module()
	module.get("builds").set("directory", "%s/builds" % SERVER_DIR)
	var builder := game.add_player(&"u81", "Mason")
	var session := DotClientSession.new()
	session.peer_id = 8101
	session.userid = 81
	session.display_name = "Mason"
	var _adopted := server.adopt_session(session)

	var at := builder.controller.state.position
	var _a := game.props.spawn(&"crate", &"u81", at + Vector3(0.0, 30.0, -3.0))
	var _b := game.props.spawn(&"plank", &"u81", at + Vector3(1.0, 30.0, -3.0))

	var said := _run_as(session, "pg_save tower")
	_check(_said(said, "saved") and _said(said, "2 props"), "`pg_save tower` saves what they built", " | ".join(said))
	said = _run_as(session, "pg_builds")
	_check(_said(said, "tower"), "`pg_builds` lists it", " | ".join(said))
	game.props.clear_player(&"u81")
	said = _run_as(session, "pg_load tower")
	_check(_said(said, "put down") and game.props.props_of(&"u81").size() == 2, "`pg_load tower` puts it back", " | ".join(said))
	said = _run_as(session, "pg_load nothing")
	_check(_said(said, "no build called"), "a build they never saved is refused by name", " | ".join(said))

	# The Q menu's Builds tab asks over the wire; the module answers the same as the commands.
	var summaries: Array = module.get("builds").call("summaries", PlaygroundPlatform.key_for_session(server, session))
	_check(summaries.size() == 1 and summaries[0]["name"] == "tower" and int(summaries[0]["props"]) == 2,
		"the Builds tab is sent what pg_builds lists", str(summaries))
	game.props.clear_player(&"u81")
	# The click is answered over the wire with a NOTICE to the clicker. 8101 is a session
	# this suite adopted with no socket behind it, so sent for real that NOTICE was an
	# `rpc_id` to a peer the multiplayer API has never heard of, and every green run printed
	# "Attempt to call RPC with unknown peer ID: 8101". Caught on the link's loopback for the
	# one call instead: the reply becomes a check, and a real unknown-peer line in this
	# suite's stderr is a real one.
	var link: Variant = module.get("bridge").get("link")
	var replies: Array = []
	if link != null:
		link.loopback = func(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
			replies.append({"method": method, "peer": peer_id, "payload": payload})
	module.get("bridge").build_load_requested.emit(session.peer_id, "tower")
	if link != null:
		link.loopback = Callable()
	_check(game.props.props_of(&"u81").size() == 2, "and a click on it puts it down, as pg_load does")
	var told := false
	for reply: Dictionary in replies:
		if reply["method"] == &"event" and int(reply["peer"]) == session.peer_id \
				and (reply["payload"] as PackedByteArray).hex_encode().contains("Put down".to_utf8_buffer().hex_encode()):
			told = true
	_check(link != null and told, "and the clicker alone is told it was put down", str(replies.map(func(r: Dictionary) -> String: return "%s->%d" % [r["method"], r["peer"]])))
	said = _run_as(session, "pg_build_delete tower")
	_check(_said(said, "deleted") and not _said(_run_as(session, "pg_builds"), "tower"), "and `pg_build_delete` takes it away", " | ".join(said))

	game.props.clear_player(&"u81")
	var _released := server.release_session(session.peer_id)
	game.remove_player(&"u81")
	_section_done()


## [method _run_command] for a coroutine handler: the live tools record each action on a
## punishment store, which may be remote, so the reply can land a frame late.
func _run_command_later(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := DotCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	await get_tree().process_frame
	await get_tree().process_frame
	return PackedStringArray(captured)


## The inventory from the console: an operator puts something in somebody's bag and reads it
## back. `headless_net` is where the bag crosses the wire; this is where the MODULE's half —
## the commands and who a session is for a bag that outlasts it — is run at all.
func _test_inventory_commands() -> void:
	print("")
	print("[the inventory, from the console]")

	var bridge: Variant = _module().get("bridge")
	_check(
		bridge != null and (bridge.get("inventory_key_fn") as Callable).is_valid(),
		"the module tells the bridge who a session is, so a bag can outlast a reconnect"
	)

	var player := game.add_player(&"u79", "Rae")
	var session := DotClientSession.new()
	session.peer_id = 7909
	session.userid = 79
	session.display_name = "Rae"
	var _adopted := server.adopt_session(session)

	var given := _run_command("pg_give Rae crate 2")
	var bag: StringName = bridge.get("inventory_net").call("bag_key", 79) if bridge != null else &""
	_check(
		player != null and game.inventory.carries(bag, &"crate") == 2 and _said(given, "2 crate"),
		"`pg_give Rae crate 2` puts two crates in their bag (%s)" % bag,
		" | ".join(given)
	)
	var carried := _run_command("pg_inv Rae")
	_check(_said(carried, "crate"), "and `pg_inv Rae` lists them", " | ".join(carried))
	var nobody := _run_command("pg_give Nobody crate")
	_check(_said(nobody, "pg_give <player>"), "somebody who is not here is answered with the usage")

	# A session nobody can recognise next time has no bag that outlasts it: the platform's
	# `local:<userid>` identifies nobody after a reconnect, and a bag kept under it would be
	# one abandoned bag per connection for the life of the server.
	var key := str(_module().call("_bag_key_for", 79))
	_check(
		not key.begins_with("bag:local:"),
		"and a key that identifies nobody next time is not used to keep a bag (%s)" % (key if key != "" else "the session's own")
	)

	var _released := server.release_session(session.peer_id)
	game.remove_player(&"u79")
	_section_done()


## A joiner is welcomed when it says READY, which on every real join is AFTER `client_spawn`.
##
## [b]The module's own half of `[pg-rpc-before-scene]`.[/b] `_welcome` (the chat backlog and
## the join line) ran from `client_spawn` and returned unless the bridge had the peer READY,
## which it never does at spawn, because the client says READY only once its scene is up. So
## no connected player had ever been sent either. This drives the real order: a session,
## `client_spawn`, then READY through the bridge, recording what goes to that one peer.
func _test_welcome_waits_for_ready() -> void:
	print("a joiner is welcomed when it says READY, and not before")

	var bridge: PlaygroundNetBridge = _module().get("bridge")
	var services: PlaygroundServices = _module().get("services")
	var peer := 7909
	var session := DotClientSession.new()
	session.peer_id = peer
	session.userid = 79
	session.display_name = "Wren"
	var _adopted := server.adopt_session(session)
	var _said: Variant = services.chat.announce("said before Wren came", PlaygroundServices.CHANNEL_ALL)

	var kinds: Array[int] = []
	var old_send: Callable = bridge.net.send_fn
	bridge.net.send_fn = func(peer_id: int, payload: PackedByteArray, _delivery: int) -> void:
		if peer_id != peer:
			return
		var decoded: DotResult = bridge.net.messages.decode(DotNetReader.new(payload), 1, false)
		if decoded.ok and decoded.value is PlaygroundEvent:
			kinds.append((decoded.value as PlaygroundEvent).kind)

	var _spawned: DotEvent = server.events.fire("client_spawn", {"userid": 79})
	_check(game.players.has(&"u79"), "client_spawn puts the joiner in the game")
	_check(
		kinds.is_empty(),
		"and sends them nothing, because they have not said READY",
		str(kinds)
	)

	var writer := DotNetWriter.new()
	var _encoded: DotResult = bridge.net.messages.encode(
		PlaygroundRequest.new(PlaygroundEvents.Ask.READY, PackedByteArray()), writer
	)
	var _ready: DotResult = bridge.receive_request(peer, writer.to_bytes())
	var chats := kinds.count(PlaygroundEvents.Kind.CHAT)
	_check(
		kinds.has(PlaygroundEvents.Kind.HELLO) and chats >= 2,
		"READY sends HELLO and then the welcome: the backlog and the join line (%d chat)" % chats,
		str(kinds)
	)

	kinds.clear()
	var _again: DotResult = bridge.receive_request(peer, writer.to_bytes())
	_check(
		kinds.count(PlaygroundEvents.Kind.CHAT) == 0,
		"a READY said twice does not welcome them twice",
		str(kinds)
	)

	_check(bridge.net.peers().has(peer), "and dot-net now replicates to them")

	bridge.net.send_fn = old_send
	server.client_disconnected.emit(session, "closed")
	_check(not game.players.has(&"u79"), "and they leave cleanly")
	# The module takes them off the ready set BEFORE the bridge removes the player, and
	# the bridge used to ask that same set whether to tell dot-net: every peer that ever
	# disconnected stayed in `net.peers()`, built a snapshot for every tick.
	_check(
		not bridge.net.peers().has(peer),
		"and dot-net stops replicating to them",
		str(bridge.net.peers())
	)
	_section_done()


## A disconnect actually reaches the module.
##
## An ARITY check: `DotServer.client_disconnected` emits `(session, reason)`, and a handler
## taking only the session was refused by Godot on every call, so no player was ever removed.
func _test_disconnect_is_handled() -> void:
	print("a client disconnecting reaches the module")

	var session := DotClientSession.new()
	session.userid = 4242
	session.peer_id = 0
	session.display_name = "Leaver"

	game.add_player(&"u4242", "Leaver")
	_check(game.players.has(&"u4242"), "a player is in the game")

	# Emitted with BOTH arguments, exactly as DotServer emits it. A handler with the
	# wrong arity is refused by the engine rather than adapted to.
	server.client_disconnected.emit(session, "closed")

	_check(
		not game.players.has(&"u4242"),
		"and the disconnect took them back out again"
	)
	_section_done()


func _test_module_unloads_cleanly() -> void:
	print("the module unloads cleanly")

	game.add_player(&"u1", "One")
	_check(game.players.size() == 1, "a player is in the game")

	var unloaded := server.modules.unload_module("playground")
	_check(unloaded.ok, "the module unloads",
		unloaded.error.message if not unloaded.ok else "")

	# Its commands go with it. A module that left them behind would leave a console
	# whose commands call into a module that is no longer there.
	_check(
		server.console.find_command("pg_status") == null,
		"and takes its commands with it"
	)
	_check(
		server.console.find_command("noclip") == null,
		"the live tools' included"
	)
	_check(
		server.console.find_cvar("pg_map_seconds") == null,
		"and its cvars"
	)

	# And the players it put in the game come back out, or the game would be holding
	# players whose sessions no longer exist.
	_check(
		game.players.is_empty(),
		"and the players it added",
		"%d left" % game.players.size()
	)

	var reloaded: DotResult = await server.modules.load_module(
		"res://game/playground_module.gd"
	)
	_check(reloaded.ok, "and it can be loaded again")

	await get_tree().process_frame
	_section_done()


## A module reload must leave ONE link under the server, still named for the client's route.
## Two used to be left, the live one renamed `@Node@n`, and every RPC to a real client was lost
## without an error. The proof is a real client over the socket: the server's snapshots and
## events must reach a link of the client's own.
func _test_a_module_reload() -> void:
	print("")
	print("a module reload leaves one live link")

	for _i in range(2):
		_check(server.modules.unload_module("playground").ok, "the module unloads")
		var back: DotResult = await server.modules.load_module("res://game/playground_module.gd")
		_check(back.ok, "and loads again", back.error.message if not back.ok else "")
	for _i in range(5):
		await get_tree().process_frame

	var links := 0
	for child in server.get_children():
		if child.get_script() == PlaygroundNetLink:
			links += 1
	_check(links == 1 and server.has_node(NodePath(String(PlaygroundNetLink.NODE_NAME))),
		"exactly one link, under the name the client routes to", "%d" % links)

	var side := Node.new()
	side.name = "ReloadClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var mirror := Node.new()
	mirror.name = name
	side.add_child(mirror)
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Reloaded"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % server.config.port
	mirror.add_child(link)
	# The client's own link, re-made on each phase change as a real client's game scene does:
	# DotClientLink clears its children while connecting. Heard is what any of them counted.
	var heard := [0]
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(String(PlaygroundNetLink.NODE_NAME))) == null:
			var sink := PlaygroundNetLink.attached_to(link, null, false)
			sink.name = PlaygroundNetLink.NODE_NAME
			link.add_child(sink)
	attach.call()
	link.phase_changed.connect(attach)
	var known: Dictionary = {}
	for each in server.playing_sessions():
		known[each.userid] = true
	link.connect_to_server("127.0.0.1:%d" % server.config.port)
	# The server's side of the wire is the bridge's own link, told to send to the newcomer:
	# real snapshots wait for the client's READY, which needs a client-side bridge, and the
	# route (Server/Playground to the client's same path) is all this is about.
	var live: PlaygroundNetLink = _module().get("bridge").link
	_check(live.get_parent() == server, "the bridge's link is the one under the server")
	for _i in 1800:
		await get_tree().physics_frame
		for each in server.playing_sessions():
			if not known.has(each.userid) and heard[0] == 0:
				live.send_event(each.peer_id, PackedByteArray([0]))
		var sink := link.get_node_or_null(NodePath(String(PlaygroundNetLink.NODE_NAME)))
		if sink != null:
			heard[0] = maxi(heard[0], sink.snapshots_received + sink.events_received)
		if heard[0] > 0:
			break
	_check(heard[0] > 0, "a real client still hears the server's RPCs after two reloads",
		"%d heard, %s" % [heard[0], link.last_error])
	link.disconnect_from_server("done")
	for _i in range(10):
		await get_tree().process_frame
	side.queue_free()
	_section_done()


## A script that `extends DotNetMessage` and preloads ITSELF, first loaded from a module a running
## [DotServer] loads, leaves every loaded script alive at exit on Godot 4.7.2. The leak is reported after
## `quit()` where no check reaches, so this reads every message script in `game/` as text.
func _test_no_message_preloads_itself() -> void:
	print("exiting clean")

	var messages := PackedStringArray()
	var offenders := PackedStringArray()
	var pending: Array[String] = ["res://game"]

	while not pending.is_empty():
		var dir_path: String = pending.pop_back()

		for sub in DirAccess.get_directories_at(dir_path):
			pending.append(dir_path.path_join(sub))

		for file in DirAccess.get_files_at(dir_path):
			if not file.ends_with(".gd"):
				continue

			var path := dir_path.path_join(file)
			var source := FileAccess.get_file_as_string(path)

			if not _extends_message(source):
				continue

			messages.append(path)

			if source.contains('preload("%s")' % file) or source.contains('preload("%s")' % path):
				offenders.append(path)

	_check(
		messages.size() >= 2,
		"this game's message scripts are found, so the next check is about something",
		", ".join(messages)
	)
	_check(
		offenders.is_empty(),
		"and none of them preloads itself, which leaks every script at exit",
		", ".join(offenders)
	)
	_section_done()


func _extends_message(source: String) -> bool:
	for line in source.split("\n"):
		if line.begins_with("extends "):
			return line.contains("DotNetMessage") or line.contains("dot_net_message.gd")
	return false


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


func _exit_probe_seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return EXIT_PROBE_SECONDS


## Runs this same suite in a fresh process: `[exit code, its stdout, its stderr, whether it
## had to be killed, the seconds it was allowed]`.
##
## A leak ("N ObjectDB instances were leaked at exit") is printed after `quit()`, so only another process
## can check a run's exit. Run first, before this run opens a port, so it is the second run on the same `user://`.
##
## Not `OS.execute`: a hanging copy would hold this run, and an outer `timeout` would orphan it holding the
## port. So the copy is polled against a deadline and killed at it, with two deadlines:
##
## - coreutils `timeout` wraps the copy where it exists. It is an exec wrapper, not a shell,
##   and it outlives this process, so a copy orphaned by the outer `timeout` still dies on
##   time. Its exit status 124 is how its expiry is recognised.
## - this loop's own deadline, a little later, for a platform without it.
##
## `execute_with_pipe` rather than `create_process`, because the latter captures nothing and
## the whole point is reading what the copy printed. Non-blocking, and drained on every pass
## rather than once at the end: a pipe holds 64 KiB, and a copy that fills it blocks on its
## next print — a hang this probe would then report as the suite's own. The copy's stdin is
## the other end of a pipe this process holds open, which is why every suite turns the
## server's stdin console off: a reader blocked on it never lets the copy exit.
func _run_exit_probe() -> Array:
	var seconds := _exit_probe_seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit — %d s allowed)" % seconds)
	var scene := scene_file_path if scene_file_path != "" else "res://examples/dedicated.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	])
	var wrapped := false
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(seconds), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, seconds]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (seconds + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		_drain_exit_probe(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await get_tree().create_timer(0.1).timeout
	# Once more after it exits: what it wrote between the last pass and its exit is still in
	# the pipe, and the leak report is always the last thing it writes.
	_drain_exit_probe(pipes, bytes)

	# OS.kill has already reaped it, and asking for the exit code of a reaped pid is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, seconds]


func _drain_exit_probe(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


func _test_exits_clean(probe: Array) -> void:
	print("")
	print("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Every leak line is the engine's, and the engine writes them to stderr; both are
	# searched so that stays a fact about the engine rather than an assumption here. Shown
	# apart, because a pipe each is two streams whose interleaving is lost, and where a hung
	# copy had got to is the end of its stdout.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so neither of the last two was seen, and
	# passing them on an absence of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))
	_section_done()
