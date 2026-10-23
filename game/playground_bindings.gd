extends RefCounted

## Every key this game reads, as one dot-menu [DotMenuBindings] table: the action, the setting
## that stores it, the words a player sees, the default, and the card it goes on.
##
## [b]A table, because four things read it and they must never disagree:[/b] the client
## matches events against the actions, the settings document stores one binding per row
## ([method DotMenuBindings.add_to_schema], from [method PlaygroundPresentation.schema]), the
## Escape menu's Controls page draws a key button per row, and the help screen (H) lists
## them with the key each is on now. Until 2026-10-11 every one of these was a keycode in
## `PlaygroundClient._unhandled_input`, which no page could show or move.
##
## [b]R is two things on purpose, so it is one row.[/b] With a gun in hand (the tool gun
## counts) it reloads, otherwise it unfreezes everything you own; two rows on one default
## would be a conflict the table's swap cannot finish.
##
## [b]Escape is in no row[/b]: it is the menu, and how a browser lets go of the pointer.

const SPAWN := &"pg_spawn"
const SPAWN_MENU := &"pg_spawn_menu"
const UNDO := &"pg_undo"
const ROTATE := &"pg_rotate"
const RELOAD := &"pg_reload"
const VEHICLE := &"pg_vehicle"
const PHYS_GUN := &"pg_phys_gun"
const GRAV_GUN := &"pg_grav_gun"
const WEAPONS := &"pg_weapons"
const TRACK := &"pg_track"
const STYLE := &"pg_style"
## Down a zee gun's sights while held (right mouse, the family's Aim row). With a tool or a toy
## in hand the right button is still its secondary (freeze, pull, a mode's second button).
const AIM := &"pg_aim"
## A zee gun's quick melee, which was its right button until the button aimed: the middle one.
const BASH := &"pg_bash"
## M is dot-menu's map menu (`dot_menu_maps`): the map list solo, the server's (a change or a
## vote) online. Kept on `bind_map`, the setting it was stored under, so a key a player moved
## stays moved.
const MAP := &"dot_menu_maps"
const CHECKPOINT_SAVE := &"pg_checkpoint_save"
const CHECKPOINT_LOAD := &"pg_checkpoint_load"
const CHECKPOINT_NEXT := &"pg_checkpoint_next"
const CHECKPOINT_CLEAR := &"pg_checkpoint_clear"
const VOICE_GAG := &"voice_gag"
const VOICE_MUTE := &"voice_mute"
const VIEW := &"pg_view"
## The admin workbench (live NPC and weapon profile edits); only an admin is let in.
const PROFILES := &"pg_profiles"
const SCOREBOARD := &"pg_scoreboard"
## The chat box's own actions (`PlaygroundPresentation`'s `DotChatWindow`).
const CHAT := &"playground_chat"
const CHAT_NEAR := &"playground_chat_near"


static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	keys.add_movement()

	keys.add(SPAWN_MENU, &"bind_spawn_menu", "Spawn menu (hold, or press to pin it open)", "Q", "Building")
	keys.add(SPAWN, &"bind_spawn", "Spawn what is armed", "E", "Building")
	keys.add(UNDO, &"bind_undo", "Undo your last spawn", "Z", "Building")
	keys.add(ROTATE, &"bind_rotate", "Turn the held prop with the mouse (hold)", "Shift", "Building")
	keys.add(RELOAD, &"bind_reload", "Reload a gun; with none, unfreeze everything yours", "R", "Building")

	keys.add(PHYS_GUN, &"bind_phys_gun", "Physics gun", "1", "Tools")
	keys.add(GRAV_GUN, &"bind_grav_gun", "Gravity gun", "2", "Tools")
	keys.add(WEAPONS, &"bind_weapons", "Next weapon", "3", "Tools")
	# The wheel cycles tools (dot-menu API 10); a held prop keeps it for push and pull.
	keys.add_wheel_weapons(DotMenuBindings.WEAPON_PREVIOUS_ACTION, DotMenuBindings.WEAPON_NEXT_ACTION, "Tools")
	keys.add(VEHICLE, &"bind_vehicle", "Use what you look at, or get in or out of a vehicle", "F", "Tools")
	keys.add(AIM, &"bind_aim", "Aim down a gun's sights (hold)", "Mouse 2", "Tools")
	keys.add(BASH, &"bind_bash", "A gun's quick melee", "Mouse 3", "Tools")

	keys.add(CHECKPOINT_SAVE, &"bind_checkpoint_save", "Save a checkpoint", "C", "Running")
	keys.add(CHECKPOINT_LOAD, &"bind_checkpoint_load", "Go to the checkpoint", "V", "Running")
	keys.add(CHECKPOINT_NEXT, &"bind_checkpoint_next", "Next checkpoint", "X", "Running")
	# G, not B: B is the family's loadout key (dot-menu's DotMenuLoadout), the arena's loadout.
	keys.add(CHECKPOINT_CLEAR, &"bind_checkpoint_clear", "Clear checkpoints", "G", "Running")
	keys.add(STYLE, &"bind_style", "Next movement style", "N", "Running")
	keys.add(TRACK, &"bind_track", "Next timed track on this map", "T", "Running")

	keys.add(VIEW, &"bind_view", "First or third person", "F5", "General")
	keys.add(PROFILES, &"bind_profiles", "Profile workbench (admins): edit NPCs and weapons live", "F6", "General")
	keys.add(MAP, &"bind_map", "Change map", "M", "General")
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "General")
	# The chat keys keep the settings they were stored under before this table existed
	# (declared in `PlaygroundPresentation.schema`, per ACCOUNT, applied there as well).
	keys.add(CHAT, &"chat_open_key", "Chat", "Y", "General", DotSettingsDef.Scope.ACCOUNT)
	keys.add(CHAT_NEAR, &"chat_near_key", "Chat with nearby players", "U", "General", DotSettingsDef.Scope.ACCOUNT)
	# dot-voice's talk action (DotVoiceManager.TALK_ACTION), on K because V is the checkpoint.
	keys.add_voice("General", "K")
	# Look at a player and press (dot-game's DotGameClient): G clears checkpoints, H is help.
	keys.add(VOICE_GAG, &"bind_voice_gag", "Look at a player: stop (or resume) hearing them", "J", "General")
	keys.add(VOICE_MUTE, &"bind_voice_mute", "Look at a player: mute (or unmute) their voice and chat", "L", "General")
	keys.add_help("General")
	# B is the arena's loadout (dot-menu's `dot_menu_loadout`), where the host has it (API 6).
	if DotAddonApi.build_level("dot_menu") >= 6 and keys.has_method(&"add_loadout"):
		var _l: Variant = keys.call(&"add_loadout", "General")
	# Clear checkpoints' default moved from B under saved documents: a player who never touched
	# it follows to G, a key they chose stays.
	return keys.renamed(&"bind_checkpoint_clear", ["B"])
