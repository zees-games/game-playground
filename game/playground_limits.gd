extends RefCounted

## How many of each kind of thing one player may have, and who gets more.
##
## [b]Separate counts per kind, which is what a sandbox actually needs.[/b] One prop budget
## treats sixty crates and sixty NPCs as the same sixty, and they are not: the crates are
## somebody building, the NPCs are somebody making the server unplayable. The sandboxes
## this game is shaped like each kept a limit per kind — props, NPCs, entities, vehicles,
## balloons, weapons, ropes and welds — and an operator turns them independently.
##
## [b]Roles, by name.[/b] An operator writes
##
## [codeblock]
## pg_limit_roles "admin: npcs=40 props=600; vip: props=300 balloons=60"
## [/codeblock]
##
## and a player gets the most generous value among the roles they hold — their dot-server
## admin groups by name, plus `admin` for anybody with an admin flag and `root` for the
## root flag. A value of 0 is "no limit". The defaults are the `pg_max_<group>` cvars.
##
## dot-props counts and refuses ([member DotPropLimits.group_limits],
## [member DotPropSpawner.limit_resolver]); this file only answers "how many for this
## player". Constraints are not props, so the tool gun asks [method limit_for] itself.

const CHANNEL := "playground.limits"

const PROPS := &"props"
const NPCS := &"npcs"
const ENTITIES := &"entities"
const VEHICLES := &"vehicles"
const BALLOONS := &"balloons"
const WEAPONS := &"weapons"
const WAYPOINTS := &"waypoints"
const SPAWNERS := &"spawners"
const CONSTRAINTS := &"constraints"

## The groups, in the order a player is shown them, and each one's default.
##
## Generous for building, tight for anything that thinks: ten NPCs is a fight, forty is a
## server that cannot keep its tick rate, and that is the number most worth limiting.
const DEFAULTS := {
	PROPS: 200,
	NPCS: 10,
	ENTITIES: 20,
	VEHICLES: 4,
	BALLOONS: 30,
	WEAPONS: 20,
	WAYPOINTS: 40,
	SPAWNERS: 6,
	CONSTRAINTS: 100,
}

## Keys a role may set as well as the groups: dot-props' cost budget and frozen count.
const EXTRA_KEYS := [&"budget", &"frozen"]

## Group -> default per-player limit. 0 is no limit.
var defaults: Dictionary = DEFAULTS.duplicate()

## Role -> {key: limit}.
var roles: Dictionary = {}

## `func(player_id: StringName) -> PackedStringArray`: the roles a player holds. Set by the
## server module from dot-server's admin groups; unset — offline, a listen server, a suite —
## every player is just a player.
var roles_fn: Callable = Callable()


## The answer to [member DotPropSpawner.limit_resolver]: [param base] unless one of the
## player's roles says more. Bound as `props.limit_resolver = limits.resolve`.
func resolve(player_id: StringName, key: StringName, base: int) -> int:
	return limit_for(player_id, key, base)


## [param player_id]'s limit for [param key], starting from [param base] — or from the
## default for that group when [param base] is negative.
##
## The most generous role wins, and "no limit" (0) beats every number. Most generous rather
## than first or last, because a player in two roles should never be worse off for being in
## the second: being made a VIP must not cost an admin their admin limits.
func limit_for(player_id: StringName, key: StringName, base: int = -1) -> int:
	var best := base if base >= 0 else int(defaults.get(key, 0))

	if best == 0:
		return 0

	for role in roles_of(player_id):
		var row: Dictionary = roles.get(role, {})

		if not row.has(key):
			continue

		var value := int(row[key])

		if value <= 0:
			return 0

		best = maxi(best, value)

	return best


func roles_of(player_id: StringName) -> PackedStringArray:
	if roles_fn.is_valid():
		var found: Variant = roles_fn.call(player_id)

		if found is PackedStringArray:
			return found
		if found is Array:
			return PackedStringArray(found)

	return PackedStringArray()


## Parses [code]"admin: npcs=40 props=600; vip: props=300"[/code] into [member roles].
##
## Refused whole on any mistake, and the old roles kept: half-applied overrides are a
## server where the admins have their new NPC limit and lost their prop one, and nothing
## says which.
func set_roles_from(text: String) -> DotResult:
	var parsed := {}

	for chunk in text.split(";", false):
		var part := chunk.strip_edges()

		if part == "":
			continue

		var colon := part.find(":")

		if colon <= 0:
			return DotResult.fail(
				DotError.CODE_INVALID, "Each role is 'name: group=number ...'.", part
			)

		var role := part.substr(0, colon).strip_edges().to_lower()
		var row := {}

		for pair in part.substr(colon + 1).strip_edges().split(" ", false):
			var bits := pair.split("=")

			if bits.size() != 2 or not bits[1].strip_edges().is_valid_int():
				return DotResult.fail(
					DotError.CODE_INVALID, "Each limit is 'group=number'.", pair
				)

			var key := StringName(bits[0].strip_edges().to_lower())

			if not defaults.has(key) and not EXTRA_KEYS.has(key):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"Unknown limit '%s'. Known: %s." % [String(key), ", ".join(known_keys())],
					pair
				)

			row[key] = maxi(bits[1].strip_edges().to_int(), 0)

		parsed[StringName(role)] = row

	roles = parsed
	return DotResult.success(parsed)


func known_keys() -> PackedStringArray:
	var out := PackedStringArray()

	for key in defaults.keys():
		out.append(String(key))

	for key in EXTRA_KEYS:
		out.append(String(key))

	return out


## Copies the defaults onto dot-props' limits, so a cvar change reaches the spawner.
func apply_to(prop_limits: DotPropLimits) -> void:
	if prop_limits == null:
		return

	var groups := {}

	for key in defaults.keys():
		groups[key] = int(defaults[key])

	prop_limits.group_limits = groups


## One line per group: what [param player_id] has against what they may have.
func describe_for(
	player_id: StringName, usage: Dictionary, constraints_used: int = 0
) -> PackedStringArray:
	var out := PackedStringArray()
	var held := roles_of(player_id)
	out.append("%s — roles: %s" % [
		String(player_id), ", ".join(held) if not held.is_empty() else "(none)",
	])

	for key in defaults.keys():
		var used := constraints_used if key == CONSTRAINTS else 0

		if usage.has(key):
			used = int((usage[key] as Array)[0])

		var cap := limit_for(player_id, key)
		out.append("  %-12s %4d / %s" % [String(key), used, "no limit" if cap == 0 else str(cap)])

	return out


func describe() -> Dictionary:
	return {"defaults": defaults.duplicate(), "roles": roles.duplicate(true)}
