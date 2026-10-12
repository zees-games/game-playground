extends DotPlayerModelVisual

## The player's body, drawn from a definition rather than loaded from art.
##
## [b]Every other project in this family installs dot-player-char and draws nothing with
## it.[/b] The catalogue is built, the metrics are read, and `DotPlayerCharVisual` —
## the abstract node the whole addon exists to fill — has no implementation anywhere. That
## was survivable while every game was first-person: nobody sees their own body. It stops
## being survivable the moment there is a third-person camera, which is what
## `PlaygroundPlayer.build_view_switch` added, and the first frame through it showed
## exactly what a player with no model looks like — an empty view four metres behind
## nothing.
##
## [b]Primitives, for this project's own stated reason.[/b] `PlaygroundIcons` draws a menu
## card from the three `meta` fields a prop's body is built from, so that a barrel is a
## green cylinder in the world and a green cylinder in the menu. A character here is the
## same argument one level up: the shipped `DotPlayerCharDef` carries height, radius and
## eye height, and those three numbers are enough to build a body that is the right size.
## A server with content points `DotPlayerModelDef.rig_scene` at a real rig and this class
## adopts it instead — which is the seam `DotPlayerModelRig.adopt` exists for.
##
## [b]It is not the local player's own view.[/b] `set_shown(false)` is what a first-person
## camera wants, and the switch drives it: a player looking through their own eyes must
## not see the inside of their own head, and one in third person must.

const CHANNEL := "playground.character"

const PlaygroundFigure := preload("playground_figure.gd")

## Parts of a body, as a fraction of the character's height.
const HEAD_FRACTION := 0.22
const TORSO_FRACTION := 0.46

var _built_for: StringName = &""
var _parts: Node3D = null

## Whether the body is posed sitting. See [method set_seated].
var _seated_pose := false
var _legs_height := 0.0
var _leg_radius := 0.0


## Builds a body the size the character definition says, under an adopted rig.
##
## [b]The rig is adopted rather than loaded[/b], which is what lets a project with no art
## use the whole addon: `DotPlayerModelRig.build_from` returns success and builds nothing
## when `rig_scene` is empty, and `adopt` hands it the node this class made instead. Every
## mount, every attachment and every tint then works exactly as it would over a real rig.
func build_for(
	def: DotPlayerCharDef, colour: Color,
	skins: PackedInt32Array = PackedInt32Array(), figure_key: String = ""
) -> void:
	if def == null:
		return

	# The skins are part of what was built: a member's avatar arriving after the join has to
	# rebuild a body that was built with the stock look.
	var built_key := StringName("%s|%s|%s" % [def.id, skins, figure_key])

	if _built_for == built_key and _parts != null and is_instance_valid(_parts):
		return

	_built_for = built_key

	if _parts != null and is_instance_valid(_parts):
		_parts.queue_free()

	# [b]Under the RIG, not under this node.[/b] `DotPlayerCharVisual` is a
	# `DotPlayerComponent`, which is a plain `Node` — it has no transform, no `rotation`
	# and no `visible`, because a component is a behaviour rather than a place. The rig
	# is the `Node3D`, which is also what `set_shown` hides and what the mounts hang off.
	# Parenting the body to this node instead gave a character that could not be turned
	# and could not be hidden, with a runtime error per tick and nothing drawn.
	if rig == null:
		rig = DotPlayerModelRig.new()
		rig.name = "Rig"
		add_child(rig)

	# Onto the player, which is what places it. dot-player-char does this itself now — a rig
	# kept under the visual, a plain Node, inherited no transform and stood at the world
	# origin for every player — and this is only for the one path above where this class
	# made the rig before the visual's own `_ready` could.
	var _seated := seat()

	_parts = Node3D.new()
	_parts.name = "Body"
	rig.add_child(_parts)

	var height := maxf(def.height, 0.4)
	var radius := maxf(def.radius, 0.1)

	var head_height := height * HEAD_FRACTION
	var torso_height := height * TORSO_FRACTION
	var legs_height := maxf(height - head_height - torso_height, 0.05)

	# The kit's figure when this build has it, so a person looks like a person and a member
	# looks like what they chose on the site; the capsules otherwise, which is what a build
	# without the art (a suite with no assets, a server stripped of them) still draws.
	var figure := PlaygroundFigure.build(height, skins, figure_key) if figure_key != "" or not skins.is_empty() else null

	if figure != null:
		_parts.add_child(figure)
		# The rig finds its mounts by name (`_model_def`), and the eye mount is the head: the
		# capsules were those nodes, so with a figure they are markers at the same heights.
		for marker: Array in [["Head", legs_height + torso_height + head_height * 0.5], ["Torso", legs_height + torso_height * 0.5]]:
			var mount := Node3D.new()
			mount.name = marker[0]
			mount.position = Vector3(0.0, float(marker[1]), 0.0)
			_parts.add_child(mount)
	else:
		_capsule("Legs", radius * 0.85, legs_height, legs_height * 0.5, colour.darkened(0.35))
		_capsule(
			"Torso", radius, torso_height, legs_height + torso_height * 0.5, colour
		)
		# A head has to be WIDER than it is tall to read as a head at this size. The entity
		# icons in the spawn menu had the opposite problem — a torso that spanned the full
		# height covered the head entirely and every NPC in the menu came out a coloured bar.
		_sphere(
			"Head",
			radius * 0.78,
			legs_height + torso_height + head_height * 0.5,
			colour.lightened(0.25)
		)

		# A nose, so a body four metres away has a visible FACING. Without one a capsule
		# looks identical from every angle and a third-person camera behind a player who has
		# turned round shows no change at all — which reads as the turn not working.
		_marker(
			"Facing",
			radius * 0.3,
			legs_height + torso_height + head_height * 0.5,
			-radius * 0.9,
			colour.lightened(0.5)
		)

	# Where a held weapon hangs: in front of the torso's right side, not its middle. The
	# mount named the torso until zee-dot-weapons' world model arrived, and a rifle hung at
	# the torso's centre is a rifle inside a capsule with two pixels of barrel showing.
	var hand := Node3D.new()
	hand.name = "RightHand"
	hand.position = Vector3(radius * 0.75, legs_height + torso_height * 0.55, -radius * 0.85)
	_parts.add_child(hand)

	_legs_height = legs_height
	_leg_radius = radius * 0.85
	_apply_pose()

	rig.adopt(_parts, _model_def(def))

	DotLog.debug(CHANNEL, "body built", {
		"char": String(def.id), "height": height, "radius": radius
	})


