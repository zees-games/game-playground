# The bag

| | |
| --- | --- |
| `PlaygroundSpawnMenu` | what exists: a catalogue |
| `PlaygroundShop` | what it costs: a price list and a purse ([modes.md](modes.md#pg_shop-a-sandbox-with-prices)) |
| `PlaygroundInventory` | **what you have paid for and not yet used** |

"Buy three crates" and "buy one crate three times" differ only because something is held; `take()` refusing when you are not carrying one is the feature. `Playground.inventory` is built on both ends, authoritative exactly when the game is, and the bridge carries it.

**The item catalogue is derived from the prop catalogue**: weight is the prop's `mass`, grid size comes from its declared size band, and the tag from the same `kind_of()` the spawner uses. A second table of what can be carried goes stale the first time somebody adds a prop. Weapons are not items: they are not in the prop catalogue, and `weapon_changed` already carries them.

Every mutation is an **op**, which makes client-side drag-and-drop safe: apply locally, send, roll back on refusal. A server receiving state would have to diff two documents, and a diff cannot tell "this crate moved" from "destroyed and an identical one appeared".

## Over the wire: `PlaygroundInventoryNet`

`game/net/playground_inventory_net.gd` is both halves, beside the bridge that routes `Ask.INVENTORY` and `Kind.INVENTORY` to it. Each shape is the answer to the obvious alternative being wrong:

- **A client sends ops, never state, and only four kinds**: MOVE, SPLIT, MERGE, DROP. An ADD from a client is a client giving itself something, and a USE is what spawning does; both are refused with an ack. The op crosses field by field **without `state`**, the one field a client must not write.
- **Every op has a sequence number**, because two ops can be the same dictionary ("drop one of #3" twice) and `DotInvManager` finds ops by comparing `to_dictionary()`. Acks are cumulative on a reliable channel: an ack for #6 while #5 waits means #5 never arrived. **dot-net drops a request past its per-peer message rate and tells nobody**; without this a predicted op sits in the bag for ever. An op lost at the tail has nothing after it, so the client asks for the whole bag once the oldest answer is three seconds overdue.
- **A refusal rewinds everything in flight, newest first, and replays the survivors, here and not in the addon.** An answer can carry more than one refusal, and which ops to keep is a question about sequence numbers, which the manager never sees.
- **A change the server makes arrives as the whole bag, by choice.** The document **converges** (it puts right whatever the client got wrong, where an op stream carries a divergence forward silently), coalesces a tick's burst, and the join and resync need it anyway. It carries the newest sequence number it includes, and the client replays what it has sent since on top, so a purchase landing mid-drag does not snap the drag back. Once per tick per bag, after the game ticked.
- **Only ever to the owner.** Nothing about a bag is a replicated field, so dot-net's interest management never sees it. Every message goes through `_tell`, which refuses peer 0 (the broadcast address); the class is handed a way to reach one peer and no way to reach everybody. A bot has a bag and no peer, and is told nothing.
- **A bag belongs to a person, not a connection.** dot-server's userid is sequential and a reconnect is a new one. `PlaygroundModule._bag_key_for` is the statistics key (`PlaygroundPlatform.key_for_session`) and the bag is kept across a disconnect under it. `local:<userid>` identifies nobody next time and is answered as empty. The key a peer was admitted with is **remembered**, not recomputed on the way out, because dot-server may no longer have the session.
- **Every HELLO resets the client's bag and sequence**, even for the same userid: old in-flight ops replayed onto the new bag land on a layout under a sequence the server has forgotten.
- **JSON for the whole bag**, the format `DotInvDoc` claims; the wire sends the same bytes, which tests the claim on every join. **Too big to send is refused, not truncated**: `DotNetWriter.write_string` truncates, and truncated JSON is a bag the client silently fails to adopt.
- **Buying into the bag is checked, then charged, then given, and the check includes room** (`PlaygroundInventory.may_give`, which is `DotInvManager.validate`). Spawning something carried is free and takes it out **only after the spawner said yes**, so a budget refusal leaves the bag as it was.
- **The rate limit is the addon's, on the server, and the server's own changes are exempt**: thirty ops a second per actor (the session the request arrived on); `PlaygroundInventory.SERVER_ACTOR` is in every manager's `unlimited_actors`. Client managers are unlimited: a client limiting itself protects nothing, and after a whole-bag correction it re-applies everything in flight in one frame.

## Not here yet

- **A screen for the bag, and a key that buys into it.** The wire, the server's rules and the client's copy exist (`PlaygroundNetBridge.inventory_manager()`, `ask_buy`), and `DotInvPanel` is the grid (its `_can_drop_data` asks the same `validate`), but nothing in the game builds the panel or calls `ask_buy`. Pocketing a prop you own back into the bag is the other missing producer.
- **Saving a bag.** Bags outlive a reconnect, not a restart. The document is already the JSON a save would be.
