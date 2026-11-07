extends RefCounted

## The staff view of the map's spawn points and links, over dot-game's `DotGameMapEditOverlay`.
##
## Markers show while it is on, and the pick key opens the point you look at in a form whose buttons send the
## same commands a typed one does, to the editor in this process. It exists only where the process holds the
## editor and may use it (offline play); a client on a server has neither the points nor the right.

const PlaygroundMapEdit := preload("playground_map_edit.gd")
const POINT_DEF := "res://addons/dot_spawn/core/dot_spawn_point_def.gd"

var overlay: DotGameMapEditOverlay = null
var _client: Node = null
var _game: Object = null


func _init(client: Node, game: Object) -> void:
	_client = client
	_game = game


## Whether the markers are up.
func active() -> bool:
	return overlay != null and overlay.visible


## Whether the point form is up, in which case the pointer belongs to it.
func panel_open() -> bool:
	return overlay != null and overlay.panel != null and overlay.panel.visible


## Whether a map editor is here and this player may use it.
func available() -> bool:
	var allowed: Variant = _game.get("map_edit_allowed_fn") if _game != null else null
	return _game.get("map_edit") != null and allowed is Callable and (allowed as Callable).is_valid() \
		and bool((allowed as Callable).call(_who()))


## Makes the editor offline, where this process is the server and so its player is staff, and says why it cannot when it cannot.
func prepare(offline: bool) -> String:
	if _game == null:
		return "No game."

	if _game.get("map_edit") == null:
		if not offline:
			return "Map editing is not on this server."

		var edit: Object = PlaygroundMapEdit.make(_game)

		if edit == null:
			return "This build has no spawn point editing."

		_game.set("map_edit", edit)
		_game.set("map_edit_allowed_fn", func(_id: StringName) -> bool: return true)
		PlaygroundMapEdit.reload_saved(edit)

	return "" if available() else "Map editing is for staff."


func toggle() -> void:
	if active():
		hide()
	else:
		show()


func show() -> void:
	_ensure()
	overlay.visible = true
	# The tool gun edits too, so the markers follow the set rather than only this form's own sends.
	(_game.get("map_edit") as Object).set("changed_fn", func(_what: String) -> void: refresh.call_deferred())
	refresh()


func hide() -> void:
	if overlay != null:
		(_game.get("map_edit") as Object).set("changed_fn", Callable())
		overlay.close_panel()
		overlay.visible = false
		_recapture()


## Looks at the point under the crosshair and opens its form.
func pick() -> StringName:
	if not active():
		return &""

	refresh()
	var id := overlay.pick_from_camera()

	if id != &"":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if not overlay.panel.visibility_changed.is_connected(_recapture):
			overlay.panel.visibility_changed.connect(_recapture, CONNECT_ONE_SHOT)

	return id


func _recapture() -> void:
	if not panel_open():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func refresh() -> void:
	if overlay == null:
		return

	var edit: Object = _game.get("map_edit")
	overlay.set_points(edit.get("points").call("to_dict"))
	var nav: Object = edit.get("nav")

	if nav != null and nav.has_method("links_dict"):
		overlay.set_links(nav.call("links_dict"))


func free() -> void:
	if overlay != null and is_instance_valid(overlay):
		overlay.queue_free()

	overlay = null


func _ensure() -> void:
	if overlay != null:
		return

	overlay = DotGameMapEditOverlay.new()
	overlay.name = "MapEditOverlay"
	overlay.schema = (load(POINT_DEF) as GDScript).call("schema")
	overlay.send_fn = _send
	_client.add_child(overlay)


## A form's line (`spawn_set id key=value`) goes to the editor as the command it names.
func _send(line: String) -> void:
	var words := line.split(" ", false)

	if words.is_empty():
		return

	var edit: Object = _game.get("map_edit")
	var ctx := PlaygroundMapEdit.Ctx.new()
	ctx.who = String(_who())
	ctx.args = PackedStringArray(words.slice(1))
	var role := _role_of(edit, words[0])

	if role != "":
		var _outcome: Variant = edit.call("run", role, ctx)

	if ctx.said != "" and _client.get("hud") != null:
		(_client.get("hud") as Object).call("notice", ctx.said)


func _role_of(edit: Object, name: String) -> String:
	for role: String in DotGameMapEdit.COMMANDS:
		if str(edit.call("command_name", role)) == name:
			return role

	return ""


func _who() -> StringName:
	return StringName(str(_client.get("player_id")))
