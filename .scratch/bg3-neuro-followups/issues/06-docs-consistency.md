# 06 — Docs consistency: honest-economy claims vs reality

Type: follow-up (code-review)
Status: open
Blocked by:

## Findings (4 independent)

1. **Map over-claim.** `.scratch/bg3-neuro-honest-economy/map.md:32` — "All 5 map tickets (01-06) are resolved and executed" — but only 4 executed bullets follow, and 06 (movement cost) is not implemented (see followup 02). Fix the wording to "4 of 5 executed; 06 specified, backend pending".
2. **Stale `Ext.Mod.GetConfig` claims.** `map.md:26` (decision 03) "Storage: Config.json via `Ext.Mod.GetConfig`" and `issues/03-force-legacy-config.md:14` "requires introducing `Ext.Mod.GetConfig`" — the code (BG3Neuro.lua, ~line 239) and `BG3_Neuro_Spec.md` §6.4 use `Ext.IO.LoadFile(..., "data")` and state "Ext.Mod.GetConfig does not exist". Update both documents; spec §6.4 is already correct.
3. **Spec snapshot set.** `BG3_Neuro_Spec.md:536` lists "…SpellSlots/Cooldowns" in the snapshot set; actual `SNAPSHOT_RESOURCES` (BG3Neuro.lua:110) = {ActionPoint, BonusActionPoint, ReactionActionPoint, Movement, WeaponActionPoint} — cooldowns are captured separately as `out.cooldowns`. Correct the spec list.
4. **research/02 claims unimplemented snapshots** (`research/02-resource-snapshot-scheme.md`, lines ~59-64: "before … `executeMoveToTarget` / `bonus_action`", "after … written in `CharacterMoveToCancelled`") — none of these exist in code; mark them as planned/aspirational, aligned with followup 02.

## Fix proposal

One doc pass over the four files above; numbers/paths verified against the current source before writing.