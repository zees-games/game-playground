extends DotNetBehaviour

const PlaygroundNetBridge := preload("playground_net_bridge.gd")
const PlaygroundNetCommand := preload("playground_net_command.gd")
const PlaygroundPlayer := preload("../playground_player.gd")
const PlaygroundZee := preload("../playground_zee.gd")

## What a networked playground player replicates: the movement state, and an
## administrator's two marks.
##
## No run timer is replicated. A server that added dot-timer (`addons/pg_timer`) times on
## both ends: a client runs its own timer over its own copy of the zones for its HUD, and
## the server's verdict on a finish arrives as an addon message.
##
## The props a player spawns are NOT here either. They are their own entities with their
## own behaviour, because a prop outlives the player who spawned it and a barrel punted
## across the map is not part of anybody's movement state.

var player: PlaygroundPlayer = null
var bridge: PlaygroundNetBridge = null

var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var net_crouch: float = 0.0
var net_flags: int = 0
var net_modifiers: int = 0

# --- An administrator's marks, from PlaygroundModTools ---

## `PlaygroundPlayer.blinded`. Owner only: see [method _register_net_vars].
var net_blind: bool = false

## `PlaygroundPlayer.beacon`. Everybody's.
var net_beacon: bool = false

## `PlaygroundPlayer.creative`. Everybody's: a watcher sees who is building, and the client's
## own tools refuse a creative player's props before asking.
var net_creative: bool = false
## `PlaygroundPlayer.downed`. Everybody's: the figure crawls on every client.
var net_downed: bool = false

# --- A zee weapon, from `ZeeWeaponNet.all_specs()` ---
#
# Seven fields, because GDScript has no dynamic properties and the spec table names one
# variable each. The magazine and the reserve are `owner_only`, as mg-smash-copter's are.

var net_slot: int = 0
var net_magazine: int = 0
var net_reserve: int = 0
var net_fire_seq: int = 0
var net_fire_kind: int = 0
var net_reloading: bool = false
var net_switching: bool = false

## The fire counter this watcher last acted on, so a wrap reads as uses.
var _seen_fire_seq: int = 0

## Retained, not cleared: a player whose packet was lost keeps moving in a straight line
## rather than stopping dead. The controller says the same of its own command.
var last_move: DotFpsCommand = DotFpsCommand.new()
var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in DotFpsNetSync.state_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])
		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))
		if bool(spec["interpolated"]):
			declaration.interpolated()
		if spec["property"] == &"net_crouch":
			declaration.range_of(0.0, 1.0)

	# [b]Per-player state rather than an event, and that is what makes both of these
	# survive what an event does not.[/b] A client that joins after the admin typed
	# `beacon`, a snapshot lost on the way, a map change: each is a baseline the next
	# snapshot corrects, where an event sent once is simply missed. Two bits, and nothing
	# at all on a tick where neither changed.
	#
	# The blind goes to its owner alone. Nobody else's screen changes, and with the arena
	# on an opponent who received it would know the moment somebody could not see them.
	#
	# [b]No relevance change for the beacon, unlike the reference game's.[/b] Every player
	# here is already `always_relevant` (`PlaygroundNetBridge._build_entity`), so a beaconed
	# one reaches every client however far away they are with nothing added — and a beacon
	# that switched relevance off when it was lifted would cut every player it had ever
	# marked out of everybody else's world.
	replicate(&"net_blind", DotNetVar.Type.BOOL).to_owner_only()
	replicate(&"net_beacon", DotNetVar.Type.BOOL)
	replicate(&"net_creative", DotNetVar.Type.BOOL)

	for spec in ZeeWeaponNet.all_specs():
		var weapon := replicate(spec["property"], DotNetVar.Type[spec["type"]])
		if int(spec["bits"]) > 0:
			weapon.bits(int(spec["bits"]))
		if bool(spec["interpolated"]):
			weapon.interpolated()
		if bool(spec["owner_only"]):
			var _owner := weapon.to_owner_only()

	# Last, so the fields before it keep their places in the schema.
	replicate(&"net_downed", DotNetVar.Type.BOOL)


func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as PlaygroundNetCommand
	if command != null:
		last_move = command.move


