# 01 — Architecture Overview

Type: grilling
Status: resolved
Blocked by: —
Depended by: 02, 03, 04, 05, 06, 07, 08, 09

## Answer

Architecture определена. (Резолвено в живом диалоге.)

### 1. Модули

**BG3SE Mod (Lua)** — dumb, без логики решений:
- `StateExtractor` — подписка на события BG3, извлечение состояния → JSON → файл `bg3_to_neuro.json`
- `ActionExecutor` — приём команд из файла `neuro_to_bg3.json`, вызов `Ext/Osi` API
- `IpcFileHandler` — работа с файлами (`Ext.IO.SaveFile/LoadFile`, `Ext.Json`, polling `Ext.Timer.WaitForRealtime`)

**C# Standalone Process** — вся логика Neuro-взаимодействия (решение в C#):
- `NeuroWebSocketClient` — WebSocket к Neuro: реконнект, startup, actions/register, actions/force, action/result
- `IpcClient` — файловый IPC: FileSystemWatcher на чтение, запись команд (JSON)
- `StateSerializer` — JSON состояния BG3 → Markdown контекст для Neuro
- `ActionRouter` — валидация JSON от Neuro (name→entity_id, schema), обычный failure → маршрутизация к ActionExecutor
- `DecisionLoop` — оркестрация: событие → context/force → валидация → execute → result; владеет правилами "когда force"

### 2. Потоки данных

**BG3 → Neuro:**
Событие в BG3 → `StateExtractor` → JSON → `bg3_to_neuro.json` → `IpcClient` (FileSystemWatcher) → `StateSerializer` (JSON→Markdown) → `NeuroWebSocketClient` (context или state в force)

**Neuro → BG3:**
Neuro decision → `ActionRouter` (валидация, alias→id) → `IpcClient` (запись JSON) → `neuro_to_bg3.json` → `IpcFileHandler` → `ActionExecutor` → `Ext/Osi` API → результат → обратно через состояние

### 3. Жизненный цикл

- **Запуск C#**: читает `config.json` → стартует `IpcClient` (файловый) → `NeuroWebSocketClient.Connect()` → при коннекте: `startup` + `actions/register`
- **Запуск BG3SE**: мод создаёт файлы IPC, подписывается на события, шлёт первое состояние (SessionLoaded)
- **Реконнект WS**: `NeuroWebSocketClient` автореконнект (interval ~3s) → после open: re-send `startup` + re-register actions (BEST_PRACTICES)
- **Реконнект игры/мода**: мод при старте пересоздаёт файлы; при отсутствии new state файла C# ждёт
- **Ошибка/паника мода**: C# логирует, ждёт файл-сердцебиение

### 4. Конфигурация (`config.json`)

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
  }
}
```

### Ключевые специфичные решения

- **Решение-в-C#**: BG3SE — dumb. Вся логика "когда слать force/context" живёт в C# (тестируемо).
- **Псевдонимы сущностей**: контекст содержит таблицу id↔name; Neuro работает с короткими именами (`goblin_1`), `ActionRouter` переводит в entity_id.
- **`controlledPartySize` (1..4)**: настройка числа контролируемых персонажей. State показывает всех; текущий ходящий определяется инициативой. Параметр `actor` в схемах действий при >1.
- **Force + state**: каждый force несёт свежий markdown state (`ephemeral_context: true` per BEST_PRACTICES для bulky state каждый ход); редкие context — для правил/задач (silent=true), редко.

### 1.6 Политика force (DecisionLoop) — уточнено в тикете 01 (review C)

Триггеры: **combat** — старт хода контролируемого, выход из боя; **dialogue** — DialogStarted; **exploration** — SessionLoaded/выход из боя/смена режима + timeout-then-force для открытых периодов (BEST_PRACTICES). **Priority: всегда `low`** (BG3 пошаговая; medium/high/critical в v1 не используются — нет хард-реалтайма). **Замена, не очередь**: новый force поверх активного отменяет и заменяет (SPEC §Force Actions), безопасно т.к. каждый force несёт полное свежее состояние. Сохранена дисциплина «force только на точках решения, где игра ждёт Neuro».

### Замечание

Q5-IPC корректируется research-фактом: не named pipe, а файловый IPC. Модуль `NamedPipe` в вопросе — устарел; актуально: `IpcFileHandler` + `IpcClient`.
