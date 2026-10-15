extends Node3D

## The playground's side of natural-disasters: one Addons-tab entry per disaster kind.
##
## [b]An adapter beside the addon, not a change to it.[/b] natural-disasters knows nothing of
## the playground and should not; this file is the only place that knows both. It lives in
## its own folder so the addon itself can stay a symlink to its own repository
## (`ln -s ../../natural-disasters/addons/natural_disasters addons/natural_disasters`), and
## when that link is absent the hook registers nothing and the playground starts as before.
##
## Paths are loaded rather than named: a script that mentioned `DotDisasterManager` would
## not compile in a checkout without the addon.

const MANAGER := "res://addons/natural_disasters/runtime/dot_disaster_manager.gd"

var manager: Node = null
var _host: Node = null


func playground_register(menu) -> void:
	if not ResourceLoader.exists(MANAGER):
		DotLog.info("pg.addons", "natural-disasters is not linked; no disasters in the menu")
		return

	_host = menu.host
	manager = (load(MANAGER) as GDScript).new()
	manager.set("authority", menu.authoritative)
	# The sandbox's props are the bodies a tornado should throw, wherever they were put.
	manager.set("bodies_fn", _bodies)
	manager.set("send_fn", menu.send_fn)
	add_child(manager)

	for kind_id in manager.call("kind_ids"):
		var kind: Object = manager.call("get_kind", StringName(kind_id))
		var label: String = str(kind.get("display_name"))
		menu.add_item(
			str(kind_id), label if label != "" else String(kind_id).capitalize(),
			_start.bind(StringName(kind_id)), "Disasters",
			"Starts a %s where you are looking." % String(kind_id)
		)


## The client half: draw what the authority announced.
func playground_receive(msg: Dictionary) -> void:
	if manager != null:
		var received: DotResult = manager.call("receive", msg)
		DotLog.result("pg.addons", "a disaster message", received)


func _start(ctx, kind_id: StringName) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "natural-disasters is not linked")

	var overrides := {"origin": ctx.at}
	return manager.call("start", kind_id, overrides)


func _bodies() -> Array:
	var out: Array = []
	var world: Variant = _host.get("world") if _host != null else null

	if world is Node:
		_collect(world as Node, out)

	return out


func _collect(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is RigidBody3D:
			out.append(child)
		_collect(child, out)
