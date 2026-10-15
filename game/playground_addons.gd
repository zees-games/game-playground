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

const CHANNEL := "pg.addons"
const HOOK_FILE := "playground_hook.gd"
const REGISTER := "playground_register"
const RECEIVE := "playground_receive"

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
