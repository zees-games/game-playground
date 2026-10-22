extends RefCounted

const PlaygroundPaths := preload("playground_paths.gd")
const PlaygroundWeaponDef := preload("weapons/playground_weapon_def.gd")

## zee-dot-weapons in the sandbox: twenty-seven real weapons beside the three toys.
##
## [b]A second kind of weapon, not a SWEP with a gun painted on.[/b] `PlaygroundWeapon` is a
## prop tool: two edge-triggered buttons and a float delta, run where the input is. A zee
## weapon is dot-weapon's: a held-button command per integer tick, its own cadence, reload
## and ammunition, and an outcome full of shots that the game resolves. Wrapping one in the
## other would throw away the cadence and run the shot on the client, which is a client
## deciding what it hit. So the menu, the shop and the loadout see one list of
## [PlaygroundWeaponDef]s, and `meta.zee` says which machinery is behind an entry.
##
## [b]Named by class, not by path, and that is not the rule broken.[/b] The path rule is for
## this game's OWN scripts, whose `class_name`s a mounted pack never registers. `Zee*` and
## `DotWeapon*` are addons compiled into the host — the client shell carries both — so they
## are registered wherever this runs. mg-smash-copter names them the same way.
##
## [b]A shot hurts only when the arena is on.[/b] A sandbox is not a deathmatch, and a
## weapon pack is not a reason to make it one: with `pg_arena 0` a shot shoves the prop it
## hits — something to do with a gun in a sandbox — and touches nobody. The arena's
## dot-combat resolves the same shot when it is on, through [member PlaygroundNetBridge.shot_fn].

const CHANNEL := "playground.zee"

## Prefixed, because two weapon lists share one id space here and both have a `launcher`.
const ID_PREFIX := "zee_"

## What one point of damage is worth in impulse, against a prop. A pistol's 26 shoves a crate
## about the way a gravity gun's punt does; a sniper's 90 throws a beach ball across the plate.
const IMPULSE_PER_DAMAGE := 0.9

## The menu's categories, from dot-weapon's slots.
const SLOT_CATEGORIES := {
	1: &"melee",
	2: &"sidearms",
	3: &"primaries",
	4: &"heavy",
	5: &"thrown",
}

## One colour per slot, for the generated icon: there is no thumbnail in the pack.
const SLOT_COLOURS := {
	1: Color(0.70, 0.56, 0.40),
	2: Color(0.56, 0.66, 0.80),
	3: Color(0.48, 0.72, 0.52),
	4: Color(0.82, 0.48, 0.40),
	5: Color(0.84, 0.74, 0.36),
}

## The catalogue, built once. Every rig is handed this one rather than building its own.
static var _catalogue: DotWeaponCatalogue = null


static func catalogue() -> DotWeaponCatalogue:
	if _catalogue == null:
		_catalogue = ZeeWeaponPack.catalogue()
	return _catalogue


## Pack weapons ([PlaygroundWorkshop]) by zee id, and the catalogue that holds them besides the pack's own.
static var _pack_defs: Dictionary = {}
static var _with_packs: DotWeaponCatalogue = null
## Weapons a spawn provider's `weapon_defs()` gave ([PlaygroundAddons]), by zee id. Kept apart from
## [member _pack_defs] because [method set_pack_defs] replaces that one on every Workshop sync, and
## a provider's weapons are not the Workshop's to drop.
static var _provider_defs: Dictionary = {}


## Teaches the rigs a weapon a spawn provider ships. [param def] is a [PlaygroundWeaponDef] whose
## `meta.pack_def` is the pack's [DotWeaponDef].
static func add_provider_def(def: PlaygroundWeaponDef) -> void:
	var pack_def: Variant = def.meta.get("pack_def")
	if pack_def is DotWeaponDef:
		_provider_defs[zee_id(def)] = pack_def
		_with_packs = null


