# 05 — Acceptance and bench plan for the perception spec

Type: grilling
Status: resolved
Blocked by: 03

## Question

How we prove the spec live and how to wire it into regression.

Sub-questions (aligned with the binary model, ticket 03: `known`/`last_seen` cut out — there is no «known but not seen» scenario):

- **Acceptance scenarios** at the gates: ambush before the cutscene (enemies offscreen — NOT emitted); entering LOS (appears in `state` with an actual position; no `perception` field); leaving sight (disappears from `state` — nothing to «carry over»); combat (all participants in `enemies`, including offscreen and invisible-silhouette ones); refusal on an invisible target (target not in `state` → `TargetMissing` router / `no_perception` mod); invisible out-of-combat on frame (not emitted); party (always in `state`, actions against it are not gated).
- **What counts as proof**: state lines (snapshot JSON), SE log, inject ids, `drive_action.ps1` (style of tickets 18/19, serial injects strictly one at a time).
- **Place in the checklist**: new box(es) in `docs/manual-regression-checklist.md` (§9.5 and the general one).
- **Regression**: existing combat/heal/fair-economy scenarios (§9.5) must not break — perception must not hide already-visible enemies from legitimate targeting.
- **Cost**: the per-tick performance threshold at which the filter is deemed unfit.

## Deliverable

- List of acceptance scenarios with expected outcomes (binary model).
- Edits in `docs/manual-regression-checklist.md` (draft of lines).
- Explicit criteria of «spec ready for implementation».

## Verification

- Each scenario is unambiguous (input → expected state/refusal), reproducible manually.

## Execution (v082, 2026-09-20, bench at the gates, PAK MD5 1F0F921033F074BBBE24E83CD2AE0F50)

Snapshots: `artifacts/05-p4-combat-roster.json`. Serial injects (single-slot), autopilot off.

### P4 — Combat: full roster ✓ (live)
Input: moving `move_to_entity sword_spider_1` (R1, exploration) provoked combat at the gates.
Result: `mode=combat`, `turn_actor=tav`, initiative 1/18;
`enemies=8`: goblin_tracker_2/3/4 (1.8–19.8 m, including offscreen 19.8 m), goblin_brawler_2,
goblin_booyahg_2, za_krug_1, bugbear_2, worg_1 — i.e. those the B-gate did NOT emit in exploration.
`allies=9`: party + wyll/zevlor/remira/aradin/barth (all in the roster).

