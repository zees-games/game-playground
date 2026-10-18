extends DotScreen

const Playground := preload("../playground.gd")

## The server list: what a person sees before they are in a game.
##
## [b]dot-browser is the client half of dot-server's queries, and this is the screen over
## it.[/b] The addon does the asking — DQP over UDP on a desktop, DQP as JSON over a
## WebSocket in a browser, and A2S for the twenty years of tooling that speaks nothing else
## — behind a list model with sources, filters, sorting, favourites and history. Nothing
## here re-implements any of that; what this decides is which sources this game has and
## what a row looks like.
##
## [b]Filtering is local and always will be.[/b] dot-browser is explicit that a filter is
## applied on the client rather than sent to the server, because a server that decided
## which of its own properties to report is a server that reports whatever gets it listed.
##
## [b]Three sources, and only one needs a website.[/b] The servers this person has visited,
## whatever they type, and — when a site is configured — the site's listing of this game's
## servers ([DotBrowserSourceBackbone], website-city's `/api/content/server/list`). The
## listing is off unless `--browser-backbone-url` / `DOT_BROWSER_BACKBONE_URL` names a site:
## a LAN game, a test or a fork must not reach out to a website the moment the list opens.
## It lists addresses only; every row is still asked what it is, like any other.
##
## [b]The map filter is the one thing here that is this game's.[/b] A sandbox server on
## `pg_flatgrass` and one on a custom map are different places to somebody choosing where to
## go, and dot-server reports the running map in a query — so a person who wants one map can
## have only servers on it, without any server having to be asked.

# A screen on a player's machine, where nobody reads a log: the asking is dot-browser's, and it
# logs its own queries. The one thing said here is a site listing that was configured and could
# not be used, which is the operator's mistake rather than the player's.
const CHANNEL := "playground.browser"

const DEFAULT_PORT := 27015

## This game's app on the site, the slug its server pages live under.
const SITE_APP := "playground"

## How often the list refreshes itself while it is open, in seconds.
##
## A list that never refreshes shows a player count from when the window opened, which is
## the one number it is being read for; one that refreshes constantly is a packet to every
## server on it several times a second, which is what a badly written browser looks like
## from the other end.
const REFRESH_INTERVAL := 8.0


signal joined(address: String)


var browser: DotBrowser = null

var _table: DotTableView = null
var _status: Label = null
var _entry: LineEdit = null
var _mode: OptionButton = null
var _rows: Array[DotBrowserEntry] = []
var _selected: int = -1
var _since_refresh: float = 0.0


## Which screen this is on a [DotScreenStack].
func _screen_id() -> StringName:
	return &"servers"


func _ready() -> void:
	# A screen, not a bare Control, so the stack owns the z-order, the input blocking and
	# the mouse mode from one place — which is dot-ui's whole claim and the reason this
	# game does not put the cursor back by hand anywhere.
	blocks_input = true
	mouse_mode = DotScreen.Mouse.VISIBLE
	closable = true

	# `set_anchors_and_offsets_preset`, not `set_anchors_preset`. The anchors describe how
	# a rectangle follows its parent and change nothing until something resizes it, so a
	# Control built in code keeps the zero size it was created with — and every child then
	# lays out inside nothing while being, by every property, correctly configured. This
	# family has shipped that twice and dot-ui had five of them.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_start()


