extends RefCounted

## dot-auth accounts for the game's [DotGameWorkbench]: a connect ticket is accepted as the bearer when its uid is listed in `workbench.admin_uids` / `admin_groups`.

const CHANNEL := "pg.workbench"


## Admits tickets through [param resolver] on [param wb]'s api, beside the actors it already permits. [param admin_permit] is `(uid, flag) -> bool`.
static func attach(wb: DotGameWorkbench, resolver: Callable, admin_permit: Callable) -> DotWorkbenchIdentity:
	var api := wb.api as DotWorkbenchApi
	if api == null or not resolver.is_valid():
		return null
	var gate := DotWorkbenchIdentity.new()
	gate.resolver = resolver
	gate.fallback_permit = admin_permit
	gate.admin_uids = PackedStringArray(wb.config.get("admin_uids", []))
	gate.admin_groups = PackedStringArray(wb.config.get("admin_groups", []))
	var base: Callable = api.permit
	api.identity = gate.authenticate
	api.permit = func(actor: Variant, flag: String) -> bool:
		return gate.permit(actor, flag) or (base.is_valid() and bool(base.call(actor, flag)))
	api.runtime.actor_name = func(actor: Variant) -> String: return str(actor)
	return gate


## A resolver that verifies a dot-auth connect ticket offline against the server's key. Sync on purpose (the api hook is); a ticket is short-lived and checked for this server's audience, but not burned.
static func ticket_resolver(auth: DotAuthServer) -> Callable:
	if auth == null or auth.config == null or auth.config.ticket_public_key.is_empty():
		return Callable()
	# An empty server_id makes verify skip the audience check, so any server's ticket would pass.
	if auth.config.server_id.strip_edges().is_empty():
		return Callable()
	var key: String = auth.config.ticket_public_key
	var sid: String = auth.config.server_id
	var leeway: int = auth.config.ticket_leeway_sec
	return func(token: String) -> Variant: return identity_of_ticket(token, key, sid, leeway)


## The identity in a verified ticket, or null. A ticket with no expiry is refused: verify only checks `exp` when present.
static func identity_of_ticket(token: String, public_key: String, server_id: String, leeway: int) -> Variant:
	var res := DotAuthTicket.verify(token, public_key, server_id, leeway)
	if not res.ok:
		return null
	var who: DotAuthIdentity = (res.value as Dictionary).get("identity")
	return who if who != null and who.expires_at > 0 else null