### P7 — Party / visible target in combat ✓ (live)
- R3 (exploration) `cast_spell guidance → tav`: perception gate PASSED → honest `not_caster_turn`.
- R5 (combat, Tav's turn) `cast_spell fire_bolt → bugbear_2`: perception gate passed (enemy in actors),
  honest cast executed — `result_r5.json: success:true`.
- R6 (combat, group turn; caster origin_astarion) `cast_spell "Sneak Attack (Ranged)" →
  goblin_tracker_4` (nearest, 1.8 m): human-name resolution went through, cast executed
  (success:true) — BUT damage 0: point-blank shot suffers disadvantages, sneak bonus does not trigger
  (9/9 HP). Finalization = the CastSpell event, not damage — a successful cast ≠ a successful hit.
- R7 (same caster, same turn) `Sneak Attack (Ranged) → goblin_tracker_3` (19.8 m) →
  `cast_failed: Cast interrupted/failed` — Astarion already spent his action on r6, the engine
  honestly rejected the cast (economy works). The point-blank shot at the far target is deferred to
  the next turn (or an explicit move back before the cast).

### P5 — Refusal on an invisible target ✓ (mod layer already in 04b; router — unit tests)
- R4 (exploration) `move_to_entity` guid of a goblin behind the barricade (LOS=0, not emitted) → `no_perception`.
- R2 `cast_spell → goblin_tracker_1` (visible in objects-category; cast=actors) → `no_perception`
  (consistent with the router matrix).
- Router layer: `TargetMissing` by unit tests 163/163 green.

### P1 — Ambush not visible ✓ (by B emission)
Exploration emission v082 at the gates = 18 entities, ALL with `HasLineOfSight(lead, *)==1`
(e.g. sword_spider_1 11 m, aradin_1 29 m, memnos_1 54 m). Goblins behind the barricade
(ebe03162..., LOS=0 by the v079 diag) were NOT emitted in exploration (but in combat made it into enemies —
this is P4). The emission list is fixed as text (the exploration snapshot was overwritten by combat).

### Cost (measurement from `Dispatching ... took N ms`, this session)
- Exploration tick (WaitForRealtime callback): v081 10.8–13.8 ms (under the 20 ms threshold)
  → **the clean exploration measurement is finalized after combat ends**.
- Combat: TurnStarted handler (`captureCombatState`) = **23.4 / 38.5 ms — above the 20 ms threshold**.
  Event-driven (on turn change), not on the 500 ms tick, but formally exceeding the threshold → the
  optimization question is open (conditions/health per participant, spells-block) OR reconsidering the
  threshold for the event-driven path. → Recorded in `docs/manual-regression-checklist.md` +
  follow-up ticket `bg3-neuro-followups/issues/21-combat-capture-cost.md` (2026-09-21).

### P2 / P3 / P6 / P8 — remain
- P2 (entering LOS) and P3 (leaving sight): by bench with a step-by-step walk after the combat (or
  the emission analogue already shown by P1↔P4: the same entity outside LOS is not emitted,
  in combat — in the roster).
- P6 (invisible NPC out of combat on frame): **closed in P6 v2** (2026-09-21, v0.8.63, PAK v095,
  followup `24-invisible-b-gate.md`) — the B-gate cuts `INVISIBLE`/`SNEAKING` (raw `StatusMachine`,
  exceptions `TRUESIGHT`/see-invisibility ≤9 m); verified live with `perception_probe`: `masked=["Ogre Brute"]`,
  `objects` 18→17, remove → 18, `TRUESIGHT` → exception. `Osi.IsInvisible` is not used in the gate (spec §2).
- P8 (positional AoE): to verify after combat — a cast with `position` (without target) must NOT
  be gated by `no_perception` (by the logic the gate skips only targeted casts).

## Additional bench (v083, 2026-09-20, re-entry)

### v083 — distance reference frame ✓ (see the fix below)
`distance_reference=tav` in exploration (first party avatar), allies/combatants have `position_z`,
objects have `position_x/y/z` (ogre_brute_1 at 204/25/419). State: 18 objects at the gates,
distances — from Tav. Any further «nearest» picks must be computed BY coordinates.

### P8 — positional cast without a target ✓ (live)
r9: `cast_spell actor=tav spell_name=fire_bolt position={x:205,y:29,z:400}` (empty spot behind
the party, no target_id) → NOT `no_perception`, NOT `no_aoe_target`, cast executed (`success:true`).
Conclusion: the perception gate 04b skips position-only casts, as designed.

### r8 — entering the barricade spot raised the ambush again (4th time, P4 plus)
`move_to_entity → ogre_brute_1` led to a dialogue (the ambush opening scene) → selecting
`Continue.` via `select_dialogue_option` (dialogue bridge, success) → ambush: `mode=combat`,
enemies=8 (including hidden ones), allies=9, `turn_actor=tav`. One more confirmation of P4
(«not perceived in exploration → combatants in cycle»).

### r10 / manual flourish — miss + honest-path divergence
r10 (`flourish → goblin_tracker_3`, on Tav's own turn) → `cast_failed: Cast interrupted/failed`, while
`bench_snapshot` of Tav reads `ActionPoint=0` (action spent on r9). The user manually
cast flourish on the same turn — the game allowed it. Bottom line: 0 damage on all enemies = **the maneuver
missed** (CastSpellDefinitive ≠ damage, per the rule). Open question of casting the maneuver:
- why the honest osiris queue refused on the player's own turn, while the game allowed it manually —
  is `ActionPoint` read incorrectly (maneuver budget book/WeaponActionPoint), or is it the
  queue channel (osiris vs `network` for player casts on own turn);
- data point: r9 (positional fire_bolt, osiris) cast visually — the channel is not a priori broken.
Action — a ticket to check `QueueName "network"` for player's own-turn casts + cross-check
`Osi.GetActionPoint`/component. Not an acceptance blocker (level of emulation, behavior more honest
than the engine, but does not match the UI).

### Combat state is written event-driven (TurnStarted), not by ticks — confirmed live
Tav's turn lasted 10+ minutes (r9 cast, r10 fail, manual flourish, melee -1hp on tracker_3):
`bg3_to_neuro.json` mtime froze at the TurnStarted moment (18:17:40), HP in the file = full 9/9,
although damage was dealt in the game. Code: captureCombatState is called from the TurnStarted listener
(BG3Neuro.lua:511), exploration — periodic loop (line 5582, line 5581). In combat the loop
5681/5581 is ABSENT — only the turn event. Contract for the App: inside a turn, HP/AP/positions in the state —
from the turn start; fresh values arrive on turn change. Not a bug; confirmation of the chosen
architecture (event-driven combat). Note: if acceptance needs an intra-turn damage stream —
a separate question (NOT in v1).

### P2/P3 — hindered by the scripted ambush
Every move toward the camp triggers the story ambush (dialogue → combat), which is why the clean
«walk → LOS-flip of an object» in exploration was interrupted twice. P2/P3 are finished AFTER the combat: step back to
the gates, check that the hidden goblins disappeared again from the exploration objects (this is exactly
P3), then if needed — a precise single step to the LOS boundary and back.

## P2 / P3 (v0.8.60, 2026-09-21, bench «save BEFORE the gate ambush»)

A series of snapshots over a single file bridge (App/Randy not involved; injects not needed —
`bg3_to_neuro.json` was read directly, the mod writes the exploration state periodically). Snapshots:
`artifacts/p2s0_gate.json`, `p2s1_away.json`, `p2s2_back.json`, `p2s3_closer.json`, `p2s4_front.json`.

Steps (the party moved manually; `EXPLORE_MAX_DISTANCE = 60`, `BG3Neuro.lua:2636`):
- **S0** `tav 219.1/31.4/409.6` → **18 objects**, all `character`, `seen_by=player`, distances 11–55 m.
- **S1** retreat ~18 m `tav 234.3/26.3/400.8` → **2 objects** (`kanon_1` 51.9 m, `door_1`). 16 characters disappeared → **P3**.
- **S2** return (short of target) `tav 224.3/29.0/404.8` → 3 objects (only ramp ones).
- **S3** `tav 222.3/30.3/407.3` → 5 objects (`arka_1` came back, but across the 60 m boundary: S2≈60.6 → S3≈57.2 — distance, not perception).
- **S4** return to point S0 `tav 218.3/31.6/410.3` → **18 objects** → **P2**.

**Distance control (the main thing):** for 18 entities from S4, distances from the S1 position were computed:
**14 of them — 17.5–51.9 m (< 60)** → their absence in S1 could not be a range cutoff, which means
it is **LOS** (honest P3), and the return in S4 — **P2** with actual positions. Distance-ambiguous
`arka_1` 70.3, `elegis_1` 66.6, `zevlor_1` 65.7, `memnos_1` 71.6 (>60) excluded from the proof.

**Observed signal:** in the exploration state there is no `perception` field — visibility is expressed
by **presence/absence in `objects`** (a character outside `Osi.HasLineOfSight(lead,*)` is culled in
`scanNearbyObjects`, `BG3Neuro.lua:2828`); `known`/`last_seen` are absent (binary model v1).

**Note (not a blocker):** `seen_by = "player"` is still hard-coded emitted (`BG3Neuro.lua:2842`),
although contract 03 rev2 fixed «`seen_by` removed». Candidate for a follow-up. **Closed:** follow-up
`bg3-neuro-followups/23-remove-seen-by` (2026-09-21, v0.8.62) — emission removed, the field and grouping
deleted in C#, the serializer prints a single header `## Objects (N)`.

## Claim (2026-09-20)

Captured for the session (paper part, game closed): 1) rewrite the scenarios for the binary model,
2) readiness criteria and cost threshold, 3) draft of checklist lines. Execution on the bench —
the next entry together with research §8 and 04b.

