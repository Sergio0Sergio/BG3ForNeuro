# Spec: contract of fair perception (draft)

Status: draft (ticket 03, `bg3-neuro-perception`)
Date: 2026-09-20 (rev 2 — binary model, see `issues/03-perception-contract.md`)
Replaces: hardcoded `seen_by = "player"` (`BG3Neuro.lua:2743`), unfiltered `scanNearbyObjects`, combat collection without perception.

## 0. Why

Neuro receives the game state and acts on it. Currently the mod emits «everything in radius», including what the player does not see and should not know yet (the gate ambush lay in `objects` before the cutscene). The contract defines **what is emitted** and **by what right**.

## 1. Two sensors for two functions (decision of ticket 02)

| | `visible` — emission | `feasible` — action gates |
|---|---|---|
| Question | «does the player see on the screen» | «does the engine allow the action on this target» |
| Sensor | **B — the player's eyes**: camera/fog (frustum + open area + local occlusion) | **A — engine mechanics**: `CanSee`/`HasLineOfSight`/statuses (stealth, invisibility, AI composition `brawl_Utils.isVisible`) |
| Who consumes | state emitter | action router (tickets 04–05) |

The fork from ticket 02: **emission** judges by the player's truth (B), **actions** — by the engine's truth (A). A cannot replace B (the engine mechanically «sees» goblins through the open street), B cannot replace A (the engine decides feasibility, the camera does not).

## 2. Emission gate — binary (decision: without memory)

**«Visible is visible. Not visible — means not visible.»** No memory and no stale positions.

- An entity **on screen** (B-sensor) → emitted with the **current true position**; there is no `perception` field in the record — visibility is expressed by the very fact of presence in `objects` (bench `p2s4_front.json`).
- An entity **not on screen** → **not emitted at all**. Neither the fact of its existence (in exploration), nor its position.
- **Definition of B = «the engine actually rendered the entity to the player»**, not «the character is logically visible by stats/statuses». Consequences: an invisible out-of-combat character is not rendered by the camera → not emitted (even if standing in the center of the frame); `IsInvisible` as a visibility signal is NOT used (trap of ticket 02 — it returned «hidden from the camera», not a status). Combat is a separate case, see `## 4` (an invisible silhouette is drawn). **Implemented (v2, v0.8.63, followup `24-invisible-b-gate.md`):** masking is cut by the raw `INVISIBLE`/`SNEAKING` statuses (exc. `TRUESIGHT`/see-invisibility ≤9 m), not by `IsInvisible`.

Why without `known`/`last_seen`: a stale coordinate is a position where the entity no longer is; it misleads («a marker at an empty spot»), gives a reason to act on a nonexistent target, and contradicts the thesis «do not reveal the unknown». Memory is deferred entirely (`known` is not in v1, see `map.md`).

## 3. JSON schema

In every emitted object/combatant (except the party):

```jsonc
{
  "alias": "..."   // visibility = the fact of presence; fields perception/perception_reason are NOT emitted
}
```

- Fields `perception`/`perception_reason` are **absent from the state** (rev2, implementation v0.8.62+): the contract **emission = visibility**; the values `known`/`unknown`/`visible` do not exist in v1.
- `seen_by` from the old schema is **removed** (it was the «lie»). **Done in v0.8.62 (ticket 23)**: until then the C# side did read it (`StateSerializer` grouped objects by `SeenBy`), contrary to the earlier draft note — the mod emission (`BG3Neuro.lua:2842`), `ExplorationObject.SeenBy`, the `GroupBy` renderer header and the test fixture (`StateSerializerTests.cs:343-344`) all carried it; all removed, single `## Objects (N)` header instead.
- **Party**: party members do not pass the perception filter, always emitted (current position).
- Coordinates of all emitted entities — **current true**; stale coordinates are absent from the protocol by construction.
- The diagnostics «which signal gave the verdict» (`cansee`/`los`/`frustum`/`fog`) was planned as `perception_reason`, but is **not emitted**; if needed it will return as a separate field outside the App contract.

## 4. Emission rules by modes

**Exploration (including before a cutscene):**
- only an on-screen entity is emitted (B-sensor), with the current position;
- everything else — not in the state at all (neither `objects` nor `enemies`);
- «the party is always known» — the only exception (allies are always in place).

**Combat:**
- combat participants are **always emitted** in `state.enemies`: the game itself reveals them to the player — the initiative order and the tactical map show any combat participant. That is, in combat the B-gate is disabled by construction: combat «visibility» is given by the UI mechanics, not the camera.
- positions of participants — current true (they are visible to the player on the tactical map).
- **Invisibility in combat does not hide the position:** BG3 renders an invisible participant as a flickering semi-transparent silhouette at its true location (can be covered with AoE; an attack removes invisibility). Such participants are emitted like everyone else — position is true (there is no `perception` field, emission = the fact of presence). The invisibility status does NOT lower emission in combat.
- non-participants — per the exploration rules (`## 4` exploration).
- `feasible` (A-sensor) in combat computes the feasibility of actions regardless of B.

Rationale: the ambush crucible from ticket 02 — an offscreen ambush in exploration is not emitted at all; a started combat does not lose participants, because the player physically sees them in the turn order and on the map. Snapshot s01→s02 confirms: participants appear exactly at the entry into `CombatState`.

## 5. Memory

In v1 — **none**. No `known`/`last_seen`/scene reset. The state of each tick is only what is visible now. Consequences:

