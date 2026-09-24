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

## Perception — fair perception (contracts 03/04/05, binary model)

Preconditions: B (emission) and A (feasible) implemented, mod gate (04b); bench at the gate,
exploration + combat; `drive_action.ps1` injects strictly serial. Outcomes per `issues/05-acceptance-and-bench.md`.

- [x] **P1 ambush not visible** (v082): exploration at the gate, camera outside the courtyard → 18 enemy entities not in `objects`/`enemies`.
- [x] **P2 LOS entry** (2026-09-21, v0.8.60): the party moved away and came back; on return the ground entities were in `objects` again with current position (`p2s4_front.json`, 18 objects, tav 218.3/31.6/410.3). There is no `perception` field in the state — visibility is expressed by presence/absence; counterexample by distance: 14 entities at 17.5–51.9 m (< `EXPLORE_MAX_DISTANCE=60`).
- [x] **P3 leaving view** (2026-09-21, v0.8.60): the party retreated ~18 m → 16 characters vanished from `objects` (`p2s1_away.json`, 2 objects; `known`/`last_seen` absent). The drop is honest by LOS, not by the 60 m limit: the same entities were at 17.5–51.9 m at S1.
- [x] **P4 combat — full roster** (v082): all combat participants in `enemies`, incl. off-screen and the invisible-silhouette; positions true.
- [x] **P5 refusal on an invisible target** (v082): an action with `target_id` outside `state` → router `TargetMissing` (Channel A); mod `no_perception` (04b).
- [x] **P6 invisible out of combat in frame** (2026-09-21, v0.8.63, PAK v095) — **P6 v2 closed**: the B-gate now cuts masked actors. `sightSees` after a positive LOS calls `BG3NEURO_SIGHT.isMasked` (raw `StatusMachine`: the target has `INVISIBLE`/`SNEAKING`, and the leader has no `TRUESIGHT`/`MOD_Generic_Truesight` and see-invisibility ≤9 m; fail-open). Verified live on the bench (file bridge, `perception_probe`): baseline `masked=[]` (18 non-party objects = exactly the `los=true` rows; ~20 entities with `is_invisible:1` without a masking status are **not** cut — the spec trap §2 confirmed); `apply_status INVISIBLE` on Ogre Brute → `masked=["Ogre Brute"]`, `objects` **18→17**; `remove_status` → 18; `SNEAKING` → masked; `TRUESIGHT` on the leader → exception (`masked=[]`). Server `v0.8.63 loaded`, no Lua errors, dispatch median 11.1 ms. NB: `Osi.IsInvisible` is not used in the gate.
- [x] **P7 party** (v082): actions on allies (cast/move/attack) pass the perception gate.
- [x] **P8 AoE point** (v083 r9): `cast_spell` with `position` — not gated by perception in v1.
- [x] **Regression** (2026-09-21, v0.8.60): the Combat/Exploration boxes of §9.5 stay green after enabling the filter — roster, turn loop, healing and economy re-verified via the file bridge (see "Run 2026-09-21 (v0.8.60)"). Feeding: an unknown spell is not rejected on the honest path (fixed and verified live in v0.8.61, follow-up `unknown-spell-stuck-cast`).
- [x] **Cost** (2026-09-21, v0.8.60, live log `Extender Runtime 2026-09-21 13-47-00.log`):
  emission median ≤ 20 ms met in both modes — **exploration** (`exploreLoop`,
  `:5795`) n=336, **med 11.20 ms**, p90 14.17, max 18.16; **combat** (`TurnStarted`/
  `captureCombatState`, `:500`) n=25, **med 9.51 ms**, p90 14.05, max 18.93. Both medians
  are below the threshold; the previous 23.4/38.5 ms (ticket 21) were single outliers on a heavier field,
  not reproducible (ticket 21 closed: threshold met, no optimization needed).

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
      absent from `state.enemies` (a dead/phantom entity) → `cast_failed` "Cast aborted/failed" (RU-locale
      engine string, translated).
