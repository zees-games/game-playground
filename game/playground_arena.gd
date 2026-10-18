extends Node

const Playground := preload("playground.gd")
const PlaygroundPlayer := preload("playground_player.gd")
const PlaygroundWeaponDef := preload("weapons/playground_weapon_def.gd")

## The fight, when an operator turns one on: health, weapons that hurt, and a round.
##
## [b]A sandbox is not a deathmatch, and this is off by default for the same reason the
## hunters are off in game-hungario.[/b] A server where somebody can shoot you while you
## are building is a different server, and turning one into the other silently because an
## addon was installed is exactly what a cvar exists to prevent. `pg_arena 1` is the
## switch; everything below it is inert until then.
##
## [b]Three addons, and each does the half this game would otherwise get wrong.[/b]
##
## - **dot-combat** is health, damage types, hitboxes and the resolution. The part that
##   matters is not the arithmetic — it is that friendly fire, self damage, falloff, hit
##   groups and clamping are *policy* rather than `if`s, and that a shot is resolved
##   against a rewound world rather than against where somebody is now.
## - **dot-match** is the loop: warmup, a countdown, rounds, scoring, respawning, and the
##   idle check. Counted in ticks and driven by one call, so it runs at whatever
##   `sv_tickrate` says rather than at a wall clock.
## - **dot-loadout** is what you spawn with, as a **document of ids** the server validates
##   against a schema and an entitlement set without loading any content. That is the whole
##   claim, and it is why the weapon a player picks is checked by a dedicated server that
##   holds none of the models.
##
## [b]The weapons are this game's own and are not re-declared.[/b] `PlaygroundWeapons`
## already has an arsenal — a script path per weapon, loaded and checked — and a second
## catalogue of the same three would be two lists to keep in step, which is this tree's
## most repeated bug. The loadout schema's items are **built from it**, and a `DotItem` is
## the same id with a cost and an entitlement on it.

const CHANNEL := "playground.arena"

## The one damage type a sandbox weapon does.
##
## [b]One rather than a table, because there is one kind of hurt here.[/b] A game with a
## rocket and a rifle needs two; this one has a launcher that throws things and an impulse
## that shoves them, and the difference between them is a velocity rather than a wound.
const DAMAGE_ID := &"kinetic"

## Starting health, and the ceiling armour tops out at.
const MAX_HEALTH := 100.0
const MAX_ARMOUR := 100.0

## Rounds in a match, and how long one may last.
const ROUND_SECONDS := 240.0
const SCORE_LIMIT := 25


## Somebody's health changed. Server side; the module tells the clients.
signal health_changed(player_id: StringName, health: float, armour: float, by: StringName)

## Asked before a death is reported: [code](victim) -> StringName[/code], answering
## [code]&"down"[/code] or [code]&"dead"[/code].
##
## [b]One place decides, and that is the whole point of a callable here.[/b] A game that
## asks "are we in a mode with incapacitation" at every damage site has as many copies of
## the rule as it has damage sites, and the copies drift. Unset means everybody dies,
## which is what a deathmatch is.
var death_rule_fn: Callable = Callable()

## Somebody died. Server side.
signal player_killed(victim: StringName, killer: StringName)

## Somebody came back in the fight (dot-match's respawn). Server side: the module hands them
## their loadout's weapon here.
signal respawned(id: StringName)

## The match clock moved. Server side.
signal clock_changed(state: int, seconds_left: float, round_number: int, label: String)


var combat: DotCombatManager = null
var match_node: DotMatch = null
var loadouts: DotLoadoutManager = null

var game: Playground = null

## Whether the fight is on. Off is a sandbox.
var enabled: bool = false

## Whether a player's client is still behind its loading cover: `func(player_key: StringName) -> bool`.
## The server module fills it from its [DotGameRoster]; unset (offline, a suite, a bot) nobody is
## loading, so every offline suite is unchanged. See [method hurt].
var loading_fn: Callable = Callable()

## player id -> [DotHealth].
var _health: Dictionary = {}

