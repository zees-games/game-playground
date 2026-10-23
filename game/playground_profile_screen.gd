extends DotScreen

const PlaygroundProfiles := preload("playground_profiles.gd")
const Readout := preload("playground_profile_readout.gd")

## The admin workbench in the game: NPC and weapon profiles edited live while the server runs.
##
## Edits are requests (`submit`, the profile link's on a client), never a local apply, so every
## player sees them; the form follows `profile_changed`, so another admin's edit shows here too.
## Spawning a test NPC or giving a weapon is the client's, reached by [signal target_requested].

## "Spawn" or "Give" was pressed for [param kind] (`npc` or `weapon`) and profile [param id].
signal target_requested(kind: String, id: String)
signal profile_opened(kind: String, id: String)

## How long edits are gathered before they are sent, so a slider drag is one request, not fifty.
const FLUSH_SECONDS := 0.12
const NPC_GROUPS := {
	"cost": "Identity", "faction": "Identity", "weight": "Identity", "enabled": "Identity",
	"health": "Vitals", "speed": "Vitals",
	"sight": "Senses", "sight_angle": "Senses", "hearing": "Senses", "los": "Senses", "eye": "Senses",
}
const WEAPON_GROUPS := {
	"enabled": "Identity", "slot": "Identity",
	"magazine": "Ammunition", "reserve": "Ammunition", "reserve_max": "Ammunition",
	"infinite_reserve": "Ammunition", "cost_per_use": "Ammunition",
	"reload_ticks": "Reload", "reload_per_round": "Reload", "reload_start_ticks": "Reload", "auto_reload": "Reload",
	"fire_mode": "Handling", "use_interval_ticks": "Handling", "burst_count": "Handling",
	"burst_interval_ticks": "Handling", "charge_ticks": "Handling", "charge_requires_min": "Handling",
	"min_charge": "Handling", "deploy_ticks": "Handling", "holster_ticks": "Handling",
}
const UNITS := {
	"sight": "m", "hearing": "m", "eye": "m", "sight_angle": "deg", "speed": "m/s",
	"reload_ticks": "ticks", "reload_start_ticks": "ticks", "use_interval_ticks": "ticks",
	"burst_interval_ticks": "ticks", "charge_ticks": "ticks", "deploy_ticks": "ticks", "holster_ticks": "ticks",
}

## `(req: Dictionary) -> DotResult`: where an edit goes. Set by the client.
var submit: Callable = Callable()
var profiles: PlaygroundProfiles = null
var tokens: DotFormTokens = DotFormTokens.dark()
var form: DotUiForm = null

var _kind := ""
var _id := ""
var _pending := {}
var _awaiting: Array[String] = []
var _resync := false
var _bound: DotProfileRuntime = null
var _buttons := {}
var _filter := ""

var _timer: Timer = null
var _side: VBoxContainer = null
var _search: LineEdit = null
var _main: VBoxContainer = null
var _title: Label = null
var _sub: Label = null
var _chips: HBoxContainer = null
var _status: Label = null
var _readout: Label = null
var _last_weapon := ""
var _last_npc := ""
var _target_btn: Button = null
var _reset_btn: Button = null
var _save_btn: Button = null
var _form_slot: Control = null
var _empty: Label = null


func _screen_id() -> StringName:
	return &"profiles"


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	tokens.animate = tokens.animate and not DisplayServer.get_name() == "headless"
	theme = tokens.build_theme()
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = FLUSH_SECONDS
	_timer.timeout.connect(flush)
	add_child(_timer)

	var scrim := ColorRect.new()
	scrim.color = Color(0.02, 0.03, 0.05, 0.62)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = tokens.px(56)
	panel.offset_right = -tokens.px(56)
	panel.offset_top = tokens.px(40)
	panel.offset_bottom = -tokens.px(40)
	panel.add_theme_stylebox_override("panel", _pad(tokens.box(tokens.bg, 20, tokens.border, 1, 3), tokens.sp(5), tokens.sp(4)))
	add_child(panel)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", tokens.sp(3))
	panel.add_child(rows)
	rows.add_child(_build_header())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", tokens.sp(4))
	rows.add_child(body)
	body.add_child(_build_sidebar())
	_main = VBoxContainer.new()
	_main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main.add_theme_constant_override("separation", tokens.sp(3))
	body.add_child(_main)
	_build_main()
	_fill_sidebar()


