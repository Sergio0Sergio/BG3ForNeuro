# 09 — Expose character abilities (weapon actions / bonus actions) to Neuro by friendly name

Type: task (state + router)
Status: ready-for-agent
Blocked by: —

## Finding (live bench 2026-09-17, PAK v0.8.34)

Many useful abilities are **weapon actions**, not spells, and the current interface hides them from
Neuro. Concrete example — **Flourish**:

- bg3.wiki: Flourish is a weapon action for rapier/scimitar/shortsword in the **main hand**, costs a
  **Bonus Action**, applies *Off Balance*; technical UID `Target_OpeningAttack`.
- Tav's `preparedSpells` (in `cast_debug.json`) contains `Target_OpeningAttack` (SourceType `Boost`).
- It is **castable through the existing pipeline**: `cast_spell {"actor":"tav",
  "spell_name":"Target_OpeningAttack","target_id":"goblin_tracker_1"}` → `success:true`;
  `resource_snapshot_cast_flourish2_before/after.json` show **BonusActionPoint 1.0 → 0.0** (engine
  spends the BA natively), AP/Movement unchanged.

Note: the router data key for the cast is **`spell_name`** (not `spell`; `spell` yields
`action_failed "spell_name is required"`).

## Gap

Even though the engine route works, Neuro cannot discover or use such abilities:

1. **No ability catalog in the state.** `available_actions` lists only `end_turn` /
   `attack_entity` / `move_to_target`; `state.spells` is empty for a martial like Tav. Neuro has no
   way to learn that Flourish exists, what it costs, or its targeting rules.
2. **`bonus_action` is hardcoded to `offhand_attack` only** (`BONUS_ACTIONS_V1`,
   `BG3Neuro.lua:3720`); any other `action_type` → `not_supported`. Flourish (a bonus action) is
   therefore unreachable through `bonus_action`.
3. **Engine UID vs friendly name.** The working route needs the internal id (`Target_OpeningAttack`);
   Neuro cannot be expected to know ids. There is no friendly-name → UID mapping.

## Fix direction

1. **State** — emit an abilities list for the acting character, each entry with a Neuro-readable
   name plus what it needs to decide: e.g.
   `{ "name":"flourish", "engine_id":"Target_OpeningAttack", "cost":"bonus_action",
      "uses":<n>, "target":"enemy", "range":"weapon" }`.
   Source candidates: `preparedSpells` (SourceType `Boost`/`WeaponSpell`) + resource costs /
   `Osi.HasSpell`. Open question to verify: a reliable way to derive the **cost type**
   (Action vs Bonus vs Reaction) per entry — `GetActionResourceValuePersonal` gives the pool, not
   the per-ability cost; may need the stat's `UseCosts`/`SpellCost` or `Osi` helpers.
2. **Router** — accept friendly names in `bonus_action` (and/or `cast_spell`) and map them to engine
   ids (table like `flourish → Target_OpeningAttack`, `offhand_attack → OffhandAttack`), so the
   contract doesn't leak internal ids. Keep `offhand_attack`'s off-hand-weapon gate.
3. Bench assertion: with a scimitar/shortsword/rapier in the main hand, a single `bonus_action`
   (or `cast_spell`) with the friendly name `flourish` spends exactly one BA and applies Off Balance.

## Evidence

- `docs/manual-regression-checklist.md` — Run 2026-09-17 (v0.8.34).
- Live `cast_flourish2` snapshots + `result_cast_flourish2.json` in the IPC dir, 2026-09-17.
- `cast_debug.json` (Tav `preparedSpells` includes `Target_OpeningAttack`).
