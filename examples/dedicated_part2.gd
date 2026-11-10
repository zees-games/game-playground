extends "res://examples/dedicated_part1.gd"
## The sections of the dedicated-server suite from the rotation file on: the vote, live tools, the loading cover and records.


func _test_map_rotation_file() -> void:
	print("")
	print("maps.yml")

	var module := _module()
	var vote: PlaygroundVote = module.get("vote")

	_check(game.maps != null and vote != null and vote.director != null, "the game has maps and a vote")
	if game.maps == null or vote == null or vote.director == null:
		return

	var catalogue := game.maps.catalogue
	var built := DotMapRotationFile.from_trees([{"defaults": {
		"rotation": "main",
		"rotations": {
			"main": {"mode": "cycle", "cooldown": 0, "maps": ["pg_flatgrass"]},
			"alt": {"maps": ["pg_generated"]},
		},
		"commands": {"names": {"rtv": "rockthevote"}},
	}}], "game-playground")
	_check(built.ok, "a maps.yml with two rotations and a renamed rtv parses",
		"" if built.ok else built.error.message)
	if not built.ok:
		return

	var kept_file: DotMapRotationFile = game.rotation_file
	game.rotation_file = built.value
	game.apply_rotation()

	var flat := catalogue.get_map(&"pg_flatgrass")
	var gen := catalogue.get_map(&"pg_generated")
	_check(flat.in_rotation and not gen.in_rotation, "the active rotation puts pg_generated out and pg_flatgrass in")
	_check(catalogue.get_map(&"pg_generated") != null and not game.in_rotation(&"pg_generated"),
		"and pg_generated stays installed in the catalogue")
	_check(not catalogue.available().has(gen) and catalogue.available().has(flat), "available() leaves it out")

	var drew_gen := false
	for i in 100:
		var chosen := game.maps.rotation.choose(0)
		if chosen != null and chosen.id == &"pg_generated":
			drew_gen = true
	_check(not drew_gen, "100 draws of the next map never choose a map outside the rotation")
	_check(not game.maps.rotation.set_next(&"pg_generated"), "it cannot be forced as the next map")

	var ids := vote.director.source.choices().map(func(c: DotVoteChoice) -> StringName: return c.id)
	_check(not ids.has(&"pg_generated") and ids.has(&"pg_flatgrass"),
		"a map outside the rotation is not on the ballot, one inside is")
	var nominated := vote.director.nominate(&"u77", &"pg_generated")
	_check(not nominated.ok, "nominate refuses a map outside the rotation")
	_check(not vote.director.nominated_ids().has(&"pg_generated"), "and nothing was recorded")

	var listed := _run_command("pg_map")
	_check(_said(listed, "pg_generated") and _said(listed, "not in rotation"),
		"the map list marks the maps that are not in rotation", str(listed))

	var switched := game.rotation_file.switch(game.maps.rotation, "alt")
	_check(switched.ok and gen.in_rotation and not flat.in_rotation, "switching to the alt rotation takes effect")
	ids = vote.director.source.choices().map(func(c: DotVoteChoice) -> StringName: return c.id)
	_check(not ids.has(&"pg_flatgrass") and ids.has(&"pg_generated"), "and the ballot follows it")
	_check(not game.rotation_file.switch(game.maps.rotation, "nope").ok, "an unknown rotation is refused")

	var rtv := DotVoteCommands.new()
	rtv.director = vote.director
	rtv.spec_fn = game.rotation_commands
	var bound := rtv.bind(server.console)
	_check(bound.ok and rtv.command_name("rtv") == "rockthevote"
		and server.console.find_command("rockthevote") != null,
		"a renamed rtv command is registered from maps.yml's commands")
	var replies := _run_command("rockthevote")
	_check(not replies.is_empty(), "and answers", " ".join(replies))

	# The game's own commands rename from the same block. They bind on a console of their own:
	# the live one already holds the defaults, and the check is that the OLD names are absent.
	var named := DotMapRotationFile.from_trees([{"defaults": {
		"rotations": {"main": {"maps": ["pg_flatgrass"]}},
		"commands": {"names": {
			"pg_rtv": "game_rtv", "pg_map": ["gamemap", "gm"],
			"pg_nextmap": "upnext", "pg_extend": "moretime", "pg_vote": "gamevote"}},
	}}], "game-playground")
	var plain_names: PackedStringArray = game.command_names("pg_rtv")
	game.rotation_file = named.value
	var fresh := DotConsole.new()
	module.bind_map_commands(fresh.command)
	_check(fresh.find_command("game_rtv") != null and fresh.find_command("pg_rtv") == null,
		"a renamed pg_rtv is registered under its new name and not its old one")
	_check(fresh.find_command("gamemap") != null and fresh.find_command("gm") != null
			and fresh.find_command("pg_map") == null, "a role takes a list of names, the first for help")
	_check(fresh.find_command("upnext") != null and fresh.find_command("moretime") != null
			and fresh.find_command("gamevote") != null and fresh.find_command("pg_nextmap") == null
			and fresh.find_command("pg_extend") == null and fresh.find_command("pg_vote") == null,
		"pg_nextmap, pg_extend and pg_vote rename too")
	_check(fresh.find_command("game_rtv").chat_policy == DotConCommand.ChatPolicy.ALLOWED
			and fresh.find_command("gamemap").permission == DotAdminFlags.CHANGEMAP,
		"and keep their chat policy and permission")

	var rocker := DotClientSession.new()
	rocker.peer_id = 4747
	rocker.userid = 47
	rocker.display_name = "Renamer"
	var new_name_replies: Array[String] = []
	var typed_new := rocker.make_context("game_rtv", PackedStringArray(), DotCmdContext.Source.CHAT,
		func(text: String) -> void: new_name_replies.append(text))
	var ran_new := fresh.execute("game_rtv", typed_new)
	_check(not new_name_replies.is_empty() and not _said(PackedStringArray(new_name_replies), "unknown"),
		"the renamed pg_rtv answers from chat", " ".join(new_name_replies))
	var old_name_replies: Array[String] = []
	var typed_old := rocker.make_context("pg_rtv", PackedStringArray(), DotCmdContext.Source.CHAT,
		func(text: String) -> void: old_name_replies.append(text))
	var ran_old := fresh.execute("pg_rtv", typed_old)
	_check(not ran_old.ok and ran_new != null and not _said(PackedStringArray(old_name_replies), "rock"),
		"and the old name no longer does", " ".join(old_name_replies))
	fresh.free()

	game.rotation_file = built.value
	_check(game.command_names("pg_rtv") == PackedStringArray(["pg_rtv"]) and plain_names == PackedStringArray(["pg_rtv"]),
		"a file that does not name them leaves the defaults")

	# No file again: everything back in, as before maps.yml.
	game.rotation_file = null
	game.apply_rotation()
	var all_in := true
	for def in catalogue.maps:
		all_in = all_in and def.in_rotation
	_check(all_in, "with no file every map is in rotation again")
	_check(game.rotation_commands().is_empty(), "and no command is renamed")

	game.rotation_file = kept_file
	game.apply_rotation()
	_section_done()


