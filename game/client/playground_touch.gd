class_name PlaygroundTouch
extends RefCounted

## The on-screen buttons a phone needs: fire, alt-fire, jump, crouch, the hold-to-open spawn menu, tool previous/next,
## the held scoreboard and the chat box.
## The look and move halves of the screen are [DotFpsTouchSampler]'s; [member buttons] tells it where a button is.

const CHANNEL := "playground.touch"

const FIRE := DotGameTouchLayout.FIRE
const ALT := DotGameTouchLayout.ALT
const JUMP := DotGameTouchLayout.JUMP
const CROUCH := DotGameTouchLayout.CROUCH
const MENU := &"spawn"
const PREV := DotGameTouchLayout.PREV
const NEXT := DotGameTouchLayout.NEXT
const BOARD := DotGameTouchLayout.BOARD
const CHAT := DotGameTouchLayout.CHAT


## The fps preset less use and reload, plus the spawn menu's Q in the slot use leaves.
static func touch_layout() -> DotGameTouchLayout:
	var res := DotGameTouchLayout.build(DotGameTouchLayout.FPS, {
		DotGameTouchLayout.USE: null,
		DotGameTouchLayout.RELOAD: null,
		MENU: {"slot": &"inner", "label": "Q"},
	})
	if not res.ok:
		DotLog.error(CHANNEL, "touch layout refused", {"error": str(res.error)})
		return DotGameTouchLayout.custom()
	return res.value

var buttons: DotTouchButtons = null


## Builds the buttons under [param parent] and routes them: jump and crouch to the sampler (read through the callable,
## the active one changes on JOIN), the rest to [param handlers], button id to a Callable taking `down: bool`.
func build(parent: Control, sampler_fn: Callable, handlers: Dictionary) -> DotTouchButtons:
	buttons = DotTouchButtons.new()
	buttons.name = "TouchButtons"
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_layout().apply(buttons)
	parent.add_child(buttons)
	buttons.button_down.connect(func(id: StringName) -> void: route(id, true, sampler_fn, handlers))
	buttons.button_up.connect(func(id: StringName) -> void: route(id, false, sampler_fn, handlers))
	return buttons


static func route(id: StringName, down: bool, sampler_fn: Callable, handlers: Dictionary) -> void:
	if id == JUMP or id == CROUCH:
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
