# 02 — Movement manual cost is specified but not implemented

Type: follow-up (code-review)
Status: resolved (v0.8.29, live bench 16.09)
Blocked by: bench (writer selection)

## Finding

The honest-economy map claims full delivery — `map.md:32` "All 5 map tickets (01-06) are resolved and executed" — but ticket 06's deliverable is **not in the code**:

- `map.md:5` — "movement is deducted manually (before/after)"; `map.md:24` — "the mod manages the distance itself … deduction finalizes only in the movement-completion event callback".
- Code: `executeMoveToTarget` (BG3Neuro.lua:2384-2414) only calls `CharacterMoveTo(...)`/`CharacterMoveToPosition`; the completion callback (right after) only writes the result. No `AddActionPoints`/`PartyIncreaseActionResourceValue` for movement anywhere.
- `research/06:143` itself defers the deduction "to a separate ticket" — so the map's "executed" claim over-reaches (its executed bullets list only 4 items, none for 06).

## Fix proposal

1. Create the movement-deduction ticket the research promised: before/after Movement-resource snapshot (`resourceLevel=0`, meters) + deduction in the movement-completion event callback, writer picked on the bench (no `TransferActionResource`; `PartyIncreaseActionResourceValue` has party semantics risk).
2. Once implemented, correct the map: split the "executed" claim from "specified, backend pending".

## Bench note (16.09, from ticket 01's live run)

Ticket 01's writer probes directly affect this ticket's candidate set:

- `Osi.PartyIncreaseActionResourceValue(actor, "Movement", delta)` — `write_ok=true` (no exception) but the actor snapshot **unchanged** for both `delta=-3` and `delta=+2` (Movement stayed 9.0). No-op on personal `Movement`. The research/06 preferred writer (PartyIncrease…) is disqualified on the bench — the "party semantics" risk is subsumed by "doesn't touch personal resources at all".
- Personal `Movement` snapshot via `Osi.GetActionResourceValuePersonal(actor, "Movement", 0)` works (9.0 meters read) — the before/after read side is available.
- Remaining write candidates for the meter deduction: `Osi.AddActionPoints(actor, -1)` dash-equivalent (proven, mod code), or non-public core `SetResourceValue` queue (not reachable from Lua — research/06 §3).

### Live demo evidence (16.09, move_to_target from brand-new state file)

Deterministic inject `move_to_target {"actor":"tav","target_id":"zevlor_1"}` in the running combat (fresh state built by `state_capture`):

- Wire: `resp "OK"` and `result_mvip1.json` → `{"id":"mvip1","success":true}` — the router/execute path runs and the actor **actually walks** (user-confirmed visually; state re-capture: Tav→zevlor distance 36.0 m → **1.6 m**).
- Movement resource **unchanged 9.0** after the walk; no movement lines in the SE log; no budget stop (Tav walked the full ~34 m approach, exceeding its 9 m).
- So on the installed (pre-fix) PAK: `move_to_target` moves Tav for free — the demo gap this ticket describes is **live-confirmed**. Tick 02's deliverable must add both the deduction AND the in-movement budget stop (map.md:5 claim "deduction finalizes only in the movement-completion event callback" — confirm that callback actually fires in the fixed build before claiming delivery).

Resolution of ticket 02 must pick from these; the PartyIncrease route is closed.

## Implemented (v0.8.29, PAK v035 / MD5 AF36E34E)

- `executeMoveToTarget`: reads `GetActionResourceValuePersonal(actor,"Movement",0)`; `m0<=0` → early fail `"No movement left"`; if distance-to-target > m0 → **budget clamp** — destination re-projected `t = m0/d` along the ray to the target and issued via `CharacterMoveToPosition` (`clamped=true`).
- `activeMove` extended (`actor,startX/Y/Z,m0,clamped`); movement finalization moved to the `EntityEvent` completion callback writes `extra.movement = {before, after, dist_m, clamped}` to `result_<id>.json`; logs `move_to_target` / `move final` (`_P`).
- Legacy fallback (only `force_legacy` or `legacyStable`): dash-equivalent `AddActionPoints(actor,-1)` in the completion callback (AP>0 guard). Honest path does NOT spend — the engine drains Movement natively on scripted combat movement (see bench below).
- Config in PAK: `force_legacy=false`, `legacy_fail_limit=3`.

## Live bench evidence (16.09, combat, Tav half-elf fighter party, SE v32)

Setup: autopilot off (`config.json autopilot.enabled=false`), deterministic injects via Randy `localhost:1337`, mod heartbeat `v0.8.29` (new Lua live — note: bootstrap "v0.8.27 loaded" lines are hardcoded literals, fixed for next build via `_G["BG3Neuro_VERSION"]` in v0.8.30+).

1. Baseline `bench_snapshot` s8: party Movement = 9.0 (meters).
2. `move_to_target {"actor":"origin_astarion","target_id":"goblin_brawler_1"}` (target ~14 m): result `{"success":true,"movement":{"before":9.0,"after":0.0,"clamped":true,"dist_m":9.4}}`; log `move_to_target: ... m0=9. clamped` + `move final: id=mvip4 dist=9.4m m_after=0. clamped`. User-confirmed visually: Astarion stopped short of the brawler (~9 m, did NOT reach it).
3. Second `move_to_target` (same turn, Movement now 0): `{"success":false,"error_code":"action_failed","error_detail":"No movement left (Movement=0.)"}` — user-confirmed no movement, budget lockout works.

Key finding: in **combat on the turn actor** the game drains the Movement pool natively (9.0 → 0.0) for scripted movement — so the honest path needs only the clamp + m0 gate, not a manual writer. (Pre-fix demo `mvip1`, exploration-mode same move left Movement at 9.0 — the "free movement" gap.) PartyIncrease/AddActionPoints writers remain disqualified/AP-only as bench-note above.

Also recorded during bench (not a bug): `ActionRouter.ValidatePhase` rejects combat actions for non-turn actors ("It is 'origin_astarion' turn now, not 'tav'") — injected action simply not dispatched; expected router behavior.

Housekeeping queued with the implementation (PAK not rebuilt yet this session): bootstrap prints real version from `_G["BG3Neuro_VERSION"]`; stale SE Lua overrides archived to `Script Extender\Lua\_archive_stale_2026-09-16\`.