extends "playground_tool.gd"

## Places and removes authored spawn points and navigation links by pointing at the map.
##
## A thin mode over dot-game's map-edit commands: it builds no point itself and sends the
## same `spawn_add`, `spawn_remove`, `nav_link_mark`, `nav_link_add` and `mapdata_save` an
## admin types, so validation, logging and the audit record are the commands'. Only a player
## the game's `map_edit_allowed_fn` names may use it.

const REACH_REMOVE := 1.5


## What a command reads from its caller: arguments, a label, the pose to place at.
class Ctx extends RefCounted:
	var args := PackedStringArray()
	var who := ""
	var pose := {}
	var said := ""

	func caller_label() -> String:
		return who

	func reply(text: String) -> void:
		said = text


func _init() -> void:
	id = &"spawnpoint"
	display_name = "Spawn points"
	description = "Places spawn points and navigation links for the map. Staff only."
	help_primary = "place a spawn point here (or mark / end a link)"
	help_secondary = "remove the spawn point you point at"
	help_reload = "save the map's data"
	super()


func schema() -> Array[Dictionary]:
	return [
		{"key": "action", "label": "Place", "type": "choice", "default": "spawn", "options": ["spawn", "link"]},
		{"key": "kind", "label": "Spawn point for", "type": "choice", "default": "player", "options": ["player", "npc", "both"]},
		{"key": "link", "label": "Link kind", "type": "choice", "default": "jump", "options": ["ladder", "door", "jump", "drop"]},
	]


func primary(gun: Object, hit: Dictionary) -> DotResult:
	var edit: Variant = _editor(gun)

	if edit is DotResult:
		return edit

	if not hit.has("point"):
		return DotResult.fail(DotError.CODE_STATE, "Point at the ground.")

	var ctx := _ctx(gun, hit)

	if str(setting("action")) == "link":
		var marking := pending.is_empty()
		ctx.args = PackedStringArray() if marking else PackedStringArray([str(setting("link"))])
		pending = {"marked": true} if marking else {}
		return _run(edit, "nav_link_mark" if marking else "nav_link_add", ctx)

	ctx.args = PackedStringArray([str(setting("kind"))])
	return _run(edit, "spawn_add", ctx)


func secondary(gun: Object, hit: Dictionary) -> DotResult:
	var edit: Variant = _editor(gun)

	if edit is DotResult:
		return edit

	if not hit.has("point"):
		return DotResult.fail(DotError.CODE_STATE, "Point at a spawn point.")

	var nearest := ""
	var best := REACH_REMOVE
	var at: Vector3 = hit["point"]

	for p: Object in (edit as Object).get("points").get("points"):
		var d := at.distance_to(p.get("position"))

		if d <= best:
			best = d
			nearest = str(p.get("id"))

	if nearest == "":
		return DotResult.fail(DotError.CODE_STATE, "No spawn point there.")

	var ctx := _ctx(gun, hit)
	ctx.args = PackedStringArray([nearest])
	return _run(edit, "spawn_remove", ctx)


func reload(gun: Object, hit: Dictionary) -> DotResult:
	var edit: Variant = _editor(gun)

	if edit is DotResult:
		return edit

	pending = {}
	return _run(edit, "mapdata_save", _ctx(gun, hit))


## The command set, or the refusal to give back.
func _editor(gun: Object) -> Variant:
	var game: Variant = gun.get("game")

	if game == null or game.get("map_edit") == null or (game.get("map_edit") as Object).get("points") == null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This server has no map editing.")

	var allowed: Callable = game.get("map_edit_allowed_fn")

	if not allowed.is_valid() or not bool(allowed.call(gun.get("wielder"))):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Map editing is for staff.")

	var edit: Object = game.get("map_edit")

	# The commands place at the caller's feet; this mode places where the gun points.
	if not edit.has_meta(&"spawntool_pose"):
		var previous: Callable = edit.get("pose_fn")
		edit.set("pose_fn", func(c: Object) -> Dictionary:
			var pose: Variant = c.get("pose")
			return pose if pose is Dictionary and not (pose as Dictionary).is_empty() else (
				previous.call(c) if previous.is_valid() else {}
			)
		)
		edit.set_meta(&"spawntool_pose", true)

	return edit


func _ctx(gun: Object, hit: Dictionary) -> Ctx:
	var ctx := Ctx.new()
	ctx.who = str(gun.get("wielder"))
	var yaw := 0.0
	var player: Variant = gun.get("game").get("players").get(gun.get("wielder"))

	if player is Node3D:
		yaw = rad_to_deg((player as Node3D).global_rotation.y)

	if hit.has("point"):
		ctx.pose = {"position": hit["point"], "yaw": yaw}

	return ctx


func _run(edit: Object, role: String, ctx: Ctx) -> DotResult:
	# Not awaited: the editing commands finish in the call, and a save that waits on its store
	# answers through the console like any other.
	edit.call("run", role, ctx)
	return DotResult.success(ctx.said if ctx.said != "" else "Sent.")
