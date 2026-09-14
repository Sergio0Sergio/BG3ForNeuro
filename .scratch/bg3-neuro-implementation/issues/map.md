# bg3-neuro-implementation — bucket of work

Tracked: 10 tickets (tracer-bullet vertical slices), Delivered: see statuses.

## Status
- [x] 01-file-bridge-heartbeat — **done** ✅ (config loader + IpcClient + heartbeat + Lua mod + 24 unit tests + smoke E2E)
- [x] 02-neuro-connect-register — **done** ✅ (ActionRegistry 17 schemas + NeuroWebSocketClient + 38 unit + Randy integration 37/37)
- [x] 03-combat-e2e-endturn — **done** ✅ (ActionRouter + DecisionLoop + Lua ActionExecutor + 60/60 tests + E2E: end_turn → Osi.EndTurn → state → Neuro)
- [x] 04-movement-attack — **done** ✅ (CombatState.Events + target validation + force by content + Lua v0.3.0 move/attack + 71/71 tests + E2E: movement/attack/Channel B)
- [x] 05-cast-spell — **done** ✅ (Combatant.PositionX/Y + CoverageAuto single code path + SpellInfo{CastsLeft,OnCooldown} + ValidateCast (no_spell/target_not_in_range) + Lua v0.4.0 executeCast via ServerCastRequest + 90/90 tests + E2E: known/unknown/AoE)
- [x] 06-error-map-channels — **done** ✅ (ErrorMapper: 11 actionable codes §6.5 + Channel A/B classification + ErrorCode.ActionFailed + ErrorMapperTests 7 tests + E2E mod_unavailable/channels + 98/98 tests)
- [x] 07-dialogue — **done** ✅ (CombatState.Dialogue + `## Dialogue` render [1..N] + dialog-fueled force + ValidateDialogueOption (dialogue_closed/invalid_parameters/not_supported) + Lua v0.5.0 executeDialogueOption + 104/104 tests + E2E: dialogue → selection → state)
- [x] 08-exploration-actions — **done** ✅ (ExplorationObject{SeenBy,Region,Interactions,Lootable} + TravelLocation{RegionId} + InventoryItem + hybrid render with MaxVisibleObjects + ValidateExploration (target_missing/invalid_parameters/wrong_phase/no_camp) + force exploration/map/inventory + Lua v0.6.0 (Osi.Use/MoveAllLootableItemsTo/RequestLongRest+listeners; travel/screen/partial — structural) + 134/134 tests + E2E: movement→interaction→loot→inventory)
- [x] 09-resilience — **done** ✅ (IpcClient.CleanStand + DecisionLoop reacts to Stale→Alive: dead bench cleanup + re-sent force; Lua v0.7.0 clearInFlight on boot; R1/R2/R7/R8/force-policy tests via FakeNeuroServer — 138/138)
- [x] 10-ci-smoke — **done** ✅ (README + smoke `tests/smoke.ps1` + `FullLoopSmokeTests` (connect→state→end_turn→new state) + §9.5 `docs/manual-regression-checklist.md` + install/run manual — 139/139 tests, one-command smoke PASS)

## Edge
Frontier: **all 10 tickets delivered** ✅ — 01..10 done; map closed.

## Source
Spec: `E:\java_projects\BG3ForNeuro\BG3_Neuro_Spec.md` (final, accepted).