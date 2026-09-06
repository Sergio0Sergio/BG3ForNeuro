# 03 — State Format

Type: grilling
Status: resolved
Blocked by: 01
Depended by: 04, 05, 06

## Answer

State-формат определён. (Резолвено в живом диалоге.)

### S1 — Ветвление по сценарию

Три генератора: `combat`, `dialogue`, `exploration`. Переключаются по активному режиму. Один `StateSerializer`, ветвление. Меньше шума для LLM.

### S2 — Боевой state

Markdown, без `#` top-level, структура через `##`. Метры как единица расстояния (движок BG3 работает в метрах, тот же язык, что в UI заклинаний). Полный набор действий (8 из тикета 04): `move_to_target`, `attack_entity`, `cast_spell`, `throw`, `use_item`, `bonus_action`, `set_reaction`, `end_turn`. Расстояние до врагов/целей — в метрах, не близко/средне/далеко.

```markdown
## Ход: Karlach (инициатива 3/5)
## Контролируемые персонажи
- Karlach: HP 45/60, distance от (ориентира) 6м, эффекты: Rage (3 раунда)...
## Враги
- goblin_1 (Goblin Raider): HP 12/18, distance 6м, статус: —
## Заклинания (Karlach)
- Fireball: слот 3, радиус 18м, AoE 4м → в радиусе: [goblin_1, goblin_2]
## Доступные действия (Karlach)
- move_to_target: [<цели движения>]
- attack_entity: [goblin_1, goblin_2]
- cast_spell: [Fireball, Magic Missile] (слот 3: 2)
- throw: [health_potion, javelin] → [goblin_1, goblin_2]
- use_item: [health_potion]
- bonus_action: [offhand_attack, help, shove]
- set_reaction: [opportunity_attack, shield]
- end_turn
```

### S3 — Гибрид: distance + в радиусе/AoE

Оба слоя вместе:
- `distance: 6м` per enemy (O(N))
- `→ в радиусе: [список]` per spell (O(N) на заклинание), считается плагином из координат + range
- Для AoE: `→ покрывает: [goblin_1, goblin_2] (2 цели)` — плагин считает оптимальное центрирование
- Заклинание без целей в радиусе: `(нет целей в радиусе)`
- НЕ O(заклинания × враги) — избегаем шума
- Требование: **единый code path** для range/AoE-вычислений в StateSerializer и ActionRouter (консистентность state ↔ валидатор)

### S4 — Диалоговый state: текст + подсказка, номера = UI окна

```markdown
## Диалог с Astarion (отношение: нейтральное)
Он говорит: "..."
## Варианты ответа
1. "Мы должны идти. Это важно."
2. "Ты прав, отложим это."
3. "У меня есть вопрос о Cazador." [Persuasion]
4. [Уйти из диалога]
```

- **Номера вариантов = порядок в UI окне диалога BG3 (1-based)** — плагин нумерует так же, как показывает игра. Совпадает со стример-модом (зрители советуют номер, Neuro видит тот же).
- `select_dialogue_option` принимает `option_index` (primary) + `option_text` (fallback, матчится по тексту).
- Метаданные сложности (DC) не показывать.

### S5 — Исследование-state: осведомлённость как фильтр

- **Фильтр = осведомлённость персонажа** (game's visibility/perception, не радиус, не top-N). Каждый контролируемый персонаж имеет свой набор. **Персонажи в стелсе/невидимости не видны** (BEST_PRACTICES: не давать читерство, human-like).
- `maxVisibleObjects: 20` (конфиг) — верхний предел с пометкой "и ещё N".
- Данные о сущностях — только из видимого игроку состояния, никогда из абсолютных координат.

```markdown
## Режим: обычный
## Объекты (видит Karlach, 5)
- goblin_camp_sign (читаемый, 5м)
...
## Объекты (видит Shadowheart, 3)
...
## Доступные действия
- move_to_entity: [...]
- interact_with: [...]
- open_map
- toggle_mode: [normal]
```

### S5-конфиг

Всё выносится в `config.json`, три блока `combat`/`dialogue`/`exploration` с дефолтами:

```json
"state": {
  "combat":     { "showQuestMarker": false },
  "dialogue":   { },
  "exploration": {
    "showQuestMarker": true,
    "maxVisibleObjects": 20,
    "objectInfo": { "visible": true, "skillRequirements": false },
    "distanceFormat": "hybrid",     // meters | region | hybrid
    "showPosition": false
  }
}
```

- S5.2 квестовый маркер: exploration true (компас), combat false
- S5.3 видимые признаки true, скилл-требования false (без читерства)
- S5.4 distanceFormat: hybrid — ближние ≤50м в метрах, дальние "область: имя"
- S5.5 showPosition: false — абсолютная позиция не нужна, геометрия в дистанциях

### S6 — Identity: НЕ писать "Вы — Neuro" в шапке

Следуя BEST_PRACTICES:
- Тождество "Neurо, играет в BG3" — она знает из `startup` + characterId. Не повторять.
- Стартовый context (silent=true, один раз) — правила игры, как читать state, значение действий, стиль (human-like).
- Шапка каждого force — **только динамика**: «Управляете: Karlach [+ партия]. Режим: combat. Ход: Karlach.»
- Никаких периодических повторов статичной информации.
