extends DotModule
## The module's preloads, state and the chat, vote and map commands.


const PlaygroundConfig := preload("playground_config.gd")
const PlaygroundPaths := preload("playground_paths.gd")
const PlaygroundMapConfig := preload("playground_map_config.gd")
const PlaygroundAmbience := preload("playground_ambience.gd")
## The workbench kind of the ambience cvar set.
const AMBIENT_KIND := "ambience"

const Playground := preload("playground.gd")
const PlaygroundProfiles := preload("playground_profiles.gd")
const PlaygroundArena := preload("playground_arena.gd")
const PlaygroundDowns := preload("playground_downs.gd")
const PlaygroundModTools := preload("playground_mod_tools.gd")
const PlaygroundMapEdit := preload("playground_map_edit.gd")
const PlaygroundLimits := preload("playground_limits.gd")
const PlaygroundPickup := preload("playground_pickup.gd")
const PlaygroundBuilds := preload("playground_builds.gd")
const PlaygroundNetBridge := preload("net/playground_net_bridge.gd")
const PlaygroundPlatform := preload("playground_platform.gd")
const PlaygroundAvatars := preload("playground_avatars.gd")
const PlaygroundPlayer := preload("playground_player.gd")
const PlaygroundProgress := preload("playground_progress.gd")
const PlaygroundServices := preload("playground_services.gd")
const PlaygroundShop := preload("playground_shop.gd")
const PlaygroundSpectate := preload("playground_spectate.gd")
const PlaygroundVote := preload("playground_vote.gd")
const PlaygroundWaves := preload("playground_waves.gd")

const CHANNEL := "playground.module"

## The drawn map ballot's notice topic. The client shell draws one menu per topic, and a
## server running several games sends its own `game_ballot` beside this one.
const MAP_BALLOT_TOPIC := &"map_ballot"

var game: Playground = null

## The netcode, and the seam that joins it to the game. Built here because a module is
## what a dedicated server loads and unloads, so the netcode goes away with the game
## rather than outliving it.
var net: DotNetManager = null
## Carries admins' profile edits up and the edited values down. Null if the types would not register.
var profile_link: DotNetProfileLink = null
## The admin web page and API over the same profiles; closed unless `workbench.enabled` in cfg/server.yml.
var workbench: DotGameWorkbench = null
## dot-team's block rules (`!block`, `!noblock`); null when dot-team is not in the build.
var noblock: DotGameNoblock = null
var bridge: PlaygroundNetBridge = null

## Chat, moderation and voice. Built here rather than in the game, because they are about
## the people connected rather than about the world.
var services: PlaygroundServices = null

## Where the services write punishments, unless a host says otherwise before this loads.
## Static because dot-server constructs the module from a path, so a host has no instance to set.
static var punishments_path: String = PlaygroundServices.PUNISHMENTS_PATH

## Health, weapons that hurt, and a round. Off unless an operator turns it on.
var arena: PlaygroundArena = null

## dot-moderation's live tools, with this game's verbs (`PlaygroundModTools`), and their
## commands. Built in the module rather than the services layer because health lives in
## the arena layer, which is the module's.
var mod_tools: DotModTools = null
var mod_commands: DotModToolCommands = null
## The admin map-edit commands (`spawn_add`, `nav_link_add`, `mapdata_save` ...), which the spawn-point tool also drives. Null without dot-spawn.
var map_edit: DotGameMapEdit = null

## NPCs the server releases, paced by a director. Also off by default.
var waves: PlaygroundWaves = null

## A price list over the spawn menu, when an operator has turned one on. `pg_shop`.
var shop: PlaygroundShop = null

## Watching somebody else build, fight, or drive into a wall.
var spectate: PlaygroundSpectate = null

## Down rather than dead, while the waves are on. The co-operative half.
var downs: PlaygroundDowns = null

## Per-player statistics, and what they are worth.
var progress: PlaygroundProgress = null

## Only asked for keys: progress opens its own tracker sessions.
var _stats_feed: DotGameStatsFeed = _new_stats_feed()

## What plays next, decided by the players.
var vote: PlaygroundVote = null

## Which userids have already been given a player, so a re-fired spawn does not add a
## second one.
var _joined: Dictionary = {}

var _tick: int = 0

## Who last said something. What `pg_status` reports, off the accepted line.
var _last_spoke: String = ""


func _module_name() -> String:
	return "playground"


