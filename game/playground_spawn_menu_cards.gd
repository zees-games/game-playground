extends "playground_spawn_menu_base.gd"
## The Q menu's cards and the lookups behind them: which entries a tab lists, their names and ids, the tools and the visible set.


func _is_pack_tab() -> bool:
	return int(_tab) >= Tab.size()


## The pack whose tab is open, or "".
func _pack_title() -> String:
	var at := int(_tab) - Tab.size()
	return _pack_titles[at] if at >= 0 and at < _pack_titles.size() else ""


func _rows_of_open_pack() -> Array:
	var out: Array = []
	var title := _pack_title()
	for row in pack_rows:
		if str(row.get("pack_title", "")) == title:
			out.append(row)
	return out


func _categories_for_tab() -> PackedStringArray:
	if _is_pack_tab():
		var named := PackedStringArray()
		for row: Dictionary in _rows_of_open_pack():
			var category := str(row.get("category", ""))
			if not named.has(category):
				named.append(category)
		named.sort()
		return named

	if _tab == Tab.WEAPONS:
		return PlaygroundWeapons.categories(_own_weapons())

	if _tab == Tab.TOOLS:
		return PackedStringArray()

	if _tab == Tab.ADDONS or _is_provider_tab(_tab):
		var groups := PackedStringArray()
		for entry: Dictionary in _all_in_tab():
			var group := str(entry.get("category", ""))
			if not groups.has(group):
				groups.append(group)
		groups.sort()
		return groups

	if _tab == Tab.BUILDS:
		var kinds := PackedStringArray()
		for entry: Dictionary in builds:
			var category := String(_category_of(entry))
			if not kinds.has(category):
				kinds.append(category)
		kinds.sort()
		return kinds

	var seen := {}

	for entry in _all_in_tab():
		seen[String(_category_of(entry))] = true

	var out := PackedStringArray(seen.keys())
	out.sort()

	return out


## One card. A [Button] rather than a container because a Button is focusable, so Godot's focus
## neighbours make the grid navigable by gamepad or arrow keys; a VBoxContainer is not.
## Icon above text is `vertical_icon_alignment`.
func _card(icon: Texture2D, text: String, tip: String) -> Button:
	var button := Button.new()
	button.icon = icon
	button.text = text
	button.tooltip_text = tip
	button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	# The icon's horizontal alignment too: it defaults to LEFT, so `vertical_icon_alignment` alone puts
	# the icon top-left and still reserves its width, leaving the label off-centre. Only a rendered
	# frame shows it.
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.custom_minimum_size = CARD
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.clip_text = true
	button.focus_mode = Control.FOCUS_ALL
	_style_card(button)
	_wire_hover(button)
	return button


## A saved build. A custom prop (one welded piece) reads as a thing; a build as a place.
func _build_card(entry: Dictionary) -> Button:
	var build_name := str(entry.get("name", ""))
	var custom := bool(entry.get("custom", false))
	var card := _card(
		Style.icon("cube" if custom else "layers", 44, Style.ACCENT.lightened(0.15)),
		build_name,
		"%s\n%s · %d props\nClick to put it down in front of you." % [
			build_name, "Custom prop, welded as one" if custom else "Saved build", int(entry.get("props", 0)),
		]
	)
	card.pressed.connect(func() -> void: build_chosen.emit(build_name))
	card.set_meta(&"entry", StringName(build_name))
	return card


## One entry an addon registered. The tooltip is the addon's own hint.
func _addon_card(entry: Dictionary) -> Button:
	var key := str(entry.get("key", ""))
	var icon_path := str(entry.get("icon", ""))
	var icon: Texture2D = null
	if icon_path != "" and ResourceLoader.exists(icon_path):
		icon = load(icon_path) as Texture2D
	# A provider entry without art gets a generated tile (its kind's silhouette, a colour from its
	# label), so a pack that ships no icons still has a grid that reads. A hook's item has no kind.
	if icon == null and str(entry.get("kind", "")) != "":
		icon = PlaygroundIcons.for_provider(str(entry.get("kind", "")), str(entry.get("label", key)))
	var card := _card(icon, str(entry.get("label", key)), str(entry.get("hint", "")))
	card.pressed.connect(func() -> void: addon_item_chosen.emit(key))
	card.set_meta(&"entry", StringName(key))
	return card


func _builds_empty_text() -> String:
	if not builds_available:
		return "Builds are kept by a server. Join one to save and load them."
	return "No saved builds yet. Build something, then type pg_save <name> in chat."


func _set_setting(key: String, value: Variant) -> void:
	var values: Dictionary = tool_settings.get(tool_mode, {})
	values[key] = value
	tool_settings[tool_mode] = values
	tool_mode_chosen.emit(tool_mode, values.duplicate())


## Everything on the current tab, before the category and the search are applied.
func _all_in_tab() -> Array:
	if _is_pack_tab():
		return _rows_of_open_pack()

	if _tab == Tab.WEAPONS:
		return _own_weapons()

	if _tab == Tab.BUILDS:
		return builds

	if _is_provider_tab(_tab):
		return _provider_items(_tab)

	if _tab == Tab.ADDONS:
		# Weapons and NPCs of a provider have tabs of their own; the rest (and the hooks') stay here.
		var rest: Array = []
		for entry: Dictionary in addon_items:
			if not str(entry.get("kind", "")) in PROVIDER_TAB_KINDS:
				rest.append(entry)
		return rest

	if _tab == Tab.TOOLS:
		return _tools()

	if catalogue == null:
		return []

	return _catalogue_defs(
		PlaygroundSpawnables.Kind.ENTITY if _tab == Tab.ENTITIES else PlaygroundSpawnables.Kind.PROP
	)


