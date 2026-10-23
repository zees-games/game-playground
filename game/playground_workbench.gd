extends RefCounted

## The admin workbench (dot-workbench) on the game's profile runtime: off unless `workbench.enabled` in cfg/server.yml.

const CHANNEL := "pg.workbench"

var api: DotWorkbenchApi = null
var http: DotWorkbenchHttp = null
var config: Dictionary = {}
var running := false
var identity: DotWorkbenchIdentity = null
## Callable(token) -> identity or null, backed by dot-auth; set before [method start] to admit accounts as well as the token.
var resolver: Callable = Callable()
## Callable(uid, flag) -> bool; the game's admin flags decide what an admitted account may do.
var admin_permit: Callable = Callable()


## Wraps the profiles' runtime with the permit rules it already holds (call after the console's permit is set).
## [param cfg] is the `workbench:` block of cfg/server.yml.
func start(profiles: RefCounted, cfg: Dictionary) -> DotResult:
	config = cfg
	if profiles == null or profiles.runtime == null or not bool(cfg.get("enabled", false)):
		return DotResult.success(0)
	api = DotWorkbenchApi.new(profiles.runtime)
	api.add_set(profiles.npcs)
	api.add_set(profiles.weapons)
	if resolver.is_valid():
		identity = DotWorkbenchIdentity.new()
		identity.resolver = resolver
		identity.fallback_permit = admin_permit
		identity.admin_uids = PackedStringArray(cfg.get("admin_uids", []))
		identity.admin_groups = PackedStringArray(cfg.get("admin_groups", []))
		identity.attach(api)
	http = DotWorkbenchHttp.new(api)
	var res := http.start_from_config(cfg)
	if not res.ok:
		DotLog.result(CHANNEL, "workbench", res)
		stop()
		return res
	running = true
	DotLog.info(CHANNEL, "workbench listening", {"port": http.server.describe().get("port", 0)})
	return res


## A resolver that verifies a dot-auth connect ticket offline against the server's key. Sync on purpose (the api hook is);
## a ticket is short-lived and checked for this server's audience, but not burned, so it is not a join.
static func ticket_resolver(auth: DotAuthServer) -> Callable:
	if auth == null or auth.config == null or auth.config.ticket_public_key.is_empty():
		return Callable()
	return func(token: String) -> Variant:
		var res := DotAuthTicket.verify(token, auth.config.ticket_public_key, auth.config.server_id, auth.config.ticket_leeway_sec)
		return (res.value as Dictionary).get("identity") if res.ok else null


## Call from the host's _process.
func poll() -> void:
	if running:
		http.poll()


## Closes the listener and gives the runtime its own permit back.
func stop() -> void:
	if http != null:
		http.stop()
	if api != null and api.runtime != null:
		api.runtime.permit = api.permit
	api = null
	http = null
	identity = null
	running = false


func describe_lines() -> PackedStringArray:
	if not running:
		return PackedStringArray(["workbench    off (workbench.enabled in cfg/server.yml)"])
	return PackedStringArray(["workbench    " + JSON.stringify(http.describe())])
