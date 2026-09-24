# 02 — Dialogue click route and the server↔client contract

Type: grilling
Status: resolved
Blocked by: 01

## Question

Based on the facts from ticket 01 "BG3SE: how to programmatically select a dialogue option (server vs client)": choose the click route and design the contract.

- **Route**: server-only, if 01 showed a working server-side approach; otherwise — the client-side `ClientAutoselectExecutor` (client Lua finds the element by `option_index`, highlights and clicks it).
- **Contract**: how the "select option N" command flows C# → server-Lua → (client-Lua) → UI; how `option_index` (order in the window) maps to an element; what confirms success (result reply vs next state); behavior when no client is present (fallback X1: `not_supported` + warning) and when leaving a dialogue/trade.
- **Timings/idempotency**: the click must not be re-raised by subsequent explore/combat ticks; the "dialogue open" state is read from `bg3_to_neuro.json`.

Domain terms are refined here as well (domain-modeling): "option_index", "client context (Client)", "cross-OS message" — recorded in `CONTEXT.md` if needed.

## Answer

Solutions (grilling round, user answers):

- **Q1 (route/mode) = (a)**: only auto-click on the client context. The human presses nothing; we don't do the "confirm with a key" mode (we'll add it if needed).
- **Q2 (how the button is found) = (b)**: the client receives `option_index` **and** `option_text`. Primary search is by `option_index` (= the button's order in the dialogue window); on failure/numbering mismatch — a fallback by the option text.
- **Q3 (how we learn the result) = (a)**: we trust the next state. The click is sent fire-only, without acknowledgment back; success is visible in the dialogue's new state (a different line). No separate confirmation loop is introduced.
- **Q4 (what on failure) = (a)**: an honest `not_supported` + warning — "Neuro never stays without a channel" (X1). No client / dialogue closed / trading — we don't stay silent, we reply with an error code.

**Final route**: C# → action file (`select_dialogue_option`) → server-Lua → **NetChannel** message (`Ext.Net.CreateChannel` + `SendToClient`, payload = `option_index` + `option_text`) → client-Lua (`Ext.UI`: traversal of the dialogue window's Noesis tree, index search, text fallback, click `:Execute()`/`Subscribe("Click")`) → the game advances the line → next `bg3_to_neuro.json` (dialogue state).
Idempotency: the click is bound to the current line (voting in the server Lua — a repeated tick doesn't re-click); a stale click on an already closed dialogue → `not_supported` + warning.

Domain terms: `option_index`, client context, cross-OS message — recorded in `CONTEXT.md`.

Context pointer: map.md "Decisions so far" — the ticket 02 entry; the route is ready for implementation (off-map).