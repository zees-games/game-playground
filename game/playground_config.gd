extends DotConfig

## Everything the playground is configured with, layered like every [DotConfig]:
## exported defaults, then a JSON file, then [code]PLAYGROUND_*[/code] environment
## variables, then [code]--pg-*[/code] arguments.
##
## [b]The tick rate is the one that matters, and it is deliberately not here.[/b] It
## is taken from the engine ([method Playground._resolve_tick_rate]), which on a
## dot-server is whatever [code]sv_tickrate[/code] was set to, and a run timer a server
## added is handed the same number. One number, in
## [code]server.cfg[/code], with everything else — rather than a second copy in a
## second file that can disagree with the first and produce plausible, wrong,
## permanently-filed times.
##
## [codeblock]
## ./game --pg-initial-map=pg_generated --pg-map-seed=42 --pg-records-directory=/srv/records
## [/codeblock]

@export_group("Content")

## The map to load on boot.
@export var initial_map: StringName = &"pg_flatgrass"

## A map catalogue JSON file. Empty uses the maps this build ships.
##
## The seam between "a game with its own maps" and "a server with a map pool": an
## operator points this at a file and the built-in list is not used at all.
@export var catalogue_path: String = ""

## The seed a generated map is built from. Zero picks one and announces it.
##
## [b]A generated world nobody can name the seed of is a world nobody can share[/b], and
## "play the map I played" is the single most-requested feature every generated game gets.
## It is a setting rather than a debugging affordance for exactly that reason, and the
## seed actually used is logged whichever way it arrived.
##
## Zero takes the seed from dot-randomness when the deployment has one, so a generated map
## and everything else random in the session come out of one number rather than two.
@export var map_seed: int = 0

## A prop catalogue JSON file. Empty uses the fourteen props this build ships.
##
## Loaded INSTEAD of the built-in list, not layered over it. A catalogue that merged
## would give every server these fourteen whether it wanted them or not, and there
## would be no way to remove one. See [method Playground.built_in_props].
@export var props_path: String = ""

## A folder of loose models (.glb or .gltf, each with an optional same-named .json sidecar for
## name, category, scale and mass) that become props with no code. Read at start and by
## [method Playground.rescan_props]. A server sets it to its content directory
## ([code]PLAYGROUND_PROPS_DIR[/code]); a missing folder is not an error. A connected client
## needs the same model to draw a prop the server added, so drop-ins that should be seen by
## everyone belong in the game's pack instead.
@export var props_dir: String = "user://props"

@export_group("Rules")

## Whether this instance times, ranks and spawns — the authority.
##
## A client sets this false; with a run timer added, it times its own run for its HUD and
## files nothing.
@export var authoritative: bool = true

## Seconds a map runs before the session asks for the next one. 0 disables it.
@export_range(0.0, 86400.0, 30.0) var map_seconds: float = 2700.0

## The file that says which maps a server ROTATES: `cfg/maps.yml`, layered over the game's own
## shipped `res://maps.yml` (dot-map's `DotMapRotationFile`: named rotations, `random` or
## `cycle`, wildcards, command names). Empty, or no such file, rotates every map. A map the
## active rotation leaves out stays installed (`pg_map <id>` loads it); it is only never
## chosen, balloted or nominated. `sv_map_rotation_file`.
@export var map_rotation_file: String = "cfg/maps.yml"

## Fraction of the players who must rock the vote to end a map early.
@export_range(0.0, 1.0, 0.05) var rtv_fraction: float = 0.6

@export_group("Records")

## Where records are kept. Empty keeps them in memory only.
@export var records_directory: String = "user://playground/records"

@export var record_replays: bool = true

## Whether published boards are reported to the TMC backbone.
##
## Off by default: publishing sends player names and times off the server, and that
## is an operator's decision rather than something that happens because a default was
## permissive.
@export var report_to_backbone: bool = false

@export_group("Props")

