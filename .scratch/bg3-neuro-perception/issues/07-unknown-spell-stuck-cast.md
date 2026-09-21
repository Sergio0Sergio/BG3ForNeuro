# 07 - Неизвестный спелл на честном пути не отсекается: висячий running:true

Type: bug
Status: verified (v0.8.61, live 2026-09-21)
Blocked by: -

## Symptom (live, v0.8.60, 2026-09-21, id `reg8_refuse`)

`cast_spell` через файловый мост (без App/C#-роутера) с именем, которого нет в книге
кастера: `{ "spell_name": "wish", "target_id": "poc_player_cleric" }`, ход клерика
(Shadowheart) → `result_reg8_refuse.json` навсегда остаётся `{ "running": true,
"success": true }` — action **не финализируется**, отказ не приходит.

Ожидание: честный отказ `no_spell` (как на legacy-пути `use_osi_spell`,
`mod/BG3Neuro/BG3Neuro.lua:4443` — `"no_spell: <name> is not in the caster's book"`),
и как это делает C#-роутер (`ActionRouter.ValidateCast` валидирует имя до мода).

## Evidence

- `prevalidate_latest.json`: `sid="wish"`, `los_1=1`, `verdict="pass"` — пре-валидация
  честно проверяет только дистанцию/LOS, но НЕ членство в книге.
- `cast_debug.json`: `spell = { Prototype:"wish", OriginatorPrototype:"Target_wish",
  SourceType:"Osiris" }`, `castOptions = [IgnoreHasSpell, IgnoreCastChecks,
  IgnoreSpellRolls, IgnoreTargetChecks, Forced, Immediate]`, `queue=osiris`.
- `cast_queues_65709f18-…_0ms.json`: `OsirisCastRequests` **size=1, не дренится**.
- `resource_snapshot_reg8_refuse_before.json` записан, `_after` — **нет**:
  исполнение не дошло до `CastSpell`, поэтому результат не финализирован.

## Root cause (гипотеза)

`executeCast` на честном пути не проверяет книгу кастера (в отличие от `executeAttack`,
где есть `knownSpellCandidates`/`Osi.HasSpell`, `:4852-4866`, `:4431-4446`). Имя
резолвится в синтетический spell (`SourceType=Osiris`) и форс-пушится с
`IgnoreHasSpell` → движок молча не исполняет → `CastSpell` не приходит → pending висит.

В проде неизвестные имена отсекает C#-роутер раньше, поэтому через App баг не виден;
под удар попадает прямой мод-путь/стенд.

## Fix direction

На честном пути перед enqueue проверять книгу (`knownSpellCandidates` или
`Osi.HasSpell(actor, sid)`) и при промахе возвращать
`false, nil, "action_failed", "no_spell: <name> is not in the caster's book"`
(единый код с `:4443`). Опционально — таймаут висячего pending, чтобы результат
гарантированно финализировался.

## Repro

```powershell
$env:BG3NEURO_DATA='{"spell_name":"wish","target_id":"poc_player_cleric"}'
powershell -File "$env:TEMP\opencode\drive_action.ps1" -Id reg8_refuse -Name cast_spell
# затем прочитать result_reg8_refuse.json → running:true навсегда
# и cast_debug.json / cast_queues_*.json в
# %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\BG3Neuro\
```

## Fix (v0.8.61, 2026-09-21)

Добавлен единый **книжный гард** в `executeCast` (`mod/BG3Neuro/BG3Neuro.lua`) сразу
после пре-валидации цели и ДО любого исполнителя каста (общий для честного и legacy-путей):

- кандидаты `{ spellName, "Projectile_"..spellName, "Target_"..spellName }` проверяются
  через `Osi.HasSpell(actor, sid)` (ленивый резолвер прогревается `pcall(function() return Osi.HasSpell end)`
  до цикла, каждый вызов обёрнут в `pcall(function() return Osi.HasSpell(actor, sid) end)`);
- ни одного совпадения при удачном чтении (`probed and not bookHit`) → честный отказ
  `action_failed` → `"no_spell: <name> is not in the caster's book"` (тот же код, что на legacy-пути);
- **fail-open**: если `Osi.HasSpell` недоступен/чтение не удалось (`probed == false`) — НЕ отказываем.

Дублирующий legacy-блок `bookHit` (прежние строки ~4431–4446) удалён — проверка теперь
одна. Мод поднят до `v0.8.61`; `luaparse` → `PARSE_OK` (237 узлов).

**Сборка/установка (2026-09-21):**
- build-дерево: `%TEMP%\opencode\v092_build` (копия v091 + 4 lua из репо);
- PAK: `%TEMP%\opencode\BG3Neuro_v092.pak` (88501 байт), `MD5 = aac0b9104d0c672db0d2b7b096ce0983`,
  `paktool2 list` → все 6 записей начинаются с `Mods/BG3Neuro/`, `get BG3Neuro.lua` == filehash репо;
- установлено: `…\BG\Mods\BG3Neuro.pak` заменён, `MD5` в **обоих** `ModuleShortDesc`
  (`ModOrder` + `Mods`) `modsettings.lsx` обновлён; бэкап — `%TEMP%\opencode\modsettings.backup.20260921_173221.lsx`.
- `heartbeat.json` после запуска: `version: 0.8.61` (PAK подхватился).

## Live verification (v0.8.61, 2026-09-21, combat save)

1. **Негатив (баг закрыт):** `cast_spell { spell_name:"wish" }` (ход Тава) →
   `result_t07_wish.json` **финализирован сразу**:
   `{ "success": false, "error_code": "action_failed",
   "error_detail": "no_spell: wish is not in the caster's book" }` — без `running:true`.
   osiris-очередь не тронута (запрос вообще не пушится).
2. **Fail-open (валидный каст не сломан):** `cast_spell { spell_name:"fire_bolt",
   target_id:"goblin_tracker_2" }` → понятное имя срезолвилось в `Projectile_FireBolt`
   (`cast_debug.json`), каст прошёл: финал `success:true`, экономика
   `resource_snapshot_t07_firebolt_{before,after}.json`: **ActionPoint 1.0 → 0.0**
   (BonusAction 1.0, слоты — без изменений).
3. **Пайплайн жив после отказа:** `heartbeat.json` свежий (age ~1 с, seq растёт),
   `cast_debug.json` `queueSize=0`, последний queue-файл содержит только fire_bolt.

## Контекст

Найдено при регрессии §9.5 после включения перцепт-фильтра (см.
`docs/manual-regression-checklist.md`, раздел «Run 2026-09-21 (v0.8.60…)»).