## Answer

**The acceptance plan is fixed (paper). Execution — after research §8 + 04b on the bench.**

### Acceptance scenarios (binary model) — input → expected outcome

| # | Scenario | Input | Expected outcome |
|---|---|---|---|
| P1 | Ambush not visible | exploration at the gates, camera outside the courtyard | 18 enemy entities NOT in `objects`/`enemies` (what is offscreen is not emitted) |
| P2 | Entering LOS | an entity entered the frame | appeared in `state` with an actual position (no `perception` field — emission = the fact of presence) |
| P3 | Leaving sight | an entity went behind cover/off frame | disappeared from `state`; absent from the next snapshot (no `known`/`last_seen`) |
| P4 | Combat — full roster | `mode=combat` | all participants in `enemies`, incl. offscreen and invisible-silhouette (spec §4), positions true |
| P5 | Refusal on an invisible target | `attack_entity`/`cast_spell` with a `target_id` absent from `state` | router: `TargetMissing` (Channel A, instant); mod: `no_perception` (after 04b) |
| P6 | Invisible out of combat on frame | a concealed NPC in the camera area | not emitted (B = «the engine actually rendered it to the player», spec §2); v2 (v0.8.63): enforced by the status gate `INVISIBLE`/`SNEAKING` (exc. `TRUESIGHT`/see-invisibility ≤9 m) |
| P7 | Party | cast/move/attack against an ally, `allies` in `state` | always passes the perception gate (spec §9) |
| P8 | AoE point | `cast_spell` with a `position` outside perception | v1: not gated by perception (success/fail per `feasible` mechanics) |

