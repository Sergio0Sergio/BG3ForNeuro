# Research: Combat-state ally/enemy classification (issue 08)

Date: 2026-09-18
Feeds: issues/08-enemies-faction-misclassification.md · complements: research/bg3se-lua-action-api.md

Research-only. No project code changed. Primary sources cross-checked: BG3SE source + docs, current (patch 7/8-era, SE v30+) Osiris symbol dump, maintained combat mods (Brawl), BG3-Community-Library.

## 0. TL;DR (what to build with)

| Question | Answer | Build with | Confidence |
|---|---|---|---|
| Q1. What does `TurnBased.CombatTeam` encode? | A per-**combat side/team** GUID (team-keyed turn order), **not** a faction, **not** a combat GUID, **not** a hostility signal | nothing — stop using it for ally/enemy | high (structure) / medium (exact team rule) |
| Q2. Correct hostility API | `Osi.IsAlly(partyRef, participant)` / `Osi.IsEnemy(partyRef, participant)` (engine hostility eval, reflects temp hostility) | ~the fix's core signal | high |
| Q3. Skip object/door participants | presence of `ServerCharacter` component (or `Osi.IsCharacter`) | skip non-characters before classification | high |

---

## 1. Sources

1. **[BG3SE source `GameDefinitions/Components/Combat.h`](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/GameDefinitions/Components/Combat.h)** — ECS combat structures. Retrieved `main` @ 2026-09-18.
2. **[BG3SE `GameDefinitions/Character.h`](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/GameDefinitions/Character.h)** (line 62: `DEFINE_COMPONENT(ServerCharacter, "esv::Character")`), **[Item.h](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/GameDefinitions/Item.h)** (line 10: `DEFINE_COMPONENT(ServerItem, "esv::Item")`), **[Components.h](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/GameDefinitions/Components/Components.h)** (line 143: `DEFINE_TAG_COMPONENT(eoc::character, CharacterComponent, IsCharacter)`).
3. **[BG3SE `IdeHelpers/ExtIdeHelpers.lua`](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua)** — autocomplete dump with every ECS component field (lines cited below).
4. **Osiris symbol dump** `LaughingLeader/BG3ModdingTools/generated/Osi.lua`, commit `ab343b6` (2025-09-27, patch 7/8 era) — authoritative maintained Osiris reference (project wiki is dead). Every signature below was grepped in this file; line numbers cited.
5. **[BG3SE `Docs/API.md`](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md)** §Calling Osiris from Lua — 0-OUT queries return `boolean`, k-OUTs return k values.
6. **tinybike/Brawl** (maintained combat mod): `Server/Utils.lua`, `Server/State.lua`, `Server/TurnOrder.lua`, `Server/Memo.lua` — battle-tested use of `Osi.IsEnemy`/`Osi.IsAlly` and `tb.CombatTeam`.
7. **BG3-Community-Library** `Utils/EntityUtils.lua` — canonical party-list helper via `Osi.DB_Players:Get(nil)`.

