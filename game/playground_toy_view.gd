class_name PlaygroundToyView
extends Node3D

## The first-person model of a toy or tool (physics gun, launcher, tool gun, remover, impulse).
## It joins `dot_view_model` so the settings applier hands it `viewmodel_fov` like a zee gun.

## Vertical field of view the model is drawn at; 0 draws it under the camera's own lens.
var hands_fov: float = 0.0

var _kick: float = 0.0


## Builds the model for [param tool_id], tinted [param colour].
static func make(tool_id: StringName, colour: Color) -> PlaygroundToyView:
	var view := PlaygroundToyView.new()
	view.name = "ToyViewModel"
	view._build(tool_id, colour)
	return view


## The same horizontal-at-4:3 convention as ZeeViewModel, so the two weapons agree.
func set_hands_fov_at_4_3(horizontal: float) -> void:
	hands_fov = ZeeViewModel.vertical_from_horizontal_4_3(horizontal)


## A short recoil, for a toy that was just used.
func kick() -> void:
	_kick = 1.0


func _init() -> void:
	add_to_group(&"dot_view_model")


func _process(delta: float) -> void:
	_kick = maxf(0.0, _kick - delta * 6.0)
	var camera := get_parent() as Camera3D
	var k := ZeeViewModel.lens_scale(camera.fov, hands_fov) if camera != null else 1.0
	scale = Vector3(k, k, 1.0)
	var size := ZeeViewModel.lens_scale(ZeeViewModel.REFERENCE_FOV, hands_fov) if camera != null else 1.0
	position = Vector3(0.0, 0.0, -maxf((size - 1.0) * ZeeViewModel.REFERENCE_DEPTH, -ZeeViewModel.MAX_PULL_IN) + _kick * 0.05)


func _build(tool_id: StringName, colour: Color) -> void:
	var grip := Node3D.new()
	grip.name = "Grip"
	grip.position = Vector3(0.2, -0.22, -0.5)
	grip.rotation_degrees = Vector3(0.0, 6.0, 0.0)
	add_child(grip)
	var long_barrel := tool_id != &"impulse"
	var body := _box(Vector3(0.07, 0.08, 0.26), colour)
	grip.add_child(body)
	if long_barrel:
		var barrel := _box(Vector3(0.05, 0.05, 0.22), colour.darkened(0.35))
		barrel.position = Vector3(0.0, 0.01, -0.24)
		grip.add_child(barrel)
	else:
		var dome := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.06
		sphere.height = 0.12
		dome.mesh = sphere
		dome.material_override = _material(colour.lightened(0.2))
		dome.position = Vector3(0.0, 0.0, -0.17)
		grip.add_child(dome)
	var handle := _box(Vector3(0.045, 0.1, 0.05), colour.darkened(0.5))
	handle.position = Vector3(0.0, -0.08, 0.08)
	grip.add_child(handle)


func _box(size: Vector3, colour: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = _material(colour)
	return mesh


func _material(colour: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	return m
