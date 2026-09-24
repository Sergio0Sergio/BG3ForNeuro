# 25 — Short Rest (`rest_type != "full"`) is a hollow ack — needs a real rest path

Type: feature
Status: done (bench passed, v0.8.64 / PAK v099)
Blocked by: PAK install requires a graceful game close (process rule); v099+ installed

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
     `executeRest` short branch → `Broadcast{kind="bg3neuro_rest_click"}` (fire-only, final — state),
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

## Bench result (2026-09-22, v0.8.64 / PAK v099, passed)

- `rest {"actor":"tav","rest_type":"partial"}` → client `executeShortRestViaDc()` finds the HUD widget
  `ls.UIWidget:HotBar` (DataContext `ui::DCWidget`, property `ShortRest`) and calls `cmd:Execute(nil)`.
  Server-side the rest-panel lives in `PopupPanels`/`WindowManager.Widgets` (outside MainCanvas),
  `Ext.UI.GetStateMachine()` is nil there, so click-by-button was impossible; the DC command is the
  real path (≡ `ShortRestItem` MenuItem / `ShortRestShortcut` hotkey in `HotBar.xaml:3633/3755`).
- Verified HP restore: wounded ally 9/17 → **17/17** after the action; client log
  `rest: ShortRest executed via DC ls.UIWidget:HotBar`.
- Earlier pitfall fixed during bench: `executeShortRestViaDc` referenced `topOfTree`/`propName` before
  their declaration → `attempt to call a nil value`; moved shared helpers (`uiTreeTop`, `uiPropName`)
  ahead of the function. Also `CrossplayOverlay` DC carries a ShortRest stub (CanExecute=true) selected
  before HotBar; priority now prefers node named/typed hotbar/rest → HotBar wins.
- PAK v099 MD5 installed: `9ef3baa8cc18aae8ace85679dbe22b38` (both ModuleShortDesc nodes).

## Acceptance

- [x] `rest {"rest_type":"partial"}` actually starts a short rest; the next state reflects it
  (HP restored), not just an ack.
- [x] No resting UI / not at camp → actionable error code, no phantom success (fallback keeps
  `openCampMenu`/`clickButton` for the resting-screen path).

## Cost

Client half + NetChannel already exist (dialogue-click). Main risk: resting screen node names /
availability outside camp. Live probing needs the game (stand rules; PAK install requires a graceful close).