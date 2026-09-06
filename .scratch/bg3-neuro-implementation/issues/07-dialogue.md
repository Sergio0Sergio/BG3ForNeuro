# 07: Диалог (select_dialogue_option)

**What to build:** Полный путь диалога: начался диалог → Neuro получает диалоговый state (реплики и варианты, пронумерованные в порядке UI) → Neuro шлёт `select_dialogue_option` с `option_index`. Public Osiris-функции выбора нет (research §7.2), поэтому исполнение — через `ClientAutoselectExecutor`: client-контекст (Lua-скрипт на стороне игры) находит вариант UI по индексу, подсвечивает и кликает; человек не жмёт ничего. Если client-скрипт недоступен → `not_supported` + warning. Диалог закрылся раньше → `dialogue_closed`.

**Blocked by:** 03 (боевой цикл/execution-шаблон).

**Status:** done

- [x] Диалоговый state выдаёт варианты с номерами, совпадающими с порядком UI (option_index). — `CombatState.Dialogue{SpeakerName,Line,Options[]}` (+ парсинг snake_case), рендер `## Диалог` с `[1]..[N]`; принцип «option_index == UI order» — источник вариантов тот же (client), fallback `not_supported`.
- [x] `select_dialogue_option` с `option_index` выполняет выбор через ClientAutoselectExecutor (подсветка + клик), успех/ошибка в едином формате action/result. — Lua v0.5.0 `executeDialogueOption` (client-контекст, `running:true` + финал по `DialogEnded`); action-файл + `action/result` (Канал A) на C#.
- [x] Client-скрипт недоступен → `not_supported` + warning, диалог не уходит в подвес. — Router: `DialogueConfig.IsEnabled` (mode `autoselect`/`confirm`, алиас `confirm`) → `NotSupported` (Канал A) без записи action-файла; Lua: `Ext.UI == nil` → `not_supported` (Канал B detail).
- [x] Диалог закрылся до выбора → `dialogue_closed` (Канал A/B по словарю §6.5). — Router: mode != dialogue / нет блока → `DialogueClosed`; вне диапазона индексов → `InvalidParameters` с диапазоном.
- [x] Сквозной тест: диалог открыт → выбран вариант → state продвигается. — E2E Randy: dialogue state → force (`## Диалог`, `[1] Да, я готов.`) → выбор → action-файл → mode=combat → второй force confirmed.

**Итог:** `Dialogue`/`DialogueOption` в модели + диалоговый force в `DecisionLoop` (content-based dedup) + `ValidateDialogueOption` (dialogue_closed / invalid_parameters по диапазону / not_supported по флагу) + Lua v0.5.0; 104/104 тестов (было 98), сборка 0 предупреждений, node-процессов после прогона 0. Client-клик (реальный UI-click) — TODO(client) в Lua, изолирован за action-слоем, деградирует в not_supported.