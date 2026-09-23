# 28 — `throw` / `hide` as separate combat actions

Type: feature
Status: resolved (hide verified; throw bench-proven as `not_supported`)
Blocked by: —

## Goal

Включить `throw` и `hide` как полноценные отдельные боевые действия после триажа
(пользователь выбрал вариант «Отдельные действия throw + hide (Recommended)»), вместо
прежнего `throw` → NotSupported и отсутствующего hide-исполнителя.

- **hide**: каст `Shout_Hide` (Shout, без цели) через каст-очередь; bonus-action по экономике.
- **throw**: каст прототипа `Throw_Throw` с полем `Item` (EntityHandle предмета) в `EsvSpellCastCastStartRequest`
  (`ExtIdeHelpers.lua:16770`). Без `Item` каст бросил бы ничего.

## What's done (C#, ready in repo)

- `ActionRouter.cs`: блок `throw` → NotSupported убран (бывшие L387-390), добавлен `ValidateThrow`
  (item_id/target_id обязательны, target среди enemies/allies, иначе `TargetMissing` с перечнем известных);
  `hide` добавлен в `requiresCombatPhase`.
- `action_schemas.json`: схема `hide` (required `[]`) добавлена после `throw`.
- `DecisionLoop.cs`: `"hide"` в `CombatActionNames`.
- `ActionRouterTests.cs`: `Throw_NotSupported…` заменён на 8 тестов throw/hide.

## What's left (Lua, server)

- `scanPartyInventory` (L3068): заполнение глобального `BG3NEURO_ITEMS = {}` (alias `inv_N` → guid
  предмета). **Глобал, не local** — main-chunk на лимите 200 активных локалов.
- `enqueueCastRequest` (L3739): опция `opts.item` → `request.Item = Ext.Entity.Get(uuid)`.
- `executeThrow` / `executeHide` через глобальную таблицу (по образцу `BG3NEURO_SIGHT`/`BG3NEURO_REST`),
  ветки `throw` / `hide` в диспетчере `executeAction` (~L6150).

## Known gaps / risks

- **Боевой стейт `buildCombatState` (L2355) инвентарь НЕ содержит** (`scanPartyInventory` вызывается
  только в exploration, L3192). Neuro в бою не увидит `item_id` → выбор предмета невозможен. Вариант:
  добавить `state.inventory` в боевой стейт (решение отложено сознательно — валидация C# проверяет только
  обязательность полей, honesty-вердикт отдаёт Lua).
- Старое research (`bg3se-lua-action-api.md`) «throw не автоматизируем» — **подтвердилось** на стенде.

## Bench-вердикт по throw (2026-09-23, v0.8.79, бой у рощи, Tav vs Goblin Tracker)

Движок **отклоняет синтетический бросок во всех проверенных вариантах** — `CastSpellFailed(caster, "Throw_Throw", "throw", "", storyActionID=0)`,
событие `UsingSpell` даже не возникает:

- v0.8.78 (форс-флаги): очереди `osiris`, `network`, `item`, `anubis` — 4/4 `cast_failed` (bt28_throw1–4).
- v0.8.79 (честный каст, `FromClient`, не форс): `item` и `network` — 2/2 `cast_failed` (bt28_throw5–6).

При этом запрос реально попадает в очередь (`ItemStartRequests` entry: spell=Throw_Throw, opts=[ShowPrepareAnimation,FromClient,NoMovement,AvoidDangerousAuras],
storyActionId=0, item=Entity, a8=1) — структура идентична успешным честным кастам атаки (OsirisCastRequests), но движок отвергает именно entry с Item.
Живой ручной бросок (логи 05-24) перед кастом показывает `QRY_GetMoveForbiddenItemInfo` и `AddedTo(предмет, кастер, "Regular")` —
движок сам поднимает предмет в руку как часть клиентского потока; синтетическому запросу этого этапа, видимо, не хватает.

**Закрыто как unsupported** (по решению пользователя), research-вывод подтверждён. Hide верифицирован и работает.

## Acceptance

- `throw {actor, item_id, target_id}` в бою: каст `Throw_Throw` + `Item`, честный status/result.
- `hide {actor}` в бою: каст `Shout_Hide` (без цели), BA по экономике.
- Схемы в `action_schemas.json`, C#-валидация, Lua-исполнители, PAK v113, luaparse + countlocals (200/200).

## Note: throw заморожен, но не списан

Можно вернуться к вопросу броска в будущем — как отдельный тикет. Перспективные направления:

- **Client-инициированный поток**: понять, как Ecl-клиент стартует Throw из инвентаря (подъём предмета в руку
  → каст), и повторить его серверно (AnubisPickUpItem / AnubisMoveItem до ItemStartRequests).
- **Live-захват**: при живом ручном броске игрока снять снапшот очередей/структуры запроса, чтобы сравнить
  с синтетическим (в v0.8.78–79 снятие есть только для наших запросов).
- **`EsvSpellCastChangeStoryActionId`**: движок сам присваивает StoryActionId живым кастам при обработке;
  для честного Item-каста ID так и остался 0 — возможно, требуется предварительная инициализация
  ActionOriginator/StoryActionId, а не только поле в запросе.