## Replaces the Workshop weapons the rigs may be given. [param defs] are [PlaygroundWeaponDef]s whose
## `meta.pack_def` is the pack's [DotWeaponDef].
static func set_pack_defs(defs: Array) -> void:
	_pack_defs.clear()
	_with_packs = null
	for def: PlaygroundWeaponDef in defs:
		var pack_def: Variant = def.meta.get("pack_def")
		if pack_def is DotWeaponDef:
			_pack_defs[zee_id(def)] = pack_def


## The catalogue a rig holding [param def] is built over: the pack's own, plus Workshop weapons it
## does not already have (code wins an id, as in dot-weapon). A copy rather than an addition to
## [method catalogue], so a solo subscription never leaks into a table a server also reads.
static func catalogue_for(def: PlaygroundWeaponDef) -> DotWeaponCatalogue:
	if def == null or not def.meta.has("pack_def") or catalogue().has(zee_id(def)):
		return catalogue()
	if _with_packs == null:
		_with_packs = ZeeWeaponPack.catalogue()
		for table: Dictionary in [_pack_defs, _provider_defs]:
			for id: StringName in table:
				if not _with_packs.has(id):
					_with_packs.add(table[id])
	return _with_packs


## The pack, as this game's weapon definitions. Read off the catalogue, so a weapon the pack
## adds arrives in the menu without a line here.
static func defs() -> Array[PlaygroundWeaponDef]:
	var out: Array[PlaygroundWeaponDef] = []
	var cat := catalogue()

	for id: StringName in ZeeWeaponIds.all():
		var weapon := cat.get_def(id)

		if weapon == null:
			continue

		var def := PlaygroundWeaponDef.make(
			StringName(ID_PREFIX + String(id)), weapon.display_name, ""
		)
		def.description = weapon.description
		def.category = SLOT_CATEGORIES.get(weapon.slot, &"zee")
		def.colour = SLOT_COLOURS.get(weapon.slot, Color(0.62, 0.68, 0.78))
		def.meta = {"zee": String(id), "slot": weapon.slot}
		out.append(def)

	return out


## The game's definition for weapon id [param id] (`zee_smg`), or null.
static func find_def(id: StringName) -> PlaygroundWeaponDef:
	for def in defs():
		if def.id == id:
			return def
	return null


static func is_zee(def: PlaygroundWeaponDef) -> bool:
	return def != null and def.meta.has("zee")


static func zee_id(def: PlaygroundWeaponDef) -> StringName:
	return StringName(str(def.meta.get("zee", ""))) if def != null else &""


## Puts a rig on [param player] holding [param def], replacing whatever rig was there.
##
## [param role] is the rig's: SERVER draws nothing, LOCAL draws into [param view_model].
## [param authority] is false only on a connected client, whose rig animates the hands and
## decides nothing — the server's rig is the one whose shots land.
static func arm(
	player: Node3D,
	def: PlaygroundWeaponDef,
	role: ZeeWeaponRig.Role,
	authority: bool,
	tick_rate: int,
	tick: int,
	view_model: Node3D = null
) -> ZeeWeaponRig:
	disarm(player)

	var rig := ZeeWeaponRig.new()
	rig.name = "ZeeWeapons"
	rig.role = role
	rig.authority = authority
	rig.tick_rate = tick_rate
	rig.catalogue = catalogue_for(def)
	rig.player_ref = DotNodeRef.of_path(player.get_path())

	if view_model != null:
		rig.view_model_ref = DotNodeRef.of_path(view_model.get_path())

	player.add_child(rig)

	var ready_now := rig.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "a weapon rig would not set up", {
			"weapon": String(def.id), "why": ready_now.error.message,
		})
		player.remove_child(rig)
		rig.free()
		return null

	var id := zee_id(def)
	var given := rig.give(id)

	if not given.ok:
		DotLog.warn(CHANNEL, "the rig refused a weapon", {
			"weapon": String(id), "why": given.error.message,
		})

	var weapon := rig.arsenal.catalogue.get_def(id)

	if weapon != null:
		var _selected := rig.arsenal.select(weapon.slot, tick)

	player.set("zee_rig", rig)
	return rig


