extends "res://game/playground_module_base.gd"
## The rest of the console commands: limits, arena, waves, shop, vote and punishments.


## `pg_max_<group>` per kind, `pg_limit_roles` for who gets more, and `pg_limits` to see
## anybody's. A role is a dot-server admin group by name, plus `admin` (any admin flag)
## and `root` (the root flag) — so an operator who already has an admin file has roles.
## One slot count: the server's `sv_maxplayers` is what it accepts and advertises (A2S clamps its
## own byte), so the roster follows it; a non-default `pg_max_players` is the operator's and wins.
func _bind_slots() -> void:
	var slots: DotConVar = server.console.find_cvar("sv_maxplayers") if server != null else null
	var roster: DotPlayerRoster = game.player_stack.roster if game.player_stack != null else null
	if slots == null or roster == null:
		return
	if game.config.max_players != PlaygroundConfig.new().max_players:
		slots.set_value(str(game.config.max_players))
	roster.config.max_players = slots.get_int()
	slots.changed.connect(func(_old: String, value: String) -> void:
		roster.config.max_players = value.to_int()
	)


func _bind_limits() -> void:
	var limits := game.spawn_limits

	for group in PlaygroundLimits.DEFAULTS.keys():
		var key: StringName = group
		var cvar := add_cvar(
			"pg_max_%s" % String(key),
			str(int(limits.defaults[key])),
			"Most %s one player may have at once. 0 is no limit." % String(key)
		)
		cvar.with_min(0.0)
		cvar.changed.connect(func(_old: String, value: String) -> void:
			limits.defaults[key] = maxi(value.to_int(), 0)
			limits.apply_to(game.props.limits)
		)

	var roles := add_cvar(
		"pg_limit_roles", "",
		"Per-role limits: 'admin: npcs=40 props=600; vip: props=300'. A role is an admin group, admin or root."
	)
	# Refused at the console rather than half-applied: a typo in one role must not leave
	# the others changed and this one silently ignored.
	roles.with_validator(func(text: String) -> DotResult: return PlaygroundLimits.new().set_roles_from(text))
	roles.changed.connect(func(_old: String, value: String) -> void:
		var _set := limits.set_roles_from(value)
	)

	limits.roles_fn = _roles_of

	add_command(
		"pg_limits", _cmd_limits, "pg_limits [player] — what somebody has against their limits", ""
	).with_chat()


## `pg_pickup` turns picking players up with the physics gun on and off; `pg_pickup_immune`
## names the roles nobody may pick up, and `pg_pickup_override` the roles that may anyway.
## The roles are the limits' roles, so one admin file answers both.
func _bind_pickup() -> void:
	var pickup := game.pickup
	pickup.roles_fn = _roles_of

	var on := add_cvar("pg_pickup", "1" if pickup.enabled else "0",
		"1 lets the physics gun pick up players; 0 refuses it.", DotConVar.FLAG_NOTIFY)
	on.changed.connect(func(_old: String, value: String) -> void:
		pickup.enabled = value.to_int() != 0
		if not pickup.enabled:
			pickup.release_all(game.players)
	)

	var immune := add_cvar("pg_pickup_immune", ",".join(pickup.immune_roles),
		"Roles nobody may pick up, e.g. 'admin, vip'. A role is an admin group, admin or root.")
	immune.changed.connect(func(_old: String, value: String) -> void:
		pickup.immune_roles = PlaygroundPickup.parse_roles(value)
	)

	var override := add_cvar("pg_pickup_override", ",".join(pickup.override_roles),
		"Roles that may pick up anybody, immune or not.")
	override.changed.connect(func(_old: String, value: String) -> void:
		pickup.override_roles = PlaygroundPickup.parse_roles(value)
	)


