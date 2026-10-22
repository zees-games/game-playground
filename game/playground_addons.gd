extends RefCounted

## The addons folder hook: what an addon dropped into `addons/` does to the Q menu.
##
## [b]A hook is a file, not a convention an addon might half-follow.[/b] Every directory
## under `res://addons/` is looked at for one file, `playground_hook.gd`. An addon without
## it is never loaded, never instantiated and never called, so dropping a library in costs
## nothing. One with it is a script that defines
##
## [codeblock]
## func playground_register(menu) -> void
## [/codeblock]
##
## and calls [method add_item] on [param menu] for each thing it offers. Optionally it also
## defines `playground_receive(msg: Dictionary)`, which gets what the item callbacks sent
## with [method PlaygroundAddonContext.send] on a client that did not start the thing.
##
## [b]The menu never runs an addon.[/b] Choosing an entry emits a request like every other
## menu action; the server (or the game itself, offline) calls [method activate], and the
## callback runs where the authority is. Anything it needs to show everybody goes through
## [code]ctx.send(dict)[/code], carried to the clients as one bounded event.
##
## Both ends scan, so both ends list the same entries without a wire message for the list.

const PlaygroundWeaponDefScript := preload("weapons/playground_weapon_def.gd")
const PlaygroundZeeScript := preload("playground_zee.gd")
const CHANNEL := "pg.addons"
const HOOK_FILE := "playground_hook.gd"
const REGISTER := "playground_register"
const RECEIVE := "playground_receive"

## The spawn provider contract: `res://addons/<pack>/spawn_provider.gd`, or any object registered
## in [DotRegistry] under a name starting with [constant REGISTRY_PREFIX]. See docs/spawn-providers.md.
const PROVIDER_FILE := "spawn_provider.gd"
const PROVIDER_ENTRIES := "spawn_entries"
const REGISTRY_PREFIX := "playground.spawn_provider"

## Provider-made scene NPCs one player may have alive at once. A catalogue prop is limited by the
## prop spawner; a scene path is not in the catalogue, so this is its only limit.
const MAX_SCENE_SPAWNS := 16
const MAX_ENTRIES_PER_PROVIDER := 256
const MAX_COUNT := 8

## The most one message may carry once encoded, matched by the event's field.
const MESSAGE_BYTES := 900

## One entry in the menu: who offered it, what it is called and what it does.
class Item:
	extends RefCounted
	var addon: String = ""
	var id: String = ""
	var label: String = ""
	var category: String = ""
	var hint: String = ""
	var callback: Callable = Callable()
	## Set only on a spawn provider's entries: "weapon", "npc", "bot", ... and the optional icon path.
	var kind: String = ""
	var icon: String = ""
	var cfg_hint: Dictionary = {}

	func key() -> String:
		return "%s/%s" % [addon, id]


## What an activation callback is handed.
class Context:
	extends RefCounted
	## Whether this process decides. False on a client, where callbacks never run.
	var authoritative: bool = true
	## The node the game's world lives under, for anything the item must spawn.
	var world: Node3D = null
	## The player who asked, or 0 for the host.
	var player_id: int = 0
	## Where they are looking, or the world origin when unknown.
	var at: Vector3 = Vector3.ZERO
	## The simulation (a [Playground]), for provider entries that give or spawn through it. Typed
	## [Object] because this file is preloaded by Playground itself.
	var game: Object = null
	## The player's id in the simulation, where [member player_id] is the network session.
	var who: StringName = &""
	var _sender: Callable = Callable()

	## Tells every client, as a dictionary. The hook's `playground_receive` gets it there.
	func send(message: Dictionary) -> void:
		if _sender.is_valid():
			_sender.call(message)


## The object a hook's `playground_register` is given.
class Menu:
	extends RefCounted
	var _owner: Object = null
	var _addon: String = ""
	## The game's node, so a hook can parent what it creates under it.
	var host: Node = null
	## True where the game decides; a hook builds its server or client half from this.
	var authoritative: bool = true

	func add_item(
		id: String, label: String, callback: Callable, category: String = "", hint: String = ""
	) -> DotResult:
		return _owner._add(_addon, id, label, callback, category, hint)

	## The message a hook sends to clients: set by the game, called with a dictionary.
	var send_fn: Callable = Callable()

	## Convenience for hooks: sends a dictionary to every client.
	func send(message: Dictionary) -> void:
		if send_fn.is_valid():
			send_fn.call(message)