## Takes the rig off [param player], if there is one.
static func disarm(player: Node) -> void:
	if player == null:
		return

	var rig: Variant = player.get("zee_rig")

	if rig is Node and is_instance_valid(rig):
		var node := rig as Node
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.queue_free()

	player.set("zee_rig", null)


## A tick's buttons and view as a weapon command.
##
## The same three bits every tool here rides on: USER_0 is fire, USER_1 the alt (a bash),
## USER_2 reload. The slot is the one the rig already holds; this game switches weapons by
## asking for one, not by a slot key. Buttons rather than a [DotFpsCommand] so the offline
## client, which has no command until its controller samples one, builds it the same way.
# --- NPCs ----------------------------------------------------------------------

## Whether an NPC can use [param def]: a zee gun or melee weapon, not a thrown or
## explosive one. Grenades and rockets fly here ([PlaygroundProjectiles]), but an NPC's
## brain aims along a straight line and has no throwing arc or blast-radius sense, so one
## holding a frag would bounce it off its own feet and a launcher would be fired point-blank.
static func npc_can_use(def: PlaygroundWeaponDef) -> bool:
	if not is_zee(def):
		return false

	var weapon := catalogue().get_def(zee_id(def))

	if weapon == null:
		return false

	return not (weapon.tags.has(ZeeWeaponIds.TAG_THROWN) or weapon.tags.has(ZeeWeaponIds.TAG_EXPLOSIVE))


## Keeps an NPC's weapon fed: the reserve back to a few magazines' worth whenever it runs
## low. An NPC out of ammunition standing still reads as broken, and nobody counts its shots.
static func top_up(rig: Node) -> void:
	var zee := rig as ZeeWeaponRig

	if zee == null or zee.arsenal == null:
		return

	var def := zee.current_def()

	if def == null or def.ammo_type == &"":
		return

	if zee.arsenal.ammo().count(def.ammo_type) < 60:
		var _added := zee.arsenal.add_ammo(def.ammo_type, 120)


## Fills what [param rig] holds back up: a full magazine and at least the reserve a fresh one
## is given. True when anything changed. The server's answer to asking for (or walking over)
## the gun already in hand; the drawn gun on a client is brought to it by [method correct].
static func refill(rig: Node) -> bool:
	var zee := rig as ZeeWeaponRig

	if zee == null or zee.arsenal == null or zee.arsenal.current() == null:
		return false

	var def := zee.current_def()

	if def == null or def.ammo_type == &"":
		return false

	var held := zee.arsenal.current()
	var changed := false

	if def.uses_magazine() and held.magazine < def.magazine:
		held.magazine = def.magazine
		changed = true

	if not def.infinite_reserve and zee.arsenal.ammo().count(def.ammo_type) < def.reserve:
		zee.arsenal.ammo().set_count(def.ammo_type, def.reserve)
		changed = true

	return changed


## How long the drawn gun must be quiet before the server's count may overwrite it: longer than
## a shot takes to reach the server and its snapshot to come back, so a correction never undoes
## a shot the server has not heard of yet. game-zombie-zone's `VIEW_RIG_SETTLE_SEC`.
const SETTLE_SEC := 0.6


## One tick of the drawn gun's quiet clock on [param player] (`zee_quiet`): reset by a trigger,
## a reload or a switch, else counted up by [param delta] simulated seconds.
static func note_drawn(player: Node, rig: ZeeWeaponRig, command: DotWeaponCommand, delta: float) -> void:
	if player == null or rig == null or rig.arsenal == null:
		return

	var busy := command != null and (command.is_pressed(DotWeaponCommand.BUTTON_ATTACK)
		or command.is_pressed(DotWeaponCommand.BUTTON_RELOAD))
	busy = busy or rig.arsenal.is_reloading() or rig.arsenal.is_switching()
	var quiet: float = float(player.get("zee_quiet")) if player.get("zee_quiet") != null else 0.0
	player.set("zee_quiet", 0.0 if busy else quiet + maxf(delta, 0.0))


