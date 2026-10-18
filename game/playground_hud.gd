extends Control

const Playground := preload("playground.gd")
const PlaygroundGeometry := preload("playground_geometry.gd")
const PlaygroundPlayer := preload("playground_player.gd")

## The playground's HUD: a status line, the tools, the ammo, the hit marks, and a line
## saying what just happened.
##
## [b]No clock of its own.[/b] A run timer is not shipped; when a server adds dot-timer,
## `addons/pg_timer` puts dot-timer's own HUD block (the clock, the split, the speed) in
## [member timer_hud] and adds its parts to the status line through [member status_fn].

## How long a notice stays up, in seconds.
const NOTICE_SECONDS := 4.0

## This game's accent over whichever theme the player picked in the menu: the boost pads'
## amber for a kill and a head, the start pads' green. The plate, the words and their outline
## are the theme's (dark by default; the client hands this HUD to dot-menu's `follow_hud`), so
## a light or high-contrast theme can change them. Set on the HUD too, so a HUD with no menu
## (a suite, a render) has the accent over dot-ui's defaults.
static func piece_theme() -> Theme:
	var t := Theme.new()
	var type := DotHudPiece.THEME_TYPE
	t.set_color(&"highlight", type, PlaygroundGeometry.COLOUR_BOOST)
	t.set_color(&"good", type, PlaygroundGeometry.COLOUR_START)
	return t


## The theme's HUD colours onto a run timer's block (the time, the speed, the strafes), which
## is not a dot-ui piece and so does not read the theme the menu sets on this HUD.
## [param palette] is the menu's; null is the default theme. Kept so a timer block added
## later is themed too.
func apply_theme(palette: DotMenuPalette = null) -> void:
	_palette = palette if palette != null else DotMenuPalette.new()
	if timer_hud != null:
		timer_hud.set("panel_colour", _palette.hud_plate)
		timer_hud.set("neutral_colour", _palette.hud_text)
		timer_hud.set("detail_colour", _palette.hud_detail)
		timer_hud.set("ahead_colour", _palette.hud_ahead)
		timer_hud.set("behind_colour", _palette.hud_behind)
		timer_hud.queue_redraw()


## Puts a run timer's HUD block in, themed. Called by `addons/pg_timer`.
func set_timer_hud(block: Control) -> void:
	timer_hud = block
	add_child(block)
	apply_theme(_palette)


## What is in hand and how much is in it: a zee weapon's magazine and reserve, bottom right.
## Empty with a toy or nothing in hand, which the tool line already names.
var ammo: DotAmmoCounter = null

## Every hit the server confirmed ([method confirm_hit]): a mark round the crosshair, and
## the number on the body. Never the local prediction.
var hit_marker: DotHitMarker = null
## The key an action is on, as bound (`PlaygroundClient.key_for`), for the lines that name one.
var key_fn: Callable = Callable()
var damage_numbers: DotDamageNumbers = null

## A run timer's HUD block (dot-timer's `DotTimerHud`), or null. See [method set_timer_hud].
var timer_hud: Control = null

## `func(player_id) -> PackedStringArray`: a run timer's parts of the status line (the
## track, the checkpoint, PRACTICE). Unset without one.
var status_fn: Callable = Callable()

var _palette: DotMenuPalette = null

var _notice: Label = null
var _status: Label = null
var _tools: Label = null
var _crosshair: DotCrosshair = null
## Through a scoped zee gun at full aim: zee's circle and reticle (the gun is not drawn then).
var scope: ZeeScopeOverlay = null
## Whether the host's DotCrosshair fades while aiming (dot-ui API 5).
var _crosshair_fades: bool = DotAddonApi.build_level("dot_ui") >= 5
var _notice_until: float = 0.0

var playground: Playground = null
var player_id: StringName = &"local"

