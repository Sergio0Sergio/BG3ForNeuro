# Research: Server status API in BG3SE Lua — enumerating creature statuses + remaining turns (issue 13)

Date: 2026-09-18 (repo snapshot b2b7513, 2026-09-16)
Feeds: issues/13-status-effects-api.md · complements: research/08-enemies-hostility-relation-api.md
Research-only. No project code changed. Primary sources: BG3SE source (this `.scratch/bg3se` clone) + its generated Lua IDE helpers. Every fact below carries file:line.

---

## 0. TL;DR (what to build with)

| Question | Answer | Build with | Confidence |
|---|---|---|---|
| Q1. Where do active statuses live server-side? | Per-character **`esv::status::StatusComponent`** (component name `ServerStatus`) with `StatusId FixedString`, `Type StatusType`, `StatusHandle ComponentHandle`; grouped under a **`StatusMachine`** (`esv::status::StatusMachine`) whose runtime class lists `Statuses` | `EsvStatusMachine.Statuses`, or `EsvCharacter:GetStatus` / `GetStatusByType` | high |
| Q2. How to enumerate all statuses of a creature | `esv::Character::GetStatus` / `GetStatusByType` (exposed via `ExtEntity`-style server P_FUN map) or iterate `StatusMachine.Statuses` | `Osi.GetStatus`/Lua `GetStatusByType` | high |
| Q3. Remaining turns for turn-based statuses | Status runtime tracks **`CurrentLifeTime` / `LifeTime`** (numbers, seconds) + **`TurnTimer`** (number, remaining turns for turn-based ticking) + `TickType` | read `CurrentLifeTime` on `EsvStatus`; turns only meaningful when `TickType` says turn-based | high for fields; **medium** for the exact remaining-turns derivation |
| Q4. Client (eoc) counterpart — not for classification | `eoc::status::ContainerComponent` (`StatusContainer`) is a **client** container mapping `EntityHandle → FixedString Statuses`; do **not** use it to answer ally/enemy/remaining-turns questions | n/a (avoid) | high |

---

## 1. Sources

1. **[BG3SE `GameDefinitions/Components/Status.h`](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/GameDefinitions/Components/Status.h)** — ECS components for statuses, both server (`esv::`) and client (`eoc::`). Lines cited below.
2. **[BG3SE `GameDefinitions/GameHelpers.cpp`](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/GameDefinitions/GameHelpers.cpp)** — `esv::StatusMachine::GetStatus`, `esv::Character::GetStatus/GetStatusByType`, and the `StatusMachine::Statuses` iteration (lines 200-252).
3. **[BG3SE `PropertyMaps/ServerObjects.inl`](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/GameDefinitions/PropertyMaps/ServerObjects.inl)** — Lua-visible property maps for server objects (line 73 `GetStatus`, 74 `GetStatusByType`).
4. **[BG3SE `IdeHelpers/ExtIdeHelpers.lua`](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua)** — generated Lua type/IDE annotations: `EsvStatus` class fields (14350-14419), `EsvStatusMachine` (14512-14513), `EsvCharacter` status accessors (13184-13185).
5. **Runtime Osiris status functions** (`Osi.HasStatus`, `Osi.ApplyStatus`, `Osi.GetStatusRemainingTurns`, etc.): **N O T found as string literals in this repo** — they are the game's OSIRIS function set, exposed by BG3SE at runtime, not declared in the BG3SE source tree. Do not treat a repo grep as a source of truth for the `Osi.*` status list; cross-check against the running game/LuaScripts examples instead (see §7).

---

## 2. Q1 — Server-side home of active statuses

**Answer: two cooperating things.** (a) A per-status ECS component `esv::status::StatusComponent` (registry name `ServerStatus`) with the canonical `StatusId`; (b) a per-character `esv::status::StatusMachine` object (runtime class `EsvStatusMachine`) that owns the `Statuses` collection you actually iterate.

### 2.1 Server status components (`Components/Status.h`)

- `Status.h:74-83` — **the per-status component**:
  ```cpp
  struct StatusComponent : public BaseComponent
  {
      DEFINE_COMPONENT(ServerStatus, "esv::status::StatusComponent")
      EntityHandle Entity;
      ComponentHandle StatusHandle;
      FixedString StatusId;
      StatusType Type;
      Guid SpellCastSourceUuid;
  };
  ```
  `DEFINE_COMPONENT(ServerStatus, …)` → an ECS tag `esv.status.ServerStatus` *plus* the read-only component; via Lua you get it either from `ext.Entity` (tag `ServerStatus`) or by walking the machine.
- `Status.h:66-72` — `esv::status::CauseComponent` (`ServerStatusCause`): carries `Guid Cause` (the thing that caused the status).
- `Status.h:85-90` — `esv::status::OwnershipComponent` (`ServerStatusOwnership`): `EntityHandle Owner`.
- `Status.h:99-104` — `esv::status::UniqueComponent` (`ServerStatusUnique`): unique-status registry `HashMap<FixedString, ComponentHandle> Unique`.
- `Status.h:106-111` — `esv::status::PerformingComponent` (`ServerStatusPerforming`): `FixedString PerformEvent`.

All of these confirm the **status ≠ combat/hostility** model: a status is an owned component on a character entity with an id + type + source/cause. Nothing here encodes "team" or "ally/enemy" — that belongs to `CombatTeam` (see research/08).

### 2.2 The StatusMachine (runtime owner of the list)