func _build_header() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", tokens.sp(3))
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 0)
	bar.add_child(col)
	var title := Label.new()
	title.theme_type_variation = &"FormTitle"
	title.text = "Profile workbench"
	col.add_child(title)
	var sub := Label.new()
	sub.theme_type_variation = &"FormCaption"
	sub.text = "Edits go to the server and reach every player at once."
	col.add_child(sub)
	var close := Button.new()
	close.theme_type_variation = &"FormGhost"
	close.text = "Close"
	close.custom_minimum_size.y = tokens.target()
	close.pressed.connect(func() -> void: close_requested.emit())
	bar.add_child(close)
	return bar


func _build_sidebar() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = tokens.px(250)
	panel.add_theme_stylebox_override("panel", _pad(tokens.box(tokens.card, 14, tokens.border, 1), tokens.sp(3), tokens.sp(3)))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", tokens.sp(2))
	panel.add_child(col)
	_search = LineEdit.new()
	_search.placeholder_text = "Find a profile"
	_search.clear_button_enabled = true
	_search.custom_minimum_size.y = tokens.target()
	_search.text_changed.connect(func(t: String) -> void:
		_filter = t.strip_edges().to_lower()
		_fill_sidebar())
	col.add_child(_search)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_side = VBoxContainer.new()
	_side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side.add_theme_constant_override("separation", 2)
	scroll.add_child(_side)
	return panel


