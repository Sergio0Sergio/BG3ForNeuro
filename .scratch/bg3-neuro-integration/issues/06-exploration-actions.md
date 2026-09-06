# 06 — Exploration Action Schemas

Type: grilling
Status: resolved
Blocked by: 01, 03
Depended by: 07

## Answer

Exploration Action Schemas — финальные. (Доработано в диалоге.)

### Набор действий

**Общий параметр всех действий: `actor?: string`** — псевдоним контролируемого персонажа (из state). Обязателен при `controlledPartySize > 1`, опускается при `party = 1`. Аналогично боевым действиям (04).

| # | Действие | Параметры | Описание |
|---|---|---|---|
| 1 | `move_to_entity` | `actor?: string`, `target_id: string` | Переместиться к цели |
| 2 | `interact_with` | `actor?: string`, `target_id: string`, `interaction_type?: string` | Взаимодействовать с объектом |
| 3 | `loot` | `actor?: string`, `target_id: string` | Собрать добычу с трупа/контейнера |
| 4 | `open_map` | `actor?: string` | Открыть карту (просмотр) |
| 5 | `open_inventory` | `actor?: string` | Открыть инвентарь (просмотр) |
| 6 | `toggle_mode` | `actor?: string`, `target_id?: string`, `mode: "normal"` | Переключить режим |
| 7 | `rest` | `actor?: string`, `rest_type: "full" \| "partial"` | Отдохнуть |
| 8 | `travel_to` | `actor?: string`, `destination: string`, `region_id?: string` | Путешествовать в локацию |

### По каждому действию

**1. `move_to_entity`** — `target_id` по псевдониму осведомлённого объекта.

**2. `interact_with`** — E4: свободный `interaction_type` (не enum!) из state:
```json
{ "target_id": "wooden_door", "interaction_type": "lockpick" }
```
- Соответствует BEST_PRACTICES: изменяющийся набор взаимодействий → свободный параметр + runtime-валидация
- В state (03) показывать доступные взаимодействия: `wooden_door (закрыта, 3м): [открыть, заламать, толкнуть]`
- Валидация: несоответствие → failure с actionable message («У двери доступны: открыть, заламать, толкнуть»)
- `interaction_type` опущен → дефолт (первый/«открыть»)

**3. `loot`** — E5: отдельное действие (частый жест в BG3, Neuro заказывает явно).

**4/5. `open_map` / `open_inventory`** — E3: **вариант B** — просмотр + существующие действия.
- `open_map` → state экрана карты (локации/области для `travel_to`)
- `open_inventory` → state инвентаря (вещи; использование — через `use_item` из combat-схем)
- Экипировка/дроп/сортировка/торговля — out of scope

**6. `toggle_mode`** — E2: `target_id?` (по умолчанию активный; обязателен при партии) + `mode` enum. **X3 (тикет 07): в v1 enum — только `["normal"]`, `"stealth"` убран** — нет публичного Osiris-API переключения скрытности (клиентская механика; ApplyStatus — хрупко, имена статусов меняются). `"stealth"` вернётся, когда появится устойчивое решение (client-UI / status experiment).

**7. `rest`** — E1: `rest_type` enum [full, partial]. Neuro выбирает, сколько припасов тратить.

**8. `travel_to`** — E2 (уточнено): `destination` = **название региона** (primary); `region_id?` — опционально, для однозначности при неоднозначных названиях. State (03 S5.4) показывает соответствие `[Название области (id: xxx)]` с дистанцией в гибридном формате.

### Примечания

- Переход в бой из исследования — автоматический (DecisionLoop, тикет 01), не через действия.
- Псевдонимы и осведомлённость — из тикетов 01, 03.
- UI-клики внутри map/inventory — не даются Neuro (только просмотр state).

### Формат регистрации

Как `Action` (SPECIFICATION.md): name, description (plain text), schema (JSON Schema object). Эти действия регистрируются на старте (persistent, см. 05 D2).
