# 02 — Communication delivery: per-agent actions and results

Type: research
Status: resolved (2026-09-23)
Sprint: bg3-neuro-multi-agent
Opened: 2026-09-23

## Question

How do two Neuro agents deliver actions and receive results over the current single-WS + single-file-bridge architecture, without breaking the single-slot file bridge?

Current facts (bench-verified):
- Incoming WS `action` carries only `{id, name, data}` (`NeuroWebSocketClient.cs:257-278`); `SessionInfo.CharacterId` (`:13`) is logged but never routes. No `agent_id` in `action/result` (`Messages.cs:30-42`).
- One command file `neuro_to_bg3.json` (`IpcPaths.cs:21-28`); parallel injects clobber each other (AGENTS.md rule, 2026-09-19 bench). One state file `bg3_to_neuro.json`.
- `DecisionLoop.OnActionRequested` dispatches fire-and-forget (`DecisionLoop.cs:209-227`), no queue/in-flight gate; single `_lastForcedContent` (`:31`).
- Mod polls only the single command file (`BG3Neuro.lua:86-98, 6672-6696`) and clears it after read (`clearInFlight`, `:6662`).

Design candidates to evaluate for FEASIBILITY against the file bridge and WS protocol:

1. **Transport `agent_id` into action data** (extend `{id,name,data}` with `data.agent_id`) and keep a single WS connection — the external Neuro server multiplexes two agents onto one socket (is that real, or does each agent own a socket?). Is `SessionInfo` able to carry two identities?
2. **Per-agent command/result files** (`neuro_to_bg3_<char>.json`, `result_<id>_<char>.json`) vs keeping the shared file with a serialization lock. The mod's file name for commands is hardcoded (`IpcPaths.CommandFile`) — changing it is a mod+router change, not just config.
3. **A queue** to serialize actions from both agents (single slot stays, ordering by turn); what happens to the second agent while the first's action is `running:true`?
4. **Force channel**: `DecisionLoop` can force only once (`_lastForcedContent`); can two agents share one force stream, or does each need its own state push? State is one file — split leads back to ticket 03 (state ownership).

## Constraints (do not rediscover — already proven)

- File bridge is single-slot; parallel file writes clobber (AGENTS.md:20).
- Mod reads only ONE hardcoded command filename; `action_<id>.json` is a trace copy, not read (spec `BG3_Neuro_Spec.md:118-119`, `DEVELOPER.md:80-81`).
- WS send is serialized by `_sendLock` (`NeuroWebSocketClient.cs:47,310-327`) — that serializes frames, not execution.

## Deliverable

A recommended delivery topology (which candidate, or combination), with the exact files/lines to change in C# and Lua to carry per-agent identity end-to-end, and a stated answer whether one WS connection can multiplex two agents or we need N sockets (and whether N sockets even fit the external Neuro server contract).

## Answer

**Вердикт 1 — сокеты: N отдельных WS-соединений, по одному на агента; мультиплексировать двух агентов в один socket нельзя.**

- Протокол Neuro назначает соединению ровно одного персонажа при старте: `startup.data.session.characterId` ∈ `{neuro, evil}` с `displayName` (`SPECIFICATION.md:198-216`); сервер выбирает character по своему конфигу при подключении (`VOICE_CHAT.md:137`: "which character a connection talks to is backend configuration"). Один socket = одна развилка персонаж/агент.
- Сервер **нативно рассчитан на несколько одновременных подключений**: `BEST_PRACTICES.md:22` — "Action names are scoped to the character and shared with any other integration connected at the same time" (регистрации от нескольких integration живут вместе), а `VOICE_CHAT.md:135-138` описывает как официальный сценарий «Neuro и Evil в одном lobby» (каждый через «each game process connects on behalf of its own character»). То есть N sockets укладывается в серверный контракт прямо.
- Единственный серверный запрет — не «сколько sockets», а «one action force at a time» (`SPECIFICATION.md:139-140`, `Unity/USAGE.md:165`): это ограничение **на канал**, и оно же даёт нам разделение: у каждого агента свой force-канал за счёт своего socket (вопрос 4 → «каждый агент форсит свой канал»).

Наш `NeuroWebSocketClient` уже устроен как **один инстанс = одно соединение** (поля `_url/_game/_actions/_reconnectInterval` в конструкторе, `:52-58`; свой `_ws`/`_sendLock`/`_cts`; `SessionInfo.CharacterId` уже читается в `HandleStartupAck`, `:246-254`). Один экземпляр = один агент; второй агент = второй экземпляр (тот же/свой URL). Никакого мультиплекса в классе.

**Вердикт 2 — файловый мост: кандидат 3 (очередь/сериализация) в чистом виде; per-agent файлы (кандидат 2) не нужны и вредны; кандидат 1 отклонён вместе с мультиплексом.**

| | Запись команды | Запись результата | Мод |
| --- | --- | --- | --- |
| Cейчас | C# → `neuro_to_bg3.json` (`IpcPaths.WriteCommandFile:48-58`) | Lua → `result_<id>.json` (`BG3Neuro.lua:124`) | читает **один** файл `NEURO_TO_BG3_FILE` (`:36, 89`), поллит раз в `ACTION_POLL_MS` (`:33`), очищает сразу после чтения (`clearInFlight:6662`) |
| Два агента | оба C#-агента пишут **в один и тот же файл** — нужен лок/очередь | `result_<id>.json` уже уникален по id — **не конфликтует** | мод остаётся **однопотоковым single-slot**: он и так исполняет одно действие в момент — это его догмат; менять его НЕ нужно |