## What plays next, decided by the players.
func _test_vote() -> void:
	print("")
	print("the vote")

	var vote: PlaygroundVote = _module().get("vote")

	_check(vote != null, "the vote is built")
	_check(
		vote.director != null and vote.director.source != null
			and vote.director.source.is_usable(),
		"with a source over dot-map's own catalogue",
		"one engine, two sources — game-hungario votes over games and this votes over "
		+ "maps, and neither file names the other"
	)

	var options := vote.director.build_options(2)
	_check(options.size() > 0, "a ballot has something on it (%d)" % options.size())

	# Hibernation: both map clocks wait while the server is empty and restart on a join.
	var game_for_clocks: Playground = _module().get("game")
	_check(server.hibernation_changed.is_connected(vote.director.set_hibernating)
		and game_for_clocks != null and server.hibernation_changed.is_connected(game_for_clocks.maps.set_hibernating),
		"the vote's clock and the map's follow the server's hibernation")

	var next := vote.next_in_rotation()
	_check(next != &"", "something is next in the rotation (%s)" % String(next))
	_check(
		game.maps.current == null or next != game.maps.current.id,
		"and it is not the map that is playing"
	)

	# Rocking the vote at the start of the map, inside `rtv_delay_sec`, so this is refused — which is the check: a refusal that
	# ARRIVES is a rule that ran, and dot-vote shipped a version where rocking the vote
	# was refused for ever on the deployment that depends on it.
	var rocked := vote.director.rock_the_vote(&"u1")
	_check(
		rocked != null,
		"rocking the vote answers rather than doing nothing",
		str(rocked.error) if not rocked.ok else "accepted"
	)

	_check(
		not vote.director.begin_on_apply,
		"the director does not announce its own change",
		"the host announces it, which also fires for an operator typing pg_map — both "
		+ "firing halves every cooldown"
	)

	_check(
		vote.director.rules.nomination_seconding,
		"seconding is allowed, which is what makes MOST_NOMINATED mean anything",
		"without it every nomination count is exactly 1 and there is nothing to sort by"
	)

	# Once. It self-advanced AND the module advanced it every tick, so every clock in the
	# vote ran at twice the speed it said.
	_check(
		not vote.director.self_advance and not vote.director.is_physics_processing(),
		"the vote's clock is advanced once a tick, by the module, and not also by itself"
	)

	# dot-vote's commands, none of which existed here.
	var absent := PackedStringArray()
	for name in [
		"rtv", "unrtv", "nominate", "vote", "timeleft", "nextmap",
		"setnextmap", "nominate_addmap", "forcertv", "votereload",
	]:
		if server.console.find_command(name) == null:
			absent.append(name)
	_check(absent.is_empty(), "dot-vote's commands are on the console", ", ".join(absent))

	# One rock-the-vote. `pg_rtv` went to the map session's tally while the wire's `rtv`
	# went to the ballot. What the ballot says to this player is asked first — a refusal,
	# so asking changes nothing — and both commands must say exactly that, and leave the
	# session's tally where it was.
	var session := DotClientSession.new()
	session.peer_id = 4343
	session.userid = 43
	session.display_name = "Rocker"
	var _adopted := server.adopt_session(session)
	var expected := vote.director.rock_the_vote(&"u43")
	var tally_before := game.maps.time_limit.rtv_votes()
	for line in ["rtv", "pg_rtv"]:
		var replies: Array[String] = []
		var ctx := session.make_context(
			line, PackedStringArray(), DotCmdContext.Source.CHAT,
			func(text: String) -> void: replies.append(text)
		)
		server.console.execute(line, ctx)
		_check(
			not expected.ok and replies.size() == 1
				and replies[0].begins_with(expected.error.message),
			"`%s` is the ballot's rock-the-vote (%s)" % [line, str(replies)]
		)
	_check(
		game.maps.time_limit.rtv_votes() == tally_before,
		"and neither touches the map session's tally"
	)

	# Who the vote treats as an admin — the wire's `extend`, an instant rtv, the
	# nomination bypasses. It was `is_admin()`, which is "holds any flag at all", so a
	# reserved slot was enough to extend the map from the client.
	session.permissions = PackedStringArray(["reservation", "chat"])
	var slot_only: bool = _module().call("_voter_is_admin", &"u43")
	session.permissions = PackedStringArray(["changemap"])
	var changer: bool = _module().call("_voter_is_admin", &"u43")
	session.permissions = PackedStringArray()
	_check(not slot_only and changer,
		"a reserved slot is not a vote admin, and changemap is",
		"slot %s, changemap %s" % [slot_only, changer])
	var _released := server.release_session(session.peer_id)

	_check(
		not game.rotation_ends_maps,
		"and the map session's own clock no longer ends a map the vote may have extended"
	)

	# What the module forwards to every client as a VOTE event, heard at the vote's edge.
	var heard: Array = []
	var probe := func(cue: StringName, seconds_left: int, _runoff: bool) -> void:
		heard.append([String(cue), seconds_left])
	vote.cue_due.connect(probe)
	var was_min := vote.director.rules.min_players_to_vote
	vote.director.rules.min_players_to_vote = 0
	var opened := vote.director.open_vote(DotVoteClock.REASON_MANUAL)
	vote.director.rules.min_players_to_vote = was_min
	if opened.ok:
		vote.director.close_vote()
	vote.cue_due.disconnect(probe)
	_check(
		heard.has([String(PlaygroundVote.CUE_START), 0]) and heard.has([String(PlaygroundVote.CUE_END), 0]),
		"a ballot's start and end cues are handed on for the wire (%s)" % str(heard),
		"" if opened.ok else opened.error.message
	)

	_test_status_clock(vote)
	_section_done()


