# 24 — P6 v2: status gate for invisible/sneaking entities in the B-emission

Type: feature (perception v2 — known limitation P6)
Status: verified (2026-09-21, v0.8.63, PAK v095 installed + live)
Blocked by: —

## Finding

Perception v1 accepted one known limitation — **P6**: the exploration B-gate is
`Osi.HasLineOfSight(lead, target)` only (`BG3Neuro.lua:sightSees`), so a **stealthed or
invisible NPC inside LOS is still emitted**. Live note (`issues/05-acceptance-and-bench.md:153`,
checklist P6): the ambush at the gate leaked into `objects`. The suggested fix was deferred:
"potential fix — `Osi.IsInvisible` — outside v1".

Perception contract rev 2 §2 warns that `Osi.IsInvisible` is **not** a reliable status signal — in
the ticket-02 probe it returned 1 for the whole non-rendered ambush ("hidden from camera/not revealed"),
not for actually-invisible entities. So `IsInvisible` is **not** used as the gate; the engine's own
visibility predicate (`brawl_Utils.lua:266 isVisible`) keys on **statuses** instead:

```lua
TRUESIGHT / MOD_Generic_Truesight                       -> visible
SEE_INVISIBILITY / MAG_SEE_INVISIBILITY_HIDDEN_IGNORE_RESTING (<=9 m) -> visible
else: IsInvisible(target)==0 and HasActiveStatus(target,"SNEAKING")==0
```

`StatusType` in the game data contains `INVISIBLE` and `SNEAKING` (`ExtIdeHelpers.lua`), and the
Osiris signatures exist: `HasActiveStatus(target,status)` (`Osi.lua:1340`), `IsInvisible(object)`
(`:1686`), `IsInvisibleByScript` (`:1690`), `ApplyStatus(object,status,duration,force,source)`
(`:2396`), `RemoveStatus(target,status,cause)` (`:3688`).

## Plan

1. **Gate (mod, `sightSees`)** — after a positive LOS verdict, if the target carries a masking
   status (`INVISIBLE` / `SNEAKING`) and the sight leader cannot see through it, do **not** emit.
   Leader exemptions mirror the engine: `TRUESIGHT` / `MOD_Generic_Truesight`; `SEE_INVISIBILITY` /
   `MAG_SEE_INVISIBILITY_HIDDEN_IGNORE_RESTING` within 9 m. Statuses are read from the raw
   `StatusMachine` (`statusListOf`/`statusItemsOf`) — the same source as `conditionsOf`, but without
   the visible/internal filter (masking statuses are filtered out of `conditions`). Fail-open on any
   read error (never wipe the whole list on a transient).
2. **Probe (`perception_probe`, bench-only, read-only + optional status mutation)** — dump the raw
   B-gate inputs for every candidate near the leader (party + `EXPLORE_OBJECT_TYPES` within
   `EXPLORE_MAX_DISTANCE`): `los`, `is_invisible`, `is_invisible_script`, `masked` (gate verdict),
   `statuses[]`. Optional `data.apply_status` / `data.remove_status` let the bench create the
   scenario (`Osi.ApplyStatus` / `Osi.RemoveStatus`) without a spell.
3. **Version** → `0.8.63`, PAK `v094`.

## Verification (to run)

- Baseline probe in exploration: normal NPCs have no `INVISIBLE`/`SNEAKING` and `masked=false`
  (gate must not over-drop); compare candidate count vs emitted `objects` count.
- Scenario: `apply_status {target_id:<visible npc>, status:"INVISIBLE"}` → probe `masked=true` and
  the NPC disappears from `objects`; `remove_status` → it reappears.
- Stealth leg: `apply_status {status:"SNEAKING"}` → same drop.
- Combat unaffected (gate is exploration-only: `sightSees` is called from `scanNearbyObjects`).
- Regression: exploration object count for normal NPCs unchanged; 166/166 tests (C# untouched).

## Notes

- `IsInvisible` is reported by the probe for research only; it is **not** part of the gate verdict
  (spec §2 trap).
- Cost: status reads are component-based (no extra Osiris calls beyond the existing LOS probe); the
  per-tick emission budget (median ≤ 20 ms) must be re-checked on the live log.

## Answer

**Closed 2026-09-21 (v0.8.63, PAK v095 installed + live).** P6 v2 implemented: the exploration
B-gate now drops masked entities, and the bench-only `perception_probe` action was added.

Implementation:
- `BG3NEURO_SIGHT` namespace (global table — see trap below): `statusIdSet` (raw
  `StatusMachine` ids via `statusListOf`/`statusItemsOf`), `anyStatusIn`, `isMasked`.
  `isMasked` = target carries `INVISIBLE`/`SNEAKING` and the sight leader lacks
  `TRUESIGHT`/`MOD_Generic_Truesight` (and `SEE_INVISIBILITY`/`MAG_SEE_INVISIBILITY_HIDDEN_IGNORE_RESTING`
  within 9 m). Fail-open on read errors. Wired into `sightSees` after a positive LOS verdict.
- `perception_probe` action: dumps per-candidate `los`/`is_invisible`/`is_invisible_script`/`masked`/
  `statuses[]`; optional `data.apply_status` / `data.remove_status` (`Osi.ApplyStatus`/`RemoveStatus`)
  create the scenario without a spell.

Live bench (file bridge, exploration; leader = Tav `e6090219-…`; target = Ogre Brute `04695229-…`,
18.8 m, LOS=true):
- Baseline: `masked=[]` — no over-drop. 18 non-party LOS-visible `objects` = exactly the
  `los=true` rows. Spec §2 trap reconfirmed: ~20 entities had `is_invisible:1` (Ogre Brute,
  Goblin Warrior, Sword Spider, …) with **no** masking status and were correctly NOT masked.
- `apply_status INVISIBLE` → `masked=["Ogre Brute"]`; forced `state_capture` → `objects` **18→17**,
  Ogre Brute absent. `remove_status` → back to **18**, `masked=[]`.
- `apply_status SNEAKING` → `masked=["Ogre Brute"]`; remove → `masked=[]`.
- `apply_status TRUESIGHT` on Tav while target `INVISIBLE` → `masked=[]` (exemption works);
  remove → masked again; cleanup → `masked=[]`.
- Server log: `[BG3Neuro] v0.8.63 loaded (server)`, no Lua/parse errors. Dispatch timing
  (n=124): min 5.8 / **median 11.1** / max 26.0 ms — median within the ≤20 ms budget.
- C# untouched → 166/166 tests unaffected.

Trap hit during build (worth recording): the main chunk already had **exactly 200 active locals**
(Lua `MAXVARS` = 200), so the first version (7 new top-level `local`s) failed to parse on the
server — `Failed to parse script: …:5297: too many local variables (limit is 200)`, the module
silently vanished (`BG3Neuro v? loaded (server)`, stale heartbeat). Fixed by moving the helpers to
the global `BG3NEURO_SIGHT` table (0 new locals; the file already uses globals `perceptionActors`/
`perceptionObjects`). Lesson: any new top-level `local` in `BG3Neuro.lua` must be offset or made a
global — headroom is **0**.