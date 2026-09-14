# 06: Error dictionary and two channels

**What to build:** A unified ErrorMapper: every error_code from §6.5 → a human-readable actionable message for Neuro (what exactly is wrong and how to fix it). Two-channel delivery: Channel A (validation codes) goes out via `action/result` immediately after validation (R6); Channel B (execution failures: `action_failed`, `mod_unavailable` after validation) — **only** through the next state + context, never a late `action/result` (the server will drop a late result, ~20s window). Full code dictionary: target_missing, not_in_combat, no_spell, no_camp, not_supported, target_not_in_range, invalid_parameters, wrong_phase, dialogue_closed, action_failed, mod_unavailable.

**Blocked by:** 03 (combat loop to verify delivery of both channels).

**Status:** done

- [x] Every code from the §6.5 list projects into an actionable message (what's wrong + what to do). — `ErrorMapper` rewritten: `[Fact] DefaultMessage` for all 11 codes, `ToMessage(detail)` returns the detail, otherwise an actionable default; `ErrorCode.ActionFailed` added to the enum.
- [x] Validation codes are delivered via `action/result` immediately (Channel A). — `DecisionLoop.DispatchAsync` sends `action/result` right after `ValidateAndDispatch`; E2E `ModUnavailable_StaleAtValidation...`: stale heartbeat → instant failure + no action file written (the game is not started).
- [x] Execution failures are delivered via the next state + context (Channel B); a test confirms that no late `action/result` is sent. — `ExecutionFailure_SurfacesInNextState_WithoutLateActionResult` (from 04): exactly one `action/result` (validation ack), the failure context goes out in the second force.
- [x] `not_supported` covers `throw` (router → `NotSupported`) and dialogue without a client script (`ClientAutoselectExecutor`, ticket 07); `wrong_phase` — bonus_action/set_reaction outside their own turn (router `ValidatePhase`, already from ticket 03/04).
- [x] Unit test of the dictionary + integration check of both channels on the real loop. — `ErrorMapperTests` (7 tests: dictionary completeness, Channel A/B classification, the invariant "the router never issues Channel B as a validation result") + E2E of both channels.

**Summary:** `ErrorMapper.ToChannel`/`IsValidationResult` as the single source of truth for channels; 98/98 tests (was 90), build 0 warnings, 0 node processes after the run. `dialogue_closed` is already in the dictionary, delivery is in ticket 07.