# 06: Словарь ошибок и два канала

**What to build:** Единый ErrorMapper: каждый error_code из §6.5 → человекочитаемое actionable сообщение для Neuro (что именно и как исправить). Двухканальная доставка: Канал A (валидационные коды) уходит через `action/result` сразу после валидации (R6); Канал B (провалы исполнения: `action_failed`, `mod_unavailable` позже валидации) — **только** через следующий state + context, никогда поздним `action/result` (сервер отбросит late result, окно ~20s). Полный словарь кодов: target_missing, not_in_combat, no_spell, no_camp, not_supported, target_not_in_range, invalid_parameters, wrong_phase, dialogue_closed, action_failed, mod_unavailable.

**Blocked by:** 03 (боевой цикл для проверки доставки обоих каналов).

**Status:** done

- [x] Каждый код из перечня §6.5 проецируется в actionable сообщение (что не так + что сделать). — `ErrorMapper` переписан: if `[Fact] DefaultMessage` для всех 11 кодов, `ToMessage(detail)` отдаёт detail, иначе actionable default; `ErrorCode.ActionFailed` добавлен в enum.
- [x] Валидационные коды доставляются через `action/result` немедленно (Канал A). — `DecisionLoop.DispatchAsync` шлёт `action/result` сразу после `ValidateAndDispatch`; E2E `ModUnavailable_StaleAtValidation...`: старый heartbeat → мгновенный failure + action-файл не пишется (игра не запускается).
- [x] Провалы исполнения доставляются следующим state + context (Канал B); тест подтверждает, что поздний `action/result` не отправляется. — `ExecutionFailure_SurfacesInNextState_WithoutLateActionResult` (ещё с 04): ровно один `action/result` (ack валидации), контекст провала уходит во второй force.
- [x] `not_supported` покрывает `throw` (router → `NotSupported`) и диалог без client-скрипта (`ClientAutoselectExecutor`, тикет 07); `wrong_phase` — bonus_action/set_reaction вне своего хода (router `ValidatePhase`, уже с тикета 03/04).
- [x] Unit-тест словаря + интеграционная проверка обоих каналов на реальном цикле. — `ErrorMapperTests` (7 тестов: полнота словаря, Канал A/B классификация, инвариант «router не выдаёт Канал B» как результат валидации) + E2E обоих каналов.

**Итог:** `ErrorMapper.ToChannel`/`IsValidationResult` как единая точка истины каналов; 98/98 тестов (было 90), сборка 0 предупреждений, node-процессов после прогона 0. `dialogue_closed` в словаре уже есть, доставка — в тикете 07.