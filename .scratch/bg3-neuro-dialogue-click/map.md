# bg3-neuro-dialogue-click — Wayfinder Map

## Destination

Fully green §9.5: dialogue option selection works **end-to-end** (state → Neuro decision → a real click on the option), not just "the dialogue is visible". The client-side scope is **dialogue click only** (minimum). The server loop remains the primary one; the client context is added only if there is no server-side way to click the dialogue. The other §9.5 sections (spells / exploration / loot / rest / travel_to) are already green or will turn green via parallel implementation off-map.

## Notes

- Domain: the BG3×Neuro mod (Lua emitter + C# router). Tracker: local-markdown `.scratch/bg3-neuro-dialogue-click/` (`docs/agents/issue-tracker.md`).
- The "dumb-mod" preamble (only state extraction / action execution) — the main loop; the client piece for the dialogue's sake — a deliberate exception (Q1=b), scope — click only (Q2=1).
- The previous spec (`.scratch/bg3-neuro-integration`, ticket 07, X1) already designed `ClientAutoselectExecutor`: client Lua finds the element by `option_index` (= order in the UI window), highlights and clicks it; no client available → `not_supported` + warning ("Neuro never stays without a channel"). Then — a post-v1 experiment; now — in scope.
- Tickets: 01 = research (AFK), 02 = grilling (HITL, blocked by 01). Skills: grilling + domain-modeling (decision tickets), research (01), prototype — when "how it should look" is unclear.
- **Off-map** (simple implementation against a known spec, not a decision; done in parallel): `use_item` (healing potion) + reading `on_cooldown` in `bg3_to_neuro.json`.
- Starting state: v0.8.26 committed (master `7a3bc46`), PAK v032 installed; dialg-options empty (`TODO(client)`), `executeDialogueOption` → `not_supported`.

## Decisions so far

- [BG3SE: how to programmatically select a dialogue option (server vs client)](issues/01-bg3se-dialogue-click-api.md): a client context is mandatory — there is no server route. `Ext.Dialog` is absent, osiris has only administrative lifecycle functions; `Ext.UI` is client-only (traversal of the Noesis tree by `option_index`, click `:Execute()`/`Subscribe("Click")`); server↔client — NetChannel (`Ext.Net.CreateChannel` + `SendToClient`/`RequestToClient`). No client → fallback `not_supported` (X1). Ticket 02 is designed on top of these facts.
- [Dialogue click route and the server↔client contract](issues/02-dialogue-click-route.md): only auto-click on the client context (Q1=a). The client finds the button by `option_index`, on failure — by `option_text` (Q2=b). Success — by the dialogue's next state, without a confirmation loop (Q3=a). No client/dialogue closed/trading → `not_supported` + warning (Q4=a). Route: C# → action file → server-Lua → NetChannel (`option_index`+`option_text`) → client-Lua (`Ext.UI` search+click) → next state.

**Map status: destination reached.** Both tickets are resolved; the click route is locked in (the options from the Fog section below became the implementation). Next — implementation off-map (dialogue click + in parallel the `use_item` potion/`on_cooldown`), per the rule "wayfinder decides, doesn't build".

## Not yet specified

- How to pack/load the client context (a second Lua script in the same PAK? ScriptExtender config, a session client hook) — will become clear after 02, if the client turns out to be needed.
- Which exact §9.5-dialogue items are declared green with a working click ("Simple choice → line changed in next state", etc.) — will be refined along with the route.
- Bench infrastructure for a live click (whether a full client + measurements are needed instead of server simulation).

## Out of scope

- Client part beyond "dialogue click": showing state/effects/screens in the UI (Q2=(1)).
- Trading, stealth, camera, voice, multiplayer — carried over from the previous map (`.scratch/bg3-neuro-integration`).
- Dialogue outside the mod: if the client is impossible and the server route is dead — the decision is revisited at 02 (fallback X1: `not_supported` + warning remains the primary honest behavior).