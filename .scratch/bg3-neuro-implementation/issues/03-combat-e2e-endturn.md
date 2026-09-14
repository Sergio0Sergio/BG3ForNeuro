# 03: Combat E2E «end_turn» (first complete path)

**What to build:** The first complete vertical Neuro → C# → Lua → game → result → state. Neuro receives the combat state (whose turn it is, controlled characters, sides), sends `end_turn`; the C# validator checks that it is indeed the controlled character's turn; the action file is written; the Lua executor calls `Osi.EndTurn`; C# receives the result, replies to Neuro with `action/result`, and the next state reflects the new turn actor. Validation returns instantly (Channel A, R6); nobody waits for the in-game effect on a timer.

**Blocked by:** 01 (file bridge), 02 (Neuro↔C# loop).

**Status:** done

- [x] Combat state in §3 format (chrome/context/entities, controlled character, whose turn it is, AP) reaches Neuro. — `DecisionLoop.MaybeForceAsync` sends `actions/force` with the markdown state on each controlled character's turn (test `TurnAdvances_NewStateSendsForce_WithNextActor`).
- [x] Incoming `end_turn`: ActionRouter validates the phase ("currently the controlled character's turn"); wrong phase → actionable failure (Channel A, `wrong_phase`). — `EndTurn_WhenEnemyTurn_FailsWithWrongPhase_NoActionFile` + `ActionRouterTests` unit.
- [x] The validated command executes in the game: the turn actually ends, the next turn belongs to the next actor. — Lua `ActionExecutor` (v0.2.0) calls `Osi.EndTurn`; actor change verified in `TurnAdvances...` (state reflects Shadowheart's turn).
- [x] `action/result` is sent immediately after validation; success/failure in the unified §6.5 format. — `EndTurn_OnControlledTurn_WritesActionFile_AndSendsSuccessResult` (+ `SendResult` unit).
- [x] The updated post-turn state goes to Neuro. — DecisionLoop reacts to `StateChanged`, sends a force with the new actor (`TurnAdvances...`, force not duplicated: `UnchangedState_DoesNotResendForce`).
- [x] End-to-end test: the Neuro simulator (ticket 02) sends `end_turn` in combat → turn end verified from state. — `RandyDecisionLoopIntegrationTests` (3 tests, full loop through Randy).

**Summary:** The vertical Neuro → C# (ActionRouter + DecisionLoop) → action file → Lua `Osi.EndTurn` → result → updated state to Neuro is closed. Channel A (validation → `action/result`) without waiting for the in-game effect on a timer. Client wire format switched to snake_case per §SPECIFICATION. 60/60 green (57 previous + 3 new integration), build 0 warnings, 0 node processes after the run.