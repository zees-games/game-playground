extends RefCounted

## What the sandbox's ambience is: dot-audio's [DotAmbienceDirector] tables and the cvar defaults. Shared by the
## simulation (which binds the `pg_ambient*` cvars) and the presentation (which plays them).

const PREFIX := "pg"
## A sandbox is mostly somebody building: the layer is felt, not heard, and the one-shots are rare.
const LEVEL := 0.15
const RATE := 0.4
const DEFAULT_MOOD := &"outdoor_night"

## By name prefix; imported and custom maps arrive named by their author.
const PREFIX_MOODS := {
	"surf_": &"snow_wind", "kz_": &"cave_tunnel", "climb_": &"cave_tunnel", "xc_": &"cave_tunnel",
	"pgc_warehouse": &"industrial", "pgc_site": &"industrial", "pgc_smallbase": &"industrial",
	"pgc_quarry": &"cave_tunnel", "pgc_canyon": &"snow_wind",
}


static func make_rules() -> DotAmbienceRules:
	var r := DotAmbienceRules.new()
	r.prefix = PREFIX
	r.volume = LEVEL
	r.frequency = RATE
	return r


## The cvars a workbench set offers: name -> profile type.
static func cvar_types() -> Dictionary:
	var rules := make_rules()
	var out := {}
	for key: String in DotAmbienceRules.VARS:
		var row: Array = DotAmbienceRules.VARS[key]
		out[rules.cvar_of(row)] = "string" if row[2] == null else "float"
	return out
