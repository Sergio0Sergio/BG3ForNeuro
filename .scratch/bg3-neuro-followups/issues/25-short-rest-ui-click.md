# 25 — Short Rest (`rest_type != "full"`) is a hollow ack — needs a real rest path

Type: feature
Status: needs-triage
Blocked by: —

## Finding

`executeRest` (`BG3Neuro.lua:5245-5266`): `Osi.RequestLongRest(actor, 0)` covers **full** rest only;
any other `rest_type` returns `true, true` — **successful ack with NO rest performed**:

```lua
if data.rest_type ~= "full" then
    -- TODO(client): лёгкий отдых — UI-кнопка Take Short Rest; структурный ack, финал — state.
    return true, true, nil, nil
end
```

Short rest has **no public Osiris/SE function** (story-side only) — same class of gap as dialogue click
was: the action is only reachable through the **client UI** ("Take Short Rest" button, resting screen).

## Plan

1. **Research (bench, exploration + a camp ready for rest):**
   - does the resting screen appear without a camp (exploration short rest at the gate)?
   - Noesis tree of the resting window — find the "Take Short Rest" button node (index/text fallback),
     mirroring the proven dialogue-click route (`bg3-neuro-dialogue-click`, `select_dialogue_option`:
     server → NetChannel → `BG3NeuroClient.lua` → `Ext.UI` traverse + click).
   - confirm completion signal: resting ends → next `bg3_to_neuro.json` (Camp/`RestFinished`-like state change).
2. **Route (if research ok):** `executeRest` for `rest_type ~= "full"` sends a client-side "click Take
   Short Rest" over the existing `Ext.Net` channel; result validation = state transition (no ack-only).
   Fallback if no UI reachable: honest error (like dialogue `not_supported`), never a hollow `success`.
3. **Contract:** `rest` gains a documented short-rest outcome; C# validator `CanAllPartiesLongRest`
   stays for full rest; check App-side `rest_type` docs (`docs` + spec §resh not modified yet).

## Acceptance

- `rest {"rest_type":"short"}` actually starts a short rest; the next state reflects it (rest in
  progress → finished), not just an ack.
- No resting UI / not at camp → actionable error code, no phantom success.

## Cost

Client half + NetChannel already exist (dialogue-click). Main risk: resting screen node names /
availability outside camp. Blocked on a game stand (needs game; same stand rules as 24).