func _build() -> void:
	var box := VBoxContainer.new()
	box.name = "List"
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 8)
	add_child(box)

	var title := Label.new()
	title.text = "Servers"
	title.add_theme_font_size_override("font_size", 24)
	box.add_child(title)

	_table = DotTableView.new()
	_table.name = "Table"
	_table.show_header = true
	_table.max_rows = 64
	var columns: Array[Dictionary] = [
		{"key": &"name", "title": "Server", "width": 4.0},
		{"key": &"mode", "title": "Map", "width": 2.0},
		{"key": &"players", "title": "Players", "align": HORIZONTAL_ALIGNMENT_RIGHT},
		{"key": &"ping", "title": "Ping", "align": HORIZONTAL_ALIGNMENT_RIGHT},
	]
	_table.set_columns(columns)
	_table.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Clicking selects; the button joins. A list where a click joins is a list where a
	# mis-click leaves the menu, and a server browser is somewhere people click about.
	_table.row_activated.connect(func(index: int, _row: Dictionary) -> void:
		_selected = index
		_show_selection()
	)
	box.add_child(_table)

	var row := HBoxContainer.new()
	box.add_child(row)

	_mode = OptionButton.new()
	_mode.add_item("Any map", 0)
	var index := 1

	# [b]From the game's own catalogue, not a written list.[/b] A second list of map ids is
	# a second thing that goes stale, and in this tree it always does.
	for map in Playground.map_catalogue().maps:
		_mode.add_item(map.name_or_id(), index)
		_mode.set_item_metadata(index, String(map.id))
		index += 1

	_mode.item_selected.connect(func(_at: int) -> void: _apply_filter())
	row.add_child(_mode)

	_entry = LineEdit.new()
	_entry.placeholder_text = "host:port"
	_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry.text_submitted.connect(func(text: String) -> void:
		if add_address(text):
			joined.emit(text.strip_edges())
	)
	row.add_child(_entry)

	var add := Button.new()
	add.text = "Add"
	add.pressed.connect(func() -> void: add_address(_entry.text))
	row.add_child(add)

	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(func() -> void: browser.refresh())
	row.add_child(refresh)

	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(_join_selected)
	row.add_child(join)

	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.66, 0.71, 0.78))
	box.add_child(_status)


func _start() -> void:
	browser = DotBrowser.new()
	browser.name = "Browser"
	browser.concurrency = 6
	browser.timeout_ms = 2000
	browser.retries = 1
	# `info` only. A player list per server is a second round trip to every one of them
	# for a column nobody reads until they have picked a row.
	browser.sections = PackedStringArray(["info"])
	browser.register_as = &""
	browser.favourites_path = "user://playground_servers.json"
	add_child(browser)

	browser.start()
	# History and favourites: the only source that needs no tracker. A server you have
	# played on is one you can get back to.
	browser.load_favourites()
	_add_site_listing()

	browser.entry_updated.connect(func(_entry: DotBrowserEntry) -> void: _redraw())
	browser.refresh_finished.connect(func(online: int, total: int) -> void:
		_status.text = "%d of %d answering." % [online, total]
		_redraw()
	)

	if browser.count() == 0:
		# A first run. The address the launcher defaults to, so somebody who has just
		# started a server on this machine sees it rather than an empty list.
		add_address("127.0.0.1:%d" % DEFAULT_PORT)

	browser.refresh()


## Adds the site's listing when one is configured. Absent, the list is exactly what it was.
func _add_site_listing() -> void:
	var made := site_listing()
	if not made.ok:
		DotLog.warn(CHANNEL, "the server listing is misconfigured and was left out", {
			"error": str(made.error)
		})
		return

	if made.value != null:
		browser.add_source(made.value as DotBrowserSourceBackbone)


## The site a deploy bakes in for native builds. Empty means a native client lists no site
## unless `--browser-backbone-url` / `DOT_BROWSER_BACKBONE_URL` names one. Not a constant
## public origin on purpose: no canonical public API origin exists in the family yet, and a
## guess here would ship a LAN build that phones a website. A deploy sets it before the
## browser opens.
static var default_backbone_url: String = ""


## Which site to list, before argv and environment get a say.
##
## [b]On the web the page's own origin[/b], because the site that serves the client also
## answers the listing and same-origin sidesteps CORS; [code]?backbone=[/code] overrides it
## for a client embedded somewhere else. Off the web it is [member default_backbone_url].
## [param probe] stands in for the page in a suite: [code]web[/code], [code]origin[/code],
## [code]query[/code]. The capability is asked of [DotPlatform], never the OS name.
static func resolve_default_site(probe: Dictionary = {}) -> String:
	var web: bool = probe.get("web", DotPlatform.is_web())
	if not web:
		return default_backbone_url

	var query: String = probe.get("query", "") if probe.has("query") else DotWeb.query_param("backbone")
	if query.strip_edges() != "":
		return query.strip_edges()

	var origin: String = probe.get("origin", "") if probe.has("origin") else DotWeb.origin()
	# A page opened from a file or an opaque origin reports "null"; that is no site.
	return origin if origin.begins_with("http") else default_backbone_url