## A [DotQueryProvider] over this module. An inner class because it is one method and a
## reference, which is game-arena's pattern for the same thing.
class PlaygroundQueryProvider extends DotQueryProvider:
	## Held as an [Object]: this script has no [code]class_name[/code] and an inner class
	## cannot name the outer script it lives in.
	var module: Object = null

	func _provider_name() -> String:
		return "playground"

	func _contribute(snapshot: DotQuerySnapshot) -> void:
		if module == null or module.game == null:
			return

		var game: Playground = module.game
		var values := {
			"map": String(game.maps.current.id) if game.maps != null
				and game.maps.current != null else "",
			"map_name": game.maps.current.display_name if game.maps != null
				and game.maps.current != null else "",
			"players": module._joined.size(),
			"props": game.props.world_count() if game.props != null else 0,
			"tick_rate": game.tick_rate,
			# The three that decide what kind of server this is.
			"arena": module.arena != null and module.arena.enabled,
			"waves": module.waves != null and module.waves.is_enabled(),
			"shop": module.shop != null and module.shop.enabled,
		}

		if module.waves != null and module.waves.is_enabled():
			values["npcs"] = module.waves.count()

		for key: String in values:
			snapshot.game[key] = values[key]


## The running map's per-map cvars (dot-game's [DotGameMapConfig]); the previous map's values return on each change and on unload.
var map_config: DotGameMapConfig = null


## Who is still behind their loading cover, from dot-game's roster used for that alone (this module is
## not on DotGameModule). Loading runs from the spawn event until the cover lifts, again per map change.
## The arena asks it by player key (`u<userid>`); a bot is never seated, so never loading.
var loading: DotGameRoster = null
var _handles_cover: bool = false


## The identity layer this module built, or null when it found one already running.
var _identity: DotPlatformIdentity = null
var _loaded_platform := false


var _board_feed: DotGameStatsFeed = null


## Somebody said something through dot-server's own chat path. Cancelled, not watched, so [DotChatRouter]'s rules are the only path.
func _on_player_chat(event: DotEvent) -> void:
	event.cancel("routed by the sandbox's chat", _module_name())

	var session := event.get_session()

	if session == null or services == null or services.chat == null:
		return

	_on_say_requested(
		session.peer_id, PlaygroundServices.CHANNEL_ALL, event.get_string("text")
	)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.chat.submit(peer_id, channel_id, text)

	if not said.ok and said.error != null:
		# Back to the sender and nowhere else: dot-chat is deliberate that a rate-limited
		# or gagged player must not be able to measure the difference from outside.
		services.chat.notice(peer_id, said.error.message, channel_id)


func _on_voice_requested(peer_id: int, payload: PackedByteArray) -> void:
	services.voice.relay(peer_id, payload)


func _on_chat_accepted(message: DotChatMessage, _to: PackedInt32Array) -> void:
	if message.sender_peer > 0:
		_last_spoke = message.sender_name


## An unclaimed `!command` from chat, routed into dot-server's own console with the player's permissions.
## Not a second command table: dot-server already decides, audits and answers.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	var session := server.session_of(peer_id)

	if session == null:
		return

	if server.console.find_command(command) == null:
		DotLog.debug(CHANNEL, "an unknown chat command was ignored", {
			"peer": peer_id, "command": command,
		})
		return

	var ctx := session.make_context(
		command,
		args,
		DotCmdContext.Source.CHAT,
		func(line: String) -> void:
			services.chat.notice(peer_id, line, PlaygroundServices.CHANNEL_ALL)
	)

	var line := command

	for arg in args:
		line += " " + arg

	server.console.execute(line, ctx)


func _on_vote_requested(peer_id: int, token: String) -> void:
	var session_id := bridge.player_for_peer(peer_id)

	if session_id == 0:
		return

	var result := vote.submit(StringName("u%d" % session_id), token)

	if not result.ok and services != null:
		services.chat.notice(
			peer_id, result.error.message, PlaygroundServices.CHANNEL_ALL
		)


func _voter_is_admin(voter: StringName) -> bool:
	var text := String(voter)

	if not text.begins_with("u"):
		return false

	var session := server.session_by_userid(text.substr(1).to_int())
	# CHANGEMAP, not any flag: `is_admin()` is "holds a flag at all", which a reserved slot
	# or admin chat satisfies, and this gates extending the map, an instant rtv and the
	# nomination bypasses. The console's own extend asks for CHANGEMAP; the wire must too.
	return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)


