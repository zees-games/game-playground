extends DotVoteTimedGame

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

signal announced(line: String)

## The game whose map session the vote runs over; set before [method setup].
var game: Playground = null


func _init() -> void:
	channel = CHANNEL
	metadata_key = METADATA_KEY
	command_names = COMMAND_NAMES
	noun = "map"
	config_path = CONFIG_PATH
	director_name = "Vote"
	# The module applies the change itself (through the map session it already drives, so clients are told).
	auto_apply = false
	# Voters are session ids of the form `u<n>`, dot-vote's own spelling.
	bare_voter_ids = false
	announce_fn = func(line: String) -> void: announced.emit(line)


## dot-map's own source, over the session this game already drives. Nothing here loads a map: `DotVoteMapSource.apply` calls
## `DotMapSession.change_to`, which is the path that already works, including the cloud fetch for a delivered map.
func _make_source() -> DotVoteSource:
	return DotVoteMapSource.from_session(game.maps)


func _rules() -> DotVoteRules:
	return vote_rules()


func _configure_director(d: DotVoteDirector) -> void:
	# This game counts heads (player_count_fn), it has no voter list.
	d.voters_fn = Callable()


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


func _is_admin(voter: StringName) -> bool:
	return bool(is_admin_fn.call(voter)) if is_admin_fn.is_valid() else false
