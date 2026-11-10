extends "res://game/playground_spawn_menu_cards.gd"



func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	# One palette for the whole menu from dot-ui's theme, rounder than the default: every
	# widget below inherits it, and the few that need more (cards, tabs, the panel) take
	# their boxes from PlaygroundMenuStyle so a changed accent changes all of them.
	_palette = DotUiTheme.dark()
	_palette.corner = 12.0
	_palette.accent = Style.ACCENT
	theme = _palette.build()

	# A dim backdrop, so the menu reads as something in front of the world rather
	# than as a panel floating in it. It is also what stops a click in the margin
	# reaching the physics gun — the client guards that too, and both are cheap next
	# to punting a crate while reaching for the search box.
	var scrim := ColorRect.new()
	scrim.name = "Scrim"
	scrim.color = Color(0.02, 0.03, 0.05, 0.62)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scrim)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	# `set_anchors_and_offsets_preset`, not `set_anchors_preset`: the second sets the
	# anchors and leaves the offsets alone, so a Control built in code keeps the zero
	# size it was created with and the whole menu lays out inside nothing while being,
	# by every property, correctly configured. dot-ui had five of these.
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = 96.0
	_panel.offset_top = 56.0
	_panel.offset_right = -96.0
	_panel.offset_bottom = -88.0
	_panel.add_theme_stylebox_override("panel", Style.panel())
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 22)
	_panel.add_child(margin)

	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.add_theme_constant_override("separation", 14)
	margin.add_child(rows)

	rows.add_child(_build_header())
	rows.add_child(_rule())

	var body := HBoxContainer.new()
	body.name = "Body"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 20)
	rows.add_child(body)

	body.add_child(_build_sidebar())
	body.add_child(_build_grid())

	rows.add_child(_rule())

	_footer = HBoxContainer.new()
	_footer.name = "Footer"
	_footer.add_theme_constant_override("separation", 6)
	rows.add_child(_footer)

	_open_motion()


## A hairline between the header, the body and the footer.
func _rule() -> Control:
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.07)
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


## The panel rises a little and the scrim fades up, each time the menu opens.
func _open_motion() -> void:
	if not animated:
		return
	_panel.pivot_offset = Vector2(size.x * 0.5, size.y)
	_panel.scale = Vector2(0.97, 0.97)
	_panel.modulate.a = 0.0
	_ease(_panel, "scale", Vector2.ONE, 0.22)
	_ease(_panel, "modulate:a", 1.0, 0.18)


func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 18)

	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", Style.box(Style.ACCENT * Color(1, 1, 1, 0.2), 12.0, Style.ACCENT * Color(1, 1, 1, 0.5), 1, Vector2(9, 9)))
	var mark := TextureRect.new()
	mark.texture = Style.icon("cube", 22, Style.ACCENT.lightened(0.3))
	mark.custom_minimum_size = Vector2(22, 22)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_child(mark)
	header.add_child(badge)

	var heading := VBoxContainer.new()
	heading.add_theme_constant_override("separation", -2)
	var title := Label.new()
	title.text = "Spawn"
	title.add_theme_font_override("font", Style.bold(0.5))
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Style.TEXT)
	heading.add_child(title)
	_subtitle = Label.new()
	_subtitle.add_theme_font_size_override("font_size", 12)
	_subtitle.add_theme_color_override("font_color", Style.FAINT)
	heading.add_child(_subtitle)
	header.add_child(heading)

	_tabs = TabBar.new()
	_tabs.name = "Tabs"
	# `clip_tabs` off, and it is not cosmetic: on — which is the default — a TabBar
	# reports a minimum width of about one tab, hides the rest behind scroll arrows,
	# and lets the HBox lay the title out underneath it. Two of the three tabs were
	# unreachable and the heading was drawn through. Only a screenshot shows it.
	_tabs.clip_tabs = false
	_tabs.size_flags_vertical = Control.SIZE_SHRINK_END
	# In `Tab` order. "Pack Weapons" rather than "Weapons": the game's own weapons tab has that name.
	for tab_title in ["Props", "Entities", "NPCs", "Weapons", "Pack Weapons", "Tools", "Builds", "Addons"]:
		_tabs.add_tab(tab_title)
	_sync_provider_tabs()
	_sync_pack_tabs()
	_style_tabs(_tabs)
	_sync_tab_icons()
	_tabs.tab_changed.connect(_on_tab_changed)
	header.add_child(_tabs)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_search_box = LineEdit.new()
	_search_box.name = "Search"
	_search_box.placeholder_text = "Search props, weapons, tools"
	_search_box.custom_minimum_size = Vector2(280.0, 0.0)
	_search_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_search_box.clear_button_enabled = true
	_search_box.right_icon = Style.icon("search", 16, Style.FAINT)
	_search_box.add_theme_stylebox_override("normal", Style.box(Style.SURFACE, 20.0, Style.LINE, 1, Vector2(16, 8)))
	_search_box.add_theme_stylebox_override("focus", Style.box(Style.SURFACE_HOVER, 20.0, Style.ACCENT, 2, Vector2(16, 8)))
	_search_box.text_changed.connect(_on_search_changed)
	# Enter puts the keyboard back where the player expects it. Without it there is no
	# way out of the search box that is not the mouse, and W still types a W.
	_search_box.text_submitted.connect(
		func(_text: String) -> void: _search_box.release_focus()
	)
	header.add_child(_search_box)

	return header


