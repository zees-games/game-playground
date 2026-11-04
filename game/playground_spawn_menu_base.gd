extends DotScreen


const PlaygroundBindings := preload("playground_bindings.gd")

const PlaygroundWeaponIcons := preload("playground_weapon_icons.gd")
const PlaygroundIcons := preload("playground_icons.gd")
const PlaygroundSpawnables := preload("playground_spawnables.gd")
const PlaygroundWeaponDef := preload("weapons/playground_weapon_def.gd")
const PlaygroundWeapons := preload("playground_weapons.gd")
const PlaygroundZee := preload("playground_zee.gd")
const SwepToolgun := preload("weapons/swep_toolgun.gd")

## The spawn menu: hold Q, pick something, click it.
##
## Holding the key opens it, releasing closes it, a quick tap pins it open. Clicking a prop
## spawns it directly, so building is one click per prop and the menu stays open.
##
## Three tabs, two systems: props and entities are one [DotPropCatalogue] split by
## [method PlaygroundSpawnables.kind_of]; weapons are their own registry, because a weapon is
## never spawned and the catalogue requires a scene path.
##
## dot-props ships no menu on purpose; this is this game's own. Its `categories()`,
## `in_category()` and `search()` read [DotPropDef] fields without loading a scene, and the
## icons are drawn from the same fields (see [PlaygroundIcons]), so opening loads nothing.
##
## The menu never spawns anything itself: it emits, and [PlaygroundClient] asks the server.

# No CHANNEL: a screen, and nothing it draws is an operator's to act on. What a player picks is
# logged where it is acted on — by the spawner, or by the server the bridge asks.

## The pseudo-category that shows everything on a tab. Not a real category.
const ALL := &"__all"

## Card size. Wide enough for "Large crate" on one line at the default font.
const CARD := Vector2(146.0, 92.0)

## The key that puts the caret in the search box.
##
## [b]Not "any letter", and not focused on open.[/b] Focusing the search box by default
## sends W, A, S and D into it — the player stands still typing "wasd" while the menu
## looks exactly as it should — and this is a menu you can walk around with. A slash is
## the convention every search-in-a-list uses and it is not a movement key.
const SEARCH_KEY := KEY_SLASH

## The provider kinds that have a tab of their own ([enum Tab]); other kinds stay on Addons.
const PROVIDER_TAB_KINDS: PackedStringArray = ["weapon", "npc", "bot"]

enum Tab {
	PROPS,
	ENTITIES,
	## A spawn provider's npc and bot entries. Hidden until one exists ([method _sync_provider_tabs]).
	NPCS,
	WEAPONS,
	## A spawn provider's weapon entries. Hidden until one exists.
	PACK_WEAPONS,
	TOOLS,
	BUILDS,
	## What the hooks of the addons folder registered. See [PlaygroundAddons].
	ADDONS,
}

## A prop or an entity was clicked. The client turns this into a spawn request.
signal prop_chosen(prop_id: StringName)

## A weapon was clicked. The client equips it.
signal weapon_chosen(weapon_id: StringName)

## One of the two built-in tools was clicked: the physics gun, the gravity gun.
signal tool_chosen(tool_id: StringName)

## Something that is neither — undo, unfreeze everything, clear my props.
signal action_requested(action: StringName)

## A tool gun mode was picked, or one of its settings changed. The client equips the tool
## gun and tells it — itself offline, the server otherwise.
signal tool_mode_chosen(mode: StringName, settings: Dictionary)

## What the NPCs this player spawns should carry: a weapon id, `none`, or empty for each
## NPC's own.
signal npc_weapon_chosen(weapon_id: StringName)

## Right click on a weapon: put one on the ground rather than in hand.
signal weapon_spawn_requested(weapon_id: StringName)

## The Builds tab opened: ask the server for this player's builds, then [method set_builds].
signal builds_opened()

## An addon's entry was clicked: `addon/item`. The client asks the server, or acts directly offline.
signal addon_item_chosen(key: String)

## A saved build was clicked: put it down in front of the player.
signal build_chosen(build_name: String)

## What the props and entities tabs are built from. Set before the first push.
var catalogue: DotPropCatalogue = null

## This player's saved builds, `{name, props, custom}` each — what the server last sent.
## Kept by the server, never by the client: a build outlives the machine it was made on.
var builds: Array = []

## Whether anything can answer for builds. Off with no server (offline play keeps none).
var builds_available: bool = true

