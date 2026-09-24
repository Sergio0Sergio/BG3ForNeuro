# 01 — BG3 multiplayer model: what the engine exposes in a co-op session

Type: research
Status: resolved (2026-09-23)
Sprint: bg3-neuro-multi-agent
Opened: 2026-09-23

## Question

Can a BG3 session hold two human players AND two Neuro-driven characters at once, with each Neuro seeing only "its own" character's frame? What does the engine expose per player in such a session:

- Host/guest process model: is one `bg3.exe` handling both Neuro characters (local co-op, `controlledPartySize`-style) or do we need two processes (one per Neuro)? Current mod is two-half (server Lua + client Lua via `BootstrapClient.lua`); what breaks when a *third* actor (human) is mixed in?
- How are "players" identified at runtime: `EocPlayer` / reserved user ids (`{1,2,3,4,0,256,65536}` in `currentCharacters()`, `BG3Neuro.lua:642-654`) — do human players occupy distinct ids from our controlled set? Can the mod tell "this id is a human, this id is Neuro's character"?
- Turn semantics per player: `TurnStarted`/`TurnEnded` — do they fire per-entity with the player's identity, or per-team? Current `actingChar` is one global latch (`BG3Neuro.lua:450, 505-517`); what does the engine say when TWO party members are in the same shared-turn window (`CanActInCombat`, `activeTurnEntities`)?
- `Osi.IsEnemy`/`IsAlly(partyRef, g)` (`CONTEXT.md` hostility truth) — is `partyRef` still resolvable when the "party" is split between a human and Neuro's character?
- Client context (`BootstrapClient.lua` — dialogue click, waypoint UI, rest HotBar click): is one client context per PROCESS or per player? Would a second Neuro character need its own client context in the same process?

## Context

All followups 01–28 resolved; this sprint asks whether the architecture's single-agent assumption (`Program.cs:46-54`, one WS client, one `actingChar` latch, one-file bridge) can grow to two agents. This ticket grounds the question in what BG3/BG3SE actually expose. See sprint `map.md` for the baseline.

## Sources to check

- BG3SE Osi symbol dump (`.scratch/bg3-neuro-followups/research/08-enemies-hostility-relation-api.md` §Sources) — `Osi.GetCurrentCharacter`, reserved user ids, `EocPlayer`.
- `mod/BG3Neuro/BG3Neuro.lua` `currentCharacters()` (`:642`), `resolveActingCharacter` (`:771`), `CanActInCombat`/`activeTurnEntities` (`:1821`, `:4611`).
- `neuro-sdk/API/SPECIFICATION.md` — startup/session `{sessionId, characterId, displayName}`; VOICE_CHAT.md mentions "each game process connects on behalf of its own character in a local/co-op session" — the only multiplayer-ish statement found.
- `.scratch/bg3-neuro-dialogue-click/` research — local co-op = two processes (server + client).

## Deliverable

A table "engine fact → what a 2-Neuro setup needs → feasible/blocked", plus a verdict on which process model (one process two characters vs two processes) is viable without engine internals.

## Answer

**Verdict: one host process holds both Neuro agents. Two game processes are NOT needed and solve nothing.** Both Neuro characters are ordinary party members of the same party; the host's server-Lua sees and controls all party entities regardless of whether a human or a Neuro sits behind the avatar. All actions go through the already-existing server-side API. The real blockers for two independent agents are not the engine but our communication/state layer (tickets 02, 03).

