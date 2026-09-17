# 01 — end_turn does not advance when the active turn is shared by several characters

Type: task (live bench)
Status: resolved (code) / bench-pending (install + verify)
Blocked by: game restart (PAK reinstall)

## Symptom

2026-09-17 combat run (PAK v0.8.33, SE v32, direct IPC). `end_turn` for `origin_astarion`
never advanced the turn:

- `et1`/`et2` → `success:false, error_code: action_failed, error_detail: "Turn did not change within the deadline (30 s)"`, `ended:false`
- `et3` (clean GUID) → `ended:false`
- `et4` (`mode=system`, clean GUID) → `write_error: "entity not found"`
- `et5` (`mode=system`, prefixed id) → `combat_handle:"nil"`, `queue_push:true`, `queue_before:0 → queue_after:1`, `ended:false`
- `turn_actor` stayed `origin_astarion` for ~13 min; game responsive (fresh heartbeat), no Lua errors in the SE log.

## Root cause

In BG3 a single **active turn** can belong to several allies that share an initiative slot.
The engine ends that turn only once `TurnBased.RequestedEndTurn` is set on **all** co-active
characters. The mod set the flag (and pushed the queue entry) only for the single `acting`
actor, so the engine kept waiting and `TurnEnded` never fired.

The state could not show this: `acting now` is computed only for `turn_actor`
(`BG3Neuro.lua:1669`), so the other co-active characters looked like plain `can act`.

**Live proof:** while Astarion was stuck, `end_turn {"actor":"tav"}` → `ended:true`,
`acting_after = S_DEN_GoblinRaider_Captain_22d80f21-…`, `turn_actor` moved on. This matches the
Command Console mod's `!sailor_endturn` — "ends the turn for all creatures on the active turn".

Note: on the 2026-09-16 run `end_turn` passed for all 4 members because their initiatives were
separate (one actor per turn); the bug only appears when a turn is shared.

Unrelated, ruled out: `Ext.Entity.UuidToHandle(TurnBased.CombatTeam)` returns `nil` for the
player's own combat (hence `combat_handle:"nil"` in `et5`), but the fallback scan over
`CombatState.Participants` works (`stats_probe` returned 12 guids incl. Astarion), so a valid
handle was always pushed. The blocker was the per-character flag, not the handle.

## Fix (v0.8.34)

`requestEngineEndTurn` now also sets `RequestedEndTurn=true` on **every** entity with
`TurnBased.IsActiveCombatTurn == true` — new helper `activeTurnEntities()` (scan
`Ext.Entity.GetAllEntitiesWithComponent("TurnBased")` + `fieldOf(tb, "IsActiveCombatTurn")`).
The combat-handle queue push is unchanged (once). Files:
`mod/BG3Neuro/BG3Neuro.lua`, `mod/BG3Neuro/BG3NeuroClient.lua` (version bump 0.8.33 → 0.8.34).

## Answer

Implemented + luaparse-OK (5.3) + PAK built (v040, `Mods/BG3Neuro/…`, MD5
`84FCF350CDC770BE135BA4944BC351AB`). Install + live verify (single-actor `end_turn` must advance
the turn) pending game restart — PAK is locked while bg3 runs.