Вывод по кандидатам:
- **Кандидат 1 (agent_id в `data.action`) — не для моста, а для различения.** В `action` нейросервера нет агента — но агент известен по **экземпляру клиента/сокета**, из которого пришло событие (`Program.cs` подписывается на `ActionRequested` каждого `NeuroWebSocketClient` отдельно, `:71`). `agent_id` не нужно глотать в JSON — identity живёт в C#, а мода агент не интересует (ему нужен `actor` из `data`/`actingChar`, который уже парти-скоуп). `SessionInfo` не «нести двух identities» — он один на соединение по построению.
- **Кандидат 2 (per-agent файлы `neuro_to_bg3_<char>.json`)** — отклонён: мод читает один жёстко зашитый файл (`:36`); разносить поллинг по N файлам = менять мод, а выгоды ноль — движок и так исполняет одно действие за раз. Два файла не дают параллелизма исполнения, только риск гонок на стороне игры.
- **Кандидат 3 (очередь)** — **это и есть модель**: C#-сторона сериализует записи в `neuro_to_bg3.json` одним потоком-писателем. Второй агент «ждёт слота» естественно: `DecisionLoop.WaitForExecutionResultAsync` (`:232-254`) уже ждёт `result_<id>.json` (до таймаута `result_timeout_s`); пока первый агент `running:true`/без результата, второй на та же очередь не пишет. Это превращает бенч-правило «инжекти строго серийно» в код. Одно «действие в пути» в файле — ровно как single-party сегодня.

**Вердикт 3 — результат/атрибуция.** `result_<id>.json` уникален по id (у каждого агента свой `NeuroWebSocketClient` и свой id-поток). Соответствие «id → какому агенту вернуть» хранится на C#: у `DecisionLoop` есть свой `_neuro` (`:24`) и `SendResultAsync` идёт в конкретный клиент (`:221,226`). Два `DecisionLoop` ≠ один общий — у каждого собственный `_neuro` и `_lastForcedContent` (`:31`), поэтому `_lastForcedContent` не «похарят» друг друга (вопрос 4).

**Вердикт 4 — force.** Один force-канал на агента: у каждого `DecisionLoop` свой `SendForceAsync` на свой `NeuroWebSocketClient`. Серверное «one force at a time» соблюдается в рамках канала — а межканального запрета нет. `_lastForcedContent` дедупликация — per-agent, не глобальная.

### Итоговая топология (рекомендация)

```
Neuro #1 (characterId=neuro) ──ws──▶ NeuroWebSocketClient#1 ──▶ DecisionLoop#1 ──▶ ActionRouter(request) ─▶ IpcPaths (один writer-lock) ─▶ neuro_to_bg3.json ─▶ BG3Neuro.lua (однопоточный poll)
Neuro #2 (characterId=evil)  ──ws──▶ NeuroWebSocketClient#2 ──▶ DecisionLoop#2 ──▶ (тот же) ActionRouter ──🔒 serialized──┘                                          │
                                                                                                                                           result_<id>.json (per id) ◀──┘
```
- Два независимых `NeuroWebSocketClient` (агент = экземпляр).
- Один общий `ActionRouter` (валидация) + **один поток-писатель** для `IpcPaths.WriteCommandFile` (SemaphoreSlim или однопоточная очередь; место — `Program.cs` / `DecisionLoop` общий writer).
- Мод **не меняется** для доставки: один `neuro_to_bg3.json`, один poll, one-slot. `pollActions:6672-6696` без правок.
- Для «кто каким персонажем владеет» — правки вне доставки, см. тикет 03 (`agent→character` map, `actor` уже переносится в `data`).

### Точные изменения (если пойдём в имплементацию)

C#:
- `Program.cs:46-54`: создать **два** `NeuroWebSocketClient` (+ второй `DecisionLoop`), подписки на `SessionStarted`/`ActionRequested`/`ConnectionStateChanged` per agent; `CharacterId` уже различает агентов (`NeuroWebSocketClient.cs:246-254`).
- `IpcPaths.WriteCommandFile` (`:48-58`): обернуть в сериализацию (SemaphoreSlim/очередь). Ничего не менять в сигнатурах: `data` уже JSON-string, команда одна.
- `DecisionLoop.DispatchAsync` (`:215-227`): уже per-agent по `_neuro`; обеспечить, чтобы validation-запись и ожидание результата шли через общий writer-lock (или один писатель в Program.cs). `_lastForcedContent` остаётся per-instance.
- `Messages.cs/`ActionRequestedEventArgs`: необязательно добавить `AgentId` — идентичность известна по подписке/аргументу события.

Lua / `mod/BG3Neuro/BG3Neuro.lua`:
- **Изменений не требуется** для доставки (мост остаётся single-slot, мод и не должен знать про 2 агентов). Персонаж действия уже гейтится самим модом по `actor`/`actingChar` — разделение персонажей это тикет 03.

Источники: `neuro-sdk/API/SPECIFICATION.md:198-240` (startup/characterId, one force at a time), `BEST_PRACTICES.md:22,36` (несколько integrations одновременно, force per channel), `VOICE_CHAT.md:135-138` (Neuro+Evil в одном lobby — каждый через свой connection), `Unity/USAGE.md:165`, `NeuroWebSocketClient.cs:34-58,238-254`, `DecisionLoop.cs:24-31,209-254`, `IpcPaths.cs:21-58`, `BG3Neuro.lua:33-37,86-130,6662-6696`.