## `pg_creative` allows creative mode (on by default) and `!creative` toggles it for the
## caller. Turning the cvar off takes everybody out of it at once, because an operator who
## switched it off mid-match meant now.
func _bind_creative() -> void:
	var allowed := add_cvar("pg_creative", "1" if game.config.allow_creative else "0",
		"1 lets players switch on creative mode (!creative); 0 refuses it and ends it for everybody.",
		DotConVar.FLAG_NOTIFY)
	allowed.changed.connect(func(_old: String, value: String) -> void:
		game.config.allow_creative = value.to_int() != 0
		if not game.config.allow_creative:
			for id in game.players.keys():
				var _off := game.set_creative(id, false)
	)

	add_command("creative", _cmd_creative,
		"Creative mode: your props and you cannot be touched, and you cannot hurt anybody", "").with_chat()


## `pg_destruction` (off) lets shots and blasts break props with health; `pg_prop_surf`
## (on) lets a moving prop carry whoever stands on it. Both live: the next shot, the next tick.
func _bind_props_feel() -> void:
	var destruction := add_cvar("pg_destruction", "1" if game.config.destruction else "0",
		"1 lets shots and blasts break crates, planks and barrels into debris; 0 makes props unbreakable.",
		DotConVar.FLAG_NOTIFY)
	destruction.changed.connect(func(_old: String, value: String) -> void:
		game.config.destruction = value.to_int() != 0
	)

	game.panes_break = game.config.breakable_glass
	var glass := add_cvar("pg_breakable_glass", "1" if game.config.breakable_glass else "0",
		"1 lets shots, blasts and fast impacts break a map's glass; 0 makes it as hard as the walls.",
		DotConVar.FLAG_NOTIFY)
	glass.changed.connect(func(_old: String, value: String) -> void:
		game.config.breakable_glass = value.to_int() != 0
		game.panes_break = game.config.breakable_glass
	)

	var surf := add_cvar("pg_prop_surf", "1" if game.config.prop_surfing else "0",
		"1 lets a moving prop carry whoever stands on it; 0 leaves props still under your feet.",
		DotConVar.FLAG_NOTIFY)
	surf.changed.connect(func(_old: String, value: String) -> void:
		game.config.prop_surfing = value.to_int() != 0
	)


func _cmd_creative(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)

	if player == null:
		ctx.reply("Only a player has a creative mode.")
		return

	var turned := game.set_creative(player.player_id, not player.creative)

	if not turned.ok:
		ctx.reply_error(turned)
		return

	ctx.reply("Creative mode %s." % ("on: your props and you cannot be touched" if player.creative else "off"))


## The roles a world player holds: their admin groups by name, and `admin` / `root`.
func _roles_of(player_id: StringName) -> PackedStringArray:
	var out := PackedStringArray()

	if server == null:
		return out

	var session := server.session_by_userid(_session_of(player_id))

	if session == null:
		return out

	out.append_array(session.groups)

	if not session.permissions.is_empty():
		out.append("admin")

	if session.permissions.has(DotAdminFlags.ROOT):
		out.append("root")

	return out


func _cmd_limits(ctx: DotCmdContext) -> void:
	var who := StringName(ctx.arg(0)) if ctx.arg(0) != "" else &""

	if who == &"" and ctx.session != null:
		who = StringName("u%d" % ctx.session.userid)

	if who == &"" or not game.players.has(who):
		ctx.reply("Usage: pg_limits <player id, e.g. u3>. Players: %s" % ", ".join(
			PackedStringArray(game.players.keys())
		))
		return

	ctx.reply_lines(game.spawn_limits.describe_for(
		who, game.props.group_usage(who), game.constraint_count(who)
	))


func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines(game.describe_lines())

	if _last_spoke != "":
		ctx.reply("last spoke   %s" % _last_spoke)

	for layer in [arena, waves, vote]:
		if layer != null:
			ctx.reply_lines(layer.describe_lines())


func _cmd_services(ctx: DotCmdContext) -> void:
	ctx.reply_lines(services.describe_lines())


