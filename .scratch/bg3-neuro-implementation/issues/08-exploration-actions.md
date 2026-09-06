# 08: Exploration: движение/взаимодействие/лут + простые действия

**What to build:** Всё, что Neuro может делать вне боя: exploration-state с осведомлённостью (что вокруг и с какой дистанцией), `move_to_entity` (перемещение к существу/объекту), `interact_with` (свободный `interaction_type` из state; несоответствие → actionable failure с перечнем доступных вариантов), `loot`, `rest` (full/partial), `travel_to` (по названию региона, `region_id` опционально), `toggle_mode [normal]` (stealth недоступен — X3), `open_map`/`open_inventory` (только просмотр → state экрана). Отдых требует лагеря и припасов → `no_camp`.

**Blocked by:** 03 (боевой цикл/execution-шаблон), 05 (переиспользование coverage для расстояний/осведомлённости — при желании объединить с 08).

**Status:** done

- [x] Exploration-state показывает ближайшие интерактивные объекты/существа с дистанцией (гибридный формат §3.3) и доступные взаимодействия.
- [x] `move_to_entity`, `interact_with`, `loot` выполняются вне боя; interaction_type невалиден → actionable failure (список доступных).
- [x] `travel_to`: матч по названию региона (primary), по `region_id` при задании; неизвестное название → failure.
- [x] `rest` full/partial: проверка лагеря/припасов → `no_camp` при отсутствии; сон в игре выполнен.
- [x] `toggle_mode` принимает только `"normal"`; `"stealth"` → отклонение с объяснением (X3).
- [x] `open_map`/`open_inventory` дают state экрана; торговля/экипировка/дроп — вне scope (не вводить).
- [x] Сквозной тест: перемещение→взаимодействие→лут по реальному state.

**Итог:** 134/134 тестов, сборка 0 предупреждений/ошибок, node 0. Lua v0.6.0 (не исполняется в CI — структурные правки: `Osi.Use` isInteraction для `interact_with`, `MoveAllLootableItemsTo`/`OpenCharacterLootUI` для `loot`, `RequestLongRest`(full) + listeners `LongRestFinished/Cancelled/StartFailed` для `rest`; `travel_to`/`open_map`/`open_inventory`/partial-rest — структурные `running:true` + TODO (нет подтверждённых публичных API; точный эффект приходит state-генератором, Канал B).