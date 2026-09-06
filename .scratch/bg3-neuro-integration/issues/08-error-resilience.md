# 08 — Error Handling & Race Conditions

Type: grilling
Status: resolved
Blocked by: 01
Depended by: —

## Answer

### Решения (HITL)

- **R1 (реконнект Neuro WS) — B**: после восстановления → повторный `startup` + перерегистрация действий. Обрабатываем `actions/reregister_all` (PROPOSALS.md): отвечаем регистрацией всего персистентного (фикс.) набора. Состав действий между реконнектами не меняется.
- **R2 (перезапуск BG3SE Mod) — A**: мод пишет `heartbeat.json` каждые **2 s**; C# считает heartbeat stale при возрасте **> 10 s** (устойчивость к паузам движка: загрузка локаций, катсцены — скорость детекта в turn-based не критична) → статус «мод недоступен», ждёт восстановления; на незавершённое действие → failure **`mod_unavailable`**; после восстановления — re-init (мод пересоздаёт polling). 5s-таймаут — дополнительный сигнал.
- **R3 (race force + самоакция) — A**: диспатчим любые действия Neuro всегда (README: слушать безотносительно force). Валидация C# (ресурсы/цель) отклоняет невозможное actionable failure. **Уточнение (review C): force не «просто push без последствий» — новый force поверх активного отменяет и заменяет его (SPEC §Force Actions: «one action force at a time»).** Безопасно, т.к. каждый force несёт полное свежее состояние; очереди нет; дисциплина — force только на точках решения (см. тикет 01 §1.6).
- **R4 (disposable) — A**: никаких disposable-действий, всё PERSISTENT (05 D2, 04 C4). Невалидный повтор → консистентный actionable failure («диалог уже закрыт»).
- **R6 (20s timeout) — A**: двухэтапно — `action/result` success сразу после валидации C# (до выполнения в игре, <20s); фактический исход (провал каста и т.п.) Neuro видит из следующего state. Просроченных result не бывает.
- **R7 (полный краш игры) — A**: рестарт игры = полный re-init через общий путь реконнекта (тот же что R1): повторный `startup` (если требуется), переустановка файлового режима, сброс decision loop, свежая force с новым state. WS Neuro либо уже переподключён, либо ждём.
- **R8 (невалидные данные) — A**: невалидный JSON / неизвестная команда → логируем и пропускаем (без ответа, чтобы не засорять); неизвестное/невалидное действие или неверные параметры → failure c actionable message + список валидных опций (BEST_PRACTICES).
- **R9 (два канала ошибок, review D) — принято**: `action/result` уходит сразу после валидации (R6), поэтому словарь разбит на два канала:
  - **Канал A (через `action/result`, валидация до игры)**: `target_missing`, `not_in_combat`, `no_spell`, `no_camp`, `not_supported`, `target_not_in_range`/`invalid_parameters`, `wrong_phase` (E7: действие требует хода контролируемого — bonus_action/set_reaction вне своего хода), `dialogue_closed`, `mod_unavailable` (**на момент валидации** — heartbeat stale, отвечаем failure не гоняя игру).
  - **Канал B (через следующий state + context, провалы исполнения)**: `action_failed`, `mod_unavailable` (**во время исполнения** — после отправки успешного результата, re-init по R7).
  - Тайминг `mod_unavailable` определяется положением относительно валидации. **Поздние `action/result` для Канала B не отправляем** — server отбросит (20s окно); картину Neuro восстанавливает следующий state/force (§1.6 триггеры).

### Error code vocabulary (feeds исполняющий слой 07) — разделено на два канала (R9, review D)

**Канал A — через `action/result` (валидация до игры):**
- `target_missing` — цель не существует/не найдена
- `not_in_combat` — действие требует боя
- `no_spell` — заклинание недоступно (нет в SpellBook / на кулдауне)
- `no_camp` — нельзя отдохнуть (нет лагеря/валидной точки)
- `not_supported` — есть слот в схеме, исполнение реализуется позже (`throw`)
- `target_not_in_range` / `invalid_parameters` — валидация параметров провалена
- `wrong_phase` — действие требует хода контролируемого персонажа (`bonus_action`, `set_reaction`), а сейчас чужой ход / не бой (E7)
- `dialogue_closed` — `select_dialogue_option` без активного диалога
- `mod_unavailable` — мод недоступен **на момент валидации** (heartbeat stale) — failure без запуска исполнения

**Канал B — через следующий state + context (провалы исполнения, без позднего action/result):**
- `action_failed` — исполнение в игре не вышло после валидации (детали — `error_detail` + следующий state)
- `mod_unavailable` — мод упал **во время исполнения** (после успешного результата; ре-init по R7)

## Question

Определить стратегию обработки ошибок и гонок:

1. **WebSocket реконнект**: Что если Neuro WS отключается? (BEST_PRACTICES.md: после реконнекта переслать startup и перерегистрировать действия)
2. **Named Pipe реконнект**: Что если BG3SE Mod перезапущен (crash/mod reload)?
3. **Race condition: action force + Neuro action**: Neuro может отправить действие до force. Как обрабатывать? (API README.md: слушать действия безотносительно состояния force)
4. **Race condition: disposable actions**: Как.unregister действия перед отправкой результата? (API: unregister перед result)
5. **Action force замена**: Отправка нового force пока старый не завершён — отменяет старый. Как избежать?
6. **Action timeout**: 20 секунд — сервер отдаёт failure. Как обрабатывать на стороне плагина?
7. **BG3SE Mod crash**: Как восстановить состояние после падения мода?
8. **Invalid Neuro response**: Невалидный JSON, несуществующее действие, неверные параметры.

См. API README.md, SPECIFICATION.md, BEST_PRACTICES.md для требований к обработке ошибок.
