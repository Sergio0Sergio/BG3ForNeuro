# 04 — Combat Action Schemas

Type: grilling
Status: resolved
Blocked by: 01, 03
Depended by: 07

## Answer

Combat Action Schemas — финальные. (Доработано в диалоге.)

**8 действий** — контекст даёт информацию, действия дают жесты. LLM сам классифицирует заклинания по описанию в контексте.

### Финальные схемы

**Общий параметр всех действий: `actor?: string`** — псевдоним контролируемого персонажа (из state). Обязателен при `controlledPartySize > 1`, опускается при `party = 1` (действует активный/ходящий). Валидатор проверяет право хода против `actor`. **Валидация фазы (E7):** `bonus_action`/`set_reaction` требуют хода контролируемого; чужой ход или не бой → `wrong_phase` (тикет 08, Канал A) с actionable message, не `invalid_parameters`.

| # | Действие | Параметры | Описание (для Neuro) |
|---|---|---|---|
| 1 | `move_to_target` | `actor?: string`, `target_id: string` | Переместиться к указанной цели |
| 2 | `attack_entity` | `actor?: string`, `target_id: string` | Атаковать указанного врага основным оружием |
| 3 | `cast_spell` | `actor?: string`, `spell_name: string`, `target_id?: string`, `coverage?: string[]`, `position?: {x, y, z}` | Использовать заклинание |
| 4 | `use_item` | `actor?: string`, `item_id: string`, `target_id?: string` | Использовать предмет из инвентаря |
| 5 | `throw` | `actor?: string`, `item_id: string`, `target_id: string` | Бросить предмет в цель |
| 6 | `bonus_action` | `actor?: string`, `action_type: enum` | Выполнить бонусное действие |
| 7 | `set_reaction` | `actor?: string`, `reaction_type: enum` | Выбрать реакцию на этот ход |
| 8 | `end_turn` | `actor?: string` | Завершить ход |

### По каждому действию

**1. `move_to_target`** — `target_id` (псевдоним сущности или точки из state) + `actor`. Neuro видит доступные цели движения в state. Схема: `{ "type": "object", "required": ["target_id"], "properties": { "target_id": {"type": "string"}, "actor": {"type": "string"} } }`

**2. `attack_entity`** — `target_id` + `actor` (main hand всегда, без `weapon_slot` — offhand только через bonus_action). C2: вариант B.

**3. `cast_spell`** — C1 (AoE-решение):
- `actor` — исполнитель (обязателен при party > 1)
- `spell_name` — имя заклинания (из state, source of truth)
- `target_id` — основной центр (враг/союзник)
- `coverage` (optional) — желаемый список жертв для AoE; плагин центрирует взрыв на оптимуме покрытия, failure со списком, если не всё достижимо
- `position` (optional) — raw-координаты центра `{x, y, z}`, fallback-путь (включается в конфиге), по умолчанию disabled
- AoE-покрытие и range считаются плагином (единый code path с StateSerializer, см. 03 S3)

**4. `use_item`** — `item_id` + `target_id` (optional). Питьё зелья как действие — здесь. C3: оба пути остаются.

**5. `throw`** — `item_id` + `target_id`. **X2 (тикет 07): в v1 действие остаётся в схеме, но валидатор возвращает `not_supported`** (нет публичного Osiris-вызова; только Anubis/client input — хрупко). Честный failure «реализуется позже», не тишина (BEST_PRACTICES).

**6. `bonus_action`** — C4: enum **полный всегда**, недоступный вариант → failure с actionable message (нет ресайза enum; только цельное действие рега/дерегigится). C3: включает `drink_potion`.

**7. `set_reaction`** — C4: enum полный всегда, same принцип.

**8. `end_turn`** — без параметров.

### Enum (полные, фиксированные)

**bonus_action.action_type:**
- `offhand_attack` — атака второй рукой (нужно offhand оружие)
- `drink_potion` — выпить зелье (вторым темпом / бонусом)
- `help` — помочь союзнику (освободить от хватки, дать advantage)
- `shove` — толкнуть цель
- `disengage` — уклониться от атак возможности
- `dash` — дополнительное перемещение
- `dodge` — уклонение (атаки по тебе с disadvantage)

**set_reaction.reaction_type:**
- `opportunity_attack` — атака возможности (цель уходит из зоны досягаемости)
- `shield` — реакция Shield (защита от входящей атаки)
- `counterspell` — контрзаклинание (против вражеского заклинания)
- `none` — не использовать реакцию в этом ходу

### Обоснование

1. **cast_spell одно** — Neuro читает `spell_name` + описание в контексте и сама понимает тип. Разделение на offensive/heal/buff избыточно.
2. **bonus_action с фикс. enum** — бонусные действия механически ограничены (одно за ход).
3. **set_reaction с фикс. enum** — реакции настраиваются до хода.
4. **offhand через bonus_action, не weapon_slot** — один глагол на одну механику (C2 B).
5. **AoE через target_id + coverage** — Neuro может ударить одного ИЛИ группу с оптимизацией центра (C1).
6. **Регистрация — фиксированный полный набор (B, тикет 09-review)**: все 17 действий (8 combat + 1 dialogue + 8 exploration) регистрируются один раз на старте и не меняются. **«Neuro видит 4–8» из исходной версии — ОТМЕНЕНО** — стабильный набор ускоряет ответы (BEST_PRACTICES); релевантность достигается через state (что доступно на ход) + actionable failure, а не через регистрацию.

### Исполнение (X4, тикет 07)

Базовые атаки игроков (`attack_entity`) и `cast_spell` исполняются через `Ext.System.ServerCastRequest.OsirisCastRequests` (честно с AP/кулдаунами; каст — рельсы настоящего пайплайна). `Osi.Attack` (one-shot, без учёта ресурсов) — только враги/NPC/fallback. `spell_name` — prototype-имя (`Ext.Stats.Get`), нормализация в StateExtractor (X5).

### Risk

BEST_PRACTICES.md: "she tends to fixate on a few of them". Компенсация: полный фиксированный набор (B, все 17 на старте, состав не меняется) + релевантный поднабор через state + actionable failure со списком опций.

### Формат регистрации

Каждое действие регистрируется как `Action` (SPECIFICATION.md): `name` (нижний регистр, underscore), `description` (plain text, 1–2 предложения), `schema` (JSON Schema object). См. SPECIFICATION.md и BEST_PRACTICES.md.
