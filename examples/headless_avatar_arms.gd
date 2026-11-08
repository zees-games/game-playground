extends DotGameCheckSuite

const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundViewGrip := preload("../game/playground_view_grip.gd")
const PlaygroundZee := preload("../game/playground_zee.gd")
const PlaygroundWeaponDef := preload("../game/weapons/playground_weapon_def.gd")

## The avatar owns the arms; a weapon brings only the gun and where to hold it. One arms rig
## per player, the same arms and body whatever is held (only the pose moves), a remote
## player's body unchanged by its gun, no second copy of the gun in first person, and a
## first-person model for every weapon in the catalogue, workshop and provider packs included.
## Run: godot --headless --path . res://examples/headless_avatar_arms.tscn

const SECTIONS := 4
## Where the avatar holds a gun's grip, in camera metres (PlaygroundClientBase.HAND_SEAT).
const HAND_SEAT := Vector3(0.16, -0.2, -0.36)

var _entered := 0
var _completed := 0
var _client: PlaygroundClient = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-playground: avatar-owned arms")
	_client = PlaygroundClient.new()
	_client.name = "Client"
	_client.fetch_content = false
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	_client.config = config
	add_child(_client)
	for _i in range(600):
		await get_tree().process_frame
		if _client.gate != null and _client.gate.is_open() and _client.player != null:
			break
	_client.mouse_capture_override = true
	if _client.player != null:
		await _hold(&"zee_pistol")
	if _check(_client.player != null and _client.zee_view != null, "the client is up with a player and, armed, a view model"):
		await _test_one_rig()
		await _test_catalogue()
		await _test_view_modes()
		await _test_remote()
	_report_sections(_entered, _completed, SECTIONS)


func _weapons() -> Array[PlaygroundWeaponDef]:
	var out: Array[PlaygroundWeaponDef] = []
	for def in _client.playground.weapons:
		if PlaygroundZee.is_zee(def):
			out.append(def)
	return out


func _hold(id: StringName) -> void:
	_client._set_tool(id)
	for _i in range(10):
		await get_tree().process_frame
	_client._present_view_arms(0.016)


func _count(root: Node, cls: StringName) -> int:
	var n := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var s: Script = node.get_script()
		if s != null and s.get_global_name() == cls:
			n += 1
		for c in node.get_children(true):
			stack.append(c)
	return n


## Drawn meshes under [param root], not counting anything under [param skip].
func _meshes(root: Node, skip: Node = null) -> int:
	var n := 0
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		if skip != null and is_instance_valid(skip) and (mi == skip or skip.is_ancestor_of(mi)):
			continue
		if (mi as MeshInstance3D).is_visible_in_tree() and (mi as MeshInstance3D).mesh != null:
			n += 1
	return n


## Bare hands are the one weapon with nothing to hold: zee's fists, which ship no model.
func _bare(def: PlaygroundWeaponDef) -> bool:
	var art: Variant = ZeeWeaponArtTable.table().get(PlaygroundZee.zee_id(def))
	return PlaygroundZee.zee_id(def) == ZeeWeaponIds.FISTS and art is ZeeWeaponArt and not (art as ZeeWeaponArt).has_model()


func _test_one_rig() -> void:
	_entered += 1
	print("One arms rig")
	await _hold(&"zee_pistol")
	_check(_count(_client, &"DotPlayerViewArms") == 1, "exactly one avatar arms rig on the client", str(_count(_client, &"DotPlayerViewArms")))
	_check(_count(_client, &"ZeeViewArms") == 0, "and no weapon-owned arms")
	_check(_client.zee_view != null and not _client.zee_view.show_arms, "the view model draws no hands of its own")
	_check(_count(_client, &"ZeeViewModel") == 1,
		"one first-person view model", str(_count(_client, &"ZeeViewModel")))
	_completed += 1


