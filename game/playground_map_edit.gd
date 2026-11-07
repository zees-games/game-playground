extends RefCounted

## Builds dot-game's `DotGameMapEdit` for this game: the point set, the map-data store and where a typed command stands.
##
## The point set and the store are found by path so a build without dot-spawn or dot-map has no map editing
## ([method make] gives null) rather than a script that does not parse.

const POINT_SET := "res://addons/dot_spawn/core/dot_spawn_point_set.gd"
const POINT_DEF := "res://addons/dot_spawn/core/dot_spawn_point_def.gd"
const STORE_CONFIG := "res://addons/dot_map/data/dot_map_data_config.gd"
const GAME_ID := "game-playground"


## dot-map's stores answer `fetch`; the command set asks `load`.
class StoreAdapter extends RefCounted:
	var inner: Object = null

	func load(game: String, map_id: String, version: String) -> Variant:
		# The file store logs an engine error for a map it holds nothing on, which is every map at first.
		if "root" in inner and not DirAccess.dir_exists_absolute(str(inner.get("root")).path_join(game).path_join(map_id)):
			return DotResult.fail("not_found", "No data for %s %s." % [map_id, version])

		return await inner.call("fetch", game, map_id, version)

	func save(bundle: Object, by: String = "") -> Variant:
		return await inner.call("save", bundle, by)


## A command's caller when nobody typed it: the offline player, or a map change reloading the saved data.
class Ctx extends RefCounted:
	var args := PackedStringArray()
	var who := "local"
	var pose := {}
	var said := ""

	func caller_label() -> String:
		return who

	func reply(text: String) -> void:
		said = text


## The editor over `game`'s map, or null when dot-spawn is not linked. [param store] defaults to dot-map's configured one.
static func make(game: Object, store: Object = null) -> Object:
	if not ResourceLoader.exists(POINT_SET):
		return null

	var edit := DotGameMapEdit.new()
	edit.points = (load(POINT_SET) as GDScript).new()
	edit.store = _adapt(store if store != null else _default_store())
	edit.map_fn = func() -> Dictionary: return map_of(game)
	edit.pose_fn = func(ctx: Object) -> Dictionary: return feet_of(game, _who(ctx))
	return edit


static func map_of(game: Object) -> Dictionary:
	var map: Object = game.get("maps").get("current") if game.get("maps") != null else null

	if map == null:
		return {}

	return {"game": GAME_ID, "id": str(map.get("id")), "version": str(map.get("version")), "digest": ""}


## Where a player stands and faces, for the commands that place at the caller's feet.
static func feet_of(game: Object, who: StringName) -> Dictionary:
	var player: Variant = game.get("players").get(who) if game.get("players") != null else null

	if player == null or player.get("controller") == null:
		return {}

	var state: Object = player.get("controller").get("state")
	return {"position": state.get("position"), "yaw": float(state.get("yaw"))}


## Empties the working set and loads the saved data for the map now running; nothing saved leaves it empty.
static func reload_saved(edit: Object) -> void:
	var list: Array = edit.get("points").get("points")
	list.clear()
	edit.set("dirty", false)
	var _outcome: Variant = await edit.call("run", "mapdata_revert", Ctx.new())


## Whether a session may edit the map's data: the flag the commands themselves need, or root.
static func session_may_edit(session: Object, flag: String) -> bool:
	return session != null and (bool(session.call("has_permission", flag)) or bool(session.call("has_permission", "root")))


## A typed command's caller is a session (`u<id>`); the offline player and the toolgun name themselves.
static func _who(ctx: Object) -> StringName:
	var session: Variant = ctx.get("session")

	if session is Object:
		return StringName("u%d" % int((session as Object).get("userid")))

	return StringName(str(ctx.get("who"))) if ctx.get("who") != null else &""


static func _default_store() -> Object:
	if not ResourceLoader.exists(STORE_CONFIG):
		return null

	var config: Object = (load(STORE_CONFIG) as GDScript).new()
	var made: Variant = config.call("make_store")
	return (made as DotResult).value if made is DotResult and (made as DotResult).ok else null


static func _adapt(store: Object) -> Object:
	if store == null or store.has_method("load"):
		return store

	var adapter := StoreAdapter.new()
	adapter.inner = store
	return adapter