## Fired when something wants every client told: the addon's folder name and the message.
signal message(addon: String, body: Dictionary)

var _items: Array[Item] = []
var _hooks: Dictionary = {}
var _skipped: PackedStringArray = PackedStringArray()
## pack -> the provider object, kept alive; and who -> the scene NPCs it spawned.
var _providers: Dictionary = {}
## Set by the game before the scan: reshapes a provider's weapon rows by its profiles.
var profiles: Object = null
var _scene_spawns: Dictionary = {}


## Lets go of everything. An item's callback is a lambda that captures the item and this object,
## and a provider entry's `spawn` is a Callable bound to the provider's script: a reference
## cycle the engine reports as leaked at exit, with every linked pack's script in it. Called when
## the game leaves the tree.
func release() -> void:
	for item in _items:
		item.callback = Callable()
	_items.clear()
	_hooks.clear()
	_providers.clear()
	_scene_spawns.clear()


## Finds and loads every hook under [param root] (a `res://addons`-shaped directory) and
## lets each register. Returns how many hooks ran.
func scan(host: Node, authoritative: bool, root: String = "res://addons") -> int:
	var found := 0

	for dir_name in DirAccess.get_directories_at(root):
		var path := "%s/%s/%s" % [root, dir_name, HOOK_FILE]

		if not FileAccess.file_exists(path) and not ResourceLoader.exists(path):
			_skipped.append(dir_name)
			continue

		var res := load_hook(host, authoritative, dir_name, path)
		DotLog.result(CHANNEL, "loading the hook of %s" % dir_name, res)

		if res.ok:
			found += 1

	return found


## Loads one hook script. A hook that does not parse, has no `playground_register` or
## fails inside it is refused and logged; the game carries on without it.
func load_hook(host: Node, authoritative: bool, addon: String, path: String) -> DotResult:
	var script: Variant = load(path)

	if not script is GDScript or not (script as GDScript).can_instantiate():
		return DotResult.fail(DotError.CODE_INVALID, "%s does not compile" % path)

	var hook: Variant = (script as GDScript).new()

	if hook == null or not hook.has_method(REGISTER):
		# A Node that is never added to the tree is never freed by anything else.
		if hook is Node:
			(hook as Node).free()

		return DotResult.fail(DotError.CODE_INVALID, "%s defines no %s(menu)" % [path, REGISTER])

	if hook is Node and host != null:
		(hook as Node).name = "Addon_%s" % addon
		host.add_child(hook as Node)

	var menu := Menu.new()
	menu._owner = self
	menu._addon = addon
	menu.host = host
	menu.authoritative = authoritative
	menu.send_fn = func(body: Dictionary) -> void: message.emit(addon, body)
	_hooks[addon] = hook
	hook.call(REGISTER, menu)
	return DotResult.success(addon)


## Finds every spawn provider: `spawn_provider.gd` under each directory of [param root] and every
## object in [DotRegistry] named `playground.spawn_provider*`. Returns how many provided entries.
## A pack with neither is not an error: the menu simply has nothing from it.
func scan_providers(host: Node, root: String = "res://addons") -> int:
	var found := 0

	for dir_name in DirAccess.get_directories_at(root):
		var path := "%s/%s/%s" % [root, dir_name, PROVIDER_FILE]

		if not FileAccess.file_exists(path) and not ResourceLoader.exists(path):
			continue

		var script: Variant = load(path)

		if not script is GDScript or not (script as GDScript).can_instantiate():
			DotLog.warn(CHANNEL, "a spawn provider does not compile", {"path": path})
			continue

		var provider: Variant = (script as GDScript).new()

		if register_provider(dir_name, provider, host).ok:
			found += 1

	for reg_name in DotRegistry.names():
		if not String(reg_name).begins_with(REGISTRY_PREFIX):
			continue

		var pack := String(reg_name).trim_prefix(REGISTRY_PREFIX).trim_prefix(".")
		pack = pack if not pack.is_empty() else "registry"

		if _providers.has(pack):
			continue

		if register_provider(pack, DotRegistry.get_service(reg_name), host).ok:
			found += 1

	return found