func _on_push() -> void:
	# Rebuilt on every open rather than once. The catalogue is replaced outright when
	# an operator points `props_path` somewhere else and reloaded on a map change, and
	# a menu built once shows a list the server has stopped offering — every click on
	# which is refused with "no such prop".
	refresh()

	# A card takes focus, not the search box: see SEARCH_KEY.
	if _first_card != null and _first_card.is_inside_tree():
		_first_card.grab_focus()


## Rebuilds the category list, the grid and the footer.
func refresh() -> void:
	_rebuild_categories()
	_rebuild_grid()
	_rebuild_settings()
	_rebuild_footer()
	_sync_hand()
	_sync_tab_icons()
	if _subtitle != null:
		_subtitle.text = _tab_blurb()

	if _npc_weapon_row != null:
		_npc_weapon_row.visible = _tab == Tab.ENTITIES


## One quiet line under the title: the open tab and how much is on it.
func _tab_blurb() -> String:
	var name_of_tab := _tabs.get_tab_title(_tabs.current_tab) if _tabs != null else ""
	return "%s  /  %d items" % [name_of_tab, _all_in_tab().size()]


func _on_tab_changed(index: int) -> void:
	_tab = index as Tab
	# The category and the search are per tab. Carrying "containers" onto the weapons
	# tab would show nothing and read as the tab being broken.
	_category = ALL
	_search = ""

	if _search_box != null:
		_search_box.text = ""

	# Asked every time the tab opens rather than once: a build saved a minute ago with
	# `pg_save` should be on the tab the next time it is looked at.
	if _tab == Tab.BUILDS:
		builds_opened.emit()

	refresh()


## Replaces the pack rows and the pack tabs with them. A pack that went (an online session hides every
## solo pack) takes its tab with it, and an open one falls back to Props rather than showing nothing.
func set_pack_rows(rows: Array[Dictionary]) -> void:
	pack_rows = rows
	var was_open := _pack_title()
	# Asked before the bars change: removing the selected tab makes the TabBar move itself to a
	# neighbour, so asking afterwards finds an ordinary tab and the fallback never runs.
	var was_pack := _is_pack_tab()
	_sync_pack_tabs()
	if _grid == null:
		return
	if was_pack and not _pack_titles.has(was_open):
		_tabs.current_tab = int(Tab.PROPS)
		return
	refresh()


## What the server says this player has saved. Redraws the tab when it is open.
func set_builds(list: Array) -> void:
	builds = list
	if _tab == Tab.BUILDS and _grid != null:
		refresh()


func _rebuild_categories() -> void:
	for child in _categories.get_children():
		child.queue_free()

	_add_category(ALL, "All", _all_in_tab().size())

	for category_name in _categories_for_tab():
		var id := StringName(category_name)
		_add_category(
			# A pack names its own categories ("NPCs"), which capitalize() would break into "Np Cs".
			id, category_name if _tab == Tab.ADDONS or _is_provider_tab(_tab) else category_name.capitalize(),
			_count_in_category(id)
		)