## The Addons tab's rows: dictionaries with `key`, `label`, `category` and `hint`, from
## [method PlaygroundAddons.describe_items]. Plain data so the menu never holds an addon's object.
var addon_items: Array = []:
	set(value):
		addon_items = value
		_sync_provider_tabs()

## What the weapons tab is built from.
var weapons: Array[PlaygroundWeaponDef] = []

## What subscribed packs offer ([method PlaygroundWorkshop.rows]): a tab per `pack_title`, after the
## Addons tab, holding every kind that pack provides. Plain rows, so the menu names no addon type.
var pack_rows: Array[Dictionary] = []

## The tabs after [constant Tab.ADDONS], one per pack. A pack tab's index is `Tab.size() + position`.
var _pack_titles: PackedStringArray = PackedStringArray()

## Which prop is armed, so the spawn key and the launcher repeat it.
var selected: StringName = &""

## What is in the player's hands, for the footer.
var tool: StringName = &""

## The tool gun mode picked on the tools tab, and every mode's settings as last set.
var tool_mode: StringName = &"resize"
var tool_settings: Dictionary = {}

## What the tool gun's edit mode has selected, by name, or empty for nothing. Shown above the
## edit mode's settings: a panel of sliders with no prop behind it moves nothing, and has to
## say so.
var edit_target_name: String = ""

## The NPC weapon picked on the entities tab: empty for each NPC's own.
var npc_weapon: StringName = &""

## One of each tool gun mode, for its name, description and settings schema.
## The key an action is on, as the player has it bound (`PlaygroundClient.key_for`). Unset,
## the footer says the defaults.
var key_fn: Callable = Callable()

var _tool_modes: Array = []

var _settings_box: VBoxContainer = null
var _npc_weapon_row: Control = null

var _palette: DotUiTheme = null
var _tab: Tab = Tab.PROPS
var _category: StringName = ALL
var _search: String = ""

var _tabs: TabBar = null
var _categories: VBoxContainer = null
var _grid: GridContainer = null
var _search_box: LineEdit = null
var _footer: Label = null
var _empty: Label = null
var _first_card: Button = null


func _screen_id() -> StringName:
	return &"spawn_menu"


# --- Building ---------------------------------------------------------------

func _build_sidebar() -> Control:
	var side := VBoxContainer.new()
	side.name = "Sidebar"
	side.custom_minimum_size = Vector2(184.0, 0.0)
	side.add_theme_constant_override("separation", 4)

	_categories = VBoxContainer.new()
	_categories.name = "Categories"
	_categories.add_theme_constant_override("separation", 4)
	side.add_child(_categories)

	side.add_child(_build_npc_weapon_row())

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(spacer)

	var heading := Label.new()
	heading.text = "In hand"
	side.add_child(heading)

	# Ids rather than indices, because the client matches on them and a reordering
	# here would otherwise silently swap two tools.
	side.add_child(_flat_button(
		"Physics gun",
		"Hold to carry, scroll for distance, right click to freeze",
		func() -> void: tool_chosen.emit(&"phys")
	))
	side.add_child(_flat_button(
		"Gravity gun",
		"Left click punts, right click pulls and carries",
		func() -> void: tool_chosen.emit(&"grav")
	))

	side.add_child(HSeparator.new())

	side.add_child(_flat_button(
		"Undo last",
		"Removes the last prop you spawned",
		func() -> void: action_requested.emit(&"undo")
	))
	side.add_child(_flat_button(
		"Unfreeze mine",
		"Thaws every prop you have frozen",
		func() -> void: action_requested.emit(&"unfreeze")
	))
	side.add_child(_flat_button(
		"Remove mine",
		"Removes every prop you own",
		func() -> void: action_requested.emit(&"clear")
	))

	return side


