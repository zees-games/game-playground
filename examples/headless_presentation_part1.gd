extends DotGameCheckSuite

const PlaygroundAmbience := preload("../game/playground_ambience.gd")
const PlaygroundInventory := preload("../game/playground_inventory.gd")
const PlaygroundParty := preload("../game/playground_party.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundTouch := preload("../game/client/playground_touch.gd")
const PlaygroundVote := preload("../game/playground_vote.gd")
const PlaygroundServices := preload("../game/playground_services.gd")
const PlaygroundSpawnables := preload("../game/playground_spawnables.gd")
const PlaygroundWorldGen := preload("../game/playground_worldgen.gd")
const PlaygroundHud := preload("../game/playground_hud.gd")
const PlaygroundClient := preload("../game/playground_client.gd")
const Playground := preload("../game/playground.gd")
const PlaygroundZee := preload("../game/playground_zee.gd")

var _entered := 0
var _completed := 0


func _make() -> PlaygroundPresentation:
	var p := PlaygroundPresentation.new()
	p.name = "P%d" % _entered
	add_child(p)
	p.setup()
	# The client builds the console after its menu; there is no menu here.
	p.build_console()
	p.settings.local_store = DotSettingsStoreMemory.new()
	p.settings.load_now()
	p.apply_all()
	return p


func _test_ambience_is_quiet_and_obeys_settings() -> void:
	_section("The ambience is quiet by default, follows the map and obeys the settings")

	var p := _make()
	var a := p.ambient
	_check(a != null and a.has_moods() and a.ambient.mood_names().size() == 8, "dot-audio's stock mood set loaded")
	if a == null or not a.has_moods():
		p.queue_free()
		_done()
		return
	a.ambient.set_process(false)
	_check(a.mood_for_map()["mood"] == &"outdoor_night", "the sandbox's default is a quiet night outdoors")
	p.on_map_changed(&"surf_ski_2")
	_check(a.ambient.effective_mood() == &"snow_wind" and a.mood_for_map()["why"] == "name prefix", "a surf map is wind")
	p.on_map_changed(&"pgc_warehouse")
	_check(a.ambient.effective_mood() == &"industrial", "the warehouse is machinery")
	a.map_lookup = func(id: StringName) -> Variant: return {"meta": {"ambient": {"level": 1.6, "lively": true}}} if id == &"zz_doc" else null
	p.on_map_changed(&"zz_doc")
	_check(p.ambience != null and is_equal_approx(p.ambience._gain(), p.ambience.level * 1.6), "on_map_changed(id) alone reaches the bed with the map definition's ambient.level through the lookup")
	p.on_map_changed(&"zz_plain")
	_check(p.ambience != null and is_equal_approx(p.ambience._gain(), p.ambience.level), "and the next map without one is back at the quiet default")
	_check(a.ambient.config.enabled and a.ambient.config.volume <= 0.35, "the level is quiet by default (%.2f)" % a.ambient.config.volume)
	_check(a.ambient.target_level() < 0.5, "and the layer's target level is under half (%.2f)" % a.ambient.target_level())

	var _r1 := p.settings.set_value(&"ambient_volume", 0.5)
	_check(is_equal_approx(a.ambient.config.volume, PlaygroundAmbience.LEVEL * 0.5), "the player's slider turns it down")
	var _r2 := p.settings.set_value(&"ambient", false)
	_check(not a.ambient.config.enabled, "the player's switch turns it off")
	var _r3 := p.settings.set_value(&"ambient", true)
	var _r4 := p.settings.set_value(&"master_volume", 0.0)
	_check(p.audio.mixer.master == 0.0 and a.ambient.bus == &"Ambience", "the master volume reaches it through the Ambience bus")

	var rules := PlaygroundAmbience.make_rules()
	var names: Array = []
	for row: Array in DotAmbienceRules.VARS.values():
		names.append(rules.cvar_of(row))
	_check(names.has("pg_ambient") and names.has("pg_ambient_volume") and rules.volume == PlaygroundAmbience.LEVEL, "the cvars are pg_ambient* with the quiet defaults")
	_check(str(p.describe_lines()).contains("ambience"), "describe says what plays")

	p.queue_free()
	_done()


func _test_one_seed() -> void:
	_section("One seed behind the map, the props and the noises")

	var p := _make()
	_check(p.rng != null, "there is a randomness manager")
	_check(p.rng.current_seed() != 0, "with a seed, picked and announced")
	_check(
		DotRegistry.has(DotRandomManager.SERVICE),
		"published, which is how a generated map finds it without naming the addon"
	)

	# The property that makes one seed usable by four things: two named streams never
	# disturb each other, so adding a fourth consumer cannot change the map.
	var map_a := p.rng.stream(&"map")
	var audio_a := p.rng.stream(&"audio")
	var expected: Array[float] = []
	for _i in range(4):
		expected.append(map_a.unit_at(_i))
	for _i in range(500):
		audio_a.next()
	var same := true
	for i in range(4):
		if not is_equal_approx(map_a.unit_at(i), expected[i]):
			same = false
	_check(same, "500 draws for audio leave the map's stream exactly where it was")

	_check(
		p.rng.seed_for(&"map") != p.rng.seed_for(&"waves"),
		"and two subsystems derive different seeds from the one number"
	)
	_check(
		p.audio.roll_source != null,
		"the audio takes its variation from the session's seed, so two people watching "
		+ "the same sandbox hear the same thing"
	)

	p.queue_free()
	_done()


func _test_generated_map_is_walkable() -> void:
	_section("A generated sandbox nobody could cross is not shipped")

	var res := PlaygroundWorldGen.generate(4242)
	_check(res.ok, "a sandbox generates")
	if not res.ok:
		_done()
		return

	var doc := res.value as DotProcGenDoc
	_check(doc.rooms.size() >= 5, "with rooms in it (%d)" % doc.rooms.size())
	_check(
		doc.links.size() > doc.rooms.size() - 1,
		"and more corridors than a spanning tree, so it has loops rather than being a "
		+ "sequence (%d links for %d rooms)" % [doc.links.size(), doc.rooms.size()]
	)

	var spawns := doc.markers_of(&"spawn")
	_check(spawns.size() == 1, "there is a spawn")
	var spawn: Vector2i = spawns[0]["cell"]

	# The check that matters, and the one every other kind passes without: everything
	# placed can actually be walked to.
	var reached := doc.reachable_from(spawn)
	var reachable := {}
	for idx in reached:
		reachable[idx] = true

	var stranded := 0
	for m in doc.markers:
		var cell: Vector2i = m.get("cell", Vector2i.ZERO)
		if not reachable.has(cell.y * doc.width + cell.x):
			stranded += 1
	_check(stranded == 0, "and every prop point can be reached from it")

	# Two runs of one seed are one map, which is what lets a server and a client agree
	# without sending a map.
	var again := PlaygroundWorldGen.generate(4242)
	_check(
		(again.value as DotProcGenDoc).fingerprint() == doc.fingerprint(),
		"two runs of one seed produce the same map, to the byte"
	)
	var other := PlaygroundWorldGen.generate(4243)
	_check(
		(other.value as DotProcGenDoc).fingerprint() != doc.fingerprint(),
		"and a different seed a different one"
	)

	_done()


func _test_generation_refuses_rather_than_ships() -> void:
	_section("What a map that cannot be generated leaves behind")

	# Too small for the rooms the pipeline asks for. A generator that shipped this anyway
	# would produce one room and call it a sandbox.
	var tiny := PlaygroundWorldGen.pipeline(12, 12)
	tiny.max_attempts = 2
	var res := tiny.generate(1)
	_check(not res.ok, "a map too small to satisfy the pipeline fails rather than shipping")
	_check(
		res.error.message != "",
		"saying which step refused it, rather than producing something unplayable"
	)

	# And what the map does about it: a plate with walls, and a spawn on it. A partially
	# generated sandbox is a room with no way out, which is worse than an empty plate.
	var map := load("res://maps/pg_generated.gd").new() as Node3D
	add_child(map)
	map.call("configure", 4242, null)
	_check(
		map.get("document") != null,
		"a generated map that succeeded holds its document, for a console command"
	)
	var spawn: Vector3 = map.get("fallback_spawn")
	_check(spawn.y > 0.0, "and a spawn above the floor")
	# The lesson from the surf maps: a capsule that starts within a unit or two of a seam
	# is a coin toss whichever way the collision backend rounds.
	_check(spawn.y >= 1.0, "clear of the floor rather than resting exactly on it")
	_check(map.get_child_count() > 2, "with geometry under it")
	map.queue_free()
	_done()


func _test_the_backpack_is_the_prop_catalogue() -> void:
	_section("What you can carry is what this server can make")

	var props := PlaygroundSpawnables.catalogue()
	var items := PlaygroundInventory.build_catalogue(props)
	_check(items.validate().ok, "the item catalogue validates")

	# One list. A second table of what can be carried would go stale the first time
	# somebody added a prop, which is this tree's most repeated bug.
	_check(
		items.ids().size() == props.props.size(),
		"one item per prop (%d against %d)" % [items.ids().size(), props.props.size()]
	)

	var heavy: DotPropDef = null
	for d in props.props:
		if heavy == null or d.mass > heavy.mass:
			heavy = d
	var item := items.find(heavy.id)
	_check(item != null, "the heaviest prop has an item")
	_check(
		is_equal_approx(item.weight, maxf(heavy.mass, 1.0)),
		"whose weight is the prop's own mass, which until now exactly one thing read"
	)
	_check(
		item.kind == DotInvItem.Kind.UNIQUE,
		"and which does not stack, because every prop carries its own state once spawned"
	)

	_done()


func _test_carrying_is_a_refusal() -> void:
	_section("Buying holds something; spawning takes it out")

	var inv := PlaygroundInventory.new()
	inv.name = "Inventory"
	add_child(inv)
	var res := inv.setup(PlaygroundSpawnables.catalogue())
	_check(res.ok, "the inventory sets up")
	if not res.ok:
		_done()
		return

	var who := &"player_one"
	var id := inv.catalogue.ids()[0]

	# The whole feature: before this, the shop charged per spawn and nothing was ever
	# held, so "buy three crates" and "buy one crate three times" were the same thing.
	_check(
		not inv.take(who, id).ok,
		"taking something you are not carrying is refused"
	)
	_check(inv.give(who, id).ok, "buying puts one in the bag")
	_check(inv.carries(who, id) == 1, "and you are carrying it")
	_check(inv.take(who, id).ok, "spawning takes it out")
	_check(inv.carries(who, id) == 0, "leaving nothing")
	_check(not inv.take(who, id).ok, "and a second spawn is refused")

	# The grid and the weight are two different limits, and a refusal has to say which.
	var given := 0
	for _i in range(60):
		if inv.give(who, id).ok:
			given += 1
		else:
			break
	_check(given > 0, "a bag holds several")
	_check(given < 60, "and stops (%d), rather than being a list with no end" % given)

	var q := inv.query(who)
	_check(q.size() > 0, "and what is in it can be listed")
	_check(
		q.size() == inv.carries(who, id),
		"with the query agreeing with the count, because both read one document"
	)

	inv.queue_free()
	_done()


func _test_sounds_and_effects() -> void:
	_section("Somebody else's building, and the switch for it")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	p.audio.listener_position = Vector3.ZERO

	sink.forget()
	p.on_prop_spawned(Vector3(4, 0, 4), true)
	_check(sink.count_of(&"prop_spawn") == 1, "a prop you spawned makes a noise")

	sink.forget()
	for _i in range(10):
		p.on_prop_spawned(Vector3(4, 0, 4), true)
	_check(
		sink.count_of(&"prop_spawn") <= 3,
		"and ten in one tick make at most three (%d), because a dozen people emptying a "
		% sink.count_of(&"prop_spawn") + "spawn menu is a building site rather than a fault"
	)

	# The sandbox's own setting, and it is about somebody else's work rather than yours.
	p.settings.set_value(&"prop_sounds", false)
	sink.forget()
	p.on_prop_spawned(Vector3(4, 0, 4), false)
	_check(
		sink.count_of(&"prop_spawn") == 0,
		"somebody else's prop is silent for a player who turned that off"
	)
	# Past the cooldown the burst above used. A check that measures a sound while it is
	# being refused for a cooldown measures the cooldown, and reads as the setting being
	# broken in the other direction.
	OS.delay_msec(100)
	sink.forget()
	p.on_prop_spawned(Vector3(4, 0, 4), true)
	_check(
		sink.count_of(&"prop_spawn") == 1,
		"while your own still is, because it is the answer to something you just did"
	)

	sink.forget()
	p.on_refused()
	var refused := p.audio.catalogue.find(&"refused")
	var landed := p.audio.catalogue.find(&"prop_land")
	_check(sink.count_of(&"refused") == 1, "a refusal makes a noise")
	_check(
		refused.priority > landed.priority,
		"and outranks a crate hitting the floor, because it answers something you did"
	)

	OS.delay_msec(150)
	sink.forget()
	p.on_undo(Vector3(3, 0, 3), 1.0, false)
	_check(sink.count_of(&"undo") == 1, "an undo makes a noise")
	OS.delay_msec(150)
	sink.forget()
	var spatial := p.on_undo(Vector3(3, 0, 3), 1.0, true)
	_check(sink.count_of(&"undo_at") == 1 and spatial["at"] == Vector3(3, 0, 3), "which can come from where the thing was")
	sink.forget()
	_check(p.on_undo(Vector3.ZERO, 0.0, false).is_empty() and sink.count_of(&"undo") == 0, "and is silent at volume zero")

	p.settings.set_value(&"shake_scale", 0.0)
	p.on_tool_punt(Vector3.ZERO, true)
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(
		p.camera_shake() == Vector3.ZERO,
		"and a player who turned shake off gets exactly none of it"
	)

	p.queue_free()
	_done()


## [b]Every effect scene the catalogue names exists, and the effects actually spawn.[/b]
## `scenes/fx/` once did not exist and dot-fx refused both scenes quietly; nothing asked whether anything drew.
func _test_breaks_throw_pieces() -> void:
	_section("Broken props and panes throw splinters and shards")

	var p := _make()
	var at := Vector3(0, 1, -6)
	# dot-fx draws nothing headless unless told to.
	p.break_fx.break_fx.config.headless = true
	p.break_fx.shatter(at, p.BreakFx.material_of(&"crate"))
	_check(p.break_fx.break_fx.spawned == 1, "a crate breaking draws one burst", str(p.break_fx.break_fx.spawned))
	p.on_pane_broken(at)
	_check(p.break_fx.break_fx.spawned == 2, "a pane breaking draws glass", str(p.break_fx.break_fx.spawned))
	_check(p.BreakFx.material_of(&"barrel") == 2 and p.BreakFx.material_of(&"die") == 3, "barrels are metal and dice plastic")
	p.break_fx.shatter(at, 99)
	_check(p.break_fx.break_fx.spawned == 2, "an index past the table draws nothing")
	var _r := p.settings.set_value(&"fx_quality", 0, &"test")
	p.break_fx.shatter(at, 1)
	_check(p.break_fx.break_fx.spawned == 2, "fx_quality 0 draws nothing", p.break_fx.break_fx.last_refusal)
	_done()


func _test_effects_draw() -> void:
	_section("The effects this game names are drawn")

	var p := _make()
	var missing := p.fx.catalogue.missing_scenes()
	_check(missing.is_empty(), "every effect scene the catalogue names exists",
		", ".join(missing))

	# Looking at where the prop appears: dot-fx culls an effect behind the viewer.
	var at := Vector3(0, 1, -6)
	p.present(0.016, Vector3(0, 1.7, 0), Vector3.FORWARD)
	var drawn: Array[Node] = []
	p.fx.spawned.connect(func(id: StringName, node: Node, _why: StringName) -> void:
		if id == &"prop_spawn" and node != null:
			drawn.append(node)
	)
	p.on_prop_spawned(at, true)
	_check(drawn.size() == 1, "a prop you spawned puffs")
	_check(
		not drawn.is_empty() and (drawn[0] as Node3D).global_position.is_equal_approx(at),
		"where the prop appeared"
	)

	var eye := Vector3(0, 1.7, 0)
	var aim := Vector3(0, 0, -1)
	var held := Vector3(2, 1, -8)
	var beam := p.on_tool_beam(eye, aim, held)
	_check(beam != null, "the physics gun draws a beam")
	var start := beam.global_position if beam != null else eye
	_check(
		(start - eye).dot(aim) > 0.2 and start.y < eye.y,
		"starting in front of and below the eye, not in it",
		str(start)
	)
	var tip := beam.global_transform * Vector3(0, 0, -1) if beam != null else Vector3.ZERO
	_check(
		tip.distance_to(held) < 0.001,
		"and ending on what it holds",
		"%s against %s" % [tip, held]
	)
	var moved := Vector3(-3, 2, -5)
	var again := p.on_tool_beam(eye, aim, moved)
	_check(
		again == beam and (again.global_transform * Vector3(0, 0, -1)).distance_to(moved) < 0.001,
		"a held prop that moves moves the same beam, rather than stacking another"
	)

	# Past its 100 ms ceiling dot-fx retires it; the next frame's call draws a new one.
	OS.delay_msec(130)
	p.present(0.016, eye, aim)
	var fresh := p.on_tool_beam(eye, aim, held)
	_check(
		fresh != null and fresh != beam and not fresh.is_queued_for_deletion(),
		"and a beam past its ceiling is replaced in the same frame, so a hold never flickers"
	)

	p.queue_free()
	_done()


func _test_blood() -> void:
	_section("A hit on a body leaves blood on the wall behind it")

	var p := _make()
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10, 10, 0.5)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(0, 0, -5)
	add_child(wall)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var npc := DotEntity.make_id(DotEntity.KIND_NPC, 1)
	var prop := DotEntity.make_id(DotEntity.KIND_PROP, 1)
	var eye := Vector3(0, 1, 0)
	var at := Vector3(0, 1, -3)

	_check(p.decals.blood_count() == 0, "no blood to begin with")
	var s := p.on_body_hit(npc, at, eye)
	_check(s != null and p.decals.blood_count() == 1, "an NPC hit leaves one splatter")
	_check(
		s != null and absf(s.global_position.z - (-4.75)) < 0.3,
		"on the wall's face, not the victim",
		str(s.global_position) if s != null else "null"
	)
	_check(p.on_body_hit(prop, at, eye) == null, "a prop is not bled on")
	_check(p.on_body_hit(npc, at, at) == null, "no line, no splatter")

	var cfg := DotFxDecalConfig.new()
	cfg.max_blood = 4
	p.decals.apply_config(cfg)
	for i in 10:
		p.on_body_hit(npc, at, eye)
	_check(p.decals.blood_count() <= 4, "the cap holds (%d of 4)" % p.decals.blood_count())

	p.settings.set_value(&"gore", false)
	_check(p.decals.blood_count() == 0, "gore off clears the blood")
	_check(p.on_body_hit(npc, at, eye) == null and p.decals.blood_count() == 0, "and draws none")

	wall.queue_free()
	p.queue_free()
	_done()


