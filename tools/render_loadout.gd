extends Node

const PlaygroundArena := preload("../game/playground_arena.gd")
const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")

## Renders a zee gun at the hip and down its sights (an iron sight and a scope), solo B outside
## the arena, and the arena's B menu open, through the real offline client, into
## `screenshots/loadout/`, with a line per frame of the crosshair, the scope and the lens.
##
## [codeblock]
## xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_loadout.tscn
## [/codeblock]
##
## [b]The B menu is opened on the arena's own offer[/b] (`PlaygroundArena.loadout_schema` through
## a `DotLoadoutManager`'s `offer_for`, the dictionary the server's `/loadout` notice carries):
## solo there is no arena, so B there only says so, which is the second frame.

const OUT_DIR := "res://screenshots/loadout"

var _client: PlaygroundClient = null


func _ready() -> void:
	PlaygroundPresentation.use_scratch_settings("render_loadout")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_client = PlaygroundClient.new()
	_client.name = "Client"
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	_client.config = config
	add_child(_client)
	_run.call_deferred()


func _run() -> void:
	await _frames(30)
	_client.mouse_capture_override = true

	for id in [&"zee_carbine", &"zee_bullpup"]:
		if _client.playground.weapon_def(id) == null:
			print("no %s here" % id)
			continue
		_client._set_tool(id)
		_client._aiming = false
		await _seconds(1.2)
		await _shot("%s_hip" % id)
		_client._aiming = true
		await _seconds(0.8)
		await _shot("%s_aimed" % id)
		_client._aiming = false

	# Solo B: the menu is off outside the arena and the client says so.
	_client._set_tool(&"physgun")
	await _seconds(0.5)
	var b := InputEventKey.new()
	b.physical_keycode = KEY_B
	b.keycode = KEY_B
	b.pressed = true
	var _took := _client.game_menu.handle_event(b)
	_client._unhandled_input(b)
	await _seconds(0.3)
	await _shot("b_outside_the_arena")

	# The arena's B: its offer, as the server sends it.
	var loadouts := DotLoadoutManager.new()
	loadouts.schema = PlaygroundArena.loadout_schema(_client.playground.weapons)
	loadouts.register_service = false
	add_child(loadouts)
	var offer: DotResult = await loadouts.offer_for("pg-player-00000001")
	var menu: Object = _client.loadout_menu
	if menu == null or not offer.ok:
		print("no loadout menu, or no offer: %s" % [offer.error if not offer.ok else "menu"])
	else:
		_client._set_arena_on(true)
		menu.call(&"open_offer", offer.value)
		await _seconds(0.6)
		await _shot("b_in_the_arena")
	get_tree().quit(0)


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name])
	var hud: Node = _client.hud
	var cross: Control = hud.get("_crosshair")
	var scope: Control = hud.get("scope")
	print("%s: crosshair %s opacity %.2f, scope %.2f, fov %.1f -> %s" % [shot_name,
		"shown" if cross.visible else "hidden", float(cross.get("aim_opacity")) if "aim_opacity" in cross else -1.0,
		float(scope.get("fraction")), _client.camera.fov, error_string(image.save_png(path))])


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _seconds(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
