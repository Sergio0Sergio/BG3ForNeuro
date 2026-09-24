# 02 — Prototype: state emitter with a perception filter (live look)

Type: prototype
Status: resolved
Blocked by: 01

## Question

What does a **perception filter in the emitter** look and behave like on a live combat scene? A first throwaway draft cut, intended to see the data and catch holes before the contract is fixed.

## Scope

- Take the signal(s) from ticket 01 (or its approximation if there is no clean one).
- Attach a rough filter to `scanNearbyObjects` (`BG3Neuro.lua:2722`) and to the combat collection `state.enemies` (`:2450`): mark `perception` (at least `visible`/not) and do NOT emit `unknown`.
- Live run on the gate ambush: approach, step back behind cover, let the enemy move out of view.
- **Draft, not for production**: no `last_seen` freezing, no honest refusal, no schema — only to see the behavior and the cost.

## Deliverable

- Draft patch (or a separate bench branch/flag) + screenshots/state lines from the SE log.
- A note: what worked, what the signal does not provide, how much it costs per tick, where it lies.
- The artifact is linked from the ticket; **the draft result is not committed as production code**.

## Verification

- The log shows: an entity behind cover stops being `visible`; behind a wall/before the cutscene it is not emitted at all.
- Signal blind spots are recorded (e.g. "does not distinguish stealth from invisibility", "expensive on N entities").

## Progress

### "Before" baseline (2026-09-20, gate exploration, no mod changes)

Live snapshot of the actually emitted state (IPC `bg3_to_neuro.json`, mod 0.8.57):
artifact [`artifacts/02-baseline-gate-exploration.json`](../artifacts/02-baseline-gate-exploration.json).

- `mode=exploration`, `trigger=free_roam`, `screen=exploration`, `allies=4`, `enemies=[]`, `objects=35`.
- **All 35 objects carry `seen_by:"player"`** — hardcoded (`BG3Neuro.lua:2743`) with no visibility check at all.
- Hostile entity leak: **18 of them** at distances **11.0–55.9 m** (`sword_spider_1` 11.0, `booyahg_benta_1` 13.0, `sharp_eye_sneem_1` 13.2, `bugbear_2` 13.5, `sapper_moke_1` 13.6, `goblin_sharp_eye_1` 14.2, … `bugbear_assassin_1` 54.7, `kaldani_1` 57.5) — the ambush has not even triggered, they are behind walls/fog, yet everything is "seen".
- Non-hostile NPCs (Wyll 47.1, Zevlor 48.8, Aradin 29.3, …) also all `seen_by:"player"`.
- `available_actions=[]` (exploration), `regions=[]`, `inventory=[]`.
- Conclusion: until the filter is fixed there is no honest perception at all — neither by distance, nor by LOS, nor by stealth.

### Remaining (requires a PAK rebuild + game restart)

- Draft patch: `scanNearbyObjects` (`BG3Neuro.lua:2722`) + combat collection `state.enemies` (`:2450`) — mark `perception`, do not emit `unknown`.
- Live look at the ambush: approach, move behind cover, let the enemy shift out of view.
- Measure the per-tick cost; cross-check with the baseline artifact.

### Draft patch installed (v066, mod 0.8.58-draftperc) + live look #1

Patch: `mod/BG3Neuro/BG3Neuro.lua` — one chunk-local `PP` (closure; the Lua limit of 200 locals per main chunk — the first build broke exactly on this, `Failed to parse script: too many local variables (limit is 200) in main function`), helper `PP.of(viewers, target)` → `visible`/`known`/`unknown`, `PP.viewers(partySet)`. In `scanNearbyObjects` `unknown` is not emitted, `state.objects` are marked `perception`+`perception_reason`, `state.perception` holds counters; in combat an unperceived enemy does not get into `state.enemies`. `MOD_VERSION="0.8.58-draftperc"`.

Live state artifact under the filter: [`artifacts/02-after-filter-gate-exploration.json`](../artifacts/02-after-filter-gate-exploration.json) (series snapshots: `artifacts/snapshots/02-s01.json`).

**Result (export save at the gate, exploration):** candidates 52 → **objects 35 before → 18** (visible=8, known=10, unknown=34). 34 entities behind obstacles/around the corner stopped being emitted entirely.

**Signal blind spots (key findings of the first look):**

1. **`Osi.CanSee` = 0 for all 52 in exploration** — no object got `reason="cansee"`. Outside combat/without an active sight engine the engine does not answer "sees" (or `Osi.StartSightEvents(character)` is needed). To be checked separately in combat.
2. **`Osi.IsInvisible` ≈ "hidden from the camera/not yet revealed", NOT the Invisible status.** All 10 "known" (the whole ambush: goblin_*, bugbear_1, ogre_brute_1, sword_spider_1/2, sapper_gald_1) got `known/los_status` precisely because `IsInvisible==1` while `HasLineOfSight==1`. That is, the ambush feature that MUST be hidden is not dropped: the signal treats "backstage/not yet in view" as "invisible" → upgraded to `known` instead of down.
3. **`HasLineOfSight` in the open field at the gate = 1 for the ambush** (the view across the street is free) — geometry alone is not enough; honest "visible" requires looking through the player's camera/fog.
4. To be fair: the 34 dropped are mostly around corners/behind barricades; Wyll also disappeared (47.1 m, open area, invisible to the camera) — i.e. even "innocent" NPCs are lost when `Los==0`, which is most likely wrong for gameplay.