## Brings a connected client's drawn [param rig] to the server's count ([param magazine],
## [param reserve], for [param slot]) once it has been quiet [constant SETTLE_SEC]. True when it
## changed anything.
##
## [b]The drawn gun predicts, so it can be wrong, and nothing used to put it right.[/b] A shot the
## server refused, a refill, a fresh rig on the server: each left the HUD on the client's own
## sum for good. Correcting on every snapshot instead would undo the shots still in flight and
## make the counter flicker up while you fire.
static func correct(rig: ZeeWeaponRig, magazine: int, reserve: int, slot: int, server_busy: bool, quiet: float) -> bool:
	if rig == null or rig.arsenal == null or server_busy or quiet < SETTLE_SEC:
		return false

	var arsenal := rig.arsenal
	var held := arsenal.current()

	if held == null or slot != arsenal.current_slot() or arsenal.is_reloading() or arsenal.is_switching():
		return false

	var changed := false

	if held.def.uses_magazine() and held.magazine != magazine:
		held.magazine = clampi(magazine, 0, held.def.magazine)
		changed = true

	if held.def.ammo_type != &"" and not held.def.infinite_reserve \
			and arsenal.ammo().count(held.def.ammo_type) != reserve:
		arsenal.ammo().set_count(held.def.ammo_type, maxi(reserve, 0))
		changed = true

	return changed


static func rig_is_melee(rig: Node) -> bool:
	var def := (rig as ZeeWeaponRig).current_def() if rig is ZeeWeaponRig else null
	return def != null and def.tags.has(ZeeWeaponIds.TAG_MELEE)


static func rig_is_automatic(rig: Node) -> bool:
	var def := (rig as ZeeWeaponRig).current_def() if rig is ZeeWeaponRig else null
	return def != null and (def.fire_mode == DotWeaponDef.Fire.AUTO or def.fire_mode == DotWeaponDef.Fire.HOLD)


static func rig_magazine_empty(rig: Node) -> bool:
	var zee := rig as ZeeWeaponRig

	if zee == null or zee.arsenal == null or zee.arsenal.current() == null:
		return false

	var def := zee.current_def()
	return def != null and def.ammo_type != &"" and zee.arsenal.current().magazine_empty()


