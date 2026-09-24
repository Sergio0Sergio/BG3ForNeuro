# 04 — enqueueCastRequest seam: lost diagnosis + 11 positional args

Type: follow-up (code-review)
Status: resolved
Blocked by:

## Finding

Two weaknesses in the honest-enqueue seam (`enqueueCastRequest`, BG3Neuro.lua:1802):

1. **Lost enqueue diagnosis.** In `executeCast`/`executeAttack`/`executeBonusAction` the pcall result is `enqOk, enqRes, enqErr`; on `enqOk == true` but `enqRes ~= true` the actual failure reason is kept only in `enqRes` (`err` stays nil until the legacy `UseSpell` also fails), so the enqueue failure cause (e.g. `"ServerCastRequest unavailable…"`, `"Failed to get the caster entity"` — Russian diagnostics translated to English) is dropped from the error path and from `diag.enqueue_error`.
2. **Primitive Obsession / Data Clumps.** The call signature is 11 positional args (`actorUuid, spellName, targetUuid, posX, posY, posZ, spellType, insertAtFront, queueName, forceFlags, bonusAction`); the same `ok, err, usedWeaponSpell, honestUsed, usedSid` result tuple repeats in the three callers.

## Fix proposal

- Thread the enqueue failure reason through: on `enqOk and enqRes ~= true`, set `err = tostring(enqRes)` (the QA guard: mine `enqErr` only on pcall failure), so `CastSpellFailed` vs machine-failure stay distinguishable and diagnostics carry the reason.
- Convert the params to a single options table (`{ spellName, target, pos, spellType, insertAtFront, queueName, forceFlags, bonusAction }`) — touches all three callers; keep behavior identical (add a bench regression: the red-green checks in `executeCast` still pass).

## Answer

Implemented in BG3Neuro.lua (v0.8.28), PAK installed (MD5 `EED6003458DA4C0722008AA31429BC7F`, modsettings replaced x2).

1. **Reason threading (with a correction to the proposal).** The proposal's formula (`err = tostring(enqRes)`, "mine enqErr only on pcall failure") is inverted: Lua `pcall(function() return enqueue(f) end)` returns `true, <r1>, <r2>` for a *logical* failure (`nil, "reason"`) and `false, "text"` for a *pcall exception*. So the logical-failure reason lives in **enqErr**, the exception message in **enqRes**. Applied the correct guard `err = enqOk and tostring(enqErr) or tostring(enqRes)` in all three callers. Net effect (matches the finding's intent): `err` no longer stays `nil` when only the honest path fails, so the cause is preserved for the final `action_failed` detail and for `diag.enqueue_error` in `executeCast`.
   - `executeCast`: stashed the actual reason instead of the previous `enqOk and enqErr or tostring(enqRes)` (behaved right for exceptions but was fragile).
   - `executeAttack`: added the missing `else` (reason was previously dropped entirely).
   - `executeBonusAction`: same added `else`.
2. **Options table.** Signature now `enqueueCastRequest(actorUuid, opts)` with `{ spellName, target, pos, spellType, insertAtFront, queueName, forceFlags, bonusAction }`; derived internally (`pos.x/y/z`, `== true` for booleans, `spellType or "Target"`). All three callers updated. Behavior identical (queue, inserts, force-flags, NoMovement-removal for bonusAction unchanged).

Verification: luaparse PARSE OK; game closed via `CloseMainWindow` (was already not running); PAK repacked V18+LZ4 and installed; both modsettings MD5 occurrences updated, old MD5 gone (new=2 old=0).

Note: bench regression (red-green checks in `executeCast`) left to live bench — same as the other followups 03 (already closed).