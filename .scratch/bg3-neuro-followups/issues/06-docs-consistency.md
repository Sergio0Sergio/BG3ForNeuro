# 06 — Docs consistency: honest-economy claims vs reality

Type: follow-up (code-review)
Status: resolved
Blocked by:

## Findings (4 independent)

1. **Map over-claim.** `.scratch/bg3-neuro-honest-economy/map.md:32` — "All 5 map tickets (01-06) are resolved and executed" — but only 4 executed bullets follow, and 06 (movement cost) is not implemented (see followup 02). Fix the wording to "4 of 5 executed; 06 specified, backend pending".
2. **Stale `Ext.Mod.GetConfig` claims.** `map.md:26` (decision 03) "Storage: Config.json via `Ext.Mod.GetConfig`" and `issues/03-force-legacy-config.md:14` "requires introducing `Ext.Mod.GetConfig`" — the code (BG3Neuro.lua, ~line 239) and `BG3_Neuro_Spec.md` §6.4 use `Ext.IO.LoadFile(..., "data")` and state "Ext.Mod.GetConfig does not exist". Update both documents; spec §6.4 is already correct.
3. **Spec snapshot set.** `BG3_Neuro_Spec.md:536` lists "…SpellSlots/Cooldowns" in the snapshot set; actual `SNAPSHOT_RESOURCES` (BG3Neuro.lua:110) = {ActionPoint, BonusActionPoint, ReactionActionPoint, Movement, WeaponActionPoint} — cooldowns are captured separately as `out.cooldowns`. Correct the spec list.
4. **research/02 claims unimplemented snapshots** (`research/02-resource-snapshot-scheme.md`, lines ~59-64: "before … `executeMoveToTarget` / `bonus_action`", "after … written in `CharacterMoveToCancelled`") — none of these exist in code; mark them as planned/aspirational, aligned with followup 02.

## Fix proposal

One doc pass over the four files above; numbers/paths verified against the current source before writing.

## Answer

Doc pass done, all four findings fixed (no code/PAK changes needed — markdown only):

1. **map.md:32** → "4 of 5 map tickets (01-05) are resolved and **executed** on v0.8.25 (on the owner's command); 06 (movement cost) is specified, backend pending (see followup 02 in bg3-neuro-followups):".
2. **map.md:26** (decision 03) and **issues/03-force-legacy-config.md:14** → rewritten to the implemented reality: storage is `ScriptExtender/Config.json` read at startup via `Ext.IO.LoadFile("Mods/" .. MOD_NAME .. "/ScriptExtender/Config.json", "data")` + `Ext.Json.Parse`; notes `Ext.Mod.GetConfig` does not exist on this build (verified), no API introduced. Spec §6.4a was already correct — untouched. The historical grill question at `issues/03:24` (which mentions `Ext.Mod.GetConfig` as a question) stays as-is — it's a verbatim transcript of the dialogue.
3. **BG3_Neuro_Spec.md:536** → the snapshot set now reads `ActionPoint`/`BonusActionPoint`/`ReactionActionPoint`/`Movement`/`WeaponActionPoint` via `Osi.GetActionResourceValuePersonal(actor, name, 0)`; cooldowns captured separately under `out.cooldowns` (`SpellBookCooldowns` + `unwrapField`); explicit note that spell slots are **not** part of the snapshot (verified: `SNAPSHOT_RESOURCES` at BG3Neuro.lua:122; `readResourceSnapshot` puts cooldowns in `out.cooldowns`).
4. **research/02 §4** → marked the movement capture points (`before` in `executeMoveToTarget`, `after` via `EntityEvent`/`CharacterMoveToCancelled`) as **planned/aspirational, not implemented**, aligned with followup 02; documented the actually-existing snapshot call sites (`before`: executeCast 3003 / executeAttack 3392 / executeBonusAction 3585; `after`: finalizeCast 2837 / Osi.Attack fallback 3528).

Line numbers above verified against the current working tree (v0.8.28).