| Engine fact (source) | What is needed for 2 Neuro + N humans | Feasible |
| --- | --- | --- |
| **Host = the only server context.** Server-Lua lives in the host process; it manages ALL party entities (moves them, casts, reads TurnBased) — that is the current mod. Guests (client-half) have no server worlds of their own (they have no `Osi`). | Both Neuro halves (both "own" characters) are visible and controllable from the host's server Lua — just as one character is controlled today. | ✅ feasible (already true for 1 Neuro; client-half stays a pure UI executor, see below) |
| **Two-process model — only local co-op / guest machines.** local co-op (split-screen) = 2 processes on one machine (server+client), network guests = separate client processes. None of them yields a second server world. | A second process would give a second server-Lua, but it does NOT see the host's scene in full and cannot duplicate it — it would only add a second UI context. | ❌ blocked — the game process does not scale with the number of Neuro agents |
| **`EocPlayer`/reserved user ids: `Osi.GetCurrentCharacter(user)`, `GetReservedUserID(character)`, `AssignToUser(userID, character)`, `GetUserProfileID(userId)`, `GetUserName(userId)`.** `currentCharacters()` (`BG3Neuro.lua:642-654`) iterates over `{1,2,3,4,0,256,65536}`. | For 2 Neuro agents there is no need to reserve additional real clients: each Neuro character is just a party member. It may or may not get its own reserved user id — the engine doesn't care, the mod works by guid. | ✅ feasible (reservable ids don't have to "interfere" with anyone — but we don't need them anyway) |
| **Distinguishing "human vs Neuro":** there is `IsPlayer(character)`, and distinguishing *direct* control is provided by **`ClientControlComponent`** (a marker meaning "this character is currently driven by a client-human") + `UserReservedForComponent.UserID` — exactly like Brawl in `brawl_State.lua:497-528` (`Ext.Entity.GetAllEntitiesWithComponent("ClientControl")` → `entity.UserReservedFor.UserID`). | Rule: power/actions belong to server Lua; the human owns `ClientControl` (UI clicks), Neuro — all the rest of the time. The mod can distinguish: a Neuro character has no ClientControl → the mod executes its actions. | ✅ feasible (the engine doesn't know "neuro", but the mod itself marks its characters via `agent→character` — ticket 03) |
| **Turn semantics per entity, not per player:** `TurnStarted`/`TurnEnded` fire with the guid of the **entity**, not the user. The `TurnBased` component (`IsActiveCombatTurn`, `CanActInCombat`) is per-entity (`BG3Neuro.lua:895-899`); shared-turn already works via `activeTurnEntities()` (`:1821`) + `requestEngineEndTurn` advances the turn for all co-active entities (`:1850-1858`). | The `actingChar` latch (`:450,505-517`) is single global — but two Neuro characters in a shared window are seen by the engine as two `IsActiveCombatTurn` members; which agent drives which guid we'll move to a per-agent "owned character" (ticket 03), without breaking the turn mechanics. | ✅ feasible (the engine doesn't impose "one actor", the imposition is ours) |
| **Hostility (`IsEnemy`/`IsAlly`) — about a guid pair, not containers:** `partyRefs` = any plain party guids (`BG3Neuro.lua:2444-2457`), truth is determined by the entity pair (avoid an enemy container). `_G` per character is not tied to an agent. | For the second Neuro you just need its own `partyRef` (its party guid) — the same formula, no new engine knowledge. | ✅ feasible |
| **Client context — one per process:** `Ext.UI`, the dialogue click, the rest button live in the client-Lua of one process (host). A second process (guest/local co-op) would give a second UI context, but dialogues/rest are globally one per scene. | 2 Neuro agents in one host process share ONE client context: the dialogue/rest click goes through it. Multiple simultaneous client clicks are impossible and unneeded (there is one dialogue). | ✅ feasible (serialized in ticket 02; the client stays shared, "one per process") |
| **`GetMultiplayerCharacter(character)`, `CombatGetInvolvedPlayer(c, idx)`** — the engine knows the "co-op" character and "humans in combat by index". | Not required; they could help validate "which humans are in the fight" — but the mod already reads everything via the entity API. | ✅ feasible (not required) |

### Ticket conclusions

1. **Game process: one (`host`), client-half one per the same process.** "Two Neuro agents" does not mean "two game processes". The two-process model (local co-op / network guests) provides no second server world and is not needed.
2. **The two "agent slots" — communication, not engine.** The SDK has `characterId` (`neuro`/`evil`, `SPECIFICATION.md:215`) — the native marker for the two twins; the app can open two WS connections (two `NeuroWebSocketClient`) and get its own `session.characterId` from each (`NeuroWebSocketClient.cs:246-254`) — that is "agent #1 / agent #2" (ticket 02).
3. **The turn engine and hostility are identical for humans and Neuro** — both "who owns whom" axes are decided on our side (ticket 03), not by the engine.
4. **The only resource shared per process** — the client context (UI clicks: dialogue/rest/waypoint). It is serialized, like the file bridge (ticket 02).

**Left open for ticket 02**: action authorization by `agent_id` (two WS = two `characterId`), delivery of actions/results through the single-slot file bridge (queue/per-agent files), serialization of client clicks.
**Left open for ticket 03**: `agent → character` mapping, per-agent `actingPos`/`distance_reference`, per-agent turn frame in the common shared window.

Fact artifacts: `.scratch/bg3-neuro-followups/research/08-enemies-hostility-relation-api.md` (hostility truth), `.scratch/bg3-neuro-dialogue-click/` (client-only UI/dialogue, local-coop = processes), `brawl_State.lua:497-528` (ClientControl ≠ human ownership), `neuro-sdk/API/SPECIFICATION.md:198-240` (startup/session, actions/force).