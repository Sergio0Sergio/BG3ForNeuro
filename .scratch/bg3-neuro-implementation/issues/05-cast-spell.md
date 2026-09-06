# 05: cast_spell (AoE-покрытие, ресурсы)

**What to build:** Каст заклинания из списка знаний: Neuro кастует известным заклинанием по `spell_id` из state (список из `SpellBook`), при необходимости с AoE-целью и coverage. Покрытие range/AoE вычисляется единым code path с StateSerializer (CoverageAuto), чтобы state и валидатор видели одно и то же. Честность ресурсов: заклинание можно кастовать только если хватает AP/зарядов/кулдауна. Каст с `throw` (кидание заклинания/предмета) → `not_supported`.

**Blocked by:** 03 (боевой цикл), 04 (движение/атака as base).

**Status:** done

- [x] State отдаёт список известных заклинаний и их предпосылки (AP, заряды, кулдаун) — из `SpellBook`/`GetSpell`. → `SpellInfo{CastsLeft, OnCooldown, Slot, Range, Aoe}` + рендер «зарядов осталось / на кулдауне» в `StateSerializer`.
- [x] `cast_spell` валидирует: известно ли заклинание (`no_spell` + список известных), достаточно ли ресурсов (кулдаун/0 зарядов → `no_spell`), в зоне ли (единый coverage-код через `CoverageAuto`). Нарушение → actionable failure (`target_missing`, `target_not_in_range` с перечнем достижимых/недостижимых).
- [x] Cast выполняется в игре (канальный или мгновенный), `running:true` + событие финала для длительных. → Lua v0.4.0 `executeCast` через `ServerCastRequest` (CastOptions `FromClient/ShowPrepareAnimation/NoMovement`, `SourceType="Osiris"`), fallback `Osi.UseSpell(AtPosition)`; финал — `CastedSpell`/`CastSpellFailed` → `running:false`. Правда уходит и через следующий state (Канал B).
- [ ] Normalization spell-id (X5): серверный id заклинания сопоставляется с русским именем в state. → отложено: заглушка `SourceType="Osiris"`, prototype-имя используется как есть до ввода реального SpellBook-extractor.
- [x] AoE: выбор центра/покрытия консистентен между state и выполнением (CoverageAuto). → чистый модуль `CoverageAuto` (единый code path), детерминированный `BestAoECenter` (центры-кандидаты = позиции целей + центроид; центр обязан быть в range кастера).
- [x] Сквозной тест: каст из списка с ресурсами и проверкой по state. → E2E Randy: известный каст (action-файл + потраченный заряд в следующем force), неизвестный (`no_spell` без action-файла), AoE-coverage с недостижимой целью (`target_not_in_range`).

**Итог:** 90/90 тестов (было 71), сборка 0 предупреждений, node-процессов после прогона 0.