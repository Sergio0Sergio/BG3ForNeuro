# 16 — Ally-targeted buff via osiris queue: engine rejects/misses status application (NOT self-cast)

Type: task (live bench) — **resolved: root cause + working fix found**
Status: resolved (2026-09-18)
Fix decision: use `force_flags` (or equivalent) for ally-targeted buff casts; see "Resolution".

> **2026-09-21 (тикет 22): вывод усилен серверной истиной.** На чистом бою `stats_probe`
> (raw StatusManager, не SE-события) подтвердил: GUIDANCE ложится на целевого союзника
> при ВСЕХ комбинациях — мягкий набор + osiris (c16a), сетевые флаги soft (c20n) и жёсткий
> osiris `Forced/Immediate` + `force_flags:true` (c23g2). «Иконка у кастера» — индикатор
> концентрации, не носитель статуса (см. CONTEXT.md → Диагностические ловушки). Термин
> «самокаст» в тикетах 16/22 окончательно закрыт.

## Original finding (2026-09-18, v0.8.47 / PAK v053, gate scene, file bridge — no C# app)

In a controlled battle, a `cast_spell` of `bless` (`Target_Bless`) with `target_id: "tav"`
returned `success: true`, but the buff was NOT observed on Tav. A `"target"` literal in the
SE-log `DB_GLO_CastedSpell` fact looked like a self-cast placeholder, so the working hypothesis
became "osiris queue self-casts ally buffs". **That hypothesis is now falsified** (see Resolution):
the literal `"target"` is how BG3 records the *spell's* TargetingMode for the fact; it does NOT
denote the recipient. The engine's *actual* recipient was correct in every single run.

## Full bench (v0.8.48 / PAK v054, same gate scene, plus a follow-up round)

All on Shadowheart, casting onto Astarion (`c7c13742-...`) unless noted:

| Variant | Channel | storyActionID | Engine outcome |
|---|---|---|---|
| (a) bless, default osiris | `OsirisCastRequests` | 760 | `UsingSpellOnTarget(Sh, Ast, ...)` correct; `StatusAttemptFailed(Ast,"BLESS",Sh)` — **no status** |
| (b) bless, `use_osi_spell:true` | `Osi.UseSpell` | 772 | same shape: target correct, `StatusAttemptFailed` — **no status** |
| (c) bless, `queue:"network"` | `NetworkStartRequests` | 0 | `CastSpellFailed` — whole cast rejected (engine, own turn) |
| (g1) guidance, default osiris, on her OWN turn | `OsirisCastRequests` | 0 | `CastSpellFailed` — rejected |
| **(g2) guidance, default osiris + `force_flags:true`** | `OsirisCastRequests` | 810 | `StatusApplied(Ast,"GUIDANCE",Sh)` — **status applied** (visual confirmed) |

The deciding SE-log lines are the *recipient-scoped* events, which always carried the real ally guid:

```
UsingSpellOnTarget(S_Player_ShadowHeart_.., S_Player_Astarion_c7c13742-.., "Target_Bless", "target", "Enchantment", 762)
PROC_CastedSpellOnTarget( S_Player_ShadowHeart_.., S_Player_Astarion_c7c13742-.., "Target_Bless", ... 762 )
```

So: **the engine never self-cast.** The buff simply failed to apply because the cast never
graduated to a real status application; without `force_flags`, osiris-queue casts of friendly
targeted spells produce solid story actions (a/b) but the `StatusAttemptFailed` fires, and in the
caster's own turn (c/g1) the engine rejects them outright with `storyActionID 0`.

## Root cause

The machine-built cast request lacks the force flags the engine needs to run the full friendly-cast
status path. With `force_flags: true`, `enqueueCastRequest` replaces the player `CastOptions` with
`{ IgnoreHasSpell, IgnoreCastChecks, IgnoreSpellRolls, IgnoreTargetChecks, Forced, Immediate }`
(`BG3Neuro.lua:3496-3506`); that is the exact set that lets `Target_Guidance` / `Target_Bless`
apply their BUFF status on an ally (g2 vs a/b/c/g1). The `"target"` literal in `DB_GLO_CastedSpell`
is evidence of nothing — drop it from future diagnostics.

## Resolution

