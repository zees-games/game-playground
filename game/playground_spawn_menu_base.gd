extends DotScreen


const PlaygroundBindings := preload("playground_bindings.gd")

const PlaygroundWeaponIcons := preload("playground_weapon_icons.gd")
const PlaygroundIcons := preload("playground_icons.gd")
const PlaygroundSpawnables := preload("playground_spawnables.gd")
const Style := preload("playground_menu_style.gd")
const PlaygroundWeaponDef := preload("weapons/playground_weapon_def.gd")
const PlaygroundWeapons := preload("playground_weapons.gd")
const PlaygroundZee := preload("playground_zee.gd")
const SwepToolgun := preload("weapons/swep_toolgun.gd")

## The spawn menu: hold Q, pick something, click it; a quick tap pins it open. It never spawns
## anything itself: it emits, and [PlaygroundClient] asks the server. Props and entities are one
## [DotPropCatalogue] split by [method PlaygroundSpawnables.kind_of]; weapons are their own registry.

# No CHANNEL: a screen, and nothing it draws is an operator's to act on. What a player picks is
# logged where it is acted on — by the spawner, or by the server the bridge asks.

## The pseudo-category that shows everything on a tab. Not a real category.
const ALL := &"__all"

## Card size. Wide enough for "Large crate" on one line at the default font.
const CARD := Vector2(150.0, 112.0)

## The key that puts the caret in the search box. Not "any letter" and not focused on open: that
## sends W, A, S and D into the box while the player walks. A slash is the search-in-a-list
## convention and is not a movement key.
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
var _footer: HBoxContainer = null
var _empty: Label = null
var _first_card: Button = null
var _subtitle: Label = null
var _panel: PanelContainer = null
var _settings_card: PanelContainer = null
var _hand_buttons: Dictionary = {}

## Whether the menu moves: it fades in, cards appear in a quick cascade and ease on hover. Off
## for a still render and for suites, where nothing draws a frame to finish a tween.
var animated: bool = true


func _screen_id() -> StringName:
	return &"spawn_menu"


func _build_sidebar() -> Control:
	var side := VBoxContainer.new()
	side.name = "Sidebar"
	side.custom_minimum_size = Vector2(212.0, 0.0)
	side.add_theme_constant_override("separation", 6)

	side.add_child(Style.section("Categories"))

	var scroll := ScrollContainer.new()
	scroll.name = "CategoryScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(scroll)

	_categories = VBoxContainer.new()
	_categories.name = "Categories"
	_categories.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_categories.add_theme_constant_override("separation", 2)
	scroll.add_child(_categories)

	side.add_child(_build_npc_weapon_row())
	side.add_child(Style.section("In hand"))

	# Ids rather than indices, because the client matches on them and a reordering
	# here would otherwise silently swap two tools.
	var hand := HBoxContainer.new()
	hand.add_theme_constant_override("separation", 6)
	hand.add_child(_hand_button(
		&"phys", "Physics", "magnet", "Physics gun\nHold to carry, scroll for distance, right click to freeze"
	))
	hand.add_child(_hand_button(
		&"grav", "Gravity", "orbit", "Gravity gun\nLeft click punts, right click pulls and carries"
	))
	side.add_child(hand)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	actions.add_child(_action_button("undo", "Undo last\nRemoves the last prop you spawned", &"undo", false))
	actions.add_child(_action_button("snow", "Unfreeze mine\nThaws every prop you have frozen", &"unfreeze", false))
	actions.add_child(_action_button("trash", "Remove mine\nRemoves every prop you own", &"clear", true))
	side.add_child(actions)

	return side