## Whether props can be spawned at all. Off makes it a pure movement server.
@export var allow_props: bool = true

## Props one player may have at once, counted in COST. 0 = unlimited, and 0 is the default.
##
## [b]Off by default since the per-kind limits arrived[/b] ([code]pg_max_props[/code],
## [code]pg_max_npcs[/code] and the rest, in `PlaygroundLimits`). Both apply when both are
## set, and a cost budget of 64 under a count of 200 props meant the count was never the
## one a player met — an NPC costs six, so the budget refused the eleventh NPC before
## [code]pg_max_npcs[/code] could say anything, with a message about props.
@export_range(0, 1000, 1) var prop_budget: int = 0

## Whether a player may move, freeze or remove somebody else's props.
##
## [b]dot-props deliberately refuses to decide this[/b] — "a build server says no, a
## sandbox says yes, a competitive one says only for admins, and hard-coding either
## answer means the other needs a fork" — so it is passed to every tool call as
## `can_touch_others`. On by default, because this is a sandbox.
@export var touch_others_props: bool = true

## Whether a player may switch on creative mode (`!creative`): their props refuse
## everybody else's tools and harm, nobody can pick them up, and they neither take nor
## deal damage from other players. What a building server offers somebody who wants to
## build while the rest of it plays. Falls, pits and their own props still reach them.
@export var allow_creative: bool = true

## Whether standing on a moving prop carries you with it: a crate somebody else swings with
## the physics gun, a plank sliding down a ramp, or the one you are holding yourself under
## your own feet (which is prop surfing). dot-props' DotPropCarry; the prop also takes some
## of your weight. Off leaves a crate exactly as solid and as still as the floor.
@export var prop_surfing: bool = true

## Whether shots and blasts break props that have health (`PlaygroundSpawnables.BREAKABLE`):
## a crate shot apart into debris, a barrel that goes up. Off by default: a sandbox where
## somebody can shoot your build to pieces is a different server, and an operator chooses
## it (`pg_destruction`). Creative mode protects a builder's props either way.
@export var destruction: bool = false

## Whether a map's breakable boxes (glass) break from shots, blasts and fast impacts. On by
## default and separate from [member destruction], which is about props: glass in a map is
## put there to be broken (`pg_breakable_glass`).
@export var breakable_glass: bool = true

## Pieces a broken prop leaves, and how long they lie there.
@export_range(0, 12) var debris_pieces: int = 4
@export_range(0.5, 60.0, 0.5) var debris_seconds: float = 6.0

## Props in the world at once, from everybody. 0 = unlimited.
@export_range(0, 10000, 1) var prop_world_budget: int = 1024

## Seconds between one player's spawns.
##
## [b]A budget alone does not stop a held key.[/b] Reach the cap, remove one, spawn
## another — that is a spawn and a free every frame, which costs the server more than
## the props do. dot-props' own default is 0.15 s; this is looser because a sandwich
## of planks is built by spawning a dozen quickly, and it is a [DotConfig] field so an
## operator who is being spammed can tighten it without a build.
@export_range(0.0, 10.0, 0.01) var prop_spawn_interval: float = 0.1


func env_prefix() -> String:
	return "PLAYGROUND_"


func cli_prefix() -> String:
	return "--pg-"


func validate() -> DotResult:
	if initial_map == &"":
		return DotResult.fail(
			DotError.CODE_INVALID, "There has to be a map to start on."
		)

	if rtv_fraction <= 0.0 or rtv_fraction > 1.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"rtv_fraction must be above 0 and at most 1.",
			"%.2f" % rtv_fraction
		)

	return DotResult.success(null)


func describe_summary() -> String:
	return "map %s, %s, props %s" % [
		String(initial_map),
		("records " + (records_directory if records_directory != "" else "in memory")),
		(("on, %s" % (props_path if props_path != "" else "built in"))
			if allow_props else "off"),
	]