Retrieved copies on disk: `C:\Users\2serg\AppData\Local\Temp\opencode\research_bg3\` (Osi.lua, ExtIdeHelpers.lua, API.md, Combat.h, Character.h, Item.h, Components.h, brawl_*, clib_EntityUtils.lua).

---

## 2. Q1 — What does `CombatTeam` really encode?

**Answer: a per-combat side/team GUID (the turn-order team), not a faction and not the combat GUID.** Not a reliable ally/hostile signal, and it is exactly why the live bug happened.

### 2.1 Structure (Combat.h, `main`)

- `struct TurnBasedComponent : BaseProxyComponent` — registered component name **`TurnBased`**; carries (line 68):
  ```cpp
  [[bg3::legacy(Combat)]] Guid CombatTeam;   // legacy name on the "Combat" member is a red herring
  ```
  ExtIdeHelpers.lua:12298-12299 spells it out: `EocCombatTurnBasedComponent` has **two distinct Guid fields** — `Combat` (the parent combat entity) and `CombatTeam` (the side/team). `CombatTeam` is therefore NOT the combat GUID (that would be `Combat` / `EocCombatStateComponent.MyGuid`, ExtIdeHelpers.lua:12278).
- The turn system is **team-keyed**, not per-entity:
  - `TurnBasedGroup` (ExtIdeHelpers.lua:12321-12331): `Handles`, `Members`, `Initiative`, `Round`, `Participant Guid`, **`Team Guid`**, **`IsPlayer bool`**.
  - `TurnBasedComponent` also has `IsPlayer`? No — see below; group carries `IsPlayer` (Combat.h line 91).
  - `EndTurnRequest`, `TurnStartedInfo`, `TurnEndedInfo` all carry `Guid Team` (Combat.h lines 79, 88).
  - `TurnOrderComponent` holds per-combat **arrays of groups** (`Groups`, `Groups2`, `Participants`..., ExtIdeHelpers.lua:12333-12339).
- Combat membership/granularity lives alongside it: `EocCombatStateComponent { MyGuid, Level, Participants[], Initiatives, IsInNarrativeCombat }` (ExtIdeHelpers.lua:12274-12285) and `EocCombatParticipantComponent` has `CombatGroupId`, `CombatHandle` (ExtIdeHelpers.lua:12256-12271); `esv::combat::CombatGroupMappingComponent` maps `FixedString combat group → set of entity handles` (Combat.h:128-134).

### 2.2 Why it breaks ally/enemy classification

- **Same combat, different sides → different team GUIDs.** At the live repro (2026-09-17, grove-gate fight) the grove defenders `wyll_1/zevlor_1/remira_1/aradin_1/barth_1` ended up on a different team than the party: `team == alliesTeam` was false, so they were misclassified as `enemies` (`BG3Neuro.lua:1673`).
- **Objects can carry `TurnBased` too.** `overgrown_portcullis_1` has a `TurnBased` component (a door participates in the turn system) but is not a character — it also emitted under `enemies`.
- Team formation in the engine is derived from the hostility/faction graph at combat start (divinity-engine lineage: one "team" per side that shares turn-order grouping). Two **allied** factions can land on different teams (see §2.3), so `CombatTeam ==` is neither a faction check nor a hostility check.
- Brawl — the closest maintained analog — reads `tb.CombatTeam` only as **part of its turn/api plumbing**, never as an ally/enemy test (see §3.3).

**Bottom line for condition (a): discard `CombatTeam` from the classifier.** It is a within-combat grouping key (e.g. "same turn group / same side of the initiative order"), not who-can-hit-whom.

### 2.3 (medium) — exact team rule unverified

Precisely how the engine buckets entities into teams at combat start (which factions/relations merge into one team) is not documented in any primary text. Structure + live repro + DOS2-engine behavior make "hostility-related, faction-derived, per-side grouping" near-certain, but treat the exact rule as observed behavior, not spec.

---

## 3. Q2 — Correct hostility/relation API

**Answer: use the engine's own hostility evaluator via Osiris: `IsAlly(partyRef, participant)` / `IsEnemy(partyRef, participant)`.** Both exist in the current dump and are exercised daily by maintained mods. No ECS-component shortcut is readable enough to be a substitute (opaque field tables).

### 3.1 Verified in current Osi.lua (`LaughingLeader/BG3ModdingTools`, commit ab343b6)

| Call | Line | Signature (from the dump) |
|---|---|---|
| `IsAlly` | 1492 | `---@param character CHARACTER ---@param otherCharacter CHARACTER ---@return integer bool` |
| `IsEnemy` | 1556 | `---@param character CHARACTER ---@param otherCharacter CHARACTER ---@return integer bool` |
| `GetFaction` | 909 | `---@param target GUIDSTRING ---@return FACTION faction` |
| `GetBaseFaction` | 781 | `---@param target GUIDSTRING ---@return FACTION faction` |
| `GetRelation` | 1119 | `---@param sourceFaction FACTION ---@param targetFaction FACTION ---@return integer relation` |
| `GetRelationRaw` | 1124 | `---@param sourceFaction FACTION ---@param targetFaction FACTION ---@return integer relation` |
| `GetIndividualRelation` | 984 | `---@param entity GUIDSTRING ---@param faction FACTION ---@return integer relation` |
| `GetAttitudeTowardsPlayer` | 773 | `---@param character CHARACTER ---@param player CHARACTER ---@return integer attitude` |
| `GetHostCharacter` | 974 | `---@return CHARACTER hostCharacter` |
| `IsPartyMember` | 1756 | `---@param character CHARACTER ---@param includeNotControlable boolean` |
| `IsPlayer` | 1764 | `---@param character CHARACTER ---@return integer bool` |
| `IsInPartyWith` | 1669 | `---@param character CHARACTER ---@param target CHARACTER` |
| `IsControlled` | 1528 | `---@param character CHARACTER` |
| `IsCharacter` | 1504 | `---@param object GUIDSTRING ---@return integer bool` |
| `IsItem` | 1694 | `---@param object GUIDSTRING ---@return integer bool` |

NOT present in the dump: `IsHostile`, generic `GetAttitude`.

### 3.2 Which one, and how

- `IsEnemy(a, b)` / `IsAlly(a, b)` evaluate the **engine hostility graph** (faction relations *and* temporary/individual hostilities) between two characters at call time — i.e. exactly "can this side currently fight that side", and it tracks mid-combat changes (`SetHostileAndEnterCombat`, `Osi.lua:4127`; Brawl uses it to force enemies). No per-faction `GetRelation` bookkeeping or `Factions.lsx` parsing is needed, and it's immune to the team problem.
- Direction: `IsEnemy(partyAvatar, participant)`. `IsAlly(partyAvatar, participant)` is the logical complement for non-`enemy` members (covers "ally 1 == 1" and non-combatant neutrals), which is exactly the three-way split the classifier wants.
- Reference character: any real party avatar in combat is fine. Prefer the currently-acting character (`actingClean`, a **full GUID** — Osiris won't resolve raw `astarion_1` ids). Robust fallbacks: first `avatar` from the ovatars/party list present in `Participants`, or `Osi.CombatGetInvolvedPartyMember(combatGuid, 1)` (Osi.lua:342; get combat guid with `Osi.CombatGetGuidFor(participant)`, line 337). The mod already has these pieces (`endTurnEntityId` resolution).

### 3.3 Real-mod usage (evidence of the "== 1" pattern)

- Brawl `Server/Utils.lua`: `isPugnacious` → `Osi.IsEnemy(M.Osi.GetHostCharacter(), uuid) == 1` (line 187); `isPlayerOrAlly` → `Osi.IsPlayer(...) == 1 or Osi.IsAlly(M.Osi.GetHostCharacter(), entityUuid) == 1` (lines 176-178).
- Brawl `Server/State.lua`: `Osi.IsEnemy(...) == 1` (~line 230), same for `Osi.IsPlayer`.
- Brawl `Server/TurnOrder.lua`: reads `tb = GetComponent(turn, 'TurnBased')` → `tb.CombatTeam` for its own bookkeeping (so the exact same ECS read the mod uses today is what they use — for ordering, **not** hostility).
- Brawl `Server/Memo.lua`: its memoization list covers exactly `Osi.IsEnemy`, `Osi.IsAlly`, `Osi.IsPlayer`, `Osi.IsCharacter`, `Osi.GetHostCharacter`, `Osi.GetCombatGroupID`.
- Community Library `Utils/EntityUtils.lua:15-22`: party UUIDs via `Osi.DB_Players:Get(nil)` — the canonical party fact; `beingIsPlayer` reads `Osi.GetHostCharacter`/`IsPlayer`.

**Return-type caveat:** the dump annotates a single `integer bool` OUT, so the Lua bridge most likely returns `1/0`; the SE docs convention would return plain `true` only for 0-OUT queries. Both patterns exist in the wild. Use a truthy check (`res == 1 or res == true`) so either bridge behavior classifies correctly.

---

## 4. Q3 — Character vs object (doors)

**Answer: component presence — `ServerCharacter` (registry name `esv::Character`) on the entity, or Osiris `IsCharacter(g)`.** That is what `insertAtFront` already relies on for the acting character (`detectIsPlayer`); reuse it.

- `Character.h:62` → `DEFINE_COMPONENT(ServerCharacter, "esv::Character")`; `Item.h:10` → `DEFINE_COMPONENT(ServerItem, "esv::Item")`; `Components.h:143` → `DEFINE_TAG_COMPONENT(eoc::character, CharacterComponent, IsCharacter)`. So `Ext.Entity.Get(g):GetComponent("ServerCharacter")` → non-nil iff creature/character; doors/portcullises are items → `ServerItem` + door tags, **no** `ServerCharacter`.
- `Osi.IsCharacter(object)` (Osi.lua:1504) is the Osiris equivalent; `Osi.IsItem` (1694) is its complement.
- **Not safe:** `Health`, `Stats`, `Data` — destructible objects and doors carry stats/health components too, so they cannot discriminate.
- Confirmed in the same dump: `Osi.GetCombatGroupID(target)` (834) returns the combat-group FixedString — usable for a *combat-group* axis later, not needed for hostility.

---

## 5. Recommended predicate (Lua pseudocode)

```lua
-- Predicate 1: creature, not object/door
local function isCharacterEntity(g)
    local ok, ent = pcall(Ext.Entity.Get, g)
    if not ok or ent == nil then return false end
    local okC, comp = pcall(function() return ent:GetComponent(M.SERVER_CHARACTER) end) -- "ServerCharacter"
    return okC and comp ~= nil