func _on_vote_announced(line: String) -> void:
	if services != null and services.chat != null:
		services.chat.announce(line, PlaygroundServices.CHANNEL_ALL)


## The vote picked a map. The game is what changes to it.
func _on_vote_change_due(map_id: StringName) -> void:
	game.change_map(map_id)


func _on_loadout_requested(peer_id: int, pairs: Array) -> void:
	var session_id := bridge.player_for_peer(peer_id)

	if session_id == 0 or arena == null or arena.loadouts == null:
		return

	var loadout := DotLoadout.new()

	for pair in pairs:
		var row: Array = pair
		loadout.set_item(StringName(str(row[0])), StringName(str(row[1])))

	# Validated on the way in, conformed on the way out: a client must not make the server repair its way to a legal loadout, while `conform_on_load` keeps a player whose weapon changed able to spawn.
	# Awaited (this handler is a coroutine): a publish must not report success before the store write returned.
	var published: DotResult = await arena.loadouts.publish(
		loadout_key(session_id), loadout, 0
	)

	if not published.ok and services != null:
		services.chat.notice(
			peer_id, published.error.message, PlaygroundServices.CHANNEL_ALL
		)


func _on_health_changed(
	player_id: StringName, health: float, armour: float, by: StringName
) -> void:
	bridge.broadcast_combat(
		_session_of(player_id), int(health), int(armour), _session_of(by), false
	)


func _on_player_killed(victim: StringName, killer: StringName) -> void:
	var fallen: PlaygroundPlayer = game.players.get(victim, null)
	bridge.broadcast_combat(
		_session_of(victim), 0, 0, _session_of(killer), true,
		fallen.death if fallen != null else null
	)

	if progress != null:
		progress.note(victim, &"deaths", 1.0)

		if killer != &"" and killer != victim:
			progress.note(killer, &"kills", 1.0)
			progress.report_kill(killer, victim)


func _on_earned(player_key: String, id: StringName, title: String, points: int) -> void:
	# The session the key belongs to, so a client can colour the line. Linear over at most
	# a few dozen players, a few times a session.
	for userid in _joined.keys():
		var session := server.session_by_userid(int(userid))

		if session == null:
			continue

		if _stats_key(session) != player_key:
			continue

		bridge.broadcast_progress(session.userid, id, title, points)
		return


## The key a statistic is filed under: a world player id's stable per-server stats key, never an account id.
func _stats_key_for(player_id: StringName) -> String:
	var text := String(player_id)

	if not text.begins_with("u"):
		return text

	var session := server.session_by_userid(text.substr(1).to_int())

	if session == null:
		return text

	return _stats_key(session)


static func _new_stats_feed() -> DotGameStatsFeed:
	var feed := DotGameStatsFeed.new()
	feed.open_sessions = false
	return feed


## dot-game's stable per-server key (guests too), not the platform key alone.
func _stats_key(session: DotClientSession) -> String:
	return String(_stats_feed.key_for(session))


## Who a session is, for a bag that outlasts the connection, or empty for nobody. The statistics' key
## (a userid is sequential); without an identity stack it is empty so the bag goes with the session.
func _bag_key_for(session_id: int) -> String:
	if server == null:
		return ""
	var session := server.session_by_userid(session_id)
	if session == null:
		return ""
	var key := PlaygroundPlatform.key_for_session(server, session)
	return "" if key == "" or key.begins_with("local:") else "bag:" + key


## Whether this player's admin session holds the configured noclip flag, `cheats` or root. A player with no session (a bot) may not.
func _session_may_noclip(player_id: StringName) -> bool:
	var session := server.session_by_userid(_session_of(player_id)) if server != null else null
	if session == null:
		return false
	var flag := game.config.noclip_flag if game.config != null else DotAdminFlags.NOCLIP
	return session.has_permission(flag) or session.has_permission(DotAdminFlags.CHEATS) \
		or session.has_permission(DotAdminFlags.ROOT)


## Whether this player's admin session holds the map-edit flag (`config`) or root.
func _session_may_edit_map(player_id: StringName) -> bool:
	var session := server.session_by_userid(_session_of(player_id)) if server != null else null
	return PlaygroundMapEdit.session_may_edit(session, map_edit.map_edit_flag if map_edit != null else DotAdminFlags.CONFIG)


## A world player id back to a dot-server session id, or zero.
func _session_of(player_id: StringName) -> int:
	var text := String(player_id)
	return text.substr(1).to_int() if text.begins_with("u") else 0


