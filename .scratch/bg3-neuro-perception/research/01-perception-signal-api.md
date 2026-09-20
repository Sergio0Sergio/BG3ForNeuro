# Research 01 — Сигналы восприятия в BG3SE

Дата: 2026-09-20. Тикет: `issues/01-perception-signal-api.md`.
Источники: локальная копия BG3SE-исходников и игровых Lua-библиотек:
- `%TEMP%\opencode\bg3se\Osi.lua` (список Osi-функций), `osi_signatures.txt`, `Docs\API.md`
- `%TEMP%\opencode\bg3se\brawl_Pick.lua`, `brawl_Actions.lua`, `brawl_AI.lua` (игровые AI-библиотеки, читающие видимость)
- `%TEMP%\opencode\research_bg3\brawl_Utils.lua` (`isVisible`), `brawl_Memo.lua` (список кэшируемых Osi-вызовов), `ExtIdeHelpers.lua` (реверс полей компонентов/флагов)

Примечание: research-субагент в этой сессии вернул пустой результат; работа выполнена на карт-сессии напрямую.

## Кандидаты

| Сигнал | Что даёт | Ограничения | Вердикт |
|---|---|---|---|
| `Osi.CanSee(source, target)` → int bool (`Osi.lua:216`) | Движковый ответ «может ли source видеть target» (осторожно: включает LOS + невидимость + скрытность) | Семантика не задокументирована; цена на вызов; нужен живой probe | **Основной кандидат** |
| `Osi.CanSeeCached(source, target)` → int bool (`Osi.lua:221`) | То же, с кэшем движка | Свежесть кэша неизвестна | Кандидат для производительности |
| `Osi.HasLineOfSight(source, target)` → 1/0 (`Osi.lua:1373`) | Чистая геометрия (стены/препятствия), без статусов | Не учитывает невидимость/скрытность | **Геометрическое уточнение** |
| `Osi.IsInvisible(object)` → int (`Osi.lua:1686`) | Невидимость цели | Не про LOS | Объясняющий сигнал |
| `Osi.HasActiveStatus(uuid, "SNEAKING"/"INVISIBLE")` | Скрытность/невидимость как статус | Нужен точный набор статусов | Объясняющий сигнал |
| Компоненты viewshed: `Sight`, `SightEntityViewshed`, `ServerViewshedParticipant`, `ServerSightAggregatedData`, `ServerSightEntityViewshedContentsChanged`, `ServerSightEntityLosCheckQueue` (`ExtIdeHelpers.lua:857-868, 1080`) | Внутренний серверный viewshed-система (авторитетная, событийная) | Чтение из Lua не подтверждено; сложно | Отложено (кандидат на будущее) |
| Флаги `ServerCharacterFlags.Invisible/SpotSneakers`, `StatCharacterFlags.Invisible/IsSneaking/Blind` | Грубые флаги | Не про восприятие партии | Вспомогательное |
| `Osi.ShroudRender` / `NETMSG_SHROUD_UPDATE` | Туман **карты** (reveal территории) | Не про видимость сущности | Не наш сигнал |

## Что делает сам движок (эталон)

Игровая AI-библиотека `brawl_Utils.lua:266`:
```lua
local function isVisible(uuid, targetUuid)
    if HasActiveStatus(uuid,"TRUESIGHT") or HasActiveStatus(uuid,"MOD_Generic_Truesight") then return true end
    local hasSeeInvisibility = HasActiveStatus(uuid,"SEE_INVISIBILITY")
        or HasActiveStatus(uuid,"MAG_SEE_INVISIBILITY_HIDDEN_IGNORE_RESTING")
    if hasSeeInvisibility and GetDistanceTo(uuid,targetUuid) <= 9 then return true end
    return Osi.IsInvisible(targetUuid) == 0 and Osi.HasActiveStatus(targetUuid,"SNEAKING") == 0
end
```
Важно: это **только статусы** (невидимость/скрытность/тру-сайт) и **без геометрии** — стены не учитываются. Игра в другом месте добавляет геометрию отдельно: `brawl_Pick.lua:551` → `Osi.CanSee(...) == 1`; `brawl_Actions.lua:339`/`brawl_Pick.lua:293` → `Osi.HasLineOfSight(...) == 0/1`.

## Рекомендация

Композиция, а не один сигнал:

1. **`Osi.CanSee(partyMember, target) == 1`** — двигать по любому члену партии (OR). Это движковый «видит», ближе всего к «воспринято».
2. Если нужен «почему»/дешёвое уточнение — **`Osi.HasLineOfSight`** (геометрия) + `IsInvisible`/`SNEAKING` (статус). Даёт материал для `known` (потеря LOS при не-статусной причине).
3. Производительность: если `CanSee` дорог — `CanSeeCached`, либо ограничить проверку сущностями в радиусе (`EXPLORE_MAX_DISTANCE`) и пересчитывать только по viewshed-событиям.

Явно: **чистого одиночного API «воспринимает ли партия» нет** — нужна композиция, и семантику `CanSee`/`CanSeeCached` обязательно подтвердить живым пробником (это вход в тикет 02).

## Открытые вопросы к прототипу (02)

- Точная семантика `CanSee`: включает ли свет/темноту, конусы FOV, высоту?
- Разница клиент/сервер: доступны ли `CanSee`/`HasLineOfSight` в обоих контекстах мода.
- Цена на тик при N×M вызовах; стоит ли кэш.
- Ловит ли `CanSee` скрытность (SNEAKING) — или её надо домешивать статусом.
