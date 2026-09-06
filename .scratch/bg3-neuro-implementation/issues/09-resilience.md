# 09: Устойчивость: реконнекты и re-init (R1–R8)

**What to build:** Полные циклы восстановления поверх уже работающего боевого пути. R1: разрыв/реконнект WS Neuro↔C# — корректная последовательность startup → register → продолжение работы. R2: перезапуск Lua-мода/игры — heartbeat протухает, `mod_unavailable`, по восстановлению мод заново инициализируется (logs, состояния). R7: краш игры — C# переживает, держит коннект к Neuro, чистит мёртвый IPC-стенд и ждёт возвращения модуля. R8: битые/частичные данные в файлах — отбросить, не ронять процесс. Политика force §1.6 соблюдена: никакого force во время активного действия, только замена поверх текущего.

**Blocked by:** 03 (боевой цикл как база для проверки устойчивости), 07 (диалог безопасно переживает рестарт — желательно).

**Status:** done

- [x] R1: разрыв WS → автореконнект → startup → register → цикл продолжается; проверено тестом. (client: `Reconnect_RepairsRegistration`; цикл: `WebSocketDrop_Reconnects_RestoresRegistration_ForceReSent_AndActionsContinue` — повторный force на реконнекте, действие после разрыва доходит и пишется в стэнд)
- [x] R2: остановка мода → `mod_unavailable`; запуск → re-init (регистрация/состояния) без ручного вмешательства. (`ModRestart_StaleDispatchModUnavailable_ThenAliveCleansStandAndResendsForce` + существующий Randy-E2E «мод выключен»: Диспатч → Канал A mod_unavailable без action-файла)
- [x] R7: прибит игровой процесс перезапуском — C# не падает, корректно пережидает и переинициализирует модуль. (переход Stale→Alive → `IpcClient.CleanStand()` + сброс `_lastForcedContent` + повторный force; Lua v0.7.0 `clearInFlight()` на бут вычищает mёртвый command-файл)
- [x] R8: битая/частичная запись в любом из файлов → отброшена, обработка продолжается. (heartbeat: HeartbeatFileTests; state: `PartialStateFile_SkippedWithoutCrash_ThenValidStateSendsForce` — частичная запись не роняет цикл, действие корректно отклоняется, валидный state → новый force)
- [x] force-политика: новый force поверх активного отменяет+заменяет его (SPEC «one action force at a time»); одновременно исполняются не более одного действия. (`TwoActions_SharedCommandSlot_KeepsOnlyLatestInFlight` — единый слот: в `neuro_to_bg3.json` только последнее действие; переотправка force при реконнекте вместо накопления)
- [x] Сквозной тест: убить/поднять мод и игру в середине сценария, убедиться в самовосстановлении цикла. (`ModRestart_...` — full loop: Alive → Stale → mod_unavailable → Alive → стенд вычищен → force переотправлен → действие снова проходит)