## dot-combat keys entities by int and this game keys players by [StringName]. Two id
## spaces meeting is exactly where this family loses things.
##
## [b]Both directions live on [member Playground.entities] now, and the counter and the
## two dictionaries that used to be here are gone.[/b] They were correct and they were
## this layer's, which was the problem: this layer only exists when the waves mode is
## on, so [PlaygroundDowns] minted its own ids from a name hash whenever it was off.
## One table on the game answers for every layer whatever is switched on.

var _tick: int = 0

## The zee weapon definitions by id, for the death reaction a weapon asks for. Built on first use.
var _weapon_defs: Dictionary = {}


# --- The catalogue ---------------------------------------------------------

## What a player may spawn holding, built from the weapons this game already ships.
##
## [b]Built FROM `PlaygroundWeapons` rather than beside it.[/b] The arsenal is already
## declared once — an id, a name, a script path — and a loadout catalogue that restated it
## would be a second list, which in this tree has now gone stale in `setup.sh`,
## `tools/check.sh`, `tools/package_check.sh` and `bootstrap`. What a `DotItem` adds is the
## two things a weapon definition has no business knowing: what it costs against a budget
## and what unlocks it.
static func item_catalogue(weapons: Array[PlaygroundWeaponDef]) -> DotItemCatalogue:
	var out := DotItemCatalogue.new()
	var items: Array[DotItem] = []

	for weapon in weapons:
		var item := DotItem.make(weapon.id, DotItem.KIND_WEAPON)
		item.display_name = weapon.name_or_id()
		item.slots = [&"primary"]
		item.cost = int(weapon.meta.get("cost", 1))
		# [b]Free unless the catalogue says otherwise, and `swep_launcher` is the one that
		# is not.[/b] Entitlements default to nothing, and that default is the important
		# one: a server that granted everything would work perfectly in every test, ship,
		# and quietly be a game where every unlock is free — which nobody reports as a bug.
		item.free = weapon.id != &"launcher"
		item.entitlement_id = &"" if item.free else &"pg_launcher"
		items.append(item)

	# [b]No tools.[/b] The physics and gravity guns were a `tool` slot until 2026-10-12, when B
	# made the loadout something a player chooses: a player holds one thing, the two tools are
	# always on 1 and 2, and the slot was a choice nothing read.

	out.items = items
	out.reindex()
	return out


## One slot: the weapon an arena spawn puts in the hands (B, `PlaygroundModule._arm_from_loadout`).
static func loadout_schema(weapons: Array[PlaygroundWeaponDef]) -> DotLoadoutSchema:
	# [b]Required, and therefore it must have a default.[/b] dot-loadout refuses a schema
	# whose required slot has none, and the refusal is exactly right: a loadout missing a
	# required slot cannot be *repaired* — `conform_on_load` has nothing to put there — so
	# it can only be refused, and a player who has never chosen could then never spawn.
	# The default is derived from the catalogue rather than written in, so a server that
	# retires a weapon does not end up with a schema pointing at nothing.
	var primary := DotLoadoutSlot.make(&"primary", true, _default_weapon(weapons))
	primary.display_name = "Weapon"
	primary.kinds = [DotItem.KIND_WEAPON]
	primary.arsenal_slot = 1
	primary.order = 0

	var schema := DotLoadoutSchema.new()
	schema.id = &"pg_arena"
	schema.display_name = "Sandbox arena"
	schema.slots = [primary]
	schema.catalogue = item_catalogue(weapons)
	schema.allow_duplicates = false
	schema.reindex()
	return schema


## What a player who has never chosen spawns with.
##
## [b]The first free weapon in the arsenal, found rather than named.[/b] Naming one would
## be a second declaration of a weapon id, and the copy that goes stale is always the one
## nothing reads — this tree's most repeated bug. Empty when there are no free weapons at
## all, which dot-loadout then refuses loudly, and loudly is right: a server whose every
## weapon is locked is one nobody can spawn on.
static func _default_weapon(weapons: Array[PlaygroundWeaponDef]) -> StringName:
	for weapon in weapons:
		if weapon.id != &"launcher":
			return weapon.id

	return &""


# --- Lifecycle -------------------------------------------------------------

