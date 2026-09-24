# research/02 — B-sensor: camera/fog probe (spec §8.1-3, tickets 03/05)

**Status:** closed. Conclusion: camera and fog are **unavailable** in this SE (proven by the bg3se v32 source — not a single
`GetCameraPosition` reader, the `Client` lib is not in `Lua/Libs`, no Reveal/FogOfWar queries). Adopted B implementation —
`Osi.HasLineOfSight` + status gate `INVISIBLE`/`SNEAKING` (the «camera perspective» blind zone is documented;
spec §8 closed, P6 v2 in v0.8.63, followup `24-invisible-b-gate.md`).
**Question:** what is available in Lua for the «player's eyes» (B): camera, «fog-revealed area», occlusion.
**Run rules:** injects strictly serial (`drive_action.ps1`), `autopilot.enabled=false`,
bench = exploration at the gates (as `02-*`), after the run — archive the result in `artifacts/`.

## INTERMEDIATE CONCLUSIONS (probes v1–v3 in the console + v3–v4 in the PAK + SE sources)

**There is no camera in this SE at all — closed question (confirmed by source).**

- PAK probe in the real server context (v068/v069, «ready» 2026-09-20): `Ext.World` = nil,
  `Osi.GetCameraPosition()`/`Osi.GetFogOfWarState()` do not exist.
- PAK probe in the real client context (v069, BG3NeuroClient.lua): `Ext.Client` = nil on all
  namespace members (namespace absent), `Ext.UI.GetCursorWorldPosition()` does not exist.
- Source `bg3se-src` (v32): **in the whole BG3Extender there is not a single `GetCameraPosition`**; in
  `ScriptExtender/Lua/Libs/` there is NO `Client` lib (list: ClientAudio, ClientIMGUI, ClientInput,
  ClientNet, ClientTemplate, Debug, Entity, IO, Json, JsonBinary, Level, Localization, Log, Math,
  Mod, Net, ServerNet, ServerTemplate, Stat*, StaticData, Stats, Table, Timer, Types, Utils, Vars).
- `ClientInput.inl` contains no Cursor/Mouse/Position code — the cursor position is not exposed.
- There are no Reveal/FogOfWar queries in `Lua/Libs` or Osiris → the «fog-revealed area» CANNOT be obtained.
  The «map revealed but off-frame» blind zone is confirmed as rock-solid (for v1) — see §2 below.

**What the engine HAS (osi_signatures.txt v32):**
- `Osi.CanSee(source, target)`, `Osi.CanSeeCached(source, target)` — «engine vision»
  (character frustum or NoFogOfWar flag, depends on mode) — candidate №1 for B (and A/feasible).
- `Osi.HasLineOfSight(source, target)` — occlusion without a cone.
- `Osi.StartSightEvents(character)` / `Osi.StopSightEvents(character)` — One argument, in BG3
  not a flag list (unlike DOS2) — turns on the sight event stream for a character.
- `Osi.GetDistanceTo/GetDistanceToPosition`, `Osi.GetRotation`, `Osi.IteratePlayerCharacters`.

### Sight probe v076 (final, empirically clean): CanSee — a working oracle of engine vision

Run 2026-09-20 (PG bench at the gates, exploration, party of 4, 8 candidates):
- **`Osi.CanSee(lead, x)` WORKS in exploration**: party members nearby (2-4 m)
  → `val="1"`; distant entities (449-1614 m, off-scene) → `val="0"`. Occlusion+frustum are alive.
- **`Osi.StartSightEvents` on all party members did NOT change the result** (`saw_CanSee` after
  1.5 s matched the first measurement 1/1/1 and 0/0/0...). Events are not needed — CanSee is correct without them.
- `Osi.HasLineOfSight` matches CanSee on all pairs (incl. distant 0/0) — CanSee already
  includes occlusion; LOS is not separately needed.
- Symmetry: `CanSeeRev(m->lead)` for party members = 1/1/1; for the distant entity, once `nil`
  instead of `0` (cache/empty note — immaterial). Semantics correction: `1`/`0`/`nil` all valid,
  `nil` ⩵ «does not see».

