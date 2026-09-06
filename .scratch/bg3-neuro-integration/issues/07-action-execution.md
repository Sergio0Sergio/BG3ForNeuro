# 07 — Action Execution Layer

Type: grilling
Status: resolved
Blocked by: 01, 02, 04, 05, 06
Depended by: —

## Question

Определить, как C# процесс отправляет команды обратно в BG3SE и получает результат:

1. **Цикл выполнения**:
   - Neuro отдаёт решение (action name + data)
   - C# валидирует (JSON schema, существование цели, доступность заклинания)
   - C# отправляет команду через Named Pipe в BG3SE Mod
   - BG3SE Mod выполняет Lua API вызов (MoveTo, CharacterUseSpell, и т.д.)
   - BG3SE Mod возвращает результат (успех/ошибка + данные)
   - C# отправляет ActionResult в Neuro

2. **Таймауты**: Сколько ждать ответа от BG3SE? Что если BG3SE не отвечает?

3. **Ошибки выполнения**: Что если действие невозможно (заклинание недоступно, цель мертва)?

4. **Параллельность**: Можно ли выполнять несколько действий одновременно? (Research: BG3SE Lua однопоточный?)

5. **Action Result для Neuro**: Как формировать success/failure message? См. BEST_PRACTICES.md: success: false с actionable error для retry.

См. SPECIFICATION.md: action/result必须 отправляться как можно быстрее, до выполнения в игре.

## Answer

### Решения (HITL)

- **X1 (диалог)**: `select_dialogue_option` выполняется **`ClientAutoselectExecutor`** — client-контекст Lua находит элемент варианта в окне диалога по `option_index` (= порядок UI), подсвечивает его и **сам кликает**; человек ничего не жмёт. (Режим `confirm` из ранней версии схлопнут: «подсветка + ручной Enter» ≡ «autoselect», отдельная клавиша не нужна.) Переключение-совместимость — флаг `dialogue.mode` в `config.json` (`"confirm"` сохраняется как алиас). Если client-скрипт недоступен (нет клиентского контекста / мод серверный) → **откат на `not_supported` + warning** — Neuro не остаётся без канала общения. Все runtime-настройки (включая режимы) живут в едином `config.json` (см. 01/03), читаются на старте.
- **X2 (throw)**: остаётся в схеме combat-действий как `not_supported` — валидатор возвращает честный failure «реализуется позже», не тишину (BEST_PRACTICES).
- **X3 (stealth)**: no public Osiris API (клиентская механика, Pomosofter; нет `SetStealthEnabled`/`EnterStealth`; grep.app — 0 Lua-хитов). В v1 `toggle_mode` enum — только `"normal"`; `"stealth"` вернётся, когда появится устойчивое решение (ApplyStatus — хрупко, имён статусов нет). Вопрос «почему недоступно» разобран в Answer/research.
- **X4 (attack)**: базовые атаки игроков — через `Ext.System.ServerCastRequest.OsirisCastRequests` (честно с AP/кулдаунами, согласовано с X-cast); `Osi.Attack` (one-shot, без ресурсов) — только для врагов/NPC/fallback.
- **X5 (spell-id)**: нормализация в StateExtractor. State и `cast_spell` оперируют prototype-именами (`Ext.Stats.Get`), единый формат во всём конвейере.
- **E5 (референс схем)**: полные JSON-Schema всех 17 действий — в спецификации §5.4 (боевые 8 + диалоговое §5.2 + исследовательские 8), формат `Action` (name/description/schema) PERSISTENT на старте.

### Executor flow (итог)

1. C# валидирует schema + существование цели + precheck'и по state (IsInCombat, CanAllPartiesLongRest, наличие заклинания в SpellBook) → пишет `action_<id>.json`.
2. Server Lua poll: `Ext.Timer.WaitForRealtime(100–250ms)` → читает → диспатч → сразу пишет `result_<id>.json` (`Ext.Json.Stringify` + `Ext.IO.SaveFile`): `{success, error_code, error_detail}`.
3. Long actions (движение/каст) → промежуточный `success:true, running:true` + финал через `RegisterListener`-событие (`CastedSpell`, `CharacterMoveToCancelled`) — никогда не блокировать поток `WaitFor`.
4. Таймаут: **5 s** ACK со стороны C#; отсутствие result-файла после N опросов = ошибка по словарю тикета 08. Ожидания игрового эффекта по таймеру в Lua — нет.
5. Однопоточность подтверждена → команды сериализуются: один in-flight action на контекст, очередь в C# и Lua.

