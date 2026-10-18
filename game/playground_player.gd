extends CharacterBody3D

const PlaygroundMaterials := preload("playground_materials.gd")
const PlaygroundCharacter := preload("playground_character.gd")

## One player: movement, view, and the tools.
##
## [b]This class is the bridge, and the bridges are where the bugs are.[/b] Every
## addon here is complete and tested on its own; what has never run is the joins
## between them, and the family's own history says that is where everything is found.
## Concretely, this file is the only place that knows:
##
## - anything that changes where a player ends up runs *inside* the simulation, after
##   the move ([member post_move_fn], the toys, a prop underfoot), so a predicting
##   client's replay of a tick gets what the server's tick got;
## - a style is dot-player-controller's [code]DotFpsStyle[/code]; a run timer, when a
##   server added one, hears [signal style_changed] and puts its ranking half beside it.

const CHANNEL := "playground.player"

## The movement style changed. What a run timer listens to for its ranking half.
signal style_changed(style: DotFpsStyle)

## `func(player, state: DotFpsState) -> void`, run on every simulated tick after the move and
## before the toys: a run timer's zone effects (push, speed limit, gravity, the prespeed
## clamp). Unset when there is none. On the tick rather than from a signal, because each of
## them changes where the player ends up.
var post_move_fn: Callable = Callable()

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"

## Whether this is the authority's copy of the player. Server-side only.
@export var authoritative: bool = false

## Whether a command is sampled from the input devices each tick.
##
## True for the person at the keyboard, false for a bot, a replay and every remote
## player. It is a property of the PLAYER rather than of the build, because a client
## holds one of each: their own, which samples, and everybody else's, which does not.
@export var samples_input: bool = false

var controller: DotFpsController = null

## The third-person controller, when this player has one. See [method set_view_mode].
var tps: DotTpsController = null

## Which of the two is driving. Built only on a player that can have a camera.
var controller_switch: DotPlayerControllerSwitch = null

## The dot-player component root the two controllers bind through.
var player_node: DotPlayer = null

## The body other people see. Null until [method build_character] is called.
var character: PlaygroundCharacter = null

## How this player's body fell on their last death: the server's pick
## ([method PlaygroundArena.decide_death]), carried on COMBAT. Null before one.
var death: DotPlayerDeath = null

## The locomotion state machine over that body.
var anim: DotPlayerAnimDriver = null

## The camera's motion cues on the local player: the landing dip and nod, the strafe lean and
## the widening past a run, from dot-player-controller's [DotFpsViewMotion] applied where the
## camera is written ([method present_camera]). Null on everybody else.
##
## [b]Not a [DotFpsView], and one stood here doing nothing until 2026-10-11.[/b] The client
## added a `DotFpsView` after the controller had looked for one, so `controller.view` was null
## and the view never ran: no dip, no lean, no widening, and the recoil `_present_zee` handed
## it went nowhere. The client writes the camera itself (the interpolated eye, below), which
## is game-arena's arrangement, so the arithmetic comes here instead of a node that would
## write the same camera.
var camera_motion: DotFpsViewMotion = null

## A landing the drawn eye has not reached yet: its impact (0 for none) and its tick.
var _landing_impact: float = 0.0
var _landing_tick: int = -1

## Turns devices into commands, for a locally controlled player only.
var sampler: DotFpsSampler = null

## See [method class_base_tunables].
var _class_base: DotFpsTunables = null

## This player's run timer, when a server added dot-timer: a `DotTimer` owned by
## `addons/pg_timer`'s manager, untyped because the addon may be absent. Null otherwise.
var timer: Object = null

## Standing on a moving prop. Set by the game on join; see [method _ride_prop].
var carry: DotPropCarry = null
var carry_enabled_fn: Callable = Callable()

## The map's toys (dot-props' [DotPropToyBox]), for the trampolines and pads that throw this
## player and the roundabout that carries them. Set by the game on every map, both ends.
var toys: DotPropToyBox = null

## `func(index: int) -> void`: this player was thrown by toy [param index]. The game's, which
## counts the bounce on the server only (that is what a client hears).
var bounced_fn: Callable = Callable()

## What a player weighs to a prop they stand on (DotPropCarry takes a share of it).
const MASS_KG := 80.0

## How far props have carried this player, all told. For `describe` and the suites.
var carried_metres: float = 0.0

## The movement half of the style in force.
var movement_style: DotFpsStyle = null

## The tools, when the game has dot-props.
var phys_gun: DotPhysGun = null
var grav_gun: DotGravGun = null

## The zee-dot-weapons rig in this player's hands, or null. Put here and taken away by
## PlaygroundZee, never built by the player: most players hold a physics gun.
var zee_rig: Node = null

## Simulated seconds the drawn zee gun on a connected client has gone without a trigger, a
## reload or a switch (`PlaygroundZee.note_drawn`); the server's count corrects it only past
## `PlaygroundZee.SETTLE_SEC`.
var zee_quiet: float = 0.0