**DECISION on B (recorded):**
- B-sensor = `Osi.HasLineOfSight(stable lead, candidate) == 1` (memo-lead = first avatar
  from `partyAvatars()`, on emptiness — first from `partySetOf()`); party members always visible.
- `Osi.CanSee` **REJECTED for B**: in exploration `CanSee(lead, NPC)=0` for ALL NPCs (measurement
  v079: 8 NPCs at 11.1-15.2 m all 0), although `CanSee(lead, member)=1`. CanSee distinguishes only
  party/ally members — not an oracle of object visibility.
- `HasLineOfSight` distinguishes (measurement v079: open NPC 11.1 m → 1; NPC behind the gates/barricade
  11.6-15.2 m → 0). Occupied-occlusion works; leader→NPC distance comes from `distance3`.
- Emit only what is «not occluded to the engine within EXPLORE_MAX_DISTANCE»: a candidate without
  `LOS=1` (up to 60 m) — not emitted.
- Degradation: on LOS error/unavailability (first-available empty), the candidate is NOT dropped
  (fallback = visible) — we avoid repeating «everything is silent» on a resolver failure.
- Blind zones remain the same (camera/fog/perspective unavailable — §2): the camera cone is NOT
  emulated (GetRotation yaw angle is not calibrated — don't pull into v1); visibility =
  occlusion from the party lead, documented.
- `StartSightEvents` is NOT called in production (no effect).
- NOT VERIFIED: calibration of the «cone+GetRotation yaw» fallback, if perspective is ever needed — not a v1 blocker.
- No camera at all: `CameraActivate`/`StartCameraSpline` — control, not reading.

**Decisions from the outcome (spec §7/§8):**
- The «real-camera frustum» target option is IMPOSSIBLE — the game cannot be asked where the
  camera is looking. This is a new documented blind zone «camera perspective» (formally falls within
  the «off-frame» blind zone); contract §7 allows this (research → new blind zone).
- B is reoriented to the **«engine visibility zone» via `Osi.CanSee`** (requires verification in
  exploration — probe v070: does CanSee survive outside combat, with StartSightEvents and without; measurement
  of symmetry/LOS/distance). Fallback if CanSee is dead at rest — own cone+LOS from
  the «lead» party member (proxy «the character sees», divergence from the camera is documented).
  **Final B implementation (supersedes the above, see `spec.md` §8:94 + followup 24, v0.8.63):**
  `HasLineOfSight(leader, candidate)` + status gate `INVISIBLE`/`SNEAKING` (exc.
  `TRUESIGHT`/see-invisibility ≤9 m); `CanSee` remains the probe for A/`feasible`.

## Intermediate findings (probes v1–v2, SE console, server-VM `S >>`)

- **`Ext.Client` is completely absent in the server-VM**: `attempt to index a nil value (field 'Client')`
  on all `Ext.Client.*` (GetCameraPosition/Rotation/FocusPosition/CursorWorldPosition/ActiveCamera/
  ZoomLevel/IsZoomedToCharacter/MapReveal/LocalMapFogOfWarVisible/HeadCamera). Our console is the server
  (`S >>`), and **the mod's server Lua (where emission lives) cannot reach the camera via `Ext.Client`**.
  Takeaway: either the server `Ext.World.*` camera (probe v3), or B lives in the client half of the mod
  (`BG3NeuroClient.lua` already has `Ext.UI`/`Ext.Input`/NetChannel bridge to the server).
- **`Ext.IO.WriteFile` is not in the API — the mod writes via `Ext.IO.SaveFile`** (`attempt to call a nil value
  (field 'WriteFile')`; in the mod: `pcall(Ext.IO.SaveFile, ...)`, BG3Neuro.lua:52,71,120,338,1828).
  Relative path — root of `Script Extender\` (comment BG3Neuro.lua:21).
- The SE console executes one line of Lua directly after Enter (no `!lua` — no such command;
  `!` is only for console commands). In v1–v2 a long line was once truncated by pasting
  (`'}' expected near <eof>`); now full execution is achieved.
- Probe v3 (2026-09-20, game alive, save loaded): `Ext.World.GetCameraPosition/Rotation/
  FocusPosition/Yaw/Pitch` **also nil in the console Lua** (`attempt to index a nil value (field 'World')`),
  while **`Ext.IO.SaveFile` worked** — the file `probe_b_sensor.json` was really written to the root
  of `Script Extender\` (pcall = true). Takeaway: **the SE console is an isolated Lua with a reduced `Ext`
  (IO/Json present, Client/World absent), this is NOT the mod's execution context.** The mod really calls
  `Ext.World` only inside `firstAttempt({Osi.GetCurrentMap, Osi.GetCurrentRegion, Ext.World.GetCurrentMap})`
  (BG3Neuro.lua:2653-2663) — the fact of calling from the mod by itself does not prove availability in the game
  context. Authoritative answers are given only by a probe **inside the PAK** (the mod's real server Lua
  and/or the client half `BG3NeuroClient.lua`, where a live `Ext.Client` is expected).

## What we probe

The probe goes through a temporary probe in the mod (or a direct call in the BG3SE console `!luaf`), for each
candidate: `pcall(fn)` → `ok/value`, the error is written verbatim. No candidate is considered
existing before confirmation.

### 1. Camera (server Lua, where the mod emits from)

- Server candidate (v3): `Ext.World.GetCameraPosition()`, `Ext.World.GetCameraRotation()`,
  `Ext.World.GetCameraFocusPosition()`, `Ext.World.GetCameraYaw()`, `Ext.World.GetCameraPitch()`.
  (The mod already works with the server `Ext.World.GetCurrentMap()` — the namespace is guaranteed.)
- Client candidate (if there is no server one): `Ext.Client.*` from the mod's client half via
  NetChannel (the «dialogue» bridge already exists) — but that is costlier, the last resort.
- Result: eye + forward/up → frustum (horizontal/vertical FOV, range `EXPLORE_MAX_DISTANCE`).

### 2. «Fog-revealed area» / map reveal

- Server: `Osi.GetMapReveal(?)`, `Osi.IsMapRevealed(?)`, `DB_MapReveal` — expect absence/incompleteness.
- Client: `Ext.Client.GetMapReveal()`, `Ext.Client.GetRevealState()` — **absence confirmed**
  (Ext.Client nil in the server VM; the client probe part is not done until the camera item is resolved).
- **Decision from the outcome:** if the reveal area cannot be obtained — we record the blind zone «map revealed,
  but off-frame» and do **not** pull it into v1 (the minimap shows enemies only in the field of view, digging deeper is expensive).
  B stays on the frustum+LOS (spec §7 fallback). If possible — compare with the frustum on boundary
  entities (behind/at the edge).

### 3. Occlusion (local obstacles)

- `Osi.HasLineOfSight(cameraPos, ent)` from the eye point (on each candidate) — clean collision,
  without a cone. Known holes (columns/thin barricades) — record as a «documented
  approximation» without additional improvements in v1.

### 4. `Osi.StartSightEvents` (implementation A / feasible in exploration)

- At rest (exploration, before combat) on the party: does `Osi.CanSee` come alive after
  `Osi.StartSightEvents(characterGuidList, ...)`?
- Yes → `feasible` for actions can be built by the engine even outside combat. No → out-of-combat `feasible` stays on
  range+statuses (as now), this is already documented.

### 5. Flicker and cost

- Negative-tick quantile: an entity at the screen edge, ~20 ticks → how many «visible/not visible» flips;
  debounce threshold (>N consecutive negatives → hide).
- Cost: measure the average tick with frustum+LOS over all candidates (N=5, median) — compare against the
  ≤20 ms budget (ticket 05). LOS cache (by position/tick) if over budget.

## The result is recorded in

- `artifacts/08-b-sensor-probe-*.json` (raw pcall results + measurements) → brief summary in this file
  marked «what is available/unavailable, which B variant was adopted (target/fallback/blind zone)».
- The contract (spec §7/§8) is updated only if the probe pointed to a NEW blind zone; the adopted
  B implementation does not affect the contract (ticket 03: «the contract does not depend on research»).