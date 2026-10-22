extends RefCounted

## The admin workbench (dot-workbench) on the game's profile runtime: off unless `workbench.enabled` in cfg/server.yml.

const CHANNEL := "pg.workbench"

var api: DotWorkbenchApi = null
var http: DotWorkbenchHttp = null
var config: Dictionary = {}
var running := false


## Wraps the profiles' runtime with the permit rules it already holds (call after the console's permit is set).
## [param cfg] is the `workbench:` block of cfg/server.yml.
func start(profiles: RefCounted, cfg: Dictionary) -> DotResult:
	config = cfg
	if profiles == null or profiles.runtime == null or not bool(cfg.get("enabled", false)):
		return DotResult.success(0)
	api = DotWorkbenchApi.new(profiles.runtime)
	api.add_set(profiles.npcs)
	api.add_set(profiles.weapons)
	http = DotWorkbenchHttp.new(api)
	var res := http.start_from_config(cfg)
	if not res.ok:
		DotLog.result(CHANNEL, "workbench", res)
		stop()
		return res
	running = true
	DotLog.info(CHANNEL, "workbench listening", {"port": http.server.describe().get("port", 0)})
	return res


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
	running = false


func describe_lines() -> PackedStringArray:
	if not running:
		return PackedStringArray(["workbench    off (workbench.enabled in cfg/server.yml)"])
	return PackedStringArray(["workbench    " + JSON.stringify(http.describe())])