## Whether the rig is where the body is. Read by the suites.
func is_on_body() -> bool:
	return is_seated()


## Turns the body to face [param yaw], in radians.
##
## On the rig rather than on this node: a component has no transform. Without this a
## third-person camera orbiting a player shows a character who never turns, which reads as
## the model being broken.
func face(yaw: float) -> void:
	if rig != null:
		# The whole rotation, not only its yaw: a ride leaves the car's pitch and roll on the
		# rig through `face_basis`, and writing `.y` alone kept them after getting out — a
		# player standing tilted for good.
		rig.rotation = Vector3(0.0, yaw, 0.0)


## Turns the body to sit the way [param basis] faces, in world space: the vehicle's, for a
## rider. Global rather than local because a rider's node is carried inside the vehicle on
## the machine that runs the ride and is not on any other, and the body has to face the car's
## way on both.
func face_basis(basis: Basis) -> void:
	if rig != null and rig.is_inside_tree():
		rig.global_basis = basis.orthonormalized()


## Sits the body down, or stands it up.
##
## [b]A rider was drawn as a standing 1.8 m figure.[/b] dot-vehicle carries the rider's node
## to the seat — its origin is where the rider sits — and the body hangs off that node, so a
## passenger in the open buggy stood bolt upright through the seat with their legs through
## the floor and their head two metres above it. The body is primitives, and dot-player-char's
## locomotion set has no sitting clip to play, so the pose is the parts moved: the legs laid
## forward at seat height, the torso on the seat, the head and the facing mark with it. The
## seat offset is the SEAT, not the floor, which is why the torso starts at zero here.
##
## Not hidden, which is what mg-buses-from-hell does with a driver — there the bus IS the
## driver, and a body inside a closed cab would never be seen. The buggy is open and the
## hover sled is a bench, so a hidden rider is a car driving itself.
func set_seated(seated: bool) -> void:
	if _seated_pose == seated:
		return
	_seated_pose = seated
	_apply_pose()


## The drawn body (the kit's figure or the capsules): what a death copies into a ragdoll and
## hides until the player is back. Null before [method build_for].
func body() -> Node3D:
	return _parts if _parts != null and is_instance_valid(_parts) else null