## dot-moderation's live tools, as an operator types them.
##
## The course is timed, so the timer's rule is the one asserted first: noclip abandons a
## run and taints any run begun under it. Then the arena's half — god and slay mean
## something only while `pg_arena` is on, and say so when it is off.
func _test_live_tools() -> void:
	print("")
	print("the moderator's live tools")

	_check(
		server.console.find_command("noclip") != null and server.console.find_command("slay") != null,
		"the live tools' commands are on the console"
	)

	var player := game.add_player(&"u77", "Pat")
	var session := DotClientSession.new()
	session.peer_id = 7707
	session.userid = 77
	session.display_name = "Pat"
	var _adopted := server.adopt_session(session)

	# The course-run halves need a run timer, and are counted only with one (TIMER_CHECKS).
	var timed := player.timer != null
	var stopped: Array[StringName] = []
	var on_stop := func(_r: Object, why: StringName) -> void: stopped.append(why)
	if timed:
		player.timer.get("run_stopped").connect(on_stop)
		player.timer.get("run").call("begin", 0.0)

	var _on := await _run_command_later("noclip Pat")
	_check(DotFpsAdminModifiers.is_noclipped(player.controller), "`noclip Pat` puts them in noclip")
	if timed:
		_check(stopped.has(&"noclip") and not player.timer.get("run").call("is_active"),
			"and abandons the course run they were on", str(stopped))
		player.timer.get("run").call("begin", 0.0)
		player._on_simulated(0, player.controller.state)
		_check(player.timer.get("run").get("tainted"), "a run begun while noclipped is marked assisted")
	var _off := await _run_command_later("noclip Pat off")

	if timed:
		# A slap is a shove in a direction the slapper knows: speed nobody earned.
		#
		# Out of the start zone first: standing in it ends a live run (REASON_RESET). Up in the air is in no zone.
		# Then let the timer see the move, or a run begun earlier is replaced when it is processed.
		player.teleport(Vector3(0.0, 400.0, 0.0))
		for _i in 4:
			await get_tree().physics_frame
		if not player.timer.get("run").call("is_active"):
			player.timer.get("run").call("begin", 0.0)
		var clean_before_slap: bool = not player.timer.get("run").get("tainted")
		var _slapped := await _run_command_later("slap Pat")
		# Two checks, not one `and`: when it was one, a failure could not say whether the run
		# was already tainted before the slap or the slap failed to taint it.
		_check(clean_before_slap, "a run begun after noclip is turned off starts clean")
		_check(player.timer.get("run").get("tainted"),
			"a slap taints the course run it lands in, so it is not a boost with a time at the end")

		player.timer.get("run_stopped").disconnect(on_stop)
		player.timer.call("stop")

	var arena: PlaygroundArena = _module().get("arena")
	var was_on := arena.enabled
	_run_command("pg_arena off")
	var no_arena := await _run_command_later("god Pat")
	_check(_said(no_arena, "arena is off"), "`god` with the arena off says why it means nothing",
		" | ".join(no_arena))

	_run_command("pg_arena on")
	arena.admit(&"u77", "Pat")
	var health := arena.health_of(&"u77")
	var _god := await _run_command_later("god Pat")
	_check(health != null and health.invulnerable, "with it on, `god Pat` makes them invulnerable")
	var slain := await _run_command_later("slay Pat")
	_check(health != null and not health.alive, "and `slay Pat` kills them through it",
		" | ".join(slain))

	var given := await _run_command_later("give Pat rifle")
	_check(_said(given, "physics gun"), "`give` says what a player holds here instead",
		" | ".join(given))

	# `return` after a map change. Moved once by a moderator, so `return` has somewhere to
	# put them — a position on THIS map, which the change is about to free. Then the map
	# changes and `return` must have nowhere to put them, rather than a point on a map that
	# is gone (armed 2026-09-25: without the clear it returned Pat to the old map's spot).
	var tools: DotModTools = _module().get("mod_tools")
	var here := player.global_position
	var _moved: DotResult = await tools.teleport(&"", &"77", here + Vector3(6.0, 0.0, 0.0))
	_check(tools.can_return(&"77"),
		"a moderator moves Pat, so `return` has somewhere to put them")

	var was_map := game.maps.current.id
	var other := &"pg_generated" if was_map != &"pg_generated" else &"pg_flatgrass"
	_run_command("map %s" % other)
	for _i in range(10):
		await get_tree().process_frame

	var returned: DotResult = await tools.return_player(&"", &"77")
	_check(
		game.maps.current.id == other and not tools.can_return(&"77") and not returned.ok,
		"and after a map change `return` has nowhere to put them",
		"map %s; it put them at %s, a spot on the previous map"
			% [game.maps.current.id, str(returned.value) if returned.ok else "-"]
	)

	_run_command("map %s" % was_map)
	for _i in range(10):
		await get_tree().process_frame
	_check(game.maps.current.id == was_map, "and the map goes back for the sections after this",
		String(game.maps.current.id))

	_run_command("pg_arena %s" % ("on" if was_on else "off"))
	var _released := server.release_session(session.peer_id)
	game.remove_player(&"u77")
	_section_done()