## Takes one provider (duck-typed: it only needs `spawn_entries()`) and adds its entries. A bad
## entry is skipped and logged; the rest of the pack still shows.
func register_provider(pack: String, provider: Variant, host: Node = null) -> DotResult:
	if not provider is Object or not (provider as Object).has_method(PROVIDER_ENTRIES):
		if provider is Node:
			(provider as Node).free()

		return DotResult.fail(DotError.CODE_INVALID, "%s has no %s()" % [pack, PROVIDER_ENTRIES])

	if provider is Node and host != null and (provider as Node).get_parent() == null:
		(provider as Node).name = "Provider_%s" % pack
		host.add_child(provider as Node)

	var entries: Variant = (provider as Object).call(PROVIDER_ENTRIES)

	if not entries is Array:
		return DotResult.fail(DotError.CODE_INVALID, "%s.%s() did not return an Array" % [pack, PROVIDER_ENTRIES])

	var added := 0

	if profiles != null:
		entries = profiles.refine_weapon_entries(pack, entries as Array)

	for entry: Variant in (entries as Array).slice(0, MAX_ENTRIES_PER_PROVIDER):
		if not entry is Dictionary:
			continue

		var made := _add_entry(pack, entry as Dictionary)

		if made.ok:
			_teach_weapon(pack, provider, entry as Dictionary, host)

		if made.ok:
			added += 1
		else:
			DotLog.warn(CHANNEL, "a spawn entry was refused", {"pack": pack, "why": made.error.message})

	_providers[pack] = provider
	return DotResult.success(added)


func _add_entry(pack: String, entry: Dictionary) -> DotResult:
	var id := str(entry.get("id", ""))
	var kind := str(entry.get("kind", ""))
	var spawn: Variant = entry.get("spawn", "")
	# `spawn_fn` is the action when `spawn` carries data (an npc's stats Dictionary) for other consumers.
	var spawn_fn: Variant = entry.get("spawn_fn")
	if spawn_fn is Callable:
		spawn = spawn_fn

	if id.is_empty() or kind.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "an entry needs an id and a kind")

	if not spawn is Callable and not spawn is String and not spawn is StringName and not spawn is Dictionary:
		return DotResult.fail(DotError.CODE_INVALID, "%s/%s: spawn is a Callable or a string" % [pack, id])

	var category := str(entry.get("category", ""))
	var hint: Variant = entry.get("cfg_hint", {})
	var item_ref: Array = []
	var made := _add(
		pack, id, str(entry.get("name", "")),
		func(ctx: Context) -> Variant: return _run_entry(item_ref[0], spawn, ctx),
		category if not category.is_empty() else kind.capitalize() + "s", ""
	)

	if not made.ok:
		return made

	var item: Item = made.value
	item_ref.append(item)
	item.kind = kind
	item.icon = str(entry.get("icon", ""))
	item.cfg_hint = (hint as Dictionary) if hint is Dictionary else {}
	item.hint = "%s - %s from %s%s" % [
		item.label, kind, pack, "" if item.cfg_hint.is_empty() else "\n" + str(item.cfg_hint)
	]
	return made


## Runs one provider entry on the authority. A Callable spawn is called with a context dictionary;
## a string spawns by [param item]'s kind through the game's own paths, so limits, charging and
## entitlement checks are the game's, not the pack's.
func _run_entry(item: Item, spawn: Variant, ctx: Context) -> Variant:
	var game := ctx.game

	if not ctx.authoritative or game == null:
		return DotResult.fail(DotError.CODE_STATE, "only the authority gives or spawns")

	if ctx.who == &"" or not (game.get("players") as Dictionary).has(ctx.who):
		return DotResult.fail(DotError.CODE_STATE, "no such player")

	if spawn is Callable:
		var out: Variant = (spawn as Callable).call({
			"game": game, "world": ctx.world, "player_id": ctx.who, "at": ctx.at,
			"kind": item.kind, "cfg_hint": item.cfg_hint, "authoritative": true,
		})
		return out if out is DotResult else DotResult.success(item.key())

	if spawn is Dictionary and item.kind != "weapon":
		return DotResult.fail(DotError.CODE_INVALID, "%s has stats but no spawn_fn to run" % item.key())

	var target := item.id if spawn is Dictionary or String(spawn).is_empty() else String(spawn)

	if spawn is Dictionary:
		# A weapon pack's data row ({weapon_id} or {weapon}): the game's id for it is the one
		# [method _teach_weapon] gave it.
		target = pack_weapon_id(item.addon, _weapon_name(spawn as Dictionary, item.id))

	if item.kind == "weapon":
		if game.call("weapon_def", StringName(target)) == null:
			return DotResult.fail(DotError.CODE_INVALID, "the weapon catalogue has no %s" % target)

		# The same event a pickup raises: on a server the bridge charges and arms it, offline the
		# client equips it. Not a second way to hold a weapon.
		game.call("pick_up_weapon", ctx.who, StringName(target))
		return DotResult.success(item.key())

	if item.kind == "npc" or item.kind == "bot":
		return _spawn_body(item, target, ctx)

	return DotResult.fail(DotError.CODE_INVALID, "kind %s needs a Callable spawn" % item.kind)


