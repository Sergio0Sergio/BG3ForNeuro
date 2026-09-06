# 03: Боевой E2E «end_turn» (первый полный путь)

**What to build:** Первая законченная вертикаль Neuro → C# → Lua → игра → result → state. Neuro получает боевой state (кто чей ход, controlled персонажи, стороны), шлёт `end_turn`; C#-валидатор проверяет, что действительно ход контролируемого; пишется action-файл; Lua-исполнитель зовёт `Osi.EndTurn`; C# получает result, отвечает Neuro `action/result`, и следующий state отражает нового актора хода. Валидация возвращается мгновенно (Канал A, R6), никто не ждёт игрового эффекта по таймеру.

**Blocked by:** 01 (файловый мост), 02 (цикл Neuro↔C#).

**Status:** done

- [x] Боевой state в формате §3 (chrome/context/entities, controlled-персонаж, чей ход, AP) доходит до Neuro. — `DecisionLoop.MaybeForceAsync` шлёт `actions/force` с markdown-state на каждый ход контролируемого (тест `TurnAdvances_NewStateSendsForce_WithNextActor`).
- [x] Входящее `end_turn`: ActionRouter валидирует фазу («сейчас ход контролируемого»); неверная фаза → actionable failure (Канал A, `wrong_phase`). — `EndTurn_WhenEnemyTurn_FailsWithWrongPhase_NoActionFile` + юнит `ActionRouterTests`.
- [x] Проверенная команда выполняется в игре: ход реально заканчивается, следующий ход у следующего актора. — Lua `ActionExecutor` (v0.2.0) вызывает `Osi.EndTurn`; смена актора проверена в `TurnAdvances...` (state отражает Shadowheart на ходу).
- [x] `action/result` отправляется сразу после валидации; успех/ошибка в едином формате §6.5. — `EndTurn_OnControlledTurn_WritesActionFile_AndSendsSuccessResult` (+ юнит `SendResult`).
- [x] Обновлённый state после хода уходит Neuro. — DecisionLoop реагирует на `StateChanged`, шлёт force с новым актором (`TurnAdvances...`, force не дублируется: `UnchangedState_DoesNotResendForce`).
- [x] Сквозной тест: Neuro-симулятор (тикет 02) шлёт `end_turn` в бою → проверка конца хода по state. — `RandyDecisionLoopIntegrationTests` (3 теста, полный цикл через Randy).

**Итог:** Вертикаль Neuro → C# (ActionRouter + DecisionLoop) → action-файл → Lua `Osi.EndTurn` → result → обновлённый state уходит Neuro закрыта. Канал A (валидация → `action/result`) без ожидания игрового эффекта по таймеру. Wire-формат клиента переведён на snake_case под §SPECIFICATION. 60/60 зелёных (57 прежних + 3 новых интеграционных), сборка 0 предупреждений, node-процессов после прогона 0.