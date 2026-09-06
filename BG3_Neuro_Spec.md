# BG3 ↔ Neuro SDK Integration — Архитектурная спецификация (v1)

Полная спецификация интеграции Baldur's Gate 3 с Neuro SDK: модули, интерфейсы, форматы состояния, схемы действий для боя/диалогов/исследования, протокол IPC и тестирование. Готово к передаче исполнителю.

Дата: 2026-09-05 · Источник: wayfinder-карта `.scratch/bg3-neuro-integration/` (тикеты 01–09).

---

## 1. Обзор архитектуры

Двухпроцессная архитектура: **C# standalone-процесс** (вся логика взаимодействия с Neuro, «решение в C#») + **BG3 Script Extender мод на Lua** (dumb — только извлечение состояния и исполнение действий).

```
┌─────────────────────────────────────────────┐
│  Neuro (внешний WS-сервер, ws://localhost)  │
└──────────────────┬──────────────────────────┘
                   │ WebSocket (протокол Neuro SDK)
┌──────────────────▼──────────────────────────┐
│  C# Standalone Process                      │
│  NeuroWebSocketClient · IpcClient ·         │
│  StateSerializer · ActionRouter ·           │
│  DecisionLoop · CoverageAuto ·              │
│  ConfigLoader · ErrorMapper                 │
└──────────────────┬──────────────────────────┘
                   │ Файловый IPC (JSON)
┌──────────────────▼──────────────────────────┐
│  BG3SE Mod (Lua)                            │
│  StateExtractor · ActionExecutor ·          │
│  IpcFileHandler                             │
└──────────────────┬──────────────────────────┘
                   │ Ext/Osi API
              Baldur's Gate 3
```

### 1.1 Модули BG3SE Mod (Lua) — dumb, без логики решений

| Модуль | Назначение |
|---|---|
| `StateExtractor` | Подписка на события BG3, извлечение состояния → JSON → файл `bg3_to_neuro.json` |
| `ActionExecutor` | Приём команд из файла `neuro_to_bg3.json`, вызов `Ext/Osi` API |
| `IpcFileHandler` | Работа с файлами (`Ext.IO.SaveFile/LoadFile`, `Ext.Json`, polling `Ext.Timer.WaitForRealtime`) |

### 1.2 Модули C# Process — вся логика Neuro-взаимодействия

| Модуль | Назначение |
|---|---|
| `NeuroWebSocketClient` | WebSocket к Neuro: реконнект, startup, actions/register, actions/force, action/result |
| `IpcClient` | Файловый IPC: чтение (FileSystemWatcher), запись команд (JSON) |
| `StateSerializer` | JSON состояния BG3 → Markdown контекст для Neuro (ветвление по сценарию) |
| `ActionRouter` | Валидация JSON от Neuro (name→entity_id, schema), маршрутизация к ActionExecutor |
| `DecisionLoop` | Оркестрация: событие → context/force → валидация → execute → result; правила «когда force» |
| `CoverageAuto` | Вычисление range/AoE-покрытия (единый code path с StateSerializer, см. §1.3) |
| `ConfigLoader` | `config.json` → структуры с дефолтами |
| `ErrorMapper` | Словарь error_code → actionable message |

### 1.3 Потоки данных

**BG3 → Neuro:**
Событие в BG3 → `StateExtractor` → JSON → `bg3_to_neuro.json` → `IpcClient` (FileSystemWatcher) → `StateSerializer` (JSON→Markdown) → `NeuroWebSocketClient` (context или state в force)

**Neuro → BG3:**
Neuro decision → `ActionRouter` (валидация, alias→id) → `IpcClient` (запись JSON) → `neuro_to_bg3.json` → `IpcFileHandler` → `ActionExecutor` → `Ext/Osi` API → результат → обратно через состояние

**Единый code path расчёта покрытия:** range/AoE-вычисления используются и в `StateSerializer` (что показано в state) и в `ActionRouter` (что валидируется) — гарантия консистентности «state ↔ валидатор».

### 1.4 Жизненный цикл

- **Запуск C#**: читает `config.json` → стартует `IpcClient` (файловый) → `NeuroWebSocketClient.Connect()` → при коннекте: `startup` + `actions/register`
- **Запуск BG3SE**: мод создаёт файлы IPC, подписывается на события, шлёт первое состояние (SessionLoaded)
- **Реконнект WS**: автореконнект (interval ~3s) → после open: re-send `startup` + re-register actions; обработка `actions/reregister_all`
- **Реконнект игры/мода**: мод при старте пересоздаёт файлы; при отсутствии нового state-файла C# ждёт
- **Ошибка/паника мода**: C# логирует, ждёт heartbeat-файл

### 1.5 Ключевые решения

- **Решение-в-C#**: BG3SE — dumb. Логика «когда слать force/context» живёт в C# (тестируемо).
- **Псевдонимы сущностей**: контекст содержит таблицу id↔name; Neuro работает с короткими именами (`goblin_1`), `ActionRouter` переводит в entity_id.
- **`controlledPartySize` (1..4)**: настройка числа контролируемых персонажей. State показывает всех; текущий ходящий определяется инициативой. Параметр `actor` в схемах действий при >1.
- **Force + state**: каждый force несёт свежий markdown state (`ephemeral_context: true` — bulky state каждый ход); редкие context (silent=true) — для правил/задач.
- **По событию**: обновления состояния приходят по игровым событиям, а не по поллингу.