- [x] **`cast_failed` "Cast aborted/failed" (RU-locale engine string, translated) originates in the
      mod's `finalizeCast` (cancelled=true)**,
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

### Run 2026-09-17 (v0.8.35) — ability catalog / friendly names (VERIFIED)

PAK v041 (`Mods/BG3Neuro/…`, MD5 `3C1274B11D48EB97F3588CAED8E72CFD`) installed; SE log `v0.8.35`,
heartbeat `version 0.8.35`. Combat at the grove gate, `turn_actor=tav`. Actions injected via a local
WS server on `:8000` (so the C# `ActionRouter` runs), and (for the safety net) straight into
`neuro_to_bg3.json`.

- [x] **catalog present**: `state.spells` (18 entries for Tav) carries `name` + `cost`, e.g.
      `{"spell_name":"Target_OpeningAttack","name":"flourish","cost":"bonus_action","range":1.5,
      "targets_in_range":["goblin_tracker_4"]}`; also `piercing_strike` (`Target_PiercingThrust`,
      action), `weakening_strike` (`Target_HinderingSmash`, action), `jump`/`dip`/`shove` (bonus_action).
- [x] **advertised**: `available_actions` lists
      `cast_spell: [jump, dip, hide, shove, throw, improvised_melee_weapon, dash, help, disengage,
      fire_bolt, main_hand_attack, second_wind, hamstring_shot, action_surge, ranged_attack,
      flourish, piercing_strike, weakening_strike]`.
- [x] **friendly-name cast (C# router)**: WS inject
      `cast_spell {"actor":"tav","spell_name":"flourish","target_id":"goblin_tracker_4"}` →
      app logged the action; **`action_b9r1.json` trace shows `spell_name` rewritten to
      `Target_OpeningAttack`**; `result_b9r1.json` `success:true`; snapshots
      `resource_snapshot_b9r1_before/after.json` → **BonusActionPoint 1.0 → 0.0**, AP/Movement unchanged.
- [x] **Lua safety net (direct inject)**: writing `neuro_to_bg3.json` with the friendly name
      `piercing_strike` (bypassing the router) → `cast_debug.json` `spellName: Target_PiercingThrust`,
      `result_b9r2.json` `success:true`, ActionPoint **1.0 → 0.0** (BA unchanged). The mod resolves
      friendly → engine id on its own.
- [x] **engine id passthrough**: WS inject with `spell_name":"Target_MainHandAttack"` →
      `action_b9r3.json` shows `spell_name` **unchanged** (no bogus rewrite). (The cast itself failed —
      AP had been spent — see the new finding below.)
- [ ] **C# markdown rendering** — NOT observable live: with `autopilot.enabled=false`,
      `DecisionLoop.MaybeForceAsync` returns early (`DecisionLoop.cs:102`) and the app never sends the
      state markdown. Coverage is the unit test
      `StateSerializerTests.ToMarkdown_FriendlyAbility_RendersNameEngineIdAndCost_OmitsZeroSlot`.
      To see it live, temporarily set `autopilot.enabled=true` and capture the WS `context` frame.

#### New finding — false success on a failed cast (fixed in v0.8.36, ticket 11)
- [x] **Before:** `CastSpellFailed` → `finalizeCast(caster, spell, true)` → the old
      `writeResult(pc.id, **true**, false, "cast_failed", "Cast interrupted/failed")` wrote
      `success:true` together with `error_code:cast_failed` (`result_b9r3.json`), and the app
      forwarded `success:true` to Neuro.
- [x] **Fix (v0.8.36):** `success = not cancelled` at `finalizeCast`, plus a `writeResult` invariant
      (`error_code` present ⇒ force `success=false`, logged). PAK v042 (`B2C762EA1FDA30573DB00A51795C89E6`)
      installed; SE/heartbeat `v0.8.36`.
- [x] **Verified live:** `c10a` `flourish` (friendly, router) → `success:true`, BA 1.0 → 0.0; `c10b`
      `Target_MainHandAttack` → `success:true`, AP 1.0 → 0.0; `c10c` the same cast again at AP=0 →
      `result_c10c.json` **`success:false, error_code:cast_failed`**, and the WS frame was
      `{"id":"c10c","success":false,"message":"Cast interrupted/failed"}`. The exact call that used to
      report success now reports failure.

### Run 2026-09-18 (v0.8.41) — combatant conditions / status effects (VERIFIED)

PAK v047 (`Mods/BG3Neuro/…`, MD5 `F18A5203E4E6BE0B98F87172FDC3DC4A`) installed; heartbeat
`version 0.8.41`. Grove-gate combat driven straight through `neuro_to_bg3.json` (`drive_action.ps1`;
no C#/WS/Neuro). Ticket 13.

- [x] **conditions on enemies**: state `enemies` → `goblin_tracker_3` `conditions:[FLANKED]`,
      `wyll_1` `conditions:[FEATHER_FALL, duration_left 29.9]`.
- [x] **allies clean**: `tav` / `poc_player_cleric` / `origin_astarion` / `poc_player_wizard` have no
      conditions, only the `availability` string (`acting now` / `can act`).
- [x] **engine-internal statuses filtered**: raw dumps show every creature carrying
      `HEALTHBOOST_HARDCORE`, `ENABLE_AOO`, `AI_NO_LOOK_AT_BATTLE`, `GOBLIN_HARDCORE`, `INSURFACE`;
      none reach the state.
- [x] **discriminator = stats `Icon`**: `stats_probe` on the 12 combatants → the four internal ids have
      `Icon` empty, `FLANKED` has it set. `DisplayName` is set for **all** statuses (no signal),
      `Visible` does not exist, `StatusPropertyFlags` is an opaque userdata.
- [x] **no `turns_left`**: `Osi.*Status*` absent from the runtime Osi table; `TickType = 0` for every
      status; `TurnTimer` is a seconds countdown (4.375 / 0.715), `CurrentLifeTime` is seconds
      (`FEATHER_FALL` 29.9) or -1 (permanent). State emits only `duration_left`.
- [ ] **`flourish` → Off Balance assert** — NOT reproduced in this save: Astarion has no `flourish`
      (only `hamstring_shot` / `piercing_strike`), and `hamstring_shot` at a 9-HP goblin killed it
      before capture. Covered by `FLANKED` / `FEATHER_FALL`; retry on a high-HP target for `HAMSTRUNG`.
- [ ] **C# markdown `conditions:` line** — same limitation as the v0.8.35 run (autopilot off ⇒ no
      context frame); covered by `StateSerializerTests` (155/155).

### Run 2026-09-18 (v0.8.46) — hostility-based enemy classification (VERIFIED)

PAK v052 (`Mods/BG3Neuro/…`, MD5 `F5930A1130DCBA2036E49C244B6927E0`) installed; heartbeat
`version 0.8.46`. Grove-gate combat driven through `neuro_to_bg3.json` (`drive_action.ps1`). Ticket 14.

- [x] **engine hostility drives the split**: `state_capture` result `diag` →
      `osi_hostility:true`, `hostility:{ally:9, enemy:8}`, `skipped_non_character:1`, `participants:18`.
- [x] **allies no longer misclassified**: state `allies` = 9 — party
      (`tav`/`poc_player_cleric`/`origin_astarion`/`poc_player_wizard`) **plus** the 5 tieflings
      (`wyll_1`/`zevlor_1`/`remira_1`/`aradin_1`/`barth_1`) that ticket 08's reproduction listed as
      enemies.
- [x] **enemies = hostiles only**: 8 entries — `worg_1`, `goblin_booyahg_1`, `bugbear_1`, `za_krug_1`,
      `goblin_brawler_1`, `goblin_tracker_1/2/3` (no tieflings).
- [x] **non-character skipped**: the portcullis is excluded (`diag.skipped_non_character = 1`) — no
      `objects` entry, no `enemies` entry.
- [x] **root cause captured**: `Osi.__index` is BG3SE's lazy C name resolver
      (`LuaNameResolver.inl`); the first access to each name throws `attempt to call a nil value` but
      caches the proxy, so `Osi.IsEnemy ~= nil` always fails while `Osi.IsEnemy(a,b)` works. `stats_probe`
      v0.8.45 confirmed: party `IsEnemy=0/IsAlly=1`, goblinoids/worg `IsEnemy=1/IsAlly=0`. The fix calls
      the proxies directly and warms the resolver.

### Run 2026-09-18 (v0.8.47) — displayName Osiris fallback un-dead (VERIFIED)

PAK v053 (`Mods/BG3Neuro/…`, MD5 `038E71B4009E640E465D2E252C61F7BF`) installed; heartbeat `version 0.8.47`.
Same grove-gate combat. Ticket 15.

- [x] **dead guard removed**: no `type(Osi.GetDisplayName) == "function"` left in `BG3Neuro.lua`
      (grep clean); shared helper `osiDisplayNameOf(guid)` calls `Osi.GetDisplayName` directly under
      `pcall` with a one-time resolver warm-up (`luaparse` OK on both Lua files).
- [x] **fallback is live**: SE log (`Osiris Runtime 2026-09-18 06-05-49.log`) shows the mod's
      `exec [DIV query] GetDisplayName( … )` → `Query returns: GetDisplayName( …, "ResStr_…" )`
      (acting char + 4 clean guids) — the Osiris fallback now runs and never throws.
- [x] **state regression-free**: `state_capture` (sc9) `success:true`, `allies`=9 / `enemies`=8
      (same as v0.8.46), every `name` field human-readable (Tav, Wyll, Zevlor, Remira, Aradin, Barth,
      Goblin Booyahg, Bugbear, Goblin Brawler, Worg, Goblin Tracker) — component path still wins.
- [x] **no Lua errors** during captures.

## Run 2026-09-19 (v0.8.55 / PAK v062, full stack §9.5 — game + App + Randy)

Bridge: PAK v062 (MD5 `3E4A030174141010336BE21B36E1BAA7`), SE heartbeat `0.8.55`,
App (`bench_config.json`, `autopilot.enabled=false`, 17 actions registered) on WS
`ws://localhost:8000`, Randy (WS `:8000` + HTTP `:1337`) as deterministic injector.
Grove-gate combat, injects strictly serial via `POST /` + `data` as JSON string.

### Combat via stack — passed
- [x] **turn-loop**: `end_turn` (Astarion → Tav group; Tav → …; cleric) → `success:true`,
      `ended:true`, next `turn_actor` in state (ids e95-1/2/3).
- [x] **attack + damage**: `attack_entity` Tav → `goblin_tracker_2` → `success:true`,
      AP 1.0→0.0, HP 9→2 in the next state (id a95-1).
- [x] **friendly cast E2E (tickets 16/18)**: `cast_spell` Guidance cleric → Astarion
      (friendly NAME through the C# router) → `StatusApplied(GUIDANCE)` in SE log,
      AP 1.0→0.0 deducted, `success:true` over WS (id c95-2). **Required a C# fix:**
      `ActionRouter.ValidateCast` looked targets up in `Enemies` only
      (`"not found among enemies"`) — now searches `Allies` too (commit with test
      `CastSpell_AllyTarget_Succeeds_ForFriendlyBuffs`, 53/53 router tests).
- [x] **healing via stack**: `cast_spell` Healing Word cleric → self → `success:true`,
      BA 1.0→0.0, AP untouched, L1 1.0→0.0 (id h95-1).
- [x] **refusals with actionable messages**: unknown `wish` → `success:false`,
      `"Spell 'wish' unavailable. Known: bane, bless, …"` over WS (id r95-1).

### Resilience via stack — passed
- [x] **WS reconnect**: Randy killed → `[neuro] disconnected` (3s retries, app alive,
      mod Alive) → Randy restarted → `connected`, re-registration, `end_turn`
      succeeds again (id e95-3). No intervention.
- [x] **corrupt write**: `bg3_to_neuro.json` overwritten with garbage → single
      `state: failed to parse combat state`, process alive; file restored, no errors.

### Findings / notes
- [x] **Randy retry storm**: any FAILED injected action makes Randy re-send it with
      faker-garbage data in a 500 ms loop (`action/result → !success → sendAction`,
      `Randy/index.ts:95-96`) — each failure reseeds the storm. Bench hygiene: restart
      Randy after every EXPECTED failure (done twice this run: 95b, 95c). Consider an
      upstream env flag to disable faker retries during deterministic benches.
- [ ] **AoE `CoverageAuto` via stack** — not run (needs a fresh Gale turn + Thunderwave;
      router-side `BestAoECenter` covered by unit tests only).
- [ ] **Dialog / Exploration via stack** — not run (save loads straight into combat;
      dialog→combat transition was verified 2026-09-17 via file bridge).
- [ ] **Mod/game restart resilience** — not run (requires PAK swap + restart mid-bench).

## Run 2026-09-21 (v0.8.59 / PAK v090, ticket 06 — ranged cast honesty, gates ambush)

Bridge: PAK v090 (MD5 `40F45BC5470724BEDBB1A8733319D625`), SE heartbeat `v0.8.59`, live game
via file bridge, deterministic injects (serial, `drive_action.ps1`). Diagnosis ladder:
v086 (Osi lazy-resolver warm-up + retry) → v087 (TargetRadius fallback) → v088
(`prevalidate_latest.json` diagnostic) → v090 (final). Root cause found via `caststats`:
`Projectile_FireBolt` = `Range=0` (NUMBER), `TargetRadius=18`, `SpellType=Projectile`.

### Ticket 06 — passed
- [x] **honest no_range before the engine** (id c05): `cast_spell fire_bolt` tav →
      `goblin_tracker_3` at 20.2 m (range 18) → `action_failed` `"no_range:
      Projectile_FireBolt target … is 20.2 m away (range 18 m)"`, verdict in
      `prevalidate_latest.json` = `no_range`; projectile does NOT get re-targeted
      by the engine (no "lightning into the corpse", no visual).
- [x] **in-range control** (id c06): `fire_bolt` tav → `goblin_tracker_1` at 1.9 m →
      verdict `pass`, engine accepts (`success:true`). Correct in/out discrimination.
- [x] **in-range projectile path** (v085 b07g): Gale `fire_bolt` → target at ~7 m →
      `success`, projectile visually flies INTO the target (user), fair miss (no damage).
- [x] **diagnostic tooling**: `prevalidate_latest.json` (range, dist_1/final, los,
      verdict) written per cast; session median 12.16 ms over 189 dispatch iterations.
- [x] **no regression**: cast_failed no longer masks engine re-targeting; sneak
      without advantage is refused by the engine itself (`cast_failed`) — not a
      projectile-path test.

Ticket 06 closed `resolved`. Follow-ups remain: mechanic №2 (in-range "bless lands on
self / sneak at caster" — not reproduced after fix), multi-target bless (separate
ticket), P2/P3 LOS walks, combat-capture cost (ticket 21).

## Run 2026-09-21 (v0.8.60, perception regression §9.5 — combat/turn/heal, file bridge)

Bridge: SE heartbeat `v0.8.60`, file bridge only (App/Randy did not take part),
injects strictly serial (`drive_action.ps1`). Save = before the ambush at the gate; the ambush
was triggered manually. Artifacts: `artifacts/reg0_combat.json` … `reg7_cap.json`.

### Regression after enabling the filter — passed
- [x] **full roster** (`reg0_combat`): `mode=combat`, `turn=tav`, 8 enemies
      (`goblin_brawler_1`, `za_krug_1`, `bugbear_1`, `worg_1`, `goblin_tracker_1..3`,
      `goblin_booyahg_1`) + 9 allies — the filter does not hide legitimate participants.
- [x] **attack on a visible enemy** (id `reg1_attack`): `attack_entity` tav →
      `goblin_tracker_2` (1.2 m) → `prevalidate verdict=pass`, `sid=Target_MainHandAttack`,
      the cast went into `OsirisCastRequests`; **resource snapshot AP 1.0→0.0**. A miss on the roll
      (HP 9/9) — `success:true` ≠ damage.
- [x] **turn loop** (id `reg2_end`, `reg3_end`): `end_turn` ×2 → `ended:true`, `turn_delta`;
      order `tav → aradin_1 → origin_astarion → za_krug_1 (AI) → remira_1 (AI) → cleric`.
- [x] **healing** (id `reg6_heal`): the cleric's turn (Shadowheart), `cast_spell healing_word`
      → self → `economy`: `BonusActionPoint 1.0→0.0`, `SpellSlot L1 1.0→0.0`;
      `state_capture` → HP **9→13**. `mode=combat`, `spells=57`.

### Findings / notes
- [x] **`bg3_to_neuro.json` in combat is written only on `TurnStarted`** (and on mode change),
      not after actions — the post-effect of an action (damage/healing) is only visible via
      a forced `state_capture` (`BG3Neuro.lua:5473`). For the bench, pull `state_capture` after each action.
- [x] **`availability` in the state reflects turn ownership, not remaining AP** — after the attack
      tav showed "acting now, can act" even though AP was already 0 (resource snapshot). Judge the economy
      only by `resource_snapshot_<id>_{before,after}.json`, not by `availability`.
- [x] **FEEDING — an unknown spell is not rejected on the honest path** (id `reg8_refuse`, v0.8.60):
      `cast_spell wish` → the mod assembled `spell=wish` (`SourceType: Osiris`), castOptions
      `IgnoreHasSpell,IgnoreCastChecks,IgnoreSpellRolls,IgnoreTargetChecks,Forced,Immediate`,
      placed it in `OsirisCastRequests` (**size=1, not drained**); `result_reg8_refuse.json`
      stays `running:true` forever, the action never finalizes. A proper `no_spell` exists only on the
      legacy path (`use_osi_spell`, `:4443`) and in the C# router (validates the name before the mod). On the
      honest path `executeCast` does not check the book — follow-up
      `bg3-neuro-perception/issues/07-unknown-spell-stuck-cast.md`.
      **Fixed and verified live (v0.8.61, 2026-09-21):** a single book guard `Osi.HasSpell`
      before enqueue, fail-open. `cast_spell wish` → immediate final `success:false,
      no_spell: wish is not in the caster's book`; `cast_spell fire_bolt` (valid) → `success:true`,
      AP 1.0→0.0. See "Run 2026-09-21 (v0.8.61)".
- Note: in this save `bg3_to_neuro.json` `party_refs` = only Tav + Shadowheart
      (the party is trimmed), but `allies`=9 includes allied NPCs (`aradin_1`, `wyll_1`, `zevlor_1`…).

## Run 2026-09-21 (v0.8.61, ticket 07 fix - file bridge, combat save)

Goal: live verification of the book guard (see above). PAK v092 installed, `heartbeat.version = 0.8.61`.

- [x] **Negative — `cast_spell wish`** (id `t07_wish`, Tav's turn): the result is finalized immediately
      `{ success:false, error_code:"action_failed", error_detail:"no_spell: wish is not in the caster's book" }`;
      `running:true` no longer hangs, the osiris request is not pushed.
- [x] **Fail-open — `cast_spell fire_bolt` → `goblin_tracker_2`** (id `t07_firebolt`): the friendly name
      resolved to `Projectile_FireBolt` (`cast_debug.json`), final `success:true`,
      `resource_snapshot_*`: **ActionPoint 1.0 → 0.0** (BA/slots unchanged).
- [x] **Pipeline alive after refusal**: `heartbeat` fresh, `cast_debug.json` `queueSize=0`.
- Artifacts: `result_t07_wish.json`, `result_t07_firebolt.json`,
      `resource_snapshot_t07_firebolt_{before,after}.json`, `cast_debug.json` in
      `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\BG3Neuro\`.