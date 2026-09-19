# 18 — force_flags osiris casts do not consume the action point (honest AP economy)

Type: task (live bench)
Status: RESOLVED 2026-09-19 (option A implemented v0.8.50–0.8.53, verified live).
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

## Leveled bench (2026-09-19, v0.8.49 / PAK v056, gate scene, auto-force, NO payload flags)

- **(v56t18a) Bless, Shadowheart → Astarion**: `forceFlags:true`, success; SE log
  `StatusAttempt×3` + `StatusApplied(Ast,"BLESS",Sh,762)×3` + `StatusAttemptFailed×2`
  (multi-target application noise — Bless tries all target slots); state confirms
  Astarion has `BLESS`. **Leveled buffs land through auto-force.**
- AP snapshot `v56t18a`: 1.0→1.0, BA 1.0→1.0, Movement unchanged — **nothing spent**.
- Slot mechanics (already researched, honest-economy 02/06): read
  `Osi.GetActionResourceValuePersonal(actor, "SpellSlot", level)` (level 1..9,
  `WarlockSpellSlot` for warlocks); slot level from `UseCosts`
  (`spellSlotFromUseCosts`, proven: Bless→"1"); cost kind from `abilityCostOf`.
  Write: `Osi.PartyIncreaseActionResourceValue(actor, resource, delta)` (proven for
  AP/Movement; slot-level write semantics to verify live via snapshots).

## Option A design (decided)

1. **Pre-cast slot gate** (leveled only): read `SpellSlot`/`WarlockSpellSlot` at the
   cast's slot level; if < 1 → refuse honestly (`no_spell_slot`) instead of a free cast.
2. **Post-success deduction** (forced casts only): AP/BA per `abilityCostOf` via the
   proven `PartyIncreaseActionResourceValue`; slot level from `UseCosts` via the same
   writer (level semantics verified live against extended snapshots). Deduct only on
   final success (`storyActionID > 0` / `StatusApplied`), never on failure.
3. **Snapshot extension**: add `SpellSlot` 1..9 (+warlock) reads to `readResourceSnapshot`
   so deduction is verifiable before/after in every cast.

## Resolution (verified live 2026-09-19, v0.8.53 / PAK v060, gate scene)

- Writer hunt: Osiris has NO personal slot writer (full surface in `bg3se/Osi.lua`:
  read + `AddActionPoints` + party-`PartyIncrease`, which is no-op on personals).
  True writer found via entity components: `ActionResources.Resources[poolUuid][i].Amount`
  is directly writable from Lua (bench ep4: `1.`→`0.`; sp2: Osiris re-read L1=0.0).
  Pool UUIDs from `ActionResourceDefinitions.lsx` (Shared.pak): SpellSlot
  `d136c5d9-…`, WarlockSpellSlot `e9127b70-…`. Generic `entity_probe` diag action
  added for future component exploration.
- Final implementation (`deductForcedCastCost` + `writeResourceAmount`):
  AP via `Osi.AddActionPoints` (proven), BA/slots via component write;
  pre-gates for AP/BA/slots (`no_action_point`/`no_spell_slot`); deduction only on
  `CastedSpell` success, before the after-snapshot; outcome in `result.extra.economy`.
- **(v60t18a) Bless, Shadowheart → Astarion, no flags**: `StatusApplied(BLESS, 768)`,
  `economy.ap.ok` + `economy.slot.ok` (SpellSlot L1, before 1.0); snapshots
  **AP 1.0→0.0 AND L1 1.0→0.0**. Forced friendly casts are now fully honest.
- Earlier legs: v57t18a Guidance AP 1.0→0.0; v57t18b 0-AP clamp → AP-gate added.

## Addendum: use_osi_spell path leaks too (found + fixed 2026-09-19, v0.8.54 / PAK v061)

- **(v60u1) FireBolt via `use_osi_spell:true`, Astarion → goblin**: real cast
  (damage 9→5, story 769) but AP 1.0→1.0 — the direct `Osi.UseSpell` path bypasses
  native spend exactly like the forced queue.
- Fix (v0.8.54, commit `2cceb25`): pre-gates and `econDeduct` now cover both
  pipeline-bypassing paths (`forceFlags or useOsiSpell`); the plain honest queue
  still spends natively and is untouched.
- **(v61u2) FireBolt via `use_osi_spell:true`, Astarion → goblin_tracker_4 (6.6m)**:
  `economy.ap.ok`, **AP 1.0→0.0**, damage 9→2 HP. Direct path honest.
  (v61u1 at 24.3m correctly failed on range with no deduction — failed casts don't spend.)