## The map's time left as the server's vote last described it. Null, or never adopted,
## when nothing has told this HUD anything — offline, where the local map session IS the
## clock that ends the map, and the only case in which it is.
##
## [b]The map session's clock was what this drew, and on a client it is wrong.[/b] A
## client's session starts its own clock when it loads the map and nothing the server
## decides ever reaches it: an extend never arrived, and the deployed `trigger: rtv_only`
## with no limit had this counting down thirty minutes the server did not have.
var clock_view: DotVoteClockView = null

## What the client says is in the player's hands, and what the menu last armed.
##
## Pushed in by [method set_tool] rather than read off the client, because the HUD is
## bound to the SIMULATION — it is built the same way for a spectator and for a
## replay, neither of which has a client holding anything.
##
## A NAME rather than an id: what is in hand may be one of the two built-in guns or
## any weapon the server offers, and the client is the only thing that can say which
## and what it is called.
var tool_name: String = ""
var armed_prop: StringName = &""

## An administrator's `blind`, over the world and under the rest of the HUD.
##
## [b]Under the widgets, on purpose.[/b] A blind takes the game away, not the player's
## bearings: the clock, the notice line and what is in their hands still say the server is
## going on and they are in it, which is what makes it read as "an admin did this" rather
## than as a client that stopped drawing. The menus and the chat box are above the HUD
## altogether.
##
## Black rather than white. A white screen at full brightness is a thing a player can be
## hurt by in a dark room, and taking the picture away is the whole of the point.
var blind_overlay: ColorRect = null

## Seconds a blind takes to come down and to lift. Short, so it is unmistakably on, and
## not instant, so it reads as something done to the screen rather than a frame dropped.
const BLIND_FADE_SEC := 0.25

const BLIND_COLOUR := Color(0.01, 0.01, 0.015)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# Offsets as well as the preset. `set_anchors_preset` does NOT set them, so a
	# Control built in code keeps the zero size it was created with — the whole
	# interface then lays out inside nothing and is invisible while being, by every
	# property, correctly configured. This cost the family a day in dot-ui.
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0

	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# First, so every widget added below draws over it. See [member blind_overlay].
	blind_overlay = ColorRect.new()
	blind_overlay.name = "Blind"
	blind_overlay.color = BLIND_COLOUR
	# Not anchored to this HUD's rect, although this HUD is the full rect today: the
	# reference game's blind was HUD-sized and its first rendered frame showed a sixteen-
	# pixel frame of the world round the edge, because its HUD insets itself by the safe
	# area. Sized to the whole viewport in `present_blind` instead, so a HUD that one day
	# does the same cannot reopen it.
	blind_overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	blind_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blind_overlay.modulate.a = 0.0
	blind_overlay.visible = false
	add_child(blind_overlay)

	_notice = Label.new()
	_notice.name = "Notice"
	_notice.position = Vector2(24.0, 240.0)
	_notice.size = Vector2(700.0, 32.0)
	add_child(_notice)

	_status = Label.new()
	_status.name = "Status"
	_status.position = Vector2(24.0, 276.0)
	_status.size = Vector2(700.0, 32.0)
	add_child(_status)

	_tools = Label.new()
	_tools.name = "Tools"
	_tools.position = Vector2(24.0, 312.0)
	_tools.size = Vector2(700.0, 32.0)
	add_child(_tools)

	# A crosshair, because every tool here is aimed. A physics gun with nothing to
	# aim by is one that picks up whatever happens to be near the middle of the
	# screen, and "why did it grab that one" is the commonest complaint in a sandbox.
	# Under the crosshair and the pieces: the scope is the view, the HUD reads over it.
	scope = ZeeScopeOverlay.new()
	scope.name = "Scope"
	add_child(scope)
	# First child, so drawn first: the run timer and the tool lines read over the black.
	move_child(scope, 0)

	_crosshair = DotCrosshair.new()
	_crosshair.name = "Crosshair"
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Offsets as well as the preset. See the note in the block above: without them
	# the crosshair draws inside a zero-sized rect in the top-left corner.
	_crosshair.offset_left = 0.0
	_crosshair.offset_top = 0.0
	_crosshair.offset_right = 0.0
	_crosshair.offset_bottom = 0.0
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_crosshair)

	theme = piece_theme()

	# Bottom right, where the chat box (bottom left) and a shell's ballot (top right) are
	# not; it dims under a ballot that reaches it, which is the piece's own default.
	ammo = DotAmmoCounter.new()
	ammo.name = "Ammo"
	ammo.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ammo.offset_left = -420.0
	ammo.offset_right = -24.0
	ammo.offset_top = -100.0
	ammo.offset_bottom = -24.0
	add_child(ammo)

	# Full rect, centred on the crosshair; both draw only what the server confirmed.
	damage_numbers = DotDamageNumbers.new()
	damage_numbers.name = "DamageNumbers"
	damage_numbers.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(damage_numbers)

	hit_marker = DotHitMarker.new()
	hit_marker.name = "HitMarker"
	hit_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(hit_marker)

	set_process(true)