func setup(p_game: Playground) -> DotResult:
	game = p_game

	var fought := _build_combat()

	if not fought.ok:
		return fought

	var played := _build_match()

	if not played.ok:
		return played

	return _build_loadouts()


func _build_combat() -> DotResult:
	var rules := DotDamageRules.new()
	# A sandbox has no teams, so nothing is friendly — said explicitly rather than left,
	# because a mode that adds teams changes exactly this line.
	rules.friendly_fire = true
	rules.friendly_scale = 1.0
	# [b]On, and scaled by the damage type.[/b] Launching a boulder at your own feet
	# hurting you is the joke the weapon exists for; it hurting you as much as it hurts
	# somebody else is not.
	rules.self_damage = true
	rules.hit_groups = true
	rules.falloff = true
	rules.minimum = 0.0
	rules.maximum = 0.0

	var config := DotCombatConfig.new()
	config.tick_rate = game.tick_rate

	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = true
	combat.register_service = false
	combat.config = config
	combat.config_file = ""
	combat.load_layered_config = false
	combat.rules = rules
	add_child(combat)

	var ready := combat.setup()

	if not ready.ok:
		return ready.wrap("dot-combat could not be set up")

	var kinetic := DotDamageType.make(DAMAGE_ID, "Kinetic")
	kinetic.falloff_start = 12.0
	kinetic.falloff_end = 60.0
	kinetic.falloff_floor = 0.3
	kinetic.armour_share = 0.6
	kinetic.self_scale = 0.35
	kinetic.uses_hit_groups = true
	combat.register_damage_type(kinetic)

	# [b]The spawn window, asked at the one point every hit goes through.[/b] `hurt`'s
	# comment above already names what an unstamped tick does to `DotHealth`'s window;
	# this is the session-scoped record of the same idea, granted per respawn in
	# `_on_respawn_due` and drained every tick, which until now nothing ever asked.
	# A veto applied at the damage sites instead is one applied at the sites somebody
	# remembered.
	combat.resolver.adjust = _adjust_damage

	combat.damage_applied.connect(_on_damage)
	combat.entity_killed.connect(_on_killed)

	return DotResult.success(null)


## Refuses a hit on somebody inside their spawn window.
##
## Self damage and world damage are not blocked, and neither decision is made here:
## [DotSpawnProtection.blocks] answers about the pair so that a protected player who
## falls into a pit still dies in it.
func _adjust_damage(damage: DotDamage) -> void:
	if damage == null or game == null or game.player_stack == null:
		return

	# Creative mode, both ways: a builder is out of the fight. A fall or a pit still reaches
	# them, or a player could make themselves unkillable and stand in a kill zone.
	if not damage.is_world_damage() and damage.attacker != damage.victim:
		var attacker_id := StringName(str(game.entity_table.key_for_id(damage.attacker)))
		var victim_id := StringName(str(game.entity_table.key_for_id(damage.victim)))
		if game.is_creative(victim_id) or game.is_creative(attacker_id):
			damage.refuse("creative mode")
			return

	if game.player_stack.blocks_damage(
		str(game.entity_table.key_for_id(damage.attacker)),
		str(game.entity_table.key_for_id(damage.victim)),
		damage.tick,
		damage.is_world_damage()
	):
		damage.refuse("spawn protection")


func _build_match() -> DotResult:
	var rules := DotMatchRules.new()
	rules.id = &"pg_arena"
	rules.display_name = "Sandbox arena"
	rules.score_limit = SCORE_LIMIT
	rules.time_limit_sec = ROUND_SECONDS
	rules.respawn_delay_sec = 3.0
	rules.warmup_sec = 10.0
	rules.countdown_sec = 3.0
	rules.min_players = 1
	rules.team_based = false
	# [b]Read off the config and declared on the rules, which is the pair dot-match shipped
	# a bug about.[/b] `pause_when_empty` was read from the wrong object, so a match sat in
	# COUNTDOWN for ever — parse-clean, because a `Resource` property access is not
	# statically checked. Setting it here is what makes it a decision.
	rules.pause_when_empty = true

	var config := DotMatchConfig.new()
	config.tick_rate = game.tick_rate
	# The game owns the tick — `Playground._simulate_tick` — so the match must not also
	# start itself from a `_ready`.
	config.auto_start = false
	config.balance_between_rounds = false
	# A sandbox is where people stand still on purpose. An idle kick would remove the
	# person who is building.
	config.idle_seconds = 0.0

	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.rules = rules
	match_node.config = config
	match_node.config_file = ""
	match_node.load_layered_config = false
	match_node.register_service = false
	add_child(match_node)

	var ready := match_node.setup()

	if not ready.ok:
		return ready.wrap("dot-match could not be set up")

	match_node.state_changed.connect(_on_state_changed)
	match_node.respawn_due.connect(_on_respawn_due)

	return DotResult.success(null)