### 1.6 Политика force (DecisionLoop)

Правила «когда слать `actions/force`» — источник истины для исполнителя. Основано на BEST_PRACTICES.md §Forcing Actions и SPECIFICATION.md §Force Actions.

**Триггеры (точки, где игра ждёт решения Neuro):**
- **combat** — старт хода контролируемого персонажа; выход из боя (сброс контекста, новый force со state exploration)
- **dialogue** — `DialogStarted` (сила с вариантами ответа)
- **exploration** — `SessionLoaded`, выход из боя, смена режима; для открытых периодов — **timeout-then-force** (BEST_PRACTICES рекомендует): если активность долго без решения, слать force по таймауту
- Всё остальное — через context (редкий, silent), не через force

**Priority:** **всегда `low` (default)** — BG3 пошаговая, никогда не прерывает речь Neuro. `medium`/`high`/`critical` в v1 **не используются** (нет хард-реалтайма; критичные моменты отсутствуют в пошаговом BG3).

**Замена, не очередь:** новый force поверх активного **отменяет и заменяет** его (SPEC: «Neuro can only handle one action force at a time»). Безопасно, поскольку каждый force несёт **полное свежее состояние** — потеря контекста невозможна. Очередь не нужна; дисциплина — force только на точках решения, не на каждом событии.

**state vs query:** `state` — markdown-состояние из §3; `query` — краткое «что сейчас делать» (например «Сейчас твой ход. Выбери действие.»). `ephemeral_context: true` для bulky state каждый ход (BEST_PRACTICES §Forcing Actions).

---

## 2. IPC-протокол (BG3SE ↔ C#)

### 2.1 Канал: файловый IPC

Research-факт: **нативного named pipe в BG3SE нет** (подробности: `.scratch/bg3-neuro-integration/research/ipc-named-pipes.md`).

- `Ext.IO` даёт только `SaveFile`/`LoadFile`; `Ext.Net` — только внутриигровые соединения.
- **LuaSocket недоступен** (`require("socket.http")` не работает).
- **Primary path — файловый IPC + JSON**:
  - BG3SE Lua пишет JSON через `Ext.IO.SaveFile()`, C# читает/пишет файлы
  - Неблокирующий polling через `Ext.Timer.WaitForRealtime()` (не `Ext.OnNextTick`)
  - Сериализация: `Ext.Json.Stringify()`/`Ext.Json.Parse()` (совпадает с JSON-протоколом Neuro)
- **Upgrade path (Phase 2, опционально)**: если файловый IPC слишком медленный (~50–100мс) — C# мод с `System.IO.Pipes` внутри BG3SE.

### 2.2 Файлы