- `GameHelpers.cpp:205-214` — `esv::StatusMachine::GetStatus(FixedString const& statusId) const`: **linear scan of `StatusMachine::Statuses`** comparing `status->StatusId`, returning first match.
- `GameHelpers.cpp:230-252` — `esv::Character::GetStatus(FixedString)` delegates to `StatusManager->GetStatus`; `esv::Character::GetStatusByType(StatusType)` **iterates `StatusManager->Statuses`** matching `status->GetStatusId() == type`.

> `StatusManager` is `esv::Character::StatusManager` — the pointer to the character's status machine. This is the connection point: **to list every active status of a creature, iterate `StatusManager->Statuses`.**

---

## 3. Q2 — Enumerating all statuses of a creature (Lua surface)

### 3.1 Confirmed bindings

- `ServerObjects.inl:73-74`:
  ```
  P_FUN(GetStatus, esv::Character::GetStatus)
  P_FUN(GetStatusByType, esv::Character::GetStatusByType)
  ```
- `ExtIdeHelpers.lua:13184-13185` (EsvCharacter):
  ```
  --- @field GetStatus fun(self:EsvCharacter, a1:FixedString):EsvStatus
  --- @field GetStatusByType fun(self:EsvCharacter, a1:StatusType):EsvStatus
  ```
- `ExtIdeHelpers.lua:14412-14513` (EsvStatusMachine):
  ```
  --- @class EsvStatusMachine
  --- @field Statuses EsvStatus[]
  ```

### 3.2 Comment

Osiris's status accessors used by the community (e.g. `Osi.HasStatus`, `Osi.GetStatusCount`, `Osi.GetStatusRemainingTurns`) live in the game's OSIRIS database, not in the BG3SE tree, so **they are NOT reproducible from a repo grep** (see §7). Within pure BG3SE Lua the reliable primitives are `EsvCharacter:GetStatus(byId)` / `GetStatusByType(byType)` and `EsvStatusMachine.Statuses`.

---

## 4. Q3 — Remaining turns / remaining lifetime

- Runtime status fields (from `ExtIdeHelpers.lua` EsvStatus, lines 14350-14419):
  - `14355` `--- @field CurrentLifeTime number`
  - `14377` `--- @field LifeTime number`
  - `14413` `--- @field TurnTimer number`
  - `14412` `--- @field TickType uint8`
  - `14405` `--- @field StatusHandle ComponentHandle`
  - `14406` `--- @field StatusId FixedString`
- The status ticking model in the source distinguishes **time-based** (float `LifeTime`/`CurrentLifeTime` in seconds, decremented every tick) from **turn-based** (turn-synced via the combat turn controller). Only turn-based statuses have an intuitive "remaining turns".
- **"Remaining turns" derivation is NOT spelled out in the repo** (no `GetRemainingTurns`-style helper in the source). The honest primitive set is `CurrentLifeTime` (seconds left) with `TurnTimer`/`TickType` to decide whether to interpret in turns.

### 4.1 Recommended computation (confirm arithmetics at next live run)

```
remainingTurns = status.TickType == turn-based
               and status.TurnTimer           -- turn counter, still to tick
               or math.ceil(status.CurrentLifeTime)  -- seconds fallback
```

Treat this as a **default policy to validate in-game**, not as a repo-documented formula.

---

## 5. Q4 — Client (eoc) counterpart, and why to avoid it

- Client `eoc::status::ContainerComponent` (`Components/Status.h` join — client `StatusContainer` ECS tag) holds `HashMap<EntityHandle, FixedString> Statuses` (map entity → status id) plus `StatusCause/StatusLifetime` client components. It is the **client/presentation** copy of statuses.
- For the "what's active on an enemy with remaining turns" question, read the **server** machine (`EsvStatusMachine.Statuses` / `EsvCharacter:GetStatus*`) instead — the server copy is authoritative for turn management and carries `LifeTime`/`CurrentLifeTime`/`TurnTimer`.

---

## 6. Confidence

- `ServerStatus` component with `StatusId`/`Type`: **high** (Status.h:74-83).
- `esv::Character:GetStatus*` Lua bindings: **high** (ServerObjects.inl:73-74 + ExtIdeHelpers.lua:13184-13185).
- `EsvStatusMachine.Statuses` iteration model: **high** (GameHelpers.cpp:205-214 + 230-252).
- `CurrentLifeTime`/`LifeTime`/`TurnTimer` fields exist on `EsvStatus`: **high** (ExtIdeHelpers.lua:14355/14377/14413).
- Exact "remaining turns" formula (turn counter vs seconds): **medium** — no in-repo helper; §4.1 policy needs a live check.
- `Osi.*` status function list: **not from this repo** — runtime/game data (see §7).

---

## 7. Unverified / do-not-guess

1. Exact `Osi.*` set of status functions (`Osi.HasStatus`, `Osi.GetStatusCount`, `Osi.GetStatusRemainingTurns`, …) — BG3SE's own Osiris list is generated at runtime from the game, not present as literals in this tree. Opportunistic source: BG3SE's own `Docs/API.md` / community mod `LuaScripts` usage, or dump `OsiNamespace` at runtime.
2. Whether `TurnTimer` counts **remaining** turns vs **total/elapsed** — check once in-game against a known-DC status (e.g. a 2-turn CC).
3. `esv::Character::GetStatus` returns first match on StatusId only — stacking/`StackId` behaviour (multiple stacks of one status) is a separate axis; confirm whether you want per-stack or per-status-id.
4. TickType enum values (`0` time-based vs turn-based) mapping — confirm the numeric `TickType` values that mean "turns", since only those give a turns-answer.
