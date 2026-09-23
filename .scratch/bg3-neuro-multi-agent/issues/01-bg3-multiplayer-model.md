# 01 — BG3 multiplayer model: what the engine exposes in a co-op session

Type: research
Status: resolved (2026-09-23)
Sprint: bg3-neuro-multi-agent
Opened: 2026-09-23

## Question

Can a BG3 session hold two human players AND two Neuro-driven characters at once, with each Neuro seeing only "its own" character's frame? What does the engine expose per player in such a session:

- Host/guest process model: is one `bg3.exe` handling both Neuro characters (local co-op, `controlledPartySize`-style) or do we need two processes (one per Neuro)? Current mod is two-half (server Lua + client Lua via `BootstrapClient.lua`); what breaks when a *third* actor (human) is mixed in?
- How are "players" identified at runtime: `EocPlayer` / reserved user ids (`{1,2,3,4,0,256,65536}` in `currentCharacters()`, `BG3Neuro.lua:642-654`) — do human players occupy distinct ids from our controlled set? Can the mod tell "this id is a human, this id is Neuro's character"?
- Turn semantics per player: `TurnStarted`/`TurnEnded` — do they fire per-entity with the player's identity, or per-team? Current `actingChar` is one global latch (`BG3Neuro.lua:450, 505-517`); what does the engine say when TWO party members are in the same shared-turn window (`CanActInCombat`, `activeTurnEntities`)?
- `Osi.IsEnemy`/`IsAlly(partyRef, g)` (`CONTEXT.md` hostility truth) — is `partyRef` still resolvable when the "party" is split between a human and Neuro's character?
- Client context (`BootstrapClient.lua` — dialogue click, waypoint UI, rest HotBar click): is one client context per PROCESS or per player? Would a second Neuro character need its own client context in the same process?

## Context

All followups 01–28 resolved; this sprint asks whether the architecture's single-agent assumption (`Program.cs:46-54`, one WS client, one `actingChar` latch, one-file bridge) can grow to two agents. This ticket grounds the question in what BG3/BG3SE actually expose. See sprint `map.md` for the baseline.

## Sources to check

- BG3SE Osi symbol dump (`.scratch/bg3-neuro-followups/research/08-enemies-hostility-relation-api.md` §Sources) — `Osi.GetCurrentCharacter`, reserved user ids, `EocPlayer`.
- `mod/BG3Neuro/BG3Neuro.lua` `currentCharacters()` (`:642`), `resolveActingCharacter` (`:771`), `CanActInCombat`/`activeTurnEntities` (`:1821`, `:4611`).
- `neuro-sdk/API/SPECIFICATION.md` — startup/session `{sessionId, characterId, displayName}`; VOICE_CHAT.md mentions "each game process connects on behalf of its own character in a local/co-op session" — the only multiplayer-ish statement found.
- `.scratch/bg3-neuro-dialogue-click/` research — local co-op = two processes (server + client).

## Deliverable

A table "engine fact → what a 2-Neuro setup needs → feasible/blocked", plus a verdict on which process model (one process two characters vs two processes) is viable without engine internals.

## Answer

**Вердикт: один host-процесс держит двух Neuro. Два процесса игры НЕ нужны и не решают ничего.** Оба Neuro-персонажа — обычные партийные члены той же party; server-Lua хоста видит и клиентом управляет всеми сущностями партии безотносительно того, сидит ли за аватаром человек или нейро. Все действия идут через уже существующие server-side API. Настоящие блокеры двух независимых агентов — не движок, а наш коммуникационный/state-слой (тикеты 02, 03).

