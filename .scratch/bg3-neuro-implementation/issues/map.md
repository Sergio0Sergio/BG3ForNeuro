# bg3-neuro-implementation — bucket of work

Tracked: 10 tickets (tracer-bullet vertical slices), Delivered: see statuses.

## Status
- [x] 01-file-bridge-heartbeat — **done** ✅ (config loader + IpcClient + heartbeat + Lua-мод + 24 unit-теста + smoke E2E)
- [x] 02-neuro-connect-register — **done** ✅ (ActionRegistry 17 схем + NeuroWebSocketClient + 38 unit + интеграция с Randy 37/37)
- [x] 03-combat-e2e-endturn — **done** ✅ (ActionRouter + DecisionLoop + Lua ActionExecutor + 60/60 tests + E2E: end_turn → Osi.EndTurn → state → Neuro)
- [x] 04-movement-attack — **done** ✅ (CombatState.Events + target-валидация + force по контенту + Lua v0.3.0 move/attack + 71/71 tests + E2E: движение/атака/Канал B)
- [x] 05-cast-spell — **done** ✅ (Combatant.PositionX/Y + CoverageAuto единый code path + SpellInfo{CastsLeft,OnCooldown} + ValidateCast (no_spell/target_not_in_range) + Lua v0.4.0 executeCast через ServerCastRequest + 90/90 tests + E2E: известный/неизвестный/AoE)
- [x] 06-error-map-channels — **done** ✅ (ErrorMapper: 11 actionable кодов §6.5 + Channel A/B классификация + ErrorCode.ActionFailed + ErrorMapperTests 7 шт + E2E mod_unavailable/Каналы + 98/98 tests)
- [x] 07-dialogue — **done** ✅ (CombatState.Dialogue + рендер «## Диалог» [1..N] + dialog-fueled force + ValidateDialogueOption (dialogue_closed/invalid_parameters/not_supported) + Lua v0.5.0 executeDialogueOption + 104/104 tests + E2E: диалог → выбор → state)
- [x] 08-exploration-actions — **done** ✅ (ExplorationObject{SeenBy,Region,Interactions,Lootable} + TravelLocation{RegionId} + InventoryItem + гибридный рендер с MaxVisibleObjects + ValidateExploration (target_missing/invalid_parameters/wrong_phase/no_camp) + force exploration/map/inventory + Lua v0.6.0 (Osi.Use/MoveAllLootableItemsTo/RequestLongRest+listeners; travel/screen/partial — structural) + 134/134 tests + E2E: перемещение→взаимодействие→лут→инвентарь)
- [x] 09-resilience — **done** ✅ (IpcClient.CleanStand + DecisionLoop реагирует на Stale→Alive: очистка мёртвого стэнда + повторный force; Lua v0.7.0 clearInFlight на бут; тесты R1/R2/R7/R8/force-политика через FakeNeuroServer — 138/138)
- [x] 10-ci-smoke — **done** ✅ (README + смоук `tests/smoke.ps1` + `FullLoopSmokeTests` (connect→state→end_turn→new state) + §9.5 `docs/manual-regression-checklist.md` + мануал установки/запуска — 139/139 tests, смоук одной командой PASS)

## Edge
Frontier: **все 10 тикетов доставлены** ✅ — 01..10 done; карта закрыта.

## Source
Spec: `E:\java_projects\BG3ForNeuro\BG3_Neuro_Spec.md` (final, accepted).