## Wires the HUD to a playground and a player.
func bind(p_playground: Playground, p_player: StringName) -> void:
	playground = p_playground
	player_id = p_player

	playground.run_filed.connect(_on_run_filed)
	playground.map_ready.connect(_on_map_ready)

	# A run timer's own block and status parts, and its stage notices.
	if playground.run_timer != null:
		playground.run_timer.call("attach_hud", self, player_id)
	playground.props.refused.connect(
		func(id: StringName, _prop: StringName, reason: String) -> void:
			if id == player_id:
				notice(reason)
	)


## Told by the client what is in the player's hands.
func set_tool(p_tool: String, p_prop: StringName) -> void:
	tool_name = p_tool
	armed_prop = p_prop


## A hit of this player's that the server confirmed (or, offline, this world): the marker
## flashes and the number goes up on [param point]. [param victim] groups hits on one body.
func confirm_hit(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
	if hit_marker == null:
		return
	hit_marker.flash(killed, headshot)
	damage_numbers.add(victim, amount, point, headshot)


func notice(text: String) -> void:
	if _notice == null:
		return

	_notice.text = text
	# Simulated time is not available here and does not need to be: a notice is
	# presentation, and nothing about it is recorded, compared or ranked.
	_notice_until = Time.get_ticks_msec() / 1000.0 + NOTICE_SECONDS


func _process(delta: float) -> void:
	present_blind(delta)

	if playground == null:
		return

	if _notice != null and Time.get_ticks_msec() / 1000.0 > _notice_until:
		_notice.text = ""

	var player: PlaygroundPlayer = playground.players.get(player_id)

	if player == null:
		ammo.clear()
		return

	var held: Variant = player.zee_rig
	show_weapon(held as ZeeWeaponRig if is_instance_valid(held) and held is ZeeWeaponRig else null)

	if _status != null:
		var map := playground.maps.current

		var parts := PackedStringArray([map.name_or_id() if map != null else "-"])

		var time_left := time_left_text(
			clock_view,
			playground.maps.time_limit.formatted_remaining(),
			Time.get_ticks_msec() / 1000.0
		)

		# Nothing at all when the vote has no clock, rather than "no limit": a status line
		# spending a slot on something that is not happening is one a player learns to skip.
		if time_left != "":
			parts.append(time_left)

		parts.append("%d props" % playground.props.world_count())
		parts.append(player.movement_style.display_name if player.movement_style else "-")

		# On the HUD for the same reason: a builder who forgot it was on would wonder why
		# their shots did nothing.
		if player.creative:
			parts.append("CREATIVE")

		# A run timer's parts: the checkpoint, PRACTICE, the track.
		if status_fn.is_valid():
			parts.append_array(status_fn.call(player_id))

		_status.text = "   ·   ".join(parts)

	if _tools != null:
		_tools.text = "   ·   ".join(PackedStringArray([
			tool_name.capitalize() if tool_name != "" else "Nothing",
			"%s armed" % _armed_name(),
			_props_line(),
			"hold %s to spawn" % (str(key_fn.call(&"pg_spawn_menu")) if key_fn.is_valid() else "Q"),
		]))


## Hands the counter what [param rig] holds: the magazine and the reserve (endless when the
## weapon says so), the reserve alone for a weapon that feeds straight from it, the name alone
## for a blade. Public so a check and a render tool can call it. On a connected client the
## rig is the predicting one, which spends the same rounds the server's does.
func show_weapon(rig: ZeeWeaponRig) -> void:
	if ammo == null:
		return

	if rig == null or rig.arsenal == null or rig.arsenal.current() == null:
		ammo.clear()
		return

	var slot := rig.arsenal.current()
	var def := slot.def
	var title := def.display_name if def.display_name != "" else String(def.id).capitalize()

	if def.ammo_type == &"":
		ammo.show_ammo(title, -1, -1)
		return

	var reserve := rig.arsenal.ammo().count(def.ammo_type)

	if def.magazine > 0:
		# Low at a quarter of a magazine, which is when a reload is worth starting.
		ammo.show_ammo(title, slot.magazine, reserve,
			float(slot.magazine) <= float(def.magazine) * 0.25, def.infinite_reserve)
	else:
		ammo.show_ammo(title, reserve, -1, reserve <= 0, false)


## "12/200 props" — the count against this player's props limit, which is the limit a
## builder meets. "no limit" when there is none rather than "/0", which reads as "none".
func _props_line() -> String:
	var used := playground.props.group_count(player_id, DotPropDef.GROUP_PROPS)
	var cap := playground.props.limit_for(player_id, DotPropDef.GROUP_PROPS)
	return "%d/%s props" % [used, str(cap) if cap > 0 else "no limit"]


## Fades [member blind_overlay] toward whether the bound player is blinded.
##
## Read off the player rather than pushed by anybody, because the flag arrives in a
## snapshot on a networked client and is set directly offline, and a HUD that had to be
## told would need telling from two places. Before the `playground == null` return in
## [method _process], so a blind still lifts on a HUD whose player has gone. Public so a
## check can step it.
func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var player: PlaygroundPlayer = playground.players.get(player_id) \
		if playground != null else null
	var want := 1.0 if player != null and player.blinded else 0.0
	blind_overlay.modulate.a = move_toward(
		blind_overlay.modulate.a, want, maxf(delta, 0.0) / BLIND_FADE_SEC
	)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0

	if blind_overlay.visible and is_inside_tree():
		# The whole viewport, in this HUD's own coordinates — whatever the safe area and
		# the interface scale did to where this HUD starts.
		var inverse := get_global_transform().affine_inverse()
		blind_overlay.position = inverse * Vector2.ZERO
		blind_overlay.size = inverse.basis_xform(get_viewport_rect().size)


func _armed_name() -> String:
	if armed_prop == &"" or playground.props.catalogue == null:
		return "nothing"

	var def := playground.props.catalogue.get_prop(armed_prop)

	return def.name_or_id() if def != null else String(armed_prop)


func _on_run_filed(id: StringName, time: float, rank: int, reason: String) -> void:
	if id != player_id:
		return

	if reason != "":
		notice("%s — not recorded: %s" % [Playground.format_time(time), reason])
		return

	notice("%s — rank %d" % [Playground.format_time(time), rank])


func _on_map_ready(map: DotMapDef) -> void:
	notice("Now playing %s" % map.name_or_id())


## What the status line says about the map's time left: the server's clock when it has
## said anything — empty when that clock does not exist — and [param local] otherwise.
static func time_left_text(view: DotVoteClockView, local: String, now: float) -> String:
	if view != null and view.known:
		return view.formatted_at(now)

	return local


## A zee gun's aim this frame, from the client: dot-ui's DotCrosshair fades as the gun comes up
## (`set_aim`, API 5, as game-arena's), and a scope replaces it for its own reticle.
func set_aim(fraction: float, scoped: bool) -> void:
	if scope != null:
		scope.fraction = fraction if scoped else 0.0
	if _crosshair != null:
		_crosshair.visible = not scoped
		if _crosshair_fades:
			_crosshair.call(&"set_aim", 0.0 if scoped else fraction)