| Engine fact (source) | Что нужно для 2 Neuro + N человек | Feasible |
| --- | --- | --- |
| **Host = единственный server-контекст.** Server-Lua живёт в host-процессе; она управляет ВСЕМИ сущностями партии (двигает, кастует, читает TurnBased) — это и есть текущий mod. Гости (client-half) не имеют своих server-миров (`Osi` у них нет). | Обе Neuro-части (оба «своих» персонажа) видимы и управляемы из серверного Lua хоста — как сейчас управляется ими один персонаж. | ✅ feasible (это уже так для 1 Neuro; client-half остаётся чисто UI-исполнителем, см. ниже) |
| **Двухпроцессная модель — только local co-op / guest-машины.** local co-op (split-screen) = 2 процесса на одной машине (server+client), гости по сети = отдельные клиентские процессы. Ни один из них не даёт второй server-мир. | Второй процесс дал бы второй server-Lua, но тот НЕ видит сцену хоста целиком и не может дублировать её — только добавит второй UI-контекст. | ❌ blocked — процесс игры не масштабируется по числу Neuro |
| **`EocPlayer`/reserved user ids: `Osi.GetCurrentCharacter(user)`, `GetReservedUserID(character)`, `AssignToUser(userID, character)`, `GetUserProfileID(userId)`, `GetUserName(userId)`.** В `currentCharacters()` (`BG3Neuro.lua:642-654`) перебираются `{1,2,3,4,0,256,65536}`. | Для 2 Neuro не нужно резервировать дополнительных реальных клиентов: каждый Neuro-персонаж — просто партийный member. Свой reserved user id он получает/не получает — движку всё равно, мод ходит по guid. | ✅ feasible (резорвируемые id никому не должны «мешать» — но нам и не нужны) |
| **Отличимость «человек vs Neuro»: Магазин:** есть `IsPlayer(character)`, а различение *прямого* управления даёт **`ClientControlComponent`** (маркер «этого персонажа сейчас ведёт клиент-человек») + `UserReservedForComponent.UserID` — ровно как Brawl в `brawl_State.lua:497-528` (`Ext.Entity.GetAllEntitiesWithComponent("ClientControl")` → `entity.UserReservedFor.UserID`). | Правило: сила/действия — за server Lua; человеку принадлежит `ClientControl` (UI-клики), Neuro — всё остальное время. Мод может отличать: у Neuro-персонажа ClientControl отсутствует → его действия исполняет мод. | ✅ feasible (движок не знает «нейро», но мод сам помечает свои персонажи по `agent→character` — тикет 03) |
| **Turn semantics per entity, не per player:** `TurnStarted`/`TurnEnded` fire c guid **сущности**, не юзера. `TurnBased` компонент (`IsActiveCombatTurn`, `CanActInCombat`) — per-entity (`BG3Neuro.lua:895-899`); shared-turn уже работает через `activeTurnEntities()` (`:1821`) + `requestEngineEndTurn` переводит ход за всех соактивных (`:1850-1858`). | Латч `actingChar` (`:450,505-517`) один глобальный — но два Neuro-персонажа в shared-window видны движком как два `IsActiveCombatTurn` member'а; какой агент какой guid ведёт — переложим на per-agent «owned character» (тикет 03), не ломая turn-. | ✅ feasible (движок не навязывает «один actor», навязка — наша) |
| **Hostility (`IsEnemy`/`IsAlly`) — про пару guid, не про контейнеры:** `partyRefs` = любые партийные чистые guid (`BG3Neuro.lua:2444-2457`), truth определяется по паре сущностей (avoid контейнера вражеских). `_G` per character не связан с agent-ом. | Для второго Neuro просто нужен свой `partyRef` (его партийный guid) — та же формула, никаких новых движковых знаний. | ✅ feasible |
| **Client context — один на процесс:** `Ext.UI`, диалоговый клик, rest-кнопка живут в client-Lua одного процесса (host). Второй процесс (guest/local co-op) дал бы второй UI-контекст, но диалоги/rest глобально один на сцену. | 2 Neuro в одном host-процессе делят ОДИН client-контекст: клик по диалогу/rest идёт через него. Несколько одновременных клиентских кликов невозможны и не нужны (диалог один). | ✅ feasible (сериализуется в тикете 02; client остаётся общим «один на процесс») |
| **`GetMultiplayerCharacter(character)`, `CombatGetInvolvedPlayer(c, idx)`** — движок знает «кооперативного» перса и «людей в бою по индексу». | Не обязательны; могут помочь валидировать «кто из людей в битве» — но мод и так читает всё через entity API. | ✅ feasible (не требуется) |

### Выводы по тикету

1. **Процесс игры: один (`host`), client-half один на тот же процесс.** «Два Neuro» не означает «два процесса игры». Двух-процессная модель (local co-op / сетевые гости) не даёт второго server-мира и не нужна.
2. **Два «слота агента» — это коммуникация, не движок.** В SDK есть `characterId` (`neuro`/`evil`, `SPECIFICATION.md:215`) — нативный маркер двух близнецов; приложение может открыть два WS-соединения (два `NeuroWebSocketClient`) и получить у каждого свой `session.characterId` (`NeuroWebSocketClient.cs:246-254`) — это и есть «агент №1 / агент №2» (тикет 02).
3. **Turn-движок и hostility одинаковы для человека и Neuro** — обе оси «кто чей» решаются на нашей стороне (тикет 03), не движком.
4. **Единственный общий на процесс ресурс** — client-контекст (UI-клики: диалог/rest/waypoint). Он сериализуется, как и файловый мост (тикет 02).

**Открыто для тикета 02**: авторизация действий по `agent_id` (два WS = два `characterId`), доставка действий/результатов через single-slot файловый мост (очередь/per-agent файлы), сериализация клиентских кликов.
**Открыто для тикета 03**: `agent → character` mapping, per-agent `actingPos`/`distance_reference`, per-agent turn frame в общем shared-window.

Артефакты фактов: `.scratch/bg3-neuro-followups/research/08-enemies-hostility-relation-api.md` (hostility truth), `.scratch/bg3-neuro-dialogue-click/` (client-only UI/диалог, local-coop = процессы), `brawl_State.lua:497-528` (ClientControl ≠ человеческое владение), `neuro-sdk/API/SPECIFICATION.md:198-240` (startup/session, actions/force).