func _add_category(id: StringName, text: String, count: int) -> void:
	var button := Button.new()
	button.text = text
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.toggle_mode = true
	button.button_pressed = id == _category
	button.clip_text = true
	_style_pill(button, id == _category)
	button.pressed.connect(func() -> void:
		_category = id
		# The search and the category are one filter, not two: a search that survived
		# a category click would show results from a category the player has just
		# navigated away from, which reads as the click doing nothing.
		_search = ""
		if _search_box != null:
			_search_box.text = ""
		_rebuild_categories()
		_rebuild_grid()
	)

	# The count sits at the right edge as a dim number, drawn over the button.
	var number := Label.new()
	number.text = str(count)
	number.add_theme_font_size_override("font_size", 12)
	number.add_theme_color_override("font_color", Style.FAINT)
	number.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	number.offset_right = -12.0
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	number.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	number.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(number)
	_categories.add_child(button)


# --- The grid ---------------------------------------------------------------

func _rebuild_grid() -> void:
	for child in _grid.get_children():
		child.queue_free()

	_first_card = null

	var visible_now := _visible()

	for entry in visible_now:
		var card: Button

		if _is_pack_tab():
			card = _pack_card(entry as Dictionary)
		elif _tab == Tab.WEAPONS:
			card = _weapon_card(entry as PlaygroundWeaponDef)
		elif _tab == Tab.BUILDS:
			card = _build_card(entry as Dictionary)
		elif _tab == Tab.ADDONS or _is_provider_tab(_tab):
			card = _addon_card(entry as Dictionary)
		elif _tab == Tab.TOOLS:
			card = _tool_card(entry as Object)
		else:
			card = _prop_card(entry as DotPropDef)

		_grid.add_child(card)
		_reveal(card, _grid.get_child_count() - 1)

		if _first_card == null:
			_first_card = card

	if _empty != null:
		_empty.visible = visible_now.is_empty()
		_empty.text = (
			"Nothing matches '%s'." % _search if _search != ""
			else _builds_empty_text() if _tab == Tab.BUILDS
			else "No addon has registered anything. Put one with a playground_hook.gd in addons/." if _tab == Tab.ADDONS
			else "Nothing here."
		)


func _prop_card(def: DotPropDef) -> Button:
	var card := _card(
		PlaygroundIcons.for_def(def),
		def.name_or_id(),
		"%s\n%s · %.0f kg · costs %d" % [
			def.name_or_id(),
			DotPropDef.Size.keys()[def.size].capitalize(),
			def.mass,
			def.cost,
		]
	)

	# A model prop names who made it: a licence read off a README is not a credit in the game.
	var credit: Variant = def.meta.get("credit", {})
	if credit is Dictionary and not (credit as Dictionary).is_empty():
		card.tooltip_text += "\nBy %s (%s)" % [
			str((credit as Dictionary).get("author", "?")), str((credit as Dictionary).get("licence", "?"))
		]

	card.pressed.connect(_on_prop_pressed.bind(def.id))
	if def.id == selected:
		_style_card(card, true)
	# The id on the button, so `shown()` and `card_for()` read what is actually on
	# screen rather than re-running the filter. A second copy of a filter is a second
	# thing that can disagree with the first, and the one that would be wrong is the
	# one nobody is looking at.
	card.set_meta(&"entry", def.id)

	return card


func _weapon_card(def: PlaygroundWeaponDef) -> Button:
	var sprite := PlaygroundWeaponIcons.shared.menu_texture(PlaygroundZee.zee_id(def)) if PlaygroundZee.is_zee(def) else null
	var card := _card(
		sprite if sprite != null else PlaygroundIcons.for_weapon(def),
		def.name_or_id(),
		"%s\n%s" % [def.name_or_id(), def.description]
	)

	card.pressed.connect(_on_weapon_pressed.bind(def.id))
	card.set_meta(&"entry", def.id)

	# Right click puts one on the ground instead — a weapon to hand to somebody, or to
	# leave for whoever walks past. Only the zee weapons: a tool gun lying in the road is
	# not a thing anybody wants.
	if PlaygroundZee.is_zee(def):
		card.tooltip_text += "\nRight click to drop one on the ground."
		card.gui_input.connect(func(event: InputEvent) -> void:
			var click := event as InputEventMouseButton
			if click != null and click.pressed and click.button_index == MOUSE_BUTTON_RIGHT:
				weapon_spawn_requested.emit(def.id)
				card.accept_event()
		)

	return card


