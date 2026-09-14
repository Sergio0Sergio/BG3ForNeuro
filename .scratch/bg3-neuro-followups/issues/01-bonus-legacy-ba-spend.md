# 01 — Bonus action BA spend on legacy/hybrid fallback

Type: follow-up (code-review)
Status: open
Blocked by: bench (live game test scene)

## Finding

`executeBonusAction` (BG3Neuro.lua): the honest path (`ServerCastRequest`, `bonusAction=true`) deducts `BonusActionPoint` natively — bench-confirmed (snapshot BA 1.0 → 0.0). But when that path fails (hybrid counter hit, or `force_legacy`), the fallback is plain `Osi.UseSpell`, which per the v0.8.22 finding "ignores resources" (`osiris` casts don't go through the economy).

Result: under `force_legacy` / after N=3 failures, a bonus attack costs **0** BonusActionPoint, contradicting ticket 05's economy intent. The former empty `if usedWeaponSpell and not honestUsed then -- TODO(стенд)` block that was meant to hold the manual spend was removed as dead code; its intent is this ticket.

Note: AP has a clean single-actor writer (`Osi.AddActionPoints(actor, -1)`, bench-proven v0.8.22); BA does **not** — `research/06` found `Osi.TransferActionResource` doesn't exist and `PartyIncreaseActionResourceValue` has party semantics (risky). So this needs a bench to pick a single-actor BonusActionPoint writer before implementing.

## Fix proposal

1. Bench: does `Osi.UseSpell(actor, OffhandAttack, target)` deduct BA natively? Record the BA snapshot around the legacy bonus.
2. If it does — no code change, just a comment/note.
3. If not — pick the single-actor bonus writer on the bench (candidates: `PartyIncreaseActionResourceValue` single-member party, `Ext.Stats`/resource APIs), then add the manual spend in the fallback branch, mirroring `executeAttack`'s AP spend (BG3Neuro.lua:2522-2527).