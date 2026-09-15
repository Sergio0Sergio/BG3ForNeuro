# bg3-neuro-dialogue-click — Wayfinder Map

## Destination

Полностью зелёный §9.5: выбор варианта диалога работает **end-to-end** (state → решение Neuro → реальный клик по варианту), а не только «диалог виден». Объём клиентской части — **только клик по диалогу** (минимум). Серверный контур остаётся основным; клиентский контекст добавляется только если серверного способа кликнуть диалог нет. Остальные разделы §9.5 (spells / exploration / loot / rest / travel_to) уже зелёные или дозелёнеют параллельной имплементацией вне карты.

## Notes

- Домен: BG3×Neuro mod (Lua-эмиттер + C#-роутер). Трекер: local-markdown `.scratch/bg3-neuro-dialogue-click/` (`docs/agents/issue-tracker.md`).
- Преамбула «dumb-мод» (только state extraction / action execution) — главный контур; клиентский кусок ради диалога — сознательное исключение (Q1=б), объём — только клик (Q2=1).
- Прежний spec (`.scratch/bg3-neuro-integration`, тикет 07, X1) уже спроектировал `ClientAutoselectExecutor`: client Lua ищет элемент по `option_index` (= порядок в UI-окне), подсвечивает и кликает; клиент недоступен → `not_supported` + warning («Neuro никогда не остаётся без канала»). Тогда — post-v1 эксперимент; теперь — в scope.
- Тикеты: 01 = research (AFK), 02 = grilling (HITL, blocked by 01). Скиллы: grilling + domain-modeling (дека-тикеты), research (01), prototype — при неясности «как должно выглядеть».
- **Вне карты** (простая имплементация по известной спеке, не решение; делается параллельно): `use_item` (зелье-лечение) + чтение `on_cooldown` в `bg3_to_neuro.json`.
- Стартовое состояние: v0.8.26 закоммичен (master `7a3bc46`), PAK v032 установлен; dialg-options пустые (`TODO(client)`), `executeDialogueOption` → `not_supported`.

## Decisions so far

- [BG3SE: как программно выбрать вариант диалога (server vs client)](issues/01-bg3se-dialogue-click-api.md): клиентский контекст обязателен — серверного маршрута нет. `Ext.Dialog` отсутствует, osiris — только административные lifecycle-функции; `Ext.UI` client-only (обход Noesis-дерева по `option_index`, клик `:Execute()`/`Subscribe("Click")`); server↔client — NetChannel (`Ext.Net.CreateChannel` + `SendToClient`/`RequestToClient`). Нет клиента → fallback `not_supported` (X1). Тикет 02 проектируется поверх этих фактов.

## Not yet specified

- Как паковать/грузить клиентский контекст (второй Lua-скрипт в том же PAK? ScriptExtender-config, сессионный client-хооk) — проявится после 02, если клиент окажется нужен.
- Какие именно пункты §9.5-диалога объявляются зелёными с рабочим кликом («Simple choice → line changed in next state» и т.д.) — уточнится с маршрутом.
- Bench-инфраструктура для живого клика (нужен ли полный клиент + замеры вместо серверной симуляции).

## Out of scope

- Клиент-часть более чем «клик по диалогу»: показ состояния/эффектов/экранов в UI (Q2=(1)).
- Trading, stealth, камера, voice, multiplayer — перенос из прежней карты (`.scratch/bg3-neuro-integration`).
- Диалог вне мода: если клиент невозможен и серверный маршрут мёртв — решение пересматривается на 02 (fallback X1: `not_supported` + warning остаётся главным честным поведением).