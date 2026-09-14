# 04 — enqueueCastRequest seam: lost diagnosis + 11 positional args

Type: follow-up (code-review)
Status: open
Blocked by:

## Finding

Two weaknesses in the honest-enqueue seam (`enqueueCastRequest`, BG3Neuro.lua:1802):

1. **Lost enqueue diagnosis.** In `executeCast`/`executeAttack`/`executeBonusAction` the pcall result is `enqOk, enqRes, enqErr`; on `enqOk == true` but `enqRes ~= true` the actual failure reason is kept only in `enqRes` (`err` stays nil until the legacy `UseSpell` also fails), so the enqueue failure cause (e.g. "ServerCastRequest недоступен…", "Не удалось получить сущность кастера") is dropped from the error path and from `diag.enqueue_error`.
2. **Primitive Obsession / Data Clumps.** The call signature is 11 positional args (`actorUuid, spellName, targetUuid, posX, posY, posZ, spellType, insertAtFront, queueName, forceFlags, bonusAction`); the same `ok, err, usedWeaponSpell, honestUsed, usedSid` result tuple repeats in the three callers.

## Fix proposal

- Thread the enqueue failure reason through: on `enqOk and enqRes ~= true`, set `err = tostring(enqRes)` (the QA guard: mine `enqErr` only on pcall failure), so `CastSpellFailed` vs machine-failure stay distinguishable and diagnostics carry the reason.
- Convert the params to a single options table (`{ spellName, target, pos, spellType, insertAtFront, queueName, forceFlags, bonusAction }`) — touches all three callers; keep behavior identical (add a bench regression: the red-green checks in `executeCast` still pass).