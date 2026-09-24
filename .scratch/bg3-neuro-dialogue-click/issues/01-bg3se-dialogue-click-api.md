# 01 — BG3SE: how to programmatically select a dialogue option (server vs client)

Type: research
Status: resolved
Blocked by: —

## Question

Which BG3 Script Extender APIs and mechanisms allow **programmatically selecting a dialogue option**?

1. **Server context**: what facilities exist in BG3SE/osiris — functions `NRD_Dialog*`, `Ext.Dialog`, commands like `DialogSetAnswer` / `CharacterUserSetDialog` / `DialogGetNode` — and which of them actually "select" an option rather than only reading the dialogue tree. Is there a working server-only route (e.g., via an osiris callback on the selected node or a direct answer set).
2. **Client context**: the reality of `Ext.UI` on the client — the dialogue window UI element name, how to find an option by `option_index` (= order in the window), how to trigger a "click"/"selection" (Invoke / callbacks / button / `Ext.UI.GetByType`), limitations (client-only, local-coop session).
3. **Server↔client exchange**: are explicit OS bridges available in SE (`Ext.Net.PostMessageToServer` / `PostMessageToClient` or similar), how server-Lua passes a command to client-Lua, what happens in the two-process local-coop model (server and client — separate processes).
4. **Verdict fact**: is a client context mandatory for the click, or does a server route exist.

Primary sources: BG3SE documentation (wiki sections Ext.UI/Ext.Dialog/osiris functions), the Norbyte/bg3se repository (types/lua, ReleaseNotes), examples of mods using dialogue UI (OptionAutoselect-like). Facts, not opinions: a source for every claimed mechanism.

Result: the file `.scratch/bg3-neuro-dialogue-click/research/01-bg3se-dialogue-click-api.md`.

## Answer

**Verdict: a client context is mandatory — there is no server route for selecting an option.**

- `Ext.Dialog` does not exist; osiris has no `DialogSetAnswer`/`CharacterUserSetDialog`/`DialogGetNode*` — only lifecycle/variables (start/stop, add/remove actors, set vars). The server context is administrative.
- `Ext.UI` is **client-only**: `GetRoot()` → traversal of the Noesis tree (`Child`/`VisualChild`/`Find`) by `option_index`; the click — a button `:Execute()` / `Subscribe("Click")`, or input simulation `Ext.Input.InjectKeyPress`.
- The server↔client bridge — **NetChannel**: `Ext.Net.CreateChannel` + `SendToClient` / `RequestToClient(cb)` (legacy `PostMessageToClient`); in single-player the exchange is in-process, Lua states are isolated.
- Mandatory route: server → NetChannel → client-Lua → click. No client → fallback `not_supported` (X1).

Artifact: `.scratch/bg3-neuro-dialogue-click/research/01-bg3se-dialogue-click-api.md` (branch `research/bg3se-dialogue-click-api`, commit `739028c`). Context pointer: ticket 02 "Dialogue click route and the server↔client contract" — designed on top of these facts.