- an entity that left the screen disappears from the state on the next tick (if not a combat participant);
- an entity that returned to the screen appears again — with actual data;
- no location/load resets are required for perception (memory is an empty set).

## 6. Entity coverage

| Type | Emitted? | Note |
|---|---|---|
| Party | yes, always | exception from the gate, current position |
| Allies-NPC (in combat/roles) | by B-gate / combat participant | combat participants — always |
| Enemies (from `state.enemies`) | per the combat rules of `## 4` | combat participants — always |
| NPCs out of combat (exploration objects) | by B-gate | — |
| Corpses | by B-gate | not emitted offscreen |
| Containers/boxes | by B-gate | — |
| Doors | by B-gate | — |
| Entities without a position/component | not emitted | the existing per-type filtering persists |

## 7. Limitations of the B sensor (what may not work — documented)

- The truth is given by the B-sensor; the particular implementation of B **is not part of the contract**:
  - target: camera frustum + fog-opened area + local occlusion (Client-Lua);
  - fallback: frustum + `HasLineOfSight` from the camera (documented approximation — the same holes `HasLineOfSight` has: columns/thin barricades);
  - if even the fallback is impossible: the blind zone is recorded, the contract does not change.
- `visible` is determined once per emission tick; an entity that flashed on screen for less than a tick is not guaranteed.

## 8. Open questions for the bench (research-checklist, ticket 03) — closed

1. Client-Lua (`BG3NeuroClient.lua`, `Ext.Client`): camera and the «fog-opened area» — **CLOSED (negatively, by the bg3se v32 source):** in the entire extender there is not a single `GetCameraPosition` reader, the `Client` lib is absent in `Lua/Libs`, there is no `Ext.World` camera either → the camera frustum is impossible by construction (blind zone «camera perspective»); no Reveal/FogOfWar requests in Extender/Osi → blind zone «map revealed, but offscreen». Final B implementation: `HasLineOfSight(leader, candidate)` + status gate `INVISIBLE`/`SNEAKING` (exc. `TRUESIGHT`/see-invisibility ≤9 m) — v0.8.63, followup `24-invisible-b-gate.md`. Research: `research/02-b-sensor-api-probe.md`.
2. `Osi.StartSightEvents` (party) at rest — **CLOSED (probe v076):** no effect, `Osi.CanSee` is correct without events; events are not needed for A/`feasible` out of combat.
3. Debounce flicker at the screen edge — **DROPPED:** there is no screen edge in emission (no camera frustum); the only boundary is the LOS threshold `EXPLORE_MAX_DISTANCE`, and flapping there is already under binary emission; no separate debounce in v1.
4. «Combat reveals all participants» — **CONFIRMED (acceptance P4, v082 + `reg0_combat`)**: combat participants are always in `state.enemies`, including offscreen and invisible-silhouette ones.

## 9. Gating actions by perception — «honest refusal» (ticket 04)

In the binary model, the **perception gate on the router is already done by construction**: the router rejects an action
referring to an entity absent from the emitted state; «in the state ⇔ in the field of view».

The «action × rule» matrix (v1):

| Action | Who gates | Rule |
|---|---|---|
| `attack_entity` | router | target in `enemies` (the combat roster reveals everyone) → otherwise refusal |
| `cast_spell` (`target_id`) | router | target in `enemies` ∪ `allies` (party buffs are valid) → otherwise refusal |
| `move_to_target` | router | target in `enemies` ∪ `allies` → otherwise refusal |
| `move_to_entity` / `interact_with` / `loot` | router | target in `objects` → otherwise refusal |
| `bonus_action` / `use_item` (target) | mod | no mirror on the router; the mod gates by its own perception set (ticket 04b) |
| `end_turn`, `rest`, reaction, dialogue | — | not gated (no target) |
| `travel_to` | — | not gated: `regions` is a curated disclosed list of waypoints |
| positional AoE (`position`/`coverage`) | — | not gated in v1 (no entity reference; a «blind» AoE is unlucky, but not a leak) |

Rules:
- The party (`allies`) is **never gated** — always visible (incl. cast/move on own party members).
- Refusal code on the router: `TargetMissing` (Channel A, instant, before the game); the default message explains
  the perception rule («this is exactly what you see; the target may be out of sight or gone — check the state»).
  A separate `no_perception` code is NOT introduced (decision of ticket 04): `TargetMissing` already fulfills this role.
- Barrier split: **router** — a mirror over the state (clarity, cheapness, before the game);
  **mod** — the authoritative perception gate at the moment of execution (party ∪ emitted this tick), honest refusal on top of
  `feasible` (range/LOS/statuses/AP). Mod layer — ticket 04b (Lua + bench), lower priority than the B/A research.
- Not yet specified: «an AoE point in the field of view» (a B module will be needed); a `bonus_action`/`use_item` mirror on the router (if needed per the results of 04b).
- `perception` in the state is needed: (a) App-UI for «this is on screen»; (b) honesty tests; (c) diagnostics.
- Removing `seen_by` → fix `StateSerializerTests.cs:241`.

## 10. Related artifacts

- Signal research: `research/01-perception-signal-api.md` (ticket 01).
- Prototype/live look: `issues/02-perception-emitter-prototype.md` + `artifacts/02-*` (ticket 02).
- B-sensor probe (plan for the game session): `research/02-b-sensor-api-probe.md` (§8.1–3).
- Contract ticket: `issues/03-perception-contract.md` (the binary-model decision is also fixed here).
- Gates: `issues/04-action-gating.md` (+04b for the mod layer); acceptance: `issues/05-acceptance-and-bench.md`.