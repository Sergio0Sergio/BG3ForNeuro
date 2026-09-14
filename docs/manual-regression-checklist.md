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

## Run 2026-09-14 (v0.8.25, live benchmark — goblin gate melee, RU locale)

Bridge: PAK v029 (MD5 `96F09777974E194677891D153D7E45D0`), SE v32, `21 actions registered`,
Randy + HTTP inject on `localhost:1337` for deterministic actions, state regenerated on `TurnStarted`.

### Combat — passed
- [x] **turn-loop**: `end_turn` → `ended=true`, acting rotates (Tav `…e6090219` → bugbear `…cde6e700`).
- [x] **attack + damage**: `attack_entity` (fresh Tav turn, AP snapshot 1→0) → `den_goblin_archer_2` HP 9/9→3/9.
- [x] **honest economy**: out-of-range attack leaves AP untouched (snapshot 1.0→1.0); attack at 0 AP → engine
      `CastSpellFailed` (`cast_failed`, no resource theft); snapshots before/after written.
- [x] **refusals in action**: `not_supported` (`use_item`; `bonus_action disengage/dash`), `action_failed`/`not_caster_turn`.

### Resilience — passed
- [x] **corrupt write**: `bg3_to_neuro.json` overwritten with garbage → app logs a single
      `state: failed to parse combat state`, keeps running; state restored, heartbeat continues.
- [x] **WS reconnect**: Neuro killed → `[neuro] disconnected` → auto-reconnect → re-registration
      (`connecting … 21 actions registered`) with no intervention; forcing resumes on the next combat turn.

### Blocked / findings (v0.8.25, state-integration gap)
Mod emits only a combat-shaped state (`captureCombatState`), never the non-combat blocks; the router
`CombatState` (deserialized straight from `bg3_to_neuro.json`) then starves the feature gates:

- [ ] **`cast_spell` (AoE / healing)** — blocked: no `spells` key in state → `CombatState.Spells` empty →
      `ErrorCode.NoSpell` on every `cast_spell`. `CoverageAuto.BestAoECenter` / `IsInRange` exist but are dead code.
- [ ] **Dialog** — blocked: state has no `dialogue` block (speaker/line/options) → `dialogue_closed` on the router;
      additionally `executeDialogueOption` has a `TODO(client)` — no `Ext.UI` click implemented.
- [ ] **Exploration** (`move_to_entity`/`interact_with`/`loot`/`rest`/`travel_to`) — blocked: no
      `objects`/`inventory`/`can_rest`/`regions` in state → `target not found` / `no_camp` / no regions.
- [ ] **Semi-blocked**: `not_in_range` schema code exists only for `cast_spell` (`CoverageAuto.IsInRange`);
      out-of-range `attack_entity` reaches the mod and the engine answers `cast_failed`.
- [ ] **Bench notes**: invalid HTTP injections are dropped silently (no response to the caller); two back-to-back
      injections race on the shared `neuro_to_bg3.json` (a command can be lost); async denials invisible over the inject channel.
- [ ] Resilience №3 (mod/game restart) — not run (requires game restart).

Next: wire the non-combat state emitters (spells / dialogue / exploration) into `bg3_to_neuro.json`,
then re-run the blocked §9.5 items against the full stack.