func _cmd_arena(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"on":
			set_arena(true)
			ctx.reply("The arena is on: %d fighting." % game.players.size())
		"off":
			set_arena(false)
			ctx.reply("The arena is off. This is a sandbox again.")
		_:
			ctx.reply_lines(arena.describe_lines())


## Turns the arena on or off, and says so to every client through `pg_arena_on`.
func set_arena(on: bool) -> void:
	if arena == null:
		return
	if arena.enabled != on:
		arena.set_enabled(on)
		# A living player watching a living one while they are shooting at each other is a
		# wallhack, and this is the moment it stops being a sandbox.
		spectate.set_fighting(on)
		if on:
			# Everybody already here joins the fight. A match that only admitted people who
			# connected *after* it started would be a match the server's existing players are
			# spectators in, with nothing saying so.
			for id in game.players.keys():
				arena.admit(id, String(id))
	if _arena_on != null and _arena_on.get_bool() != on:
		_arena_on.force_set("1" if on else "0")


# --- The loadout (B) ----------------------------------------------------------

func _build_loadout_command() -> void:
	_arena_on = add_cvar("pg_arena_on", "1" if arena.enabled else "0",
		"Whether the arena is on (pg_arena); clients read it to know B has a loadout to open",
		DotConVar.FLAG_REPLICATED)
	if _arena_on != null:
		# A method, never a lambda: a lambda captures this module and the cvar would keep it alive.
		_arena_on.changed.connect(_on_arena_on_changed)
	arena.respawned.connect(func(id: StringName) -> void:
		var _armed: Variant = await _arm_from_loadout(PlaygroundNetBridge.session_of(id)))

	if DotAddonApi.build_level("dot_loadout") < 2 or not ResourceLoader.exists(LOADOUT_COMMAND_SCRIPT) \
			or arena.loadouts == null:
		return
	loadout_command = (load(LOADOUT_COMMAND_SCRIPT) as GDScript).new()
	loadout_command.set(&"manager", arena.loadouts)
	loadout_command.set(&"key_fn", func(ctx: Object) -> String:
		var session: Variant = ctx.get(&"session") if ctx != null else null
		return loadout_key(int((session as Object).get(&"userid"))) if session is Object else "")
	loadout_command.set(&"closed_fn", func(_key: String) -> String:
		return "" if arena.enabled else LOADOUT_ARENA_ONLY)
	loadout_command.set(&"applied_fn", func(_ctx: Object, key: String) -> bool:
		return await rearm_if_allowed(key.trim_prefix("pg-player-").to_int()))
	loadout_command.call(&"bind", self)


func _on_arena_on_changed(_old: String, value: String) -> void:
	set_arena(value.strip_edges() == "1")


## Puts the loadout's weapon in [param session_id]'s hands now when they are inside their
## arena spawn protection; otherwise it waits for their next arena spawn. True when it did.
func rearm_if_allowed(session_id: int) -> bool:
	if arena == null or not arena.is_protected(PlaygroundNetBridge._player_key(session_id)):
		return false
	return await _arm_from_loadout(session_id)


## Hands [param session_id] the weapon their loadout names, through the bridge (the shop
## charges as for any weapon; the client adopts it from the WEAPON event). False when there is
## nothing to hand.
func _arm_from_loadout(session_id: int) -> bool:
	if arena == null or arena.loadouts == null or bridge == null or session_id <= 0:
		return false
	var res: DotResult = await arena.loadouts.active_for(loadout_key(session_id))
	if not res.ok:
		return false
	var weapon := (res.value as DotLoadout).item_in(&"primary")
	var id := PlaygroundNetBridge._player_key(session_id)
	if weapon == &"" or not game.players.has(id):
		return false
	bridge._give_weapon(session_id, id, weapon)
	return true


func _cmd_waves(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"on":
			waves.set_enabled(true)
			# Being killed by a wave is what being downed is for, so the two switch together.
			downs.set_enabled(true)
			ctx.reply("Waves are on, and a player at zero health goes down rather than dying.")
		"off":
			waves.set_enabled(false)
			downs.set_enabled(false)
			ctx.reply("Waves are off, and the map is cleared of them.")
		"clear":
			var gone := waves.spawner.clear_all()
			ctx.reply("Cleared %d." % gone)
		_:
			ctx.reply_lines(waves.describe_lines())


## `pg_spec` — watch somebody else. In a sandbox watching is not about being dead: the interesting thing is what somebody is making.
func _cmd_spec(ctx: DotCmdContext) -> void:
	var session := ctx.session

	if session == null:
		ctx.reply("Only a player can watch somebody.")
		return

	var viewer := _player_id(session)

	match ctx.arg(0):
		"", "next":
			var res := spectate.next_target(viewer)
			ctx.reply(
				("Watching %s." % String(spectate.target_of(viewer))) if res.ok
				else res.error.message
			)
		"off", "stop":
			spectate.stop(viewer)
			ctx.reply("Back to your own view.")
		_:
			var wanted := _player_named(ctx.arg(0))

			if wanted == &"":
				ctx.reply("There is nobody called '%s' here." % ctx.arg(0))
				return

			var res := spectate.watch(viewer, wanted)
			ctx.reply(
				("Watching %s." % String(wanted)) if res.ok else res.error.message
			)


## A player id by display name, case-insensitively and by prefix (`!pg_spec ad` finds Ada).
##
## The first match wins, in the roster's stable order; refusing an ambiguous prefix loses players.
func _player_named(text: String) -> StringName:
	var wanted := text.strip_edges().to_lower()

	if wanted == "":
		return &""

	for session in server.sessions():
		var name := session.display_name.to_lower()
		if name == wanted or name.begins_with(wanted):
			return _player_id(session)

	for id: Variant in game.players.keys():
		var name := String(id).to_lower()
		if name == wanted or name.begins_with(wanted):
			return StringName(id)

	return &""


## `pg_shop` — turn the price list on, off, or read it. Off by default: installing an addon must not turn a sandbox into a game.
func _cmd_shop(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"on":
			shop.set_enabled(true)
			ctx.reply("The shop is on. Everything has a price now.")
		"off":
			shop.set_enabled(false)
			ctx.reply("The shop is off. Take what you like.")
		"prices":
			if shop.economy == null or shop.economy.shop == null:
				ctx.reply("There is no price list.")
			else:
				ctx.reply_lines(shop.economy.shop.describe_lines())
		_:
			ctx.reply_lines(shop.describe_lines())


## `pg_credits` — read a balance, or hand somebody a few.
func _cmd_credits(ctx: DotCmdContext) -> void:
	var who := ctx.arg(0)

	if who == "":
		var lines := PackedStringArray()
		for id: Variant in game.players.keys():
			lines.append("%-20s %d" % [String(id), shop.balance(StringName(id))])
		if lines.is_empty():
			lines.append("Nobody is here.")
		ctx.reply_lines(lines)
		return

	var target := _player_named(who)

	if target == &"":
		ctx.reply("There is nobody called '%s' here." % who)
		return

	var amount := ctx.arg(1)

	if amount == "":
		ctx.reply("%s has %d." % [String(target), shop.balance(target)])
		return

	var paid := shop.award(target, amount.to_int(), &"admin")
	ctx.reply(
		"%s now has %d (%s%d)."
			% [String(target), shop.balance(target), "+" if paid >= 0 else "", paid]
	)


## `pg_give` — put something in somebody's bag, as the server. It reaches their client as
## the whole bag, like any change the server makes; see [PlaygroundInventoryNet].
func _cmd_give(ctx: DotCmdContext) -> void:
	var target := _player_named(ctx.arg(0))
	var item := StringName(ctx.arg(1))

	if target == &"" or item == &"":
		ctx.reply("pg_give <player> <prop> [count]")
		return

	if game.inventory == null or bridge == null or bridge.inventory_net == null:
		ctx.reply("This server has no inventory.")
		return

	var count := maxi(1, ctx.arg(2).to_int()) if ctx.arg(2) != "" else 1
	var bag := bridge.inventory_net.bag_key(PlaygroundNetBridge.session_of(target))
	var given := game.inventory.give(bag, item, count)

	if not given.ok:
		ctx.reply_error(given)
		return

	ctx.reply("%s now carries %d %s." % [String(target), game.inventory.carries(bag, item), item])


## `pg_inv` — what somebody is carrying, as the server has it.
func _cmd_inv(ctx: DotCmdContext) -> void:
	var target := _player_named(ctx.arg(0))

	if target == &"":
		ctx.reply("pg_inv <player>")
		return

	if game.inventory == null or bridge == null or bridge.inventory_net == null:
		ctx.reply("This server has no inventory.")
		return

	var bag := bridge.inventory_net.bag_key(PlaygroundNetBridge.session_of(target))
	ctx.reply_lines(game.inventory.for_player(bag).describe_lines())


func _cmd_achievements(ctx: DotCmdContext) -> void:
	var session := ctx.session

	if ctx.args.size() > 0:
		var found := server.find_sessions(ctx.arg(0), ctx.session)
		session = found[0] if not found.is_empty() else null

	if session == null:
		ctx.reply("Who?")
		return

	var key := PlaygroundPlatform.key_for_session(server, session)
	var listing := progress.achievements.listing(key)

	if listing.is_empty():
		ctx.reply("%s has earned nothing yet." % session.display_name)
		return

	ctx.reply("%s — %d points" % [
		session.display_name, progress.achievements.points_of(key)
	])

	for row in listing:
		var entry: Dictionary = row

		# A secret one that has not been earned is not listed at all. That is what
		# `secret` means, and a listing that named it would be a listing that spoils it.
		if bool(entry.get("secret", false)) and not bool(entry.get("unlocked", false)):
			continue

		ctx.reply("  %s %-24s %s" % [
			"*" if bool(entry.get("unlocked", false)) else " ",
			str(entry.get("name", "")),
			str(entry.get("description", "")),
		])


func _cmd_gag(ctx: DotCmdContext) -> void:
	await _punish(ctx, DotPunishment.Kind.GAG, "gagged")


func _cmd_mute(ctx: DotCmdContext) -> void:
	await _punish(ctx, DotPunishment.Kind.VOICE_MUTE, "muted")


## The shared half of gag and mute: dot-moderation models both as one record, differing only in kind.
func _punish(ctx: DotCmdContext, kind: DotPunishment.Kind, verb: String) -> void:
	if ctx.args.size() < 2:
		ctx.reply("Usage: %s <who> <seconds, 0 for permanent> [reason]" % ctx.command)
		return

	var targets := server.find_sessions(ctx.args[0], ctx.session)

	if targets.is_empty():
		ctx.reply("Nobody matches '%s'." % ctx.args[0])
		return

	if targets.size() > 1:
		# Refused rather than applied to all: `@me` and a name prefix can match several people.
		ctx.reply("'%s' matches %d people. Be more specific." % [
			ctx.args[0], targets.size()
		])
		return

	var session := targets[0]
	var seconds := maxi(0, ctx.arg_int(1))
	var reason := ctx.rest(2) if ctx.args.size() > 2 else "No reason given."

	var issued: DotResult = await services.moderation.issue(
		kind,
		DotPunishmentSubject.for_uid(session.uid()),
		reason,
		ctx.caller_label(),
		seconds,
		ctx.immunity
	)

	if not issued.ok:
		ctx.reply("Refused: %s" % issued.error.message)
		return

	ctx.reply("%s %s: %s" % [
		session.display_name, verb, DotPunishment.format_duration(seconds)
	])

	# Told to the person it happened to, on the channel they are reading. A mute nobody is
	# told about is a microphone that has stopped working, which is what they report.
	services.chat.notice(
		session.peer_id,
		(issued.value as DotPunishment).player_message(),
		PlaygroundServices.CHANNEL_ALL
	)