## Tells the person how the player moves this frame and advances its clip: `speed`,
## `vertical`, `on_floor`, `crouched`, `aim` (a seated player is drawn `seated`). Once a frame,
## from the client, for every player; a capsule ignores it.
func move_person(motion: Dictionary) -> void:
	var person := _parts.get_node_or_null(^"Figure") as DotHumanoidFigure if _parts != null else null
	if person == null:
		return
	var now := Time.get_ticks_usec()
	var delta := 0.0 if _moved_usec < 0 else clampf((now - _moved_usec) / 1e6, 0.0, 0.1)
	_moved_usec = now
	var wanted := motion.duplicate()
	if _seated_pose:
		# The made sitting pose: thighs along the cushion, shins hanging, whatever the car's speed.
		wanted["seated"] = true
		wanted["crouched"] = false
		wanted["on_floor"] = true
		wanted["speed"] = 0.0
	else:
		wanted["seated"] = false
	person.set_motion(wanted)
	person.animate(float(wanted.get("speed", 0.0)), delta)


var _moved_usec: int = -1


func is_seated_pose() -> bool:
	return _seated_pose


func _apply_pose() -> void:
	if _parts == null or not is_instance_valid(_parts):
		return

	var drop := _legs_height if _seated_pose else 0.0

	for part: Node in _parts.get_children():
		var node := part as Node3D
		if node == null:
			continue

		if not node.has_meta(&"standing_y"):
			node.set_meta(&"standing_y", node.position.y)

		var standing_y := float(node.get_meta(&"standing_y"))

		if node.name == &"Figure":
			# Seated plays the person's made sitting pose (`seated`, [method move_person]), whose
			# thighs are `seat_height()` over its origin: this node's origin is the seat, so the
			# figure goes that far under it. Drawn as a crouch lowered by half the legs before,
			# a rider was somebody squatting over the cushion.
			var person := node as DotHumanoidFigure
			node.position.y = standing_y - (person.seat_height() if _seated_pose and person != null else 0.0)
		elif node.name == &"Legs":
			if _seated_pose:
				# Laid forward (-Z) along the seat, at the height of a thigh on a cushion.
				node.rotation = Vector3(PI * 0.5, 0.0, 0.0)
				node.position = Vector3(0.0, _leg_radius, -_legs_height * 0.5)
			else:
				node.rotation = Vector3.ZERO
				node.position = Vector3(0.0, standing_y, 0.0)
		else:
			node.position.y = standing_y - drop


## Whether the body is currently drawn. For a suite, and for a HUD that says so.
func is_body_visible() -> bool:
	return rig != null and rig.visible


## A model definition for a rig that is built rather than loaded.
##
## `rig_scene` is deliberately empty: it is what tells `DotPlayerModelRig.build_from` to
## build nothing and wait for `adopt`. The mounts name nodes this class makes, so
## `attachment(&"right_hand")` answers for a weapon the same way it would over real art.
func _model_def(char_def: DotPlayerCharDef) -> DotPlayerModelDef:
	var def := DotPlayerModelDef.new()
	def.id = char_def.id
	def.display_name = char_def.display_name
	def.rig_scene = ""
	def.mounts = {"head": "Head", "torso": "Torso", "right_hand": "RightHand"}
	def.weapon_mount = &"right_hand"
	def.eye_mount = &"Head"
	return def


func _capsule(
	part_name: String, radius: float, height: float, y: float, colour: Color
) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	# A CapsuleMesh's height INCLUDES its two hemispherical caps, so a height below twice
	# the radius is refused by the engine and clamped — which silently makes a short, fat
	# part the wrong size rather than erroring.
	mesh.height = maxf(height, radius * 2.0 + 0.01)
	_add_mesh(part_name, mesh, y, colour)


func _sphere(part_name: String, radius: float, y: float, colour: Color) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	_add_mesh(part_name, mesh, y, colour)


func _marker(
	part_name: String, radius: float, y: float, z: float, colour: Color
) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0

	var node := _add_mesh(part_name, mesh, y, colour)

	if node != null:
		node.position.z = z


func _add_mesh(
	part_name: String, mesh: Mesh, y: float, colour: Color
) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	# Unshaded, like every other surface this project draws: the sandbox has no lights
	# worth speaking of and a lit primitive at this size reads as a grey blob.
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var node := MeshInstance3D.new()
	node.name = part_name
	node.mesh = mesh
	node.material_override = material
	node.position.y = y
	_parts.add_child(node)
	return node