func _test_the_vote_is_heard() -> void:
	_section("The map vote is heard: every cue its rules name is a sound here")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	var rules := PlaygroundVote.vote_rules()

	var named: Array[StringName] = []
	for id in [
		rules.cue_vote_start, rules.cue_vote_end, rules.cue_warning,
		rules.cue_runoff_warning, rules.countdown_cue_id(3),
	]:
		named.append(StringName(id))

	var missing: Array[String] = []
	for id in named:
		if id == &"" or not p.audio.catalogue.has(id):
			missing.append(String(id))
	_check(
		missing.is_empty(),
		"the rules name a cue for every moment, and each is in the catalogue (missing: %s)"
			% str(missing)
	)

	sink.forget()
	_check(p.on_vote_cue(StringName(rules.cue_vote_start)) != 0, "a ballot opening plays")
	p.on_vote_cue(&"")
	p.on_vote_cue(&"not_in_this_build")
	_check(
		sink.count_of(StringName(rules.cue_vote_start)) == 1
			and sink.count_of(&"not_in_this_build") == 0,
		"once, and an empty or unknown cue is silence"
	)

	p.queue_free()
	_done()


func _test_console() -> void:
	_section("The console, and the command this game needs most")

	var p := _make()
	_check(p.console != null and p.console_panel != null, "there is a console and a panel")
	_check(
		p.console.all_names().has("seed"),
		"with `seed` in it -- a generated map nobody can name the seed of is a map "
		+ "nobody can share"
	)

	var missing := PackedStringArray()
	for key in PlaygroundPresentation.schema().keys():
		if not p.console.all_names().has(String(key)):
			missing.append(String(key))
	_check(missing.is_empty(), "every setting is reachable (%s)" % ", ".join(missing))

	var res := p.console.submit("seed")
	_check(res.ok, "asking for the seed works")

	p.console.submit("fx_quality 0")
	_check(p.fx.config.quality == 0, "a console line reaches the effects config")

	p.console.submit("rcon_password hunter2")
	_check(
		not p.console.buffer.to_text().contains("hunter2"),
		"a credential never reaches the scrollback"
	)

	p.queue_free()
	_done()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1
