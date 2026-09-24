# 01 — What engine/BG3SE signals give off the party's "perception" of an entity?

Type: research
Status: resolved
Blocked by: none

## Question

What signals are available from the mod's Lua context (BG3SE) to determine whether the **party perceives** a given entity right now — and which of them can serve as a source of truth for the three-state `visible`/`known`/`unknown`?

A report is required on candidates: the exact API/component name, how to call it, what it returns, its limitations. At minimum:

- direct visibility / line-of-sight (`CanSee`-like Osi predicates, raycasts, vision components);
- stealth and detection (invisibility, stealth, `IsInvisible`/`IsHidden`, engine shroud/fog);
- engine awareness/memory (does the party know about the entity: combat-aware, fog-of-war for a specific entity);
- how client and server contexts differ (the mod lives in both);
- cost of a call per entity per tick (for many entities).

## Constraints

- The mod lives in two contexts (`CONTEXT.md`): server (command emission/reception) and client (UI). The signal must work where the state is born.
- `Osi` is a lazy resolver: you cannot probe `Osi.X ~= nil`, only call it directly via `pcall` (AGENTS.md rule).
- Both combat and exploration must be covered.

## Deliverable

`research/01-perception-signal-api.md`: a candidate table (signal → what it gives → limitations → recommendation), with links to primary sources (BG3SE source/docs). Plus a brief verdict: is there one universal signal or is composition needed.

## Verification

- Each claimed API is confirmed by a primary source (BG3SE code / documentation), not a guess.
- Explicitly marked where no signal exists and an approximation will be required (this ties into decision Q7 of the map).

## Answer

Report: [`research/01-perception-signal-api.md`](../research/01-perception-signal-api.md).

- **There is no single universal signal.** Recommendation — composition.
- **Primary candidate:** `Osi.CanSee(source, target)` → int bool (`Osi.lua:216`), OR over party members; cheap alternative `Osi.CanSeeCached` (`Osi.lua:221`).
- **Geometry separately:** `Osi.HasLineOfSight(source, target)` → 1/0 (`Osi.lua:1373`) — pure LOS, without statuses.
- **Explanatory statuses:** `Osi.IsInvisible` (`Osi.lua:1686`), `IsInvisibleByScript` (`Osi.lua:1690`), `Osi.HasActiveStatus(uuid, "SNEAKING"/"INVISIBLE")` (`Osi.lua:1340`). The engine reference is `brawl_Utils.lua:266 isVisible` (statuses, **without** geometry).
- **Not it:** `Osi.ShroudRender`/`NETMSG_SHROUD_UPDATE` — **map** fog, not entity visibility.
- **Deferred:** server viewshed (`Sight`/`ServerViewshedParticipant`/`ServerSightAggregatedData`) — authoritative, but reading from Lua not confirmed.
- **Open for 02:** exact `CanSee` semantics (light/cones/height/stealth), client/server difference and cost at N×M. All Osi references cross-checked line by line against `bg3se\Osi.lua`; AI references — against `bg3se\brawl_Pick.lua:293,551`, `bg3se\brawl_Actions.lua:339`.