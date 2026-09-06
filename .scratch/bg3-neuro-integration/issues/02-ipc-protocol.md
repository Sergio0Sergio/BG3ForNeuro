# 02 — BG3SE IPC Protocol

Type: research
Status: resolved
Blocked by: 01
Depended by: 07

## Answer

Research completed. **Named Pipe native support in BG3SE отсутствует.** Отчёт: [ipc-named-pipes.md](../research/ipc-named-pipes.md).

### Ключевые факты

1. **BG3SE не имеет нативного named pipe API.** Модуль `Ext.IO` даёт только `SaveFile`/`LoadFile`. `Ext.Net` — только внутриигровые соединения, не наружу.
2. **LuaSocket недоступен.** `require("socket.http")` не работает — BG3SE не включает LuaSocket.
3. **Лучший путь: файловый IPC через `Ext.IO` + JSON.**
   - BG3SE Lua пишет JSON через `Ext.IO.SaveFile()`
   - C# процесс читает/пишет файлы
   - Неблокирующий polling через `Ext.Timer.WaitForRealtime()` на стороне BG3SE
4. **Формат: JSON** — BG3SE имеет `Ext.Json.Stringify()`/`Ext.Json.Parse()` (быстрая C++ реализация), совпадает с JSON WebSocket Neuro.
5. **Готовых BG3→Neuro интеграций не найдено** — это новая работа.
6. **Потокобезопасность:** использовать `Ext.Timer.WaitForRealtime()` для polling (не `Ext.OnNextTick`). C# процесс на отдельных потоках.
7. **Upgrade path (опционально):** если файловый IPC слишком медленный (~50–100мс), Phase 2 — C# mod с `System.IO.Pipes` напрямую внутри BG3SE.

### Фоллоу-ап

Имя канала/файла, структура сообщений и handshake формализовать в финальной спецификации (тикет 01), опираясь на файловый IPC. Named pipe как upgrade path документировать в секции "Phase 2".

## Question

Исследовать и определить протокол IPC через Named Pipe между BG3SE Mod (Lua/C#) и C# процессом:

1. **Как BG3SE предоставляет Named Pipe?** Какой API используется для создания сервера именованных каналов внутри BG3 Script Extender? Есть ли готовые обёртки?
2. **Формат сообщений**: JSON? MsgPack? Какая сериализация?
3. **Структура сообщений**: Request/Response? Event-driven? Есть ли идентификаторы корреляции для сопоставления запросов и ответов?
4. **Handshaking**: Как C# процесс обнаруживает BG3SE Mod? Как начинается сессия?
5. **Потокобезопасность**: BG3SE Lua выполняется в основном потоке игры. Как обеспечить безопасный доступ к данным из named pipe?
6. **Примеры**: Существуют ли открытые проекты, использующие named pipe в BG3SE?

Исследовать: BG3SE documentation, GitHub repos с примерами named pipe, Lua socket API в BG3SE.