end

-- Predicate 2: ally / enemy vs party
-- partyRef = currently-acting character guid (full GUID; fallback: first party avatar in Participants)
local function isHostileToParty(partyRef, g)
    local r = Osi.IsEnemy(partyRef, g)
    return r == 1 or r == true          -- truthy, immune to 1/0 vs true/false bridge
end

-- classification loop (replaces bg3neuro.lua:1673 `team == alliesTeam` branch)
-- for each participant guid g:
if not isCharacterEntity(g) then
    -- SKIP (door/object) — do not emit into allies OR enemies; optionally collect into `objects`
elseif isControlled[g] or avatars[g] or partyFlag[g] then
    -- party member
elseif isHostileToParty(partyRef, g) then
    -- enemy
else
    -- ally / neutral (not hostile): IsAlly()==1 or IsEnemy()==0
end
```

Notes:
- Keep the party-member fast path first (cheap table lookups, no Osiris round-trip).
- Skip is cheap (`IsCharacter`/`ServerCharacter` before any `IsEnemy` call), and removes the portcullis symptom automatically.
- If the emitter wants visibility, emit skipped objects under a new `objects` array instead of dropping.

---

## 6. Confidence summary

- **Q1** `CombatTeam` = per-combat team GUID: **high** (structure + IDE dump + legacy rename + repro). Exact team-bucketing rule: **medium** (observed/inferred, not documented).
- **Q2** `Osi.IsAlly`/`Osi.IsEnemy` exist and are the right tool: **high**. Internal hostility threshold/rule of `IsEnemy`: **medium** (black-box; consistent with DOS2 lineage and Brawl's use).
- **Q3** `ServerCharacter`/`IsCharacter` discriminates creatures from objects: **high** (header-level definitions + Brawl uses `IsCharacter` in the same batch).
- `== 1` vs `true` return shape: probably `1/0`, **runtime-verify** once (truthy check makes it a non-issue).

## 7. Unverified (don't guess; bench at the next live run)

1. Exact equality of `TurnBased.CombatTeam` with `TurnOrder.Groups[].Team` (structurally certain, not runtime-probed).
2. Actual Lua return values (`1/0` vs `true`) of `Osi.IsEnemy`/`Osi.IsAlly` for the installed SE version.
3. Component list on `overgrown_portcullis_1` (expect `ServerItem` + `IsDoor`-family tags, no `ServerCharacter`) — confirm via the existing `stats_probe`/`GetAllComponentNames()` diagnostics before/after the fix.
4. Whether `Osi.IsEnemy` reflects mid-combat `SetHostileAndEnterCombat` switches for this patch (Brawl depends on it; sanity-bench).
5. Team GUIDs of each of `wyll_1/zevlor_1/remira_1/aradin_1/barth_1` vs party at fight start (would confirm Q1 outright; not collected in the 2026-09-17 trace).
6. Whether any game-bundled `DB_*` hostility fact exists (`DB_Players` is the only relation-ish fact confirmed in use; no hostility DB verified).