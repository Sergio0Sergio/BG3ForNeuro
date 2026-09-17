# 09 — Expose character abilities (weapon actions / bonus actions) to Neuro by friendly name

Type: task (state + router)
Status: implemented (bench-pending)
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

Even though the engine route works, Neuro could not discover or use such abilities:

1. **State listed engine UIDs only — correction to the earlier note.** `state.spells` is **not**
   empty in combat: `buildCombatSpellsBlock` already emits the caster's whole `preparedSpells`
   (18 entries for Tav, `Target_OpeningAttack` among them). But each entry carried only the raw
   engine `spell_name` (stat id) with no friendly name and no cost type (`slot` was `0` for every
   weapon action, since they have no `SpellSlotsGroup`). `available_actions` did not advertise
   `cast_spell` at all (only `end_turn` / `attack_entity` / `move_to_target`). So Neuro saw a raw
   UID but could not tell what it is or what it costs.
   (The earlier claim "`state.spells` is empty for a martial like Tav" came from an **exploration**
   capture — combat was not active — and is wrong.)
2. **`bonus_action` is hardcoded to `offhand_attack` only** (`BONUS_ACTIONS_V1`,
   `BG3Neuro.lua:3720`); any other `action_type` → `not_supported`. Flourish (a bonus action) is
   therefore unreachable through `bonus_action`.
3. **Engine UID vs friendly name.** The working route needs the internal id (`Target_OpeningAttack`);
   Neuro cannot be expected to know ids. There was no friendly-name → UID mapping.

## Implementation (v0.8.35, 2026-09-17)

1. **State — ability catalog.** Each `state.spells` entry now carries:
   - `name` — Neuro-readable name: `slug` of the localized name (`Ext.Stats.Get(id).DisplayName` →
     `Ext.Loca.GetTranslatedString`), with a curated fallback table (`ABILITY_NAME_FALLBACK`,
     e.g. `Target_OpeningAttack → flourish`) and, last, a derived slug (`Target_OpeningAttack →
     opening_attack`). So `flourish`, `piercing_thrust`, `hamstring_shot`, `second_wind`, … appear
     instead of raw ids (localization is the primary source, the table is a safety net).
   - `cost` — `action` / `bonus_action` / `reaction` / `free`, derived from the stat's `UseCosts`
     (`ReactionActionPoint`/`BonusActionPoint` checked before `ActionPoint`, which they contain as a
     substring). This answers the open cost-type question without `Osi` helpers.
   - `available_actions` now advertises `cast_spell: [<names>]`.
   (`BG3Neuro.lua`: `abilityDisplayName`, `abilityCostOf`, `preparedSpellStatId`,
   `resolveAbilityStatName`; `buildCombatSpellsBlock`; `captureCombatState`.)
2. **Router — friendly names.** `ActionRouter.ValidateCast` (C#) accepts `spell_name` matching either
   `SpellInfo.SpellName` (engine id) or `SpellInfo.Name` (friendly); on a friendly match it rewrites
   the payload `spell_name` to the engine id before writing `action_*.json`, so the mod contract stays
   on engine ids. The Lua `executeCast` also resolves friendly names defensively
   (`resolveAbilityStatName`), covering direct injects.
3. **`cast_spell` is the working path for bonus-action abilities** (proven for Flourish: BA 1.0 → 0.0
   natively). `bonus_action` stays offhand-only for now (its own gate/ticket); it is not needed to
   reach Flourish.

Tests (pure, no game): `StateSerializerTests` (catalog parse + rendering
`- flourish (Target_OpeningAttack): cost bonus_action, range 1.5m`) and `ActionRouterTests`
(friendly → engine rewrite; engine id passthrough; unknown name lists friendly names). 94/94 green in
the `State` namespace; the solution builds clean. PAK v041 built
(`Mods/BG3Neuro/…`, MD5 `3C1274B11D48EB97F3588CAED8E72CFD`) — **not installed** (game running).

## Bench assertion (pending)

With a scimitar/shortsword/rapier in the main hand, `state.spells` must contain
`{"name":"flourish","spell_name":"Target_OpeningAttack","cost":"bonus_action"}`, `available_actions`
must list `cast_spell: [… flourish …]`, and one `cast_spell {"spell_name":"flourish", …}` must spend
exactly one BA and apply Off Balance (same result as the raw-id inject).

## Evidence

- `docs/manual-regression-checklist.md` — Run 2026-09-17 (v0.8.34).
- Live `cast_flourish2` snapshots + `result_cast_flourish2.json` in the IPC dir, 2026-09-17.
- `cast_debug.json` (Tav `preparedSpells` includes `Target_OpeningAttack`).