## The weapon id a data row names: `weapon_id`, else `weapon`, else the row's own id.
func _weapon_name(spawn: Dictionary, row_id: String) -> String:
	for key in ["weapon_id", "weapon"]:
		if not str(spawn.get(key, "")).is_empty():
			return str(spawn[key])
	return row_id


## The game's id for a provider's weapon. Prefixed with the pack, so a pack can never replace one
## of the game's own and two packs can both have a `pistol`.
static func pack_weapon_id(pack: String, weapon: String) -> StringName:
	return StringName("pk_%s_%s" % [pack, weapon])


## A weapon row whose `spawn` is data (a Dictionary) is a dot-weapon definition behind the
## provider's static `weapon_defs()`. Adds it to the host's weapon list as a rig-held weapon
## (`meta.zee` + `meta.pack_def`, the shape the Workshop's weapons have), so the pickup path, the
## bridge and the rigs find it the way they find any other. Both ends scan, so both know it.
func _teach_weapon(pack: String, provider: Variant, entry: Dictionary, host: Node) -> void:
	var spawn: Variant = entry.get("spawn")
	if str(entry.get("kind", "")) != "weapon" or not spawn is Dictionary or host == null:
		return
	if not (provider as Object).has_method("weapon_defs") or host.get("weapons") == null:
		DotLog.warn(CHANNEL, "a weapon row has data and its provider has no weapon_defs()", {"pack": pack, "id": str(entry.get("id", ""))})
		return

	var want := _weapon_name(spawn as Dictionary, str(entry.get("id", "")))
	var game_id := pack_weapon_id(pack, want)
	var weapons: Array = host.get("weapons")
	if weapons.any(func(d: Variant) -> bool: return d.id == game_id):
		return

	for each: Variant in _defs_of(provider as Object):
		if not each is DotWeaponDef or String((each as DotWeaponDef).id) != want:
			continue
		var pack_def := each as DotWeaponDef
		var def := PlaygroundWeaponDefScript.make(game_id, str(entry.get("name", pack_def.display_name)), "")
		def.description = pack_def.description
		def.category = &"pack"
		def.colour = PlaygroundZeeScript.SLOT_COLOURS.get(pack_def.slot, Color(0.62, 0.68, 0.78))
		def.meta = {"zee": want, "slot": pack_def.slot, "provider": pack, "pack_def": pack_def}
		weapons.append(def)
		PlaygroundZeeScript.add_provider_def(def)
		return

	DotLog.warn(CHANNEL, "a weapon row names a weapon its provider's weapon_defs() lacks", {"pack": pack, "weapon": want})


## A provider's definitions; over the live profile edits when it offers `weapon_defs_with(layer)`.
func _defs_of(provider: Object) -> Array:
	if profiles != null and provider.has_method("weapon_defs_with"):
		return provider.call("weapon_defs_with", profiles.weapon_layer())
	return provider.call("weapon_defs")


## Rebuilds the taught pack weapons of weapon profile [param profile_id] in place, so a rig that holds
## one reads the new numbers on its next shot. Returns how many it refreshed.
func reapply_weapons(host: Node, profile_id: String) -> int:
	var weapons: Variant = host.get("weapons")
	if profiles == null or weapons == null:
		return 0
	var fresh_by_pack := {}
	var done := 0
	for def: Variant in weapons:
		var pack_def: Variant = def.meta.get("pack_def")
		var pack := str(def.meta.get("provider", ""))
		if not pack_def is DotWeaponDef or not _providers.has(pack):
			continue
		if profiles.weapons.profile_for(String((pack_def as DotWeaponDef).id)) != profile_id:
			continue
		if not fresh_by_pack.has(pack):
			fresh_by_pack[pack] = _defs_of(_providers[pack] as Object)
		for fresh: Variant in fresh_by_pack[pack]:
			if fresh is DotWeaponDef and (fresh as DotWeaponDef).id == (pack_def as DotWeaponDef).id:
				DotWeaponProfiles.refresh_def(pack_def, fresh)
				done += 1
	return done


