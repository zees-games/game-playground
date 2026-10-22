extends SceneTree

const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundAddons := preload("../game/playground_addons.gd")
const PlaygroundSpawnMenu := preload("../game/playground_spawn_menu.gd")
const PlaygroundWorkshop := preload("../game/playground_workshop.gd")
const PlaygroundSpawnables := preload("../game/playground_spawnables.gd")
const PlaygroundWeapons := preload("../game/playground_weapons.gd")

## Renders this game's own screens to `screenshots/` so a person can look at them.
##
## Separate from `screenshot.gd`, which renders MAPS. The spawn menu is the screen worth
## the most here: it is this project's own, it is the one a player is in most often, and
## two of the interface bugs in this game's history were in it — a `TabBar` that hid two of
## its three tabs behind scroll arrows, and an NPC silhouette that came out as a coloured
## bar. Neither was reachable from an assertion; both were found by looking.
##
## [b]Not `--headless`[/b]: that gives a null renderer, a 64 x 64 viewport, and frames that
## are empty for a reason that has nothing to do with the code.

const OUT_DIR := "res://screenshots"
const SETTLE := 3

var _stack: DotScreenStack = null
## What a spawn provider hands the menu, as PlaygroundAddons.describe_items makes it.
const PROVIDER_ROWS: Array = [
	{"key": "demo_pack/rifle", "label": "Rifle", "category": "Firearms", "hint": "Rifle - weapon from demo_pack", "kind": "weapon"},
	{"key": "demo_pack/pistol", "label": "Pistol", "category": "Firearms", "hint": "", "kind": "weapon"},
	{"key": "demo_pack/blade", "label": "Combat blade", "category": "Melee", "hint": "", "kind": "weapon"},
	{"key": "demo_pack/guard", "label": "Guard", "category": "Soldiers", "hint": "", "kind": "npc"},
	{"key": "demo_pack/patrol", "label": "Patrol x4", "category": "Soldiers", "hint": "", "kind": "npc"},
	{"key": "demo_pack/sparring_bot", "label": "Sparring bot", "category": "Bots", "hint": "", "kind": "bot"},
]

var _menu: PlaygroundSpawnMenu = null
var _workshop: PlaygroundWorkshop = null
var _presentation: PlaygroundPresentation = null
var _game_menu: DotMenu = null
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _done := false


## What the real linked packs (`addons/zz_*`, gitignored symlinks) put in the Q menu: the rows
## PlaygroundAddons builds from their own providers. Empty when none is linked, and the two shots
## then show the tabs falling back to Props, which is the honest picture of "no pack".
func _real_pack_rows() -> Array:
	var found := PlaygroundAddons.new()
	found.scan_providers(null)
	return found.describe_items()