## This game's site listing from the layered config, or [code]success(null)[/code] when no
## site is configured. Order: [code]--browser-backbone-url[/code] > [code]DOT_BROWSER_BACKBONE_URL[/code]
## > [method resolve_default_site] (web: [code]?backbone=[/code] > page origin; native: the
## exported default). Static so a suite can ask without building the window.
static func site_listing(probe: Dictionary = {}) -> DotResult:
	var defaults := DotBrowserBackboneConfig.new()
	defaults.app = SITE_APP
	defaults.backbone_url = resolve_default_site(probe)

	var made := DotBrowserSourceBackbone.from_config(defaults)
	if not made.ok:
		return made

	var source: DotBrowserSourceBackbone = made.value
	return DotResult.success(source if source.is_available() else null)


func _process(delta: float) -> void:
	if browser == null or not visible:
		return

	_since_refresh += delta

	if _since_refresh >= REFRESH_INTERVAL and not browser.is_refreshing():
		_since_refresh = 0.0
		browser.refresh_known()


func add_address(text: String) -> bool:
	var parsed := DotBrowserTarget.parse(text.strip_edges(), DEFAULT_PORT)

	if not parsed.ok:
		_status.text = "That is not an address: %s" % parsed.error.message
		return false

	browser.add_target(parsed.value as DotBrowserTarget)
	browser.refresh()
	return true


## Applies the mode filter, which is the only game-specific thing on this screen.
func _apply_filter() -> void:
	var selected := _mode.get_selected_id()
	var wanted: Variant = _mode.get_item_metadata(_mode.get_item_index(selected))

	# [b]On the model, not in `_redraw`.[/b] `DotBrowserFilter` already knows how to match
	# a game id and how to sort what is left; a screen that filtered its own rows would be
	# a second filter that disagrees with the one favourites are pinned by.
	browser.filter.map = str(wanted) if wanted != null else ""
	_redraw()


func _redraw() -> void:
	_rows = browser.filtered()

	# The selection is an index into a list that has just been rebuilt, and a refresh can
	# reorder it — the default sort is by ping. Dropping it is the honest answer: keeping
	# the index would silently move it onto a different server, and the failure is
	# somebody joining a game they did not choose.
	if _selected >= _rows.size():
		_selected = -1

	var rows: Array[Dictionary] = []

	for entry in _rows:
		rows.append({
			&"name": entry.name if entry.name != "" else entry.target.join_address(),
			&"mode": entry.map if entry.map != "" else entry.game_id,
			&"players": "%d/%d" % [entry.players, entry.max_players],
			&"ping": "%d" % entry.ping_ms if entry.is_online() else "-",
			"colour": (
				Color(0.86, 0.89, 0.94) if entry.is_online()
				else Color(0.55, 0.55, 0.60)
			),
		})

	_table.set_rows(rows)


func _show_selection() -> void:
	if _selected < 0 or _selected >= _rows.size():
		return

	var entry := _rows[_selected]

	if not entry.is_online():
		_status.text = "%s is not answering." % entry.target.join_address()
	elif entry.is_full():
		_status.text = "%s is full (%d/%d)." % [
			entry.name, entry.players, entry.max_players
		]
	else:
		_status.text = "%s — %s, %d of %d, %d ms." % [
			entry.name, entry.map, entry.players, entry.max_players, entry.ping_ms
		]


func _join_selected() -> void:
	if _selected < 0 or _selected >= _rows.size():
		_status.text = "Pick a server first."
		return

	var entry := _rows[_selected]

	# [b]The join address, not the query address.[/b] A server's query port is frequently
	# not the port people connect to — A2S carries the game port separately for exactly
	# that reason — and joining the one it answered on is the most confusing possible
	# failure: the list works, the server is right there, and the connection times out.
	browser.note_connected(entry.key())
	joined.emit(entry.join_address())
