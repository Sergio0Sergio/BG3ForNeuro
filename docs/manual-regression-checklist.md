# Manual regression checklist (§9.5) — real game + real Neuro

Mandatory run **before release** (test layer C). Automated tests cover the logic against simulated states; these scenarios are the final trust check on the real game.

Before running:
- a **test scene with a single enemy** is set up (combat checks);
- the mod is hooked into the BG3SE server context, and the C# process and Neuro are running;
- OK in the log: `[ipc] mod: Unknown -> Alive`, `[neuro] connected`, `[neuro] session: …`.

## Bridge status (run 2026-09-06, Patch 8 + HotFix 9, SE v32, `Ext.Utils.GameVersion()="v4.73.98.727"`)

- [x] **The mod is accepted by the engine and stays in the load order**: `modsettings.lsx` stores BG3Neuro
      (backup of the vanilla one: `PlayerProfiles\Public\modsettings.lsx.vanilla.bak`); the MD5 of the
      `Mods\BG3Neuro.pak` content matches the MD5 embedded in `modsettings.lsx` (and in the Steam cloud mirror).
- [x] **SE brings up the Lua bootstrap**: in `Script Extender Logs\Extender Runtime ....log` —
      `'BG3Neuro': SE v32; flags: Lua`, `Loading bootstrap script: Mods/BG3Neuro/ScriptExtender/Lua/BootstrapServer.lua`,
      `[BG3Neuro] v0.7.0 loaded (server)`.
- [x] **Osiris listeners are hooked to the real game signatures**: **0** occurrences of
      `Symbol not found in story` and **0** `Osiris event handler failed` in the log.
- [x] **Heartbeat in ISO-8601 UTC** (`Ext.Timer.ClockTime()` → `T…Z`; `os` in the SE sandbox = nil,
      `Ext.Print`/`Ext.PrintError` = nil, output via `_P`) — `BG3Neuro\heartbeat.json`.
- [x] **The C# bridge sees the mod and Neuro**: output of `BG3Neuro.App.exe`:
      `[ipc] mod: Unknown -> Alive`, `[neuro] connected`, `17 actions registered`; Randy accepted
      `startup`/`register`.

Fixed event signatures of this build (verified against the game story
`Story\RawFiles\Goals\__PROC.txt`/`GLO_Camp.txt`/`__GLOBAL_Dialogs.txt` when unpacking
`Shared.pak`+`Patch8_HotFix9.pak`):

| Event | Arity | Fact in game |
| --- | --- | --- |
| `CharacterMoveToCancelled(_Char,_ID)` | 2 | signature from the story |
| `CastSpell(...)` / `CastedSpell(...)` | 5 | fired in the session (capture `CastSpell@5`) |
| `CastSpellFailed(_Caster,_Spell,_SpellType,_SpellElement,_StoryActionID)` | 5 | signature from the story |
| `DialogStarted(_Dialog,_Inst)` / `DialogEnded(_Dialog,_Inst)` | 2 | fired (capture `DialogStarted@2`) |
| `DialogStarting` | — | **not an event** — listener removed |
| `LongRestFinished()` / `LongRestCancelled()` / `LongRestStartFailed()` | **0** | signatures from `GLO_Camp.txt` |

SE v32 quirk: `RegisterListener(name, arity, event, handler)` registers the listener only when the
arity exactly matches the event declaration; on a mismatch it silently writes
`Couldn't register Osiris subscriber for <name>/<arity>: Symbol not found in story` to the log, and `pcall`
does NOT surface this — the error is only visible in the Extender Runtime log.

## Combat

- [ ] **1v1**: entering combat → force with `## Turn: …` → `end_turn` → next turn in the state → new force.
- [ ] **1 vs many**: entering combat with a group ≥2 → `move_to_target`/`attack_entity` at the selected target → damage visible in the next state (`HP …/…`).
- [ ] **AoE**: `cast_spell` with an AoE spell and empty `coverage` → autonomous target from `CoverageAuto` → failure/success reflected in the state.
- [ ] **Healing**: `use_item` (potion/healing spell) on self/ally → HP increased in the next state.
- [ ] **Refusal codes in combat**: `no_spell` (spell not in the list), `not_in_range` (target out of range) — `action/result` arrives with an actionable message, no action file is written.

## Dialog

- [ ] **Simple choice**: dialog → force `## Dialog` with `[1]…` → `select_dialogue_option` → the line changed in the next state, the window closed → force for combat/exploration.
- [ ] **Quest dialog**: a branch of several consecutive choices; after the quest completes — correct next mode.
- [ ] **Closed dialog**: `select_dialogue_option` without an active dialog → `dialogue_closed` via Channel A.

## Exploration

- [ ] **Movement**: `move_to_entity` → object in the state with updated distance, movement interrupts an active one.
- [ ] **Interaction**: `interact_with` (door/lever/loot) → object state change in the next state.
- [ ] **Loot**: `loot` from a corpse/container → items in the inventory in the state.
- [ ] **Rest/travel**: `rest` full (camp) / without camp → `no_camp`; `travel_to` by location name and by `region_id`.

## Resilience (ticket 09)

- [ ] **WS reconnect**: Neuro disconnect → auto-reconnect → `startup`+`register` repeated → the loop continues without intervention.
- [ ] **Mod/game restart**: kill the mod/game → `mod_unavailable` on actions → restart → re-init (`Stale→Alive`): the dead bench is cleaned up, fresh force, actions pass again.
- [ ] **Corrupt write**: manually overwrite `bg3_to_neuro.json` with garbage → the process stays alive and continues processing after the file is restored.

## Exclusions

- [ ] Purchasing/trading — **out of scope v1** (not tested).
- [ ] Stealth `toggle_mode "stealth"` — **out of scope v1** (no public API).
- [ ] `throw`, voice, multiplayer, camera — **out of scope v1**.

Result: all items checked + 139 automated tests green (`dotnet test` + `tests\smoke.ps1 -Full`) → release candidate. Project entry point — `README.md`.