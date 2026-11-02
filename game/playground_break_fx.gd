extends Node

## Splinters and shards where a prop or a pane breaks, drawn by dot-fx's DotFxBreak and following fx_quality.

## Wire index -> dot-fx material; append only, the index travels in SHATTER.
const MATERIALS: PackedStringArray = ["glass", "wood", "metal", "plastic"]
const KIND_OF_PROP := {
	&"plank": 1, &"beam": 1, &"panel": 1, &"crate": 1, &"crate_large": 1,
	&"barrel": 2, &"can": 2, &"die": 3,
}

var break_fx: DotFxBreak = null


func setup(settings: Object) -> void:
	break_fx = DotFxBreak.new()
	break_fx.name = "Break"
	add_child(break_fx)
	break_fx.follow(settings)


## The wire index for a broken prop of [param prop_id]; wood for anything unlisted.
static func material_of(prop_id: StringName) -> int:
	return int(KIND_OF_PROP.get(prop_id, 1))


func shatter(at: Vector3, material: int, size: float = 1.0) -> void:
	if break_fx != null and material >= 0 and material < MATERIALS.size():
		var _b := break_fx.burst(MATERIALS[material], at, Vector3.UP, size)
