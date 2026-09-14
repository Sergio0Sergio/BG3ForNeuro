# 09: Resilience: reconnects and re-init (R1–R8)

**What to build:** Full recovery loops on top of the already working combat path. R1: WS drop/reconnect Neuro↔C# — correct startup → register → continue sequence. R2: Lua mod/game restart — heartbeat goes stale, `mod_unavailable`, on recovery the mod re-initializes (logs, states). R7: game crash — C# survives, holds the connection to Neuro, cleans up the dead IPC bench and waits for the module to come back. R8: broken/partial data in files — discard it, do not crash the process. The §1.6 force policy is honored: no force during an active action, only replacement over the current one.

**Blocked by:** 03 (combat loop as the base for resilience checks), 07 (dialogue safely survives a restart — desired).

**Status:** done

- [x] R1: WS drop → auto-reconnect → startup → register → the loop continues; verified by test. (client: `Reconnect_RepairsRegistration`; loop: `WebSocketDrop_Reconnects_RestoresRegistration_ForceReSent_AndActionsContinue` — a re-sent force on reconnect, an action after the drop arrives and is written to the bench)
- [x] R2: mod stop → `mod_unavailable`; start → re-init (registration/states) with no manual intervention. (`ModRestart_StaleDispatchModUnavailable_ThenAliveCleansStandAndResendsForce` + the existing "mod off" Randy E2E: Dispatch → Channel A mod_unavailable without an action file)
- [x] R7: the game process killed via restart — C# does not crash, waits everything out correctly and re-initializes the module. (Stale→Alive transition → `IpcClient.CleanStand()` + reset of `_lastForcedContent` + re-sent force; Lua v0.7.0 `clearInFlight()` on boot cleans up the dead command file)
- [x] R8: a broken/partial write in any of the files → discarded, processing continues. (heartbeat: HeartbeatFileTests; state: `PartialStateFile_SkippedWithoutCrash_ThenValidStateSendsForce` — a partial write does not crash the loop, the action is correctly rejected, a valid state → new force)
- [x] Force policy: a new force over an active one cancels+replaces it (SPEC "one action force at a time"); at most one action executes simultaneously. (`TwoActions_SharedCommandSlot_KeepsOnlyLatestInFlight` — single slot: only the latest action in `neuro_to_bg3.json`; force re-sent on reconnect instead of accumulating)
- [x] End-to-end test: kill/restart the mod and the game mid-scenario, verify the loop self-heals. (`ModRestart_...` — full loop: Alive → Stale → mod_unavailable → Alive → bench cleaned → force re-sent → the action passes again)