# 06 — Research: honest movement deduction (confirming/refuting "before/after")

Type: research
Date: 2026-09-13
Feeds: issues/06-movement-ap-spend.md · issues/05-bonus-actions-pipeline.md · issues/02-resource-snapshot-scheme.md · map.md (Q6)
Primary source: `LaughingLeader/BG3ModdingTools/generated/Osi.lua`, `Shared.pak` → `Public/Shared/ActionResourceDefinitions/ActionResourceDefinitions.lsx`, `bg3se-src` (`GameDefinitions/Components/ActionResources.h`), live story dump SE v32, mod code `BG3Neuro.lua` (executeMoveToTarget 2163–2193).

## 0. TL;DR — verdict on the owner's default

| Question | Answer |
|---|---|
| `CharacterMoveTo`/`CharacterMoveToPosition` deduct AP themselves? | **No.** Neither AP nor (by the same mechanism) `Movement`. It's a scenario Osiris call: the signature has no resource parameters, it doesn't go through the server "MoveTo" pipeline that accounts for movement (see §1). |
| `Osi.TransferActionResource` exists? | **No.** Absent from `Osi.lua` (983 symbols) and from the dumps. The name is made up. |
| Is the "manually before/after" variant viable? | **Viable, but with two corrections:** (1) you must capture the **`"Movement"`** resource (meters, `resourceLevel=0`), not AP; (2) the game itself **never changes** either AP or Movement for Osiris movement, so there's nothing to "refund as extra" from the snapshot — the honest cost (the distance traveled) must be computed by the mod itself. "Before/after" becomes "deduct by the distance computed by the mod", not "re-capture and return what the game consumed". |
| Full public write API for resources | Only `Osi.AddActionPoints(object, amount)` (AP-specific) and `Osi.PartyIncreaseActionResourceValue(player, resourceName, delta)` (any resource, but **party semantics**, dangerous). There's no personal public "set" for `Movement`. |

## 1. AP deduction by `CharacterMoveTo` itself — NO

Facts:

1. **Signature (LaughingLeader Osi.lua, `---@param`, verbatim):**
   ```lua
   ---@param character CHARACTER
   ---@param target GUIDSTRING
   ---@param movementSpeed string
   ---@param event string
   ---@param moveID integer
   function Osi.CharacterMoveTo(character, target, movementSpeed, event, moveID) end
   ---@param character CHARACTER
   ---@param x number
   ---@param y number
   ---@param z number
   ---@param movementSpeed string
   ---@param event string
   ---@param moveID integer
   function Osi.CharacterMoveToPosition(character, x, y, z, movementSpeed, event, moveID) end
   ```
   Not a single resource parameter. `movementSpeed` is an animation-speed string (`"Run"`/`"Walk"`), not an equivalent of the in-game movement resource.

2. **Mechanism.** A live story dump (SE v32) shows the real call: `PROC_CharacterMoveTo(char, target, "Run", event)` → `_Intern` → `CharacterMoveTo(..., 1)` (DIV call). It's the universal mechanism of scenario movements (reinforcement squads, cutscenes) — it runs the character along the path and fires `EntityEvent`, without touching combat resources.

3. **Mod empirics.** Live tests: AP is not spent during movement (recorded in the ticket). The same precedent — **Brawl** (real-time combat): `CharacterMoveTo`/`CharacterMoveToPosition` are used "as is", AP is spent only on attacks/casts through `ServerCastRequest`.

4. It should be separately checked on the bench whether the **`Movement`** resource changes for `CharacterMoveTo` (expectation: it doesn't, for the same reason; but it's a one-line snapshot in ticket 02 — cheap).

Conclusion: there's no honest "movement with AP" in Osiris at all; the native movement accounting (`Movement`, meters) lives in the client-server "MoveTo" pipeline (the Anubis task), which `Osi.CharacterMoveTo` **does not use**.

## 2. Exact resource API signatures (Osi.lua, generated dump)

```lua
---@param player CHARACTER
---@param resourceName string
---@param resourceLevel integer
---@return number amount
function Osi.GetActionResourceValuePersonal(player, resourceName, resourceLevel) end        -- QUERY (per-character read)

---@param player CHARACTER
---@param resourceName string
---@return number amount
function Osi.PartyGetActionResourceValue(player, resourceName) end                          -- QUERY (party aggregate)

---@param object GUIDSTRING
---@param amount integer
function Osi.AddActionPoints(object, amount) end                                            -- CALL (AP-specific; negative = spend; proven in mod code v0.8.22: AddActionPoints(actor, -1))

---@param player CHARACTER
---@param resourceName string
---@param delta number
function Osi.PartyIncreaseActionResourceValue(player, resourceName, delta) end             -- CALL (any resource by name; negative = spend; BUT party semantics)
```