func _build_main() -> void:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _pad(tokens.box(tokens.card, 14, tokens.border, 1), tokens.sp(4), tokens.sp(3)))
	_main.add_child(card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", tokens.sp(2))
	card.add_child(col)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", tokens.sp(2))
	col.add_child(top)
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.add_theme_constant_override("separation", 0)
	top.add_child(names)
	_title = Label.new()
	_title.theme_type_variation = &"FormTitle"
	names.add_child(_title)
	_sub = Label.new()
	_sub.theme_type_variation = &"FormCaption"
	names.add_child(_sub)
	_target_btn = _button("Spawn in front of me", &"FormPrimary", func() -> void: request_target())
	_reset_btn = _button("Reset all", &"FormGhost", func() -> void: reset_all())
	_save_btn = _button("Save to server", &"FormGhost", func() -> void: save())
	for b in [_target_btn, _reset_btn, _save_btn]:
		top.add_child(b)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", tokens.sp(2))
	col.add_child(line)
	_chips = HBoxContainer.new()
	_chips.add_theme_constant_override("separation", tokens.sp(2))
	line.add_child(_chips)
	_status = Label.new()
	_status.theme_type_variation = &"FormCaption"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_child(_status)

	_readout = Label.new()
	_readout.theme_type_variation = &"FormCaption"
	col.add_child(_readout)

	_form_slot = Control.new()
	_form_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_form_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main.add_child(_form_slot)
	_empty = Label.new()
	_empty.theme_type_variation = &"FormCaption"
	_empty.text = "Pick an NPC or a weapon on the left."
	_empty.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_form_slot.add_child(_empty)
	_set_actions(false)


func _button(text: String, variation: StringName, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.theme_type_variation = variation
	b.custom_minimum_size.y = tokens.target()
	b.pressed.connect(on_press)
	return b


# --- Lifecycle ---------------------------------------------------------------

func _on_push() -> void:
	_bind_runtime()
	_fill_sidebar()
	if _id != "":
		open_profile(_kind, _id)
	elif _search != null:
		_search.release_focus()


func _on_pop() -> void:
	flush()
	if _bound != null and _bound.profile_changed.is_connected(_on_changed):
		_bound.profile_changed.disconnect(_on_changed)
	_bound = null


func _bind_runtime() -> void:
	var rt: DotProfileRuntime = profiles.runtime if profiles != null else null
	if rt == _bound:
		return
	if _bound != null and _bound.profile_changed.is_connected(_on_changed):
		_bound.profile_changed.disconnect(_on_changed)
	_bound = rt
	if rt != null:
		rt.profile_changed.connect(_on_changed)


func _process(_delta: float) -> void:
	if _resync and _pending.is_empty() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_resync = false
		_sync_form()


# --- The list ------------------------------------------------------------------

## The ids shown for [param kind]: every profile the runtime can edit.
func ids(kind: String) -> PackedStringArray:
	var set := _profile_set(kind)
	return set.list_ids() if set != null else PackedStringArray()


## `[{id, group, sort, label}]` for [param kind], grouped and ordered as the Q menu does.
func entries(kind: String) -> Array:
	var set := _profile_set(kind)
	var out: Array = []
	if set == null:
		return out
	for id in set.list_ids():
		var res := set.load_profile(id)
		if not res.ok:
			continue
		var p: DotProfile = res.value
		var menu: Dictionary = p.get_value("menu", {})
		var group := str(menu.get("category", ""))
		if group == "":
			group = str(p.get_value("faction", "")) if kind == "npc" else "weapons"
		var label := str(p.get_value("name", ""))
		out.append({"id": id, "group": group.capitalize(), "sort": int(menu.get("sort", 0)),
			"label": label if label != "" else id})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["group"] != b["group"]:
			return a["group"] < b["group"]
		return a["sort"] < b["sort"] or (a["sort"] == b["sort"] and a["id"] < b["id"]))
	return out


func _profile_set(kind: String) -> DotProfileSet:
	if profiles == null:
		return null
	match kind:
		"npc":
			return profiles.npcs
		"weapon":
			return profiles.weapons
	return null


func _fill_sidebar() -> void:
	if _side == null:
		return
	for c in _side.get_children():
		_side.remove_child(c)
		c.queue_free()
	_buttons.clear()
	for kind in ["npc", "weapon"]:
		var list := entries(kind)
		var shown := list.filter(func(e: Dictionary) -> bool:
			return _filter == "" or _filter in str(e["id"]).to_lower() or _filter in str(e["label"]).to_lower())
		_side.add_child(_caption("NPCS" if kind == "npc" else "WEAPONS", true))
		if list.is_empty():
			_side.add_child(_caption("none loaded", false))
		var group := ""
		for e: Dictionary in shown:
			if e["group"] != group:
				group = e["group"]
				_side.add_child(_caption(group, false))
			var b := _list_button(kind, e)
			_side.add_child(b)
			_buttons["%s/%s" % [kind, e["id"]]] = b
	_mark_selection()


func _caption(text: String, major: bool) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = &"FormCaption"
	l.add_theme_color_override("font_color", tokens.accent if major else tokens.text_faint)
	if major:
		var top := Control.new()
		top.custom_minimum_size.y = tokens.sp(2)
		_side.add_child(top)
	return l


func _list_button(kind: String, e: Dictionary) -> Button:
	var b := Button.new()
	var edited := _edited_count(kind, e["id"]) > 0
	b.text = ("%s   ●" % e["label"]) if edited else str(e["label"])
	b.tooltip_text = "%s/%s" % [kind, e["id"]]
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.toggle_mode = true
	b.clip_text = true
	b.custom_minimum_size.y = tokens.target()
	var pad := tokens.sp(3)
	b.add_theme_stylebox_override("normal", _pad(tokens.box(Color.TRANSPARENT, 8), pad, tokens.sp(1)))
	b.add_theme_stylebox_override("hover", _pad(tokens.box(tokens.field_hover, 8), pad, tokens.sp(1)))
	b.add_theme_stylebox_override("focus", _pad(tokens.box(Color.TRANSPARENT, 8, tokens.accent, 2), pad, tokens.sp(1)))
	var on := _pad(tokens.box(Color(tokens.accent, 0.20), 8, tokens.accent, 1), pad, tokens.sp(1))
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_color_override("font_color", tokens.accent if edited else tokens.text)
	for c in ["font_pressed_color", "font_hover_pressed_color", "font_hover_color"]:
		b.add_theme_color_override(c, tokens.text)
	b.pressed.connect(func() -> void: open_profile(kind, e["id"]))
	return b


func _mark_selection() -> void:
	for key in _buttons:
		(_buttons[key] as Button).set_pressed_no_signal(key == "%s/%s" % [_kind, _id])


# --- Opening and the form --------------------------------------------------------------

func current_kind() -> String:
	return _kind


func current_id() -> String:
	return _id


## Opens [param id] of [param kind] (`npc` or `weapon`) in the form. Pending edits go out first.
func open_profile(kind: String, id: String) -> DotResult:
	var set := _profile_set(kind)
	if set == null:
		return DotResult.fail(DotError.CODE_INVALID, "no profile kind '%s'" % kind)
	if not set.has_id(id):
		return DotResult.fail(DotError.CODE_INVALID, "%s/%s: no such profile" % [kind, id])
	flush()
	var base := _read(set, id, false)
	if base.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "%s/%s does not load" % [kind, id])
	_kind = kind
	_id = id
	_resync = false
	_build_form(kind, id, _schema_for(kind, base))
	_sync_form()
	_mark_selection()
	profile_opened.emit(kind, id)
	return DotResult.success(null)


