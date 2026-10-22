extends RefCounted

## Damage per second and time to kill from a flattened weapon profile (the workbench's `_read` rows) and an NPC's health.

const FALLBACK_HEALTH := 100.0


## `{shot, rpm, burst_dps, sustained_dps, mag, reload}`; empty when the weapon states no damage.
static func weapon_stats(v: Dictionary, tick_rate: float) -> Dictionary:
	var shot := float(v.get("extra.damage", 0.0)) * maxf(1.0, float(v.get("extra.pellets", 1.0)))
	if shot <= 0.0:
		shot = float(v.get("extra.splash_damage", 0.0))
	var rpm := float(v.get("extra.rpm", 0.0))
	var interval := float(v.get("use_interval_ticks", 0.0))
	if rpm <= 0.0 and interval > 0.0 and tick_rate > 0.0:
		rpm = 60.0 * tick_rate / interval
	if shot <= 0.0 or rpm <= 0.0:
		return {}
	var mag := int(v.get("magazine", 0))
	var reload := float(v.get("extra.reload_seconds", 0.0))
	if reload <= 0.0 and tick_rate > 0.0:
		reload = float(v.get("reload_ticks", 0.0)) / tick_rate
	var burst := shot * rpm / 60.0
	var sustained := burst
	if mag > 0 and reload > 0.0:
		var cycle := float(mag) * 60.0 / rpm + reload
		sustained = shot * float(mag) / cycle
	return {"shot": shot, "rpm": rpm, "burst_dps": burst, "sustained_dps": sustained, "mag": mag, "reload": reload}


## `{shots, seconds}` to bring [param health] to zero with [param stats]; empty without stats.
static func ttk(stats: Dictionary, health: float) -> Dictionary:
	if stats.is_empty() or health <= 0.0:
		return {}
	var shots := int(ceil(health / float(stats["shot"])))
	var seconds := float(maxi(shots - 1, 0)) * 60.0 / float(stats["rpm"])
	var mag := int(stats["mag"])
	if mag > 0 and shots > mag:
		seconds += float((shots - 1) / mag) * float(stats["reload"])
	return {"shots": shots, "seconds": seconds}


static func line(stats: Dictionary, health: float, target: String) -> String:
	if stats.is_empty():
		return "No damage stated: no DPS."
	var k := ttk(stats, health)
	return "%.0f DPS burst, %.0f sustained   |   vs %s (%.0f hp): %d shots, %.2f s" % [
		stats["burst_dps"], stats["sustained_dps"], target, health, k["shots"], k["seconds"]]