## On the authority the whole game ticks as one — every entity moves, then every player,
## then every timer sees the positions those moves produced — so the first behaviour
## through drives the game and the rest find it done. On a predicting client there is one
## predicted player, and simulating it directly is the whole of what a client may
## compute: the props are rigid bodies and a client cannot reproduce them.
func _net_simulate(tick: int, delta: float) -> void:
	if player == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_game_ticked(tick)
	elif player.riding:
		# A rider is not predicted, because a rider is not walking. The controller is the
		# thing that would be predicting, and while its owner is in a vehicle it has no
		# answer to predict: the vehicle's position comes from the server, it is not
		# reproducible across machines, and a controller simulating on top of it fights
		# every snapshot at a metre a time. The command is still applied so the driver's
		# keys are in the input the predictor sends — which is the whole of what a
		# driving client does.
		player.controller.apply_command(last_move.duplicate_command())
	else:
		player.controller.apply_command(last_move.duplicate_command())
		player.controller.simulate_tick(tick, delta)

	pull()


func pull() -> void:
	if player != null:
		DotFpsNetSync.pull(player.controller.state, self)
		net_blind = player.blinded
		net_beacon = player.beacon
		net_creative = player.creative
		net_downed = player.downed
		# A rig that has gone leaves the last values: the counter stops, so nothing fires.
		if player.zee_rig != null:
			ZeeWeaponNet.pull(player.zee_rig, self)


## The server's answer, adopted wholesale. On the owner it is the rewind half of
## reconciliation and the predictor replays every unacknowledged command on top.
func _net_state_applied(tick: int) -> void:
	if player == null:
		return
	last_state_tick = tick
	DotFpsNetSync.push(self, player.controller.state)
	player.blinded = net_blind
	player.beacon = net_beacon
	player.creative = net_creative
	player.downed = net_downed
	_apply_weapon()
	_correct_drawn()
	# NOT the node, on a predicted entity: receive_snapshot calls this before the
	# predictor reconciles, and reconcile's first act is to read the node as "what the
	# client is showing". Moving it here makes the measured error the whole replay
	# distance and the correction rate reads as if every snapshot snapped. Both
	# HungryPieceNet and G2GPlayerNet shipped with that line.
	# ...unless they are riding, when there is no replay to spoil: nothing was predicted,
	# so the server's answer IS what the client should be showing. Without this the local
	# player's node — and the camera under it — stays where they got in, and the player
	# watches the car drive away from inside their own head.
	if identity == null or not identity.is_predicted() or player.riding:
		player.global_position = player.controller.state.position


## Every frame on a remote player. Without this the interpolator's work sits in a
## property nothing reads and the remote player moves in snapshot-sized steps.
func _net_interpolated(_tick: int) -> void:
	if player == null:
		return
	DotFpsNetSync.push(self, player.controller.state)
	player.global_position = player.controller.state.position


## The owner's own count (owner-only fields), put onto the gun this client draws once that has
## been quiet long enough for the server to have heard every shot it fired.
##
## [b]Nothing else ever writes the server's count back.[/b] The drawn rig simulates from the same
## buttons, so the two agree until the server refuses a shot or refills the gun (asking again for
## the gun in hand), and from then the HUD showed the client's own sum for good. The rig is only
## the drawn one on its owner: a LOCAL rig without the authority. Watchers have no rig, and the
## owner-only fields are stale on them.
func _correct_drawn() -> void:
	var rig: Variant = player.zee_rig
	if not (rig is ZeeWeaponRig) or not is_instance_valid(rig):
		return
	var drawn := rig as ZeeWeaponRig
	if drawn.authority or drawn.role != ZeeWeaponRig.Role.LOCAL:
		return
	var _corrected := PlaygroundZee.correct(drawn, net_magazine, net_reserve, net_slot,
		net_reloading or net_switching, player.zee_quiet)


## Somebody's zee weapon, as a watcher sees it: the world model kicks once per snapshot the
## fire counter moved in, however many shots that was. A counter, not an event per shot,
## for the reasons `ZeeWeaponNet.apply` gives.
func _apply_weapon() -> void:
	var held: Variant = player.zee_world
	var model: ZeeWorldModel = null
	if held is ZeeWorldModel and is_instance_valid(held):
		model = held as ZeeWorldModel

	var answer := ZeeWeaponNet.apply(self, model, _seen_fire_seq)
	_seen_fire_seq = int(answer["seq"])
