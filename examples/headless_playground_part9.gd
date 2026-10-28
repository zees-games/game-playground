extends "res://examples/headless_playground_part8.gd"

func _test_the_wheel_cycles_tools() -> void:
	_section("the wheel cycles tools")

	var keys := PlaygroundBindings.make()
	var prev_row := {}
	var next_row := {}
	var jump_wheel := 0
	for row in keys.rows:
		var action := StringName(str(row["action"]))
		if action == DotMenuBindings.WEAPON_PREVIOUS_ACTION:
			prev_row = row
		elif action == DotMenuBindings.WEAPON_NEXT_ACTION:
			next_row = row
		elif action == DotMenuBindings.JUMP_ACTION and str(row["default"]).begins_with("Wheel"):
			jump_wheel += 1
	_check(str(prev_row.get("default", "")) == "Wheel up" and str(next_row.get("default", "")) == "Wheel down",
		"the weapon actions default to Wheel up and Wheel down", "%s / %s" % [prev_row.get("default"), next_row.get("default")])
	_check(jump_wheel == 0, "and the wheel is on no jump row", str(jump_wheel))

	var client := PlaygroundClient.new()
	client.name = "WheelClient"
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	client.config = config
	add_child(client)
	for _i in range(4):
		await get_tree().process_frame
	await _gate_opens(client)

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true

	var ring := client._tool_ring()
	_check(ring.size() >= 2 and ring[0] == &"phys", "a client has two or more tools to cycle", str(ring))

	client.mouse_capture_override = true
	client._was_driving = true
	client._set_tool(ring[0])
	client.call("_unhandled_input", down)
	_check(client.tool == ring[1], "a wheel-down press moves one slot on", str(client.tool))
	client.call("_unhandled_input", up)
	_check(client.tool == ring[0], "and a wheel-up press moves one back", str(client.tool))
	client.call("_unhandled_input", up)
	_check(client.tool == ring[ring.size() - 1], "wrapping round past the first", str(client.tool))

	client._set_tool(ring[0])
	var before_holding: bool = client._holding
	client._holding = true
	client.call("_unhandled_input", down)
	_check(client.tool == ring[0], "while holding a prop the wheel does not change tools", str(client.tool))
	client._holding = before_holding

	client.queue_free()
	await get_tree().process_frame
	_done()


# --- The circuit -----------------------------------------------------------
