# 26 — `travel_to` across regions is a hollow ack — no real waypoint teleport

Type: feature
Status: done (v0.8.67, PAK v109)
Blocked by: each new PAK requires a graceful game close before install (process rule)

## Finding

`executeTravel` (`BG3Neuro.lua:5381-5392`) returns `true, true` — ack only:

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

## Research (2026-09-22, static + live probe)

- **`scanRegions` is currently broken**: it scans `allEntityGuids("Waypoint")`, but there is **no ECS
  component named "Waypoint"** in bg3se (`ECS.inl`). Live `state_capture` at the Gate: `regions=0` —
  `travel_to` therefore fails validation in C# (`ValidateTravel` → "No known locations") and the
  checklist's in-region travel presumably used an earlier build/schema.
- The real waypoint source is the party ECS component **`PartyWaypoints`**
  (`eoc::party::WaypointsComponent`, `Party.h:77-81`): `HashSet<Waypoint>` with
  `{ FixedString Name; Guid field_8; FixedString Level }`. Reachable from Lua via
  `Ext.Entity.GetAllEntitiesWithComponent("PartyWaypoints")` → `comp.Waypoints`.
- Osiris fast-travel surface: **no `RequestShortRest`-like trigger for waypoint travel**. Available:
  - `Osi.OpenWaypointUI(character, currentWaypoint, item, isFleeing)` — opens the client fast-travel
    UI (waypoint selection screen); the actual travel is a client/story path
    (`NETMSG_OPEN_WAYPOINT_UI_MESSAGE`, `NETMSG_TELEPORT_WAYPOINT`, `NETMSG_LOCK/UNLOCK/REGISTER_WAYPOINT`).
  - `Osi.TeleportTo(sourceObject, targetObject, event, link, partyFollowers, summons, leaveCombat, snap)`
    and `Osi.TeleportToPosition(...)` — raw teleport to an entity/coords; **does not change level** —
    works only within the currently loaded level. Cross-region needs a level change
    (`TeleportPartiesToLevelWithMovie(levelName, ...)`, `NETMSG_LEVEL_SWAP` family).
  - `Osi.RegisterWaypoint / UnlockWaypoint / LockWaypoint(name, ...)` — bookkeeping, not travel.
- **Implication:** a true cross-region travel is a level-swap operation (unload → load → place party),
  not a positional teleport. Any honest implementation must either drive `OpenWaypointUI` +
  client-side waypoint click (mirroring the ticket-25 resting-screen route) or document
  out-of-scope and return an actionable error instead of `true,true`.

## Plan (research first, bench)