`Osi.GetActionResourceValuePersonal` is a query: it returns a number only for a valid `resourceName`; for an invalid one it returns `nil`/0. Always `pcall` + value check.

## 3. Valid `resourceName` values for movement

Primary source — the unpacked `Shared.pak`:

`Public/Shared/ActionResourceDefinitions/ActionResourceDefinitions.lsx` (the dump below is an excerpt), resource definitions:

| Name | MaxLevel | ReplenishType | PartyActionResource | Comment |
|---|---|---|---|---|
| `ActionPoint` | 0 | Turn | — | basic action |
| `BonusActionPoint` | 0 | Turn | — | bonus action |
| `ReactionActionPoint` | 0 | Turn | — | reaction (hidden, `ShowOnActionResourcePanel=false`) |
| **`Movement`** | **0** | **Turn** | — | **the movement resource: meters, replenished each turn** |
| `ExtraActionPoint` | 0 | Never | false | double action (Haste and similar) |
| `WeaponActionPoint` | 0 | ShortRest | — | weapon action (new in Patch 8) |
| `SpellSlot` / `WarlockSpellSlot` | 9 | Rest/ShortRest | — | level = 1..9 |
| … | | | | Rage, KiPoint, SorceryPoint, ChannelDivinity, SuperiorityDie, BardicInspiration, WildShape, ChannelOath, LayOnHandsCharge, HitDice, … |

Findings:
- **`"MovementPoint"` is NOT a resource name.** The expected name is **`"Movement"`**. `GetActionResourceValuePersonal(player, "Movement", 0)` — a valid query (meters, e.g. 7.5).
- `resourceLevel` for `Movement`/`ActionPoint`/`BonusActionPoint` = **0** (they have `MaxLevel=0`); for SpellSlot = 1..9. A live story dump confirms `resourceLevel=0` for non-slot resources (e.g., `GetActionResourceValuePersonal(char, "WeaponActionPoint", 0)`) and `1..9` for `SpellSlot`.

Internals (bg3se `ActionResources.h`): a character has the `eoc::ActionResourcesComponent` component = `HashMap<Guid, Array<ActionResourceEntry>>`, where `ActionResourceEntry = { ResourceUUID, Level, Amount, MaxAmount, ReplenishType, DiceValues }`, and `Amount` is a **double**. I.e., a resource's value is stored in the core as a per-level list; `GetActionResourceValuePersonal` maps name → definition UUID. The core's internal write path is the `SetResourceValue` queue (`ActionResourceSetValueRequest { ResourceId, Amount, OldAmount }`) in `esv::ActionResourceSystem` — not reachable publicly from Lua.

## 4. What the native movement cost looks like in BG3

- In tactical (Turn-Based) mode, character movement deducts the **`Movement`** resource (meters), not AP: the green movement bar goes down; 7.5 m by default, half-cost/double distances are controlled by statuses and `MovementSpeed` stat worlds.
- The deduction is done by the client-server "move" task (player input / AI), i.e. **not** by the story call `Osi.CharacterMoveTo`. So for neuro movement the game itself will deduct nothing — neither AP nor Movement. That's exactly what was observed in live tests (AP didn't drop).

## 5. Is the "before/after" variant viable + the call order

### Scheme A — "as the owner literally said" (AP snapshot, refund the "extra") — does NOT work as intended

Since `CharacterMoveTo` doesn't touch AP, `AP_after == AP_before`, the delta is 0, there's nothing to refund as "extra", and without an explicit "how much to deduct" decision the mod will deduct nothing. The AP snapshot here is a dead signal.

### Scheme B — the correct one (`Movement` snapshot + explicit spend by distance)

The call order in server Lua (BG3SE is single-threaded: each chunk executes on the main thread, no races at the read point):

1. `resolve actor/target`, validation (`Osi.CanMove`, `IsMovementBlocked` — optional).
2. `cancelActiveMove(...)` — interrupt the previous movement (the mod code already does this), account for a refund (see §6).
3. The "before" snapshot: `local m0 = pcall-GetActionResourceValuePersonal(actor, "Movement", 0)`.
4. Record `startPos = Osi.GetPosition(actor)` (for distance estimation; more precisely — by the finish after the move).
5. Start `Osi.CharacterMoveTo` / `Osi.CharacterMoveToPosition(… "Run", moveEvent, moveId)`; `activeMove = { id, event = moveEvent, moveId }`; return `running:true`.
6. Wait for an **event-based** completion (not `WaitFor`): the `EntityEvent` listener (BG3Neuro.lua:1235) is already in place, matching `event == activeMove.event`; here too (or in `CharacterMoveToCancelled`, currently a no-op at 1218) is the "after" snapshot point.
7. At the final: `local m1 = GetActionResourceValuePersonal(actor, "Movement", 0)`; `local movedMeters = |endPos - startPos|` via `Osi.GetPosition` (a straight line — an approximation; formal honesty — by path length, but for v1 a straight line/a standoff point is enough).
8. **Deduction:** lower the resource by the actual distance:
   - preferred: `Osi.PartyIncreaseActionResourceValue(actor, "Movement", -movedMeters)` — **verify on the bench** whether it hits the whole party (party semantics — the main risk);
   - fallback (already proven on the bench in the mod code): `Osi.AddActionPoints(actor, -1)` — a **dash-equivalent** "moving = 1 action", without meter precision.