func _build_loadouts() -> DotResult:
	var config := DotLoadoutConfig.new()
	config.backend = "memory"
	config.allow_default_loadout = true
	# [b]On for LOADING and off for PUBLISHING, which is the asymmetry that matters.[/b]
	# Refusing on the way out means a player who has not played since a weapon was retired
	# cannot spawn; repairing on the way IN would let a client put anything in any slot and
	# have the server pick the nearest legal thing. game-hungario says the same two
	# sentences and this is the same decision.
	config.conform_on_load = true
	config.enforce_entitlements = true
	config.allow_live_changes = false

	loadouts = DotLoadoutManager.new()
	loadouts.name = "Loadouts"
	loadouts.config = config
	loadouts.config_file = ""
	loadouts.load_layered_config = false
	loadouts.schema = loadout_schema(game.weapons)
	loadouts.register_service = false
	add_child(loadouts)

	return loadouts.setup().wrap("dot-loadout could not be set up")


## Turns the fight on or off.
##
## [b]Off clears every health record rather than leaving them.[/b] A player who was on 12
## health when an operator turned the arena off and back on would otherwise still be, and
## the symptom is somebody dying in a sandbox to a shot fired an hour ago.
func set_enabled(on: bool) -> void:
	if enabled == on:
		return

	enabled = on

	# The spawn window opens and shuts with the fight. Without this an operator who
	# turned the arena on mid-session got no protection until the next map change, and
	# one who turned it off kept granting it for ever.
	if game != null and game.player_stack != null:
		game.player_stack.refresh_spawn_rules()

	if on:
		match_node.start(_tick)

		for id in game.players.keys():
			admit(id, str(id))

		return

	match_node.stop(_tick)

	for id in _health.keys():
		_forget(id)

	_health.clear()


# --- Players ---------------------------------------------------------------

## Gives somebody health and puts them on the scoreboard.
func admit(id: StringName, display_name: String) -> void:
	if not enabled or _health.has(id):
		return

	var health := DotHealth.new()
	health.name = "Health_%s" % String(id)
	health.max_health = MAX_HEALTH
	health.max_armour = MAX_ARMOUR
	health.regen_per_second = 0.0
	# Three seconds of protection on spawn, counted in ticks. A player shot on the tick
	# they appear has not had a game.
	health.spawn_protection_ticks = game.tick_rate * 3
	add_child(health)

	health.set_tick_rate(game.tick_rate)
	health.reset(_tick)

	_health[id] = health

	# [b]Asked for, and opened only if nobody has.[/b] A player who joined the game has
	# an entity already -- [member Playground.entity_table] opens one on join so every
	# layer sees the same id whether or not the others are switched on -- and this must
	# use theirs rather than mint a second. But `admit` is also called for ids the game
	# itself never saw: the dedicated suite admits two by hand, and an operator can put
	# somebody in the waves mode who is not a `PlaygroundPlayer`. Those get one here,
	# against their health node, which is the node that exists for exactly as long as
	# the thing does.
	#
	# One allocator with two callers is not the bug this replaced. That bug was two
	# ALLOCATORS -- a counter here and a name hash in the downs layer -- answering
	# differently for one player depending on which modes were on.
	var entity_id := game.entity_table.id_for_key(id)

	if entity_id == 0:
		var opened := game.entity_table.open(
			DotEntity.KIND_PLAYER, health, &"", id, float(_tick) / float(maxi(game.tick_rate, 1))
		)

		if not opened.ok:
			DotLog.error(CHANNEL, "could not open an entity for an admitted player", {
				"player": String(id), "why": opened.error.message,
			})
			health.queue_free()
			_health.erase(id)
			return

		entity_id = (opened.value as DotEntityHandle).id

	combat.register_health(entity_id, health)
	match_node.add_player(String(id), display_name, _tick)


