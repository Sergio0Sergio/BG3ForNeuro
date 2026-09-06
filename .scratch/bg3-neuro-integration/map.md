# BG3 Neuro SDK Integration — Wayfinder Map

## Destination

Полная архитектурная спецификация интеграции Baldur's Gate 3 с Neuro SDK: модули, интерфейсы, форматы состояния, схемы действий для боя/диалогов/исследования, протокол IPC и тестирование. Результат — документ, готовый к передаче исполнителю.

## Notes

- Язык: C# как отдельный процесс
- Извлечение состояния: BG3 Script Extender (Lua/C# мод)
- Выполнение действий: BG3SE Lua-скрипт — полный каталог: [research/bg3se-lua-action-api.md](research/bg3se-lua-action-api.md) (сигнатуры, threading BG3SE однопоточный, матрица надёжности; решает «Not yet specified» про действие-в-ход/TurnOrder, путь → нативный MoveTo, таймауты и errors 07)
- Связь BG3SE ↔ C#: ~~Named pipe~~ → **файловый IPC (Ext.IO + JSON)** — research показал, что нативного named pipe в BG3SE нет; файловый IPC primary path, named pipe(C# mod) — upgrade path. Подробности: тикет BG3SE IPC Protocol
- Обновления состояния: по событию
- Тестирование: Randy + unit-тесты + интеграционные
- Консультации: neuro-sdk/API/SPECIFICATION.md, neuro-sdk/API/BEST_PRACTICES.md
- **Статус карты: destination reached.** Все 9 decision-тикетов решены; остались только post-v1 эксперименты (см. Out of scope). Итоговая спецификация собирается из тикетов 01–09.

## Decisions so far

- [BG3SE IPC Protocol](issues/02-ipc-protocol.md): Нативного named pipe в BG3SE нет; LuaSocket и HTTP недоступны. Primary path — файловый IPC через `Ext.IO.SaveFile`/`LoadFile` + JSON (`Ext.Json`), неблокирующий polling через `Ext.Timer.WaitForRealtime`. C# process на отдельных потоках. Named pipe (C# mod) — Phase 2 upgrade path. Готовых BG3→Neuro интеграций не найдено.
- [Architecture Overview](issues/01-architecture-overview.md): Двухпроцессная архитектура. BG3SE Mod (Lua) — dumb: `StateExtractor` + `ActionExecutor` + `IpcFileHandler`. C# Process — возя всю логику: `NeuroWebSocketClient`, `IpcClient`, `StateSerializer`, `ActionRouter`, `DecisionLoop`. Файловый IPC (JSON) в решении, decision-в-C#. Псевдонимы сущностей для Neuro. `controlledPartySize` 1..4 в конфиге. Force несёт свежий markdown state (ephemeral), редкие context для правил. Политика force (§1.6, review C): триггеры — ход контролируемого / DialogStarted / выход из боя / timeout-then-force; priority всегда `low` (BG3 пошаговая); новый force отменяет+заменяет (спека), т.к. несёт полный state.
- [State Format](issues/03-state-format.md): Три генератора state (combat/dialogue/exploration). Метры как расстояния. Гибрид distance + «в радиусе/покрывает» per spell (единый code path с валидатором). Диалоговые номера = порядок в UI окна BG3 (1-based), совпадают со стример-модом; `option_index` primary + `option_text` fallback. Осведомлённость как фильтр видимости (скрытые/невидимые не видны, без читерства). toggle_mode в exploration-state: `[normal]` (E6, X3 — stealth в v1 нет). Всё состояние — выведено в config.json (combat/dialogue/exploration блоки с дефолтами). «Вы — Neuro» не писать в шапке force; только динамика (управляете/режим/ход); правила — разовый стартовый context (silent).
- [Combat Action Schemas](issues/04-combat-actions.md): 8 combat-действий: `move_to_target`, `attack_entity` (без weapon_slot, всегда main), `cast_spell` (target_id + coverage для AoE + position fallback), `use_item`, `throw` (→ `not_supported` в v1), `bonus_action` (enum полный всегда, drink_potion внутри), `set_reaction` (enum полный), `end_turn`. Общий `actor?: string` во всех — псевдоним исполнителя, обязателен при party > 1, опускается при party = 1. C4: динамическая регистрация только на уровне действия, никогда enum-ресайз (BEST_PRACTICES: частые изменения схемы замедляют ответы).
- [Dialog Action Schemas](issues/05-dialogue-actions.md): Одно действие `select_dialogue_option` (`option_index` primary, `option_text` fallback; номер = порядок UI окна BG3). PERSISTENT регистрация с старте — никаких рега/дерега (fail при нет диалога). Контекст: заголовок+реплика+варианты с подсказками. Forced dialogue: DecisionLoop переключает режим, persistent остаётся. Торговля — out of scope.
- [Exploration Action Schemas](issues/06-exploration-actions.md): 8 exploration-действий: `move_to_entity`, `interact_with` (свободный `interaction_type`, валидация в плагине), `loot` (отдельное), `open_map`/`open_inventory` (только просмотр + use_item/travel_to), `toggle_mode` (target_id? + mode; в v1 enum только `["normal"]`, `"stealth"` убран по X3 — нет публичного API), `rest` (full/partial), `travel_to` (destination = название региона (primary), region_id? опционально для однозначности; state даёт [Название (id)]). Общий `actor?: string` (аналог combat). UI-клики внутри карты/инвентаря — out of scope.
- [Action Execution Layer](issues/07-action-execution.md): Один in-flight action (BG3SE Lua однопоточный → сериализация). Файловый IPC: C# валидирует + пишет `action_<id>.json`; Lua poll (100–250мс) → диспатч → `result_<id>.json` `{success, error_code, error_detail}`. ACK-таймаут 5s (тикет 08). Long actions: `running:true` → финал событием (`CastedSpell`), блокировку потока не делаем. Диалог: X1 — `ClientAutoselectExecutor`: client Lua находит элемент по option_index (= порядок UI), подсвечивает и кликает, человек ничего не жмёт (confirm схлопнут как алиас в `dialogue.mode`); client недоступен → откат на `not_supported` + warning (Neuro не остаётся без канала). `throw` — в схеме как `not_supported` (честный failure). Stеalth: X3 — в v1 `toggle_mode` только `"normal"`, `"stealth"` убрать (нет публичного API) до появления решения. Атаки игроков: через `ServerCastRequest.OsirisCastRequests` (честно с AP), `Osi.Attack` — враги/fallback. SpellId: нормализация в StateExtractor, по конвейеру prototype-имена (`Ext.Stats.Get`). Полные JSON-Schema всех 17 действий — спецификация §5.4.
- [Error Resilience](issues/08-error-resilience.md): R1 — реконнект: `startup` + перерегистрация, обработка `actions/reregister_all` (persistent набор). R2 — мод пишет `heartbeat.json` каждые 2s, stale при возрасте > 10s (устойчивость к паузам движка, детект неспешен — turn-based) → `mod_unavailable` + re-init. R3 — диспатчим любые действия Neuro всегда (force не блокирует); уточнено (C): новый force отменяет+заменяет активный (спека), безопасно т.к. несёт полный state. R4 — нет disposable, всё persistent. R6 — двухэтапный ответ: success на валидации, исход через след. state. R7 — краш игры = полный re-init через путь реконнекта. R8 — JSON-мусор → лог+пропуск; невалидное действие → failure со списком опций. R9 (review D) — словарь error_code разделён на **два канала**: Канал A (action/result, валидация): target_missing/not_in_combat/no_spell/no_camp/not_supported/invalid_parameters/target_not_in_range/wrong_phase(E7: bonus_action/set_reaction вне своего хода)/dialogue_closed/mod_unavailable(до валидации); Канал B (следующий state+context, исполнение): action_failed/mod_unavailable(во время исполнения). Поздних action/result не шлём — server отбросит; картину восстанавливает следующий force (§1.6).
- [Testing Architecture](issues/09-testing-architecture.md): T1 — Randy как есть (`ws://localhost:8000` + HTTP POST `:1337`), не форкаем. T2 — unit: StateSerializer, ActionRouter, IpcClient (фейк-файлы), ConfigLoader, ErrorMapper + отдельный модуль range/AoE coverage; Lua-мод против моков `Ext.*` — smoke на стенде, не в CI. T3 — интеграция: mock-файлы BG3SE + C#-конвейер в CI (A) и с Randy (B); реальная Neuro — ручной регресс. T4 — smoke: фейковый BG3SE в CI + обязательный ручной прогон на реальной игре перед релизом. T5 — авто на симулированных state по-максимуму + ручной чек-лист регрессии (бой/диалог/исследование, без покупки).

## Not yet specified

- ~~Структура данных сущностей BG3~~ → решено в [research/bg3se-lua-action-api.md](research/bg3se-lua-action-api.md): компоненты (`SpellBook`, `Inventory`, `TurnOrder`, `EocCombatTurnOrderComponent`) + `ExtIdeHelpers` — источник полей
- ~~Как определить доступные действия в текущем ходу (боевые)~~ → решено: события `TurnStarted/TurnEnded` + `EocCombatTurnOrderComponent` (`IsPlayer`, `Initiative`, `Members`); `Osi.CombatGetActiveEntity`
- ~~Алгоритм построения пути для исследования~~ → решено: нативный `Osi.CharacterMoveTo( Position)` / `TeleportToPosition`; свой A* не нужен
- ~~Таймауты и error-модель выполнения~~ → решено в тикете 07: ACK 5s, `{success, error_code, error_detail}`, long actions `running:true`
- ~~Как выбирается вариант диалога~~ → решено в тикете 07 (X1): `confirm` (человек жмёт клавишу) как v1 + экспериментальный `auto` (client UI) за флагом `dialogue.mode`; `option_index` = порядок UI окна
- Конкретная схема force/query/state для каждого сценария (бой/диалог/исследование) — решается при сборке итоговой спецификации из тикетов 03–07 (сикция «Готовые блоки», конвейер данных)

## Out of scope

- Голосовой чат (Voice Chat API) — не входит в первую спецификацию
- Мультиплеер — поддержка других игроков в сессии
- Реалтайм-управление камерой — Neuro не управляет камерой напрямую
- Оптимизация производительности — не приоритет для спецификации
- Упаковка и деплой — не входит в архитектурную спецификацию
- Торговля (покупка/продажа) — отдельный UI-экран вне диалоговых вариантов; решено в тикете 05, вне scope карты (опциональный мини-модуль позже)
- `throw` (бросок предметов) в v1 — `not_supported` (нет публичного API; Anubis/client input — хрупко) — решено X2 в тикете 07
- Стелс-режим `"stealth"` для `toggle_mode` в v1 — нет публичного API, убрано; вернётся после эксперимента — решено X3 в тикете 07
- Post-v1 эксперименты (фреш-направления после v1, не часть текущей спецификации): клиентская автоселекция диалога (`auto` mode), stealth-status experiment (для `"stealth"` в `toggle_mode`) — черновики в тикете 07, research§7.6/§10