## The zee weapon everybody else sees in this player's hands (a [ZeeWorldModel]), or null.
## Built on a client from the server's WEAPON event by [method PlaygroundZee.show_held].
var zee_world: Node3D = null

## Whether this player is in a vehicle, and so is not walking.
##
## [b]Read-only from outside: [method set_riding] is the switch.[/b] It exists as a flag
## on the PLAYER rather than as a lookup in the vehicle spawner because everything that
## has to know is on this side — the tick, the sampler, the net behaviour and the HUD —
## and a client has no vehicle spawner at all to ask.
var riding: bool = false

## The vehicle this player is riding in, when it is known: the body sits facing the way it
## does. Null when not riding, and null on a client that has not been told which vehicle —
## the body then faces where the rider is looking, which is the best it has.
var ride_node: Node3D = null

## An administrator's `blind`: this player's own screen is blacked out.
##
## [b]Set on the server and replicated to the OWNER ONLY[/b] (`PlaygroundPlayerNet.net_blind`).
## Nobody else's screen changes, so nobody else needs to know — and in the arena an
## opponent who could read it would know exactly when somebody could not see them coming.
## `PlaygroundHud` draws it.
var blinded: bool = false

## An administrator's `beacon`: a pulsing ring and a column over this player that every
## client draws, and a ping every client hears, until it is turned off.
##
## Set on the server and replicated to everybody (`PlaygroundPlayerNet.net_beacon`), who
## each draw it in [method present_beacon].
var beacon: bool = false

## Creative mode: see [member PlaygroundConfig.allow_creative] and [method Playground.set_creative].
## Replicated, so everybody's picture can say who is building.
var creative: bool = false

## Down and waiting to be picked up (`PlaygroundDowns`, server-side), replicated so every
## client draws them crawling on the floor rather than standing for the ninety seconds.
var downed: bool = false

## The marker [member beacon] draws, while it does. Client side; built and freed by
## [method present_beacon], and never built on a server, which calls nothing that draws.
var beacon_marker: DotFxBeacon = null

## Set by the world so the timer is ticked with the same clock the movement uses.
## [b]Assigned through, not just stored.[/b] The controller sizes its step from its own
## copy, taken in [method _ready] — so setting this on a player who already exists and
## stopping there runs the game's loop at one rate and that player's movement at
## another. Nothing errors; the player is simply correct on their own screen and wrong
## on everybody else's. A client adopting the server's rate through HELLO is exactly
## that case whenever a player already exists, which is every map change.
var tick_rate: int = 128:
	set(value):
		tick_rate = value
		if controller != null:
			controller.tick_rate = value


## This player's swimming mode (dot-player-controller's DotFpsSwimMode). Its water is the
## map's, set by [method set_water].
var swim: DotFpsSwimMode = DotFpsSwimMode.new()


## The water this player can swim in: the map's water boxes, world space.
func set_water(boxes: Array[AABB]) -> void:
	swim.volumes = boxes
	if controller != null and controller.motor != null and controller.state != null \
			and controller.state.mode == swim.mode_id and boxes.is_empty():
		controller.motor.set_mode(controller.state, DotFpsState.Mode.AIR)


func _ready() -> void:
	controller = DotFpsController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate

	# EXTERNAL, not LOCAL, even in single player.
	#
	# [b]The game owns the tick, and that is the whole ordering argument.[/b] In
	# LOCAL the controller accumulates frame time and ticks itself, which means the
	# timer would be fed from a signal fired inside somebody else's loop and a bot
	# could not be driven at all. Owning the loop here makes the order explicit —
	# sample, move, then time the tick with the position the move produced — and it
	# is the same shape a dot-net bridge and a dedicated server use, so nothing has
	# to be rearranged when one arrives.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = _tunables()
	# What a map box is made of reaches the feet: ice, mud, sand, snow, rubber. Read off box
	# metadata both ends build from one map document, so a client predicts it too.
	controller.surfaces = PlaygroundMaterials.player_surfaces()
	# Every player, both ends: an admin's noclip is a modifier whose index travels on the
	# wire. See dot-player-controller's DotFpsAdminModifiers.
	controller.admin_abilities = true

	# body_ref left unset, so it defaults to the parent — this node, which is the
	# Node3D the movement drives. `DotNodeRef.of_self()` looks equivalent and is not:
	# it resolves to the CONTROLLER, which is a plain Node, and setup() then refuses
	# with "the player body must be a Node3D" and the whole player never simulates.
	# Swimming: one mode per player, registered on every setup (a style rebuilds the motor),
	# the same on every machine because its id is on the wire. The water comes from the map.
	controller.extra_modes = [swim]

	add_child(controller)

	controller.simulated.connect(_on_simulated)

	if samples_input:
		sampler = DotFpsSampler.new(controller.tunables)
		DotFpsSampler.register_default_actions(sampler)


