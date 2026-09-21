# 04b — Мод-side авторитетный перцепт-гейт (честный отказ на исполнении)

Type: implementation
Status: resolved
Blocked by: 04, 03 (контракт)

## Problem

Роутер C# гейтит цель по эмитированному стейту (зеркало, тикет 04). Но между валидацией
и исполнением мир меняется (цель ушла из поля зрения, персонаж умер/скрылся) — стейл-зеркало
может пропустить действие, которое игрок физически не видел на момент исполнения. Плюс
`bonus_action`/`use_item` роутер вовсе не зеркалит по цели. Нужен авторитетный гейт в моде.

## Task

- В моде вести актуальный перцепт-набор: `party_guids ∪ emitted-this-tick` (эмитированные
  сущности уже известны — тот же набор, что пишется в стейт).
- Перед исполнением action с целью-сущностью проверять цель по перцепт-набору; при отсутствии —
  честный отказ `action_failed` + `no_perception` + English detail («target not in current
  perception set — it may be out of view; only act on entities the state reports»).
- Не гейтить: действия без цели (`end_turn`, `rest`, `travel_to`), позиционный AoE (тикет 04).
- Партия не гейтится (всегда в наборе).
- Не ломать `feasible`-честные отказы (no_spell_slot/no_action_point и т.п.) — порядок проверок:
  перцепт-гейт → существующие честные отказы → исполнение.

## Deliverable

- Lua-правки `mod/BG3Neuro/BG3Neuro.lua` (целевые хендлеры: attack, cast_spell, move,
  interact, loot, bonus_action, use_item).
- Живой сценарий отказа на стенде: цель в стейте исчезает с экрана → действие из кэша
  отклонено `no_perception`.
- Регрессия: существующие успешные пути и честные отказы `feasible` не сломаны.

## Verification

- Стенд: серия inject-тестов «цель видна → ок», «цель вне кадра → no_perception», «партия → ок».
- Сверка с роутерным `TargetMissing`: оба слоя в одном сценарии отвечают согласованно.

## Результат (v082, 2026-09-20)

**Реализовано в BG3Neuro.lua (04b):**
- `refreshPerceptionSet(state)` (глобальные `perceptionActors`/`perceptionObjects`) — пересобирает
  перцепт-набор из full-билда: аллеи + враги → `actors`, эмитированные object'ы → `objects`,
  плюс `partyAvatars()` всегда в обоих (партия не гейтится). Вызывается из `buildExplorationState`
  (каждый тик, до `return state`) и из `captureCombatState` (полный combat-билд перед записью).
- Гейт в `executeAction` (после парсинга data, ПЕРЕД dispatch): зеркало роутерной матрицы тикета 04:
  `attack_entity/cast_spell/move_to_target/bonus_action/use_item` → `actors`;
  `move_to_entity/interact_with/loot` → `objects`. Без цели и позиционный AoE — не гейтится.
  Отказ: `action_failed` + `no_perception: target not in current perception set ...`.
  Структура PERCEPTION_GATE/target — внутри `do..end` функции (не топ-локальные — бережём лимит 200).
  Символы перцепта глобальные (как `build*`), чтобы не упираться в лимит 200 local merge.
- Порядок: перцепт-гейт → существующие честные отказы (canAct/AP/слоты/Movement) → исполнение.

**Стендовая верификация (эксплорейшн у ворот, v082, серийные inject'ы):**
- R1 `move_to_entity sword_spider_1` (видимый object) → `running=true` (прошёл objects-гейт).
- R2 `cast_spell firebolt` на `goblin_tracker_1` (видимый, но objects-категория; cast=actors) →
  `no_perception` (зеркалит роутер: cast только enemies∪allies).
- R3 `cast_spell guidance` на `tav` (член партии) → перцепт ПРОШЁЛ, далее честный
  `not_caster_turn` (порядок «гейт → честный отказ» подтверждён).
- R4 `move_to_entity` на guid гоблина за баррикадой (LOS=0, не эмитирован) → `no_perception`.
- SE-лог без Lua-ошибок (FAILED/attempt отсутствуют).

Локальные 199 (≤200 лимит merge), parse OK, PAK v082 установлен (MD5 1F0F921033F074BBBE24E83CD2AE0F50).