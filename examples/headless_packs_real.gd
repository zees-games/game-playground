extends Node

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")
const PlaygroundProfiles := preload("../game/playground_profiles.gd")
const PlaygroundZee := preload("../game/playground_zee.gd")
const PlaygroundWeaponDef := preload("../game/weapons/playground_weapon_def.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundSpawnMenu := preload("../game/playground_spawn_menu.gd")
const PlaygroundWorkbench := preload("../game/playground_workbench.gd")

## The three real optional packs (zz-modern-weapons, zz-medieval-weapons, zz-historical-monsters) in
## the Q menu, not the fixture the main suite uses.
##
## [codeblock]
## godot --headless --path . res://examples/headless_packs_real.tscn
## [/codeblock]
##
## [b]Skips, visibly, when a pack is not linked[/b] (`addons/zz_*` is a gitignored symlink, see
## docs/development-setup.md): exit 0 with a SKIP line and no checks. Why it exists: a fixture's
## weapon spawn is a string; the real weapon packs hand a Dictionary and the definition behind a
## static `weapon_defs()`, and nothing but running them showed the playground refused every one.

const PACKS: Array[String] = ["zz_modern_weapons", "zz_medieval_weapons", "zz_historical_monsters"]
const MONSTERS: Array[String] = ["trex", "allosaurus", "raptor", "tiger", "thylacine", "bear"]
const CHECKS := 49
const SECTIONS := 7

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _skipped := 0
var _game: Playground = null
var _weapon_rows: Array = []
var _npc_rows: Array = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := PlaygroundPresentation.use_scratch_settings("headless_packs_real")
	_run.call_deferred()


func _run() -> void:
	print("playground - the real spawn packs")
	var missing: Array[String] = []
	for pack in PACKS:
		if not FileAccess.file_exists("res://addons/%s/spawn_provider.gd" % pack):
			missing.append(pack)
	if not missing.is_empty():
		print("  SKIP  not linked under res://addons: %s" % ", ".join(missing))
		get_tree().quit(0)
		return

	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.initial_map = &"pg_flatgrass"
	config.map_seconds = 0.0
	_game = Playground.new()
	_game.config = config
	add_child(_game)
	for _i in 120:
		await get_tree().process_frame
		if _game.maps != null and _game.maps.current != null:
			break

	_game.add_player(&"bot", "Bot")
	await get_tree().physics_frame
	await _test_menu()
	await _test_weapons()
	await _test_monsters()
	_test_override()
	_test_live_edit()
	await _test_workbench()
	await _test_workbench_identity()

	print("")
	print("%d sections, %d passed, %d failed" % [_completed, _passed, _failed])
	if _completed != SECTIONS or _passed + _failed != CHECKS - _skipped:
		print("ERROR: %d of %d sections, %d of %d checks ran." % [_completed, SECTIONS, _passed + _failed, CHECKS - _skipped])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _test_menu() -> void:
	_section("the Q menu lists every real entry")
	var rows := _game.addons.describe_items()
	for row in rows:
		match str(row["kind"]):
			"weapon": _weapon_rows.append(row)
			"npc": _npc_rows.append(row)
	var declared := 0
	for pack in ["zz_modern_weapons", "zz_medieval_weapons"]:
		var provider: GDScript = load("res://addons/%s/spawn_provider.gd" % pack)
		declared += provider.call("spawn_entries").size()
	_check(declared > 0 and _weapon_rows.size() == declared, "one weapon row per entry the weapon packs declare", "%d of %d" % [_weapon_rows.size(), declared])
	_check(_npc_rows.size() == MONSTERS.size(), "one NPC row per species the monster pack ships", str(_npc_rows.size()))

	var menu := PlaygroundSpawnMenu.new()
	menu.catalogue = _game.props.catalogue
	menu.weapons = _game.weapons
	add_child(menu)
	var stack := DotScreenStack.new()
	add_child(stack)
	stack.setup()
	stack.register(menu)
	stack.push(menu.screen_id())
	await get_tree().process_frame
	menu.addon_items = rows
	menu.show_tab(PlaygroundSpawnMenu.Tab.PACK_WEAPONS)
	await get_tree().process_frame
	var shown := menu.shown()
	_check(shown.size() == _weapon_rows.size(), "Pack Weapons shows all of them", str(shown.size()))
	var all_cards := true
	for row in _weapon_rows:
		all_cards = all_cards and menu.card_for(StringName(row["key"])) != null
	_check(all_cards, "each has a card")
	menu.show_tab(PlaygroundSpawnMenu.Tab.NPCS)
	await get_tree().process_frame
	_check(menu.shown().size() == MONSTERS.size(), "NPCs shows every monster", str(menu.shown()))
	for row in _npc_rows:
		_check(menu.card_for(StringName(row["key"])) != null, "a card for %s" % row["key"])
	menu.queue_free()
	stack.queue_free()
	_done()


func _test_weapons() -> void:
	_section("every weapon entry gives the player that weapon")
	var bot: PlaygroundPlayer = _game.players[&"bot"]
	bot.teleport(Vector3(0, 1, 0), 0.0)
	await get_tree().physics_frame
	var at := bot.global_position + Vector3(0, 0, -3)
	var picked: Array = []
	_game.weapon_picked_up.connect(func(who: StringName, w: StringName) -> void: picked.append([who, w]))
	var gave_all := true
	var defined := true
	var rigs := true
	for row in _weapon_rows:
		picked.clear()
		var res: DotResult = _game.activate_addon_item(str(row["key"]), 0, at, &"bot")
		var ok: bool = res.ok and picked.size() == 1 and picked[0][0] == &"bot"
		gave_all = gave_all and ok
		if not ok:
			print("    refused %s: %s" % [row["key"], res.error.message if not res.ok else "no pickup"])
			continue
		var def := _game.weapon_def(picked[0][1])
		defined = defined and def != null and PlaygroundZee.is_zee(def)
		if def != null:
			var rig := PlaygroundZee.arm(bot, def, ZeeWeaponRig.Role.SERVER, true, 64, 0)
			var held: bool = rig != null and rig.arsenal.catalogue.has(PlaygroundZee.zee_id(def))
			rigs = rigs and held
			if not held:
				print("    no rig for %s" % row["key"])
	_check(gave_all, "all %d activations go through the pickup path" % _weapon_rows.size())
	_check(defined, "and the id picked up is one the game's catalogue defines")
	_check(rigs, "and a rig built over it holds the real definition")
	PlaygroundZee.disarm(bot)
	_check(not _game.activate_addon_item("zz_medieval_weapons/nope", 0, at, &"bot").ok, "an unknown entry is still refused")
	_done()


func _test_monsters() -> void:
	_section("every monster spawns in front of the player")
	var bot: PlaygroundPlayer = _game.players[&"bot"]
	var at := bot.global_position + Vector3(0, 0, -6)
	var spawned_all := true
	var near := true
	for row in _npc_rows:
		var before := _bodies()
		var res: DotResult = _game.activate_addon_item(str(row["key"]), 0, at, &"bot")
		await get_tree().physics_frame
		var fresh := _bodies().filter(func(n: Node) -> bool: return not before.has(n))
		var ok: bool = res.ok and not fresh.is_empty()
		spawned_all = spawned_all and ok
		if not ok:
			print("    %s: %s" % [row["key"], res.error.message if not res.ok else "nothing new in the world"])
			continue
		var closest := 1e9
		for n in fresh:
			closest = minf(closest, (n as Node3D).global_position.distance_to(at))
		near = near and closest < 4.0
	_check(spawned_all, "each of the three activations puts a body in the world")
	_check(near, "within four metres of where the player aimed")
	await get_tree().create_timer(0.5).timeout
	_done()


## Every 3D node under the world, flattened: a monster's runtime makes its own bodies.
func _bodies() -> Array:
	var out: Array = []
	var stack: Array = [_game.world]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			if c is CharacterBody3D or c is RigidBody3D or c.is_in_group("zhm_monster"):
				out.append(c)
			stack.append(c)
	return out


func _test_override() -> void:
	_section("a cfg/addons/<pack>/*.yml changes a value")
	var dir := "user://cfg/addons/zz_modern_weapons"
	DirAccess.make_dir_recursive_absolute(dir)
	var script: GDScript = load("res://addons/zz_modern_weapons/spawn_provider.gd")
	var before := _damage(script, "zz_m4")
	var file := FileAccess.open(dir + "/99-test.yml", FileAccess.WRITE)
	file.store_string("m4:\n  damage: 51\n")
	file.close()
	var after := _damage(script, "zz_m4")
	DirAccess.remove_absolute(dir + "/99-test.yml")
	var restored := _damage(script, "zz_m4")
	_check(before != 51.0 and after == 51.0, "a one-key file overrides the M4's damage in weapon_defs()", "%s -> %s" % [before, after])
	_check(restored == before, "and removing it restores the shipped value")

	var med_dir := "user://cfg/addons/zz_medieval_weapons"
	DirAccess.make_dir_recursive_absolute(med_dir)
	var mscript: GDScript = load("res://addons/zz_medieval_weapons/spawn_provider.gd")
	var mfile := FileAccess.open(med_dir + "/99-test.yml", FileAccess.WRITE)
	mfile.store_string("mace:\n  damage: 123.0\n")
	mfile.close()
	var med := _damage(mscript, "mace")
	DirAccess.remove_absolute(med_dir + "/99-test.yml")
	_check(med == 123.0, "a one-key file overrides the medieval mace's damage in weapon_defs()", str(med))

	var mon_dir := "user://cfg/addons/zz_historical_monsters"
	DirAccess.make_dir_recursive_absolute(mon_dir)
	var nscript: GDScript = load("res://addons/zz_historical_monsters/spawn_provider.gd")
	var hp_before := _monster_health(nscript, "trex")
	var nfile := FileAccess.open(mon_dir + "/99-test.yml", FileAccess.WRITE)
	nfile.store_string("trex:\n  health: 1234.0\n")
	nfile.close()
	var hp_after := _monster_health(nscript, "trex")
	DirAccess.remove_absolute(mon_dir + "/99-test.yml")
	var hp_restored := _monster_health(nscript, "trex")
	_check(hp_before != 1234.0 and hp_after == 1234.0, "a one-key file overrides the T-Rex's health in spawn_entries()", "%s -> %s" % [hp_before, hp_after])
	_check(hp_restored == hp_before, "and removing it restores the monster's shipped value")
	_done()


func _monster_health(script: GDScript, species: String) -> float:
	for entry: Dictionary in script.spawn_entries():
		if str(entry.get("id", "")).ends_with(species) and entry.get("spawn") is Dictionary:
			return float(entry["spawn"].get("health", -1.0))
	return -2.0


## An admin's `profile_edit weapon <id> extra.damage N` reaches the next shot of a rig that already holds
## the weapon, for both packs (one `weapon` kind); a player's is refused; a reset puts it back.
func _test_live_edit() -> void:
	_section("an admin's weapon edit changes the next shot")
	if not (_game.profiles.weapons.has_id("m4") and _game.profiles.weapons.has_id("mace")):
		print("  SKIP  link cfg/addons/zz_modern_weapons and zz_medieval_weapons (docs/profiles.md): no profile to edit")
		_skipped += 10
		_done()
		return
	var bot: PlaygroundPlayer = _game.players[&"bot"]
	var rt := _game.profiles.runtime
	var old_permit := rt.permit
	rt.permit = func(actor: Variant, _flag: String) -> bool: return actor == "uid-admin"

	var m4 := _game_def("zz_m4")
	var rig := PlaygroundZee.arm(bot, m4, ZeeWeaponRig.Role.SERVER, true, 64, 0) if m4 != null else null
	_check(rig != null, "a rig holds the modern M4")
	if rig == null:
		rt.permit = old_permit
		_done()
		return
	var tick := [0]
	var before := _shot_damage(rig, tick)
	var req := DotConsoleProfileEdit.parse(PackedStringArray(["set", "weapon", "m4", "extra.damage", "77"]))
	var denied := rt.handle_request("uid-player", req.value)
	_check(not denied.ok and denied.error.code == DotError.CODE_FORBIDDEN, "a non-admin's weapon edit is refused")
	_check(_shot_damage(rig, tick) == before and before > 0.0, "and the next shot is unchanged", str(before))
	var done := rt.handle_request("uid-admin", req.value)
	_check(done.ok, "an admin's edit is accepted", "" if done.ok else done.error.message)
	_check(_shot_damage(rig, tick) == 77.0, "and the next shot does 77")

	var mace := _game_def("mace")
	var mace_was := (_pack_def(mace).tuning as DotWeaponBallistics).damage
	var med := DotConsoleProfileEdit.parse(PackedStringArray(["set", "weapon", "mace", "extra.damage", "123"]))
	_check(rt.handle_request("uid-admin", med.value).ok, "the other pack's weapon edits through the same kind")
	_check((_pack_def(mace).tuning as DotWeaponBallistics).damage == 123.0 and mace_was != 123.0, "and its definition changed", "%s -> %s" % [mace_was, (_pack_def(mace).tuning as DotWeaponBallistics).damage])
	_check(_shot_damage(rig, tick) == 77.0, "while the first pack's edit stays")

	rt.handle_request("uid-admin", DotProfileRuntime.make_request("reset", "weapon", "m4"))
	rt.handle_request("uid-admin", DotProfileRuntime.make_request("reset", "weapon", "mace"))
	_check(_shot_damage(rig, tick) == before, "a reset puts the shot back")
	_check((_pack_def(mace).tuning as DotWeaponBallistics).damage == mace_was, "and the other pack's too")
	PlaygroundZee.disarm(bot)
	rt.permit = old_permit
	_done()


## The workbench over real HTTP on an ephemeral loopback port: a token edits a weapon and the next shot uses it.
func _test_workbench() -> void:
	_section("the workbench edits a weapon over HTTP")
	var off := PlaygroundWorkbench.new()
	_check(off.start(_game.profiles, {}).ok and not off.running, "off by default: nothing listens")
	if not _game.profiles.weapons.has_id("m4"):
		print("  SKIP  link cfg/addons/zz_modern_weapons (docs/profiles.md): no profile to edit")
		_skipped += 7
		_done()
		return
	var dir := "user://wb_real_test"
	DirAccess.make_dir_recursive_absolute(dir)
	var tf := FileAccess.open(dir + "/workbench.token", FileAccess.WRITE)
	tf.store_string("wb-s3cret\n")
	tf.close()
	var wb := PlaygroundWorkbench.new()
	var res := wb.start(_game.profiles, {"enabled": true, "port": 0, "token_file": dir + "/workbench.token"})
	_check(res.ok and wb.running, "enabled with a token file listens", "" if res.ok else res.error.message)
	var bot: PlaygroundPlayer = _game.players[&"bot"]
	var m4 := _game_def("zz_m4")
	var rig := PlaygroundZee.arm(bot, m4, ZeeWeaponRig.Role.SERVER, true, 64, 0) if m4 != null else null
	if not res.ok or rig == null:
		_check(false, "a rig holds the M4 and the server runs")
		wb.stop()
		_done()
		return
	var tick := [0]
	var before := _shot_damage(rig, tick)
	var listed := _http(wb, "GET", "/api/profiles/weapon", "wb-s3cret")
	_check(listed["status"] == 200 and "m4" in listed["text"], "an authorised list shows the weapon profiles", str(listed["status"]))
	var denied_actor := _game.profiles.runtime.handle_request("uid-player", DotConsoleProfileEdit.parse(PackedStringArray(["set", "weapon", "m4", "extra.damage", "5"])).value)
	_check(not denied_actor.ok, "the game's own permit still refuses a player")
	var body := JSON.stringify({"op": "set", "kind": "weapon", "id": "m4", "key": "extra.damage", "value": 88})
	var set := _http(wb, "POST", "/api", "wb-s3cret", body)
	_check(set["status"] == 200 and set["json"].get("ok", false), "an authorised set is accepted", str(set["text"]))
	var after := _shot_damage(rig, tick)
	_check(after == 88.0 and before != 88.0, "and the next shot does 88", "%s -> %s" % [before, after])
	var none := _http(wb, "POST", "/api", "", body)
	_check(none["status"] == 401, "no token is 401", str(none["status"]))
	for _i in 4:
		var _bad := _http(wb, "POST", "/api", "wrong", body)
	var locked := _http(wb, "POST", "/api", "wrong", body)
	_check(locked["status"] == 429, "repeated bad tokens are 429", str(locked["status"]))
	_game.profiles.runtime.handle_request(PlaygroundProfiles.LOCAL_ACTOR, DotProfileRuntime.make_request("reset", "weapon", "m4"))
	PlaygroundZee.disarm(bot)
	wb.stop()
	DirAccess.remove_absolute(dir + "/workbench.token")
	DirAccess.remove_absolute(dir)
	_done()


## No token file: an account resolved by the resolver gets in only when listed, and the game's flags still apply.
func _test_workbench_identity() -> void:
	_section("the workbench admits a dot-auth account")
	var wb := PlaygroundWorkbench.new()
	wb.resolver = func(token: String) -> Variant:
		return {"uid": token.trim_prefix("t-")} if token.begins_with("t-") else null
	wb.admin_permit = func(uid: String, flag: String) -> bool: return uid == "boss" and flag == "cvar"
	var res := wb.start(_game.profiles, {"enabled": true, "port": 0, "admin_uids": ["boss", "nocvar"]})
	_check(res.ok and wb.running, "an identity resolver alone is enough to start", "" if res.ok else res.error.message)
	if not wb.running:
		_done()
		return
	var listed := _http(wb, "GET", "/api/profiles/weapon", "t-boss")
	_check(listed["status"] == 200, "a listed admin account reads", str(listed["status"]))
	_check(_http(wb, "GET", "/api/profiles/weapon", "t-nobody")["status"] == 401, "an account not listed is refused")
	var denied := _http(wb, "POST", "/api", "t-nocvar", JSON.stringify({"op": "reset", "kind": "weapon", "id": "m4"}))
	_check(denied["status"] != 200, "a listed account without the game's flag cannot edit", str(denied["status"]))
	_check_ticket_gate()
	wb.stop()
	_done()


## The offline ticket verifier behind the resolver: only a fresh, signed, this-server, expiring ticket gives an identity.
func _check_ticket_gate() -> void:
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var priv := key.save_to_string(false)
	var pub := key.save_to_string(true)
	var who := DotAuthIdentity.new()
	who.uid = "backbone:boss"
	who.display_name = "Boss"
	who.provider = "backbone"
	var good := DotAuthTicket.issue(who, "srv", priv, "iss", 60)
	var got: Variant = PlaygroundWorkbench.identity_of_ticket(good.value, pub, "srv", 0)
	_check(got != null and got.uid == "backbone:boss", "a fresh ticket for this server resolves")
	_check(PlaygroundWorkbench.identity_of_ticket(good.value, pub, "other", 0) == null, "a ticket for another server is refused")
	var stale := DotAuthTicket.issue(who, "srv", priv, "iss", -120)
	_check(PlaygroundWorkbench.identity_of_ticket(stale.value, pub, "srv", 0) == null, "an expired ticket is refused")
	var claims := DotJwt.base_claims("iss", "backbone:boss", "srv", 60)
	claims.erase("exp")
	var forever := DotJwt.encode_rs256(claims, priv)
	_check(PlaygroundWorkbench.identity_of_ticket(forever.value, pub, "srv", 0) == null, "a ticket with no expiry is refused")
	var parts := String(good.value).split(".")
	var forged := "%s.%s.%s" % [parts[0], parts[1], parts[2].reverse()]
	_check(PlaygroundWorkbench.identity_of_ticket(forged, pub, "srv", 0) == null, "a tampered signature is refused")


func _http(wb: PlaygroundWorkbench, method: String, path: String, token: String, body: String = "") -> Dictionary:
	var head := "%s %s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n" % [method, path, body.to_utf8_buffer().size()]
	if token != "":
		head += "Authorization: Bearer %s\r\n" % token
	var c := StreamPeerTCP.new()
	c.connect_to_host("127.0.0.1", wb.http.server.port())
	var out := PackedByteArray()
	var sent := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000:
		c.poll()
		if not sent and c.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			c.put_data((head + "\r\n" + body).to_utf8_buffer())
			sent = true
		wb.poll()
		c.poll()
		if c.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var n := c.get_available_bytes()
			if n > 0:
				out.append_array(c.get_data(n)[1])
		elif sent:
			break
		OS.delay_msec(1)
	var text := out.get_string_from_utf8()
	var i := text.find("\r\n\r\n")
	var payload := text.substr(i + 4) if i >= 0 else ""
	var parsed: Variant = JSON.parse_string(payload) if payload.begins_with("{") else null
	return {"status": int(text.split(" ")[1]) if text.length() > 12 else -1, "json": parsed if parsed is Dictionary else {}, "text": payload}


func _game_def(zee_id: String) -> PlaygroundWeaponDef:
	for def: PlaygroundWeaponDef in _game.weapons:
		if String(def.meta.get("zee", "")) == zee_id and def.meta.has("pack_def"):
			return def
	return null


func _pack_def(def: PlaygroundWeaponDef) -> DotWeaponDef:
	return def.meta["pack_def"]


## Holds the trigger until the rig shoots, and returns that shot's damage; -1 when it never does.
func _shot_damage(rig: ZeeWeaponRig, tick: Array) -> float:
	for _i in 600:
		tick[0] += 1
		var command := DotWeaponCommand.new()
		command.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
		command.slot = rig.current_def().slot
		var outcome := rig.simulate_tick(command, tick[0])
		if outcome.used and not outcome.shots.is_empty():
			var released := DotWeaponCommand.new()
			released.slot = command.slot
			for _j in 40:
				tick[0] += 1
				var _o := rig.simulate_tick(released, tick[0])
			return outcome.shots[0].damage
	return -1.0


func _damage(script: GDScript, id: String) -> float:
	for def: DotWeaponDef in script.weapon_defs():
		if String(def.id) == id:
			return (def.tuning as DotWeaponBallistics).damage
	return -2.0


func _section(title: String) -> void:
	_entered += 1
	print(title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % (what if detail == "" else "%s (%s)" % [what, detail]))
