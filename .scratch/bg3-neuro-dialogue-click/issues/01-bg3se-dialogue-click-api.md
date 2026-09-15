# 01 — BG3SE: как программно выбрать вариант диалога (server vs client)

Type: research
Status: resolved
Blocked by: —

## Question

Какими API и механизмами BG3 Script Extender можно **программно выбрать вариант диалога**?

1. **Server-контекст**: какие средства существуют в BG3SE/osiris — функции `NRD_Dialog*`, `Ext.Dialog`, команды вида `DialogSetAnswer` / `CharacterUserSetDialog` / `DialogGetNode` — и что из них реально «выбирает» опцию, а не только читает дерево диалога. Есть ли рабочий server-only маршрут (например, через osiris-колбэк на выбранную ноду или прямую установку answer).
2. **Client-контекст**: реальность `Ext.UI` на клиенте — имя UI-элемента окна диалога, как найти option по `option_index` (= порядок в окне), как вызвать «клик»/«выбор» (Invoke / коллбеки / кнопка / `Ext.UI.GetByType`), ограничения (client-only, local-coop-сессия).
3. **Server↔client обмен**: доступны ли в SE явные OS-мосты (`Ext.Net.PostMessageToServer` / `PostMessageToClient` или аналоги), как server-Lua передаёт команду client-Lua, что в двухпроцессной модели local-coop (server и client — отдельные процессы).
4. **Вердикт-факт**: обязателен ли клиентский контекст для клика, или существует серверный маршрут.

Первоисточники: документация BG3SE (wiki-разделы Ext.UI/Ext.Dialog/osiris-функции), репозиторий Norbyte/bg3se (types/lua, ReleaseNotes), примеры модов, использующих диалоговый UI (OptionAutoselect-подобные). Факты, не мнения: под каждый заявленный механизм — источник.

Результат: файл `.scratch/bg3-neuro-dialogue-click/research/01-bg3se-dialogue-click-api.md`.

## Answer

**Вердикт: клиентский контекст обязателен — серверного маршрута выбора опции нет.**

- `Ext.Dialog` не существует; в osiris нет `DialogSetAnswer`/`CharacterUserSetDialog`/`DialogGetNode*` — только lifecycle/переменные (start/stop, add/remove actors, set vars). Server-контекст — административный.
- `Ext.UI` — **client-only**: `GetRoot()` → обход Noesis-дерева (`Child`/`VisualChild`/`Find`) по `option_index`; клик — кнопка `:Execute()` / `Subscribe("Click")`, или симуляция ввода `Ext.Input.InjectKeyPress`.
- Server↔client мост — **NetChannel**: `Ext.Net.CreateChannel` + `SendToClient` / `RequestToClient(cb)` (legacy `PostMessageToClient`); в single-player обмен in-process, Lua-state изолированы.
- Обязательный маршрут: server → NetChannel → client-Lua → клик. Нет клиента → fallback `not_supported` (X1).

Артефакт: `.scratch/bg3-neuro-dialogue-click/research/01-bg3se-dialogue-click-api.md` (ветка `research/bg3se-dialogue-click-api`, commit `739028c`). Контекст-указатель: тикет 02 «Маршрут клика по диалогу и контракт server↔client» — проектируется поверх этих фактов.