## Gives this player a third-person controller and the switch that hands between them.
##
## [b]The sandbox is where third person belongs, and the other two 3D games are where it
## does not.[/b] game-g2gfast has a third-person view already and it is deliberately
## *cosmetic* — `G2GCamera` flips between two cameras over one motor, because a run set in
## third person has to be comparable with one set in first and a second movement model
## would make it a different game. game-arena is lag-compensated and analytic: its server
## and its clients agree because there is exactly one motor to agree about. A sandbox has
## neither constraint — nothing here is ranked and nothing is rewound — so it is the one
## place a genuinely different motor is free.
##
## [b]Built on demand, not for everybody.[/b] `DotTpsController` drives a
## `CharacterBody3D` through Godot's physics, which is real per-tick cost, and a
## dedicated server full of remote players that will never be looked at through a camera
## should not pay it. Only a player that samples input gets one.
##
## Returns whether it was built.
func build_view_switch() -> bool:
	if tps != null:
		return true

	if not samples_input:
		return false

	# [b]The component root both controllers bind through.[/b] `DotPlayerController` is a
	# `DotPlayerComponent`: it finds its player by walking up, reads the body from it and
	# refuses to run unbound. Without this node the third-person controller has no body to
	# ask for and logs "no CharacterBody3D for this player" once per activation.
	player_node = DotPlayer.new()
	player_node.name = "Player"
	player_node.player_key = String(player_id)
	player_node.is_local = true
	# [b]No `roster_ref`, deliberately.[/b] `DotPlayer` binds on a key alone when it
	# cannot find a roster, and everything the controllers ask it for — the body, whether
	# the player is alive — is answered without one. Pointing it at the stack's roster
	# would mean either a node path across two subtrees or turning
	# `register_service` on, and a registry name is global to the process: two servers in
	# one editor session would collide on it, which is the reason the stacks turn it off.
	# The body is this node, which is why it is a CharacterBody3D at all.
	player_node.body_ref = DotNodeRef.of_path(NodePath(".."))
	add_child(player_node)

	tps = DotTpsController.new()
	tps.name = "ThirdPerson"
	tps.controller_id = &"tp"
	tps.tunables = DotTpsTunables.new()
	add_child(tps)

	# [b]The id BEFORE the switch is added, and that ordering is the bug.[/b]
	# `DotPlayerControllerSwitch._ready` runs `refresh()` and activates its default the
	# moment it enters the tree — so a controller still carrying an empty `controller_id`
	# at that instant is registered under its class name instead, `default_controller`
	# names something that is not there, and the switch falls back to whatever it found
	# first. The sandbox opened in third person and the only symptom was the camera.
	controller.controller_id = &"fp"

	controller_switch = DotPlayerControllerSwitch.new()
	controller_switch.name = "ViewSwitch"
	# First person is what a sandbox opens in: the tools are aimed down a crosshair and a
	# physics gun held over the shoulder is a different, worse tool.
	controller_switch.default_controller = &"fp"
	add_child(controller_switch)

	# This is the moment a client learns the player is its own, so the body built for them
	# as somebody else's is hidden now: they are looking out of it.
	refresh_body()

	return true


## Gives this player a visible body and the locomotion state machine that drives it.
##
## [b]dot-player-char's visual half had no implementation in any game in this family.[/b]
## Five projects installed the addon, four built a catalogue, and `DotPlayerCharVisual` —
## the abstract node the whole addon exists to fill — was subclassed nowhere. It survived
## because every game was first-person and nobody sees their own body; the third-person
## camera is what made it visible, and the first frame through it was an empty view four
## metres behind nothing.
##
## [param colour] is the player's own, so two people in a sandbox are told apart.
## What this person wears: [face, top, legs] as kit skins (see `playground_avatars.gd`), empty
## for the stock look their id picks. Set by the server from their avatar and sent in JOIN.
var skins := PackedInt32Array()

var _character_def: DotPlayerCharDef = null
var _character_colour := Color.WHITE


## Dresses this player in [param p_skins] and rebuilds the body if it changed.
func set_skins(p_skins: PackedInt32Array) -> void:
	if p_skins == skins:
		return
	skins = p_skins
	if _character_def != null:
		build_character(_character_def, _character_colour)
		refresh_body()


func build_character(def: DotPlayerCharDef, colour: Color) -> void:
	if def == null:
		return

	_character_def = def
	_character_colour = colour

	if character == null:
		character = PlaygroundCharacter.new()
		character.name = "Character"
		add_child(character)

	character.build_for(def, colour, skins, String(player_id))
	character.set_seated(riding)

	if anim == null:
		anim = DotPlayerAnimDriver.new()
		anim.name = "Animation"
		# [b]Driven from here rather than by itself.[/b] `auto_drive` reads the body's
		# transform once a frame and differentiates it, which is a second opinion about
		# how fast the player is going — and this game already has an authoritative one
		# on the controller. Two sources of "am I running" disagree exactly when a
		# correction lands, which is when an animation pop is most visible.
		anim.auto_drive = false
		anim.anim_set = DotPlayerAnimSet.locomotion()
		add_child(anim)

	refresh_body()


