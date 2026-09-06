# BG3Neuro

Файловый IPC-мост между Neuro (ИИ-собеседник) и Baldur's Gate 3 через BG3 Script Extender: бой, диалоги и исследование. Спека: `BG3_Neuro_Spec.md` — финальная, принята.

## Состав репозитория

| Путь | Что это |
|---|---|
| `src/BG3Neuro.Core` | Ядро C#: IpcClient (heartbeat/stale), WebSocket-клиент Neuro, ActionRouter (валидация §6.5), DecisionLoop (force), StateSerializer |
| `src/BG3Neuro.App` | Консольный процесс — точка запуска C#-части |
| `mod/BG3Neuro` | Lua-мод BG3SE: heartbeat 2s, state-файл, исполнение `action_*.json` |
| `tests` | xUnit: unit (StateSerializer/ActionRouter/IpcClient/ErrorMapper…), интеграция (A: FakeNeuroServer; B: Randy), smoke |
| `tests/smoke.ps1` | Смоук одной командой (см. ниже) |
| `docs/manual-regression-checklist.md` | Ручной регресс-чек-лист §9.5 |
| `.scratch/bg3-neuro-implementation` | Тикеты 01–10 + карта статусов |

## Быстрый старт

```powershell
# сборка
dotnet build BG3Neuro.sln

# весь набор тестов (unit + интеграция A/B; Randy-часть сама запускается, если установлен)
dotnet test tests\BG3Neuro.Core.Tests\BG3Neuro.Core.Tests.csproj

# смоук одной командой: connect -> state -> end_turn -> new state (без игры и без Randy)
powershell -ExecutionPolicy Bypass -File tests\smoke.ps1
powershell -ExecutionPolicy Bypass -File tests\smoke.ps1 -Full   # весь набор
```

## Тест-стенд (§9 Testing Architecture)

- **Unit** — чистые модули: StateSerializer, ActionRouter, IpcClient (фейк-файлы), ConfigLoader, ErrorMapper, CoverageAuto.
- **A (CI, без игры)** — `FakeNeuroServer` (мой WS-сервер вместо Neuro) + mock-файлы BG3SE на временной директории: боевой цикл, exploration, диалог, устойчивость (реконнект, рестарт мода, битые файлы).
- **B (CI, с симулятором)** — настоящий Randy через реальный WS `ws://localhost:8000`. Подготовка Randy один раз:

  ```powershell
  cd neuro-sdk\neuro-sdk\Randy
  npm install
  ```

  Тесты сами запускают Randy с портами из env (`RANDY_WS_PORT`/`RANDY_HTTP_PORT`); если `node_modules/tsx` нет или порт не открылся за 40s — Randy-тесты пропускаются, остальной набор остаётся зелёным. Прогон проходит с `node` на машине (Randy — `node`-процесс).
- **C (ручной регресс)** — реальная Neuro перед выпуском: чек-лист §9.5 в `docs/manual-regression-checklist.md`.

Смоук-сценарий «подключился → state пришёл → end_turn выполнен → state обновился» реализован тестом `FullLoopSmokeTests` и выполняется одной командой `tests\smoke.ps1`.

## Запуск C#-процесса и подключение Neuro

Требуется: .NET 9 (Runtime для запуска / SDK вместе с тестами), BG3 + BG3 Script Extender, Neuro (или Randy для проверки).

1. **Мод**: скрипт `mod\BG3Neuro\BG3Neuro.lua` подключается в **server-контекст** BG3SE (Lua живёт на сервере игры, не в UI-клиенте) — например, в конец `Script Extender\Lua\BootstrapServer.lua`; контекст и требования — в `.scratch\bg3-neuro-integration\research\bg3se-lua-action-api.md`. IPC-директория по умолчанию: `<LocalAppData>\Larian Studios\Baldur's Gate 3\Script Extender\BG3Neuro`.
2. **Запуск игры** — мод пишет `heartbeat.json` (2s) и `bg3_to_neuro.json`, слушает `neuro_to_bg3.json`.
3. **Запуск Neuro/Randy**, затем C#-процесс:

   ```powershell
   dotnet run --project src\BG3Neuro.App -- config.json
   # или собранный exe:
   src\BG3Neuro.App\bin\Debug\net9.0\BG3Neuro.App.exe config.json
   ```

   Пример `config.json` (все ключи опциональны, применяются дефолты из `AppConfigDefaults`):

   ```json
   {
     "neuro": { "ws_url": "ws://localhost:8000", "reconnect_interval_s": 3 },
     "ipc": { "poll_interval_ms": 50, "heartbeat_interval_s": 2, "heartbeat_stale_s": 10 },
     "game": { "name": "Baldur's Gate 3", "controlled_party_size": 1 }
   }
   ```

4. Контроль лога: `[ipc] mod: Unknown -> Alive`, `[neuro] connected`, `[neuro] session: …` — цикл поднят. Вход в бой/диалог/исследование шлёт `actions/force`, ответ Neuro — `action`, валидация уходит в `action/result` (Канал A), успешные действия — в `action_*.json` для мода.

## Вопросы, решённые в споке

- Каналы ошибок, force-политика «один action», тайминги result — §6.5/§1.6 спеки.
- Устойчивость: реконнект WS, рестарт мода/игры (re-init по `Stale→Alive`), битые файлы — тикет 09.
- Out of scope v1 — §10 спеки (голос, мультиплеер, камера, покупка, `throw`, стелс).