`<BG3ScriptExtender appdata>/BG3Neuro/`:
- `bg3_to_neuro.json` — состояние из игры (пишет мод)
- `neuro_to_bg3.json` — команды действия (пишет C#)
- `action_<id>.json` — конкретная команда действия
- `result_<id>.json` — результат выполнения (пишет мод)
- `heartbeat.json` — сердцебиение мода (пишет каждые **2 s**; stale-порог **10 s**)

---

## 3. Формат состояния (state)

### 3.1 Ветвление по сценарию

Три генератора: `combat`, `dialogue`, `exploration`. Переключаются по активному режиму. Один `StateSerializer`, ветвление. Меньше шума для LLM.

### 3.2 Боевой state

Markdown, без `#` top-level, структура через `##`. Метры как единица расстояния (движок BG3 работает в метрах — тот же язык, что в UI заклинаний). Полный набор боевых действий (§5.1). Расстояния до врагов/целей — в метрах.

```markdown
## Ход: Karlach (инициатива 3/5)
## Контролируемые персонажи
- Karlach: HP 45/60, distance 6м, эффекты: Rage (3 раунда)...
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

> Блок «Доступные действия» уже адресуется конкретному персонажу (Karlach). Параметр `actor` в схемах дублирует эту привязку для случая партии (`controlledPartySize > 1`); при `= 1` он не требуется.

### 3.3 Гибрид расстояний + «в радиусе/покрывает» (S3)

Оба слоя вместе:
- `distance: 6м` per enemy (O(N))
- `→ в радиусе: [список]` per spell (O(N) на заклинание), считается плагином из координат + range
- Для AoE: `→ покрывает: [goblin_1, goblin_2] (2 цели)` — плагин считает оптимальное центрирование
- Заклинание без целей в радиусе: `(нет целей в радиусе)`
- НЕ O(заклинания × враги) — избегаем шума
- **Единый code path** для range/AoE-вычислений в StateSerializer и ActionRouter

### 3.4 Диалоговый state: текст + подсказка, номера = UI окна

```markdown
## Диалог с Astarion (отношение: нейтральное)
Он говорит: "..."
## Варианты ответа
1. "Мы должны идти. Это важно."
2. "Ты прав, отложим это."
3. "У меня есть вопрос о Cazador." [Persuasion]
4. [Уйти из диалога]
```

- **Номера вариантов = порядок в UI окне диалога BG3 (1-based)** — плагин нумерует так же, как показывает игра (совпадает со стример-модом).
- `select_dialogue_option` принимает `option_index` (primary) + `option_text` (fallback, матчится по тексту).
- Метаданные сложности (DC) не показывать; репутационные числа не показывать.

### 3.5 Исследование-state: осведомлённость как фильтр

- **Фильтр = осведомлённость персонажа** (game's visibility/perception, не радиус, не top-N). Каждый контролируемый персонаж имеет свой набор. **Персонажи в стелсе/невидимости не видны** (никакого читерства, human-like).
- `maxVisibleObjects: 20` (конфиг) — верхний предел с пометкой «и ещё N».
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

> Примечание: `toggle_mode` в v1 показывает только `[normal]` (см. §5.3 X3).

### 3.6 Identity — не писать «Вы — Neuro» в шапке

- Тождество — это же BG3, она знает из `startup` + characterId. Не повторять.
- Стартовый context (silent=true, один раз) — правила игры, как читать state, значение действий, стиль (human-like).
- Шапка каждого force — **только динамика**: «Управляете: Karlach [+ партия]. Режим: combat. Ход: Karlach.»
- Никаких периодических повторов статичной информации.

---

## 4. Конфигурация

Все runtime-настройки живут в едином `config.json`, читаются на старте.

```json
{
  "neuro": {
    "ws_url": "ws://localhost:8000",
    "reconnect_interval_s": 3
  },
  "ipc": {
    "dir": "<BG3ScriptExtender appdata>/BG3Neuro",
    "state_file": "bg3_to_neuro.json",
    "command_file": "neuro_to_bg3.json",
    "poll_interval_ms": 100,
    "heartbeat_interval_s": 2,
    "heartbeat_stale_s": 10
  },
  "game": {
    "name": "Baldur's Gate 3",
    "controlledPartySize": 1
  },
  "actions": {
    "result_timeout_s": 20
  },
  "dialogue": {
    "mode": "confirm"
  },
  "state": {
    "combat":     { "showQuestMarker": false },
    "dialogue":   { },
    "exploration": {
      "showQuestMarker": true,
      "maxVisibleObjects": 20,
      "objectInfo": { "visible": true, "skillRequirements": false },
      "distanceFormat": "hybrid",
      "showPosition": false
    }
  }
}
```

Поля `state`:
- `showQuestMarker`: exploration true (компас), combat false
- `objectInfo.skillRequirements`: false (без читерства)
- `distanceFormat`: `meters | region | hybrid`; hybrid — ближние ≤50м в метрах, дальние «область: имя»
- `showPosition`: false — абсолютная позиция не нужна, геометрия в дистанциях

---

## 5. Схемы действий

Все действия регистрируются как `Action` (как в SPECIFICATION.md): `name` (нижний регистр, underscore), `description` (plain text, 1–2 предложения), `schema` (JSON Schema object). Регистрация — **PERSISTENT**: все действия на старте, однажды, никакой рега/дерега (BEST_PRACTICES: "Register everything you can once at startup").

Принципы:
- Контекст даёт информацию, действия дают жесты.
- **Параметр `actor?: string`** — псевдоним контролируемого персонажа (из state §1.5/§3). Обязателен при `controlledPartySize > 1`, опускается при `party = 1` (действует активный/ходящий персонаж). Наличие задаёт единственного исполнителя; см. схему в каждом действии.
- **Полный фиксированный набор**: все **17 действий** (8 combat + 1 dialogue + 8 exploration) регистрируются **один раз на старте** и в течение сессии не меняются (никакой рега/дерега, никаких disposable). Dynamic registration на уровне whole-действия в v1 **не используется** — стабильный набор ускоряет ответы Neuro (BEST_PRACTICES: «Register everything you can once at startup»).
- Enum — полный всегда; недоступный вариант → failure с actionable message, без ресайза enum.
- **Риск фиксации** (BEST_PRACTICES: «she tends to fixate on a few of them») компенсируется тем, что state явно показывает доступные на текущий ход действия/цели, а валидатор даёт actionable failure со списком опций — Neuro фактически видит релевантный поднабор через state, а не через набор actions.

### 5.1 Боевые действия (8)

| # | Действие | Параметры | Описание |
|---|---|---|---|
| 1 | `move_to_target` | `actor?: string`, `target_id: string` | Переместиться к указанной цели |
| 2 | `attack_entity` | `actor?: string`, `target_id: string` | Атаковать указанного врага основным оружием |
| 3 | `cast_spell` | `actor?: string`, `spell_name: string`, `target_id?: string`, `coverage?: string[]`, `position?: {x, y, z}` | Использовать заклинание |
| 4 | `use_item` | `actor?: string`, `item_id: string`, `target_id?: string` | Использовать предмет из инвентаря |
| 5 | `throw` | `actor?: string`, `item_id: string`, `target_id: string` | Бросить предмет в цель (**X2: в v1 → `not_supported`**) |
| 6 | `bonus_action` | `actor?: string`, `action_type: enum` | Выполнить бонусное действие |
| 7 | `set_reaction` | `actor?: string`, `reaction_type: enum` | Выбрать реакцию на этот ход |
| 8 | `end_turn` | `actor?: string` | Завершить ход |

> **Общий `actor`** во всех 8 боевых действиях: `actor?: string` — псевдоним исполнителя (при `controlledPartySize > 1` обязателен, при `= 1` опускается). Валидация: псевдоним должен быть контролируемым персонажем; при `party = 1` действует единственный/активный. Валидатор проверяет фазу/право (чей ход) против `actor`.

Детали:
- **`move_to_target`**: schema `{ "type": "object", "required": ["target_id"], "properties": { "target_id": {"type": "string"}, "actor": {"type": "string"} } }`. Neuro видит доступные цели в state.
- **`attack_entity`**: `target_id` + `actor` (main hand всегда, без `weapon_slot` — offhand только через `bonus_action`).
- **`cast_spell`** (AoE): `actor` + `spell_name` — из state (source of truth); `coverage` (optional) — желаемый список жертв, плагин центрирует взрыв на оптимуме покрытия, failure со списком, если не всё достижимо; `position` (optional) — raw-координаты центра `{x, y, z}` (BG3SE API 3D), fallback (включается в конфиге, disabled по умолчанию). AoE-покрытие и range считает плагин — единый code path с StateSerializer.
- **`use_item`**: `actor` + предмет + цель. Питьё зелья как действие — здесь (оба пути: и `use_item`, и `bonus_action.drink_potion`).
- **`throw`**: `actor` + `item_id` + `target_id`. В схеме есть, но в v1 валидатор возвращает `not_supported` (нет публичного Osiris-вызова) — честный failure «реализуется позже», не тишина.
- **`bonus_action.action_type`** (enum полный, фиксированный):
  - `offhand_attack` — атака второй рукой (нужно offhand оружие)
  - `drink_potion` — выпить зелье (вторым темпом / бонусом)
  - `help` — помочь союзнику (освободить от хватки, дать advantage)
  - `shove` — толкнуть цель
  - `disengage` — уклониться от атак возможности
  - `dash` — дополнительное перемещение
  - `dodge` — уклонение (атаки по тебе с disadvantage)
- **`set_reaction.reaction_type`** (enum полный, фиксированный):
  - `opportunity_attack` — атака возможности
  - `shield` — реакция Shield
  - `counterspell` — контрзаклинание
  - `none` — не использовать реакцию в этом ходу

> **Валидация фазы для `bonus_action`/`set_reaction`:** эти действия требуют, чтобы ход был у контролируемого персонажа. Если ход чужой или боя нет → `wrong_phase` (Канал A, §6.5) с actionable message («Сейчас не твой ход — чей/фаза»), не `invalid_parameters`.

> Ограничение (замечено в BEST_PRACTICES): «she tends to fixate on a few of them». Компенсация — полный фикс. набор (все 17 на старте, B) + релевантный поднабор в state + actionable failure со списком опций.

### 5.2 Диалоговые действия (1)

**`select_dialogue_option`** — единственное диалоговое действие (D1). Уходить/прерывать/пропускать — обычные варианты в state (BG3 предоставляет их в списке ответов). Никаких `skip_dialogue`/`end_dialogue`.

```json
{
  "name": "select_dialogue_option",
  "description": "Выбрать один из предложенных вариантов ответа в диалоге.",
  "schema": {
    "type": "object",
    "required": ["option_index"],
    "properties": {
      "option_index": { "type": "integer", "minimum": 1 },
      "option_text":   { "type": "string" }
    }
  }
}
```

- `option_index` — **primary**: номер варианта = порядок в UI окна диалога BG3 (1-based, совпадает со стример-модом).
- `option_text` — fallback: если Neuro написала текст, но пропустила индекс, плагин матчит по тексту и подставляет индекс.
- Регистрация **PERSISTENT**: один раз на старте; неактивный диалог → failure «Сейчас нет активного диалога»; защита от гонок (диалог закрылся → failure, не отсутствующее действие).
- **Forced dialogue** (враг атакует во время диалога): диалог прерывается игрой автоматически; DecisionLoop переключает режим (combat > dialogue); `select_dialogue_option` остаётся зарегистрированным.
- **Торговля — out of scope**: «[Торговля]» — обычный вариант, но он открывает торговый экран (отдельный UI-тип, вне scope).

### 5.3 Исследовательские действия (8)

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

> **Общий `actor`** во всех 8 exploration-действиях: `actor?: string` — псевдоним исполнителя (при `controlledPartySize > 1` обязателен, при `= 1` опускается). Аналогично боевым действиям (§5.1).

Детали:
- **`interact_with`**: свободный `interaction_type` (не enum!) из state — соответствие BEST_PRACTICES (изменяющийся набор взаимодействий → свободный параметр + runtime-валидация). В state показывать доступные взаимодействия: `wooden_door (закрыта, 3м): [открыть, заламать, толкнуть]`. Несоответствие → failure с actionable message («У двери доступны: открыть, заламать, толкнуть»). Опущен → дефолт (первый/«открыть»).
- **`loot`**: отдельное действие (частый жест в BG3, Neuro заказывает явно).
- **`open_map`/`open_inventory`**: только просмотр. `open_map` → state экрана карты (локации для `travel_to`); `open_inventory` → state инвентаря (использование — через `use_item`). Экипировка/дроп/сортировка/торговля — out of scope.
- **`toggle_mode`** (X3): `target_id?` (по умолчанию активный; обязателен при партии) + `mode`. **В v1 enum — только `["normal"]`**; `"stealth"` убран (нет публичного Osiris-API переключения скрытности; вернётся после эксперимента).
- **`rest`**: `rest_type` enum [full, partial]. Neuro выбирает, сколько припасов тратить.
- **`travel_to`**: `destination` = **название региона** (human-readable, primary); `region_id?` — **опционально**, идентификатор региона для однозначности при неоднозначных названиях (валидатор сверяет: если `region_id` задан — матчим по нему, иначе по имени). State показывает соответствие: `→ локации (доступно): [Название области (id: xxx)]` с дистанцией в гибридном формате из §3.3.
- Переход в бой из исследования — автоматический (DecisionLoop), не через действия.
- UI-клики внутри map/inventory — не даются Neuro (только просмотр state).

### 5.4 Полные JSON-Schema (референс регистрации, E5)

Формат регистрации — `Action` из SPECIFICATION.md: `name`, `description`, `schema` (JSON Schema object). Все 17 — PERSISTENT, на старте (B). `actor` — в schema optional (runtime-валидация: обязателен при `controlledPartySize > 1`, см. §5.1/§5.3).

**Боевые (8):**

```json
[
  { "name": "move_to_target",
    "description": "Переместиться к указанной цели.",
    "schema": { "type": "object", "required": ["target_id"],
      "properties": {
        "target_id": { "type": "string" },
        "actor":     { "type": "string" } } } },
  { "name": "attack_entity",
    "description": "Атаковать указанного врага основным оружием.",
    "schema": { "type": "object", "required": ["target_id"],
      "properties": {
        "target_id": { "type": "string" },
        "actor":     { "type": "string" } } } },
  { "name": "cast_spell",
    "description": "Использовать заклинание; для AoE — указать target_id, coverage или position центра.",
    "schema": { "type": "object", "required": ["spell_name"],
      "properties": {
        "spell_name": { "type": "string" },
        "target_id":  { "type": "string" },
        "coverage":   { "type": "array", "items": { "type": "string" } },
        "position":   { "type": "object",
          "required": ["x", "y", "z"],
          "properties": { "x": { "type": "number" }, "y": { "type": "number" }, "z": { "type": "number" } } },
        "actor":      { "type": "string" } } } },
  { "name": "use_item",
    "description": "Использовать предмет из инвентаря (лечиться, броня, еда) на себя или указанную цель.",
    "schema": { "type": "object", "required": ["item_id"],
      "properties": {
        "item_id":   { "type": "string" },
        "target_id": { "type": "string" },
        "actor":     { "type": "string" } } } },
  { "name": "throw",
    "description": "Бросить предмет в указанную цель.",
    "schema": { "type": "object", "required": ["item_id", "target_id"],
      "properties": {
        "item_id":   { "type": "string" },
        "target_id": { "type": "string" },
        "actor":     { "type": "string" } } } },
  { "name": "bonus_action",
    "description": "Выполнить бонусное действие (offhand_attack, drink_potion, help, shove, disengage, dash, dodge).",
    "schema": { "type": "object", "required": ["action_type"],
      "properties": {
        "action_type": { "type": "string", "enum": ["offhand_attack", "drink_potion", "help", "shove", "disengage", "dash", "dodge"] },
        "target_id":   { "type": "string" },
        "actor":       { "type": "string" } } } },
  { "name": "set_reaction",
    "description": "Выбрать реакцию на этот ход (opportunity_attack, shield, counterspell, none).",
    "schema": { "type": "object", "required": ["reaction_type"],
      "properties": {
        "reaction_type": { "type": "string", "enum": ["opportunity_attack", "shield", "counterspell", "none"] },
        "actor":         { "type": "string" } } } },
  { "name": "end_turn",
    "description": "Завершить ход текущего персонажа.",
    "schema": { "type": "object", "required": [],
      "properties": { "actor": { "type": "string" } } } }
]
```

**Диалоговое (1)** — см. §5.2 (полная схема там).

**Исследовательские (8):**

```json
[
  { "name": "move_to_entity",
    "description": "Переместиться к указанной осведомлённой цели.",
    "schema": { "type": "object", "required": ["target_id"],
      "properties": { "target_id": { "type": "string" }, "actor": { "type": "string" } } } },
  { "name": "interact_with",
    "description": "Взаимодействовать с объектом одним из доступных способов (см. state).",
    "schema": { "type": "object", "required": ["target_id"],
      "properties": {
        "target_id":        { "type": "string" },
        "interaction_type": { "type": "string" },
        "actor":            { "type": "string" } } } },
  { "name": "loot",
    "description": "Собрать добычу с указанного трупа или контейнера.",
    "schema": { "type": "object", "required": ["target_id"],
      "properties": { "target_id": { "type": "string" }, "actor": { "type": "string" } } } },
  { "name": "open_map",
    "description": "Открыть карту (просмотр локаций).",
    "schema": { "type": "object", "required": [],
      "properties": { "actor": { "type": "string" } } } },
  { "name": "open_inventory",
    "description": "Открыть инвентарь (просмотр предметов).",
    "schema": { "type": "object", "required": [],
      "properties": { "actor": { "type": "string" } } } },
  { "name": "toggle_mode",
    "description": "Переключить режим персонажа (v1: normal).",
    "schema": { "type": "object", "required": ["mode"],
      "properties": {
        "mode":      { "type": "string", "enum": ["normal"] },
        "target_id": { "type": "string" },
        "actor":     { "type": "string" } } } },
  { "name": "rest",
    "description": "Отдохнуть (полный или лёгкий отдых).",
    "schema": { "type": "object", "required": ["rest_type"],
      "properties": { "rest_type": { "type": "string", "enum": ["full", "partial"] }, "actor": { "type": "string" } } } },
  { "name": "travel_to",
    "description": "Путешествовать в локацию по названию области.",
    "schema": { "type": "object", "required": ["destination"],
      "properties": {
        "destination": { "type": "string" },
        "region_id":   { "type": "string" },
        "actor":       { "type": "string" } } } }
]
```

Примечание: свободные параметры (`cast_spell.spell_name`, `interact_with.interaction_type`, `travel_to.destination`) валидируются **runtime** против state (список заклинаний / доступные взаимодействия / известные локации) → failure со списком валидных опций (BEST_PRACTICES), а не против захардкоженного enum.

---

## 6. Слой исполнения действий (Action Execution Layer)

### 6.1 Цикл выполнения

1. C# валидирует schema + существование цели + precheck'и по state (`IsInCombat`, `CanAllPartiesLongRest`, наличие заклинания в `SpellBook`) → пишет `action_<id>.json`.
2. Server Lua poll: `Ext.Timer.WaitForRealtime(100–250ms)` → читает → диспатч → сразу пишет `result_<id>.json` (`Ext.Json.Stringify` + `Ext.IO.SaveFile`): `{success, error_code, error_detail}`.
3. Долгие действия (движение/каст) → промежуточный `success:true, running:true` + финал через `RegisterListener`-событие (`CastedSpell`, `CharacterMoveToCancelled`) — никогда не блокировать поток через `WaitFor`.
4. Таймаут: **5 s** ACK со стороны C#; отсутствие result-файла после N опросов = ошибка по словарю (§6.5). Ожидания игрового эффекта по таймеру в Lua — нет.
5. Однопоточность BG3SE Lua подтверждена → команды сериализуются: один in-flight action на контекст, очередь в C# и Lua.

### 6.2 Ключевые BG3SE API (выжимка research)

| Жест | Основной вызов | Надёжность |
|---|---|---|
| Движение | `Osi.CharacterMoveTo(character, target, speed, event, moveID)` / `Osi.CharacterMoveToPosition(...)` | ✔ |
| Телепорт-хелпер | `Osi.TeleportTo` / `Osi.TeleportToPosition` | ✔ |
| Каст/атака игроков | `Ext.System.ServerCastRequest.OsirisCastRequests` (**FromClient** — рельсы пайплайна, AP/кулдауны честно) | ⚠→✔ |
| Каст fallback | `Osi.UseSpell` / `Osi.UseSpellAtPosition` | ⚠ |
| Атака (NPC/fallback) | `Osi.Attack(character, target, alwaysHit)` — one-shot, без учёта ресурсов | ⚠ |
| Предмет | `Osi.Use(character, item, useItem, isInteraction, event)`; экипировка `Osi.Equip` | ✔ |
| Старт диалога | `Osi.CharacterMoveToAndTalk` / `Osi.StartDialog_Internal` | ✔ |
| Выбор варианта диалога | **нет публичной функции** → §7 (X1) | ✘ |
| Отдых | `Osi.RequestLongRest(initiator, isForced)` (+ `RequestLongRestConfirmed`); гейт `Osi.CanAllPartiesLongRest` | ✔ |
| Стелс | **нет публичной функции** → §5.3 (X3) | ✘ |
| Лут | `Osi.Pickup`, `Osi.OpenCharacterLootUI`, `Osi.MoveAllLootableItemsTo`, `Osi.ToInventory` | ✔ |
| Ход/бой | События `TurnStarted/TurnEnded/CombatStarted/CombatEnded/CombatRoundStarted`, `Osi.CombatGetActiveEntity`, `Osi.EndTurn` | ✔ |
| Список заклинаний | `Ext.Entity.Get(char).SpellBook.Spells` + `Ext.Stats.GetStats("SpellData")` + `Ext.Stats.Get(name)` (UseCosts/SpellType/Range) | ✔ |
| Инвентарь | `Ext.Entity.Get(char).Inventory` + `Osi.IterateInventory`, `Osi.GetGold` | ✔ |
| Порядок ходов | `Ext.Entity.Get(combatGuid).TurnOrder` (`EocCombatTurnOrderComponent.Groups/Groups2/field_40`=round) | ✔ |

Подробный каталог с сигнатурами и источниками: `.scratch/bg3-neuro-integration/research/bg3se-lua-action-api.md`.

### 6.3 Работа с ресурсами (AP/кулдауны)

- Для игроков — `FromClient` касты (нативная обработка ресурсов), без ручного жонглирования AP.
- Утилиты: `Osi.CharacterResetCooldowns(char)`, `Osi.GetActionResourceValuePersonal(char, resourceName, resourceLevel)`, `Ext.Entity.Get(c).SpellBookCooldowns`.

### 6.4 Атаки и заклинания — единый пайплайн

Базовые атаки игроков (`attack_entity`) и `cast_spell` исполняются через `Ext.System.ServerCastRequest.OsirisCastRequests` (честно с AP/кулдаунами). `Osi.Attack` (one-shot, без ресурсов) — только для врагов/NPC/fallback. `spell_name` — prototype-имя (`Ext.Stats.Get`), нормализация в StateExtractor (X5).

### 6.5 Словарь error_code (два канала)

**Принцип (тикет 08, review D):** `action/result` уходит Neuro **сразу после валидации** (R6, §8) — до исполнения в игре. Поэтому коды **валидации** (Канал A) физически доходят до Neuro через `action/result`, а **провалы исполнения** (Канал B) — нет: сообщать о них нужно **через следующий state + context**, а не поздним `action/result` (server отбросит late result, окно ~20s).

**Канал A — через `action/result` (Neuro видит сразу; валидация до игры):**

| Код | Когда |
|---|---|
| `target_missing` | Цель не существует/не найдена |
| `not_in_combat` | Действие требует боя, боя нет |
| `no_spell` | Заклинание недоступно (нет в SpellBook / на кулдауне / нет ресурсов) |
| `no_camp` | Нельзя отдохнуть (нет лагеря/валидной точки) |
| `not_supported` | Есть слот в схеме, исполнение позже (`throw`) |
| `target_not_in_range` / `invalid_parameters` | Валидация параметров провалена |
| `wrong_phase` | Действие требует хода контролируемого персонажа (`bonus_action`, `set_reaction`), а сейчас чужой ход / не бой |
| `dialogue_closed` | `select_dialogue_option` без активного диалога |
| `mod_unavailable` | Мод недоступен **на момент валидации** (heartbeat stale) — C# отвечает failure, не гоняя игру |

**Канал B — через следующий state + context (Neuro видит как «правду игры»; исполнение уже ушло в игру):**

| Код | Когда |
|---|---|
| `action_failed` | Валидация прошла, но в игре действие не вышло (каст провалился, движение заблокировано) — детали в `error_detail` + следующий state |
| `mod_unavailable` | Мод упал **во время исполнения** (heartbeat stale после отправки успешного результата) — re-init по R7, картина через state |

> **Тайминг `mod_unavailable`:** до валидации → Канал A (немедленный failure в `action/result`), во время исполнения → Канал B (не гоняем поздний `action/result`). Определение по положению относительно валидации, не по коду. **Не отправлять поздний `action/result` для кодов Канала B** — он будет отброшен сервером; целостность картины Neuro восстанавливается следующим state/force (§1.6 диалог/боевые триггеры).

---

## 7. Диалог: как исполняется `select_dialogue_option` (X1)

Публичной Osiris-функции выбора варианта **нет** (research §7.2). Исполнение — **client-подсветка + клик** через единый реализатор (Neuro видит одно действие и единый формат `{success, error_code, error_detail}`):

- **Реализация `ClientAutoselectExecutor`**: client-контекст Lua находит элемент варианта в окне диалога по `option_index` (= порядок UI), **подсвечивает его и сам кликает** — человек ничего не жмёт. (Режим `confirm` из ранней версии схлопнут в это — разница между «подсветка + ручной Enter» и «autoselect» исчезла.)
- Переключение — флаг `dialogue.mode` в `config.json` (значение `confirm` сохранено как алиас, поведение единое).
- Если client-скрипт недоступен (нет клиентского контекста / мод серверный) → **откат на `not_supported` + warning в лог** — не отправлять Neuro в цикл без канала.
```
select_dialogue_option (schema из §5.2)
        │
        ▼
Action Layer: валидация option_index → диспатч
        │
        ▼
ClientAutoselectExecutor
      • client Lua находит элемент по option_index, подсвечивает, кликает
      • (отдельная клавиша человеку не требуется)
```

---

## 8. Устойчивость и обработка ошибок (Error Resilience)

- **R1 — Реконнект Neuro WS**: после восстановления → повторный `startup` + перерегистрация действий. Обрабатываем `actions/reregister_all` (PROPOSALS.md): отвечаем регистрацией всего персистентного (фикс.) набора.
- **R2 — Перезапуск BG3SE Mod**: мод пишет `heartbeat.json` каждые **2 s**; C# считает heartbeat stale при возрасте **> 10 s** → статус «мод недоступен», ждёт восстановления; на незавершённое действие → failure `mod_unavailable`; после восстановления — re-init (мод пересоздаёт polling). Порог 10 s выбирает устойчивость к паузам движка (загрузка локаций, катсцены), а не скорость детекта — в turn-based игре задержка детекции безвредна. 5s-таймаут — дополнительный сигнал.
- **R3 — Race force + самоакция**: диспатчим любые действия Neuro всегда (README: слушать безотносительно force). Валидация C# отклоняет невозможное actionable failure. Уточнено (review C): force — push контекста, заменяем без очереди; новый force поверх активного **отменяет и заменяет** (SPEC §Force Actions), безопасно т.к. каждый force несёт полный свежий state.
- **R4 — Disposable**: никаких disposable-действий, всё PERSISTENT. Невалидный повтор → консистентный actionable failure («диалог уже закрыт»).
- **R5 — Замена force**: force заменяем идемпотентно (новый force — новый push, см. R3).
- **R6 — 20s timeout**: двухэтапно — `action/result` success сразу после валидации C# (до выполнения в игре, <20s); фактический исход (провал каста) Neuro видит из следующего state. Просроченных result не бывает.
- **R7 — Полный краш игры**: рестарт игры = полный re-init через общий путь реконнекта (тот же что R1): повторный `startup` (если требуется), переустановка файлового режима, сброс decision loop, свежая force с новым state. WS Neuro либо уже переподключён, либо ждём.
- **R8 — Невалидные данные**: невалидный JSON / неизвестная команда → логируем и пропускаем (без ответа, чтобы не засорять); неизвестное/невалидное действие или неверные параметры → failure c actionable message + список валидных опций (BEST_PRACTICES).

---

## 9. Тестирование (Testing Architecture)

### 9.1 Randy

Randy (Random Dot Range) — простой WS-сервер, имитирующий Neuro: `ws://localhost:8000`, HTTP POST `localhost:1337` для ручной эмуляции. Ограничения Randy: не шлёт невалидные данные, вызывает только forced actions, отвечает мгновенно (нет 20s-таймаутов).

- Используем **как есть**, не форкаем: базовый e2e-цикл (register → force → action → result) + POST для ручных сценариев.
- «Плохие» кейсы — unit/интеграционные, не Randy.

### 9.2 Unit-тесты

Минимальный набор модулей:
- **StateSerializer** — мок-данные BG3 → проверка формата
- **ActionRouter** — валидация JSON schema, dispatch по name
- **IpcClient** — запись/чтение action_/result_ (с фейковыми файлами)
- **ConfigLoader** — config.json → структуры с дефолтами
- **ErrorMapper** — error_code → actionable message
- **CoverageAuto** — автомат «range/AoE coverage» — **отдельный чистый модуль** с собственными unit-тестами (единый code path со StateSerializer; это основной кусок логики)

Lua-часть (BG3SE мод) против моков `Ext.*` — лёгкий smoke на стенде, **не в CI**.

### 9.3 Интеграционные тесты

- **A в CI**: C#-конвейер без игры — mock-файлы BG3SE (action_/result_) + фейковый WS.
- **B в CI**: C# ↔ Randy (реальный WS `ws://localhost:8000`) + mock-файлы BG3SE.
- **C (ручной регресс)**: реальная Neuro — перед выпуском, не в CI.

### 9.4 Smoke-тест

- Авто в CI: фейковый BG3SE (mock-файлы) — сценарий «видит поле боя → attack_entity → результат».
- **Обязательный ручной тест на реальной игре** (тестовая сцена с 1 врагом) перед релизом — главный доверитель.

### 9.5 Набор сценариев

- Автотесты на **симулированных state** покрывают логику (formatter/валидатор/coverage/router) по-максимуму.
- Все сценарии — в **ручной чек-лист регрессии** на реальной игре:
  - Бой: 1v1, 1vмного, AoE, лечение
  - Диалог: простой выбор, квест
  - Исследование: перемещение, взаимодействие
- Покупка — out of scope, из чек-листа исключена.

---

## 10. Out of scope (v1)

- Голосовой чат (Voice Chat API)
- Мультиплеер — поддержка других игроков в сессии
- Реалтайм-управление камерой — Neuro не управляет камерой напрямую
- Оптимизация производительности
- Упаковка и деплой
- Торговля (покупка/продажа) — отдельный UI-экран вне диалоговых вариантов
- `throw` (бросок предметов) — `not_supported` в v1 (нет публичного API)
- Стелс-режим `"stealth"` для `toggle_mode` — нет публичного API

**Post-v1 эксперименты** (не часть текущей спецификации): stealth-status experiment (для `"stealth"` в `toggle_mode`).

---

## 11. Источники

- Wayfinder-карта: `.scratch/bg3-neuro-integration/map.md`
- Тикеты: `.scratch/bg3-neuro-integration/issues/01..09`
- Research IPC: `.scratch/bg3-neuro-integration/research/ipc-named-pipes.md`
- Research BG3SE API: `.scratch/bg3-neuro-integration/research/bg3se-lua-action-api.md`
- Neuro SDK: `neuro-sdk/neuro-sdk/API/SPECIFICATION.md`, `API/BEST_PRACTICES.md`, `API/README.md`, `API/PROPOSALS.md`
- Randy: `neuro-sdk/neuro-sdk/Randy/README.md`