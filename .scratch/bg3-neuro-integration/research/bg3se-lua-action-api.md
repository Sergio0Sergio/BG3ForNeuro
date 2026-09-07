# Research: BG3SE Lua/Osiris API for Game-Action Execution (Action Executor, ticket 07)

Date: 2026-09-05
Feeds: issues/07-action-execution.md · complements: research/ipc-named-pipes.md, issues/03/04/05/06

## 0. TL;DR (what to build with)

| Action (ticket schema) | Primary BG3SE call | Reliability |
|---|---|---|
| `move_to_target`, `move_to_entity` | `Osi.CharacterMoveTo(pos)` / `Osi.CharacterMoveToPosition(x,y,z)` | ✔ reliable |
| teleport helper | `Osi.TeleportTo` / `Osi.TeleportToPosition` | ✔ reliable |
| `attack_entity` | `Osi.Attack(character, target, alwaysHit)` | ⚠ works, one-shot, no action-cost integration |
| `cast_spell` | `Ext.System.ServerCastRequest.OsirisCastRequests` (queue push) | ✔ reliable (modern path) |
| `cast_spell` fallback | `Osi.UseSpell` / `Osi.UseSpellAtPosition` | ⚠ ok for scripted casts |
| `use_item` | `Osi.Use(character, item, useItem, isInteraction, event)`; equip: `Osi.Equip` | ✔ reliable |
| `throw` | no public Osiris call — client input / Anubis `AnubisMoveItem` only | ✘ not automatable reliably |
| dialogue start | `Osi.CharacterMoveToAndTalk` / automated: `Osi.StartDialog_Internal` | ✔ |
| dialogue option pick | **no public function exists** (see §7.6) | ✘ → client UI, experimental |
| `rest` | `Osi.RequestLongRest(initiator, isForced)` (+ `RequestLongRestConfirmed`) | ✔ reliable |
| stealth `toggle_mode` | **no public function exists** | ✘ → experimental |
| turn detection (`end_turn`, state) | events `TurnStarted/TurnEnded/CombatRoundStarted`, `Osi.CombatGetActiveEntity` | ✔ reliable |
| `loot` | `Osi.Pickup`, `Osi.OpenCharacterLootUI`, `Osi.MoveAllLootableItemsTo`, `Osi.ToInventory` | ✔ reliable |
| spell list / inventory list (item 12) | `Ext.Stats.GetStats("SpellData")`, `Ext.Entity.Get(c).SpellBook.Spells`, `Ext.Entity.Get(c).Inventory`, `Osi.IterateInventory` | ✔ reliable |
| threading (ticket Q4) | Lua is **single-threaded** on the engine's main thread; use `Ext.Timer` + serial command queue | fact |

Legend: ✔ = documented in SE docs and/or exercised by real maintained mods; ⚠ = signature known/works but behavior is version-dependent or bypasses game systems; ✘ = no supported public call; only hacks.

---

## 1. Sources

High-trust, cross-checked against each other:

