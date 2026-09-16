# 07 — Duplication smells in the honest pipeline

Type: follow-up (code-review)
Status: resolved
Blocked by:

## Answer

Refactored on v0.8.28 (2026-09-16), PAK `5B4925F2`, installed (modsettings new=2 old=0), luaparse PARSE OK.

1. **Honest-enqueue loop extracted** into `honestEnqueue(actor, target, knownNames, opts)` (BG3Neuro.lua:2858). Both `executeAttack` (~3493) and `executeBonusAction` (~3632) call it; `bonusAction=true` is passed via the options table. The error-threading formula from followup 04 (`enqOk and tostring(enqErr) or tostring(enqRes)`) lives inside the helper — reasons are still preserved on failure.
2. **Two-pass candidate filter extracted** into `knownSpellCandidates(actor, candidates)` (BG3Neuro.lua:2832); all three sites (executeCast use_osi_spell branch :3108, executeAttack :3481, executeBonusAction :3624) now call it. Behavior identical: known spellbook names first, then the rest as fallback order.
3. **`characterPartyFlags` string tri-state replaced** (:549-580) with a proper `boolean|nil` decode: booleans stay booleans, numbers decode `~= 0`, strings decode `~= "" and ~= "0"`, missing/ERR → nil (was fragile literal comparison of `"false (boolean)"`/`"0 (number)"`/`"ERR"`). `raw` string table is kept for `diag.party_flags_raw`. Callers (`detectIsPlayer`, combat-state) read truthiness, so nil behaves the same as false.
4. **scope-creep candidates dropped on static evidence, no bench needed:** `MeleeOffHandWeaponAttack` / `RangedOffHandWeaponAttack` are **AttackType names** (they appear inside spell data only as `SpellRoll "Attack(AttackType.MeleeOffHandWeaponAttack)"` etc.), **not spell entries** — no `new entry` exists for them in the stat index (verified in extracted Shared/Gustav/SharedDev stats). The two-pass filter would have dragged them into the honest enqueue as fallback names that can never match a stat. Resolved set left as per issues/05: `OffhandAttack`, `Target_OffhandAttack` (Spell_Target.txt:206), `Projectile_OffhandAttack` (Spell_Projectile.txt:43) — all confirmed present (well, `OffhandAttack` has no file entry either, but it is the ticket-05 umbrella name that the bench proved resolves; it stays for parity with the HasSpell guard which also probes it).

**Bench re-check still required** (per the fix proposal, "re-run the isPlayer bench check"): `characterPartyFlags` edge cases changed intent — a read error / nil field now decodes to `false` where the old literal-string comparison coaxed `true`. A normal ServerCharacter always yields real booleans, so `detectIsPlayer` and the honest player-variant cast are expected unchanged; confirm with one honest cast that it still comes out player-variant.

## Findings (judgement calls, not hard violations)

1. **Duplicated honest-enqueue loop** in `executeAttack` (~2471-2492) and `executeBonusAction` (~2605-2648): the same shape `for _, sid in ipairs(knownNames) do Ext.Stats.Get(sid) -> enqueueCastRequest(...) -> pipelineSucceeded()` with only the `bonusAction` flag differing. Extract into one helper.
2. **Duplicated two-pass candidate filter** (`knownNames`/`knownAdded`, HasSpell-first-then-rest) at three sites: `executeCast` use_osi_spell branch (~2262-2277), `executeAttack` (~2444-2459), `executeBonusAction` (~2605-2620). Extract `knownSpellCandidates(actor, candidates)`.
3. **Primitive Obsession (string tri-state)** in `characterPartyFlags` (BG3Neuro.lua:526-555): encodes fields as `"false (boolean)"` strings and compares literals; a proper `boolean|nil` result (with a decode flag) would be less fragile.
4. **Scope creep vs ticket 05:** `bonusCandidates` adds `MeleeOffHandWeaponAttack`/`RangedOffHandWeaponAttack` (BG3Neuro.lua ~2609-2612) — absent from `issues/05`. Justify on the bench or drop to the resolved set (`OffhandAttack`, `Target_OffhandAttack`, `Projectile_OffhandAttack`).

## Fix proposal

- Refactor 1+2 into shared helpers (pure extraction, behavior identical — require the three callers to keep passing their bench checks; luabalance for syntax).
- Refactor 3 only on touch: keep behavior, change representation, re-run the isPlayer bench check (honest cast still player-variant).
- Resolve 4 after a bench run of the bonus path.