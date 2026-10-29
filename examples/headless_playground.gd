extends "res://examples/headless_playground_part9.gd"

const CHECKS := 776 + 22 + 9 + 10 + 8 + 1 + 4 + 15 + 2 + 1 + 26 + 3 + 2

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total above is the other half — see docs/testing.md.
const SECTIONS := 43

## What `_test_the_run_timer` and `_test_leaderboards` add when dot-timer is linked.
const TIMER_SECTIONS := 2
const TIMER_CHECKS := 14

func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	# The real `PlaygroundClient`s below each build a presentation layer, and that layer's
	# settings go to a scratch directory emptied first, never the player's own file (see
	# `PlaygroundPresentation.use_scratch_settings`).
	var _scratch := PlaygroundPresentation.use_scratch_settings("headless_playground")
	_run.call_deferred()


func _run() -> void:
	print("playground — headless integration")
	print("")

	playground = Playground.new()

	var config := PlaygroundConfig.new()
	# Records in memory: a headless run must not write into the user's data directory.
	config.records_directory = ""
	# No map on boot: the tests below load their own and would race a boot load.
	config.initial_map = &"pg_flatgrass"
	config.map_seconds = 0.0
	playground.config = config

	add_child(playground)

	# Two frames: `_ready` awaits its first map change, so one is not enough to finish booting.
	await get_tree().process_frame
	await get_tree().process_frame

	# `-- --only=<method>` runs the boot and that one section, for working on it: nothing
	# else runs, so the totals are not checked and the exit code is the section's alone.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			await _test_boots()
			await Callable(self, arg.substr(7)).call()
			print("")
			print("ONLY %s: %d passed, %d failed (totals not checked)" % [arg.substr(7), _passed, _failed])
			for line in _failures:
				print("  FAIL  %s" % line)
			get_tree().quit(1 if _failed > 0 else 0)
			return

	await _test_boots()
	await _test_tick_rate_comes_from_the_engine()
	await _test_styles()
	# The two that need dot-timer, run only when linked; skipped, they add to neither total.
	if _timer_linked():
		await _test_the_run_timer()
		await _test_leaderboards()
	else:
		print("")
		print("  SKIP  the run timer and its leaderboards: res://addons/dot_timer is not linked")
	await _test_props()
	await _test_map_change()
	await _test_map_time_limit()
	await _test_props_are_built_from_their_definitions()
	await _test_model_props()
	await _test_entities_run_their_scripts()
	await _test_profiles()
	await _test_profile_workbench()
	await _test_weapons()
	await _test_zee_weapons()
	await _test_limits_per_kind()
	await _test_the_tool_gun()
	await _test_armed_npcs()
	await _test_addon_hook_and_npc_tools()
	await _test_spawn_providers()
	await _test_grenades()
	await _test_spawn_menu()
	await _test_workshop()
	await _test_vehicles()
	await _test_picking_players_up()
	await _test_riding_a_moving_prop()
	await _test_breaking_props()
	await _test_buttons_and_doors()
	await _test_saved_builds()
	await _test_editing_a_selected_prop()
	await _test_the_maps_are_surveyed()
	await _test_nothing_drawn_is_walked_through()
	await _test_a_maps_own_props()
	await _test_toys()
	await _test_every_maps_toys_stand_clear()
	await _test_map_materials()
	await _test_glass()
	await _test_water()
	await _test_ice_slime_foliage()
	await _test_camera_motion()
	await _test_the_client_boots()
	await _test_the_wheel_cycles_tools()
	await _test_noclip_is_a_permission()
	_test_view_cycle()

	var sections := SECTIONS + (TIMER_SECTIONS if _timer_linked() else 0)
	var checks := CHECKS + (TIMER_CHECKS if _timer_linked() else 0)
	_report_sections(_entered, _completed, sections, checks)


## Whether a point is over a box seen from above.
static func _over(at: Vector3, box: AABB) -> bool:
	return (
		at.x >= box.position.x and at.x <= box.end.x
		and at.z >= box.position.z and at.z <= box.end.z
	)


