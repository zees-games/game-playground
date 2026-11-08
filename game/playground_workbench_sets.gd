class_name PlaygroundWorkbenchSets
extends RefCounted

## What the playground's Workbench lists, and under which heading. One call for the three hosts: the offline client,
## an online client's remote panel and the server. Every set is scoped with dot-workbench's [DotWorkbenchScope] to what
## is loaded. The arena mode's settings show only while `pg_arena` is on. Each loaded weapon pack's profiles get a
## heading of their own. Every heading says which side it edits.

const GAME := "game-playground"
## The owner the arena mode's settings are listed under.
const ARENA_OWNER := "arena mode (pg_arena)"
## Config file kind -> [heading, side]. A kind not here gets "Game settings: <file>" on the server side.
const CONFIG := {
	"config_server": ["Game settings: server", DotWorkbenchScope.SIDE_SERVER],
	"config_props": ["Game settings: props", DotWorkbenchScope.SIDE_SERVER],
	"config_world": ["Game settings: world (waves, NPCs, movement)", DotWorkbenchScope.SIDE_REPLICATED],
	"config_arena": ["Arena mode (pg_arena)", DotWorkbenchScope.SIDE_SERVER],
}
## Addon cvar sets a server lists when the addon bound them: [kind, cvar prefix, heading, owner, side].
const CVAR_SETS := [
	["grenades", "sv_grenade", "Grenades (sv_grenade_*)", "arena_weapons", DotWorkbenchScope.SIDE_SERVER],
	["ragdolls", "sv_ragdoll", "Ragdolls (sv_ragdoll*)", "dot-player-char", DotWorkbenchScope.SIDE_REPLICATED],
	["toys", "sv_toys", "Map toys (sv_toys*)", "dot-props", DotWorkbenchScope.SIDE_REPLICATED],
]
## Meta on the workbench node: {pack: true} for the packs that already have a view.
const VIEWS_META := &"pg_weapon_views"


## Adds the NPC, weapon, config and flashlight sets of [param game] (a [Playground]) to [param wb] before it starts.
## [param arena_on] is a Callable() -> bool: whether the arena mode is on now (asked each time the panel opens).
## Weapon packs scanned later are added as they arrive.
static func add_sets(wb: DotGameWorkbench, game: Object, arena_on: Callable) -> void:
	var profiles: Object = game.get(&"profiles")
	var side := DotWorkbenchScope.SIDE_REPLICATED
	wb.add_set(DotWorkbenchScope.tag(profiles.get(&"npcs"), {"owner": GAME, "side": side}), "NPCs")
	# The group stays the one `weapon` kind the runtime edits; each pack is listed through a view of it.
	wb.add_set(DotWorkbenchScope.tag(profiles.get(&"weapons"), {"owner": GAME, "side": side, "listed": false}), "Weapons")
	var binder: Object = game.get(&"config_binder")
	if binder != null:
		for set: DotProfileSet in binder.call(&"profile_sets"):
			wb.add_set(tag_config(set, arena_on), label_of(set.rel_path))
	var _fl: Variant = game.call(&"flashlight_conf")
	var fl_binder: Object = game.get(&"flashlight_binder")
	if fl_binder != null:
		for set: DotProfileSet in fl_binder.call(&"profile_sets"):
			wb.add_set(DotWorkbenchScope.tag(set, {"owner": "dot-flashlight", "side": DotWorkbenchScope.SIDE_SERVER}), "Flashlight")
	follow_weapon_packs(wb, profiles)


## The heading of config file [param kind].
static func label_of(kind: String) -> String:
	if CONFIG.has(kind):
		return String(CONFIG[kind][0])
	return "Game settings: %s" % kind.trim_prefix("config_")


## Tags config set [param set]: the arena mode's file only while [param arena_on] holds.
static func tag_config(set: DotProfileSet, arena_on: Callable) -> DotProfileSet:
	var row: Array = CONFIG.get(set.rel_path, ["", DotWorkbenchScope.SIDE_SERVER])
	var info := {"owner": GAME, "side": row[1]}
	if set.rel_path == "config_arena":
		info["owner"] = ARENA_OWNER
		info["requires"] = func() -> bool: return arena_on.is_valid() and bool(arena_on.call())
	return DotWorkbenchScope.tag(set, info) as DotProfileSet


## One heading per loaded weapon pack ("Weapons: zz_modern_weapons"): the packs [param profiles] has now and every
## one it adds later. A pack with no profiles in any cfg tier stays off the panel.
static func follow_weapon_packs(wb: DotGameWorkbench, profiles: Object) -> void:
	for pack: String in profiles.get(&"weapon_packs"):
		add_pack_view(wb, profiles.get(&"weapons"), pack)
	if profiles.has_signal(&"weapon_pack_added"):
		var group: DotProfileSet = profiles.get(&"weapons")
		profiles.connect(&"weapon_pack_added", func(pack: String) -> void:
			if is_instance_valid(wb) and not wb.is_queued_for_deletion():
				add_pack_view(wb, group, pack))


## Lists pack [param pack] of weapon group [param group] on [param wb], before or after it started. Idempotent.
static func add_pack_view(wb: DotGameWorkbench, group: DotProfileSet, pack: String) -> void:
	var done: Dictionary = wb.get_meta(VIEWS_META, {})
	if done.has(pack) or group == null or not group.has_method(&"add_pack"):
		return
	var member: DotProfileSet = group.call(&"add_pack", pack)
	var view := DotWorkbenchSetView.make(group, member, pack)
	DotWorkbenchScope.tag(view, {
		"owner": pack, "side": DotWorkbenchScope.SIDE_REPLICATED,
		"requires": func() -> bool: return not member.list_ids().is_empty(),
	})
	done[pack] = true
	wb.set_meta(VIEWS_META, done)
	wb.add_set(view, "Weapons: %s" % pack)
	if wb.api != null:
		wb.api.call(&"add_set", view)


## Lists the addon cvar sets of [constant CVAR_SETS] whose cvars [param console] has on [param wb], which has started,
## and binds each to [param runtime]: Save writes `cfg/<kind>`, applied to the cvars at the next start. Call it after
## the module bound those cvars (the workbench starts before them). Value: how many sets were listed.
static func add_cvar_sets(wb: DotGameWorkbench, console: DotConsole, runtime: DotProfileRuntime) -> int:
	if wb == null or wb.api == null or console == null:
		return 0
	var listed := 0
	for row: Array in CVAR_SETS:
		var made := DotGameWorkbench.cvar_set(console, cvar_types(console, String(row[1])), String(row[0]))
		if made == null:
			continue
		DotWorkbenchScope.tag(made, {"owner": row[3], "side": row[4]})
		wb.add_set(made, String(row[2]))
		wb.api.call(&"add_set", made)
		var _applied := DotGameWorkbench.bind_cvar_set(made, runtime, console)
		listed += 1
	return listed


## {cvar: type} for every cvar of [param console] whose name starts with [param prefix]: `bool` for a 0..1 switch
## at 0 or 1, `float` for any other number, `string` otherwise.
static func cvar_types(console: DotConsole, prefix: String) -> Dictionary:
	var out := {}
	for name: String in console.cvar_names():
		if not name.begins_with(prefix):
			continue
		var c := console.find_cvar(name)
		var d := c.default_value
		if c.has_min and c.has_max and c.min_value == 0.0 and c.max_value == 1.0 and (d == "0" or d == "1"):
			out[name] = "bool"
		elif d.is_valid_float():
			out[name] = "float"
		else:
			out[name] = "string"
	return out
