# 07 — Duplication smells in the honest pipeline

Type: follow-up (code-review)
Status: open
Blocked by:

## Findings (judgement calls, not hard violations)

1. **Duplicated honest-enqueue loop** in `executeAttack` (~2471-2492) and `executeBonusAction` (~2605-2648): the same shape `for _, sid in ipairs(knownNames) do Ext.Stats.Get(sid) -> enqueueCastRequest(...) -> pipelineSucceeded()` with only the `bonusAction` flag differing. Extract into one helper.
2. **Duplicated two-pass candidate filter** (`knownNames`/`knownAdded`, HasSpell-first-then-rest) at three sites: `executeCast` use_osi_spell branch (~2262-2277), `executeAttack` (~2444-2459), `executeBonusAction` (~2605-2620). Extract `knownSpellCandidates(actor, candidates)`.
3. **Primitive Obsession (string tri-state)** in `characterPartyFlags` (BG3Neuro.lua:526-555): encodes fields as `"false (boolean)"` strings and compares literals; a proper `boolean|nil` result (with a decode flag) would be less fragile.
4. **Scope creep vs ticket 05:** `bonusCandidates` adds `MeleeOffHandWeaponAttack`/`RangedOffHandWeaponAttack` (BG3Neuro.lua ~2609-2612) — absent from `issues/05`. Justify on the bench or drop to the resolved set (`OffhandAttack`, `Target_OffhandAttack`, `Projectile_OffhandAttack`).

## Fix proposal

- Refactor 1+2 into shared helpers (pure extraction, behavior identical — require the three callers to keep passing their bench checks; luabalance for syntax).
- Refactor 3 only on touch: keep behavior, change representation, re-run the isPlayer bench check (honest cast still player-variant).
- Resolve 4 after a bench run of the bonus path.