**Conclusion for the contract (input to ticket 03):** raw Osi predicates are not enough in exploration. Candidates for the source of truth: server viewshed (`Sight`/`ServerSightEntityViewshed…`/`StartSightEvents`+`CanSeeCached`) or the client fog/camera. A second iterative pass is needed (see `Not yet specified` of the map).

### Remaining in the live look

- Tav movement: approach/move behind cover — check emission reactivity (visible↔unknown churn by LOS).
- Measure the per-tick call cost (52 entities; `PP.of` hits `CanSee`+`HasLineOfSight`+`IsInvisible` × viewers × apis).
- Trigger the ambush (cutscene) → look at `state.enemies` under the filter in combat.

### Live look #2 — combat started: `Osi.CanSee` is ALIVE in combat

Snapshot: [`artifacts/snapshots/02-s02.json`](../artifacts/snapshots/02-s02.json) — `mode=combat`, `turn_actor=tav`, `init=5/18`.

- Tav movement → the party walked into the ambush → cutscene → **combat**. In exploration the step between s01 (gate square) and s02 (inside) landed exactly on the trigger moment; a clean move-behind-cover snapshot was not captured in time (combat started on its own).
- **All 8 enemies emitted as `visible`**; `perception_reason`: `cansee` ×5 (`goblin_tracker_1/2`, `bugbear_1`, `goblin_brawler_1`, `za_krug_1`) and `los` ×3 (`goblin_booyahg_1`, `goblin_tracker_3`, `worg_1`). Nothing is cut — the fight is fully in view.
- **`Osi.CanSee` returns 1 in combat** — in exploration it returned 0 for all 52. The engine enables sight logic on combat entry/combat awareness; in idle exploration the raw predicate is dead.
- The enemy combat roster is wider than the exploration list: `goblin_tracker_2/3`, `za_krug_1`, `worg_1` appeared (came with the cutscene). Old staged tails (`sword_spider_1/2`, `sapper_gald_1`, `bugbear_1` and the like) do NOT take part in this fight — they are the participants of the next fights on the scene.
- `turn_initiative_total = #parts = 18`; emitted allies 9 + enemies 8 = 17 → one participant did not make it. `parts = participantGuids(combatComp)` (`BG3Neuro.lua:2454`, `:1601`) — entity handles of participants, including non-characters (the door/barricade at the gate are ordinary combat participants) → most likely `diag.skipped_non_character=1`; the `perception_dropped=1` case is not ruled out (diag is not written to the state file — verify only via the app channel or log).
- **Cost:** the emitter with the filter — **11–15 ms/tick** (max 16.3 ms; `BG3Neuro.lua:5565`), from the SE log.

**Conclusion from the live look (input to the contract):** raw signals suffice in combat (`CanSee` works, all enemies honestly marked as in view); the hole is exactly exploration: without an active sight engine `CanSee=0`, `IsInvisible` lies, `HasLineOfSight` does not account for cone/back/barricades. For honest "not emitted before the cutscene" a client/camera-side source is needed or engine sight must be enabled (`StartSightEvents`+`CanSeeCached`) — to check in ticket 03.

## Answer

**The draft produced its data and is closed. Prototype summary:**

1. **In combat** raw Osiris predicates suffice: `Osi.CanSee` is alive (5×`cansee` + 3×`los` at the gate), all participants are honestly marked `visible`, the filter breaks nothing.
2. **In exploration** there are NO raw signals: `CanSee=0` on all 52 candidates (the engine counts sight only "when it looks"/in combat), `IsInvisible` treats "hidden from the camera/not yet revealed" rather than an invisibility status, `HasLineOfSight` is pure collision (no cone, back, barricades). The 35→18 cut of objects exists, but **the ambush leaked as `known`** — the filter did not close the ticket's main case; known NPCs (Wyll) are falsely discarded.
3. **Cost:** the whole emitter with the filter is 11–15 ms/tick (the filter's contribution has not been isolated separately).
4. `known` on its own is a source of leaks (it surfaced exactly the ambush) and drags in memory/`last_seen`.

**Decision on fork #1 (agreed with the user):** two different sensors for two different functions —

- **emission (`visible`) — the player's eyes (option B):** player camera/fog (frustum + fog-revealed zone + local occlusion);
- **action gates (`feasible`) — engine mechanics (option A):** `CanSee`/LOS/statuses with which the engine decides the feasibility of an action.

A does not cure the ambush leak even with a live sight engine (the goblins are mechanically "visible" through the open street); B cures by definition, but carries a research risk (availability of the camera-fog API in client-Lua). The contract of ticket 03 is written from this formulation with a documented fallback.

**Fallback (in the contract):** if camera-fog is unavailable in client-Lua — `visible` is implemented via the "frustum + `HasLineOfSight` from the camera" approximation; if that is also impossible — the blind spot is documented and we live with it.

**Artifacts:** `artifacts/02-baseline-gate-exploration.json` (before), `artifacts/02-after-filter-gate-exploration.json` + `snapshots/02-s01.json` (exploration under the filter), `snapshots/02-s02.json` (combat). The draft did not go to production: `BG3Neuro.lua` reverted to HEAD (`0.8.57`), the production PAK rebuilt (`009026B4…`), the draft PAK saved to `%TEMP%\opencode\BG3Neuro_v066_draft.pak`.