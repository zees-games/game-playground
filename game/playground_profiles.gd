extends RefCounted

## The Q menu's NPCs and pack weapons, derived from dot-core profiles, and the live edit of them.
##
## Profiles add to or override the built-in catalogue, never replace it: an NPC profile named
## like a catalogue entry changes the keys it states; a new id needs `extra.base: <entry id>`
## to clone. A pack weapon's `menu:` (category, sort, hidden) reshapes that pack's rows.
## Tiers: `cfg/addons/<addon>/<kind>/`, `cfg/game/game-playground/<kind>/`, `cfg/server/addons/<addon>/<kind>/`, `cfg/server/game/game-playground/<kind>/`.

const CHANNEL := "pg.profiles"
## The game key of the profile game tier (the repository name).
const GAME := "game-playground"
## The actor of an edit made on the process itself: the server console, or offline play.
const LOCAL_ACTOR := &"__local"
## Profile keys written to an entry's `meta`, where the entity scripts read them with `tune`.
const TUNED: PackedStringArray = ["health", "speed", "sight", "sight_angle", "hearing", "faction"]

var roots := PackedStringArray()
var npcs: DotProfileSet = null
## Every pack's weapon profiles as the one `weapon` kind; its runtime layer is what the packs rebuild from.
var weapons: DotWeaponProfileGroup = null
var runtime: DotProfileRuntime = null

var _snap: Dictionary = {}
var _clones: PackedStringArray = PackedStringArray()


## Builds the NPC set and the runtime layer over it; [param p_roots] replaces the config roots (tests).
func setup(p_roots: PackedStringArray = PackedStringArray()) -> void:
	roots = p_roots
	npcs = DotNpcProfiles.make_set(GAME, roots)
	runtime = DotProfileRuntime.new()
	runtime.add_set(npcs)
	weapons = DotWeaponProfileGroup.make(GAME, roots)
	runtime.add_set(weapons)
	runtime.permit = func(actor: Variant, _flag: String) -> bool: return typeof(actor) == TYPE_STRING_NAME and actor == LOCAL_ACTOR


## Lets go of the sets and callables (a reference cycle otherwise).
func release() -> void:
	if runtime != null:
		runtime.permit = Callable()
		runtime.broadcast = Callable()
		runtime.send_to = Callable()
	if weapons != null:
		weapons.clear_cache()
		weapons = null
	if npcs != null:
		npcs.clear_cache()
	runtime = null
	npcs = null
	_snap.clear()


## The runtime layer (profile id -> {path: value}) the packs rebuild their weapons from.
func weapon_layer() -> Dictionary:
	return weapons.runtime if weapons != null else {}


## Applies every NPC profile (or just [param only]) to [param catalogue]. Returns how many entries
## a profile touched. Safe to repeat: each entry restarts from what the catalogue held first.
func apply_npcs(catalogue: DotPropCatalogue, only: String = "") -> int:
	if npcs == null or catalogue == null:
		return 0
	var menu := {}
	for e: Dictionary in DotNpcProfiles.menu_entries(npcs, true):
		menu[e["id"]] = e
	var touched := 0
	var listed := npcs.list_ids()
	# A profile whose file is gone puts its entry back, or removes the clone it made.
	for id: String in _snap.keys():
		if not listed.has(id) and (only == "" or only == id):
			_restore(catalogue, id)
	for id in listed:
		if only != "" and id != only:
			continue
		var res := npcs.load_profile(id)
		if not res.ok:
			DotLog.warn(CHANNEL, "npc profile skipped", {"id": id, "why": res.error.message})
			continue
		if _apply_npc(catalogue, id, res.value, menu.get(id, {})):
			touched += 1
	return touched


func _restore(catalogue: DotPropCatalogue, id: String) -> void:
	if _clones.has(id):
		var _gone := catalogue.remove(StringName(id))
		_clones.remove_at(_clones.find(id))
	else:
		var def := catalogue.get_prop(StringName(id))
		var snap: Dictionary = _snap[id]
		if def != null:
			def.display_name = snap["name"]
			def.cost = snap["cost"]
			def.category = snap["category"]
			def.meta = (snap["meta"] as Dictionary).duplicate(true)
	_snap.erase(id)


