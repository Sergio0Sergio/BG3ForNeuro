# 08: Exploration: movement/interaction/loot + simple actions

**What to build:** Everything Neuro can do outside combat: an exploration state with awareness (what is around and at what distance), `move_to_entity` (movement to a creature/object), `interact_with` (free-form `interaction_type` from the state; a mismatch → actionable failure with the list of available options), `loot`, `rest` (full/partial), `travel_to` (by region name, `region_id` optional), `toggle_mode [normal]` (stealth unavailable — X3), `open_map`/`open_inventory` (view-only → screen state). Rest requires a camp and supplies → `no_camp`.

**Blocked by:** 03 (combat loop/execution pattern), 05 (reusing coverage for distances/awareness — optional, could be merged with 08).

**Status:** done

- [x] Exploration state shows the nearest interactive objects/creatures with distance (hybrid §3.3 format) and available interactions.
- [x] `move_to_entity`, `interact_with`, `loot` execute outside combat; an invalid interaction_type → actionable failure (list of available ones).
- [x] `travel_to`: match by region name (primary), by `region_id` when given; unknown name → failure.
- [x] `rest` full/partial: camp/supplies check → `no_camp` when missing; the in-game sleep is performed.
- [x] `toggle_mode` accepts only `"normal"`; `"stealth"` → rejected with an explanation (X3).
- [x] `open_map`/`open_inventory` give the screen state; trading/equipping/dropping — out of scope (do not introduce).
- [x] End-to-end test: movement→interaction→loot on the real state.

**Summary:** 134/134 tests, build 0 warnings/errors, node 0. Lua v0.6.0 (not executed in CI — structural changes: `Osi.Use` isInteraction for `interact_with`, `MoveAllLootableItemsTo`/`OpenCharacterLootUI` for `loot`, `RequestLongRest` (full) + listeners `LongRestFinished/Cancelled/StartFailed` for `rest`; `travel_to`/`open_map`/`open_inventory`/partial rest — structural `running:true` + TODO (no confirmed public APIs; the exact effect arrives via the state generator, Channel B).