## One thing a pack provides. Weapons are equipped, everything else is spawned, through the same
## signals the built-in tabs use, so nothing downstream knows a pack was involved.
func _pack_card(row: Dictionary) -> Button:
	var id := row.get("id", &"") as StringName
	var icon := row.get("icon") as Texture2D
	var def: Variant = row.get("def")
	if icon == null and def is PlaygroundWeaponDef:
		icon = PlaygroundIcons.for_weapon(def as PlaygroundWeaponDef)
	elif icon == null and def is DotPropDef:
		icon = PlaygroundIcons.for_def(def as DotPropDef)
	var card := _card(icon, str(row.get("name", id)), str(row.get("tip", "")))
	if row.get("kind") == &"weapon":
		card.pressed.connect(_on_weapon_pressed.bind(id))
	else:
		card.pressed.connect(_on_prop_pressed.bind(id))
	card.set_meta(&"entry", id)
	return card


func _tool_card(mode: Object) -> Button:
	var id: StringName = mode.get("id")
	var card := _card(
		Style.icon(Style.tool_glyph(id), 40, Style.ACCENT.lightened(0.2) if id == tool_mode else Style.DIM),
		str(mode.get("display_name")), str(mode.get("description"))
	)
	card.toggle_mode = true
	card.button_pressed = id == tool_mode
	_style_card(card, id == tool_mode)
	card.pressed.connect(_on_tool_pressed.bind(id))
	card.set_meta(&"entry", id)
	return card


func _on_tool_pressed(id: StringName) -> void:
	tool_mode = id
	_rebuild_grid()
	_rebuild_settings()
	_rebuild_footer()
	tool_mode_chosen.emit(id, (tool_settings.get(id, {}) as Dictionary).duplicate())


## The picked tool's settings, drawn from its schema: a slider per number, a tick box per
## switch, swatches per colour, a list per choice. Every change is sent at once — a
## settings panel with an Apply button is one where the tool does the wrong thing until
## somebody notices the button.
func _rebuild_settings() -> void:
	if _settings_box == null:
		return

	for child in _settings_box.get_children():
		child.queue_free()

	_settings_box.visible = _tab == Tab.TOOLS
	_settings_card.visible = _tab == Tab.TOOLS

	if _tab != Tab.TOOLS:
		return

	var mode := _tool_for(tool_mode)

	if mode == null:
		return

	var title := Label.new()
	title.text = "%s — %s" % [str(mode.get("display_name")), str(mode.get("description"))]
	title.add_theme_font_override("font", Style.bold(0.3))
	title.add_theme_font_size_override("font_size", 15)
	_settings_box.add_child(title)

	var help := Label.new()
	help.text = "   ".join(mode.call("help_lines"))
	help.add_theme_color_override("font_color", Style.DIM)
	help.add_theme_font_size_override("font_size", 12)
	_settings_box.add_child(help)

	if tool_mode == &"edit":
		var target := Label.new()
		target.text = ("Selected: %s" % edit_target_name) if edit_target_name != "" \
			else "Nothing selected. Click a prop with the tool gun."
		target.modulate = Color(0.55, 0.85, 1.0) if edit_target_name != "" else Color(1, 1, 1, 0.55)
		_settings_box.add_child(target)

	var values: Dictionary = tool_settings.get(tool_mode, {})

	for field in mode.call("schema"):
		_settings_box.add_child(_setting_row(field, values))