1. **Research (bench):** read `PartyWaypoints` on a live stand (which names/levels exist), confirm
   `TeleportTo` cannot cross levels, check whether `OpenWaypointUI` correctly opens and whether a
   client-side waypoint item is clickable (same pattern as ticket 25's HotBar DC command).
2. **Decide:** full waypoint travel via client UI (open waypoint screen + select) vs documenting
   **out-of-scope v1** (travel_to = same-region only; cross-region → actionable `not_supported`
   instead of phantom ack).
3. If implemented: server-side sends a client-UI action over the NetChannel; region move confirmed
   via next `bg3_to_neuro.json` (`region_id` changed). Fix `scanRegions` to read `PartyWaypoints`
   either way (needed for honest validation).

## Implementation (v0.8.65, PAK v100 — not installed yet, game running)

Decision: **full path** (waypoint UI click, mirror of ticket 25). Changes in the repo:

- **Server `scanRegions`** now reads the real ECS component `PartyWaypoints`
  (`BG3NEURO_WAYPOINTS.collect()` — global table, main chunk is at the 200-local limit):
  region entries `{ name, region_id, distance=0, region, level, waypoint_guid }`. C# `ValidateTravel`
  will finally see populated regions (was always 0 → hard-blocked).
- **Server `executeTravel`** now honest: `Osi.OpenWaypointUI(actor, "", nil, 0)` opens the fast-travel
  screen, then `BG3NEURO_TRAVEL.bridge:Broadcast({ kind="bg3neuro_travel_click", action_id, waypoint })`.
  Fire-only; final confirmation = next state (`region_id` changed). Bridge is a global-table mirror of
  `BG3NEURO_REST` (channel `BG3NeuroTravel`, retry 4×800ms on `retry:`, honest `not_supported` fallback).
- **Client** `executeTravelViaUi(target)` scans the Noesis tree (depth 14) for button candidates,
  logs `travel: cmd candidate <typ>:<name> text=...`, then clicks the one whose text/DataContext.Name
  matches the target waypoint (Command:Execute with CommandParameter). New client bridge
  `BG3NeuroTravel` → `performTravelClick`. Client locals 71/200, server 200/200, luaparse OK.
- **Bench (next):** after game close → install v100 (MD5 `0E334B7B9494A6C77B508F3171B84D4A` in **both**
  modsettings nodes) → `state_capture` (expect `regions > 0`) → `travel_to` inject → watch client log
  `travel: cmd candidate ...` (what buttons appear after OpenWaypointUI) and next `region_id` in state.
- Risk: `OpenWaypointUI` may not open a clickable overlay the way the rest screen did; candidate scan
  output will tell (empty list → visible non-clickable → fallback decision).

## Outcome (v0.8.67, PAK v109 — bench PROVEN 2026-09-22)

The UI-click route is dead (bench v108): `ls.JournalMap` is a **native Scaleform widget** — `full_dump`
shows `123: ls.UIWidget:JournalMap d5 cc=1 vc=1` → `124: ls.JournalMap: d6 cc=0 vc=0` (no Noesis
children), `full_dc` finds `gtw=False` on every HUD widget. `NETMSG_TELEPORT_WAYPOINT` exists in
`NetMessage.inl` (=221) but `Ext.Net` only exposes **custom channels** (`PostMessageToServer/Client`,
`BroadcastMessage`) — raw engine netmsg is not sendable from Lua.

Real engine travel found in the game's own story data (`GLO_LevelSwap.txt:325`):
`TeleportPartiesWithMovie(_StartTrigger, "", _Movie)` — the trigger IS the waypoint position.
`_Gustav_Waypoints_Act1.txt` links `DB_WaypointInfo("Act1","WAYP_CHA_Top",
(ITEM)S_CHA_WaypointShrine_Top_8ebd584c..., (TRIGGER)S_CHA_WaypointTrigger_Top_4141c0a2-... )` —
the **TRIGGER GUID == `waypoint_guid`** already exposed in state (field_8 of `PartyWaypoints`).

**Server `executeTravel` (v0.8.67)** resolves the waypoint by name/`wp_N` in
`BG3NEURO_WAYPOINTS.collect()`, takes `field_8` (trigger GUID), calls
`Osi.TeleportPartiesWithMovie(waypoint_guid, "", "")`. Cross-region works too — the engine loads the
target level and places the party itself (this is exactly the game's fast travel).

**Bench (stand, in-game, channel ready / client 0.8.63 + server 0.8.67):**
- `travel_to WAYP_CHA_Chapel` → log `travel: TeleportPartiesWithMovie (server) -> WAYP_CHA_Chapel
  (5e857e93-203a-4d4a-bd29-8e97eb34dec6)`, Tav moved to the beach/Chapel area.
- `travel_to WAYP_CHA_Top` → `(4141c0a2-5ba9-42c0-ab18-082426df45e7)` (matches Loki trigger GUID),
  Tav moved to the mountain pass: position (222.8, 16.4, 325.8) vs (276, 2.5, 297.7); objects changed
  (mephits/goblins instead of beach devourers). No `retry:no_waypoint_match`, both injects accepted,
  no error dialogs, `region_id` in `regions` list reflects the new area state.

## Cross-region bench PROVEN (2026-09-22, v0.8.67 / PAK v109, live Underdark)

- Opened a real second region: solved the Defiled Temple moon puzzle → Selunite Outpost → **Underdark**
  (`WLD_Underdark`). `WAYP_UND_Fort` (`dddb39d6-c5ac-4470-98c5-395ce81af017`) auto-registered in
  `PartyWaypoints`.
- `travel_to WAYP_CHA_Chapel` **from Underdark**: party teleported out — positions changed from
  `~140,49,-125` (Selunite Outpost) to `276,2.5,297` (Overgrown Ruins beach). `TeleportPartiesWithMovie`
  with a waypoint trigger performs the **level swap itself**, exactly like the engine's fast travel —
  no `TeleportPartiesToLevelWithMovie` needed for open waypoints.
- Note: the waypoint `Level` field reads back as `WLD_Main_A` even for `WAYP_UND_*` — the trigger GUID
  (`field_8`) is the reliable key, level field is informational only.
- Bench-side hazard hit along the way: a stuck empty combat flag (`TurnBasedComponent` with no roster,
  `allies=0 enemies=0`, caused by a mid-combat teleport) suppresses the `regions` emitter → travel looked
  broken. Cleared by a plain Load Game (no game restart needed). Worth a note in CONTEXT.md Diagnostic
  traps if it recurs.

## Acceptance

- `travel_to` with a `region_id` in another region either REALLY travels (next state shows the new
  region with the party there) or fails honestly — never ack-without-travel. **DONE (v0.8.67): measured
  party-position change twice: Chapel→Top (same level) and **Underdark→Chapel (cross-region level swap)**.
- Same-region travel keeps working (regression box from the checklist). **Same code path — the engine
  teleports the party within/into the requested level.**

## Cost

Research risk is moderate (Osiris travel API surface unknown); feature itself is contained in one
handler. Blocked on a game stand.