## [b]A seat behind its loading cover is not harmed, and is once the cover lifts.[/b] A real
## [DotClientLink] joins over the server's ENet socket and says nothing, as a client still
## loading its level does. The server's one damage choke point (the arena's `hurt`, which a
## weapon, an NPC shot and lava all end at) must refuse it; an operator's hit still lands. The
## client then sends `game.cover` on the real wire and the same hit lands.
func _test_loading_cover() -> void:
	print("")
	print("a client behind its loading cover is not harmed")

	var arena: PlaygroundArena = _module().get("arena")
	var roster: DotGameRoster = _module().get("loading")
	var was_on := arena.enabled
	arena.enabled = true

	var known: Dictionary = {}
	for each in server.playing_sessions():
		known[each.userid] = true

	var side := Node.new()
	side.name = "CoverClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	# Under a node named like this suite's own, so the RPC path the server sends
	# ("Dedicated/Server") resolves in the client's separate multiplayer tree too.
	var mirror := Node.new()
	mirror.name = name
	side.add_child(mirror)
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Cover"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % server.config.port
	mirror.add_child(link)
	link.connect_to_server("127.0.0.1:%d" % server.config.port)

	var seat: Array = [null]
	for _i in 1800:
		await get_tree().physics_frame
		for each in server.playing_sessions():
			if not known.has(each.userid) and game.players.has(StringName("u%d" % each.userid)):
				seat[0] = each
		if seat[0] != null:
			break

	_check(seat[0] != null, "a real client joins over the socket", str(link.last_error))

	if seat[0] == null:
		side.queue_free()
		arena.enabled = was_on
		_section_done()
		return

	var userid: int = seat[0].userid
	var key := StringName("u%d" % userid)
	var health := arena.health_of(key)
	health.invulnerable_until_tick = -1
	_check(roster != null and roster.is_loading(userid),
		"the server holds the seat as loading from its spawn",
		str(roster.describe()) if roster != null else "no roster")

	var before := health.health
	var lava: bool = game.hazard_hurt.call(key, 10.0)
	var shot := arena.hurt(&"", key, 10.0, 0.0)
	_check(lava and health.health == before and shot != null and shot.refused,
		"lava and a shot both do nothing to it", "%s -> %s" % [before, health.health])

	var _slap := arena.hurt(&"", key, 10.0, 0.0, DotHitGroup.CHEST, true)
	_check(health.health < before, "an operator's hit still lands", "%s -> %s" % [before, health.health])

	DotGameClient.report_cover(link, false)
	var lifted := false
	for _i in 900:
		await get_tree().physics_frame
		if not roster.is_loading(userid):
			lifted = true
			break
	_check(lifted, "its cover report crosses the wire and ends the loading state")

	var after_lift := health.health
	var _late := arena.hurt(&"", key, 10.0, 0.0)
	_check(health.health < after_lift, "and the same hit now lands", "%s -> %s" % [after_lift, health.health])

	_check(not roster.is_loading(99999) and not bool(arena.loading_fn.call(&"u99999")),
		"a seat the roster does not hold is always harmable")

	link.disconnect_from_server("done")
	var gone := false
	for _i in 900:
		await get_tree().physics_frame
		if not game.players.has(key):
			gone = true
			break
	_check(gone and not roster.is_loading(userid), "it leaves and the roster forgets it")
	side.queue_free()
	arena.enabled = was_on
	_section_done()