func _initialize() -> void:
	# Settings to a scratch directory emptied first (see
	# `PlaygroundPresentation.use_scratch_settings`): a render must not save into a player's
	# file, nor draw from whatever the player last saved there.
	var _scratch := PlaygroundPresentation.use_scratch_settings("screenshot_menus")
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	_presentation = PlaygroundPresentation.new()
	_presentation.name = "Presentation"
	root.add_child(_presentation)
	_presentation.setup()

	_stack = DotScreenStack.new()
	_stack.name = "Stack"
	_stack.register_service = false
	_stack.manage_mouse = false
	_stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(_stack)
	_stack.setup()

	# The real catalogues, because a picture of a hand-built list is a picture of a list.
	var menu := PlaygroundSpawnMenu.new()
	menu.name = "SpawnMenu"
	menu.catalogue = PlaygroundSpawnables.with_models(PlaygroundSpawnables.catalogue(), "")
	menu.weapons = PlaygroundWeapons.built_in()
	_stack.register(menu)
	_menu = menu

	# A subscribed weapon pack, as the solo client wires it: the real zee provides.json in a
	# DotContentIndex, followed by the workshop adapter, so the tab is the one a player sees.
	var zee_dir := ProjectSettings.globalize_path("res://").path_join("../zee-dot-weapons").simplify_path()
	var zee_provides: Variant = JSON.parse_string(FileAccess.get_file_as_string(zee_dir.path_join("provides.json")))
	var index := DotContentIndex.new()
	var _zee := index.add_pack({
		"content_id": "gamemann/zee-dot-weapons", "version": "1.0.0", "prefix": zee_dir,
		"session": "solo", "source": "subscription", "provides": zee_provides,
	})
	_workshop = PlaygroundWorkshop.new()
	_workshop.follow(index, menu.catalogue, menu.weapons)
	menu.set_pack_rows(_workshop.rows())

	# The Escape menu the client builds (dot-menu's), over this game's own settings document,
	# and its Tab board with a roster shaped like the one dot-server sends.
	_game_menu = DotMenu.new()
	_game_menu.name = "GameMenu"
	_game_menu.settings = _presentation.settings
	_game_menu.open_on_escape = false
	_game_menu.manage_pointer = false
	root.add_child(_game_menu)
	var _set := _game_menu.setup()
	# As the client does: the console after the menu, so it is one of the menu's overlays.
	_presentation.build_console(_game_menu)
	PlaygroundClient.add_general_rows(_game_menu)
	_game_menu.scoreboard.source = func() -> Dictionary:
		return {
			"server": {"name": "Playground  |  build anything", "map": "pg_flatgrass", "players": 4, "max": 24},
			"you": "2",
			"players": [
				{"id": "1", "name": "gamemann", "score": 42, "seconds": 1840, "ping": 23},
				{"id": "2", "name": "builder_bo", "score": 17, "seconds": 610, "ping": 48},
				{"id": "3", "name": "a_very_long_display_name", "score": 9, "seconds": 95, "ping": 112},
				{"id": "4", "name": "newcomer", "score": 0, "seconds": 12, "ping": -1},
			],
		}

	_shots = [
		{"id": &"spawn_menu", "file": "menu_spawn.png"},
		# The model props: a category chip picked, so the thumbnails and their names are on screen.
		{"id": &"spawn_menu", "file": "menu_props_models.png", "tab": PlaygroundSpawnMenu.Tab.PROPS, "category": &"furniture"},
		# The tools tab with a tool picked, so its settings panel is drawn: the balloon has
		# all three kinds of control — two sliders and a row of colour swatches.
		{"id": &"spawn_menu", "file": "menu_tools.png", "tab": PlaygroundSpawnMenu.Tab.TOOLS, "mode": &"balloon"},
		# The edit mode with a prop selected: the panel holds what that prop IS, as the server
		# sends it — a painted crate, half again as big, frozen, a little heavier.
		{"id": &"spawn_menu", "file": "menu_tool_edit.png", "tab": PlaygroundSpawnMenu.Tab.TOOLS, "mode": &"edit",
			"settings": {"size": 1.5, "colour": "e05252", "frozen": true, "gravity": true, "weight": 2.0, "friction": 0.6, "bounce": 0.25}},
		{"id": &"spawn_menu", "file": "menu_entities.png", "tab": PlaygroundSpawnMenu.Tab.ENTITIES},
		# The Builds tab with a list as a server would send it: two builds and a custom prop.
		{"id": &"spawn_menu", "file": "menu_builds.png", "tab": PlaygroundSpawnMenu.Tab.BUILDS, "builds": [
			{"name": "bridge", "props": 6, "custom": false},
			{"name": "watchtower", "props": 41, "custom": false},
			{"name": "go_kart", "props": 9, "custom": true},
		]},
		# The Addons tab as the hook of natural-disasters fills it.
		{"id": &"spawn_menu", "file": "menu_addons.png", "tab": PlaygroundSpawnMenu.Tab.ADDONS, "addons": [
			{"key": "pg_natural_disasters/tornado", "label": "Tornado", "category": "Disasters", "hint": ""},
			{"key": "pg_natural_disasters/thunderstorm", "label": "Thunderstorm", "category": "Disasters", "hint": ""},
			{"key": "pg_natural_disasters/earthquake", "label": "Earthquake", "category": "Disasters", "hint": ""},
			{"key": "pg_natural_disasters/blizzard", "label": "Blizzard", "category": "Disasters", "hint": ""},
			{"key": "pg_natural_disasters/wind", "label": "Wind", "category": "Disasters", "hint": ""},
		]},
		{"id": &"spawn_menu", "file": "menu_provider_weapons.png", "tab": PlaygroundSpawnMenu.Tab.PACK_WEAPONS, "addons": PROVIDER_ROWS},
		{"id": &"spawn_menu", "file": "menu_provider_npcs.png", "tab": PlaygroundSpawnMenu.Tab.NPCS, "addons": PROVIDER_ROWS},
		{"id": &"spawn_menu", "file": "menu_real_packs_weapons.png", "tab": PlaygroundSpawnMenu.Tab.PACK_WEAPONS, "addons": _real_pack_rows()},
		{"id": &"spawn_menu", "file": "menu_real_packs_npcs.png", "tab": PlaygroundSpawnMenu.Tab.NPCS, "addons": _real_pack_rows()},
		{"id": &"spawn_menu", "file": "menu_tools_waypoint.png", "tab": PlaygroundSpawnMenu.Tab.TOOLS, "mode": &"waypoint"},
		{"id": &"spawn_menu", "file": "menu_tools_npc.png", "tab": PlaygroundSpawnMenu.Tab.TOOLS, "mode": &"npc_spawn"},
		{"id": &"game_menu", "file": "menu_general.png", "page": &"general"},
		# The same page scrolled to its end: the sandbox's rows and the camera motion sliders.
		{"id": &"game_menu", "file": "menu_general_end.png", "page": &"general", "scroll_end": true},
		{"id": &"game_menu", "file": "menu_video.png", "page": &"video"},
		{"id": &"game_menu", "file": "menu_audio.png", "page": &"audio"},
		{"id": &"game_menu", "file": "menu_controls.png", "page": &"controls"},
		{"id": &"board", "file": "menu_scoreboard.png"},
		# The console, open: DotConsoleKit's panel, on the layer it puts it on.
		# The first pack tab, after Addons: zee's weapons grouped by the pack's own categories.
		{"id": &"spawn_menu", "file": "menu_pack_weapons.png", "tab": PlaygroundSpawnMenu.Tab.size()},
		{"id": &"console", "file": "console.png"},
	]