### Proof

- State snapshots `snapshots/05-*.json` before/after each step (style of `02-*`), inject ids in the log,
  SE log without Lua errors, serial inject by one script (`drive_action.ps1`, one at a time, wait for `result_<id>`).
- Cross-check of P5: both layers (router and mod) answer consistently in one scenario.

### Cost (fitness threshold)

- Draft filter (ticket 02): 11–15 ms/tick (max 16.3 ms) per look.
- **Threshold:** the B-sensor + roster must not push the average emission tick cost above **20 ms**
  (measurement: 5 runs, median) — otherwise the filter is deemed unfit and a LOS cache/frequency reduction is needed.
- Measured in combat and in exploration separately (the tick collects different things).

### Criteria of «spec ready for implementation»

1. Research §8 closed ✓ (2026-09-21): camera/fog in client-Lua are **unavailable** (by bg3se v32 source) → the `HasLineOfSight` fallback + status gate `INVISIBLE`/`SNEAKING` was chosen, the «camera perspective» blind zone is documented (research/02, spec §8); `StartSightEvents` at rest — no effect (probe v076); debounce dropped (no screen edge in emission); «combat reveals all participants» — confirmed (P4).
2. The contract (03) and gates (04) are fixed ✓ (spec rev 2, tickets resolved).
3. Implementation tickets B (emission) and A (feasible) created, 04b (mod gate) — with green unit tests among them.
4. The draft of checklist lines below added to `docs/manual-regression-checklist.md`.

### Place in the checklist — draft of lines (added to `docs/manual-regression-checklist.md`, Perception section)

See the «Perception (fair perception, contract 03/04/05)» section of the checklist: boxes P1–P8 as a checklist with
expected outcomes + the regression box «existing §9.5 combat/heal remain green after the filter is enabled».

## Acceptance execution (2026-09-21, v0.8.60, bench at the gates) — DONE

| # | Result | Proof |
|---|---|---|
| P1 | ✅ ambush not emitted (v082) | checklist §Perception |
| P2 | ✅ entering LOS — objects returned with actual positions | `artifacts/p2s4_front.json` (18 objects); distance control 17.5–51.9 m |
| P3 | ✅ leaving sight — 16 characters disappeared, without `known`/`last_seen` | `artifacts/p2s1_away.json` (2 objects) |
| P4 | ✅ combat — full roster (v082 + `reg0_combat` re-run: 8 enemies) | `artifacts/reg0_combat.json` |
| P5 | ✅ refusal on an invisible target (router `TargetMissing` + mod `no_perception`) (v082) | checklist §Perception |
| P6 | ✅ invisible/stealthy out of combat not emitted (P6 v2, 2026-09-21, v0.8.63, PAK v095) | `perception_probe`: `INVISIBLE`/`SNEAKING` → `masked=["Ogre Brute"]`, `objects` 18→17, remove → 18, `TRUESIGHT` → exception. See followup `24-invisible-b-gate.md` |
| P7 | ✅ party always passes the gate (v082) | checklist §Perception |
| P8 | ✅ AoE point not gated (v083 r9) | checklist §Perception |

**Cost (≤ 20 ms median):** exploration `exploreLoop` med **11.20 ms** (n=336, p90 14.17);
combat `TurnStarted` med **9.51 ms** (n=25, p90 14.05) — both under the threshold (log
`Extender Runtime 2026-09-21 13-47-00.log`; ticket 21).

**Regression §9.5:** roster, turn loop (`tav→aradin→astarion→za_krug→remira→cleric`), healing
(`healing_word` BA+L1, HP 9→13), attack (AP 1→0, `prevalidate pass`) — green.
Feeding: unknown spell (`wish`) is not cut off on the honest path → `issues/07-unknown-spell-stuck-cast.md`.