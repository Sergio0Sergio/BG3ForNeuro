# 08 — Error Handling & Race Conditions

Type: grilling
Status: resolved
Blocked by: 01
Depended by: —

## Answer

### Decisions (HITL)

- **R1 (Neuro WS reconnect) — B**: after recovery → re-send `startup` + re-register actions. Handle `actions/reregister_all` (PROPOSALS.md): respond with registration of the entire persistent (fixed) set. The action set does not change between reconnects.
- **R2 (BG3SE Mod restart) — A**: the mod writes `heartbeat.json` every **2 s**; C# considers the heartbeat stale when older than **> 10 s** (tolerant to engine pauses: location loading, cutscenes — detection speed is not critical in turn-based) → status «mod unavailable», waits for recovery; for an incomplete action → failure **`mod_unavailable`**; after recovery — re-init (the mod recreates polling). The 5s timeout is an additional signal.
- **R3 (race force + self-action) — A**: we always dispatch any Neuro action (README: listen regardless of force). C# validation (resources/target) rejects what's impossible with an actionable failure. **Clarification (review C): force is not "a push without consequences" — a new force over the active one cancels and replaces it (SPEC §Force Actions: "one action force at a time").** Safe, because each force carries complete fresh state; no queue; discipline — force only at decision points (see ticket 01 §1.6).
- **R4 (disposable) — A**: no disposable actions, everything PERSISTENT (05 D2, 04 C4). Invalid repeat → consistent actionable failure («dialogue already closed»).
- **R6 (20s timeout) — A**: two phases — `action/result` success immediately after C# validation (before in-game execution, <20s); the actual outcome (failed cast, etc.) Neuro sees from the next state. No overdue results.
- **R7 (full game crash) — A**: game restart = full re-init via the common reconnect path (the same as R1): re-send `startup` (if required), re-set the file mode, reset the decision loop, fresh force with new state. The Neuro WS is either already reconnected, or we wait.
- **R8 (invalid data) — A**: invalid JSON / unknown command → log and skip (no response, to avoid clutter); unknown/invalid action or wrong parameters → failure with an actionable message + list of valid options (BEST_PRACTICES).
- **R9 (two error channels, review D) — accepted**: `action/result` is sent immediately after validation (R6), so the vocabulary is split into two channels:
  - **Channel A (via `action/result`, validation before the game)**: `target_missing`, `not_in_combat`, `no_spell`, `no_camp`, `not_supported`, `target_not_in_range`/`invalid_parameters`, `wrong_phase` (E7: the action requires the controlled character's turn — bonus_action/set_reaction outside one's own turn), `dialogue_closed`, `mod_unavailable` (**at validation time** — heartbeat stale, we respond with a failure without running the game).
  - **Channel B (via next state + context, execution failures)**: `action_failed`, `mod_unavailable` (**during execution** — after a successful result was sent, re-init per R7).
  - The `mod_unavailable` timing is determined by its position relative to validation. **We don't send late `action/result` for Channel B** — the server will discard it (20s window); Neuro restores the picture from the next state/force (§1.6 triggers).

### Error code vocabulary (feeds the execution layer 07) — split into two channels (R9, review D)

**Channel A — via `action/result` (validation before the game):**
- `target_missing` — the target does not exist / not found
- `not_in_combat` — the action requires combat
- `no_spell` — the spell is unavailable (not in SpellBook / on cooldown)
- `no_camp` — cannot rest (no camp/valid point)
- `not_supported` — there is a slot in the schema, execution is implemented later (`throw`)
- `target_not_in_range` / `invalid_parameters` — parameter validation failed
- `wrong_phase` — the action requires the controlled character's turn (`bonus_action`, `set_reaction`), but it's another character's turn / not combat right now (E7)
- `dialogue_closed` — `select_dialogue_option` without an active dialogue
- `mod_unavailable` — the mod is unavailable **at validation time** (heartbeat stale) — failure without starting execution

**Channel B — via next state + context (execution failures, no late action/result):**
- `action_failed` — the in-game execution failed after validation (details — `error_detail` + next state)
- `mod_unavailable` — the mod crashed **during execution** (after a successful result; re-init per R7)

## Question

Determine the error handling and race condition strategy:

1. **WebSocket reconnect**: What if the Neuro WS disconnects? (BEST_PRACTICES.md: after reconnect resend startup and re-register actions)
2. **Named Pipe reconnect**: What if the BG3SE Mod is restarted (crash/mod reload)?
3. **Race condition: action force + Neuro action**: Neuro can send an action before the force. How to handle it? (API README.md: listen to actions regardless of the force state)
4. **Race condition: disposable actions**: How to unregister an action before sending the result? (API: unregister before result)
5. **Action force replacement**: Sending a new force while the old one is unfinished — cancels the old one. How to avoid it?
6. **Action timeout**: 20 seconds — the server returns a failure. How to handle it on the plugin side?
7. **BG3SE Mod crash**: How to restore state after a mod crash?
8. **Invalid Neuro response**: Invalid JSON, non-existent action, wrong parameters.

See API README.md, SPECIFICATION.md, BEST_PRACTICES.md for error handling requirements.