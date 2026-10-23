extends RefCounted

## Playground's per-map settings: dot-game's [DotGameMapConfig] over the cvars a map may change.
##
## `cfg/game/game-playground/dot_map/map/<name>.yml` (a glob such as `pgc_*.yml` covers a class of maps), overridable from `cfg/server/...`. Only the keys in [constant KEYS] are accepted. All are server-side or replicated, so a client needs no hook of its own.

const GAME_ID := "game-playground"

## cvar -> its constraint. Add a cvar here to let a map or an operator's per-map file set it.
const KEYS := {
	"pg_destruction": {"type": "int", "min": 0, "max": 1},
	"pg_breakable_glass": {"type": "int", "min": 0, "max": 1},
	"pg_prop_surf": {"type": "int", "min": 0, "max": 1},
	"pg_creative": {"type": "int", "min": 0, "max": 1},
	"mp_solidplayers": {"type": "int", "min": 0, "max": 1},
}


## The applier over [param console]'s cvars. Call `apply(map_id)` on every map load.
static func build(console: DotConsole) -> DotGameMapConfig:
	return DotGameMapConfig.for_console(GAME_ID, console, KEYS)
