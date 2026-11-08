extends RefCounted

## The flashlight's config and the server's start rule (the beam, the click and the replication helpers are dot-flashlight's).

const PlaygroundAmbience := preload("playground_ambience.gd")

const GAME_ID := "game-playground"

## The moods whose maps start lit. The sandbox is a clear afternoon, so it starts dark and the key lights it; the enclosed rock maps (kz, climb, xc, the quarry) start lit.
const DARK_MOODS: PackedStringArray = ["interior_horror", "cave_tunnel"]


## A config with this game's defaults: T (F is use), off on a lit map, on in a dark mood.
static func make_config() -> DotFlashlightConfig:
	var cfg := DotFlashlightConfig.new()
	cfg.key = "T"
	cfg.dark_moods = DARK_MOODS
	return cfg


## The binder: `pg_flashlight_<field>` cvars, `cfg/game/game-playground/flashlight/game.yml`, a workbench set.
static func make_binder(cfg: DotFlashlightConfig) -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(cfg, GAME_ID, "pg_flashlight")
	b.profile_kind = "flashlight"
	return b


## The ambience mood a map's name implies, or "" for the sandbox's own daylit maps (the ambience's default mood is a bed, not a lighting fact).
static func mood_of(map_id: String) -> String:
	var id := map_id.to_lower()
	for prefix: String in PlaygroundAmbience.PREFIX_MOODS:
		if id.begins_with(prefix):
			return String(PlaygroundAmbience.PREFIX_MOODS[prefix])
	return ""


## Whether a player starts on [param map_id] with the light on.
static func starts_on(cfg: DotFlashlightConfig, map_id: String, mood: String = "") -> bool:
	return DotFlashlightRules.start_on(cfg, map_id, 1.0, mood if mood != "" else mood_of(map_id))
