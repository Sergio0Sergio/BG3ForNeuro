# 01 — Bonus action BA spend on legacy/hybrid fallback

Type: task (live bench)
Status: resolved
Blocked by: bench (live game test scene)

## Finding

`executeBonusAction` (BG3Neuro.lua): the honest path (`ServerCastRequest`, `bonusAction=true`) deducts `BonusActionPoint` natively — bench-confirmed (snapshot BA 1.0 → 0.0). But when that path fails (hybrid counter hit, or `force_legacy`), the fallback is plain `Osi.UseSpell`, which per the v0.8.22 finding "ignores resources" (`osiris` casts don't go through the economy).

Result: under `force_legacy` / after N=3 failures, a bonus attack costs **0** BonusActionPoint, contradicting ticket 05's economy intent. The former empty `if usedWeaponSpell and not honestUsed then -- TODO(стенд)` block that was meant to hold the manual spend was removed as dead code; its intent is this ticket.

Note: AP has a clean single-actor writer (`Osi.AddActionPoints(actor, -1)`, bench-proven v0.8.22); BA does **not** — `research/06` found `Osi.TransferActionResource` doesn't exist and `PartyIncreaseActionResourceValue` has party semantics (risky). So this needs a bench to pick a single-actor BonusActionPoint writer before implementing.

## Fix proposal

1. Bench: does `Osi.UseSpell(actor, OffhandAttack, target)` deduct BA natively? Record the BA snapshot around the legacy bonus.
2. If it does — no code change, just a comment/note.
3. If not — pick the single-actor bonus writer on the bench (candidates: `PartyIncreaseActionResourceValue` single-member party, `Ext.Stats`/resource APIs), then add the manual spend in the fallback branch, mirroring `executeAttack`'s AP spend (BG3Neuro.lua:2522-2527).

## Answer

Live bench (16.09, Patch 8 / SE v32, Tav half-elf fighter, turn Tav with BA=1.0/AP=1.0/Movement=9.0), injects via Randy `localhost:1337`, snapshots by the mod's `bench_*` diagnostics.

1. **`Osi.UseSpell(actor, "OffhandAttack", goblin_tracker_2)` — BA is NOT deducted natively.** `cast_ok=true` (no pcall error), BA snapshot 1.0 → 1.0.
2. **Control: `Osi.UseSpell(actor, "Projectile_MainHandAttack", goblin_tracker_2)`** (a real action-costing attack, target in range) — AP 1.0 → 1.0, BA 1.0 → 1.0, Movement unchanged. `Osi.UseSpell` bypasses the economy entirely, confirming the v0.8.22 "osiris casts ignore resources" finding.
3. **Writer probe — `Osi.PartyIncreaseActionResourceValue(actor, resource, delta)` is a no-op for personal resources:** `(BonusActionPoint, −1)`, `(BonusActionPoint, +1)`, `(Movement, −3)`, `(Movement, +2)` all returned `write_ok=true` (no exception) while the actor snapshot stayed unchanged (BA 1.0, Movement 9.0) right after the call.
4. **Writer set is exhausted** (generated `Osi.lua` dump): queries `GetActionResourceValuePersonal`, `PartyGetActionResourceValue`, `IsMovementBlocked`; writes `AddActionPoints` (AP-only) and `PartyIncreaseActionResourceValue` (no-op on personal). No `SetResource`, no `TransferActionResource`, no `ChangeActionResourceValue`.

**Conclusion:** the legacy/hybrid fallback **cannot spend BA via the public Osiris API** — there is no single-actor `BonusActionPoint` writer (AP's `AddActionPoints` has no BA analogue; `PartyIncrease…` doesn't touch personal values). The manual-spend branch from the fix proposal is therefore not implementable; it must not fake a spend that the engine won't honor.

**Decision:** enforce the BA budget in the mod's own router instead of in the engine. `executeBonusAction` tracks `legacyBonusUsedThisTurn`; the honest path keeps engine gating (native BA spend, bench-proven), and on the legacy path the mod (a) refuses a second bonus action in the same turn and (b) logs `[BG3Neuro] legacy bonus: BA budget enforced in-router (no engine writer)` loudly so the deviation is visible in the SE log. No engine write. Mirrors the honest-economy intent without lying to the engine.

Caveat: attack execution (damage landed) wasn't independently confirmed — the state doesn't refresh mid-turn and no `CastSpell` capture line appeared during the casts — but the economy conclusion (Osi path never touches AP/BA) is independent of it.

Implementation of the router BA gate (mod code + PAK rebuild) is a follow-up, not part of this resolution.

## Router gate — implementation (follow-up) & bench verification

**Code (v0.8.30, `BG3Neuro.lua`):** per-actor table `bonusUsedThisTurn = {}` (keyed by actor guid), cleared on every `TurnStarted`; honest path marks `bonusUsedThisTurn[actor] = true` on successful enqueue; legacy fallback refuses when the actor is already marked — `action_failed` "Bonus action already used this turn (BA budget enforced in-router)" — and logs both sides loudly:

- on accepted legacy cast: `[BG3Neuro] legacy bonus: BA budget enforced in-router (no engine writer)`
- on refused second use: `[BG3Neuro] legacy bonus REFUSED: BA already used this turn (in-router budget, no engine writer)`

**Bench (16.09, PAK v036L `force_legacy=true`, v0.8.30 loaded, save re-equipped with offhand weapons for Tav + Astarion):** Tav's turn at the gate, offhand equipped, target `goblin_tracker_2`:

| inject | result |
|---|---|
| `bonus_action` tav offhand #1 (`bax2`) | `{"success": true, "running": true}` + log "legacy bonus: BA budget enforced in-router (no engine writer)" |
| `bonus_action` tav offhand #2 (`bax3`) | `{"success": false, "error_code": "action_failed", "error_detail": "Bonus action already used this turn (BA budget enforced in-router)"}` + log "legacy bonus REFUSED: ..." |
| `bonus_action` tav offhand #3 (`bax4`) same turn | REFUSED again (same error), correct — still Tav's turn |

**Reset caveat:** the budget clears on the next `TurnStarted` (single line in the listener, luaparse OK), but this bench save is static — the engine turn never leaves Tav (100 s poll: `turn_actor=tav` throughout; legacy `end_turn` doesn't advance it: `end_turn verify: ended=false`), so a *fresh-Tav-turn* allowance could not be observed live. The reset leg is therefore bench-pending on a save where combat turns actually cycle; the gate refusal itself (the ticket's core) is proven.