func _build_form(kind: String, id: String, schema: Array) -> void:
	if form != null:
		_form_slot.remove_child(form)
		form.queue_free()
	if _empty != null:
		_empty.visible = false
	form = DotUiForm.new()
	form.tokens = tokens
	form.compact_below = 640.0
	form.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_form_slot.add_child(form)
	var built := form.build(schema, _read(_profile_set(kind), id, false))
	if not built.ok:
		_say(built.error.message, true)
	form.value_changed.connect(_on_value)
	form.key_reset.connect(_on_key_reset)
	for b in [form.apply_button(), form.revert_button()]:
		if b != null and b.get_parent() != null and b.get_parent().get_parent() != null:
			b.get_parent().get_parent().visible = false
	_set_actions(true)
	_target_btn.text = "Spawn in front of me" if kind == "npc" else "Give me this weapon"


## The profile's values, flattened: schema keys by name, the `extra:` numbers as `extra.<key>`.
## [param live] reads the runtime layer too; false reads the file tiers alone (the reset targets).
func _read(set: DotProfileSet, id: String, live: bool) -> Dictionary:
	var kept := set.runtime_paths(id)
	if not live and not kept.is_empty():
		set.set_runtime(id, {})
	var res := set.load_profile(id)
	if not live and not kept.is_empty():
		set.set_runtime(id, kept)
	if not res.ok:
		return {}
	var p: DotProfile = res.value
	var out: Dictionary = {}
	for k in p.values:
		if NPC_GROUPS.has(k) or WEAPON_GROUPS.has(k):
			out[k] = p.values[k]
	for k in p.extra:
		if _is_number(p.extra[k]) or p.extra[k] is bool:
			out["extra." + str(k)] = p.extra[k]
	return out


func _is_number(v: Variant) -> bool:
	return v is int or v is float


func _schema_for(kind: String, base: Dictionary) -> Array:
	var set := _profile_set(kind)
	var groups: Dictionary = NPC_GROUPS if kind == "npc" else WEAPON_GROUPS
	var fields: Array = []
	for f: Dictionary in set.schema:
		var name := str(f["name"])
		if not groups.has(name):
			continue
		var d := f.duplicate(true)
		d["group"] = groups[name]
		d["default"] = base.get(name, f["default"])
		if UNITS.has(name):
			d["unit"] = UNITS[name]
		fields.append(d)
	var extras: Array = []
	for key in base:
		if not str(key).begins_with("extra."):
			continue
		var v: Variant = base[key]
		var short := str(key).substr(6)
		var d := {"name": key, "label": short.capitalize(), "default": v,
			"group": "Weapon numbers" if kind == "weapon" else "Tuning"}
		if v is bool:
			d["type"] = "bool"
		elif v is int:
			d["type"] = "int"
			d["min"] = 0
			d["max"] = maxi(100, absi(v) * 4)
		else:
			d["type"] = "float"
			d["min"] = 0.0
			d["max"] = maxf(10.0, absf(v) * 4.0)
		extras.append(d)
	return extras + fields if kind == "weapon" else fields + extras


## Puts the form on what the replicated state holds now.
func _sync_form() -> void:
	if form == null or _id == "":
		return
	var live := _read(_profile_set(_kind), _id, true)
	var res := form.set_values(live)
	if not res.ok:
		_say(res.error.message, true)
	_refresh_chips()


func _refresh_chips() -> void:
	if _chips == null:
		return
	for c in _chips.get_children():
		_chips.remove_child(c)
		c.queue_free()
	if _id == "":
		_sub.text = ""
		return
	var edited := _edited_count(_kind, _id)
	var rev := profiles.runtime.revision(_kind, _id) if profiles != null else 0
	_sub.text = "%s / %s" % [_kind, _id]
	if edited > 0:
		_chips.add_child(_chip("EDITED LIVE   %d key%s" % [edited, "" if edited == 1 else "s"], tokens.accent, true))
	else:
		_chips.add_child(_chip("Defaults", tokens.text_faint, false))
	_chips.add_child(_chip("revision %d" % rev, tokens.text_dim, false))
	_title.text = _id
	for e: Dictionary in entries(_kind):
		if e["id"] == _id:
			_title.text = str(e["label"])
	_reset_btn.disabled = edited == 0
	_save_btn.disabled = edited == 0
	_refresh_readout()


