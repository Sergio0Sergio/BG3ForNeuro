# 05 — Bonus actions through the honest pipeline

Type: grilling
Status: resolved
Blocked by:

## Answer

Owner's decisions (grill 2026-09-13):

- **v1 scope — ONLY `offhand_attack`.** The other 6 (`drink_potion`, `help`, `shove`, `disengage`, `dash`, `dodge`) are outside the honest v1 pipeline; the enum stays complete in the scheme (C4: the enum isn't resized), unavailable → failure with an actionable message, implementation later.
- **Mechanism (refined on the bench):** the bonus attack goes through `enqueueCastRequest(bonusAction=true)` and casts a **separate weapon stat `OffhandAttack`** (`Target_OffhandAttack`/`Projectile_OffhandAttack`). There's **no** `CastOffhand` option in `SpellCastOptions` of this game version (valid ones — IgnoreHasSpell..AvoidDangerousAuras), so the engine resolves the off-hand via the second-hand weapon action rather than a flag on MainHandAttack; and the game grants the separate stat into spellbooks only when there is a weapon in the off-hand.
- **BA deduction — native via ServerCastRequest** (CONFIRMED on the bench: BA snapshot 1.0→0.0, AP unchanged). No manual delta needed.
- **A weapon in the off-hand is required:** without it the `OffhandAttack` spell is absent and the honest cast "hangs" without a finalization event. Guard: `Osi.HasSpell(actor, OffhandAttack)` before casting → `action_failed` ("requires a light weapon in the off-hand").
- **Movement:** `NoMovement` is removed from CastOptions for bonus attacks (otherwise the engine won't approach a far target — CastSpellFailed/BlockedRequiredMove).
- **`isPlayer`** is determined by the `ServerCharacter` component (InParty/IsPlayer/PartyFollower); detecting "Player" in the name is only a fallback (a clean GUID without the marker drives into an NPC-cast with NULL-Source, and the engine silently rejects it).
- **Snapshot — the current one** SNAPSHOT_RESOURCES (5 resources, already includes BonusActionPoint), expected delta `BA −1`, AP unchanged. No separate bonus snapshot needed.
- A failed honest bonus increments the shared hybrid counter of 03 (enqueue error).

Output for implementation: the Lua `bonus_action` handler (action_type=offhand_attack): resolve actor/target → HasSpell guard → enqueueCastRequest with `Target_`/`Projectile_OffhandAttack` without CastOffhand and without NoMovement → pendingCasts finalization like a cast → before/after snapshot (BA −1). Other action_type → failure("not implemented in v1"), but the enum stays complete in the scheme.

## Question

Q1=(b): bonus actions must also be deducted through the honest economy. Currently the v1 scheme has `bonus_action` (drink_potion and others), but it's not implemented in Lua. Decide:

- Which specific actions count as bonus actions in the current spec (`drink_potion`, bonus spells?) — the list.
- How does the honest pipeline (`enqueueCastRequest`) express a bonus action: is it just another spell with Cost="BonusAction" in `Ext.Stats.Get`, intuitively the same ServerCastRequest? Or is a separate mechanism needed?
- Is the bonus deducted natively by the same `ServerCastRequest`, or is a manual `TransferActionResource` needed, as with movement?
- The role of `Osi.HasSpell`/the quality of spell candidates for bonus actions.
- Which bonus snapshot diagnostics to add (resource ×2: ActionPoint and BonusActionPoint).

Output: a list of bonus actions + the pipeline-node decision (shared/separate) + snapshot diagnostics.