# 04: Движение и атака (move_to_target, attack_entity)

**What to build:** Основные боевые действия «на собачьих ногах» за предыдущей вертикалью: командное перемещение в бою к координатам и атака врага. Долгоиграющие действия (движение) отвечают `running:true` и завершаются игровым событием (BG3SE-событие движения/атаки), никаких ожиданий по таймеру в Lua. C#-исполнитель умеет interruption пути, cancellation и приводит result к единому формату §6.5.

**Blocked by:** 03 (боевой цикл и формат action/result).

**Status:** done ✅

- [x] `move_to_target` перемещает контролируемого к точке; пока движется — `running:true`, финал приходит игровым событием, следующее состояние отражает новую позицию. — Lua v0.3.0: `executeMoveToTarget` → `Osi.CharacterMoveTo`/`Osi.CharacterMoveToPosition`, `writeResult` с двухфазным `running:true`; E2E: после движения state с `distance 2м` уходит Neuro в новом force.
- [x] Прерывание/отмена движения обработано без зависания (событие cancel). — `cancelActiveMove` регистрирует финал cancel при новом действии; C#-сторона safety чистит активный корутин не требуется (движение в Lua-модуле, event-driven).
- [x] `attack_entity` атакует цель через Osiris/BG3SE, результат (попал/промазал, урон) виден в следующем state/context. — `executeAttack` → `Osi.Attack` (fallback; честный party-pipeline через ServerCastRequest вынесен в 05-каст); E2E: HP 5/18 + событие урона в следующем force.
- [x] Failure-путь (цель вне досягаемости / цель не в бою) → Канал B через следующий state + context, не поздний action/result. — `CombatState.Events` + рендер «## События»; force по изменению контента; E2E гарантирует ровно один action/result для действия (ack валидации, Канал A) и контекст провала в state.
- [x] Сквозной тест движения + атаки с проверкой state + events. — `RandyDecisionLoopIntegrationTests`: `MoveToTarget_...SendsForceWithEvent`, `AttackEntity_...DamageShowsInNextForce`, `ExecutionFailure_...WithoutLateActionResult`.

**Итог:** 71/71 зелёных (60 → +11: 3 StateSerializer.Events, 5 ActionRouter target, 3 E2E), сборка 0 предупреждений/ошибок, node-процессов 0. C#: `CombatState.Events`, target-валидация (`target_missing` / недостающий `target_id` → `InvalidParameters`), force по контенту state (позиция/HP/события) вместо latch по актору. Lua mod v0.3.0: move/attack executors + running:true + cancel. Lua не исполняется в CI (тесты — mock-файлы); party-атаки через ServerCastRequest и cast-схема — тикет 05.