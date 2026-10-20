extends Node

const Playground := preload("playground.gd")

## What plays next, decided by the players.
##
## [b]This game already had a rock-the-vote and it was `DotMapTimeLimit`'s, which is half
## of one.[/b] That half is real — it counts a fraction of the players and fires — and what
## it cannot do is offer a ballot, take nominations, break a tie, respect a cooldown, or
## give somebody the option to extend. dot-vote is fifty-five settings over exactly those,
## and the ad-hoc version is now the *time limit* under it rather than the vote itself.
##
## [b]The source is dot-map's catalogue, not dot-server's games.[/b] game-hungario votes
## over games because its modes are games; this one votes over **maps**, and
## `DotVoteMapSource` applies through the [DotMapSession] this game already drives. One
## engine, two sources, and neither this file nor that one names the other — which is the
## whole reason `DotVoteSource` exists.

const CHANNEL := "playground.vote"

## Where a server owner configures this game's map vote. Empty skips the file.
##
## [b][method vote_rules] is this game's DEFAULTS, not its configuration.[/b] They layer
## the way every [DotConfig] in the family does, so an owner changes a number without
## touching code:
##
## [codeblock]
## vote_rules()  <  game.yml metadata: map_vote:  <  this file  <  DOT_VOTE_*  <  --vote-*
## [/codeblock]
##
## The file is JSON, keyed exactly as [DotVoteRules] is, enums by name. The end-of-map
## vote and its extend option, which is what an owner usually wants to change:
##
## [codeblock]
## {
##     "end_vote": true,          "vote_lead_sec": 120,
##     "include_extend": true,    "extend_seconds": 900,    "max_extends": 4
## }
## [/codeblock]
##
## [code]DOT_VOTE_EXTEND_SECONDS=1200[/code] or [code]--vote-include-extend=false[/code]
## do the same for one run. A result that does not validate is refused whole and the
## defaults stand, with the reason in the log.
const CONFIG_PATH := "user://cfg/playground_vote.json"

## The key in the running game's descriptor metadata an operator's overrides are read
## from — [code]metadata: map_vote:[/code] in a delivered game's [code]game.yml[/code].
const METADATA_KEY := "map_vote"

## The vote's sound cues, as ids in [code]PlaygroundPresentation.sound_catalogue()[/code].
## One copy: the rules name them and the catalogue defines them, both from here.
const CUE_START := &"vote_start"
const CUE_END := &"vote_end"
const CUE_WARNING := &"vote_warning"
const CUE_COUNT := &"vote_count"

## What dot-vote's commands are called here. `vote` rather than `votefor`, so the command
## a player types is the token this game's own wire already sends.
const COMMAND_NAMES := {"vote": "vote"}


## The vote picked something. The game is what changes to it.
signal change_due(map_id: StringName)

## Something a player should be told: the ballot, the tally, a warning.
signal announced(line: String)

## Something for every client to hear or count: a [code]cue_*[/code] id, or a second of
## the countdown before a ballot. One of the two is empty or zero. The module puts it on
## the wire as [constant PlaygroundEvents.Kind].VOTE.
signal cue_due(cue: StringName, seconds_left: int, runoff: bool)

## The map's time left changed in a way a client counting it down would not have guessed:
## an extend, a new map, a clock stopped for a ballot or started again. [param state] is
## [method DotVoteClockView.state_of]'s. The module puts it on the wire as
## [constant PlaygroundEvents.Kind].CLOCK.
signal clock_due(state: Dictionary)


var director: DotVoteDirector = null
var commands: DotVoteCommands = null

## `() -> Dictionary`: maps.yml's `commands:` block, so an operator renames the vote's commands
## without this game naming any. The module points it at the game's rotation file.
var commands_spec_fn: Callable = Callable()
var game: Playground = null

## How many people are playing. Every threshold in a vote needs it.
var player_count_fn: Callable = Callable()
var is_admin_fn: Callable = Callable()

## [code]func(state: Dictionary)[/code]: the ballot as a client draws it, sent whenever it
## changes. The host points it at the client shell (a dot-server notice), which draws a
## menu a player picks from with a number key or a click. Unset sends nothing.
var ballot_fn: Callable = Callable()

## [code]func(voter: StringName) -> Dictionary[/code]: a voter's name and avatar URL.
var people_fn: Callable = Callable()

## What [member ballot_fn] is fed from. Polled once per [method advance].
var feed: DotVoteBallotFeed = null

## What every client was last told about the clock, counted down the way they count it.
## See [method advance].
var clock_view: DotVoteClockView = DotVoteClockView.new()

## Simulated seconds, for [member clock_view]. Never compared with a client's clock.
var _clock_time: float = 0.0

## The file [method setup] layers over the defaults. A test sets it empty.
var config_path: String = CONFIG_PATH