## The catalogue's definitions of one kind that belong on a tab, in menu order.
func _catalogue_defs(wanted: PlaygroundSpawnables.Kind) -> Array:
	var out: Array = []

	for def in catalogue.props:
		# A balloon is the tool gun's and a pickup is the weapons tab's right click: in the
		# catalogue so the spawner can count and limit them, not on a tab to be placed.
		if (
			PlaygroundSpawnables.kind_of(def) == wanted and not bool(def.meta.get("hidden", false))
			and not def.meta.has("pack")
		):
			out.append(def)

	# A profile's `menu: sort`; the catalogue's own order breaks ties.
	var at := {}
	for i in out.size():
		at[out[i]] = i
	out.sort_custom(func(a: DotPropDef, b: DotPropDef) -> bool:
		var sa := int(a.meta.get("menu_sort", 0))
		var sb := int(b.meta.get("menu_sort", 0))
		return sa < sb or (sa == sb and at[a] < at[b]))

	return out


## The game's own weapons: a pack's have a tab of their own.
func _own_weapons() -> Array[PlaygroundWeaponDef]:
	var out: Array[PlaygroundWeaponDef] = []
	for weapon in weapons:
		if not weapon.meta.has("pack"):
			out.append(weapon)
	return out


func _count_in_category(category: StringName) -> int:
	var count := 0

	for entry in _all_in_tab():
		if _category_of(entry) == category:
			count += 1

	return count


func _category_of(entry: Variant) -> StringName:
	if entry is Dictionary and (entry as Dictionary).has("pack_title"):
		return StringName(str((entry as Dictionary).get("category", "")))
	if entry is Dictionary and (entry as Dictionary).has("key"):
		return StringName(str((entry as Dictionary).get("category", "")))
	if entry is Dictionary:
		return &"custom props" if bool((entry as Dictionary).get("custom", false)) else &"builds"
	if entry is Object and not (entry is PlaygroundWeaponDef) and not (entry is DotPropDef):
		return &"tools"
	return (
		(entry as PlaygroundWeaponDef).category
		if entry is PlaygroundWeaponDef
		else (entry as DotPropDef).category
	)


func _name_of(entry: Variant) -> String:
	if entry is Dictionary and (entry as Dictionary).has("pack_title"):
		return str((entry as Dictionary).get("name", ""))
	if entry is Dictionary and (entry as Dictionary).has("key"):
		return str((entry as Dictionary).get("label", ""))
	if entry is Dictionary:
		return str((entry as Dictionary).get("name", ""))
	if entry is Object and not (entry is PlaygroundWeaponDef) and not (entry is DotPropDef):
		return str((entry as Object).get("display_name"))
	return (
		(entry as PlaygroundWeaponDef).name_or_id()
		if entry is PlaygroundWeaponDef
		else (entry as DotPropDef).name_or_id()
	)


func _id_of(entry: Variant) -> StringName:
	if entry is Dictionary and (entry as Dictionary).has("pack_title"):
		return (entry as Dictionary).get("id", &"") as StringName
	if entry is Dictionary and (entry as Dictionary).has("key"):
		return StringName(str((entry as Dictionary).get("key", "")))
	if entry is Dictionary:
		return StringName(str((entry as Dictionary).get("name", "")))
	if entry is Object and not (entry is PlaygroundWeaponDef) and not (entry is DotPropDef):
		return (entry as Object).get("id")
	return (
		(entry as PlaygroundWeaponDef).id
		if entry is PlaygroundWeaponDef
		else (entry as DotPropDef).id
	)


## One of each tool gun mode. Built once: a mode is a name, a description and a schema here.
func _tools() -> Array:
	if _tool_modes.is_empty():
		for script in SwepToolgun.MODES:
			var made: Object = script.new()
			_tool_modes.append(made)

			if not tool_settings.has(made.get("id")):
				tool_settings[made.get("id")] = (made.get("settings") as Dictionary).duplicate()

	return _tool_modes


func _tool_for(id: StringName) -> Object:
	for mode in _tools():
		if mode.get("id") == id:
			return mode
	return null


## The entries the grid should show: the search if there is one, else the category. The search
## spans the whole tab, not the selected category (a player typing "barrel" wants the barrel), but
## not other tabs: a weapon in a prop search is a surprise.
func _visible() -> Array:
	var pool := _all_in_tab()

	if _search != "":
		var needle := _search.to_lower()
		var found: Array = []

		for entry in pool:
			if (
				_name_of(entry).to_lower().contains(needle)
				or String(_id_of(entry)).to_lower().contains(needle)
			):
				found.append(entry)

		return found

	if _category == ALL:
		return pool

	var out: Array = []

	for entry in pool:
		if _category_of(entry) == _category:
			out.append(entry)

	return out


## The ids the grid is currently showing, in order. Read off the buttons themselves.
func shown() -> Array[StringName]:
	var out: Array[StringName] = []

	if _grid == null:
		return out

	for child in _grid.get_children():
		if child.has_meta(&"entry"):
			out.append(child.get_meta(&"entry"))

	return out


## The card for one entry on the current tab, or null when it is not on screen.
func card_for(id: StringName) -> Button:
	if _grid == null:
		return null

	for child in _grid.get_children():
		if child.has_meta(&"entry") and child.get_meta(&"entry") == id:
			return child as Button

	return null


func _key(action: StringName, fallback: String) -> String:
	return str(key_fn.call(action)) if key_fn.is_valid() else fallback