### What exactly gets "refunded"

If per item 8 you deducted a wider bracket (e.g., minus AP upfront, to keep another action from slipping in between step 5 and the final), the "refund" is a second write with the same call: `PartyIncreaseActionResourceValue(actor,"Movement", +refund)` / `AddActionPoints(actor, +extra)` in the same final callback. The deduct/refund calls aren't atomic (they're just writes into the core resource system), but at a single execution point on a single thread there will be no double execution.

## 6. Pitfalls

- **`TransferActionResource` doesn't exist** — don't reference it in code/docs; work with `AddActionPoints` / `PartyIncreaseActionResourceValue`.
- **ResourceLevel:** for `Movement`/AP/BA = `0`; anything else → `nil`.
- **`resourceName`:** you need `"Movement"`, not `"MovementPoint"` (no such definition) and not `"MovementSpeed"` (that's a stat).
- **Party write semantics:** there's no public personal writer for an "arbitrary resource". `PartyIncreaseActionResourceValue` is party-wide by name and signature; before using it, a mandatory bench test: does it really change only on the target, or on the whole party/aggregate. If it hits the party — keep the `AddActionPoints(-1)` dash-equivalent.
- **`AddActionPoints` — AP only**, integer `amount`; negative works (proven live in v0.8.22). The "movement = meters" model isn't expressible with it.
- **Distance ≠ straight line:** movement goes along a navigation path (A* under Osi), `|endPos - startPos|` understates the real path. For an honest meter economy, if you want to measure by path — take `FindValidPosition` waypoints (the Brawl `moveToDistanceFromTarget` precedent) and sum the segments.
- **Single-threading/events:** the "before" snapshot is allowed only at the dispatch moment (server Lua), the "after" snapshot — **only from the completion event** (`EntityEvent` by the `event` guid, or `CharacterMoveToCancelled`). No `WaitFor` until the movement ends. If the final never arrives — `activeMove` hangs; the current channel B (the next state) will pick it up, but then the deduction must happen there too, otherwise the spend is lost.
- **Interruption:** on a new command `cancelActiveMove` closes the previous movement as "cancel" — at this point it must be decided whether what's already traveled gets deducted (deduct the accumulated amount) or the movement is canceled without cost. Candidate — route it into `CharacterMoveToCancelled` (currently empty).
- **Negative `Movement`:** `PartyIncreaseActionResourceValue(actor,"Movement",-dist)` when `dist > current` — don't let the resource go negative (check `m0` before the deduction; the engine usually clamps by `MaxAmount`, but verify the negative-overflow behavior on the bench).

## 7. Output recommendation (for the ticket-decision)

- Keep "manually" (the owner's default), but the target resource is **`"Movement"`** (meters), deducted by the distance actually traveled at the movement-completion event point.
- Calls: `GetActionResourceValuePersonal(actor, "Movement", 0)` before/after (the snapshot = the honesty criterion from ticket 02), deduct/refund via `PartyIncreaseActionResourceValue` **after the bench check of party semantics**, otherwise `AddActionPoints(actor, -1)` (dash-equivalent) as a proven fallback under the `force_legacy` flag.
- Concrete changes in `executeMoveToTarget` (BG3Neuro.lua 2163) — in a separate ticket; here only facts and the order.

## Sources

1. `LaughingLeader/BG3ModdingTools/generated/Osi.lua` (983 built-in calls + queries) — signatures §2. Cross-check: `MCPadak/BG3ModInfos` Osi-Functions.
2. `Shared.pak` (Patch 8 / HF9) → `Public/Shared/ActionResourceDefinitions/ActionResourceDefinitions.lsx` — valid resource names §3.
3. `bg3se-src` → `BG3Extender/GameDefinitions/Components/ActionResources.h` — the core resource layout (§3, §4).
4. Live story dump SE v32 (`Story\RawFiles\Goals\*.txt`) — the `CharacterMoveTo(char,"Run",event)` call as a scenario mechanism; enumeration of resourceNames/levels.
5. `tinybike/Brawl` — a real mod: movement via `CharacterMoveTo`/`CharacterMoveToPosition` without AP accounting; attacks/casts via `ServerCastRequest`.
6. Mod code `mod/BG3Neuro/BG3Neuro.lua`: `executeMoveToTarget` (2163–2193), the `EntityEvent` final (1235), `CharacterMoveToCancelled` (1218), the live-proven `AddActionPoints(actor, -1)` (2289).