## The vote's policy. Fifty-five settings, and these are the ones a sandbox changes.
static func vote_rules() -> DotVoteRules:
	var rules := DotVoteRules.new()
	rules.enabled = true
	rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
	# Forty-five minutes, dot-vote's default and right here: a sandbox map is a place people
	# build in, and a short limit throws away the thing they built. The deployed sandbox
	# runs around the clock instead (`duration_sec: 0` in its game.yml).
	rules.duration_sec = 2700.0
	rules.vote_lead_sec = 150.0
	rules.vote_cooldown_sec = 60.0
	rules.vote_duration_sec = 30.0
	rules.max_options = 5
	rules.include_extend = true
	rules.include_current = false
	rules.method = DotVoteRules.Method.PLURALITY
	rules.tie_break = DotVoteRules.TieBreak.BALLOT_ORDER
	# [b]Off, and this is the setting dot-vote found a bug in.[/b] With it on, "extend" is
	# erased from a tie and the tie goes to the new map; with it off the ordinary tie-break
	# runs — and every pseudo-option sorts last in ballot order, so `BALLOT_ORDER` hands
	# the tie to the new map as well. Two documented policies, one behaviour. Set here so
	# somebody changing it is changing something.
	rules.extend_needs_majority = false
	# A sandbox is exactly the server where extending matters: people are mid-build.
	rules.extend_seconds = 900.0
	rules.max_extends = 4
	rules.rtv_enabled = true
	rules.rtv_fraction = 0.6
	rules.rtv_min_players = 1
	# [b]Measured against elapsed time, which is the other bug dot-vote found.[/b]
	# `DotVoteClock.running` used to mean "has a limit" rather than "has started", so a
	# server with no time limit never accumulated elapsed time and rocking the vote was
	# refused for ever — on exactly the deployment whose only way to change anything is
	# the vote.
	rules.rtv_delay_sec = 180.0
	rules.nominations_enabled = true
	rules.nominations_per_player = 1
	# [b]On, and it is the setting that makes `MOST_NOMINATED` mean anything.[/b] dot-vote
	# refused a second player nominating what somebody had already nominated, so every
	# count was exactly 1 and there was nothing to sort by.
	rules.nomination_seconding = true
	# A ballot filled by what people actually asked for, which is the fill that needs
	# seconding to work at all.
	rules.fill = DotVoteRules.Fill.MOST_NOMINATED
	rules.cooldown = 2
	rules.cooldown_mode = DotVoteRules.Cooldown.PLAYS
	rules.apply = DotVoteRules.Apply.IMMEDIATE
	rules.apply_delay_sec = 5.0
	# The ids PlaygroundPresentation's catalogue plays. dot-vote ships every cue empty.
	rules.cue_vote_start = String(CUE_START)
	rules.cue_vote_end = String(CUE_END)
	rules.cue_warning = String(CUE_WARNING)
	rules.cue_runoff_warning = String(CUE_WARNING)
	rules.cue_countdown = String(CUE_COUNT)
	return rules


func setup(p_game: Playground) -> DotResult:
	game = p_game

	var rules := vote_rules()
	var problem := rules.validate()

	if not problem.ok:
		return problem.wrap("The vote rules are not usable")

	# The owner's layers over the defaults that just validated. A layered result that
	# does not validate is refused whole and the defaults stand — loud, not fatal,
	# because a server that would not start over its vote file is one nobody can fix
	# from a chat window.
	var layered := rules.layer_over_defaults(
		config_path, DotVoteGameSource.running_game_metadata(METADATA_KEY)
	)

	if not layered.ok:
		DotLog.error(CHANNEL, "the map vote configuration is not usable; using the defaults", {
			"path": config_path,
			"why": layered.error.message,
			"detail": layered.error.detail,
		})

	# Nothing in this game reports a round end or a leading score to the vote, so a
	# `trigger: round_end` or a score limit in an operator's file would validate and then
	# wait for ever — and with the map's own clock handed to the vote, the map never ends.
	var unfed := rules.drop_unfed(false, false)
	if not unfed.is_empty():
		DotLog.error(CHANNEL, "the map vote configuration asks for what this game cannot drive; ignored", {
			"path": config_path, "ignored": ", ".join(unfed),
		})

	director = DotVoteDirector.new()
	director.name = "Vote"
	director.rules = rules
	# [b]dot-map's own source, over the session this game already drives.[/b] Nothing here
	# loads a map: `DotVoteMapSource.apply` calls `DotMapSession.change_to`, which is the
	# path that already works — including the cloud fetch for a delivered map.
	director.source = DotVoteMapSource.from_session(game.maps)
	director.auto_apply = false
	# [b]Off, and this is dot-vote's fifth bug.[/b] With it on the director announces the
	# change it just made *and* the host announces the same change through its own map
	# signal — which fires for an operator typing `pg_map` too, and is therefore the one
	# that has to be connected. Both firing is two entries in the play history for one
	# play, and a "played in the last N" cooldown that is quietly half what it says.
	director.begin_on_apply = false
	# [b]Off: the module advances it, once per server tick.[/b] It was on, AND the module
	# called `advance(step)` every tick, so every clock in the vote ran at twice the speed
	# it said — a thirty-minute limit was fifteen, a thirty-second ballot fifteen, and the
	# three-minute rock-the-vote delay ninety seconds. Nothing errored: every number was
	# consistent with itself, and only a clock on the wall disagrees.
	director.self_advance = false
	director.register_service = false
	director.player_count_fn = _player_count
	director.is_admin_fn = _is_admin
	director.announce_fn = func(line: String) -> void: announced.emit(line)
	add_child(director)

	director.change_due.connect(func(id: StringName, _choice: DotVoteChoice) -> void:
		change_due.emit(id)
	)

	# Two signals, two messages: dot-vote emits a countdown second and that second's cue
	# separately, and merging them here would be this file deciding which is which.
	director.cue.connect(func(id: StringName) -> void: cue_due.emit(id, 0, false))
	director.countdown_tick.connect(func(seconds_left: int, runoff: bool) -> void:
		cue_due.emit(&"", seconds_left, runoff)
	)

	feed = DotVoteBallotFeed.of(director, func(state: Dictionary) -> void:
		if ballot_fn.is_valid():
			ballot_fn.call(state)
	)
	feed.title = "Vote for the next map"
	feed.people_fn = func(voter: StringName) -> Dictionary:
		return people_fn.call(voter) if people_fn.is_valid() else {}

	return DotResult.success(null)