### Критичные ограничения (влияют на 04/05/06)

- `select_dialogue_option` — **нет** публичной функции выбора варианта (только старт диалога + `instanceID`). → решено X1.
- stealth — **нет** публичной функции. → решено X3.
- `throw` — нет публичного вызова (Anubis/client input). → решено X2.
- SpellId нормализация — решено X5 (влияет на 03).
- Рекомендуемый каст: `ServerCastRequest.OsirisCastRequests` (validate на SE build). Turn detection: события TurnStarted/TurnEnded/CombatRoundStarted/CombatStarted/CombatEnded + `CombatGetActiveEntity`; порядок ходов: `Ext.Entity.Get(combatGuid).TurnOrder`. Движение: `CharacterMoveTo`/`CharacterMoveToPosition` (Speed "Run"/"Walk"). Списки: `SpellBook.Spells` + `Ext.Stats.GetStats("SpellData")` + `Ext.Stats.Get(name)`.

## Research results (2026-09-05)

Полное исследование: [research/bg3se-lua-action-api.md](../research/bg3se-lua-action-api.md) — точные сигнатуры, sample-код, ссылки на источники, матрица надёжности. Кратко:

- **Цикл/pipe (Q1)**: file-based IPC подтверждён (ext. `research/ipc-named-pipes.md`); серверный Lua poll через `Ext.Timer.WaitForRealtime(100–250ms)` → диспатч → `Ext.Json.Stringify` + `Ext.IO.SaveFile` в `result_<id>.json`.
- **Таймауты (Q2)**: ACK от BG3SE — 5 s на C# стороне; отсутствие result-файла после N опросов → ошибка по тикету 08. Ожидание финального игрового эффекта не делать по таймеру в Lua — долгоиграющие действия (движение/каст) отвечают `running:true` и завершаются событием (`CastedSpell`, `CharacterMoveToCancelled`).
- **Ошибки (Q3)**: валидация-до-отправки в C# (цель, `IsInCombat`, `CanAllPartiesLongRest`, наличие заклинания в `SpellBook`); на стороне Lua — пула action error code (`target_missing/not_in_combat/no_spell/no_camp/not_supported`).
- **Параллельность (Q4)**: **да, BG3SE Lua однопоточный** (главный поток движка; `Ext.Timer` откладывает коллбеки, не создаёт потоки). → команды сериализуются: один in-flight action на контекст, очередь в C# и в Lua.
- **Action Result (Q5)**: `{success, error_code, error_detail}`; для long actions двухфазно `running:true` → финал.
- **Критичные ограничения (важно для схем 04/05/06)**: `select_dialogue_option` — **нет** публичной Osiris-функции выбора варианта (только старт диалога `CharacterMoveToAndTalk`/`StartDialog_Internal` + получение `instanceID`); stealth-переключатель — **нет** публичной функции; `throw` — нет публичного вызова (только Anubis/client input). Для диалога и stealth предложены experimental-пути (client UI, statuses) — вынести в отдельные миникииски.
- **Рекомендуемый каст заклинания**: `Ext.System.ServerCastRequest.OsirisCastRequests` (реальный pipeline, `FromClient` для ресурсов/кулдаунов); fallback — `Osi.UseSpell/UseSpellAtPosition`.
- **Turn detection**: события `TurnStarted/TurnEnded/CombatRoundStarted/CombatStarted/CombatEnded`, query `Osi.CombatGetActiveEntity(combatGuid)`; порядок ходов — `Ext.Entity.Get(combatGuid).TurnOrder` (`EocCombatTurnOrderComponent.Groups/Groups2/field_40`=round).
- **Движение**: нативное (`Osi.CharacterMoveTo (Speed "Run"/"Walk")` / `CharacterMoveToPosition`), свой A* не нужен; `TeleportTo/TeleportToPosition` как вспомогательный.
- **Списки (для 03)**: заклинания — `Ext.Entity.Get(char).SpellBook.Spells` + `Ext.Stats.GetStats("SpellData")` + `Ext.Stats.Get(name)` (UseCosts/SpellType/Range); инвентарь — `.Inventory` (EntityHandle) + `Osi.IterateInventory`, `Osi.GetGold`. SpellId нормализация (prototype vs root template) — решить до финализации 03.