func _setting_row(field: Dictionary, values: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var key: String = field["key"]

	var label := Label.new()
	label.text = str(field["label"])
	label.custom_minimum_size = Vector2(110, 0)
	label.add_theme_color_override("font_color", Style.DIM)
	row.add_child(label)

	match str(field["type"]):
		"float":
			_float_setting(row, key, field, values)
		"bool":
			var tick := CheckBox.new()
			tick.button_pressed = bool(values.get(key, field["default"]))
			tick.toggled.connect(func(on: bool) -> void: _set_setting(key, on))
			row.add_child(tick)
		"colour":
			_colour_setting(row, key, field, values)
		"choice":
			_choice_setting(row, key, field, values)

	return row


## A slider with a drawn track and its value beside it.
func _float_setting(row: HBoxContainer, key: String, field: Dictionary, values: Dictionary) -> void:
	var slider := HSlider.new()
	slider.min_value = float(field["min"])
	slider.max_value = float(field["max"])
	slider.step = float(field.get("step", 0.05))
	slider.value = float(values.get(key, field["default"]))
	slider.custom_minimum_size = Vector2(220, 0)
	# A track, drawn. The theme here draws a slider as its grabber alone, and a lone
	# dot gives no sense of where in the range a value is — a rendered frame showed
	# "Lift" and "String" as two dots floating beside their numbers.
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.12)
	track.content_margin_top = 2.0
	track.content_margin_bottom = 2.0
	track.set_corner_radius_all(2)
	var filled := StyleBoxFlat.new()
	filled.bg_color = Style.ACCENT
	filled.content_margin_top = 2.0
	filled.content_margin_bottom = 2.0
	filled.set_corner_radius_all(2)
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", filled)
	slider.add_theme_stylebox_override("grabber_area_highlight", filled)
	var shown := Label.new()
	shown.text = "%.2f" % slider.value
	slider.value_changed.connect(func(value: float) -> void:
		shown.text = "%.2f" % value
		_set_setting(key, value)
	)
	row.add_child(slider)
	row.add_child(shown)

## One swatch per option, the chosen one ringed.
func _colour_setting(row: HBoxContainer, key: String, field: Dictionary, values: Dictionary) -> void:
	for hex in field.get("options", []):
		var swatch := Button.new()
		swatch.custom_minimum_size = Vector2(28, 28)
		swatch.tooltip_text = "#%s" % hex
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color.html(str(hex))
		fill.set_border_width_all(3 if str(values.get(key, "")) == str(hex) else 1)
		fill.border_color = Color.WHITE if str(values.get(key, "")) == str(hex) else Color(1, 1, 1, 0.2)
		fill.set_corner_radius_all(14)
		swatch.add_theme_stylebox_override("normal", fill)
		swatch.add_theme_stylebox_override("hover", fill)
		swatch.pressed.connect(func() -> void:
			_set_setting(key, str(hex))
			_rebuild_settings()
		)
		row.add_child(swatch)

## A drop-down over the options, zee weapons shown by name.
func _choice_setting(row: HBoxContainer, key: String, field: Dictionary, values: Dictionary) -> void:
	var list := OptionButton.new()
	var options: Array = field.get("options", [])
	for option in options:
		var def := PlaygroundZee.find_def(StringName(str(option)))
		list.add_item(def.name_or_id() if def != null else str(option))
		list.set_item_metadata(list.item_count - 1, str(option))
		if str(option) == str(values.get(key, field["default"])):
			list.select(list.item_count - 1)
	list.item_selected.connect(func(index: int) -> void:
		_set_setting(key, str(list.get_item_metadata(index)))
	)
	row.add_child(list)

## Puts [param values] in as tool [param id]'s settings without sending them anywhere: what the
## server says a selected prop IS, for the edit mode. The panel is redrawn only when something
## differs from what it shows, because the server answers every change a slider makes and a
## redraw mid-drag would take the slider out from under the mouse.
## Says which prop the edit mode has selected (empty: none), redrawing the panel if it is up.
func set_edit_target(prop_name: String) -> void:
	if prop_name == edit_target_name:
		return
	edit_target_name = prop_name
	if tool_mode == &"edit":
		_rebuild_settings()