## The id the game files records under: the session's own scoped id, not a site account, so
## operators cannot correlate players across servers.
func _player_id(session: DotClientSession) -> StringName:
	return StringName("u%d" % session.userid)


## The player a command is about: a named one for an admin, otherwise the caller.
func _target(ctx: DotCmdContext, allow_named: bool = true) -> StringName:
	if allow_named and ctx.args.size() > 0 and ctx.session == null:
		# Only from the server console: letting a player name somebody else would be
		# letting them restart a stranger's run.
		return StringName(ctx.args[0])

	if ctx.session == null:
		return &""

	return _player_id(ctx.session)


func _caller(ctx: DotCmdContext) -> PlaygroundPlayer:
	var id := _target(ctx, false)

	if id == &"":
		return null

	var found: Variant = game.players.get(id)
	return found if found is PlaygroundPlayer else null


func _cmd_restart(ctx: DotCmdContext) -> void:
	var id := _target(ctx)

	if not game.players.has(id):
		ctx.reply("You are not in the game.")
		return

	game.spawn_player(id)
	ctx.reply("Back at the start.")


func _cmd_style(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var lines := PackedStringArray(["Styles:"])

		for style_id in game.style_order:
			var style: DotFpsStyle = game.movement_styles[style_id]
			lines.append("  %-16s %s" % [String(style.id), style.display_name])

		ctx.reply_lines(lines)
		return

	var id := _target(ctx, false)

	if id == &"" or not game.players.has(id):
		ctx.reply("Only a player can switch style.")
		return

	var wanted := StringName(ctx.args[0])

	if not game.set_player_style(id, wanted):
		ctx.reply("No such style: %s" % ctx.args[0])
		return

	ctx.reply("Style: %s" % String(wanted))


func _cmd_map(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var lines := PackedStringArray(["Maps:"])

		for map in game.maps.catalogue.maps:
			lines.append("  %-24s tier %d  %s%s%s" % [
				String(map.id), map.tier, String(map.kind),
				"" if map.enabled else "  (disabled)",
				"" if map.in_rotation else "  (not in rotation)",
			])

		ctx.reply_lines(lines)
		return

	var found := game.maps.catalogue.search(ctx.args[0])

	if found.is_empty():
		ctx.reply("No map matches '%s'." % ctx.args[0])
		return

	if found.size() > 1:
		var names := PackedStringArray()
		for map in found:
			names.append(String(map.id))
		ctx.reply("Which one? %s" % ", ".join(names))
		return

	ctx.reply("Changing to %s." % found[0].name_or_id())

	var changed: DotResult = await game.change_map(found[0].id)

	if not changed.ok:
		ctx.reply_error(changed)


func _cmd_nextmap(ctx: DotCmdContext) -> void:
	# With a ballot, the ballot's answer: its clock, its rock-the-vote and what it would
	# play. The map session's are the ones that decide nothing then.
	if vote != null and vote.director != null:
		var director := vote.director
		var pending := director.pending_id()
		ctx.reply("Next: %s   ·   %s   ·   %d rocked the vote (%d needed)" % [
			String(pending) if pending != &"" else String(director.next_in_rotation()),
			director.clock.timeleft_line(),
			director.clock.rtv_votes(),
			director.clock.rtv_needed(director.player_count()),
		])
		return

	var next := game.maps.rotation.choose(game.players.size())

	ctx.reply("Next: %s   ·   %s left   ·   %d rocked the vote (%d needed)" % [
		next.name_or_id() if next != null else "-",
		game.maps.time_limit.formatted_remaining(),
		game.maps.time_limit.rtv_votes(),
		game.maps.time_limit.rtv_needed(game.players.size()),
	])


## The game's own map and vote commands (`pg_map`, `pg_nextmap`, `pg_rtv`, `pg_extend`, `pg_vote`),
## each registered under every name maps.yml's `commands: names:` gives its role. Takes the
## registrar as a Callable so a check can bind them on a console of its own.
func bind_map_commands(register: Callable) -> void:
	var table := [
		["pg_map", _cmd_map, "Change map, or list what there is", DotAdminFlags.CHANGEMAP],
		["pg_nextmap", _cmd_nextmap, "What plays next, and how long is left", ""],
		["pg_rtv", _cmd_rtv, "Rock the vote", ""],
		["pg_extend", _cmd_extend, "Extend the current map", DotAdminFlags.CHANGEMAP],
	]

	for row: Array in table:
		for name in game.command_names(row[0]):
			var cmd: Variant = register.call(name, row[1], row[2], row[3])
			if cmd != null:
				cmd.with_chat()

	# Not chat-typable by default: it is the operator's (CHANGEMAP), as it always was.
	for name in game.command_names("pg_vote"):
		var _cmd: Variant = register.call(
			name, _cmd_vote, "pg_vote [open|next|status] — what plays next", DotAdminFlags.CHANGEMAP)


func _cmd_rtv(ctx: DotCmdContext) -> void:
	var id := _target(ctx, false)

	if id == &"":
		ctx.reply("Only a player can rock the vote.")
		return

	# With a ballot, `pg_rtv` is the ballot's rock-the-vote — the one `rtv` and the wire
	# reach. It went to the map session's tally, which on a server with a vote is a vote
	# that decides nothing. The voter id is the ballot's, `u<userid>`.
	if vote != null and vote.director != null:
		var voter := StringName("u%d" % ctx.session.userid) if ctx.session != null else id
		var res := vote.director.rock_the_vote(voter)
		ctx.reply("Rocked the vote." if res.ok else res.error.message)
		return

	if game.maps.time_limit.has_rocked(id):
		# Said rather than silently ignored: nothing visible happening twice is the worst answer.
		ctx.reply("You have already rocked the vote. %d of %d." % [
			game.maps.time_limit.rtv_votes(),
			game.maps.time_limit.rtv_needed(game.players.size()),
		])
		return

	if game.rock_the_vote(id):
		ctx.reply("The vote passed.")
		return

	ctx.reply("%d of %d." % [
		game.maps.time_limit.rtv_votes(),
		game.maps.time_limit.rtv_needed(game.players.size()),
	])


func _cmd_extend(ctx: DotCmdContext) -> void:
	var seconds := -1.0

	if ctx.args.size() > 0 and ctx.args[0].is_valid_float():
		seconds = ctx.args[0].to_float()

	# The ballot's clock is the one that ends a map when there is a ballot.
	if vote != null and vote.director != null:
		var extended := vote.director.extend(seconds)
		ctx.reply(
			("Extended. %s." % vote.director.clock.timeleft_line()) if extended.ok
			else extended.error.message
		)
		return

	if not game.maps.extend_map(seconds):
		ctx.reply("This map has been extended as often as it may be.")
		return

	ctx.reply("Extended. %s left." % game.maps.time_limit.formatted_remaining())


func _cmd_prop(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)

	if player == null:
		ctx.reply("Only a player can spawn props.")
		return

	if ctx.args.is_empty():
		# Grouped by the spawn menu's own categories: a delivered catalogue is four hundred ids.
		for category in game.props.catalogue.categories():
			var names := PackedStringArray()

			for prop in game.props.catalogue.in_category(StringName(category)):
				names.append(String(prop.id))

			ctx.reply("%s: %s" % [category.capitalize(), ", ".join(names)])

		return

	var found := game.props.catalogue.search(ctx.args[0])

	if found.is_empty():
		ctx.reply("No prop matches '%s'." % ctx.args[0])
		return

	var at := player.eye_position() + player.aim_direction() * 3.0
	var spawned := game.props.spawn(found[0].id, player.player_id, at)

	# The refusal reason reaches the player through the spawner's own signal, which
	# the HUD is already listening to — so this says nothing on failure rather than
	# saying it twice.
	if spawned != null:
		ctx.reply("Spawned %s." % found[0].name_or_id())


# Relative to the player both ways: a build is saved around where its builder stands and faces,
# and put down around whoever loads it. Kept under the player's statistics key, so it outlives a
# reconnect wherever there are accounts.

## Where saved builds are kept. The suites point it somewhere of their own.
var builds := PlaygroundBuilds.new()


func _build_key(ctx: DotCmdContext) -> String:
	return PlaygroundPlatform.key_for_session(server, ctx.session) if server != null and ctx.session != null else ""


## The Q menu's Builds tab opened: send this player what they have saved.
func _on_builds_requested(peer_id: int) -> void:
	var session := server.session_of(peer_id) if server != null else null
	if session == null:
		return
	bridge.send_builds(peer_id, builds.summaries(PlaygroundPlatform.key_for_session(server, session)))


## A card on the Builds tab was clicked: the same as `pg_load <name>`, asked over the wire.
func _on_build_load_requested(peer_id: int, build_name: String) -> void:
	var session := server.session_of(peer_id) if server != null else null
	if session == null:
		return
	var found: Variant = game.players.get(StringName("u%d" % session.userid))
	if not (found is PlaygroundPlayer):
		return
	var player: PlaygroundPlayer = found
	var doc := builds.load_build(PlaygroundPlatform.key_for_session(server, session), build_name)
	if not doc.ok:
		bridge.tell_notice(peer_id, doc.error.message)
		return
	var state := player.controller.state
	var placed := builds.place(game, player.player_id, doc.value, state.position, state.yaw)
	if not placed.ok:
		bridge.tell_notice(peer_id, placed.error.message)
		return
	bridge.tell_notice(peer_id, "Put down \"%s\": %d props." % [build_name, int(placed.value)])


func _cmd_save(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)
	if player == null or ctx.args.is_empty():
		ctx.reply("Usage: pg_save <name>, as a player.")
		return
	var state := player.controller.state
	var doc := builds.capture(game, player.player_id, state.position, state.yaw)
	if not doc.ok:
		ctx.reply_error(doc)
		return
	var saved := builds.save(_build_key(ctx), ctx.args[0], doc.value)
	if not saved.ok:
		ctx.reply_error(saved)
		return
	ctx.reply("Saved \"%s\": %d props." % [ctx.args[0], (doc.value["props"] as Array).size()])


func _cmd_load(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)
	if player == null or ctx.args.is_empty():
		ctx.reply("Usage: pg_load <name>, as a player.")
		return
	var doc := builds.load_build(_build_key(ctx), ctx.args[0])
	if not doc.ok:
		ctx.reply_error(doc)
		return
	var state := player.controller.state
	var placed := builds.place(game, player.player_id, doc.value, state.position, state.yaw)
	if not placed.ok:
		ctx.reply_error(placed)
		return
	ctx.reply("Put down \"%s\": %d props." % [ctx.args[0], int(placed.value)])


func _cmd_builds(ctx: DotCmdContext) -> void:
	if ctx.session == null:
		ctx.reply("Only a player has builds.")
		return
	var listed := builds.names(_build_key(ctx))
	ctx.reply("Your builds: %s" % (", ".join(listed) if not listed.is_empty() else "none yet (pg_save <name>)"))


func _cmd_build_delete(ctx: DotCmdContext) -> void:
	if ctx.session == null or ctx.args.is_empty():
		ctx.reply("Usage: pg_build_delete <name>, as a player.")
		return
	var gone := builds.delete(_build_key(ctx), ctx.args[0])
	if not gone.ok:
		ctx.reply_error(gone)
		return
	ctx.reply("Deleted \"%s\"." % ctx.args[0])


func _cmd_undo(ctx: DotCmdContext) -> void:
	var id := _target(ctx, false)

	if id == &"" or not game.undo(id):
		ctx.reply("Nothing to undo.")
		return

	ctx.reply("Removed.")


func _cmd_props_clear(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var count := game.props.clear_all(DotPropSpawner.REASON_ADMIN)
		ctx.reply("Removed %d props." % count)
		return

	var count := game.props.clear_player(
		StringName(ctx.args[0]), DotPropSpawner.REASON_ADMIN
	)
	ctx.reply("Removed %d of %s's props." % [count, ctx.args[0]])


const LOADOUT_COMMAND_SCRIPT := "res://addons/dot_loadout/integrations/dot_loadout_command.gd"

## The B menu's server half (dot-loadout's `DotLoadoutCommand` over the arena's manager), or
## null on a host whose dot-loadout predates it (API 2).
var loadout_command: Object = null

## `pg_arena_on`: whether the arena is on, REPLICATED so a client's B knows whether there is a
## loadout to open (the lead's call: B opens it only in the arena, and says so outside). Also a
## switch: setting it is `pg_arena on/off`.
var _arena_on: DotConVar = null


## The loadout key of session [param session_id]: dot-loadout keys are at least eight long, so
## the player key ("u7") is not one.
static func loadout_key(session_id: int) -> String:
	return "pg-player-%08d" % session_id


## What B says outside the arena, on both ends.
const LOADOUT_ARENA_ONLY := "Loadouts are in the arena."


func _cmd_vote(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"open":
			var opened := vote.director.open_vote()

			if opened.ok:
				ctx.reply("Vote opened.")
			else:
				ctx.reply_error(opened)
		"next":
			ctx.reply("Next in rotation: %s" % String(vote.next_in_rotation()))
		_:
			ctx.reply_lines(vote.describe_lines())