## Whether this player's body is drawn: always, except by the person looking out of it in
## first person.
##
## [b]It used to be `view_mode() == &"tp"` for everybody, and that hid every other player on
## every client.[/b] A view mode is a fact about the LOCAL player — only a player that
## samples input has a switch at all — so every remote player answered "fp" and was built
## with its body hidden. It was invisible offline because offline there is nobody else,
## and in the one frame anybody had looked at, the body in it was the local player's own.
func body_shown() -> bool:
	return not samples_input or view_mode() == &"tp"


## Puts [method body_shown] onto the body. Called whenever either half of it can change: the
## body being built, the view switch being built (which is when a client learns this player
## is its own), and the view being switched.
func refresh_body() -> void:
	if character != null:
		character.set_shown(body_shown())


## Turns the body to face where this player is looking, from the state as it is NOW.
##
## Once a frame from the client, for every player. [method drive_character] does the same
## once a tick, but only where the game ticks every player — the authority; a client ticks
## only its own, so a remote player's body kept whatever way it faced when it was built and
## slid across the floor sideways.
func face_body() -> void:
	if character != null and controller != null:
		_face(controller.state.yaw)
		var state := controller.state
		character.move_person({
			"speed": Vector2(state.velocity.x, state.velocity.z).length(),
			"vertical": state.velocity.y,
			"on_floor": state.is_grounded(),
			"crouched": state.crouch_fraction > 0.5,
			"downed": downed,
			# The view's pitch: the upper body, the head and a held gun follow it.
			"aim": deg_to_rad(state.pitch),
		})


## A rider's body faces the vehicle, whoever is looking where. Everybody else's faces where
## they look.
func _face(yaw_degrees: float) -> void:
	if riding and ride_node != null and is_instance_valid(ride_node) and ride_node.is_inside_tree():
		character.face_basis(ride_node.global_basis)
	else:
		character.face(deg_to_rad(yaw_degrees))


## Advances the locomotion state from the movement that just happened.
##
## Called from the game's tick, after the controller has simulated, for the ordering
## reason every other consumer here follows: a state machine fed the position a player
## was at is a state machine one tick behind the player.
func drive_character(delta: float) -> void:
	if anim == null or controller == null:
		return

	var state := controller.state
	var _clip := anim.drive({
		"speed": Vector2(state.velocity.x, state.velocity.z).length(),
		"vertical": state.velocity.y,
		"on_floor": state.is_grounded(),
		"crouched": state.crouch_fraction > 0.5,
		"facing": deg_to_rad(state.yaw),
		"alive": true,
	}, delta)

	if character != null:
		character.set_stance(state.crouch_fraction > 0.5)
		# The body faces where the player is looking. Without this the capsule keeps the
		# rotation it was built with and a third-person camera orbiting a player shows a
		# character who never turns — which reads as the model being broken rather than
		# as a missing line.
		_face(state.yaw)


## Switches between the first- and third-person controllers.
##
## [b]The handover is the point, and it is the switch's rather than this game's.[/b]
## Position, velocity and look angles cross; the motor state does not, because a
## first-person air-strafe has no counterpart in a third-person motor and any mapping
## between them is a lie. Returns the id now driving.
func set_view_mode(third_person: bool) -> StringName:
	if controller_switch == null:
		return &"fp"

	var wanted := &"tp" if third_person else &"fp"
	var res := controller_switch.activate(wanted)
	var now := StringName(str(res.value)) if res.ok else controller_switch.active_id()

	# The body is shown in third person and hidden in first, which is the whole reason
	# `DotPlayerCharVisual.set_shown` exists.
	refresh_body()

	return now


## Which controller is driving.
func view_mode() -> StringName:
	return controller_switch.active_id() if controller_switch != null else &"fp"


## Sets which collision layers this player's movement sweeps against.
##
## [b]Not `DotFpsTunables`' default of 1.[/b] One means bit 0, which is right only while
## every body in the game is on bit 0 — the state a layout exists to end. Once props,
## entities and vehicles moved to their own layers, a mask of 1 was a player who walks
## through every crate, every NPC and every car in the sandbox, and nothing would have
## said so: a sweep that hits nothing is a sweep, not an error.
##
## [b]Through `set_collision_mask`, which survives a style.[/b] Written on the live tunables
## it lasted until the next `set_style`, which rebuilds them from the controller's base copy:
## a connected client has its style set straight after the join, so on every client the
## player walked through every prop (found measuring prop surfing over the wire, 2026-10-06).
func use_collision_mask(mask: int) -> void:
	if controller != null:
		controller.set_collision_mask(mask)


## The movement this player was built with, before any class scaled it.
##
## [b]Captured once, and it is what makes applying a class on every respawn safe.[/b] A
## class's `move_speed_scale` is a multiplier; applied to tunables that already carry it
## the product compounds, so four respawns as a 0.8 class is 0.41 of the speed, arrived
## at silently with every number in the inspector looking deliberate.
func class_base_tunables() -> DotFpsTunables:
	if _class_base == null and controller != null and controller.tunables != null:
		_class_base = controller.tunables.duplicate()

	return _class_base


