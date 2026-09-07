# Ручной регресс-чек-лист (§9.5) — реальная игра + реальная Neuro

Обязательный прогон **перед выпуском** (тест-слой C). Автотесты покрывают логику на симулированных state; эти сценарии — финальный доверитель на реальной игре.

Перед прогоном:
- заведена **тестовая сцена с одним врагом** (проверка боёв);
- мод подключён в server-контекст BG3SE, C#-процесс и Neuro запущены;
- в логе ок: `[ipc] mod: Unknown -> Alive`, `[neuro] connected`, `[neuro] session: …`.

## Статус моста (прогон 2026-09-06, Patch 8 + HotFix 9, SE v32, `Ext.Utils.GameVersion()="v4.73.98.727"`)

- [x] **Мод принимается движком и держится в load order**: `modsettings.lsx` хранит BG3Neuro
      (бэкcия ванильного: `PlayerProfiles\Public\modsettings.lsx.vanilla.bak`); MD5 содержимого
      `Mods\BG3Neuro.pak` совпадает с MD5, зашитым в `modsettings.lsx` (и в облачном зеркале Steam).
- [x] **SE поднимает Lua-бутстрап**: в `Script Extender Logs\Extender Runtime ....log` —
      `'BG3Neuro': SE v32; flags: Lua`, `Loading bootstrap script: Mods/BG3Neuro/ScriptExtender/Lua/BootstrapServer.lua`,
      `[BG3Neuro] v0.7.0 loaded (server)`.
- [x] **Листенеры Osiris захомканы на реальные сигнатуры игры**: в логе **0** вхождений
      `Symbol not found in story` и **0** `Osiris event handler failed`.
- [x] **Heartbeat в ISO-8601 UTC** (`Ext.Timer.ClockTime()` → `T…Z`; `os` в песочнице SE = nil,
      `Ext.Print`/`Ext.PrintError` = nil, вывод через `_P`) — `BG3Neuro\heartbeat.json`.
- [x] **C#-мост видит мод и Neuro**: вывод `BG3Neuro.App.exe`:
      `[ipc] mod: Unknown -> Alive`, `[neuro] connected`, `17 actions registered`; Randy принял
      `startup`/`register`.

Зафиксированные сигнатуры событий этого билда (проверены по сторяxe игры
`Story\RawFiles\Goals\__PROC.txt`/`GLO_Camp.txt`/`__GLOBAL_Dialogs.txt` при распаковке
`Shared.pak`+`Patch8_HotFix9.pak`):

| Событие | Арность | Факт в игре |
| --- | --- | --- |
| `CharacterMoveToCancelled(_Char,_ID)` | 2 | сигнатура из story |
| `CastSpell(...)` / `CastedSpell(...)` | 5 | сработали в сессии (capture `CastSpell@5`) |
| `CastSpellFailed(_Caster,_Spell,_SpellType,_SpellElement,_StoryActionID)` | 5 | сигнатура из story |
| `DialogStarted(_Dialog,_Inst)` / `DialogEnded(_Dialog,_Inst)` | 2 | сработали (capture `DialogStarted@2`) |
| `DialogStarting` | — | **не является событием** — листенер удалён |
| `LongRestFinished()` / `LongRestCancelled()` / `LongRestStartFailed()` | **0** | сигнатуры из `GLO_Camp.txt` |

Особенность SE v32: `RegisterListener(name, arity, event, handler)` регистрирует листенер только при
точном совпадении arity с объявлением события; при несовпадении молча пишет в лог
`Couldn't register Osiris subscriber for <name>/<arity>: Symbol not found in story`, а `pcall`
этого НЕ сигнализирует — ошибка видна только в логе Extender Runtime.

## Бой

- [ ] **1v1**: вход в бой → force с `## Ход: …` → `end_turn` → следующий ход в state → новый force.
- [ ] **1vмного**: вход в бой с группой ≥2 → `move_to_target`/`attack_entity` по выбранной цели → урон виден в следующем state (`HP …/…`).
- [ ] **AoE**: `cast_spell` с AoE-заклинанием и незаполненным `coverage` → автономная цель из `CoverageAuto` → провал/успех отражается в state.
- [ ] **Лечение**: `use_item` (зелье/заклинание лечения) на себя/союзника → HP в следующем state выросло.
- [ ] **Отказные коды в бою**: `no_spell` (заклинание не в списке), `not_in_range` (цель вне радиуса) — приходят `action/result` с actionable-сообщением, action-файл не пишется.

## Диалог

- [ ] **Простой выбор**: диалог → force `## Диалог` с `[1]…` → `select_dialogue_option` → реплика сменилась в следующем state, окно закрылось → force боя/исследования.
- [ ] **Квестовый диалог**: ветка из нескольких выборов подряд; после завершения квеста — корректный следующий режим.
- [ ] **Закрытый диалог**: `select_dialogue_option` без активного диалога → `dialogue_closed` по Каналу A.

## Исследование

- [ ] **Перемещение**: `move_to_entity` → объект в state с обновлённой дистанцией, движение прерывает активное.
- [ ] **Взаимодействие**: `interact_with` (дверь/рычаг/лот) → смена состояния объекта в следующем state.
- [ ] **Лут**: `loot` с трупа/контейнера → предметы в инвентаре state.
- [ ] **Отдых/путешествие**: `rest` полный (лагерь) / без лагеря → `no_camp`; `travel_to` по имени локации и по `region_id`.

## Устойчивость (тикет 09)

- [ ] **Реконнект WS**: разрыв Neuro → авто-реконнект → `startup`+`register` повторены → цикл продолжается без вмешательства.
- [ ] **Рестарт мода/игры**: прибить мод/игру → `mod_unavailable` на действия → перезапуск → re-init (`Stale→Alive`): мёртвый стэнд вычищен, свежая force, действия снова проходят.
- [ ] **Битая запись**: перезаписать вручную `bg3_to_neuro.json` мусором → процесс жив, обработка продолжается после восстановления файла.

## Исключения

- [ ] Покупка/торговля — **out of scope v1** (не тестируем).
- [ ] Стелс `toggle_mode "stealth"` — **out of scope v1** (нет публичного API).
- [ ] `throw`, голос, мультиплеер, камера — **out of scope v1**.

Итог: все пункты отмечены + 139 автотестов зелёные (`dotnet test` + `tests\smoke.ps1 -Full`) → релиз-кандидат. Точка входа в проект — `README.md`.