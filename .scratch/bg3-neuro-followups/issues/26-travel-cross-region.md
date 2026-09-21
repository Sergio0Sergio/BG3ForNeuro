# 26 — `travel_to` across regions is a hollow ack — no real waypoint teleport

Type: feature
Status: needs-triage
Blocked by: —

## Finding

`executeTravel` (`BG3Neuro.lua:5268-5279`) returns `true, true` — ack only:

```lua
-- Публичного fast-travel Osiris-вызова в research нет (§0/§15): структурный ack.
-- TODO(game): кандидат — телепорт к waypoint-маркеру региона (Osi.TeleportTo/Position);
-- фактический переезд области придёт отдельным state от мод-генератора (Канал B).
return true, true, nil, nil -- success, running (перенос региона — следующий state)
```

`travel_to` inside the current region is done (there is a working path — checklist
"Rest/travel: ... travel_to by location name and by region_id"), but a **cross-region** travel does
not move the party — the region change is expected to arrive as a separate state, relying on the
player doing it manually.

## Plan (research first, bench)

1. **Research (bench):** `Osi.TeleportTo` signature/behavior, `Osi.GetNearestWaypoint(...)`,
   waypoint marker entities per region, whether teleporting to a waypoint actually changes region and
   triggers the same region-change state the generator already emits on manual travel.
2. **Decide:** full teleport-to-waypoint (true cross-region) vs documenting **out-of-scope v1**
   (travel_to = same-region only; cross-region → actionable `not_supported` instead of phantom ack).
3. If implemented: server-side candidate is `Osi.TeleportTo(actor, waypoint)` inside `executeTravel`;
   region move confirmed via next `bg3_to_neuro.json` (`region_id` changed).

## Acceptance

- `travel_to` with a `region_id` in another region either REALLY travels (next state shows the new
  region with the party there) or fails honestly — never ack-without-travel.
- Same-region travel keeps working (regression box from the checklist).

## Cost

Research risk is moderate (Osiris travel API surface unknown); feature itself is contained in one
handler. Blocked on a game stand.