func release(id: StringName) -> void:
	if not _health.has(id):
		return

	# [b]Decided BEFORE anything is torn down.[/b] Whose entity this is can only be
	# answered while the health node still exists to compare against, and `_forget`
	# frees it -- so the question is asked first and acted on after.
	#
	# A real player's entity is NOT this layer's. It belongs to the game, which opened
	# it on join and closes it on leave; this layer can be switched off mid-map and a
	# player whose handle went with it would lose their downed state and their effects.
	# One opened by `admit` for an id the game never saw IS this layer's. The test is
	# whose node it is: the game opens against the player, `admit` opens against the
	# health node.
	var handle := game.entity_table.handle_for_key(id)
	# `_health.get` is a Variant, so the comparison is written against a typed local:
	# `var x := <Dictionary index>` is a parse error under these projects' settings,
	# and a parse error in a suite scene is a HANG rather than a failure.
	var health_node: Variant = _health.get(id)
	var ours: bool = handle != null and handle.node == health_node

	_forget(id)
	_health.erase(id)

	if ours:
		game.entity_table.close(handle.id, DotEntityTable.REASON_DESPAWN)

	match_node.remove_player(String(id))


func _forget(id: StringName) -> void:
	var entity_id := game.entity_table.id_for_key(id)

	if entity_id != 0 and combat != null:
		combat.forget(entity_id)

	var health: Variant = _health.get(id)

	if health is DotHealth:
		(health as DotHealth).queue_free()


func health_of(id: StringName) -> DotHealth:
	var found: Variant = _health.get(id)
	return found as DotHealth if found is DotHealth else null


func entity_id_of(id: StringName) -> int:
	return game.entity_table.id_for_key(id) if game != null else 0


## The other direction, which used to be the one that was missing.
##
## [PlaygroundDowns] needs it and hashed the player's name when this layer was off — a
## number that is stable, plausible and **not** the one the health, the hitboxes and the
## kill feed use, so a player who is down in one system was up in the other. Both
## directions are the game's table now and neither layer can answer differently.
func player_for_entity(entity_id: int) -> StringName:
	return game.entity_table.key_for_id(entity_id) if game != null else &""


# --- The tick --------------------------------------------------------------

## One authoritative step, from the game's own tick.
##
## [b]After the players have moved.[/b] dot-combat rewinds to resolve a shot, and what it
## rewinds to is where everybody was on a tick — so the origin it is told about has to be
## the one the movement has just produced. Ticking it first would rewind to a frame that
## never existed.
func tick(current_tick: int, delta: float) -> void:
	_tick = current_tick

	if not enabled:
		return

	for id in _health.keys():
		var health: DotHealth = _health[id]
		health.tick(current_tick, delta)

		var found: Variant = game.players.get(id)
		var player := found as PlaygroundPlayer

		if player != null and player.controller != null \
				and player.controller.state != null:
			combat.set_authoritative_origin(
				entity_id_of(id), player.controller.state.position
			)

	combat.tick(current_tick, delta)
	match_node.tick(current_tick)

	# The clock, once a second. [b]A mirroring client's match never runs[/b] — nothing
	# ticks it, so `seconds_remaining()` is derived from a tick that is still zero. A
	# number produced correctly on the server and never sent is this family's most
	# repeated bug, and game-arena shipped exactly it.
	if current_tick % maxi(game.tick_rate, 1) == 0:
		_announce_clock()


func _announce_clock() -> void:
	clock_changed.emit(
		int(match_node.state),
		match_node.seconds_remaining(_tick),
		match_node.round_number,
		_state_label()
	)


