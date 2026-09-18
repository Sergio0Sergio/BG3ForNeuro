# 18 — force_flags osiris casts do not consume the action point (honest AP economy)

Type: task (live bench)
Status: open
Blocked by: none (evidence collected; needs a fixing bench for leveled spells)

## Finding (2026-09-18, v0.8.48 / PAK v054, gate scene)

While resolving ticket 16, `cast_spell` with `force_flags: true` (osiris queue) on Shadowheart
successfully applied `GUIDANCE` to Astarion — but the cast did not cost an action:

- `resource_snapshot_n16g2_before.json` → `ActionPoint 1.0`, `after` → `ActionPoint 1.0`
  (also `BonusActionPoint 1.0`, `Movement 9.0` unchanged).
- The spell cell stayed ready, and the user cast Guidance **a second time** in the same turn
  (on Gale) — impossible with a real AP cost.

## Root cause (hypothesis)

`force_flags: true` swaps player `CastOptions` for
`{ IgnoreHasSpell, IgnoreCastChecks, IgnoreSpellRolls, IgnoreTargetChecks, Forced, Immediate }`
(`BG3Neuro.lua:3496-3506`). The `Forced`/`Immediate`/option combination lets the engine run the
status-application path but bypasses the normal action/resource deduction of a player-turn cast.
The status lands (`StatusApplied`, ticket 16 g2) but no AP is spent.

## Scope / impact

- Friendly-targeted buffs are the *only* path currently known to need `force_flags` (ticket 16).
  If the fix for ticket 16 routes friendly buffs through `force_flags` automatically, this AP-leak
  becomes a real economy bug for the controller (free actions every turn).
- Cantrips (Guidance/Resistance) lose nothing — but a leveled buff (Bless, Cure Wounds) cast this
  way would also skip its slot/AP check.

## Options

1. After a `force_flags` cast, deduct the action manually via the action-resource API
   (verify what the engine exposes; snapshot after a short delay showed no change, so the delay
   is not a factor).
2. Use `force_flags` only as last resort and prefer a compliant path for friendly buffs
   (e.g. `use_osi_spell`, or network queue) — both were rejected/failed in ticket 16, so this
   needs a different angle (maybe `Osi.RequestUseSpell` with full action data).
3. For cantrip-level buffs, declare AP-freeness acceptable and document it; only enforce honest
   AP for leveled casts (check `spell` resource cost before deciding).

## Verification (once implemented)

- AP before/after a friendly-buff forced cast: after == before - 1 (action spells).
- Slot/resource snapshot unchanged for cantrips, correct deduction for leveled spells.
- Regression: enemy-targeted casts keep their current behaviour (b2o/b4m already work).

## Evidence

- `resource_snapshot_n16g2_{before,after}.json` (both `ActionPoint 1.0`).
- Second same-turn cast accepted (user-observed: Guidance on Gale after g2).
- `mod/BG3Neuro/BG3Neuro.lua`: `enqueueCastRequest` force `CastOptions` L3496-3506;