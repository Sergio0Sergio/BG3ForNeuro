# 04: Movement and attack (move_to_target, attack_entity)

**What to build:** Core combat actions on stub legs behind the previous vertical: commanded in-combat movement to coordinates and attacking an enemy. Long-running actions (movement) reply with `running:true` and finish via a game event (BG3SE movement/attack event), no timer-based waiting in Lua. The C# executor handles path interruption, cancellation, and normalizes the result into the unified §6.5 format.

**Blocked by:** 03 (combat loop and action/result format).

**Status:** done ✅

- [x] `move_to_target` moves the controlled character to the point; while moving — `running:true`, the final arrives via a game event, the next state reflects the new position. — Lua v0.3.0: `executeMoveToTarget` → `Osi.CharacterMoveTo`/`Osi.CharacterMoveToPosition`, `writeResult` with two-phase `running:true`; E2E: after movement a state with `distance 2m` goes to Neuro in a new force.
- [x] Movement interruption/cancellation handled without hanging (cancel event). — `cancelActiveMove` registers a cancel final when a new action arrives; no C#-side safety cleanup of the active coroutine is needed (movement lives in the Lua module, event-driven).
- [x] `attack_entity` attacks the target via Osiris/BG3SE, the result (hit/miss, damage) is visible in the next state/context. — `executeAttack` → `Osi.Attack` (fallback; the honest party-pipeline via ServerCastRequest is deferred to 05-cast); E2E: HP 5/18 + a damage event in the next force.
- [x] Failure path (target out of reach / target not in combat) → Channel B via the next state + context, not a late action/result. — `CombatState.Events` + `## Events` render; force on content change; E2E guarantees exactly one action/result per action (validation ack, Channel A) and the failure context in the state.
- [x] End-to-end movement + attack test with state + events verification. — `RandyDecisionLoopIntegrationTests`: `MoveToTarget_...SendsForceWithEvent`, `AttackEntity_...DamageShowsInNextForce`, `ExecutionFailure_...WithoutLateActionResult`.

**Summary:** 71/71 green (60 → +11: 3 StateSerializer.Events, 5 ActionRouter target, 3 E2E), build 0 warnings/errors, 0 node processes. C#: `CombatState.Events`, target validation (`target_missing` / missing `target_id` → `InvalidParameters`), force on state content (position/HP/events) instead of an actor latch. Lua mod v0.3.0: move/attack executors + running:true + cancel. Lua is not executed in CI (tests use mock files); party attacks via ServerCastRequest and the cast schema — ticket 05.