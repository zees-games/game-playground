# Not here yet

- **The module is a `DotModule`, not a `DotGameModule`**, deliberately for now: converting is its own piece of work (typed fields, build order, its own roster). Because of it the module wires identity and hibernation itself. [simulation](simulation.md#the-server-module)
- **`ask_restart` and `ask_checkpoint`** are on the bridge and handled by the server, and no key or menu calls them, so a networked client cannot restart a run or use a practice checkpoint. Each is a decision about bindings, not a deliberate omission. (`publish_loadout` is unused too: B goes through `/loadout`.)
- **A bag screen and buying into the bag; saving a bag.** [inventory](inventory.md#not-here-yet)
- **A wardrobe.** [client](client.md#people-are-drawn-as-people)
- **Grenades already in the air are not sent to a joiner**, and the thrower's own grenade is not predicted. [sandbox](sandbox.md#grenades-and-rockets)
- **The PROP event carries no frozen state**, so a mirror frozen later is not reclassified on a client. [netcode](netcode.md#a-prop-mirror-is-on-the-props-layer)
- **Replay playback.** dot-timer records and stores replays; drawing a ghost is a game's own decision. Deliberate for now.
