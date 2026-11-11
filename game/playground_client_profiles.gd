extends "playground_client_base.gd"


# Profile screen, map-edit toggle and the admin probe, split out of the UI layer to keep files small.


## Offline this process is the server, so it is an admin; connected, the server decides and
## the answer to [method _probe_profile_admin] is remembered for the connection.
func _may_edit_profiles() -> bool:
	return bridge == null or _profile_admin


func _toggle_profiles() -> void:
	if screens == null or profile_screen == null:
		return
	if screens.is_open(&"profiles"):
		screens.pop(&"profiles")
	elif not _menu_is_open():
		_open_profiles()


func _open_profiles() -> void:
	if not _may_edit_profiles():
		_probe_profile_admin()
		return
	if screens == null:
		return
	call(&"_primary_up")
	call(&"_secondary_up")
	_rotating = false
	var _pushed := screens.push(&"profiles")


## F7: the spawn point markers, for staff. Offline this process is the server; on a server the client has neither the points nor the right.
func _toggle_map_edit() -> void:
	if map_edit_view == null:
		map_edit_view = PlaygroundMapEditView.new(self, playground)

	if map_edit_view.active():
		map_edit_view.hide()
		return

	var why := map_edit_view.prepare(bridge == null)

	if why != "":
		if hud != null:
			hud.notice(why)
		return

	map_edit_view.show()


## F8: opens the form of the spawn point the crosshair is on.
func _pick_map_edit() -> void:
	if map_edit_view == null or not map_edit_view.active():
		return

	call(&"_primary_up")
	call(&"_secondary_up")
	_rotating = false
	var _picked := map_edit_view.pick()


## The server answers a harmless request by who asked: an unknown profile for an admin, "needs
## cvar" for anybody else. There is no "am I an admin" message, and this is the cheapest honest one.
func _probe_profile_admin() -> void:
	var link: DotNetProfileLink = presentation.profile_link if presentation != null else null
	if link == null:
		if hud != null:
			hud.notice("Profile editing is not available on this server.")
		return
	if _profile_probing:
		return
	_profile_probing = true
	_mute_profile_replies(true)
	var sent := link.submit(DotProfileRuntime.make_request("reset_key", "npc", "", ""))
	if not sent.ok:
		_profile_probing = false
		_mute_profile_replies(false)


func _on_profile_reply(ok: bool, text: String) -> void:
	if not _profile_probing:
		if profile_screen != null:
			profile_screen.on_reply(ok, text)
		return
	_profile_probing = false
	_profile_admin = not text.begins_with("profile edits need")
	_mute_profile_replies(screens != null and screens.is_open(&"profiles"))
	if _profile_admin:
		_sync_profiles_entry()
		_open_profiles()
	elif hud != null:
		hud.notice("Editing profiles needs the server's cvar admin flag.")


func _mute_profile_replies(on: bool) -> void:
	if presentation != null:
		presentation.mute_profile_replies = on


## The Escape menu's entry, there only for somebody who may use it.
func _sync_profiles_entry() -> void:
	if game_menu == null or game_menu.screen == null:
		return
	var actions: Array = game_menu.screen.actions
	var at := -1
	for i in actions.size():
		if (actions[i] as Dictionary).get("id") == &"profiles":
			at = i
	if _may_edit_profiles() and at < 0:
		actions.insert(1, {"id": &"profiles", "text": "Profile workbench"})
	elif not _may_edit_profiles() and at >= 0:
		actions.remove_at(at)
	else:
		return
	game_menu.screen.restyle(game_menu.kit)