- Falsified: "osiris queue self-casts ally-targeted buffs". Target routing was always correct.
- Working path for ally-targeted (single-target friendly) buff casts:
  **`cast_spell` + `force_flags: true`** on the default osiris queue, verified live (g2).
  It graduates to `StatusApplied` on the target ally.
- Next (implementation): make `executeCast` apply the force-option set automatically when the
  resolved target is a party ally / not an enemy — either always for friendly-target buffs, or
  expose an explicit helper. `data.force_flags` currently reaches `enqueueCastRequest`
  (`executeCast` L3894-3897). Regression check: enemy-targeted casts must keep their AP/story
  behaviour (compl. contrast b2o/b4m: they already worked).
- **IMPL (2026-09-18, v0.8.49)**: `executeCast` now auto-enables `force_flags` when the resolved
  target is not an enemy of the caster (`data.force_flags == nil` → verdict from `hostilityOf`
  != "enemy"). `data.force_flags` stays an explicit override (incl. `false`). Osiris-unavailable
  (verdict `nil`) → no forcing, preserving enemy-cast behaviour. Same-enemy casts keep prior
  AP/story path.
- Honest-economy caveat observed on g2: AP snapshot before/after unchanged (1.0 → 1.0) and the
  spell cell stayed ready — the forced cast did not spend the action. **Confirmed by user**: the
  same turn, Shadowheart cast Guidance a second time on Gale after the g2 forced cast — the
  action was not consumed. For cantrips that is harmless; for leveled action-cost spells this
  breaks honest AP economy (tracked in followup ticket 18).

## Verification (done in this bench)

- `cast_debug.json` for every variant: targetUuid == Astarion guid, targetPos correct, spell
  `Target_Bless` / `Target_Guidance` from the caster's book, queue recorded.
- SE-log recipient-scoped facts (`UsingSpellOnTarget` / `CastedSpellOnTarget` / `StatusApplied`)
  vs status-outcome (`StatusAttemptFailed` / `CastSpellFailed`).
- Visual: Guidance glow/icon on Astarion confirmed; Guidance cell on Shadowheart still ready.

## Bench recipe (recorded for reproducibility)

Precondition: party turn, caster with an unused action + friendly single-target buff.
1. `state_capture`; pick caster (e.g. `poc_player_cleric`) + ally alias (e.g. `origin_astarion`).
2. Per fresh action, cast `bless`/`guidance` on the ally:
   (a) default osiris; (b) `use_osi_spell:true`; (c) `queue:"network"`; (d) `force_flags:true` (+guid variant: full guid instead of alias).
3. Compare `cast_debug.json` (targetUuid), result file, SE-log recipient events + status outcome.
4. Judge by **recipient-scoped** SE events + visual, NOT by the `"target"` literal.

## Evidence

- `mod/BG3Neuro/BG3Neuro.lua`: `executeCast` (L3836-3980, force flag plumbing L3894-3897),
  `enqueueCastRequest` (L3365-3606, `Targets` build L3454-3476, `cast_debug.json` L3569,
  force `CastOptions` L3496-3506), queue select L3478-3488.
- SE log `Osiris Runtime 2026-09-18 07-14-18.log`: `UsingSpellOnTarget(.. Astarion ..)`,
  `StatusAttemptFailed`, `StatusApplied(.. "GUIDANCE" ..)` at storyActionID 810.
- Bench ids: `n16a`/`n16b`/`n16c`/`n16g1`/`n16g2` (results + resource snapshots in the SE dir).

## Live verification of the v0.8.49 auto-force (2026-09-19, PAK v056, gate scene)

- **(v56t16a) Guidance, Shadowheart → Astarion, NO `force_flags` in payload** →
  `cast_debug.json`: `forceFlags:true` + force `CastOptions`, queue osiris,
  `Target_Guidance` on Astarion guid; SE log:
  `UsingSpellOnTarget(Sh, Ast, "Target_Guidance", …)` →
  `StatusApplied(Ast, "GUIDANCE", Sh, storyActionID 760)`. **Auto-force path works
  end-to-end.** AP snapshot 1.0→1.0 (nothing spent — ticket 18 live).
- **(v56t16b) FireBolt, Astarion → goblin_brawler_2, NO `force_flags`** →
  `forceFlags:false` + player `CastOptions` (no `Forced`); AP 1.0→0.0 honestly spent;
  projectile rules fired (storyActionID 761). **Enemy casts keep the normal path —
  no regression.**