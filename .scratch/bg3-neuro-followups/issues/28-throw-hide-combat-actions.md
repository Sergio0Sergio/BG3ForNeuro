# 28 — `throw` / `hide` as separate combat actions

Type: feature
Status: resolved (hide verified; throw bench-proven as `not_supported`)
Blocked by: —

## Goal

Enable `throw` and `hide` as full-fledged separate combat actions after triage
(the user chose the "Separate throw + hide actions (Recommended)" option), instead of
the previous `throw` → NotSupported and the missing hide executor.

- **hide**: cast `Shout_Hide` (Shout, no target) through the cast queue; bonus-action by economy.
- **throw**: cast of the `Throw_Throw` prototype with an `Item` field (item EntityHandle) in `EsvSpellCastCastStartRequest`
  (`ExtIdeHelpers.lua:16770`). Without `Item` the cast would throw nothing.

## What's done (C#, ready in repo)

- `ActionRouter.cs`: the `throw` → NotSupported block removed (former L387-390), `ValidateThrow` added
  (item_id/target_id required, target among enemies/allies, otherwise `TargetMissing` with the list of known targets);
  `hide` added to `requiresCombatPhase`.
- `action_schemas.json`: the `hide` schema (required `[]`) added after `throw`.
- `DecisionLoop.cs`: `"hide"` in `CombatActionNames`.
- `ActionRouterTests.cs`: `Throw_NotSupported…` replaced with 8 throw/hide tests.

## What's left (Lua, server)

- `scanPartyInventory` (L3068): fill the global `BG3NEURO_ITEMS = {}` (alias `inv_N` → item guid).
  **Global, not local** — the main chunk is at the 200 active-locals limit.
- `enqueueCastRequest` (L3739): the `opts.item` option → `request.Item = Ext.Entity.Get(uuid)`.
- `executeThrow` / `executeHide` via a global table (following the pattern of `BG3NEURO_SIGHT`/`BG3NEURO_REST`),
  `throw` / `hide` branches in the `executeAction` dispatcher (~L6150).

## Known gaps / risks

- **The combat state `buildCombatState` (L2355) does NOT contain inventory** (`scanPartyInventory` is only
  called in exploration, L3192). Neuro will not see `item_id` in combat → item selection is impossible. Option:
  add `state.inventory` to the combat state (the decision is deliberately deferred — C# validation only checks
  field requiredness, the honesty verdict is given by Lua).
- The old research (`bg3se-lua-action-api.md`) "throw cannot be automated" — **confirmed** on the bench.

## Bench verdict on throw (2026-09-23, v0.8.79, battle at the grove, Tav vs Goblin Tracker)

The engine **rejects the synthetic throw in all tested variants** — `CastSpellFailed(caster, "Throw_Throw", "throw", "", storyActionID=0)`,
the `UsingSpell` event does not even fire:

- v0.8.78 (force-flags): queues `osiris`, `network`, `item`, `anubis` — 4/4 `cast_failed` (bt28_throw1–4).
- v0.8.79 (honest cast, `FromClient`, not forced): `item` and `network` — 2/2 `cast_failed` (bt28_throw5–6).

Yet the request really does reach the queue (`ItemStartRequests` entry: spell=Throw_Throw, opts=[ShowPrepareAnimation,FromClient,NoMovement,AvoidDangerousAuras],
storyActionId=0, item=Entity, a8=1) — the structure is identical to successful honest attack casts (OsirisCastRequests), but the engine rejects exactly the entry with Item.
A live manual throw (05-24 logs) right before the cast shows `QRY_GetMoveForbiddenItemInfo` and `AddedTo(item, caster, "Regular")` —
the engine picks the item up into the hand itself as part of the client flow; the synthetic request apparently lacks this stage.

**Closed as unsupported** (per the user's decision), the research conclusion confirmed. Hide verified and working.

## Acceptance

- `throw {actor, item_id, target_id}` in combat: cast `Throw_Throw` + `Item`, honest status/result.
- `hide {actor}` in combat: cast `Shout_Hide` (no target), BA by economy.
- Schemas in `action_schemas.json`, C# validation, Lua executors, PAK v113, luaparse + countlocals (200/200).

## Note: throw is frozen, but not written off

The throw question can be revisited in the future — as a separate ticket. Promising directions:

- **Client-initiated flow**: understand how the Ecl client starts a Throw from the inventory (picking the item up
  into the hand → cast), and replicate it server-side (AnubisPickUpItem / AnubisMoveItem before ItemStartRequests).
- **Live capture**: during a live manual throw by the player, take a snapshot of the queues/request structure to compare
  with the synthetic one (in v0.8.78–79 the capture exists only for our requests).
- **`EsvSpellCastChangeStoryActionId`**: the engine assigns the StoryActionId to live casts itself during processing;
  for an honest Item-cast the ID stayed 0 — maybe a preliminary initialization of
  ActionOriginator/StoryActionId is required, not just a field in the request.