## The movement a bunny-hop and surf server runs.
##
## [b]These are not the addon's defaults and the differences are the whole genre.[/b]
## `auto_hop` on, because the alternative makes the skill a keyboard-hardware contest
## rather than an aiming one. `bhop_speed_cap_scale` at zero, because a cap is what
## those shooters added to *stop* bunny-hopping. `crease_slide` on, because a surf map
## is made of seams. `friction` low and `air_accelerate` high, because that pair is
## what makes a strafe worth making.
##
## Static because a map sizes its jumps against these with no player in the tree:
## `PlaygroundMap.jump_reach` asks [method movement_tunables] directly.
func _tunables() -> DotFpsTunables:
	return movement_tunables()


## A fresh copy of the movement every player here is built with. See [method _tunables].
static func movement_tunables() -> DotFpsTunables:
	var t := DotFpsTunables.new()

	t.auto_hop = true
	t.bhop_speed_cap_scale = 0.0
	t.crease_slide = true

	t.max_speed = 7.0
	t.accelerate = 10.0
	t.friction = 5.0
	t.stop_speed = 4.0

	t.air_accelerate = 100.0
	t.max_air_wish_speed = 1.0
	t.gravity = 20.0
	t.jump_height = 1.15

	# No coyote time and no jump buffer beyond one tick: on a timed map both are
	# free speed, and a run set with them is not comparable with one set without.
	t.coyote_time = 0.0
	t.jump_buffer_time = 0.0

	t.max_slope_angle = 46.0
	t.step_height = 0.4

	return t


## Puts this player on a movement style.
##
## [signal style_changed] is how a run timer keeps its ranking half in step: applying only
## the movement half would time and rank a run as "normal" while the player is actually
## sideways, and nothing would error.
func set_style(movement: DotFpsStyle) -> DotResult:
	movement_style = movement
	var applied := controller.set_style(movement)
	style_changed.emit(movement)
	return applied


## Stops the run in progress, if there is a run timer. [param reason] is one of dot-timer's
## stop reasons (`&"teleport"`, `&"noclip"`, ...), as a StringName.
func stop_run(reason: StringName) -> void:
	if timer != null:
		timer.call("stop", reason)


## Marks the run in progress as assisted, if there is a run timer: it finishes and is never
## filed.
func taint_run() -> void:
	if timer != null:
		timer.call("taint")


## Moves the player, cancelling any run.
##
## Used by a respawn zone, a teleport zone, an admin, and the spawn on map load.
func teleport(to: Vector3, yaw: float = INF, keep_run: bool = false) -> void:
	_teleported = true
	# [b]Through the controller's own teleport, and then the view is told too.[/b]
	#
	# This used to write `controller.state` directly, and a yaw written there lasts
	# exactly until the next tick. Commands carry ABSOLUTE view angles, so the tick
	# after a teleport sets the yaw back to whatever the command says: for a client,
	# this player's own `sampler`, which had never been told and still faced wherever
	# the mouse last left it; for a bot or any player with no command that tick,
	# `DotFpsController`'s starved-tick substitute, which is a fresh command facing yaw
	# 0. So every derived spawn yaw on every map here — the tower's, the circuit's,
	# the switchback's, each with a paragraph about its sign convention — was true for
	# no ticks at all, and the one check on it passed because it read the yaw BEFORE a
	# tick had run. `headless_playground::_the_spawn_yaw_survives_a_tick` is the check
	# that reads it after.
	#
	# `DotFpsController.teleport` also drops the smoothing and puts the player in the
	# air, which a direct write did not: a player moved while grounded kept a ground
	# state for a tick at a height with no ground under it.
	controller.teleport(to, yaw)

	# A teleport is not a landing, a strafe or a burst of speed.
	if camera_motion != null:
		camera_motion.snap()
		_landing_impact = 0.0

	if sampler != null:
		sampler.look_at_angles(controller.state.yaw, controller.state.pitch)
	else:
		# Nothing samples this player, so leave it HOLDING STILL and facing where it was
		# put. Not left null: a null command is a starved tick and faces north. And not
		# the command it had: a bot that was holding forward when it fell off a course
		# is otherwise respawned already running off the pad.
		var hold := DotFpsCommand.new()
		hold.yaw = controller.state.yaw
		hold.pitch = controller.state.pitch
		controller.apply_command(hold)

	global_position = to

	# The run goes with it. A teleport that kept the clock running is the simplest
	# possible cheat on any timed map, and a respawn zone is a teleport. The one exception
	# is [param keep_run]: a map's own TELEPORT zone on the player's track, which the timer
	# asked for (it is part of the route) and already expects.
	if not keep_run:
		stop_run(&"teleport")


func speed() -> float:
	return controller.state.horizontal_speed()


func eye_position() -> Vector3:
	return controller.motor.eye_position(controller.state)


