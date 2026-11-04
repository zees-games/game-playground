class_name PlaygroundTouch
extends RefCounted

## The on-screen buttons a phone needs: fire, alt-fire, jump, duck, the hold-to-open spawn menu, tool previous/next,
## the held scoreboard and the chat box.
## The look and move halves of the screen are [DotFpsTouchSampler]'s; [member buttons] tells it where a button is.

const CHANNEL := "playground.touch"

const FIRE := &"fire"
const ALT := &"alt"
const JUMP := &"jump"
const DUCK := &"duck"
const MENU := &"spawn"
const PREV := &"prev"
const NEXT := &"next"
const BOARD := &"board"
const CHAT := &"chat"

## Offsets are from the bottom-right corner towards the middle; small enough for a 375 px tall screen.
static func layout() -> Array[Dictionary]:
	return [
		{"id": FIRE, "label": "FIRE", "offset": Vector2(80, 84), "radius": 44.0},
		{"id": ALT, "label": "ALT", "offset": Vector2(190, 60), "radius": 30.0},
		{"id": JUMP, "label": "JUMP", "offset": Vector2(80, 172), "radius": 32.0},
		{"id": DUCK, "label": "DUCK", "offset": Vector2(262, 60), "radius": 28.0},
		{"id": MENU, "label": "Q", "offset": Vector2(190, 150), "radius": 26.0},
		{"id": PREV, "label": "<", "offset": Vector2(138, 246), "radius": 22.0},
		{"id": NEXT, "label": ">", "offset": Vector2(80, 246), "radius": 22.0},
		{"id": BOARD, "label": "TAB", "offset": Vector2(196, 246), "radius": 22.0},
		{"id": CHAT, "label": "CHAT", "offset": Vector2(254, 246), "radius": 22.0},
	]

var buttons: DotTouchButtons = null


## Builds the buttons under [param parent] and routes them: jump and duck to the sampler (read through the callable,
## the active one changes on JOIN), the rest to [param handlers], button id to a Callable taking `down: bool`.
func build(parent: Control, sampler_fn: Callable, handlers: Dictionary) -> DotTouchButtons:
	buttons = DotTouchButtons.new()
	buttons.name = "TouchButtons"
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	buttons.set_buttons(layout())
	parent.add_child(buttons)
	buttons.button_down.connect(func(id: StringName) -> void: route(id, true, sampler_fn, handlers))
	buttons.button_up.connect(func(id: StringName) -> void: route(id, false, sampler_fn, handlers))
	return buttons


static func route(id: StringName, down: bool, sampler_fn: Callable, handlers: Dictionary) -> void:
	if id == JUMP or id == DUCK:
		var sampler: Variant = sampler_fn.call()
		if sampler != null and sampler.has_method(&"hold"):
			var bit := DotFpsCommand.BUTTON_JUMP if id == JUMP else DotFpsCommand.BUTTON_CROUCH
			sampler.call(&"hold", bit, down)
		return
	if handlers.has(id):
		(handlers[id] as Callable).call(down)


## A touch sampler where a phone is, the keyboard one otherwise; [param tunables] are the player's; [param ignore_fn] is asked with a screen position and keeps a button's finger off the stick.
static func make_sampler(tunables: DotFpsTunables, ignore_fn: Callable) -> DotFpsSampler:
	var sampler: DotFpsSampler
	if DotPlatform.has_touch():
		var touch := DotFpsTouchSampler.new(tunables)
		touch.ignore_fn = ignore_fn
		sampler = touch
	else:
		sampler = DotFpsSampler.new(tunables)
	DotFpsSampler.register_default_actions(sampler)
	return sampler