## One tick's motion into [param tally]. A tick that moved further than any run can, a
## metre sideways or up or down in 1/128 s, is a respawn's teleport and is left out.
static func _tally_tick(tally: Dictionary, before: Vector3, after: Vector3, where: String) -> void:
	var flat := Vector2(after.x - before.x, after.z - before.z).length()
	var dy := after.y - before.y

	if flat >= 1.0 or absf(dy) >= 1.0:
		return

	var bucket: Dictionary = tally[where]
	bucket["distance"] = float(bucket["distance"]) + flat
	bucket["ticks"] = int(bucket["ticks"]) + 1

	if dy < 0.0:
		bucket["descent"] = float(bucket["descent"]) - dy
	else:
		bucket["ascent"] = float(bucket["ascent"]) + dy


## The sum of one field over all three parts of [param tally].
static func _tally_total(tally: Dictionary, field: String) -> float:
	var total := 0.0
	for where in tally:
		total += float((tally[where] as Dictionary)[field])
	return total


## Prints where [param tally]'s ground and descent happened, against the route's own net
## rise ([param route_rise]). [param surface] names what the route is about.
func _print_where(route_name: String, surface: String, tally: Dictionary, route_rise: float) -> void:
	var covered := _tally_total(tally, "distance")
	var descent := _tally_total(tally, "descent")
	var ascent := _tally_total(tally, "ascent")
	var part := func(field: String, where: String, total: float) -> String:
		var value := float((tally[where] as Dictionary)[field])
		return "%.1f (%.0f%%)" % [value, 100.0 * value / maxf(total, 0.001)]

	print("    %s, where the ground went: %.1f m covered: %s on %s, %s in the air, %s on anything else" % [
		route_name, covered, part.call("distance", "on", covered), surface,
		part.call("distance", "air", covered), part.call("distance", "else", covered),
	])
	print("    %s, where the descent came from: %.1f m down (%.1f up, net %+.1f against the route's %+.1f): %s on %s, %s in the air, %s on anything else" % [
		route_name, descent, ascent, ascent - descent, route_rise,
		part.call("descent", "on", descent), surface,
		part.call("descent", "air", descent), part.call("descent", "else", descent),
	])


## The length of a route of boxes as a bot that took every jump straight covers it:
## [param from] to the first box after the pad, then centre to centre, along the ground.
static func _route_length(from: Vector3, route: Array[AABB]) -> float:
	var length := 0.0
	for i in range(1, route.size()):
		var to := route[i].get_center()
		length += Vector2(to.x - from.x, to.z - from.z).length()
		from = to
	return length


## `[bot-drive-1]`: the drive covered at least [param covered_floor] of the route, at a
## pace of at least [param pace_floor] of [param max_speed]. The floors are per route and
## set just under what the bot measured (2026-09-27), because a route with many jumps
## spends time in the air where a bot cannot hold its ground speed; a bot crawling at 40%
## of its speed fails every one of them.
func _check_pace(
	route_name: String, covered: float, length: float, pace: float, max_speed: float,
	pace_floor: float, covered_floor: float = 0.9
) -> void:
	_check(
		covered >= length * covered_floor and pace >= max_speed * pace_floor,
		"%s is covered at a running pace, not a crawl (%.0f%% of the route, %.0f%% of max speed or more)"
			% [route_name, covered_floor * 100.0, pace_floor * 100.0],
		"%.1f m of %.1f at %.2f m/s against %.1f" % [covered, length, pace, max_speed]
	)


## `[surf-ramp-1]`: none of the ground and none of the descent of a drive happened on
## something other than the route's own surface or the air above it.
func _check_where(route_name: String, surface: String, tally: Dictionary) -> void:
	var elsewhere: Dictionary = tally["else"]
	_check(
		float(elsewhere["distance"]) < 1.0 and float(elsewhere["descent"]) < 0.1,
		"%s is run on its %s and the air between them, and nothing else" % [route_name, surface],
		"%.1f m and %.2f m of descent on something else"
			% [float(elsewhere["distance"]), float(elsewhere["descent"])]
	)


## `[bot-drive-1]`: prints "covered X of Y m in T s: V m/s against a max" and returns V.
func _print_pace(
	route_name: String, covered: float, length: float, ticks: int, max_speed: float,
	top: float
) -> float:
	var seconds := float(ticks) / float(Engine.physics_ticks_per_second)
	var pace := covered / maxf(seconds, 0.001)
	print("    %s: covered %.1f m of a %.1f m route in %.2f s: %.2f m/s against a %.1f m/s max, top %.2f" % [
		route_name, covered, length, seconds, pace, max_speed, top,
	])
	return pace