## dot-vote's commands, on [param host] — the module, so they go when it does.
##
## [b]The only vote commands, and the one rock-the-vote.[/b] `pg_rtv` went to the map
## session's own `DotMapTimeLimit` while the wire's `rtv` went to this director — two
## votes under one name — and none of dot-vote's commands existed here: no `nominate`
## from chat, no `timeleft`, and none of the operator's `setnextmap`, `nominate_addmap`,
## `forcertv`, `votereload`. A chat `!` line goes to the console in this game, so
## registering them is all it takes. Voters are `u<userid>`, dot-vote's default and the
## id [method submit] is handed off the wire.
func install_commands(host: Object) -> DotResult:
	if director == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no vote to command.")

	commands = DotVoteCommands.new()
	commands.director = director
	commands.names = COMMAND_NAMES
	commands.spec_fn = commands_spec_fn

	var bound := commands.bind(host)

	if feed != null:
		feed.command = commands.command_name("vote")

	return bound


## Somebody is playing something. The vote is told, once, from the one signal that fires
## for every change however it happened.
func note_playing(map_id: StringName) -> void:
	if director != null:
		director.begin(map_id)


func advance(delta: float) -> void:
	if director != null:
		director.advance(delta)

	if feed != null:
		feed.poll()

	_clock_time += delta

	# [b]Sent when a client's own count would be wrong, not every second.[/b] Both ends
	# count with `DotVoteClockView`, so the server knows exactly what every client is
	# showing and only an extend, a new map or a stopped clock is worth a message.
	if clock_view.is_stale(director, _clock_time):
		clock_view.adopt(clock_state(), _clock_time)
		clock_due.emit(clock_view.to_state())


## The map's time left as a client should show it: the VOTE's clock, which is the one that
## ends a map here, and no clock at all when the vote has none — which is the deployed
## `trigger: rtv_only` with `duration_sec: 0`.
func clock_state() -> Dictionary:
	return DotVoteClockView.state_of(director)


## Rock the vote, nominate, or cast one. The token comes off the wire.
func submit(voter: StringName, token: String) -> DotResult:
	if director == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no vote here.")

	var parts := token.strip_edges().split(" ", false)

	if parts.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "Vote for what?")

	match parts[0].to_lower():
		"rtv":
			return director.rock_the_vote(voter)
		"unrtv":
			# The clock holds rock-the-votes. This used to call withdraw_nomination with
			# an empty id, which matched nothing, so taking back a rock-the-vote said
			# "done" and left the vote counted.
			return (
				DotResult.success(null) if director.clock.unrock(voter)
				else DotResult.fail(DotError.CODE_STATE, "You had not rocked the vote.")
			)
		"nominate":
			if parts.size() > 1:
				return director.nominate(voter, StringName(parts[1]))
		"vote":
			if parts.size() > 1:
				return director.cast_one(voter, StringName(parts[1]))
		"extend":
			# An admin's, not a player's: extending without a vote is what the ballot's
			# "extend" option exists to make a decision of the players.
			if not _is_admin(voter):
				return DotResult.fail(
					DotError.CODE_FORBIDDEN, "Only an admin can extend without a vote."
				)

			return director.extend()

	return DotResult.fail(DotError.CODE_INVALID, "That is not something to vote.")


func next_in_rotation() -> StringName:
	return director.next_in_rotation() if director != null else &""


func _player_count() -> int:
	return int(player_count_fn.call()) if player_count_fn.is_valid() else 0


func _is_admin(voter: StringName) -> bool:
	return bool(is_admin_fn.call(voter)) if is_admin_fn.is_valid() else false


func describe_lines() -> PackedStringArray:
	return director.describe_lines() if director != null else PackedStringArray()