## A tool the player can take in hand; lit while it is the one held.
func _hand_button(id: StringName, text: String, glyph: String, tip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.icon = Style.icon(glyph, 16, Style.DIM)
	button.tooltip_text = tip
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(func() -> void: tool_chosen.emit(id))
	_hand_buttons[id] = button
	_style_ghost(button, false, false)
	return button


## A square icon button for an action; the destructive one reddens when hovered.
func _action_button(glyph: String, tip: String, action: StringName, danger: bool) -> Button:
	var button := Button.new()
	button.icon = Style.icon(glyph, 18, Style.DANGER if danger else Style.DIM)
	button.tooltip_text = tip
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(func() -> void: action_requested.emit(action))
	_style_ghost(button, false, danger)
	return button


## Lights the held tool's button; called whenever the menu is redrawn.
func _sync_hand() -> void:
	for id: StringName in _hand_buttons:
		_style_ghost(_hand_buttons[id] as Button, tool == id, false)


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
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	var inset := MarginContainer.new()
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		inset.add_theme_constant_override("margin_%s" % side, 4)
	scroll.add_child(inset)
	inset.add_child(_grid)

	# Said, rather than left as an empty rectangle. A search with no results and a tab
	# with nothing on it look identical when both are blank, and the player's next
	# move is different in each case.
	_empty = Label.new()
	_empty.name = "Empty"
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.add_theme_color_override("font_color", Style.DIM)
	_empty.add_theme_font_size_override("font_size", 15)
	_empty.custom_minimum_size = Vector2(0.0, 120.0)
	_empty.visible = false
	holder.add_child(_empty)

	# The picked tool's settings, under the grid on the tools tab: what the tool gun's
	# panel was in the sandboxes this is shaped like.
	_settings_box = VBoxContainer.new()
	_settings_box.name = "ToolSettings"
	_settings_box.add_theme_constant_override("separation", 6)
	_settings_box.visible = false
	_settings_card = PanelContainer.new()
	_settings_card.name = "ToolSettingsCard"
	_settings_card.visible = false
	_settings_card.add_theme_stylebox_override("panel", Style.box(Style.SURFACE, Style.RADIUS, Style.LINE, 1, Vector2(16, 12)))
	_settings_card.add_child(_settings_box)
	holder.add_child(_settings_card)

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


## A card: a lifted plate with the thumbnail on it, lighter when hovered, outlined in the
## accent when focused (the arrow keys and a gamepad move focus, so it has to show). An armed
## card (the prop the spawn key repeats, the tool mode in use) wears the accent fill.
func _style_card(button: Button, armed: bool = false) -> void:
	var pad := Vector2(8, 10)
	var plate := Style.box(Style.ACCENT * Color(1, 1, 1, 0.16), Style.CARD_RADIUS - 2.0, Style.ACCENT, 2, pad) if armed \
		else Style.box(Style.SURFACE, Style.CARD_RADIUS - 2.0, Style.LINE, 1, pad)
	button.add_theme_stylebox_override("normal", plate)
	button.add_theme_stylebox_override("hover", Style.box(Style.SURFACE_HOVER, Style.CARD_RADIUS - 2.0, Style.ACCENT * Color(1, 1, 1, 0.65), 1, pad))
	button.add_theme_stylebox_override("pressed", Style.box(Style.ACCENT * Color(1, 1, 1, 0.22), Style.CARD_RADIUS - 2.0, Style.ACCENT, 2, pad))
	button.add_theme_stylebox_override("hover_pressed", Style.box(Style.ACCENT * Color(1, 1, 1, 0.28), Style.CARD_RADIUS - 2.0, Style.ACCENT, 2, pad))
	button.add_theme_stylebox_override("focus", Style.box(Color(0, 0, 0, 0), Style.CARD_RADIUS - 2.0, Style.ACCENT, 2, pad))
	button.add_theme_constant_override("icon_max_width", 60)
	button.add_theme_constant_override("h_separation", 0)
	button.add_theme_constant_override("outline_size", 0)
	button.add_theme_font_override("font", Style.bold(0.25))
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_color_override("font_color", Style.TEXT)
	for state in ["font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)


## A quiet button for the sidebar: a faint plate, lit with the accent while [param on].
func _style_ghost(button: Button, on: bool, danger: bool) -> void:
	var pad := Vector2(10, 8)
	var tint := Style.DANGER if danger else Style.ACCENT
	var plate := Style.box(Style.ACCENT * Color(1, 1, 1, 0.20), 10.0, Style.ACCENT, 1, pad) if on \
		else Style.box(Style.SURFACE, 10.0, Style.LINE, 1, pad)
	button.add_theme_stylebox_override("normal", plate)
	button.add_theme_stylebox_override("hover", Style.box(tint * Color(1, 1, 1, 0.22), 10.0, tint * Color(1, 1, 1, 0.6), 1, pad))
	button.add_theme_stylebox_override("pressed", Style.box(tint * Color(1, 1, 1, 0.34), 10.0, tint, 1, pad))
	button.add_theme_stylebox_override("focus", Style.box(Color(0, 0, 0, 0), 10.0, tint, 2, pad))
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_color_override("font_color", Style.TEXT if on else Style.DIM)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_constant_override("h_separation", 7)


## A category row: a faint rail, the accent as a fill and a bar on the left while chosen.
func _style_pill(button: Button, on: bool = false) -> void:
	var pad := Vector2(12, 7)
	var fill := Style.box(Style.ACCENT * Color(1, 1, 1, 0.17) if on else Color(1, 1, 1, 0.0), 10.0, Color.TRANSPARENT, 0, pad)
	if on:
		fill.border_color = Style.ACCENT
		fill.border_width_left = 3
	button.add_theme_stylebox_override("normal", fill)
	button.add_theme_stylebox_override("pressed", fill)
	button.add_theme_stylebox_override("hover", Style.box(Style.ACCENT * Color(1, 1, 1, 0.24) if on else Color(1, 1, 1, 0.06), 10.0, Color.TRANSPARENT, 0, pad))
	button.add_theme_stylebox_override("hover_pressed", Style.box(Style.ACCENT * Color(1, 1, 1, 0.26), 10.0, Color.TRANSPARENT, 0, pad))
	button.add_theme_stylebox_override("focus", Style.box(Color(0, 0, 0, 0), 10.0, Style.ACCENT, 2, pad))
	button.add_theme_font_size_override("font_size", 14)
	button.add_theme_color_override("font_color", Style.TEXT if on else Style.DIM)
	for state in ["font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)


## Tabs as an underlined strip: text and icon, the accent under the open one.
func _style_tabs(bar: TabBar) -> void:
	var pad := Vector2(14, 9)
	var open := Style.box(Color(0, 0, 0, 0), 0.0, Style.ACCENT, 0, pad)
	open.border_width_bottom = 2
	bar.add_theme_stylebox_override("tab_selected", open)
	bar.add_theme_stylebox_override("tab_hovered", Style.box(Color(1, 1, 1, 0.05), 8.0, Color.TRANSPARENT, 0, pad))
	bar.add_theme_stylebox_override("tab_unselected", Style.box(Color(0, 0, 0, 0), 0.0, Color.TRANSPARENT, 0, pad))
	bar.add_theme_stylebox_override("tab_focus", Style.box(Color(0, 0, 0, 0), 8.0, Style.ACCENT, 2, pad))
	bar.add_theme_color_override("font_selected_color", Color.WHITE)
	bar.add_theme_color_override("font_unselected_color", Style.DIM)
	bar.add_theme_color_override("font_hovered_color", Style.TEXT)
	bar.add_theme_font_size_override("font_size", 14)
	bar.add_theme_constant_override("h_separation", 8)
	bar.add_theme_constant_override("icon_max_width", 16)


## The glyph a tab wears: its own for the built-in ones, a parcel for a pack's.
func _tab_glyph(index: int) -> String:
	match index:
		Tab.PROPS: return "cube"
		Tab.ENTITIES: return "bolt"
		Tab.NPCS: return "user"
		Tab.WEAPONS: return "target"
		Tab.TOOLS: return "wrench"
		Tab.BUILDS: return "layers"
		Tab.ADDONS: return "grid"
	return "package"


## Redraws every tab's icon, the open one in the accent. Hidden tabs keep theirs.
func _sync_tab_icons() -> void:
	if _tabs == null:
		return
	for i in _tabs.tab_count:
		var on := i == _tabs.current_tab
		_tabs.set_tab_icon(i, Style.icon(_tab_glyph(i), 16, Style.ACCENT.lightened(0.2) if on else Style.DIM))


## Eases one property to a value, replacing a move already under way on the same node.
func _ease(node: Control, property: String, to: Variant, seconds: float, delay: float = 0.0) -> void:
	# A property path such as "modulate:a" is not a valid meta name, so ":" becomes "_".
	var key := &"ease_" + StringName(property.replace(":", "_"))
	if node.has_meta(key):
		(node.get_meta(key) as Tween).kill()
	var tween := node.create_tween()
	node.set_meta(key, tween)
	tween.tween_property(node, property, to, seconds).set_delay(delay).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)


## A card swells a little under the pointer or the focus ring.
func _wire_hover(card: Control) -> void:
	if not animated:
		return
	card.resized.connect(func() -> void: card.pivot_offset = card.size * 0.5)
	for enter in [card.mouse_entered, card.focus_entered]:
		enter.connect(func() -> void: _ease(card, "scale", Vector2(1.035, 1.035), 0.14))
	for leave in [card.mouse_exited, card.focus_exited]:
		leave.connect(func() -> void: _ease(card, "scale", Vector2.ONE, 0.18))


## Fades a freshly built card in, a few milliseconds after the one before it.
func _reveal(card: Control, index: int) -> void:
	if not animated or not card.is_inside_tree():
		return
	card.modulate.a = 0.0
	_ease(card, "modulate:a", 1.0, 0.18, minf(index, 24) * 0.014)


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
	_sync_tab_icons()


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

