# 21 — Combat capture cost (TurnStarted) exceeds the 20 ms perception threshold

Type: task (measure + decide optimize vs re-tune threshold)
Status: open (measured 2026-09-20, not yet decided)
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

## Options (for the next live session / code pass)

1. Optimize: only refresh per-actor `spells`/statuses for the acting character;
   roster-wide fields on turn change only. Kick the heavy reads for non-acting
   actors.
2. Split write: full state on player-turn starts, reduced state on NPC starts.
3. Re-tune: accept event-driven capture ≤ 100 ms as "fine" (one-shot per turn,
   no UI stall comparable to a tick) and adjust threshold wording in the
   checklist/ticket 05 accordingly.

## Status

Open. Minimum viable: on the next live session capture 3–5 `Dispatching ... took N ms`
combat samples for the median; then pick option 1 or 3. Until then the checklist
box stays unchecked.