## Where the eye is DRAWN this frame, which is not where it is: the last two ticks blended by
## how far this frame sits between them ([method DotFpsController.render_state]). Aim, reach
## and every trace still use [method eye_position]; this is the camera's and nothing else's.
##
## [b]Why the camera needs it now and did not before 2026-09-25.[/b] Until then a connected
## client predicted nobody, its own player was interpolated like everybody else's, and the
## eye rode that interpolation — smooth, and a round trip plus the interpolation delay behind
## the keys. Predicted, the eye is the simulation's and moves once a tick, so on a screen
## faster than the tick some frames advance it and some do not: measured with
## `tools/screenshot_net.sh --walk`, 62 of 593 frames standing still at full speed.
##
## Not while riding: the controller is not simulated in a vehicle, so its previous tick is
## wherever the player got in, and a blend toward it drags the view backwards every frame —
## the lurch mg-buses-from-hell measured at 137.9 m/s when its blend read a tick nothing had
## simulated. A teleport resets the blend itself (`DotFpsController.teleport`).
## The camera motion this game picks for a bunny-hop and surf sandbox (scale 1 of each
## setting). Its numbers are about [method movement_tunables]:
##
## - A hop lands at about 6.8 m/s (1.15 m at 20 m/s²), under [code]landing_min_speed[/code], so
##   a chain of hops never bobs the view; a drop off a ledge does, fully from 16 m/s (6.4 m).
## - The widening starts past the 7 m/s run and is all there at 25 m/s, where a good bhop or
##   any surf ramp is; a player walking about building never sees the lens move.
## - The lean is a degree at a sideways run, bounded, because a surfer looks across the ramp
##   for whole seconds at a time.
static func camera_motion_picks() -> DotFpsViewMotion:
	var m := DotFpsViewMotion.new()
	m.landing_dip = 0.06
	m.landing_reference_speed = 16.0
	m.landing_min_speed = 8.0
	m.landing_recovery = 0.25
	m.landing_pitch = 1.0
	m.strafe_roll = 1.0
	m.strafe_roll_reference = 9.0
	m.strafe_roll_response = 8.0
	m.slide_roll = 0.0
	m.wall_run_roll = 0.0
	m.roll_limit = 2.0
	m.fov_speed_gain = 5.0
	m.fov_speed_floor = 8.0
	m.fov_speed_reference = 25.0
	m.fov_response = 4.0
	m.slide_fov_gain = 0.0
	m.wall_run_fov_gain = 0.0
	return m


## Gives this player [member camera_motion] at the picks. The client calls it on its own
## player once that player has a camera.
func enable_camera_motion() -> void:
	if camera_motion != null or controller == null:
		return
	camera_motion = camera_motion_picks()
	if not controller.landed.is_connected(_on_landed):
		controller.landed.connect(_on_landed)


## Scales the camera motion from [method camera_motion_picks]: each 0 (off) to 2, 1 the pick.
## The player's `camera_*` settings, through `PlaygroundPresentation`; each goes to 0 on its
## own, because a player whom the lean makes sick may still want the dip.
func set_camera_motion_scales(landing: float, strafe: float, widen: float) -> void:
	if camera_motion == null:
		return
	var picks := camera_motion_picks()
	camera_motion.landing_dip = picks.landing_dip * maxf(landing, 0.0)
	camera_motion.landing_pitch = picks.landing_pitch * maxf(landing, 0.0)
	camera_motion.strafe_roll = picks.strafe_roll * maxf(strafe, 0.0)
	camera_motion.roll_limit = picks.roll_limit * maxf(strafe, 0.0)
	camera_motion.fov_speed_gain = picks.fov_speed_gain * maxf(widen, 0.0)


## Writes [param camera] for this frame: the interpolated eye, the view's angles, and the
## motion cues on top, plus [param shake] (metres) and [param punch] (degrees, x pitch y yaw:
## the recoil's camera half). [param base_fov] is the lens before the widening. The one place
## the first-person camera is written, so a render tool draws exactly what the client does.
func present_camera(camera: Camera3D, delta: float, base_fov: float, shake: Vector3 = Vector3.ZERO, punch: Vector2 = Vector2.ZERO, zoom: float = 1.0) -> void:
	var dip := 0.0
	var nod := 0.0
	var lean := 0.0
	var widen := 0.0

	if camera_motion != null:
		if riding:
			camera_motion.snap()
		else:
			var drawn := controller.render_state()
			_kick_landing(drawn)
			camera_motion.advance(drawn, delta)
			dip = camera_motion.eye_drop()
			nod = camera_motion.pitch()
			lean = camera_motion.roll()
			widen = camera_motion.fov_added()

	camera.global_position = render_eye_position() + Vector3(0.0, dip, 0.0) + shake
	camera.global_rotation = Vector3(
		deg_to_rad(controller.state.pitch + nod + punch.x),
		deg_to_rad(controller.state.yaw + punch.y),
		deg_to_rad(lean)
	)
	# [param zoom] is a zee gun's aim (1 at the hip), after the widening, as game-arena's lens.
	camera.fov = (base_fov + widen) * (clampf(zoom, 0.01, 1.0) if is_finite(zoom) else 1.0)


## Holds a landing until the drawn eye reaches the floor ([method _kick_landing]): the signal
## comes from the tick that lands, and the frames after it still draw part of the fall, so a
## kick here would add the dip to the last of the fall (game-arena measured the jump).
func _on_landed(impact: float) -> void:
	if camera_motion == null:
		return
	_landing_impact = maxf(_landing_impact, impact)
	_landing_tick = controller.state.tick