func _process(_delta: float) -> bool:
	if _done:
		return true

	if _at >= _shots.size():
		_done = true
		return false

	var shot: Dictionary = _shots[_at]

	if _wait == SETTLE and StringName(shot["id"]) == &"console":
		_stack.clear()
		_game_menu.close_all()
		_game_menu.scoreboard.close()
		# `help` only: a setting typed here would be written to this machine's settings.
		var _ran := _presentation.console.submit("help")
		var _opened := _presentation.console.open()
	elif _wait == SETTLE and StringName(shot["id"]) in [&"game_menu", &"board"]:
		_stack.clear()
		_game_menu.close_all()
		if StringName(shot["id"]) == &"board":
			_game_menu.scoreboard.open()
		else:
			_game_menu.open(StringName(shot["page"]))
	elif _wait == SETTLE:
		_stack.clear()
		if _game_menu != null:
			_game_menu.close_all()
			# The scoreboard is not one of close_all's pages: left open it drew over the
			# next menu shot.
			_game_menu.scoreboard.close()

		var opened := _stack.push(StringName(shot["id"]))

		if not opened.ok:
			# Said out loud rather than saved as a grey rectangle. A picture of an empty
			# viewport is indistinguishable from a renderer that is not working, which is
			# exactly how dot-ui's unopened pause menu looked.
			push_error("could not open '%s': %s" % [shot["id"], opened.error.message])
			_at += 1
			return false

		if shot.has("tab") and _menu != null:
			if shot.has("mode"):
				_menu.tool_mode = shot["mode"]
			if shot.has("settings"):
				_menu.set_tool_settings(StringName(shot["mode"]), shot["settings"])
				_menu.set_edit_target("Crate")
			if shot.has("addons"):
				_menu.addon_items = shot["addons"]
			if shot.has("builds"):
				_menu.builds = shot["builds"]
			_menu.show_tab(shot["tab"])
			_menu.refresh()
			if shot.has("category"):
				_menu.set("_category", shot["category"])
			# The grid too: two frames on one tab do not change tab, and the card picked for
			# the last frame would stay lit.
			_menu.call("_rebuild_grid")
			_menu.call("_rebuild_settings")

	if _wait == 1 and bool(shot.get("scroll_end", false)):
		for found in _game_menu.find_children("*", "ScrollContainer", true, false):
			var scroll := found as ScrollContainer
			if scroll.is_visible_in_tree():
				scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)

	if _wait > 0:
		_wait -= 1
		return false

	var image := root.get_texture().get_image()
	var path := OUT_DIR.path_join(str(shot["file"]))
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_at += 1
	_wait = SETTLE
	return false
