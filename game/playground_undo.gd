extends RefCounted

## The undo stack: one entry per thing a player spawned, props and addon-made disasters alike, newest first.
##
## [b]Props keep their own stack in dot-props; this one only orders the other entries among them.[/b] A prop entry
## only marks its place, and undoing it asks [method DotPropSpawner.undo], so the two stacks cannot disagree about
## what a prop is. An addon entry carries the callable that takes its thing away.

signal undone(who: StringName, at: Vector3)

const MAX_ENTRIES := 64

var _props: DotPropSpawner = null
var _stacks: Dictionary = {}


func attach(props: DotPropSpawner) -> void:
	_props = props
	props.spawned.connect(_on_spawned)
	props.removed.connect(_on_removed)


## Registers an undoable thing for [param who]. [param undo_fn] takes it away; it runs on the authority only.
func push(who: StringName, undo_fn: Callable, at: Vector3 = Vector3.ZERO) -> void:
	_add(who, {"prop": -1, "fn": undo_fn, "at": at})


## Undoes [param who]'s newest spawn. False when there is nothing.
func undo(who: StringName) -> bool:
	var stack: Array = _stacks.get(who, [])
	while not stack.is_empty():
		var entry: Dictionary = stack.pop_back()
		if int(entry["prop"]) >= 0:
			if _props != null and _props.undo(who):
				undone.emit(who, entry["at"])
				return true
			continue
		var fn: Callable = entry["fn"]
		if fn.is_valid():
			fn.call()
			undone.emit(who, entry["at"])
			return true
	if _props != null and _props.undo(who):
		undone.emit(who, Vector3.ZERO)
		return true
	return false


func count(who: StringName) -> int:
	return (_stacks.get(who, []) as Array).size()


func _add(who: StringName, entry: Dictionary) -> void:
	if not _stacks.has(who):
		_stacks[who] = []
	var stack: Array = _stacks[who]
	stack.append(entry)
	if stack.size() > MAX_ENTRIES:
		stack.pop_front()


func _on_spawned(prop: DotPropInstance) -> void:
	var node := prop.node as Node3D if prop != null else null
	var at := node.global_position if node != null and node.is_inside_tree() else Vector3.ZERO
	_add(prop.owner_id, {"prop": prop.instance_id, "fn": Callable(), "at": at})


func _on_removed(prop: DotPropInstance, _reason: StringName) -> void:
	var stack: Array = _stacks.get(prop.owner_id, [])
	for i in range(stack.size() - 1, -1, -1):
		if int((stack[i] as Dictionary)["prop"]) == prop.instance_id:
			stack.remove_at(i)
			return