func _apply_npc(catalogue: DotPropCatalogue, id: String, p: DotProfile, entry: Dictionary) -> bool:
	var def := catalogue.get_prop(StringName(id))
	if def == null:
		var base := catalogue.get_prop(StringName(str(p.get_extra("base", ""))))
		if base == null:
			DotLog.warn(CHANNEL, "npc profile names no catalogue entry; set extra.base to add one", {"id": id})
			return false
		def = base.duplicate(true) as DotPropDef
		def.id = StringName(id)
		var added := catalogue.add(def)
		if not added.ok:
			DotLog.warn(CHANNEL, "npc profile entry refused", {"id": id, "why": added.error.message})
			return false
		_clones.append(id)
	if not _snap.has(id):
		_snap[id] = {"name": def.display_name, "cost": def.cost, "category": def.category, "meta": def.meta.duplicate(true)}
	var snap: Dictionary = _snap[id]
	def.display_name = snap["name"]
	def.cost = snap["cost"]
	def.category = snap["category"]
	def.meta = (snap["meta"] as Dictionary).duplicate(true)

	var defaults := {}
	for f: Dictionary in DotNpcProfiles.schema():
		defaults[f["name"]] = f["default"]
	var explicit := npcs.runtime_paths(id)
	# A key counts as stated when it differs from the schema default or was edited at runtime.
	for key in TUNED:
		var v: Variant = p.get_value(key)
		if v != defaults[key] or explicit.has(key):
			def.meta[key] = v
	if p.get_value("los") != defaults["los"] or explicit.has("los"):
		def.meta["line_of_sight"] = 1.0 if bool(p.get_value("los")) else 0.0
	if p.get_value("cost") != defaults["cost"] or explicit.has("cost"):
		def.cost = int(p.get_value("cost"))
	var shown := str(p.get_value("name", ""))
	if shown != "":
		def.display_name = shown
	for key: String in p.extra:
		if key != "base":
			def.meta[key] = p.extra[key]

	var m: Dictionary = p.get_value("menu", {})
	if str(m.get("category", "")) != "":
		def.category = StringName(str(m["category"]))
	def.meta["menu_sort"] = int(entry.get("sort", 0))
	if bool(entry.get("hidden", false)) or not bool(p.get_value("enabled", true)):
		def.meta["hidden"] = true
	return true


## Reorders and regroups a pack's weapon rows by the `menu:` of its weapon profiles
## (cfg/addons/<pack>/weapon, with the game tier over them). Hidden ones are dropped; a row with
## no profile stays as it was. Returns the rows, not the same Array.
func refine_weapon_entries(pack: String, entries: Array) -> Array:
	var set := weapons.add_pack(pack)
	if set.list_ids().is_empty():
		return entries
	var menu := {}
	for e: Dictionary in DotWeaponProfiles.menu_entries(set, true):
		menu[e["id"]] = e
	var out: Array = []
	for row: Variant in entries:
		if not row is Dictionary:
			out.append(row)
			continue
		var found := _weapon_menu(menu, str((row as Dictionary).get("id", "")))
		if found.is_empty():
			out.append({"row": row, "sort": 0, "at": out.size()})
			continue
		if bool(found["hidden"]):
			continue
		var changed := (row as Dictionary).duplicate()
		if str(found["category"]) != "":
			changed["category"] = str(found["category"])
		if str(found["icon"]) != "":
			changed["icon"] = str(found["icon"])
		out.append({"row": changed, "sort": int(found["sort"]), "at": out.size()})
	var wrapped := out.filter(func(x: Variant) -> bool: return x is Dictionary and x.has("row"))
	wrapped.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["sort"] < b["sort"] or (a["sort"] == b["sort"] and a["at"] < b["at"]))
	return wrapped.map(func(x: Dictionary) -> Variant: return x["row"])


## A row id `zz_m4` matches the profile `m4`: the row carries the pack's prefix.
static func _weapon_menu(menu: Dictionary, row_id: String) -> Dictionary:
	if menu.has(row_id):
		return menu[row_id]
	for pid: String in menu:
		if row_id.ends_with("_" + pid):
			return menu[pid]
	return {}
