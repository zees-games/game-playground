extends SceneTree

## Live proof that a purchase made on the site reaches a game's loadout: a real DotBackboneClient asks the site's
## STORE_READ entitlements route and the manager wrapped by DotGameStoreEntitlements.attach holds the result.
## Dev site only; the token is a dev credential. Exit 1 when the expected item is not held.
##
##   STORE_PLAYER=<scoped key> STORE_EXPECT=e2e_trail STORE_TOKEN_FILE=~/.config/dot/store-token-dev-games \
##   STORE_URL=https://games.tmcdev.net godot --headless --path . --script tools/store_live_check.gd

func _initialize() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	var url := OS.get_environment("STORE_URL") if OS.get_environment("STORE_URL") != "" else "https://games.tmcdev.net"
	var player := OS.get_environment("STORE_PLAYER")
	var expect := OS.get_environment("STORE_EXPECT")
	var token := FileAccess.get_file_as_string(OS.get_environment("STORE_TOKEN_FILE")).strip_edges()
	if player == "" or expect == "" or token == "":
		printerr("store_live_check: set STORE_PLAYER, STORE_EXPECT, STORE_TOKEN_FILE")
		quit(2)
		return
	var cfg := DotAuthConfig.new()
	cfg.backbone_url = url
	cfg.integration_token = token
	var client := DotBackboneClient.new()
	client.config = cfg
	client.auto_report = false
	client.register_as = &"dot_backbone_client"
	root.add_child(client)
	var started: DotResult = client.start()
	if not started.ok:
		printerr("store_live_check: ", started.error)
		quit(2)
		return
	var manager := DotLoadoutManager.new()
	manager.entitlement_source = func(_key: String) -> DotLoadoutEntitlements:
		return DotLoadoutEntitlements.of([])
	var attached := DotGameStoreEntitlements.attach(manager)
	manager.entitlement_source.call(player)
	var held := false
	for i in 100:
		await create_timer(0.1).timeout
		var ents: DotLoadoutEntitlements = manager.entitlement_source.call(player)
		if ents.holds(StringName(expect)):
			held = true
			break
	print("store_live_check: attached=%s player=%s expect=%s held=%s" % [attached, player, expect, held])
	quit(0 if attached and held else 1)
