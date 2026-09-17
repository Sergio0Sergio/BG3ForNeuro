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

## Run 2026-09-16 (v0.8.31, direct IPC drive — no Randy/C#, no WS, no Neuro)

Bridge: PAK v0.8.31, `21 actions registered`, `autopilot.enabled=false` in `config.json` (only
deterministic injects act). Driving = a helper script writes `neuro_to_bg3.json` and waits for
`result_<id>.json` (RESULT_DIR = IPC_DIR).

### Combat — passed
- [x] **state_capture** — full fresh state written (turn_actor, enemies with aliases + distances, spells).
- [x] **movement**: `move_to_target` Astarion→goblin (clamped 9/10.8 m), Cleric by position (9 m),
      Tav→goblin_tracker_1 (4.2 m) — next state shows distance 6.0→2.2 m.
- [x] **attack**: Tav→goblin_tracker_1 @2.2 m SUCCESS (AP 1→0, enemy HP 9→6); Astarion→bugbear_1 @2.0 m
      SUCCESS (AP 1→0 **and** BA 1→0 — the engine spends both natively for a dual-wield/offhand setup, not a bug).
- [x] **cast_spell**: Astarion `Projectile_FireBolt` SUCCESS (AP 1→0); Shadowheart `Target_HealingWord` on
      self SUCCESS (BA 1→0, HP 9→14); Gale `Projectile_FireBolt` SUCCESS (AP 1→0; target HP unchanged — miss).
- [x] **resource snapshots**: `resource_snapshot_{id}_before/after.json` written for every
      AP/BA-costing action (AP/BA/Movement/Reaction/WeaponActionPoint + cooldowns) — honest economy
      acceptance criterion verified on the bench.
- [x] **end_turn**: all 4 party members (Tav/Astarion/Shadowheart/Gale) — two-phase result
      (`success:true, ended:true`), next acting character reported in `acting_after`.

### Findings / corrections (state + action semantics)
- [x] **The mod reads ONLY `neuro_to_bg3.json`** (singleton). `action_<id>.json` is written by C# for
      tests/debug but is NOT polled by the mod; an action placed only in `action_<id>.json` never executes.
- [x] **Target ids must be state aliases** (`goblin_tracker_1`, `bugbear_1`), not raw UUID/GUID strings:
      `resolveEntity`/`ENTITY_BY_ALIAS` only resolves by alias; a GUID that is present in initiative but
      absent from `state.enemies` (a dead/phantom entity) → `cast_failed` "Каст прерван/провален".
- [x] **`cast_failed` "Каст прерван/провален" originates in the mod's `finalizeCast` (cancelled=true)**,
      not from the engine — always pair it with the actual error path (out-of-range, target changed,
      double action spend).
- [x] **`cast_spell.targets_in_range`/`spell.range` in the state are unreliable**: `spellRangeAndAoe`
      reads `TargetRadius` from `Ext.Stats.Get`, which is nil for Target/Shout-type spells (`Target_*`),
      so the fallback of 1.5 m is bogus for most spells. Prefer `distance` (per-enemy, meters) over range.
- [x] **Check `distance` before casting/attacking**: melee/actions succeed at ≤~2.2 m; Target-type casts
      on a distant enemy hung in `running:true` forever (no `CastedSpell` event) — e.g. Shadowheart
      `Target_SacredFlame` @16.8 m. All successful casts below were at targets already in range.
- [x] **Verify offhand**: `bonus_action.offhand_attack` SUCCESS only when the offhand weapon is equipped
      (`Osi.HasSpell(actor, "OffhandAttack")` gate); Tav BA already 0 → `cast_failed`.

## Run 2026-09-17 (v0.8.33 → v0.8.34, shared-turn `end_turn` fix)

Bridge: PAK v0.8.33, SE v32, direct IPC (`drive_action.ps1`). Combat at the grove gate.

### Finding — `end_turn` blocked on a shared turn
- [x] **Symptom**: `end_turn` for `origin_astarion` → `success:false, error_code: action_failed,
      error_detail: "Turn did not change within the deadline (30 s)"` (`ended:false`); `turn_actor` stuck
      ~13 min while the game stayed responsive (fresh heartbeat, no Lua errors).
- [x] **Root cause**: a BG3 active turn can be **shared** by several allies (same initiative slot). The engine
      ends it only when `TurnBased.RequestedEndTurn` is set on **all** co-active characters; the mod set it on
      the single `acting` actor only → `TurnEnded` never fires. The state hid the co-actives: `acting now` is
      computed only for `turn_actor` (`BG3Neuro.lua:1669`).
- [x] **Proof**: with Astarion stuck, `end_turn {"actor":"tav"}` → `ended:true`,
      `acting_after = S_DEN_GoblinRaider_Captain_22d80f21-…`, `turn_actor` advanced. Matches Command Console's
      `!sailor_endturn` ("ends the turn for all creatures on the active turn").
- [x] **Ruled out**: `Ext.Entity.UuidToHandle(TurnBased.CombatTeam)` → `nil` for the player's own combat
      (`combat_handle:"nil"`), but the `CombatState.Participants` fallback scan works (`stats_probe` = 12 guids),
      so a valid handle was pushed; the blocker was the per-character flag, not the handle.
- Why 2026-09-16 passed: initiatives there were separate (one actor per turn); the bug needs a shared turn.

### Fix (v0.8.34) — verified live
- [x] `requestEngineEndTurn` now also sets `RequestedEndTurn=true` on every entity with
      `TurnBased.IsActiveCombatTurn == true` (new helper `activeTurnEntities()`); handle push unchanged.
- [x] luaparse OK (5.3); PAK built (v040, `Mods/BG3Neuro/…`, MD5 `84FCF350CDC770BE135BA4944BC351AB`).
- [x] **Install + verify**: PAK v040 installed (`modsettings.lsx` MD5 in both entries); SE log shows
      `v0.8.34 loaded` (server+client), no errors. On a **shared** turn a **single** `end_turn` now advances:
      `end_turn {"actor":"origin_astarion"}` → `ended:true`, `acting_after = S_DEN_GoblinRaider_Captain…`,
      state `turn_actor` `origin_astarion` → `za_krug_1` (init 10/18) — the exact call that used to return
      `ended=false` and hang. Fix confirmed.

### Run 2026-09-17 (v0.8.34) — exploration → combat transition (observed)
- [x] **exploration → dialogue → combat**: from `mode=exploration, trigger=free_roam` (35 objects, 0 enemies),
      `move_to_target {"actor":"tav","target_id":"goblin_tracker_1"}` → `mode=dialogue` (`dialog_state`,
      1 response option); `select_dialogue_option {"option_index":1}` → `mode=combat` (`trigger=TurnStarted`,
      14 enemies, `turn_actor=zevlor_1`). The gate encounter is gated by a dialogue, not a pure proximity trigger.
- [x] **new finding (filed)**: `state.enemies` again contains friendly NPCs (`zevlor_1` was `turn_actor` for the
      combat's first turn) — faction misclassification in the state emitter; see
      `.scratch/bg3-neuro-followups/issues/08-enemies-faction-misclassification.md`.