## [b]A record belongs to the account, not to the connection.[/b] dot-server's userid is a
## server-local counter: the same account reconnecting is a new number, and a restarted
## server hands the old numbers to strangers. Timer records were keyed by `u<userid>`, so a
## returning runner was a second row with no Best, and a new player could inherit an old
## runner's time. Armed by making `_record_key_for` return `&""` (the key falls back to
## `u<userid>`): both halves fail.
func _test_records_follow_the_account() -> void:
	print("records follow the account, not the connection")

	var map_id: StringName = game.maps.current.id
	var manager: Object = game.run_timer.get("manager")
	var store: Object = manager.get("store")

	# No socket stands behind these peers: swallow what the bridge would send them.
	var bridge: PlaygroundNetBridge = _module().get("bridge")
	var kept_send: Callable = bridge.net.send_fn
	bridge.net.send_fn = func(_peer: int, _payload: PackedByteArray, _delivery: int) -> void: pass

	var join := func(peer: int, userid: int, uid: String, label: String) -> DotClientSession:
		var session := DotClientSession.new()
		session.peer_id = peer
		session.userid = userid
		session.display_name = label
		var who := DotGuestIdentity.new()
		who.uid = uid
		session.identity = who
		var _adopted := server.adopt_session(session)
		var _spawned: DotEvent = server.events.fire("client_spawn", {"userid": userid})
		return session

	var leave := func(session: DotClientSession) -> void:
		server.client_disconnected.emit(session, "test")
		var _released := server.release_session(session.peer_id)

	var settle := func() -> void:
		for _i in range(8):
			await get_tree().physics_frame

	# Alice connects, finishes a run, goes.
	var first: DotClientSession = join.call(9201, 8801, "acct:alice", "Alice")
	var player: Variant = game.players.get(&"u8801")
	_check(player != null, "an account connects as u<userid> in the match", str(game.players.keys()))
	if player == null:
		_section_done()
		return
	_check(game.record_key(&"u8801") == &"acct:alice", "and is filed under its account uid, not the userid")
	_check(player.timer == manager.call("timer_for", &"acct:alice"), "the timer manager knows it by the account")

	var run: Object = load("res://addons/dot_timer/core/dot_timer_run.gd").call(
		"make", player.timer.get("track"), player.timer.get("run").get("style_id"), 0.01)
	run.call("begin", 0.0)
	for _i in range(6000):
		run.call("advance", 1.0)
	run.call("finish", 0.0)
	for stage in range(1, int(manager.call("stage_count", run.get("track"))) + 1):
		run.get("splits")[stage] = float(stage)
	var why: Array = []
	game.run_filed.connect(func(_id: StringName, _time: float, _rank: int, reason: String) -> void: why.append(reason))
	player.timer.get("run_finished").emit(run)
	await settle.call()
	var mine: DotResult = await store.best_for(map_id, 0, &"normal", &"acct:alice")
	_check(mine.ok and mine.value != null, "the finish is on the board under the account", str(why))
	var by_number: DotResult = await store.best_for(map_id, 0, &"normal", &"u8801")
	_check(by_number.ok and by_number.value == null, "and nothing is filed under the userid")

	leave.call(first)
	await settle.call()
	_check(not game.players.has(&"u8801"), "the player leaves")

	# Alice reconnects: a new userid, the same account.
	var again: DotClientSession = join.call(9202, 8802, "acct:alice", "Alice")
	await settle.call()
	_check(game.players.has(&"u8802") and game.record_key(&"u8802") == &"acct:alice",
		"the reconnect is a new userid on the same account")
	var best: DotResult = await store.best_for(map_id, 0, &"normal", game.record_key(&"u8802"))
	_check(best.ok and best.value != null and float(best.value.get("time")) > 0.0,
		"and keeps the Best it had")
	var rows: DotResult = await store.top(map_id, 0, &"normal", 20)
	_check(rows.ok and (rows.value as Array).size() == 1, "the records board has one row for the account",
		str((rows.value as Array).size()) if rows.ok else str(rows.error))
	var fastest: DotResult = await game.boards.page_async(&"fastest", {
		"map": String(map_id), "track": str(0), "style": "normal",
	})
	var entries: Array = fastest.value if fastest.ok and fastest.value is Array else []
	_check(fastest.ok and entries.size() == 1 and (entries[0] as DotLeaderboardEntry).player_id == &"acct:alice",
		"and so does the leaderboard", str(fastest.value) if fastest.ok else str(fastest.error))

	# The server restarts: userids start again, and the number Alice had goes to a stranger.
	leave.call(again)
	await settle.call()
	var stranger: DotClientSession = join.call(9203, 8801, "acct:bob", "Bob")
	await settle.call()
	var none: DotResult = await store.best_for(map_id, 0, &"normal", game.record_key(&"u8801"))
	_check(none.ok and none.value == null, "a stranger who draws an earlier userid has no record")
	leave.call(stranger)
	await settle.call()

	# A second connection of an account already playing has no records of its own.
	var one: DotClientSession = join.call(9204, 8803, "acct:carol", "Carol")
	var two: DotClientSession = join.call(9205, 8804, "acct:carol", "Carol")
	_check(game.record_key(&"u8803") == &"acct:carol" and game.record_key(&"u8804") == &"u8804"
		and Playground.is_legacy_key(game.record_key(&"u8804")),
		"a duplicate concurrent account keeps its session number, which is never ranked")
	leave.call(two)
	leave.call(one)
	await settle.call()

	# Rows written before the change are retired, not ranked and not deleted.
	var old: Object = load("res://addons/dot_timer/core/dot_timer_record.gd").new()
	old.set("map_id", map_id)
	old.set("track", 0)
	old.set("style_id", &"normal")
	old.set("player_id", &"u12")
	old.set("player_name", "Old")
	old.set("time", 31.0)
	var _put: DotResult = await store.put(old)
	_check(Playground.is_legacy_key(&"u12") and not Playground.is_legacy_key(&"acct:alice")
		and not Playground.is_legacy_key(&"local") and not Playground.is_legacy_key(&"user"),
		"a session-number key is recognised by its shape and an account's is not")
	var moved: int = await game.run_timer.call("retire_legacy_records")
	var after: DotResult = await store.top(map_id, 0, &"normal", 20)
	var left_ids: Array = []
	for row in (after.value as Array):
		left_ids.append(row.get("player_id"))
	_check(moved == 1 and not left_ids.has(&"u12") and left_ids.has(&"acct:alice"),
		"a u<N> row leaves the board and the account's stays", str(left_ids))
	var base: String = game.config.records_directory.strip_edges()
	var archive := (base if base != "" else "user://").path_join("legacy_records.jsonl")
	_check(FileAccess.file_exists(archive) and FileAccess.get_file_as_string(archive).contains("\"u12\""),
		"and is kept in legacy_records.jsonl, not deleted", archive)
	_check(await game.run_timer.call("retire_legacy_records") == 0, "and retiring is idempotent")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(archive))
	bridge.net.send_fn = kept_send
	_section_done()
