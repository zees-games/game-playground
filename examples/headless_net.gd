extends "res://examples/headless_net_part6.gd"

const CHECKS := 403

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total above is the other half — see docs/testing.md.
const SECTIONS := 48

func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var errors := EngineErrors.new()
	OS.add_logger(errors)

	print("game-playground — headless netcode")
	print("")

	_test_command_wire()
	_test_event_wire()
	_test_inventory_wire()

	if await _build():
		await _test_handshake()
		await _test_prediction()
		await _test_local_is_predicted()
		await _test_prop_replication()
		await _test_prop_request()
		await _test_tools()
		await _test_prop_removal()
		await _test_vehicle_over_the_wire()
		await _test_timer()
		await _test_lossy()
		# Last of the tests that need a connected player: both halves share one physics space, so
		# a test that advances the world moves every later reading. This one spawns no body.
		# Run before the vehicle test it made that test flake.
		await _test_weapon_request()
		# After the weapon request for the same reason it is after everything else: this
		# adds a second body to the shared physics space. It takes the body back out again.
		await _test_blind_and_beacon()
		# After the blind and beacon, for the reason that one gives: it adds a body to the
		# shared world and takes it back out.
		await _test_somebody_else_is_drawn()
		_test_clock_wire()
		# Adds no body and moves nothing; it builds the services and takes them down again.
		await _test_chat_end_to_end()
		# The inventory last among the connected-player sections, for the reason every
		# section above gives: the rejoin below takes the player's body out of the shared
		# physics world and puts it back.
		# Before the inventory sections, whose bag it must not find a barrel in.
		await _test_refused_spawn_is_free()
		await _test_inventory_predicted()
		await _test_inventory_refused()
		await _test_inventory_lost()
		await _test_inventory_from_the_server()
		await _test_inventory_is_private()
		await _test_nothing_before_ready()
		await _test_inventory_flood()
		await _test_inventory_rejoin()
		await _test_zee_over_the_wire()
		await _test_toys_over_the_wire()
		# Last but the leave: it resizes the crate and spawns an NPC, and every section above
		# reads a world this would have changed. See its own note.
		await _test_tool_look_and_armed_npcs()
		# Adds no body: a grenade is a ray swept each tick, not a physics object.
		await _test_grenade_over_the_wire()
		await _test_utility_over_the_wire()
		# Spawns a platform and takes it out again; nothing after it but the leave.
		await _test_riding_over_the_wire()
		await _test_button_over_the_wire()
		await _test_builds_over_the_wire()
		await _test_edit_over_the_wire()
		await _test_map_props_over_the_wire()
		await _test_held_over_the_wire()
		await _test_glass_over_the_wire()
		await _test_swimming_over_the_wire()
		await _test_avatars_over_the_wire()
		# Arms a gun and puts it away again; adds no body.
		await _test_drawn_ammo_corrected()
		# Lays the player down and stands them up again; adds no body.
		await _test_downed_over_the_wire()
		# The map's toys: kicks a ball and spins the roundabout, changes map and back. Last but
		# the leave, because a ball it kicks would be in the way of whatever came after.
		await _test_map_toys_over_the_wire()
		await _test_grenade_for_a_joiner()
		await _test_leave()

	_test_the_remote_workbench()

	OS.remove_logger(errors)
	# Engine errors go to stderr and change no exit code: a toy pulled out of the tree after a
	# mid-tick rebuild (dot-net history #30) printed `!is_inside_tree()` on green runs elsewhere.
	var seen := errors.seen()
	_check(seen.is_empty(), "the engine reported no error over the whole run",
		"%d: %s" % [seen.size(), ", ".join(seen.slice(0, 3))])

	_finish()


func _finish() -> void:
	_report_sections(_entered, _completed, SECTIONS, CHECKS)