func _kick_landing(drawn: DotFpsState) -> void:
	if _landing_impact <= 0.0:
		return
	if drawn.position.y > controller.state.position.y + 0.005 and controller.state.tick <= _landing_tick + 1:
		return
	camera_motion.note_landing(_landing_impact)
	_landing_impact = 0.0


func render_eye_position() -> Vector3:
	if riding or controller == null or controller.motor == null:
		return eye_position()
	return controller.motor.eye_position(controller.render_state())


func aim_direction() -> Vector3:
	return DotFpsMotor.aim_for(controller.state.yaw, controller.state.pitch)


## The duck-typed lookup dot-weapon's player bridge asks a carrier for.
##
## [b]Without it every shot leaves the body's origin pointing north.[/b]
## `DotWeaponPlayerBridge` takes a shot's origin and aim from a controller it finds through
## `component()`, and a player without the method falls back to the node's transform —
## whose basis is identity here, because the yaw lives in the controller's state. Every
## shot fires, costs ammunition and hits nothing; mg-smash-copter found it as twenty drawn
## rounds in a row. `DotFpsController` as well as `DotPlayerController`, because the bridge
## asks for the base and this player holds the first-person subclass.
func component(type_name: StringName) -> Object:
	match String(type_name):
		"DotPlayerController", "DotFpsController":
			return controller
		"ZeeWeaponRig":
			return zee_rig
		_:
			return null


# --- The tick --------------------------------------------------------------

## Advances this player by one simulated tick.
##
## Called by [Playground], not by the controller: see the note in [method _ready]
## about who owns the loop.
func simulate(tick: int, delta: float) -> void:
	if sampler != null:
		controller.apply_command(sampler.sample(delta))

	# A rider's movement is TURNED OFF, not ignored, and the sample above still happens.
	#
	# Off, because a controller simulating a player who is parented into a moving vehicle
	# writes its own answer into the state every tick while the vehicle carries the node
	# somewhere else — two authorities over one transform, which reads as the car shaking
	# itself apart at speed. Sampled anyway, because those same keys are what the car is
	# being driven with: `Playground._drive_vehicles` reads the pending command and turns
	# it into throttle and steering.
	if riding:
		return

	controller.simulate_tick(tick, delta)


## Called once per simulated tick, by the controller, after the move.
##
## [b]After the move, and that ordering is the point.[/b] What runs here changes where
## the player ends up this tick, and a run timer decides whether the player crossed a line
## from where they were and where they now are — so it has to see the position the move
## produced, not the one it started from.
func _on_simulated(_tick: int, state: DotFpsState) -> void:
	global_position = state.position

	# Into the water once the waist is in it. Here because this runs on every simulated tick,
	# a prediction replay's included, so a client and the server enter on the same tick.
	if not riding and controller.motor != null:
		swim.update(controller.motor, state)

	if post_move_fn.is_valid():
		post_move_fn.call(self, state)

	_launch_from_toy(state)
	_ride_prop(state)


## A trampoline or a bounce pad under the feet throws them, after the move, on every end that
## simulates this player (a predicting client's replays included): dot-props' `launch_for` is a
## pure function of where the toys stand, so the client is thrown on the tick the server is.
## AIR at once, as a jump leaves the ground, or the motor's ground snap holds them down.
func _launch_from_toy(state: DotFpsState) -> void:
	if toys == null or riding or not state.is_grounded():
		return
	var thrown := toys.launch_for(state.position, state.velocity)
	if thrown.is_empty():
		return
	state.velocity = thrown["velocity"]
	state.mode = DotFpsState.Mode.AIR
	state.time_since_grounded = 1000.0
	if bounced_fn.is_valid():
		bounced_fn.call(int(thrown["index"]))


## Carried by the prop underfoot, after the move (mg-buses-from-hell's shape).
##
## [b]`ground_id` is a local physics handle, not simulation state[/b], so riding is
## resolved on each machine from its own bodies. Written into the state as well as the
## node: the next move starts from `state.position`, and a lift applied to the node alone
## is undone by it, so the player would ride one frame a tick and stand still overall.
func _ride_prop(state: DotFpsState) -> void:
	if carry == null or not state.is_grounded() or riding:
		return

	var step := 1.0 / float(maxi(1, controller.tick_rate))
	var surfing := not carry_enabled_fn.is_valid() or bool(carry_enabled_fn.call())
	var lift := Vector3.ZERO

	# A prop underfoot (prop surfing), and a turning roundabout through the same call
	# (`DotPropCarry.toys`). With prop surfing off, the roundabout still carries: it is a toy
	# on the map, not a prop somebody spawned to ride.
	if surfing:
		lift = carry.ride(state.ground_id, state.position, MASS_KG, step)
	elif carry.toys != null:
		lift = carry.toys.carry_for(state.position, step, state.ground_id).get("offset", Vector3.ZERO)

	# A connected client's ground is a mirror, which its spawner does not know and whose body
	# is frozen: its velocity is the one its net behaviour measured (PlaygroundPropNet).
	if surfing and lift == Vector3.ZERO and state.ground_id != 0:
		var ground: Object = instance_from_id(state.ground_id)
		if ground is Node and (ground as Node).has_meta(&"mirror_velocity"):
			lift = ((ground as Node).get_meta(&"mirror_velocity") as Vector3) * step

	if lift == Vector3.ZERO:
		return

	state.position += lift
	global_position = state.position
	carried_metres += lift.length()