func _state_label() -> String:
	match match_node.state:
		DotMatch.State.WARMUP:
			return "Warm-up"
		DotMatch.State.COUNTDOWN:
			return "Starting"
		DotMatch.State.LIVE:
			return "Live"
		DotMatch.State.INTERMISSION:
			return "Round over"
		DotMatch.State.MATCH_END:
			return "Match over"
		_:
			return "Idle"


# --- Hurting people --------------------------------------------------------

## A weapon hit somebody. The whole of what a game supplies to dot-combat.
##
## [b]The resolver decides, not this.[/b] Friendly fire, self damage, the falloff over the
## distance and the hit-group multiplier are all policy that lives on the rules and the
## damage type, and a function here that shortcut any of them would be a policy an operator
## cannot change.
func hurt(
	attacker: StringName, victim: StringName, amount: float, distance: float,
	group: StringName = DotHitGroup.CHEST, admin: bool = false
) -> DotDamage:
	if not enabled:
		return null

	var health := health_of(victim)

	if health == null:
		return null

	# A player whose client is still behind its loading cover froze itself and cannot see, so
	# no weapon, NPC shot or lava may hurt it. This is the one function every one of them
	# ends at. A refused damage is returned rather than null: null reads as "the arena is off"
	# and lava would then send the player to the spawn instead. An [param admin] call (slay,
	# slap) is the operator's and passes.
	if not admin and loading_fn.is_valid() and bool(loading_fn.call(victim)):
		var refused := DotDamage.make(
			entity_id_of(attacker), entity_id_of(victim), amount, combat.damage_type(DAMAGE_ID)
		)
		refused.refuse("loading")
		DotLog.debug(CHANNEL, "a hit was refused", {"why": "loading", "victim": String(victim)})
		return refused

	var damage := DotDamage.make(
		entity_id_of(attacker), entity_id_of(victim), amount,
		combat.damage_type(DAMAGE_ID)
	)
	damage.distance = distance
	damage.hit_group = group
	# [b]The tick, and leaving it out is a silent kill switch.[/b] `DotHealth.apply`
	# refuses anything whose `tick` is at or before `invulnerable_until_tick`, and a
	# `DotDamage` starts at tick 0 — so an event that never got stamped is refused by spawn
	# protection FOR EVER, on every player, with `refused` set and nothing erroring
	# anywhere. Every shot on the server does nothing and the only symptom is that combat
	# does not work. Found by this game's own suite on the first run of the arena section.
	damage.tick = _tick

	return combat.apply_damage(damage)


func _on_damage(damage: DotDamage) -> void:
	var victim := game.entity_table.key_for_id(damage.victim) as StringName

	if victim == &"":
		return

	var health := health_of(victim)

	if health == null:
		return

	health_changed.emit(
		victim,
		health.health,
		health.armour,
		game.entity_table.key_for_id(damage.attacker) as StringName
	)

	match_node.report_damage(
		String(game.entity_table.key_for_id(damage.attacker)),
		String(victim),
		damage.health_lost
	)

	# The shooter's hit marker and number: a player's damage to somebody else, as applied.
	var attacker := game.entity_table.key_for_id(damage.attacker) as StringName
	if attacker != victim and not damage.refused:
		var player: PlaygroundPlayer = game.players.get(victim, null)
		var at := damage.point
		if at == Vector3.ZERO and player != null:
			at = player.controller.state.position + Vector3.UP * 1.5
		game.confirm_hit(attacker, damage.victim, damage.health_lost, at, damage.lethal,
			damage.hit_group == DotHitGroup.HEAD)


func _on_killed(entity_id: int, damage: DotDamage) -> void:
	var victim := game.entity_table.key_for_id(entity_id) as StringName
	var killer := game.entity_table.key_for_id(damage.attacker) as StringName

	if victim == &"":
		return

	# Down rather than dead, when something else has said so. A downed player is not
	# reported to dot-match at all: the scoreboard has not lost anybody, the respawn
	# queue must not start counting, and the kill feed would be announcing a death that
	# did not happen.
	if death_rule_fn.is_valid():
		var what := StringName(str(death_rule_fn.call(victim)))

		if what == &"down":
			DotLog.debug(CHANNEL, "a player went down rather than dying", {
				"player": String(victim), "by": String(killer),
			})
			return

	# [b]Through dot-match's own kill report, so the scoreboard, the feed and the respawn
	# queue all agree.[/b] A game that scored a kill itself and then queued a respawn
	# separately would have two counts of the same event, and the one that is wrong is
	# whichever nobody prints.
	# How the body falls, picked once, here, and carried on COMBAT to every client.
	var fallen: PlaygroundPlayer = game.players.get(victim, null)
	if fallen != null:
		fallen.death = decide_death(victim, damage)

	match_node.report_kill(String(killer), String(victim), DAMAGE_ID, _tick)
	player_killed.emit(victim, killer)