func _flat_button(text: String, tip: String, on_press: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.pressed.connect(on_press)
	return button


func _build_grid() -> Control:
	var holder := VBoxContainer.new()
	holder.name = "Holder"
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	holder.add_child(scroll)

	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.columns = 5
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	scroll.add_child(_grid)

	# Said, rather than left as an empty rectangle. A search with no results and a tab
	# with nothing on it look identical when both are blank, and the player's next
	# move is different in each case.
	_empty = Label.new()
	_empty.name = "Empty"
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.visible = false
	holder.add_child(_empty)

	# The picked tool's settings, under the grid on the tools tab: what the tool gun's
	# panel was in the sandboxes this is shaped like.
	_settings_box = VBoxContainer.new()
	_settings_box.name = "ToolSettings"
	_settings_box.add_theme_constant_override("separation", 6)
	_settings_box.visible = false
	holder.add_child(_settings_box)

	return holder


## "NPCs carry: …" — on the entities tab only. What every armed NPC this player spawns
## holds, unless they pick "Their own".
func _build_npc_weapon_row() -> Control:
	var row := VBoxContainer.new()
	row.name = "NpcWeapon"

	var label := Label.new()
	label.text = "NPCs carry"
	row.add_child(label)

	var choice := OptionButton.new()
	choice.name = "Choice"
	choice.add_item("Their own")
	choice.set_item_metadata(0, "")
	choice.add_item("Nothing")
	choice.set_item_metadata(1, "none")

	for def in PlaygroundZee.defs():
		if PlaygroundZee.npc_can_use(def):
			choice.add_item(def.name_or_id())
			choice.set_item_metadata(choice.item_count - 1, String(def.id))

	choice.item_selected.connect(func(index: int) -> void:
		npc_weapon = StringName(str(choice.get_item_metadata(index)))
		npc_weapon_chosen.emit(npc_weapon)
	)
	row.add_child(choice)

	_npc_weapon_row = row
	row.visible = false
	return row


# --- Lifecycle --------------------------------------------------------------

func _on_pop() -> void:
	# The search does not survive being put away. Coming back to a menu still filtered
	# to "boul" from a minute ago reads as a menu with one prop in it.
	_search = ""

	if _search_box != null:
		_search_box.text = ""


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_top or not (event is InputEventKey):
		return

	var key := event as InputEventKey

	if not key.pressed or key.is_echo() or key.physical_keycode != SEARCH_KEY:
		return

	if _search_box != null:
		_search_box.grab_focus()
		_search_box.select_all()

	# Marked handled so the slash does not also arrive as text in the box it just
	# focused, and so the client's own key handling never sees it.
	get_viewport().set_input_as_handled()


# --- Looks ------------------------------------------------------------------

## A rounded box from the palette. A helper because five widgets want one and each wants a
## different fill, border and padding; the StyleBoxFlat defaults are square and borderless.
func _box(
	fill: Color, radius: float, line: Color = Color.TRANSPARENT, line_width: int = 0,
	pad_x: float = 8.0, pad_y: float = 6.0
) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(int(radius))
	box.set_border_width_all(line_width)
	box.border_color = line
	box.content_margin_left = pad_x
	box.content_margin_right = pad_x
	box.content_margin_top = pad_y
	box.content_margin_bottom = pad_y
	return box


## A card: a lifted plate with the thumbnail on it, lighter when hovered, outlined in the
## accent when focused (the arrow keys and a gamepad move focus, so it has to show).
func _style_card(button: Button) -> void:
	var plate := _palette.surface.lightened(0.03)
	button.add_theme_stylebox_override("normal", _box(plate, 12.0, _palette.outline.darkened(0.35), 1, 6.0, 8.0))
	button.add_theme_stylebox_override("hover", _box(_palette.surface_hover, 12.0, _palette.accent.darkened(0.2), 1, 6.0, 8.0))
	button.add_theme_stylebox_override("pressed", _box(_palette.accent.darkened(0.55), 12.0, _palette.accent, 2, 6.0, 8.0))
	button.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), 12.0, _palette.accent, 2, 6.0, 8.0))
	button.add_theme_constant_override("icon_max_width", 56)
	button.add_theme_constant_override("h_separation", 0)
	button.add_theme_font_size_override("font_size", 14)
	for state in ["font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)


## A category chip: a pill, filled with the accent while it is the chosen one.
func _style_pill(button: Button) -> void:
	button.add_theme_stylebox_override("normal", _box(Color(1, 1, 1, 0.04), 16.0, Color.TRANSPARENT, 0, 12.0, 5.0))
	button.add_theme_stylebox_override("hover", _box(Color(1, 1, 1, 0.09), 16.0, Color.TRANSPARENT, 0, 12.0, 5.0))
	button.add_theme_stylebox_override("pressed", _box(_palette.accent.darkened(0.3), 16.0, Color.TRANSPARENT, 0, 12.0, 5.0))
	button.add_theme_stylebox_override("hover_pressed", _box(_palette.accent.darkened(0.2), 16.0, Color.TRANSPARENT, 0, 12.0, 5.0))
	button.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), 16.0, _palette.accent, 2, 12.0, 5.0))
	for state in ["font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)


func _style_tabs(bar: TabBar) -> void:
	bar.add_theme_stylebox_override("tab_selected", _box(_palette.accent.darkened(0.25), 16.0, Color.TRANSPARENT, 0, 16.0, 6.0))
	bar.add_theme_stylebox_override("tab_hovered", _box(Color(1, 1, 1, 0.08), 16.0, Color.TRANSPARENT, 0, 16.0, 6.0))
	bar.add_theme_stylebox_override("tab_unselected", _box(Color(1, 1, 1, 0.03), 16.0, Color.TRANSPARENT, 0, 16.0, 6.0))
	bar.add_theme_stylebox_override("tab_focus", _box(Color(0, 0, 0, 0), 16.0, _palette.accent, 2, 16.0, 6.0))
	bar.add_theme_color_override("font_selected_color", Color.WHITE)
	bar.add_theme_color_override("font_unselected_color", _palette.text_dim)
	bar.add_theme_color_override("font_hovered_color", _palette.text)
	bar.add_theme_constant_override("h_separation", 6)


# --- Tabs and categories ----------------------------------------------------

func _sync_pack_tabs() -> void:
	var titles := PackedStringArray()
	for row in pack_rows:
		var title := str(row.get("pack_title", ""))
		if not titles.has(title):
			titles.append(title)
	_pack_titles = titles
	if _tabs == null:
		return
	while _tabs.tab_count > Tab.size():
		_tabs.remove_tab(_tabs.tab_count - 1)
	for title in titles:
		_tabs.add_tab(title)


## Shows the NPCs and Pack Weapons tabs only while a spawn provider has entries of that kind, and
## falls back to Props when the open one lost its entries. Hidden rather than removed, so the
## tab indices stay the enum's.
func _sync_provider_tabs() -> void:
	if _tabs == null:
		return
	var was_open := _tab
	_tabs.set_tab_hidden(int(Tab.NPCS), _provider_items(Tab.NPCS).is_empty())
	_tabs.set_tab_hidden(int(Tab.PACK_WEAPONS), _provider_items(Tab.PACK_WEAPONS).is_empty())
	if _grid != null and _is_provider_tab(was_open) and _provider_items(was_open).is_empty():
		_tabs.current_tab = int(Tab.PROPS)


static func _is_provider_tab(tab: int) -> bool:
	return tab == int(Tab.NPCS) or tab == int(Tab.PACK_WEAPONS)


## The provider entries a tab lists: weapons on Pack Weapons, npc and bot on NPCs. Any other kind
## stays on the Addons tab with the hooks' items. A hook's own item has no kind.
func _provider_items(tab: int) -> Array:
	var out: Array = []
	for entry: Dictionary in addon_items:
		var kind := str(entry.get("kind", ""))
		if tab == int(Tab.PACK_WEAPONS) and kind == "weapon":
			out.append(entry)
		elif tab == int(Tab.NPCS) and (kind == "npc" or kind == "bot"):
			out.append(entry)
	return out


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


## One card. A [Button] rather than a container, deliberately.
##
## [b]A Button is focusable and a VBoxContainer is not.[/b] Godot's own focus
## neighbours then make the whole grid navigable with a gamepad or the arrow keys for
## free — and a menu that cannot be used without a mouse is the failure dot-ui's
## `initial_focus` exists to prevent. Icon above text is `vertical_icon_alignment`,
## which is exactly what that property is for.
func _card(icon: Texture2D, text: String, tip: String) -> Button:
	var button := Button.new()
	button.icon = icon
	button.text = text
	button.tooltip_text = tip
	button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	# [b]And the icon's own horizontal alignment too.[/b] It defaults to LEFT, and
	# `vertical_icon_alignment` alone puts the icon in the top-LEFT corner and still
	# reserves its width beside the text, so the label is centred in what is left and
	# drawn off-centre under nothing. Every property above reads right; only a
	# rendered frame shows it.
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.custom_minimum_size = CARD
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.clip_text = true
	_style_card(button)
	return button


## A saved build. A custom prop (one welded piece) reads as a thing; a build as a place.
func _build_card(entry: Dictionary) -> Button:
	var build_name := str(entry.get("name", ""))
	var custom := bool(entry.get("custom", false))
	var card := _card(
		null,
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


# --- What is on screen ------------------------------------------------------

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


## The entries the grid should show: the search if there is one, else the category.
##
## [b]The search reaches across the whole tab, not the selected category.[/b] A player
## typing "barrel" wants the barrel, and telling them it does not exist because they
## last clicked "Toys" is the wrong answer to the question they asked. It does not
## reach across tabs, because the tabs are three different kinds of thing and a weapon
## turning up in a prop search is not a result, it is a surprise.
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