## Where every pellet of every shot in [param outcome] lands: `[{collider, point,
## direction, damage}]`, nearest hit per pellet, [param exclude] ignored.
##
## [b]Pellets, not the shot's direction.[/b] A shot made by a weapon has its spread already
## rolled into `pellets`, and tracing the direction instead puts every shotgun pellet down
## one line — a shotgun that is a rifle.
static func trace_outcome(
	space: PhysicsDirectSpaceState3D, outcome: DotWeaponOutcome, exclude: Array[RID]
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	if space == null or outcome == null:
		return out

	for shot: DotShot in outcome.shots:
		var directions: Array = shot.pellets if not shot.pellets.is_empty() else [shot.direction]
		var per_pellet := shot.damage

		for direction in directions:
			var dir: Vector3 = (direction as Vector3).normalized()
			var query := PhysicsRayQueryParameters3D.create(
				shot.origin, shot.origin + dir * maxf(shot.max_range, 1.0)
			)
			query.exclude = exclude
			var found := space.intersect_ray(query)

			if found.is_empty():
				continue

			out.append({
				"collider": found["collider"],
				"point": found["position"],
				"direction": dir,
				"damage": per_pellet,
				"distance": shot.origin.distance_to(found["position"]),
			})

	return out


static func command_for(buttons: int, yaw: float, pitch: float, slot: int) -> DotWeaponCommand:
	var command := DotWeaponCommand.new()
	command.set_button(DotWeaponCommand.BUTTON_ATTACK, (buttons & DotFpsCommand.BUTTON_USER_0) != 0)
	command.set_button(DotWeaponCommand.BUTTON_ALT, (buttons & DotFpsCommand.BUTTON_USER_1) != 0)
	command.set_button(DotWeaponCommand.BUTTON_RELOAD, (buttons & DotFpsCommand.BUTTON_USER_2) != 0)
	command.yaw = yaw
	command.pitch = pitch
	command.slot = slot
	return command


## The slot of the weapon a rig holds, or 0.
static func slot_of(rig: ZeeWeaponRig) -> int:
	if rig == null:
		return 0
	var def := rig.current_def()
	return def.slot if def != null else 0


## Shoves the prop each shot hits. Returns how many it moved.
##
## [b]Through the gravity gun's own ray and ownership test[/b], so a shot can move exactly
## what a punt could: nothing frozen, nothing another player owns unless the server lets
## players touch each other's props. A second answer to "may I move that crate" would be
## a server where you cannot pick somebody's crate up and can shoot it across the map.
static func shove_props(
	player: Node, outcome: DotWeaponOutcome, may_touch_others: bool
) -> int:
	if outcome == null or player == null or not (player is Node3D):
		return 0

	var gun: DotGravGun = player.get("grav_gun")

	if gun == null or not (player as Node3D).is_inside_tree():
		return 0

	var space := (player as Node3D).get_world_3d().direct_space_state
	var moved := 0

	for shot: DotShot in outcome.shots:
		var direction := shot.direction.normalized()
		var reach := gun.reach
		gun.reach = shot.max_range
		var prop := gun.target(space, shot.origin, direction)
		gun.reach = reach

		if prop == null or not gun.may_act_on(prop, may_touch_others).ok:
			continue
		if prop.frozen or not (prop.node is RigidBody3D):
			continue

		var body := prop.node as RigidBody3D
		var damage := maxf(shot.total_damage(), shot.damage * float(maxi(shot.pellet_count, 1)))
		body.apply_central_impulse(direction * damage * IMPULSE_PER_DAMAGE)
		moved += 1

	return moved


## What everybody else sees in [param player]'s hands: [param def]'s gun, or nothing.
##
## A [ZeeWorldModel] on the character's `right_hand` mount, built on a CLIENT from the
## server's WEAPON event, so a remote player's gun is drawn, kicks when
## [PlaygroundPlayerNet]'s fire counter moves, and goes when they put it away. Idempotent:
## the same weapon twice keeps the model it has.
static func show_held(player: Node, def: PlaygroundWeaponDef) -> void:
	if player == null:
		return

	var held: Variant = player.get("zee_world")
	var model: ZeeWorldModel = null
	if held is ZeeWorldModel and is_instance_valid(held):
		model = held as ZeeWorldModel

	if not is_zee(def):
		if model != null:
			model.queue_free()
		player.set("zee_world", null)
		return

	var id := zee_id(def)
	if model != null and model.equipped() == id:
		return

	var art: Variant = ZeeWeaponArtTable.table().get(id)
	if not (art is ZeeWeaponArt):
		return

	if model == null:
		model = ZeeWorldModel.new()
		model.name = "ZeeWorldModel"
		if not model.attach_to(player.get("character")):
			model.free()
			return
		player.set("zee_world", model)

	var _equipped := model.equip(art as ZeeWeaponArt)


## Points zee's art at this game's copy of it: `res://assets/` built in, the mount in a pack.
static func use_this_games_art() -> void:
	ZeeModelCache.set_asset_root(PlaygroundPaths.root())


## Puts zee's art back where a built-in game keeps it, for whatever the shell loads next.
static func release_art() -> void:
	ZeeModelCache.set_asset_root("res://")