## The fall a death gets: dot-player-char's reaction rule over the server's
## `sv_ragdoll_reactions`, seeded from the victim's entity and the tick, with the killing zee
## weapon's def (the sniper and the launcher always throw the body). The push is the shot's,
## or away from the killer. [param named] is a reaction asked for outright, for a death that is
## not a weapon's: a downed player bleeding out crumples where they lay.
func decide_death(victim: StringName, damage: DotDamage, named: StringName = &"") -> DotPlayerDeath:
	if _weapon_defs.is_empty():
		_weapon_defs = ZeeWeaponPack.table()
	var player: PlaygroundPlayer = game.players.get(victim, null)
	var direction := damage.direction if damage != null else Vector3.ZERO
	if direction.length_squared() < 0.0001 and damage != null and player != null:
		var attacker: PlaygroundPlayer = game.players.get(game.entity_table.key_for_id(damage.attacker), null)
		if attacker != null and attacker != player:
			direction = player.controller.state.position - attacker.controller.state.position
	direction.y = 0.0
	return DotPlayerDeath.decide(
		game.ragdoll_rules.reactions(),
		damage != null and damage.hit_group == DotHitGroup.HEAD,
		damage.amount if damage != null else 0.0,
		direction,
		DotPlayerDeath.seed_of(entity_id_of(victim), _tick),
		_weapon_defs.get(damage.weapon_id) if damage != null else null,
		-1.0, named
	)


func _on_state_changed(_from: DotMatch.State, _to: DotMatch.State) -> void:
	_announce_clock()


## dot-match says somebody may come back. The game is what puts them there.
##
## [b]The addon decides and the game acts, which is dot-timer's division exactly.[/b] What
## "respawn" means differs between a first-person game, a 2D one and a replay being
## scrubbed, and dot-match knowing any of that would make it a game.
func _on_respawn_due(key: String, spawn: DotSpawnPoint, _tick_value: int) -> void:
	var id := StringName(key)
	var health := health_of(id)

	if health != null:
		# The class's numbers, before the reset — `reset` sets health to `max_health`, so
		# raising the maximum afterwards leaves a "full" player on the old class's number.
		var player_for_class: PlaygroundPlayer = game.players.get(id)

		if game.player_stack != null and player_for_class != null:
			game.player_stack.apply_class_numbers(
				String(id),
				health,
				player_for_class.controller.tunables,
				player_for_class.class_base_tunables()
			)

		health.revive(1.0)
		health.reset(_tick)
		health_changed.emit(id, health.health, health.armour, &"")

	game.spawn_player(id)

	if spawn != null:
		var found: Variant = game.players.get(id)
		var player := found as PlaygroundPlayer

		if player != null:
			player.teleport(spawn.global_position, spawn.global_rotation.y)

	respawned.emit(id)


## Whether [param id] is inside their spawn protection: a loadout chosen now goes into their
## hands at once (`PlaygroundModule.rearm_if_allowed`), as game-arena's does.
func is_protected(id: StringName) -> bool:
	var health := health_of(id)
	return enabled and health != null and health.alive and health.is_protected(_tick)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("arena        %s" % ("on" if enabled else "off"))

	if not enabled:
		return out

	out.append_array(match_node.describe_lines())
	out.append_array(combat.describe_lines())

	for id in _health.keys():
		var health: DotHealth = _health[id]
		out.append("  %-20s %5.0f hp %5.0f ap" % [String(id), health.health, health.armour])

	return out