## Every weapon: a model in the first-person view on the same arms, the hand seated where the
## avatar holds a gun, the arms and body untouched by the swap.
func _test_catalogue() -> void:
	_entered += 1
	print("Every weapon on the avatar's arms")
	_client.player.set_view_mode(false)
	var weapons := _weapons()
	_check(weapons.size() >= 20, "the catalogue lists the weapons", str(weapons.size()))
	var arms_rig := _client.view_arms as DotPlayerViewArms
	var arms: Node3D = arms_rig.arms() if arms_rig != null else null
	var arms_scale := arms.transform.basis.get_scale() if arms != null else Vector3.ZERO
	var body: Node3D = _client.player.character.body() if _client.player.character != null else null
	var body_scale := body.global_transform.basis.get_scale() if body != null else Vector3.ZERO
	var body_meshes := -1
	var lacking: PackedStringArray = []
	var reshaped: PackedStringArray = []
	var unseated: PackedStringArray = []
	var doubled: PackedStringArray = []
	var bare := 0
	for def in weapons:
		await _hold(def.id)
		var wid := String(def.id)
		if _bare(def):
			bare += 1
		elif _meshes(_client.zee_view) == 0 or _client.zee_view.equipped() != PlaygroundZee.zee_id(def):
			lacking.append(wid)
		var now_arms: Node3D = arms_rig.arms() if arms_rig != null else null
		if now_arms != arms or _count(_client, &"DotPlayerViewArms") != 1 \
				or not now_arms.transform.basis.get_scale().is_equal_approx(arms_scale) \
				or body == null or not body.global_transform.basis.get_scale().is_equal_approx(body_scale):
			reshaped.append(wid)
		var own := _meshes(body, _client.player.zee_world) if body != null else 0
		if body_meshes < 0:
			body_meshes = own
		elif own != body_meshes:
			reshaped.append("%s (body meshes %d, was %d)" % [wid, own, body_meshes])
		if _client.held_grip != null and _client.zee_view.aim_fraction() <= 0.0:
			var at := _client.camera.global_transform.affine_inverse() * _client.held_grip.grip_world()
			if at.distance_to(HAND_SEAT) > 0.03:
				unseated.append("%s %s" % [wid, at])
		if _count(_client, &"ZeeViewModel") != 1 or _count(_client.player, &"ZeeWorldModel") > 1:
			doubled.append(wid)
	_check(lacking.is_empty(), "every weapon draws a first-person model (%d weapons, %d bare hands)" % [weapons.size(), bare], ", ".join(lacking))
	_check(reshaped.is_empty(), "no weapon swaps or rescales the arms or the body", ", ".join(reshaped))
	_check(unseated.is_empty(), "the firing hand sits at the avatar's seat for every weapon", ", ".join(unseated))
	_check(doubled.is_empty(), "never a second view or world model", ", ".join(doubled))
	_completed += 1


## In first person the own world gun only casts a shadow (else it doubles the view model's);
## in third person it is the gun that is seen.
func _test_view_modes() -> void:
	_entered += 1
	print("The held gun in each view")
	for id: StringName in [&"zee_sniper", &"zee_pistol"]:
		_client.player.set_view_mode(false)
		await _hold(id)
		var world := _client.player.zee_world as Node3D
		if not _check(world != null and is_instance_valid(world), "%s: the body holds a world model" % id):
			continue
		var geo := world.find_children("*", "GeometryInstance3D", true, false)
		_check(not geo.is_empty() and geo.all(func(g: Node) -> bool: return (g as GeometryInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY),
			"%s: in first person the body's gun only casts a shadow" % id)
		_check(_meshes(_client.zee_view) > 0, "%s: and the view model is what is seen" % id)
		_client.player.set_view_mode(true)
		_client._present_view_arms(0.016)
		_check(geo.all(func(g: Node) -> bool: return is_instance_valid(g) and (g as GeometryInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON),
			"%s: in third person the body's gun is drawn" % id)
	_client.player.set_view_mode(false)
	_completed += 1


## A remote player's body: the same figure whatever they hold, one gun on its hand, the same
## art the local view draws for that weapon.
func _test_remote() -> void:
	_entered += 1
	print("A remote player")
	var remote := _client.playground.add_player(&"u_remote", "Bea")
	for _i in range(4):
		await get_tree().process_frame
	if not _check(remote != null and remote.character != null and remote.character.body() != null, "a remote player has a body"):
		_completed += 1
		return
	var body := remote.character.body()
	var body_scale := body.global_transform.basis.get_scale()
	var figures := _count(remote, &"DotHumanoidFigure")
	var meshes := -1
	var changed: PackedStringArray = []
	var missing: PackedStringArray = []
	for def in _weapons():
		PlaygroundZee.show_held(remote, def)
		await get_tree().process_frame
		var world := remote.zee_world as ZeeWorldModel
		if _bare(def):
			continue
		if world == null or world.equipped() != PlaygroundZee.zee_id(def) or _meshes(world) == 0 or _count(remote, &"ZeeWorldModel") != 1:
			missing.append(String(def.id))
		var own := _meshes(body, world)
		if meshes < 0:
			meshes = own
		if own != meshes or _count(remote, &"DotHumanoidFigure") != figures or not body.global_transform.basis.get_scale().is_equal_approx(body_scale):
			changed.append(String(def.id))
	_check(_count(remote, &"DotPlayerViewArms") == 0, "a remote player carries no first-person arms")
	_check(missing.is_empty(), "a remote player's hand holds one model of every weapon", ", ".join(missing))
	_check(changed.is_empty(), "and its body is the same whatever it holds", ", ".join(changed))
	_completed += 1
