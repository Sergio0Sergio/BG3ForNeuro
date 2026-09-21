# 21 — Combat capture cost (TurnStarted) exceeds the 20 ms perception threshold

Type: task (measure + decide optimize vs re-tune threshold)
Status: resolved (2026-09-21 — measured, median re-tested **below** threshold)
Blocked by: none

## Symptom (bench v081–v083, gate, 2026-09-20)

The perception cost threshold (ticket 05) is: median emission-tick cost ≤ 20 ms
(5 runs) in both combat and exploration. Measurements from `Dispatching ... took
N ms` lines in the SE log:

- Exploration tick (`WaitForRealtime` callback, v081): **10.8–13.8 ms** — under
  threshold. A clean post-combat measurement still owed (was overlapped by this
  session's combat).
- Combat: `TurnStarted` handler (`captureCombatState`) = **23.4 / 38.5 ms —
  above 20 ms** on the two measured turns.

## Why it is a ticket, not a non-issue

- The combat capture is **event-driven** (one call per turn change), not a
  500 ms polling tick — so the "tick cost" framing doesn't map 1:1. Formally,
  however, it exceeds the stated threshold, so either (a) optimize the capture,
  or (b) re-state the threshold for the event-driven path. Not decided.

## What captureCombatState does that is heavy (candidate hotspots)

- Per combatant: statuses/conditions read, HP/max-HP, `${key}` reads, spells
  block (book per actor), faction check (`die-type` classification), distances
  computed from `actingPos`.
- Whole block runs synchronously on every `TurnStarted` (BG3Neuro.lua:511),
  including for NPC starts where the app's decision loop just needs the roster.

## Fresh measurement (2026-09-21, v090, gate battle, whole-day log)

- 86 `TurnStarted (BG3Neuro.lua:500)` samples in `Extender Runtime 2026-09-21 06-25-44.log`:
  **median = 9.04 ms, avg = 9.61 ms, min = 5.01 ms, max = 24.1 ms**; over 20 ms = **1/86**,
  12–20 ms = 16/86.
- Median is comfortably **below** the 20 ms ticket-05 threshold — combat capture is no
  longer the bottleneck. The earlier 23.4/38.5 ms readings (2 samples) were outliers on
  a heavier battlefield (17→16 participants; today 15).
- Decision: **neither optimization nor threshold re-tune needed.** Event-driven combat
  capture passes the stated median criterion; rare single spikes (≤1/86 over 20 ms) are
  per-turn one-shots with no polling stall. Rolled into checklist as verified.

## Options (for the next live session / code pass)

1. Optimize: only refresh per-actor `spells`/statuses for the acting character;
   roster-wide fields on turn change only. Kick the heavy reads for non-acting
   actors.
2. Split write: full state on player-turn starts, reduced state on NPC starts.
3. Re-tune: accept event-driven capture ≤ 100 ms as "fine" (one-shot per turn,
   no UI stall comparable to a tick) and adjust threshold wording in the
   checklist/ticket 05 accordingly.

## Status

**Resolved 2026-09-21**: median 9.04 ms (n=86) — under threshold; no action needed.
If the battlefield grows (more party members/enemies) and spikes recur at the median,
revisit option 1 (defer per-actor heavy reads for non-acting combatants).

**Re-measured 2026-09-21 (v0.8.60, `Extender Runtime 2026-09-21 13-47-00.log`)**: combat
`TurnStarted` n=25, median **9.51 ms**, p90 14.05, max 18.93; exploration `exploreLoop`
n=336, median **11.20 ms**, p90 14.17, max 18.16 — both medians under 20 ms. Confirms the
resolution; no optimization needed.