func set_tool_settings(id: StringName, values: Dictionary) -> void:
	var had: Dictionary = tool_settings.get(id, {})
	var differs := false

	for key in values:
		var a: Variant = had.get(key)
		var b: Variant = values[key]
		if (a is float or a is int) and (b is float or b is int):
			differs = differs or not is_equal_approx(float(a), float(b))
		else:
			differs = differs or str(a) != str(b)

	tool_settings[id] = values.duplicate()

	if differs and id == tool_mode:
		_rebuild_settings()


## Switches tab from code, as a click on the tab bar would.
func show_tab(tab: Tab) -> void:
	if _tabs != null:
		# Through the TabBar rather than by setting `_tab`, so the bar and the grid
		# cannot disagree about which tab is open.
		_tabs.current_tab = int(tab)
	else:
		_on_tab_changed(int(tab))


# --- Clicks -----------------------------------------------------------------

func _on_search_changed(text: String) -> void:
	_search = text.strip_edges()
	_rebuild_grid()


func _on_prop_pressed(prop_id: StringName) -> void:
	selected = prop_id
	prop_chosen.emit(prop_id)
	_rebuild_footer()


func _on_weapon_pressed(weapon_id: StringName) -> void:
	weapon_chosen.emit(weapon_id)
	_rebuild_footer()


func _rebuild_footer() -> void:
	if _footer == null:
		return

	# The verb follows the tab. "Click to spawn" over a grid of weapons is wrong in
	# the one place a player looks to find out what a click will do — and clicking a
	# weapon really does something different from clicking a prop.
	var verb := "Click to spawn"

	if _is_pack_tab():
		verb = "From %s: click to spawn or equip" % _pack_title()

	match _tab:
		Tab.WEAPONS:
			verb = "Click to equip, right click to drop one"
		Tab.PACK_WEAPONS:
			verb = "Click to be given it"
		Tab.NPCS:
			verb = "Click to spawn it where you are looking"
		Tab.TOOLS:
			verb = "Click a tool, then use it with the tool gun"
		Tab.BUILDS:
			verb = "Click to put a build down in front of you"
		Tab.ADDONS:
			verb = "Click to start it where you are looking"

	for child in _footer.get_children():
		child.queue_free()

	_hint(verb)
	_footer_gap()
	_hint("spawns %s again" % _armed_name(), _key(PlaygroundBindings.SPAWN, "E"))
	_footer_gap()
	_hint("search", "/")
	_footer_gap()
	_hint("hold to peek, tap to pin", _key(PlaygroundBindings.SPAWN_MENU, "Q"))

	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_footer.add_child(fill)
	_hint(name_of_tool(tool), "", "In hand")


## One footer hint: an optional key cap, then a dim sentence. [param lead] goes before it, dim too.
func _hint(text: String, key: String = "", lead: String = "") -> void:
	if lead != "":
		var front := Label.new()
		front.text = lead
		front.add_theme_font_size_override("font_size", 13)
		front.add_theme_color_override("font_color", Style.FAINT)
		_footer.add_child(front)
	if key != "":
		_footer.add_child(Style.keycap(key))
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Style.TEXT if lead != "" else Style.DIM)
	_footer.add_child(label)


func _footer_gap() -> void:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(14.0, 0.0)
	_footer.add_child(gap)


func _armed_name() -> String:
	if selected == &"" or catalogue == null:
		return "nothing"

	var def := catalogue.get_prop(selected)

	return def.name_or_id() if def != null else String(selected)


## What is in the player's hands, for the footer and the HUD.
##
## Static and shared, because the HUD says the same thing in its own corner and two
## spellings of "gravity gun" is the sort of difference nobody notices until a
## screenshot puts them side by side.
static func name_of_tool(tool_id: StringName) -> String:
	match tool_id:
		&"phys":
			return "physics gun"
		&"grav":
			return "gravity gun"
		&"":
			return "nothing"
		_:
			return String(tool_id)


func describe() -> Dictionary:
	var out := super.describe()
	out["tab"] = Tab.keys()[_tab] if int(_tab) < Tab.size() else _pack_title()
	out["pack_tabs"] = Array(_pack_titles)
	out["category"] = String(_category)
	out["shown"] = shown().size()
	out["selected"] = String(selected)
	out["tool_mode"] = String(tool_mode)
	out["npc_weapon"] = String(npc_weapon)
	return out