func _spawn_body(item: Item, target: String, ctx: Context) -> DotResult:
	var game := ctx.game
	var count := clampi(int(item.cfg_hint.get("count", 1)), 1, MAX_COUNT)
	var weapon := StringName(str(item.cfg_hint.get("weapon", "")))
	var spawned := 0
	var catalogue: Object = (game.get("props") as Object).get("catalogue")

	for i in count:
		var angle := TAU * float(i) / float(count)
		var at := ctx.at + Vector3.UP + (Vector3(cos(angle), 0.0, sin(angle)) * 1.2 if count > 1 else Vector3.ZERO)
		var body: Node = null

		if catalogue != null and catalogue.call("get_prop", StringName(target)) != null:
			# Through the prop spawner: the NPC limit, the cost budget and creative mode apply.
			var prop: Variant = (game.get("props") as Object).call("spawn", StringName(target), ctx.who, at)
			body = prop.node if prop != null else null
		elif target.begins_with("res://") and (target.ends_with(".tscn") or target.ends_with(".scn")):
			body = _spawn_scene(target, ctx, at)

		if body == null:
			break

		spawned += 1

		if weapon != &"" and body.has_method("arm_with"):
			body.call("arm_with", weapon)

	if spawned == 0:
		return DotResult.fail(DotError.CODE_QUOTA, "%s could not be spawned (limit, or no such NPC)" % item.label)

	return DotResult.success(spawned)


func _spawn_scene(path: String, ctx: Context, at: Vector3) -> Node:
	var alive: Array = _scene_spawns.get(ctx.who, [])
	alive = alive.filter(func(n: Variant) -> bool: return is_instance_valid(n))
	_scene_spawns[ctx.who] = alive

	if alive.size() >= MAX_SCENE_SPAWNS or ctx.world == null:
		return null

	var scene: Variant = load(path)

	if not scene is PackedScene:
		return null

	var node: Node = (scene as PackedScene).instantiate()
	node.set_meta(&"spawn_provider_owner", ctx.who)
	ctx.world.add_child(node)

	if node is Node3D:
		(node as Node3D).global_position = at

	alive.append(node)
	return node


func provider_count() -> int:
	return _providers.size()


func _add(
	addon: String, id: String, label: String, callback: Callable, category: String, hint: String
) -> DotResult:
	if id.is_empty() or not callback.is_valid():
		return DotResult.fail(DotError.CODE_INVALID, "an item needs an id and a callback")

	for existing in _items:
		if existing.addon == addon and existing.id == id:
			return DotResult.fail(DotError.CODE_CONFLICT, "%s/%s is registered" % [addon, id])

	var item := Item.new()
	item.addon = addon
	item.id = id
	item.label = label if not label.is_empty() else id.capitalize()
	item.category = category if not category.is_empty() else addon.capitalize()
	item.hint = hint
	item.callback = callback
	_items.append(item)
	return DotResult.success(item)


func items() -> Array[Item]:
	return _items


func hook_count() -> int:
	return _hooks.size()


func skipped() -> PackedStringArray:
	return _skipped


func find(key: String) -> Item:
	for item in _items:
		if item.key() == key:
			return item

	return null


## The menu's rows: plain dictionaries, so the menu never holds an addon's objects.
func describe_items() -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	for item in _items:
		out.append({
			"key": item.key(), "label": item.label, "category": item.category, "hint": item.hint,
			"kind": item.kind, "icon": item.icon,
		})

	return out


## Runs one entry. Server side, or offline.
func activate(key: String, ctx: Context) -> DotResult:
	var item := find(key)

	if item == null:
		return DotResult.fail(DotError.CODE_INVALID, "no addon item %s" % key)

	ctx._sender = func(body: Dictionary) -> void: message.emit(item.addon, body)
	var out: Variant = item.callback.call(ctx)

	if out is DotResult:
		return out as DotResult

	return DotResult.success(key)


## A message the authority sent, on a client: handed to the hook that sent it.
func deliver(addon: String, body: Dictionary) -> bool:
	var hook: Variant = _hooks.get(addon)

	if hook == null or not hook.has_method(RECEIVE):
		return false

	hook.call(RECEIVE, body)
	return true


func describe() -> String:
	return "addons: %d hooks, %d items, %d without a hook" % [
		_hooks.size(), _items.size(), _skipped.size()
	]
