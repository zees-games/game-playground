extends RefCounted

## The test provider: shows the whole spawn-provider contract in one file (docs/spawn-providers.md).
## Duck-typed on purpose, no class_name: a pack never names a type the playground owns.

## Set by the suite so the weapon entry names a weapon the catalogue really has.
static var weapon_id: String = ""
static var custom_calls: Array = []


func spawn_entries() -> Array:
	return [
		{"category": "Weapons", "id": "test_gun", "name": "Test gun", "kind": "weapon",
			"spawn": weapon_id, "cfg_hint": {}},
		{"category": "Weapons", "id": "unknown_gun", "name": "Missing gun", "kind": "weapon",
			"spawn": "no_such_weapon_anywhere"},
		{"category": "NPCs", "id": "test_guard", "name": "Test guard", "kind": "npc",
			"spawn": "npc_soldier", "cfg_hint": {"count": 2}},
		{"category": "Bots", "id": "test_bot", "name": "Test bot", "kind": "bot",
			"spawn": func(c: Dictionary) -> DotResult:
				custom_calls.append(c)
				return DotResult.success("ok")},
		{"category": "Props", "id": "scene_npc", "name": "Scene NPC", "kind": "npc",
			"spawn": "res://examples/fixtures/spawn_pack/scene_npc.tscn"},
		{"category": "NPCs", "id": "stat_npc", "name": "Stat NPC", "kind": "npc",
			"spawn": {"health": 50, "speed": 3.0},
			"spawn_fn": func(c: Dictionary) -> DotResult:
				custom_calls.append(c)
				return DotResult.success("ok")},
		{"category": "NPCs", "id": "stat_only", "name": "Stats only", "kind": "npc", "spawn": {"health": 5}},
		{"id": "", "kind": "npc"},
		{"id": "bad_spawn", "kind": "npc", "spawn": 12},
		"not a dictionary",
	]
