# 25 — Short Rest (`rest_type != "full"`) is a hollow ack — needs a real rest path

Type: feature
Status: in-progress (implementation done, awaiting live bench)
Blocked by: game restart for PAK v096 install

## Finding

`executeRest` (`BG3Neuro.lua:5245-5266`): `Osi.RequestLongRest(actor, 0)` covers **full** rest only;
any other `rest_type` returned `true, true` — **successful ack with NO rest performed**.

Short rest has **no public Osiris/SE function** (story-side only) — same class of gap as dialogue click
was: the action is only reachable through the **client UI** ("Take Short Rest" button, resting screen).

## Research (2026-09-21, static)

- Curated `osi_signatures.txt` (983 lines, bg3se dump): rest-family = `CanAllPartiesLongRest`,
  `RequestLongRest*`, `FindGossipCamp`, `RequestGatherAtCamp`, `SetShortRestAvailable`,
  `SetStoryShortRestEnabled/Disabled`, `SetCampQuality`, `EnableCampWaypoint`, `SendToCamp*`.
  **No `RequestShortRest`/`OpenCamp`/`OpenShortRest`** — a server-side trigger does not exist.
- bg3se ECS has `EsvRestShortRestSystem`, `EocRestShortRestComponent`,
  `EsvRestShortRestConsumeResourcesComponent`, `EsvRestShortRestResultEventOneFrameComponent`,
  `StatsShortRestFunctor`, `NETMSG_SHORT_REST`, `StoryShortRestState`/`UpdateShortRestState`
  (`GameDefinitions\Components\ServerData.h` L328/385-386), `ShortRestPoint` ActionResource
  (`a24ca5e2-01e1-48fd-a4c8-79b8817f0a18`) — but **no high-level Ext trigger**.
- Story scripts (`gustav-goals`) only react to the **internal** `ShortRested(...)` event /
  endless-day tutorial DB rows; `ShortRested` is not in the Osi signature dump → not callable.
- **Conclusion:** the resting screen must be opened + clicked on the **client**, mirroring the
  proven dialogue-click route (server → NetChannel → `BG3NeuroClient.lua` → `Ext.UI` + `ICommand:Execute`).

## Plan

1. **Research (static)** — done: no server initiator exists; client-UI route is the only path.
2. **Implementation (v0.8.64, PAK v096)** — done:
   - server: global `BG3NEURO_REST` module (main chunk at the 200-local limit → **no top-level locals**),
     channel `BG3NeuroRest`, click-result handler with retry on `retry:*` reasons,
     `executeRest` short branch → `Broadcast{kind="bg3neuro_rest_click"}` (fire-only, финал — state),
     bench action `rest_probe` (BroadcastMessage request → client UI scan → `result_<id>.json`);
   - client: `bg3neuro_rest_click` + `bg3neuro_rest_probe` handlers, `scanUiButtons()`
     (all Button/Cmd roots, text + first child text), `openCampMenu()` (open by hint-matched
     button, retry-able), `clickButton()` (Command:Execute, CommandParameter > DataContext > el);
   - verified: `luaparse` OK on both files, active-local max **200/200** (equal to HEAD).
3. **Live bench (needs game restart for PAK v096):** `rest_probe` → read UI scan (state machine
   State, roots, buttons) → tune open/click selectors if needed → `rest {"rest_type":"short"}`
   → verify the rest actually starts and the next state reflects it (ShortRestPoint/HP via forced
   `state_capture`). Fallback if no UI reachable: honest error (like dialogue `not_supported`),
   never a hollow `success`.
4. **Contract:** `rest` documents the short-rest outcome; C# validator `CanAllPartiesLongRest`
   stays for full rest.

## Acceptance

- `rest {"rest_type":"partial"}` (enums: `["full","partial"]`) actually starts a short rest; the next
  state reflects it (rest in progress → finished), not just an ack.
- No resting UI / not at camp → actionable error code, no phantom success.

## Cost

Client half + NetChannel already exist (dialogue-click). Main risk: resting screen node names /
availability outside camp. Live probing needs the game (stand rules; PAK install requires a graceful close).