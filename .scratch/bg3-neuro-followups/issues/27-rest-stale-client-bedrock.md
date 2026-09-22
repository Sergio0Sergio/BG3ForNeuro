# 27 — `rest` click fires but HP never recovers on a beaten party (stale client v0.8.63 on v110)

Type: bug
Status: needs-triage
Blocked by: needs a live stand with a beaten party + a fresh client; may depend on daily short-rest cap

## Finding

On PAK **v110** (server v0.8.68, but the *shipped client* was still `_G["BG3Neuro_VERSION"]=0.8.63`
— the version export was stale, see the v0.8.68 cleanup) the `rest` action **clicked but never healed**:

- Party was beaten after combat (~tav 12/28, astarion 9/24, cleric 7/24, wizard 4/20).
- Inject `rest {"actor":"tav","partial":true}` (id `v68_r2`) → result `success=true running=true`
  **stuck** (no final `running:false` ever written), HP unchanged across repeated `state_capture`.
- Client log claims the click landed: `[BG3NeuroClient] rest: ShortRest executed via DC ls.UIWidget:HotBar`,
  then `[BG3Neuro] rest: click fired (action=v68_r2, ver=...)`.
- Screen stayed `exploration`; user reported "a **combat log** opened" instead of the rest panel.

## Timeline (2026-09-22, live stand)

1. v109/v110 was installed over a running game session (violating the process rule briefly during a
   rebuild?) — actually no: v110 was installed with game **closed**. But the v110 *client file* carried
   the stale `0.8.63` version export (server was already `0.8.68`).
2. Regression on v110: `travel_to` worked both ways (Chapel ⇄ Underdark), `rest` **did not heal**.
3. Built v111 with the *fixed* client export (`0.8.68`), installed with game closed, MD5 updated in both
   modsettings nodes.
4. Fresh session on a new save: `v0.8.68 loaded (client)` + `v0.8.68 loaded (server)`; the same
   `rest {"actor":"tav","partial":true}` healed the cleric **9/17 → 17/17** on the first try.

## Hypotheses (untested)

- **H1 — daily short-rest cap drained:** the v110 session had already short-rested earlier that game-day
  (v0.8.67 regression bench healed cleric 9/17→17/17). BG3 allows one short rest per camp night; a
  second click is a no-op that opens/derives a panel — the click "landed" but the engine refused to rest.
  The v111 session is a **new save/day**, so the cap was available → heal worked. This is currently the
  most probable cause and is **not a code bug at all**.
- **H2 — stale client version artifact:** v110's client had `_G["BG3Neuro_VERSION"]=0.8.63`, but the rest
  bridge code itself was unchanged; the stale export is cosmetic. Weak cause.
- **H3 — interaction with the stuck combat flag (ticket 26 side-effect):** the v110 session had hit a
  stuck `TurnBasedComponent` after a mid-combat teleport, cleared later by Load Game. If rest was
  attempted near that, the engine may refuse healing while combat participation lingers. Medium plausibility.

## What distinguishes the hypotheses

A single bench on the current v111 save can falsify H1 vs H3:
- If rest now works twice in a row on the **same day**, H1 is wrong.
- If the second rest on the same day is a silent no-op (click fires, HP flat, `running` hangs),
  **H1 is confirmed** — and the real bug/limitation is that the mod does not report "no short rests left
  today": it should return an honest `action_failed`/`not_supported` instead of `success=true running=true`.

## Implicit defect discovered (independent of the cause)

Even if H1 is the root cause, the mod's behaviour is wrong: a refused rest must never linger in
`running=true` forever. `executeRest` (`BG3Neuro.lua:5382`) returns fire-only on the click path, and the
final is only ever written by `LongRestFinished/Cancelled/StartFailed` (`finalizeRest`) — a refused
*short* rest has **no Osiris event** to finalize it, so `running` hangs indefinitely. Either
(a) a timeout fires an honest failure, or (b) the client sends back `ok=false` when the click cannot
begin a rest (already partially there via `retry:`), or (c) the server detects the same-day cap and
completes immediately with an actionable error.

## Next steps

1. On the live v111 stand: trigger `rest` twice on the **same game day**; observe HP + `running`.
2. If second rest no-ops → confirm H1; decide the honest-response fix (timeout / ok=false / cap check).
3. Re-check whether the stale `0.8.63`-shipped v110 changes anything (H2) — probably can be closed as
   cosmetic only.

## Acceptance

- `rest` always terminates: either real HP recovery (next state shows healed party) or an honest
  `success:false` with an English `error_detail` explaining why (e.g. "No short rests left today").
- No `running=true` that never finalizes.