## Gets in or out of a vehicle. Called by the ride's `on_seated` / `on_unseated`.
##
## Both halves matter and the second is the one that is easy to leave out: a player put
## back down after a drive whose velocity was whatever it was when they got in launches
## across the map on their first step.
func set_riding(value: bool, vehicle_node: Node3D = null) -> void:
	# Before the early return: a client told twice about one ride may learn the vehicle
	# only the second time.
	ride_node = vehicle_node if value else null

	if character != null:
		character.set_seated(value)

	if riding == value:
		return

	riding = value

	if riding:
		controller.state.velocity = Vector3.ZERO
	else:
		# Handed back walking, standing still and in the air. The controller works out
		# on its next tick whether there is ground under them, which is the honest answer
		# — the exit sweep only proved there was room, not that it was a floor.
		controller.state.velocity = Vector3.ZERO
		controller.state.mode = DotFpsState.Mode.AIR


## Held by somebody's physics gun ([PlaygroundPickup]): a rider with no vehicle and no
## seat. Movement off, prediction off, and the body standing, because nobody sat down.
func set_held(value: bool) -> void:
	set_riding(value)
	if character != null:
		character.set_seated(false)


## Copies where the vehicle has carried this player into the movement state.
##
## [b]Without this a passenger is drawn on every other machine at the spot where they got
## in.[/b] The NODE is carried by dot-vehicle, which reparents it into the seat — but the
## timer, the NPC candidate list, the HUD and above all [PlaygroundPlayerNet] all read
## [code]controller.state.position[/code], and nothing was writing it. The failure is
## invisible in one process, because in one process the node is the thing being looked at.
func adopt_ride(at: Vector3, velocity: Vector3) -> void:
	controller.state.position = at
	controller.state.velocity = velocity


## The command this player is about to be simulated with, or was last simulated with.
##
## What a vehicle is driven from. Never null: the controller keeps the last command it
## was given, which is what makes a dropped input a straight line rather than a stop.
func pending_command() -> DotFpsCommand:
	return controller.current_command if controller.current_command != null else DotFpsCommand.new()


## Draws [member beacon] for one frame, and says when it pings.
##
## Called once a frame by whatever draws this player — `PlaygroundClient._process` for every
## player in the world, a screenshot tool for the ones it arranges — and never on a server,
## so a dedicated server builds no marker. Returns true when a new ripple starts, which is
## when the caller plays the ping; a return value rather than a signal, because the one
## caller that plays it is the one that asked.
##
## [param local_view] is whether this is the player whose eyes the camera is behind, which
## hides the column (see [DotFxBeacon]).
##
## [b]Not hidden while dead, unlike the reference game's.[/b] Nothing on this node knows
## the arena killed it: a dead player here is a body standing where it fell until dot-match's
## respawn teleports it, and a marker on that body marks where the player is.
##
## Placed at the SIMULATED position, the one the client's camera follows: the render state
## on the local player and the interpolated one on a remote player, both written into
## `controller.state` once a frame.
func present_beacon(delta: float, local_view: bool) -> bool:
	if not beacon:
		if beacon_marker != null:
			beacon_marker.queue_free()
			beacon_marker = null
		return false

	if beacon_marker == null:
		beacon_marker = DotFxBeacon.new()
		beacon_marker.name = "Beacon"
		# Red-orange, the colour nothing in a grey dev-textured sandbox is, and brighter than
		# the warm props a player spawns. Ping off: the game plays its own catalogue ping
		# (BEACON_SOUND) from advance()'s return, so the node's would be heard twice.
		beacon_marker.colour = Color(1.0, 0.24, 0.14)
		beacon_marker.ring_radius = 0.78
		beacon_marker.column_height = 14.0
		beacon_marker.column_base = 2.1
		beacon_marker.ping_enabled = false
		add_child(beacon_marker)

	beacon_marker.local_view = local_view
	beacon_marker.global_position = controller.state.position if controller != null \
		else global_position

	return beacon_marker.advance(delta)


func describe() -> Dictionary:
	return {
		"id": String(player_id),
		"name": display_name,
		"style": String(movement_style.id) if movement_style != null else "-",
		"speed": "%.1f m/s" % speed(),
		"run": str(timer.get("run")) if timer != null else "-",
		"blinded": blinded,
		"beacon": beacon,
	}


## Set by [method teleport], read once by [method take_teleported].
var _teleported: bool = false


## Whether this player was teleported since the last call, and forgets it. Read once a tick
## by a run timer's replay recorder, so a ghost is not smeared across a teleport.
func take_teleported() -> bool:
	var was := _teleported
	_teleported = false
	return was