1. **[BG3SE Docs/API.md](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md)** — official SE Lua framework documentation (Ext.IO, Ext.Timer, Ext.Json, Ext.Stats, Ext.Entity, Ext.Events, calling Osiris from Lua, network).
2. **[BG3SE `ExtIdeHelpers.lua`](https://raw.githubusercontent.com/Norbyte/bg3se/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua)** — official autocomplete dump: every ECS component field + type aliases (`ActionDataType`, `ClientCharacterTaskType`, `OsirisTaskType`, `Anubis*` operations, etc.).
3. **Generated Osiris symbol dump (story_header.div → Lua)** — `LaughingLeader/BG3ModdingTools/generated/`:
   - `Osi.lua` (983 built-in **calls + queries**, exact `---@param` types),
   - `Osi.Events.lua` (320 built-in **events**),
   - `Ext.Osiris.RegisterListener.lua` (every event + arity for `RegisterListener`).
   Raw: <https://raw.githubusercontent.com/LaughingLeader/BG3ModdingTools/master/generated/Osi.lua> (same for the other two).
   This is the closest thing to a maintained Osiris reference now that the project wiki is retired.
4. **Real mods (server-side Lua)**: `Norbyte/bg3se` `SampleMod/.../BootstrapServer.lua` (official usage of `RegisterListener`), `tinybike/Brawl` (combat automation: `Server/Movement.lua`, `TurnOrder.lua`, `Actions.lua`, `Pick.lua`), `BG3-Community-Library-Team/BG3-Community-Library` (reference scripts).
5. `bg3.wiki`, the GitHub wiki (`/wiki/Osiris-Functions`, `/wiki/Combat-Utils`) and `wiki.bg3.community` were checked — the first two are dead/moved, the last was unreachable for deep content; items 1–4 above are authoritative enough to stand alone.

Caveat: the generated dumps are tied to a specific game/patch (SE version). Symbols listed here exist in the current (v30+) story library; **verify against your SE version** via `Ext.DumpCallstack`/console autocomplete before locking schemas.

## 2. How to call Osiris from Lua (conventions)

All of this is from API.md §"Calling Osiris from Lua" (v30):

```lua
-- Built-ins are exposed both bare and via Osi table (server Lua context only)
CharacterResetCooldowns(player)
Osi.CharacterResetCooldowns(player)         -- same call

-- Queries: 0 OUT → boolean; k OUTs → k return values
local ok          = Osi.IsInCombat(charGuid)
local x, y, z     = Osi.GetPosition(charGuid)

-- Database reads: Osi.DB_<NAME>:Get(f1, f2, ...) with nil = wildcard
local rows = Osi.DB_GiveTemplateFromNpcToPlayerDialogEvent:Get(nil, nil, nil)
-- Database insert / delete
Osi.DB_CharacterAllCrimesDisabled(player)
Osi.DB_GiveTemplateFromNpcToPlayerDialogEvent:Delete(nil, nil, nil)

-- Capturing a story event from Lua (turn/combat/dialog/etc.)
Ext.Osiris.RegisterListener("TurnEnded", 1, "after", function (characterGuid)
    ...end)
-- ind:"<name>", arity:<#params incl OUT>, "before"|"after"|"beforeDelete"|"afterDelete"
-- captured event arities are listed in generated/Ext.Osiris.RegisterListener.lua
```

Implementation note (API.md): name resolution happens at call time (overload by arg count), so `Osi.Something ~= nil` can NOT be used to test symbol existence.

Client vs server: **game-action OS calls run in the server Lua context** (`ScriptExtender/Lua/BootstrapServer.lua`). UI-side calls (`Ext.UI`, picking, dialogue window) are client-only (`BootstrapClient.lua`). Our IPC loop must therefore live on the server side; the client state should be mirrored separately if the UI path is used for dialogue.

## 3. Runtime & threading model (ticket 07, question 4 — "is BG3SE Lua single-threaded?")

**Answer: yes.** Pure Lua mods execute on the engine's single main (server) thread. Concretely:

- One Lua state per context (server/client); every listener, timer callback, and Osiris hook runs on that thread; there is no thread pool and no `coroutine`-based concurrency exposed for mods (only the engine-internal state machines like `Anubis*` tasks, which are C++-side and are themselves serialized).
- `Ext.Timer.WaitFor(ms, cb)` / `Ext.Timer.WaitForRealtime(ms, cb)` do **not** spawn threads; they defer `cb` until the main loop reaches the deadline. `WaitForRealtime` uses the OS clock and is the correct primitive for our poll interval (dt. research/ipc-named-pipes.md; game clock pauses e.g. in menus).
- A long-running blocking Lua loop (or a heavy C++ call it triggers) stutters/freezes the whole game on that thread.
- Consequences for the executor:
  - **Serialize all commands**: at most one in-flight action per context; enqueue in C# and in Lua.
  - Keep every handler short and non-blocking; read the command file, dispatch, write the result — target «под секунду», ideally «десятки мс» per action (SPECIFICATION consensus «action/result ASAP, before it happens in-game»).
  - Actions that take game time (movement, spell animation) must not be awaited synchronously — fire-and-forget + report completion via an event/callback, not by sleeping on the Lua side.

## 4. Movement (`move_to_target`, `move_to_entity`, exploration)

Signatures (story dump, `Osi.lua`):

```lua
--- CHARACTER GUID, GUIDSTRING target, string movementSpeed, string event, integer moveID
Osi.CharacterMoveTo(character, target, movementSpeed, event, moveID)
--- x,y,z:number, movementSpeed:string, event:string, moveID:integer
Osi.CharacterMoveToPosition(character, x, y, z, movementSpeed, event, moveID)
Osi.TeleportTo(sourceObject, targetObject, event, tc, tpF, tS, leaveCombat, snapToGround)
Osi.TeleportToPosition(sourceObject, x, y, z, event, tc, tpF, tS, leaveCombat, snapToGround)
```

- `movementSpeed` is a string like `"Walk"`/`"Run"` (Brawl) — value must match the float-speed names; `"Run"` is the safe default for combat, `"Walk"` for RP. The `event` param is a GUID-string *story event id* used to observe completion/cancel via `RegisterListener("CharacterMoveToCancelled",...)` etc.; `moveID` is an integer move identifier.
- Used verbatim in production code: `Osi.CharacterMoveTo(uuid, targetUuid, getMovementSpeed(uuid), eventUuid)` and `Osi.CharacterMoveToPosition(uuid, x, y, z, ..., eventUuid)` (Brawl `Movement.lua`; completion events `CharacterMoveToCancelled`/`CharacterMoveToAndTalkFailed` exist in the events dump).
- Companion target position helper: `Osi.FindValidPosition(x, y, z, radius, character, snap)` (query, used by Brawl for «near target» waypoints).
- **Path-finding is game-native** (Osi handles it); do NOT reimplement A*. For «move in range of target» prefer computing a standoff point via `GetPosition` + vector math (like Brawl's `moveToDistanceFromTarget`) and then `CharacterMoveToPosition`.
- If the member is stuck/in-combat guarded: pre-checks `Osi.CanMove(char)`, `Osi.IsMovementBlocked(char)`.
- Events to react to: `SchemeEvent`… no — `CharacterMoveToAndTalkRequestDialog` (for dialogue auto-walk), movement failure events `CharacterMoveFailedUseJump`, `CharacterMoveToCancelled`.

## 5. Attack (`attack_entity`)

```lua
--- character:CHARACTER, target:GUIDSTRING, alwaysHit:integer
Osi.Attack(character, target, alwaysHit)
```

- The naive atomic attack. It will make `character` perform a basic attack on `target`; `alwaysHit=1` skips the hit roll. Known community caveats: it is a one-shot fire-and-forget; it doesn't respect action points / weapon-swap or integration into the normal action pipeline, so mixed use with `end_turn`/resources can desync the game's action state for player characters. It is fine for **enemies/NPCs**, acceptable for party members, but the modern recommended path for party-member attacks is the same `ServerCastRequest` mechanism as spells (§6) with the weapon's attack spell (e.g. `Target_WeaponRange`-style data) — this is how Brawl drives combos.
- Damage/robustness primitives (cheat/mod side): `Osi.ApplyDamage(object, damage, damageType, source)`, `Osi.SetHitpoints`; never use these for "attack", only for tests/corrections.

## 6. Cast spell (`cast_spell`)

Two viable paths.

### 6a. Recommended: `Ext.System.ServerCastRequest.OsirisCastRequests`

Modern server-side cast queue — touches the **real** spell pipeline (animations, rolls, targeting), and for players with `FromClient` also enforces resources/cooldowns naturally. Production example = Brawl `Actions.lua`:

```lua
local Caster      = Ext.Entity.Get(casterUuid)              -- entity, not guid string
local Targets     = { { Target = Ext.Entity.Get(targetUuid),
                        TargetingType = stats.SpellType,    -- "Object"/"Area"/"Axis"...
                        Position = {x,y,z} } }              -- optional fallback pos
local Spell       = { OriginatorPrototype = originatorPrototype,
                      ProgressionSource  = "uuid-or-null-uuid",
                      Prototype          = spellName,
                      Source             = "uuid-or-null-uuid",
                      SourceType         = "Osiris" }        -- for NPCs; use spellbook values for players
local request     = { CastOptions = { "FromClient", "ShowPrepareAnimation", "NoMovement" },  -- see below
                      Caster      = Caster,
                      RequestGuid = uuid,
                      Spell       = Spell,
                      Targets     = Targets,
                      field_A8    = 1 }
local queue = Ext.System.ServerCastRequest.OsirisCastRequests
queue[#queue + 1] = request                                 -- or insertAtFront for pause/priority
```

- `CastOptions` used by Brawl: `FromClient` (player; game handles resources/cooldowns), `IgnoreHasSpell` (NPCs), `ShowPrepareAnimation`, `NoMovement`, `AvoidDangerousAuras`, `IgnoreSpellRolls`, `IgnoreTargetChecks`, `IgnoreCastChecks`.
- Listening to outcome: story events `CastSpell(caster, spell, spellType, spellElement, storyActionID)`, `CastedSpell(...)`, `CastSpellFailed(...)` (all in the events dump). `Ext.System` / `ServerCastRequest` are not described in the v30 `API.md` — they're system-level (`Ext.System.*`, added later); code above is current in a maintenance-level mod; verify table/field names against your SE console at build time.
- Getting a tactic ready: `Ext.Stats.Get(spellName)` gives `SpellType`, `UseCosts`, `Range`, `Requirements`, etc. — exactly what ticket 03/04's coverage validator needs.

### 6b. Fallback: direct Osiris calls

```lua
Osi.UseSpell(caster, spellID, target, target2, withoutMove)          -- GUID,string,GUID,GUID,integer
Osi.UseSpellAtPosition(caster, spellID, x, y, z, withoutMove)
```

Simple, no animation/setup guarantees, no resource accounting — used by many cheat/utility mods. Acceptable if `ServerCastRequest` proves unstable on your SE build.

### 6c. Cooldowns/resources

`Osi.CharacterResetCooldowns(character)` (the canonical API.md example), `Osi.AddSpell/RemoveSpell`, `Ext.Entity.Get(c).SpellBookCooldowns`, `Osi.GetActionResourceValuePersonal(player, resourceName, resourceLevel)`, `Osi.AddActionPoints(object, amount)`, `Osi.PartyGetActionResourceValue`.

## 7. Dialogue (`select_dialogue_option`, ticket 05)

### 7.1 Detection — ✔ reliable

```lua
-- events (events dump; arities confirmed):
Osi.DialogStartRequested(target, player)      -- before dialog window opens
Osi.DialogStarted(dialog, instanceID)
Osi.DialogEnded(dialog, instanceID)
Osi.DialogActorJoined(dialog, instanceID, actor, speakerIndex)
-- instanceID is an integer; dialog is the DIALOGRESOURCE guid
```

Use `DialogStarted`/`DialogEnded` (server) to flip the dialogue mode in the state generator and to block other commands while talking (`IsDialogueBlocked(char)` query also exists).

### 7.2 Programmatic option select — ✘ NO public Osiris function

- Confirmed missing from `Osi.lua` (983 symbols): no `PickDialogNode`, no `ChangeDialogNode`, no `DialogNodeSetSequence`, no `GetGameDialogActive` (these DOS2-era functions did not carry over). Cross-checked: `grep.app` shows zero Lua matches for BG3 dialog-option hacking symbols.
- What exists is *node plumbing*, not selection: `Osi.PlayMovieForDialog(character, dialogGuidString, nodePrefix)`, `Osi.DialogSetVariable{Int,Float,String,TranslatedString}[ForInstance](...)`, `Osi.DialogFindReservedSpeakerSlot`, `Osi.DialogAddActor`, `Osi.SetHasDialog`, and the big **automated** family (`Osi.StartDialog_Internal(dialog, allowAttack, speakers..., allowSpellVocal)`, `AnubisStartAutomatedDialog` op, `Osi.SetDualEntityEventDialog`, `Osi.SetEntityEventDialog`) which drive linear/canned dialogs, not player choices.
- **Implication for ticket 05/07**: `select_dialogue_option` cannot be implemented with a stable public call today. Two options:
  1. *(recommended for v1)* Semi-interactive: Neuro proposes the option; the human confirms with a keypress (or the option is auto-selected through simulated **client-side input**, see below).
  2. *(experimental)* Client UI scripting: the dialogue window is Noesis UI; a client-context script can find the option elements and invoke their command (the same technique mods use for auto-talking/skipping). The dialog **option order** is the native UI window order — exactly what ticket 05 defines (`option_index` = 1-based UI order) — so the mapping is feasible, but it's brittle across UI patches and is client-side work. Mark as experimental, isolated behind the action layer so it can degrade gracefully.
- Note for consistency (map «Not yet specified»): whichever path is chosen, the option list shown to Neuro must be produced by the same (client) source that renders them, to keep `option_index` == UI order.

## 8. Use item (`use_item`, `interact_with`)

```lua
--- character:CHARACTER, item:ITEM, useItem:integer, isInteraction:integer, event:string
Osi.Use(character, item, useItem, isInteraction, event)
Osi.Equip(character, item, addToMainInventoryOnFail, showNotification, clearOriginalOwner)
Osi.Lock(item, key) / Osi.Unlock(item, character)
Osi.SetCanInteract(item, bool); Osi.GetCanInteract(item)
```

- `useItem=1` = consumable/activatable use; `isInteraction=1` = world interaction (levers, doors, alchemy tables). Equip via `Equip` (and events `Equipped`/`EquipFailed`).
- For "interact with X where X is a scenery/container", combination of `Osi.Use` (interaction) + `Osi.OpenCharacterLootUI(looter, target)` for containers; perception/traps via `IsTrap*`/`SetTrapDiscovered` only as utilities.
- `throw`: **no** public call. Closest internals: `AnubisMoveItem` / `AnubisPickUpItem` operations on `AnubisRuntimeComponent` (needs setup, essentially scripted-cutscene machinery), or client input mapping the Throw action button. Do not schedule `throw` in v1 (mark as unsupported; the executor can fail with a clear "implemented later" code).

## 9. Rest (`rest`)

```lua
Osi.CanAllPartiesLongRest()                          -- query
Osi.RequestLongRest(initiator, isForced)             -- initiator:CHARACTER, isForced:integer
Osi.RequestLongRestConfirmed()
Osi.RequestLongRestFinish(character)
-- short rest is story-side: Osi.SetStoryShortRestDisabled(character, reason) / SetStoryShortRestEnabled(character)
-- events: LongRestStarted, LongRestFinished, LongRestCancelled, LongRestStartFailed,
--         UserCharacterLongRested(character, isFullRest),
--         ShortRestCapable(character, capable), ShortRestProcessing(character), ShortRested(character)
```

- UI flow drives `RequestLongRest`; our server call should mirror the player pressing Long Rest: call `RequestLongRest(controlledCharacter, 0)`; only `RequestLongRestConfirmed()` after the UI/camp validation if `isForced` didn't already confirm. Long-rest requires a valid camp (level has camp waypoint); check `CanAllPartiesLongRest` first and surface a clean error to Neuro if false (ticket 08: actionable error strings).
- Components (ExtIdeHelpers): `EocRestLongRestStateComponent` (`State`, `FinishConfirmed`, `CancelReason`), `EocRestLongRestTimeline` — useful to poll for "rest active".

## 10. Stealth (`toggle_mode` → mode="stealth")

**✘ No public Osiris toggle for Enter/Exit Stealth.** Verified in: `Osi.lua` (983 symbols) — no `SetStealthEnabled`/`EnterStealth`; `grep.app` has zero Lua hits for a stealth-enable call in any BG3 mod.

- What exists: perception/tracking side only — `Osi.SetCanSpotSneakers(character, canSpotSneakers)`, `Osi.CanSpotSneakers(character)`, `Osi.IsInvisible*`, and the `Stealth` / `SightStealthRoll*` components (ExtIdeHelpers).
- Honest recommendation: stealth toggle in v1 is **not automatable** with a stable API. Two pragmatic paths: (a) use `Osi.ApplyStatus(char, "<X>", ...)` with the engine's stealth/hidden statuses — brittle and status names change; (b) leave `toggle_mode` implemented as *client input simulation* or *no-op with mode hint* for the pilot. Mark experimental, out of the reliable matrix.

## 11. Loot (`loot`)

```lua
Osi.Pickup(character, item, event, forcePickUpOnFailure)           -- adds to character inventory
Osi.OpenCharacterLootUI(looter, target)                            -- opens the loot window
Osi.MoveAllLootableItemsTo(fromObject, toObject, equipArmor, equipWeapons, clrOwner, vanityClothing)
Osi.ToInventory(object, targetObject, amount, showNotification, clearOriginalOwner)
Osi.AddGold(inventoryHolder, amount); Osi.TemplateAddTo(itemTemplate, inventoryHolder, count, showNotification)
-- events: AddedTo(object, inventoryHolder, addType), RemovedFrom(object, inventoryHolder)
```

- `Pickup` is the «take item» action for a nearby item that can be picked up (`GetCanPickUp(item)`). For bulk/area looting (e.g., after a fight) `OpenCharacterLootUI` + client-side "take all" is the user-visible flow; server-side autopick matches pick `MoveAllLootableItemsTo`. NOTE (exploration ticket): `loot` on a corpse/container = `OpenCharacterLootUI` + UI; the pure-server variant is `Pickup`/`ToInventory` per item. Verify `Pickup`'s `event` argument (story event) for completion if exact timing matters.

## 12. Turn & combat state (bonus/end_turn, turn detection, state generator)

```lua
-- queries
Osi.IsInCombat(entity)                                 -- 1/0
Osi.CombatGetActiveEntity(combatGuid)                  -- who acts NOW
Osi.CombatGetGuidFor(object)                           -- combatGuid for a participant
Osi.GetActionResourceValuePersonal(player, resourceName, resourceLevel)  -- AP/BA/RA/MA
-- calls
Osi.EndTurn(target)                                    -- end the current actor's turn
Osi.ForceTurnBasedMode(playerCharacter, onOff)         -- enter/leave turn-based
Osi.AddActionPoints(object, amount)
-- events (register via Ext.Osiris.RegisterListener, arities in generator):
--  "TurnStarted"(1)   "TurnEnded"(1)
--  "CombatStarted"(1) "CombatEnded"(1) "CombatRoundStarted"(2) "EnteredCombat"(2) "LeftCombat"(2)
```

Turn-order *content* (state generator "whose turn / order list"): Brawl reads the combat entity's component:

```lua
local c = Utils.getCombatEntity()                  -- Ext.Entity.Get(combatGuid from Osi.CombatGetGuidFor(anyParticipant))
local order = c.TurnOrder                          -- EocCombatTurnOrderComponent
-- order.Groups / order.Groups2 : { {Initiative,IsPlayer,Round,Team,Members={{Entity,Uuid}}}, ... }
-- order.field_40 = current combat round
```

`EocCombatTurnOrderComponent` fields (ExtIdeHelpers): `Groups`, `Groups2`, `Participants`, `Participants2`, `TurnOrderIndices`, `TurnOrderIndices2`, `field_40` (round counter). Combat containment: `EocCombatParticipantComponent` (`CombatHandle`, `InitiativeRoll`), `EocCombatIsInCombatComponent`, `EocCombatStateComponent` (`Participants`, `IsInNarrativeCombat`).

`end_turn` implementation: `Osi.EndTurn(controlledCharacter)` when `CombatGetActiveEntity == controlledCharacter`; guard with `IsInCombat`. Bonus action: for v1 use `FromClient` casts (native resource handling) — no manual AP juggling needed.

## 13. Spell & inventory lists (item 12 — feeds state extractor, ticket 03)

```lua
-- all spells known to the modding runtime
Ext.Stats.GetStats("SpellData")                    -- string[] of stat names (SpellData type)
-- per-character castable/known
local ent = Ext.Entity.Get(controlledGuid)
ent.SpellBook.Spells                -- SpellSpellData[]  (SpellBookComponent)
ent.SpellBookPrepares.PreparedSpells -- SpellMetaId[] (OriginatorPrototype/ProgressionSource/Source/SourceType)
ent.SpellBookCooldowns              -- per-spell cd (SpellSpellBookCooldownsComponent)
-- inventory
local invEntity = Ext.Entity.Get(controlledGuid).Inventory   -- Inventory component (EntityHandle)
Osi.IterateInventory(inventoryHolder, event, completionEvent) -- stream rows
Osi.GetItemByTemplateInInventory(itemTemplate, inventoryHolder)
Osi.GetItemByTagInInventory(tags, inventoryHolder); Osi.GetGold(inventoryHolder)
-- human-readable names: Ext.Loca.GetTranslatedString via Ext.Stats.Get(spell).DisplayName (see API.md Loca section)
```

- Spells with type = `SpellData` via `Ext.Stats.GetStats("SpellData")` gives the **full** list including passives-pulled / item / feat spells; the *actually usable* subset for a character = `SpellBook` (or `SpellBookPrepares` for prepared casters). For the Neuro state model, prefer `SpellBook.Spells` (+ `SpellBookCooldowns`) as the source of truth, enriched by `Ext.Stats.Get(spellName)` for `UseCosts`/`SpellType`/`Requirements`.
- Conversation of a SpellId string vs prototyp:`Stats.Get(spellName)` uses the stat/prototype name; UI ids in `SpellBook.Spells` may refer to *root templates* (prototype). Normalize through `Ext.Stats.Get` by both name and root-template (compare `TemplateId`/`RootTemplate` — see `Stats.Get` and the Loca notes in API.md) to keep `cast_spell` args and state consistent.

## 14. Reliability matrix (for ticket 08 error-resilience)

| Call | Mode | Risk / notes |
|---|---|---|
| `CharacterMoveTo( Position)` | ✔ reliable | verify `movementSpeed` enum at target version; `event` optional for fire-and-forget |
| `TeleportTo( Position)` | ✔ reliable | leaveCombat + snapToGround both available; avoids wrath of the walk |
| `Attack` | ⚠ | one-shot; bypasses AP/cooldown bookkeeping — prefer §6a for party members |
| `ServerCastRequest.OsirisCastRequests` | ⚠→✔ | current-production path; not in v30 docs (newer `Ext.System`); validate schema on SE build |
| `UseSpell(AtPosition)` | ⚠ | works; skips setup/cost logic |
| `Use` / `Equip` | ✔ reliable | `isInteraction` matters for world objects |
| `Pickup` / `ToInventory` / `AddGold` | ✔ reliable | — |
| `OpenCharacterLootUI` | ✔ reliable | UI window opens on player client |
| `RequestLongRest(Confirmed)` | ✔ reliable | gate on `CanAllPartiesLongRest`, camp availability |
| `EndTurn` / `ForceTurnBasedMode` | ⚠ | `EndTurn` while not active = no-op; verify on target build |
| `TurnStarted/Ended`, `CombatRoundStarted`, `CombatGetActiveEntity` | ✔ reliable | the turn-detection backbone |
| dialog `SelectOption` | ✘ | none; client UI experiment only |
| stealth toggle | ✘ | none; `ApplyStatus` status-name dependent |
| `throw` | ✘ | none; defer |
| `Osi.Attack`-based kill path | ⚠ | use only as normalized server action |

Recommended executor flow per command (maps ticket 07 Q1/Q2/Q3/Q5):
1. C# validates schema + target existence + range-ish prechecks (using state data) → writes `action_<id>.json`.
2. Server Lua poll (`Ext.Timer.WaitForRealtime(100–250)`) reads it, dispatches to the handler, immediately writes `result_<id>.json` (`Ext.Json.Stringify`, `Ext.IO.SaveFile`). Result includes: `success` bool, `error_code` (ticket-08 vocabulary: `target_missing`, `not_in_combat`, `no_spell`, `no_camp`, `not_supported`, …), `error_detail` string.
3. Long actions (movement/cast) write an *intermediate* `success:true, running:true` and finalize via an `Ext.Osiris.RegisterListener`-captured completion event (e.g. `CastedSpell`, `CharacterMoveToCancelled`) — never `WaitFor` until done (blocks the single thread).
4. Timeout (ticket Q2): C# side 2–5 s for command ACK; no wait for the game event itself; a missing result file after N polls = `${error}` per ticket 08. Recommended: 5 s ACK timeout, then resend policy per 08.

## 15. Open questions / next actions for ticket 07

1. Confirm `Ext.System.ServerCastRequest.OsirisCastRequests` field names + `CastOptions` values against the target SE version (no official doc; validate via console/`Ext.DumpCallstack` in dev build).
2. Decide dialogue path: "Neuro proposes + human confirms" (safe v1) vs "client UI autoselect" (experimental spike). Recommend the spike as a separate mini-issue since it needs a client-context script and cross-patch maintenance.
3. Decide `toggle_mode` (stealth): accept `unsupported` in v1 or budget a status-based experiment.
4. Movement speeds: freeze `"Run"` for combat / `"Walk"` for exploration and exposed in [config](map.md).
5. Where equipped items + spell ids come from: settle SpellId normalization (§13) before state extractor schema (03) is finalized.
---

## Addendum (2026-09-06): эмпирика live-прогона на SE v32 (Patch 8 + HotFix 9)

Проверено в живой сессии (bootstrap server-контекста, `Ext.Utils.GameVersion()="v4.73.98.727"`).

### Реальные сигнатуры событий (источник: `Story\RawFiles\Goals\*.txt` из `Shared.pak`+`Patch8_HotFix9.pak`)

| Событие | Сигнатура | Подтверждение |
| --- | --- | --- |
| `CharacterMoveToCancelled` | 2 (`_Char,_ID`) | `__PROC.txt` |
| `CastSpell` / `CastedSpell` | 5 (`_Caster,_Spell,_SpellType,_SpellElement,_StoryActionID`) | `__PROC.txt` + live capture `@5` |
| `CastSpellFailed` | 5 (та же сигнатура, что CastedSpell) | `__PROC.txt` |
| `DialogStarted` / `DialogEnded` | 2 (`_Dialog,_Inst`) | `__GLOBAL_Dialogs.txt` + live capture `@2` |
| `DialogStarting` | **не событие** | отсутствует в raws; регистрация молча фейлится |
| `LongRestFinished` / `LongRestCancelled` / `LongRestStartFailed` | **0** | `GLO_Camp.txt` (`LongRestCancelled()`, `LongRestStartFailed()`, `LongRestStarted()`, `LongRestFinished()`) |

### Поведение `Ext.Osiris.RegisterListener` в SE v32

- Сигнатура: `RegisterListener(name, arity, "after"/"before", handler)`. Долгоживущие листенеры из
  bootstrap не требуют id-стрint; лишний 3-й аргумент в старых примерах — не id, а фаза события.
- Регистрация с арностью, отличной от объявления события, **молча не регистрирует**: в логе
  `Couldn't register Osiris subscriber for <Name>/<arity>: Symbol not found in story`.
- `pcall(RegisterListener(...))` при этом возвращает `true` — **ошибку видно только в логе
  `Script Extender Logs\Extender Runtime …log`**; по имени с неверной arity «Symbol not found»
  появляется на любой арности, включая 0.
- Вывод в лог: `_P(...)` работает, `Ext.Print`/`Ext.PrintError` в этом билде = `nil`.

### Песочница: что чего нет

- `os` — `nil` (нет `os.date`/`os.time`); время — `Ext.Timer.ClockTime()` = `"YYYY-MM-DD HH:MM:SS.fffffff"`
  (UTC, пробел, без `Z`) → нормировка `(s):gsub(" ", "T") .. "Z"` даёт ISO-8601, читаемый
  `DateTimeOffset` на C#; есть `Ext.Timer.ClockEpoch()` (секунды).
- `Ext.IO.SaveFile/LoadFile` — относительно `<профиль>\Script Extender\` (подкаталог `BG3Neuro\` —
  файлы `heartbeat.json`, `bg3_to_neuro.json`, `neuro_to_bg3.json`, `result_*.json`).
- `math` есть; `Ext.Json.Stringify/Parse` работают.