## DPS of the weapon last opened against the health of the NPC last opened, both as live as the form.
func _refresh_readout() -> void:
	if _readout == null:
		return
	if _kind == "weapon":
		_last_weapon = _id
	elif _kind == "npc":
		_last_npc = _id
	if _last_weapon == "":
		_readout.text = "Open a weapon to see DPS and time to kill against %s." % (_last_npc if _last_npc != "" else "a reference target")
		return
	var health := Readout.FALLBACK_HEALTH
	var target := "reference target"
	if _last_npc != "":
		health = float(_read(profiles.npcs, _last_npc, true).get("health", health))
		target = _last_npc
	var stats := Readout.weapon_stats(_read(profiles.weapons, _last_weapon, true), float(Engine.physics_ticks_per_second))
	_readout.text = "%s:  %s" % [_last_weapon, Readout.line(stats, health, target)]


func _chip(text: String, color: Color, solid: bool) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _pad(tokens.box(Color(color, 0.18) if solid else Color.TRANSPARENT, 99, Color(color, 0.7), 1), tokens.sp(3), 3))
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", tokens.px(tokens.font_small))
	l.add_theme_color_override("font_color", color)
	p.add_child(l)
	return p


func _edited_count(kind: String, id: String) -> int:
	var set := _profile_set(kind)
	return set.runtime_paths(id).size() if set != null else 0


func _set_actions(on: bool) -> void:
	for b in [_target_btn, _reset_btn, _save_btn]:
		if b != null:
			b.disabled = not on
			b.visible = on


# --- Edits ---------------------------------------------------------------------------

func _on_value(key: String, value: Variant) -> void:
	_pending[key] = value
	if _timer != null and is_inside_tree():
		_timer.start()


func _on_key_reset(key: String) -> void:
	_pending.erase(key)
	_send("reset_key", key, null)
	if _edited_paths().has(key) == false:
		_sync_form()


func _edited_paths() -> Dictionary:
	var set := _profile_set(_kind)
	return set.runtime_paths(_id) if set != null and _id != "" else {}


## Sends the gathered edits now.
func flush() -> void:
	if _pending.is_empty():
		return
	var batch := _pending.duplicate()
	_pending.clear()
	if _timer != null:
		_timer.stop()
	for key in batch:
		_send("set", str(key), batch[key])


## Puts every key of the open profile back to the file's numbers.
func reset_all() -> void:
	_pending.clear()
	_send("reset", "", null)


## Writes the open profile's live edits to the server layer (needs the root flag).
func save() -> void:
	flush()
	_send("save", "", null)


## Asks the client to spawn the open NPC, or give the open weapon.
func request_target() -> void:
	if _id == "":
		return
	target_requested.emit(_kind, _id)
	_say("Spawned %s in front of you." % _title.text if _kind == "npc" else "Gave you %s." % _title.text, false)


func _send(op: String, key: String, value: Variant) -> void:
	if _id == "" or not submit.is_valid():
		_say("Not connected to a server that takes edits.", true)
		return
	var res: DotResult = submit.call(DotProfileRuntime.make_request(op, _kind, _id, key, value))
	if not res.ok:
		_say("Refused: " + res.error.message, true)
		_sync_form()
		return
	if typeof(res.value) == TYPE_BOOL:
		_awaiting.append(op)
	else:
		_say(_done_text(op), false)


func _done_text(op: String) -> String:
	match op:
		"save":
			return "Saved to the server layer."
		"reset", "reset_key":
			return "Back to the file's numbers."
	return "Live for everyone."


## The server's answer to the oldest request still waiting (the link's `reply`).
func on_reply(ok: bool, text: String) -> void:
	var op: String = _awaiting.pop_front() if not _awaiting.is_empty() else "set"
	if ok:
		_say(_done_text(op), false)
	else:
		_say("Refused: " + text, true)
		_resync = true


func _on_changed(kind: String, id: String, _revision: int) -> void:
	_fill_sidebar()
	if kind == _kind and id == _id:
		_resync = true
		_refresh_chips()


func _say(text: String, bad: bool) -> void:
	if _status == null:
		return
	_status.text = text
	_status.add_theme_color_override("font_color", tokens.danger if bad else tokens.good)


## The status line, for a suite.
func status_text() -> String:
	return _status.text if _status != null else ""


func describe() -> Dictionary:
	var out := super.describe()
	out["profile"] = "%s/%s" % [_kind, _id]
	out["pending"] = _pending.size()
	out["awaiting"] = _awaiting.size()
	return out


func _pad(b: StyleBoxFlat, h: int, v: int) -> StyleBoxFlat:
	b.content_margin_left = h
	b.content_margin_right = h
	b.content_margin_top = v
	b.content_margin_bottom = v
	return b
