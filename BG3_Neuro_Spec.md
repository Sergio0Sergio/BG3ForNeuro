# BG3 ↔ Neuro SDK Integration — Architecture Specification (v1)

The complete integration specification for Baldur's Gate 3 with the Neuro SDK: modules, interfaces, state formats, action schemas for combat/dialogue/exploration, the IPC protocol, and testing. Ready for hand-off to the implementer.

Date: 2026-09-05 · Source: wayfinder map `.scratch/bg3-neuro-integration/` (tickets 01–09).

---

## 1. Architecture Overview

A two-process architecture: a **C# standalone process** (all Neuro-facing logic, "decide in C#") + a **BG3 Script Extender Lua mod** (dumb — only state extraction and action execution).

```
┌─────────────────────────────────────────────┐
│  Neuro (external WS server, ws://localhost)  │
└──────────────────┬──────────────────────────┘
                   │ WebSocket (Neuro SDK protocol)
┌──────────────────▼──────────────────────────┐
│  C# Standalone Process                      │
│  NeuroWebSocketClient · IpcClient ·         │
│  StateSerializer · ActionRouter ·           │
│  DecisionLoop · CoverageAuto ·              │
│  ConfigLoader · ErrorMapper                 │
└──────────────────┬──────────────────────────┘
                   │ File-based IPC (JSON)
┌──────────────────▼──────────────────────────┐
│  BG3SE Mod (Lua)                            │
│  StateExtractor · ActionExecutor ·          │
│  IpcFileHandler                             │
└──────────────────┬──────────────────────────┘
                   │ Ext/Osi API
              Baldur's Gate 3
```

### 1.1 BG3SE Mod Modules (Lua) — dumb, no decision logic

| Module | Purpose |
|---|---|
| `StateExtractor` | Subscribes to BG3 events, extracts state → JSON → file `bg3_to_neuro.json` |
| `ActionExecutor` | Receives commands from `neuro_to_bg3.json`, calls `Ext/Osi` APIs |
| `IpcFileHandler` | File handling (`Ext.IO.SaveFile/LoadFile`, `Ext.Json`, `Ext.Timer.WaitForRealtime` polling) |

### 1.2 C# Process Modules — all Neuro-interaction logic

| Module | Purpose |
|---|---|
| `NeuroWebSocketClient` | WebSocket to Neuro: reconnect, startup, actions/register, actions/force, action/result |
| `IpcClient` | File IPC: reads (FileSystemWatcher), writes commands (JSON) |
| `StateSerializer` | BG3 state JSON → Markdown context for Neuro (branches by scenario) |
| `ActionRouter` | Validates JSON from Neuro (name→entity_id, schema), routes to ActionExecutor |
| `DecisionLoop` | Orchestration: event → context/force → validate → execute → result; "when to force" rules |
| `CoverageAuto` | Computes range/AoE coverage (single code path with StateSerializer, see §1.3) |
| `ConfigLoader` | `config.json` → structures with defaults |
| `ErrorMapper` | error_code dictionary → actionable message |

### 1.3 Data Flows

**BG3 → Neuro:**
Event in BG3 → `StateExtractor` → JSON → `bg3_to_neuro.json` → `IpcClient` (FileSystemWatcher) → `StateSerializer` (JSON→Markdown) → `NeuroWebSocketClient` (context or state in force)

**Neuro → BG3:**
Neuro decision → `ActionRouter` (validation, alias→id) → `IpcClient` (JSON write) → `neuro_to_bg3.json` → `IpcFileHandler` → `ActionExecutor` → `Ext/Osi` API → result → back via state

**Single coverage code path:** range/AoE calculations are used both in `StateSerializer` (what is shown in state) and `ActionRouter` (what gets validated) — guarantees "state ↔ validator" consistency.

### 1.4 Lifecycle

- **C# startup**: reads `config.json` → starts `IpcClient` (file-based) → `NeuroWebSocketClient.Connect()` → on connect: `startup` + `actions/register`
- **BG3SE startup**: mod creates IPC files, subscribes to events, sends first state (SessionLoaded)
- **WS reconnect**: auto-reconnect (interval ~3s) → on open: re-send `startup` + re-register actions; handle `actions/reregister_all`
- **Game/mod reconnect**: the mod recreates files on startup; C# waits while no fresh state file exists
- **Mod error/panic**: C# logs, waits for the heartbeat file

### 1.5 Key Decisions

- **Decide-in-C#**: BG3SE is dumb. The "when to force/context" logic lives in C# (testable).
- **Entity aliases**: the context carries an id↔name table; Neuro uses short names (`goblin_1`), `ActionRouter` translates to entity_id.
- **`controlledPartySize` (1..4)**: configuration for the number of controlled characters. State shows all; the current actor is determined by initiative. The `actor` parameter in action schemas when >1.
- **Single-agent = one `agent→ownedAlias` map entry**: the whole v1 spec is the single-agent case of the multi-agent model (§12) — exactly one owned character. Everything in §1–§10 stays the authoring contract; §12 only adds what appears when the map has ≥2 entries.
- **Force + state**: every force carries a fresh markdown state (`ephemeral_context: true` — bulky state every turn); rare contexts (silent=true) for rules/tasks.
- **Event-driven**: state updates arrive on game events, not on polling.

### 1.6 Force Policy (DecisionLoop)

The "when to send `actions/force`" rules — the source of truth for the executor. Based on BEST_PRACTICES.md §Forcing Actions and SPECIFICATION.md §Force Actions.

**Triggers (points where the game waits for a Neuro decision):**
- **combat** — the start of a controlled character's turn; combat exit (context reset, new force with exploration state)
- **dialogue** — `DialogStarted` (force with answer options)
- **exploration** — `SessionLoaded`, combat exit, mode change; for open-ended periods — **timeout-then-force** (BEST_PRACTICES recommendation): if activity goes on without a decision, send force on a timeout
- Everything else — via context (rare, silent), not force

**Priority:** **always `low` (default)** — BG3 is turn-based, never interrupts Neuro's speech. `medium`/`high`/`critical` are **not used** in v1 (no hard real-time; turn-based BG3 has no critical moments).

**Replace, not queue:** a new force on top of an active one **cancels and replaces** it (SPEC: "Neuro can only handle one action force at a time"). Safe because every force carries **the full fresh state** — losing context is impossible. No queue is needed; discipline — force only at decision points, not on every event.

**state vs query:** `state` — Markdown state from §3; `query` — a short "what to do now" (e.g. "It's your turn. Choose an action."). `ephemeral_context: true` for bulky state every turn (BEST_PRACTICES §Forcing Actions).

---

## 2. IPC Protocol (BG3SE ↔ C#)

### 2.1 Channel: file-based IPC

Research fact: **there is no native named pipe in BG3SE** (details: `.scratch/bg3-neuro-integration/research/ipc-named-pipes.md`).

- `Ext.IO` only provides `SaveFile`/`LoadFile`; `Ext.Net` only covers in-game connections.
- **LuaSocket is unavailable** (`require("socket.http")` does not work).
- **Primary path — file IPC + JSON**:
  - BG3SE Lua writes JSON via `Ext.IO.SaveFile()`, C# reads/writes files
  - Non-blocking polling via `Ext.Timer.WaitForRealtime()` (not `Ext.OnNextTick`)
  - Serialization: `Ext.Json.Stringify()`/`Ext.Json.Parse()` (matches the Neuro JSON protocol)
- **Upgrade path (Phase 2, optional)**: if file IPC is too slow (~50–100ms) — a C# mod with `System.IO.Pipes` inside BG3SE.

### 2.2 Files

`<BG3ScriptExtender appdata>/BG3Neuro/`:
- `bg3_to_neuro.json` — game state (written by the mod)
- `neuro_to_bg3.json` — action commands (written by C#) — **the only command file the mod polls** (singleton, one in-flight action)
- `action_<id>.json` — C#-side trace/log of the dispatched action (tests, debug — **NOT read by the mod**; bench-verified 2026-09-16)
- `result_<id>.json` — execution result (written by the mod)
- `heartbeat.json` — mod heartbeat (written every **2 s**; stale threshold **10 s**)

---

## 3. State Format

### 3.1 Branching by Scenario

Three generators: `combat`, `dialogue`, `exploration`. Switched by the active mode. One `StateSerializer`, branched output. Less noise for the LLM.

### 3.2 Combat state

Markdown, no `#` top-level, structure via `##`. Meters as the distance unit (the BG3 engine works in meters — the same language as the spell UI). The full combat action set (§5.1). Distances to enemies/targets — in meters.

```markdown
## Turn: Karlach (initiative 3/5)
## Controlled characters
- Karlach: HP 45/60, distance 6m, effects: Rage (3 rounds)...
## Enemies
- goblin_1 (Goblin Raider): HP 12/18, distance 6m, status: —
## Spells (Karlach)
- Fireball: slot 3, radius 18m, AoE 4m → in range: [goblin_1, goblin_2]
- flourish (Target_OpeningAttack): cost bonus_action, range 1.5m → in range: [goblin_1]
## Available actions (Karlach)
- move_to_target: [<move targets>]
- attack_entity: [goblin_1, goblin_2]
- cast_spell: [Fireball, Magic Missile, flourish]
- throw: [health_potion, javelin] → [goblin_1, goblin_2]
- use_item: [health_potion]
- bonus_action: [offhand_attack, help, shove]
- set_reaction: [opportunity_attack, shield]
- end_turn
```

> The "Available actions" block already addresses a specific character (Karlach). The `actor` parameter in the schemas duplicates this binding for the party case (`controlledPartySize > 1`); at `= 1` it is not required.

### 3.3 Distance Hybrid + "in range/covers" (S3)

Both layers together:
- `distance: 6m` per enemy (O(N))
- `→ in range: [list]` per spell (O(N) per spell), computed by the plugin from coordinates + range
- For AoE: `→ covers: [goblin_1, goblin_2] (2 targets)` — the plugin computes the optimal centering
- A spell with no targets in range: `(no targets in range)`
- NOT O(spells × enemies) — avoid noise
- **Single code path** for range/AoE calculation in StateSerializer and ActionRouter

### 3.4 Dialogue state: text + prompt, numbers = UI window

```markdown
## Dialogue with Astarion (relationship: neutral)
He says: "..."
## Answer options
1. "We have to go. This is important."
2. "You're right, let's put this off."
3. "I have a question about Cazador." [Persuasion]
4. [Leave the dialogue]
```

- **Option numbers = order in the BG3 dialogue UI window (1-based)** — the plugin numbers exactly as the game shows (matches the streamer mod).
- `select_dialogue_option` takes `option_index` (primary) + `option_text` (fallback, matched by text).
- Do not show difficulty metadata (DC); do not show reputation numbers.

### 3.5 Exploration state: awareness as a filter

- **Filter = the character's awareness** (game's visibility/perception, not radius, not top-N). Each controlled character has its own set. **Characters in stealth/invisibility are not visible** (no cheating, human-like).
- `maxVisibleObjects: 20` (config) — upper limit flagged as "and N more".
- Entity data — only from what is visible to the player, never from absolute coordinates.

```markdown
## Mode: normal
## Objects (8)
- goblin_camp_sign (readable, 5m)
...
## Available actions
- move_to_entity: [...]
- interact_with: [...]
- open_map
- toggle_mode: [normal]
```

> Perception contract rev 2 (`.scratch/bg3-neuro-perception/spec.md`): emission is **binary** — an entity is either on screen (emitted at its true current position; there is **no `perception` field** — visibility is expressed by the entity's mere presence in `objects`) or absent from the state entirely. Per-character `seen by` grouping and the `seen_by` field are **removed** (single `## Objects (N)` header).

> Note: `toggle_mode` in v1 shows only `[normal]` (see §5.3 X3).

### 3.6 Identity — do not write "You are Neuro" in the header

- Identity is the same BG3; it knows from `startup` + characterId. Do not repeat.
- Startup context (silent=true, once) — game rules, how to read the state, action meaning, style (human-like).
- The header of every force — **only dynamics**: "You control: Karlach [+ party]. Mode: combat. Turn: Karlach."
- No periodic repetition of static information.

---

## 4. Configuration

All runtime settings live in a single `config.json`, read at startup.

```json
{
  "neuro": {
    "ws_url": "ws://localhost:8000",
    "reconnect_interval_s": 3
  },
  "ipc": {
    "dir": "<BG3ScriptExtender appdata>/BG3Neuro",
    "state_file": "bg3_to_neuro.json",
    "command_file": "neuro_to_bg3.json",
    "poll_interval_ms": 100,
    "heartbeat_interval_s": 2,
    "heartbeat_stale_s": 10
  },
  "game": {
    "name": "Baldur's Gate 3",
    "controlledPartySize": 1
  },
  "actions": {
    "result_timeout_s": 20
  },
  "dialogue": {
    "mode": "confirm"
  },
  "state": {
    "combat":     { "showQuestMarker": false },
    "dialogue":   { },
    "exploration": {
      "showQuestMarker": true,
      "maxVisibleObjects": 20,
      "objectInfo": { "visible": true, "skillRequirements": false },
      "distanceFormat": "hybrid",
      "showPosition": false
    }
  }
}
```

`state` fields:
- `showQuestMarker`: exploration true (compass), combat false
- `objectInfo.skillRequirements`: false (no cheating)
- `distanceFormat`: `meters | region | hybrid`; hybrid — close ≤50m in meters, far "area: name"
- `showPosition`: false — absolute position is not needed, geometry in distances

`agents` (multi-agent, §12): one entry per Neuro. **Absent = single-agent v1** (one WS client, no owned character).
```json
"agents": [
  { "characterId": "neuro", "ownedAlias": "Karlach", "ws_url": "ws://localhost:8000" },
  { "characterId": "evil",  "ownedAlias": "Astarion", "ws_url": "ws://localhost:8001" }
]
```
- `ws_url` empty → fall back to top-level `neuro.ws_url`.
- `ownedAlias` empty → the agent may act for any controlled member (v1 behavior even with several agents).

---

## 5. Action Schemas

All actions are registered as `Action` (as in SPECIFICATION.md): `name` (lowercase, underscore), `description` (plain text, 1–2 sentences), `schema` (JSON Schema object). Registration — **PERSISTENT**: all actions at startup, once, no re-reg/dereg (BEST_PRACTICES: "Register everything you can once at startup").

Principles:
- Context gives information, actions give gestures.
- **`actor?: string` parameter** — alias of the controlled character (from state §1.5/§3). Required when `controlledPartySize > 1`, omitted at `party = 1` (the active/turn-taking character acts). Sets the single executor; see the schema in each action.
- **Full fixed set**: all **17 actions** (8 combat + 1 dialogue + 8 exploration) registered **once at startup** and unchanged for the session (no re-reg/dereg, no disposables). Dynamic whole-action registration is **not used** in v1 — a stable set speeds up Neuro responses (BEST_PRACTICES: "Register everything you can once at startup").
- Enum — always full; an unavailable option → failure with an actionable message, no enum resizing.
- **Fixation risk** (BEST_PRACTICES: "she tends to fixate on a few of them") is compensated by the state explicitly showing the actions/targets available this turn, and the validator giving an actionable failure with an options list — Neuro effectively sees the relevant subset through state, not through the action set.

### 5.1 Combat Actions (8)

| # | Action | Parameters | Description |
|---|---|---|---|
| 1 | `move_to_target` | `actor?: string`, `target_id: string` | Move to the specified target |
| 2 | `attack_entity` | `actor?: string`, `target_id: string` | Attack the specified enemy with the main weapon |
| 3 | `cast_spell` | `actor?: string`, `spell_name: string`, `target_id?: string`, `coverage?: string[]`, `position?: {x, y, z}` | Cast a spell |
| 4 | `use_item` | `actor?: string`, `item_id: string`, `target_id?: string` | Use an item from inventory |
| 5 | `throw` | `actor?: string`, `item_id: string`, `target_id: string` | Throw an item at a target (**X2: in v1 → `not_supported`**) |
| 6 | `bonus_action` | `actor?: string`, `action_type: enum` | Perform a bonus action |
| 7 | `set_reaction` | `actor?: string`, `reaction_type: enum` | Set the reaction for this turn |
| 8 | `end_turn` | `actor?: string` | End the turn |

> **Shared `actor`** across all 8 combat actions: `actor?: string` — executor alias (required when `controlledPartySize > 1`, omitted at `= 1`). Validation: the alias must be a controlled character; at `party = 1` the single/active one acts. The validator checks phase/right (whose turn) against `actor`.

Details:
- **`move_to_target`**: schema `{ "type": "object", "required": ["target_id"], "properties": { "target_id": {"type": "string"}, "actor": {"type": "string"} } }`. Neuro sees available targets in state.
- **`attack_entity`**: `target_id` + `actor` (main hand always, no `weapon_slot` — offhand only via `bonus_action`).
- **`cast_spell`** (AoE): `actor` + `spell_name` — from state (source of truth); `coverage` (optional) — desired victim list, the plugin centers the blast on the coverage optimum, failure with a list if not everything is reachable; `position` (optional) — raw center coordinates `{x, y, z}` (BG3SE API 3D), fallback (enabled via config, disabled by default). AoE coverage and range are computed by the plugin — a single code path with StateSerializer. **v0.8.35:** this is also the path for weapon actions / bonus-action abilities (e.g. Flourish). `spell_name` accepts **either** the engine stat id (`Target_OpeningAttack`) **or** the friendly `name` from the state (`flourish`); the plugin resolves the friendly name to the engine id before dispatch. The plugin spends the ability's own resource cost (a bonus-action ability spends BA) natively — `bonus_action` stays `offhand_attack`-only.
- **`use_item`**: `actor` + item + target. Drinking a potion as an action — here (both paths: `use_item` and `bonus_action.drink_potion`).
- **`throw`**: `actor` + `item_id` + `target_id`. Present in the schema, but execution returns `not_supported` — **bench-proven** (see §11 note): the engine rejects synthetic `Throw_Throw` casts in every variant (4 force queues + 2 honest `FromClient`), always `CastSpellFailed(..., storyActionID=0)`, `UsingSpell` never fires. Honest "implemented later" failure, not silence.
- **`bonus_action.action_type`** (full, fixed enum):
  - `offhand_attack` — attack with the second hand (needs an offhand weapon)
  - `drink_potion` — drink a potion (as a second tempo/bonus)
  - `help` — help an ally (break a grapple, grant advantage)
  - `shove` — shove a target
  - `disengage` — avoid opportunity attacks
  - `dash` — extra movement
  - `dodge` — dodge (attacks against you at disadvantage)
- **`set_reaction.reaction_type`** (full, fixed enum):
  - `opportunity_attack` — opportunity attack
  - `shield` — Shield reaction
  - `counterspell` — counterspell
  - `none` — do not use a reaction this turn

> **Phase validation for `bonus_action`/`set_reaction`:** these actions require the controlled character's turn. If it is someone else's turn or there is no combat → `wrong_phase` (Channel A, §6.5) with an actionable message ("It's not your turn — whose/phase"), not `invalid_parameters`.

> Limitation (from BEST_PRACTICES): "she tends to fixate on a few of them". Compensation — the full fixed set (all 17 at startup, B) + the relevant subset in state + actionable failure with the options list.

### 5.2 Dialogue Actions (1)

**`select_dialogue_option`** — the only dialogue action (D1). Leaving/interrupting/skipping are normal options in the state (BG3 provides them in the answer list). No `skip_dialogue`/`end_dialogue`.

```json
{
  "name": "select_dialogue_option",
  "description": "Choose one of the proposed dialogue answer options.",
  "schema": {
    "type": "object",
    "required": ["option_index"],
    "properties": {
      "option_index": { "type": "integer", "minimum": 1 },
      "option_text":   { "type": "string" }
    }
  }
}
```

- `option_index` — **primary**: option number = order in the BG3 dialogue UI window (1-based, matches the streamer mod).
- `option_text` — fallback: if Neuro wrote the text but missed the index, the plugin matches by text and fills the index in.
- Registration **PERSISTENT**: once at startup; no active dialogue → failure "No active dialogue right now"; race protection (dialogue closed → failure, not a missing action).
- **Forced dialogue** (enemy attacks during dialogue): the game interrupts the dialogue automatically; DecisionLoop switches mode (combat > dialogue); `select_dialogue_option` stays registered.
- **Trading — out of scope**: "[Trade]" is a normal option, but it opens the trading screen (a separate UI type, outside scope).

### 5.3 Exploration Actions (8)

| # | Action | Parameters | Description |
|---|---|---|---|
| 1 | `move_to_entity` | `actor?: string`, `target_id: string` | Move to a target |
| 2 | `interact_with` | `actor?: string`, `target_id: string`, `interaction_type?: string` | Interact with an object |
| 3 | `loot` | `actor?: string`, `target_id: string` | Loot a corpse/container |
| 4 | `open_map` | `actor?: string` | Open the map (view) |
| 5 | `open_inventory` | `actor?: string` | Open the inventory (view) |
| 6 | `toggle_mode` | `actor?: string`, `target_id?: string`, `mode: "normal"` | Toggle the mode |
| 7 | `rest` | `actor?: string`, `rest_type: "full" \| "partial"` | Rest |
| 8 | `travel_to` | `actor?: string`, `destination: string`, `region_id?: string` | Travel to a location |

> **Shared `actor`** across all 8 exploration actions: `actor?: string` — executor alias (required when `controlledPartySize > 1`, omitted at `= 1`). Same as combat actions (§5.1).

Details:
- **`interact_with`**: free-form `interaction_type` (not an enum!) from state — matches BEST_PRACTICES (a changing set of interactions → free parameter + runtime validation). Show available interactions in state: `wooden_door (closed, 3m): [open, break, shove]`. Mismatch → failure with an actionable message ("The door has available: open, break, shove"). Omitted → default (first/"open").
- **`loot`**: a separate action (a frequent gesture in BG3, Neuro orders it explicitly).
- **`open_map`/`open_inventory`**: view only. `open_map` → map screen state (locations for `travel_to`); `open_inventory` → inventory state (use via `use_item`). Equipping/dropping/sorting/trading — out of scope.
- **`toggle_mode`** (X3): `target_id?` (default active; required for a party) + `mode`. **In v1 the enum is only `["normal"]`**; `"stealth"` removed (no public Osiris API to toggle stealth; will return after an experiment).
- **`rest`**: `rest_type` enum [full, partial]. Neuro chooses how many supplies to spend.
- **`travel_to`**: `destination` = **region name** (human-readable, primary); `region_id?` — **optional**, region id for unambiguity with ambiguous names (the validator checks: if `region_id` given — match by it, otherwise by name). State shows the mapping: `→ locations (available): [Area Name (id: xxx)]` with distance in the §3.3 hybrid format.
- Transition from exploration to combat — automatic (DecisionLoop), not via actions.
- UI clicks inside map/inventory — not given to Neuro (view-only state).

### 5.4 Full JSON Schemas (registration reference, E5)

Registration format — `Action` from SPECIFICATION.md: `name`, `description`, `schema` (JSON Schema object). All 17 — PERSISTENT, at startup (B). `actor` — optional in schema (runtime validation: required when `controlledPartySize > 1`, see §5.1/§5.3).

**Combat (8):**

```json
[
  { "name": "move_to_target",
    "description": "Move to the specified target.",
    "schema": { "type": "object", "required": ["target_id"],
      "properties": {
        "target_id": { "type": "string" },
        "actor":     { "type": "string" } } } },
  { "name": "attack_entity",
    "description": "Attack the specified enemy with the main weapon.",
    "schema": { "type": "object", "required": ["target_id"],
      "properties": {
        "target_id": { "type": "string" },
        "actor":     { "type": "string" } } } },
  { "name": "cast_spell",
    "description": "Cast a spell; for AoE — provide a target_id, coverage, or a center position.",
    "schema": { "type": "object", "required": ["spell_name"],
      "properties": {
        "spell_name": { "type": "string" },
        "target_id":  { "type": "string" },
        "coverage":   { "type": "array", "items": { "type": "string" } },
        "position":   { "type": "object",
          "required": ["x", "y", "z"],
          "properties": { "x": { "type": "number" }, "y": { "type": "number" }, "z": { "type": "number" } } },
        "actor":      { "type": "string" } } } },
  { "name": "use_item",
    "description": "Use an inventory item (heal, armor, food) on yourself or the specified target.",
    "schema": { "type": "object", "required": ["item_id"],
      "properties": {
        "item_id":   { "type": "string" },
        "target_id": { "type": "string" },
        "actor":     { "type": "string" } } } },
  { "name": "throw",
    "description": "Throw an item at the specified target.",
    "schema": { "type": "object", "required": ["item_id", "target_id"],
      "properties": {
        "item_id":   { "type": "string" },
        "target_id": { "type": "string" },
        "actor":     { "type": "string" } } } },
  { "name": "bonus_action",
    "description": "Perform a bonus action (offhand_attack, drink_potion, help, shove, disengage, dash, dodge).",
    "schema": { "type": "object", "required": ["action_type"],
      "properties": {
        "action_type": { "type": "string", "enum": ["offhand_attack", "drink_potion", "help", "shove", "disengage", "dash", "dodge"] },
        "target_id":   { "type": "string" },
        "actor":       { "type": "string" } } } },
  { "name": "set_reaction",
    "description": "Set the reaction for this turn (opportunity_attack, shield, counterspell, none).",
    "schema": { "type": "object", "required": ["reaction_type"],
      "properties": {
        "reaction_type": { "type": "string", "enum": ["opportunity_attack", "shield", "counterspell", "none"] },
        "actor":         { "type": "string" } } } },
  { "name": "end_turn",
    "description": "End the current character's turn.",
    "schema": { "type": "object", "required": [],
      "properties": { "actor": { "type": "string" } } } }
]
```

**Dialogue (1)** — see §5.2 (full schema there).

**Exploration (8):**

```json
[
  { "name": "move_to_entity",
    "description": "Move to the specified aware target.",
    "schema": { "type": "object", "required": ["target_id"],
      "properties": { "target_id": { "type": "string" }, "actor": { "type": "string" } } } },
  { "name": "interact_with",
    "description": "Interact with an object using one of the available ways (see state).",
    "schema": { "type": "object", "required": ["target_id"],
      "properties": {
        "target_id":        { "type": "string" },
        "interaction_type": { "type": "string" },
        "actor":            { "type": "string" } } } },
  { "name": "loot",
    "description": "Loot the specified corpse or container.",
    "schema": { "type": "object", "required": ["target_id"],
      "properties": { "target_id": { "type": "string" }, "actor": { "type": "string" } } } },
  { "name": "open_map",
    "description": "Open the map (view locations).",
    "schema": { "type": "object", "required": [],
      "properties": { "actor": { "type": "string" } } } },
  { "name": "open_inventory",
    "description": "Open the inventory (view items).",
    "schema": { "type": "object", "required": [],
      "properties": { "actor": { "type": "string" } } } },
  { "name": "toggle_mode",
    "description": "Toggle the character mode (v1: normal).",
    "schema": { "type": "object", "required": ["mode"],
      "properties": {
        "mode":      { "type": "string", "enum": ["normal"] },
        "target_id": { "type": "string" },
        "actor":     { "type": "string" } } } },
  { "name": "rest",
    "description": "Rest (full or partial rest).",
    "schema": { "type": "object", "required": ["rest_type"],
      "properties": { "rest_type": { "type": "string", "enum": ["full", "partial"] }, "actor": { "type": "string" } } } },
  { "name": "travel_to",
    "description": "Travel to a location by area name.",
    "schema": { "type": "object", "required": ["destination"],
      "properties": {
        "destination": { "type": "string" },
        "region_id":   { "type": "string" },
        "actor":       { "type": "string" } } } }
]
```

Note: free-form parameters (`cast_spell.spell_name`, `interact_with.interaction_type`, `travel_to.destination`) are validated **at runtime** against the state (spell list / available interactions / known locations) → failure with a list of valid options (BEST_PRACTICES), not against a hardcoded enum.

---

## 6. Action Execution Layer

### 6.1 Execution Loop

1. C# validates the schema + target existence + prechecks against state (`IsInCombat`, `CanAllPartiesLongRest`, spell existence in `SpellBook`) → writes the single `neuro_to_bg3.json` command file (plus an `action_<id>.json` trace copy).
2. Server Lua poll: `Ext.Timer.WaitForRealtime(100–250ms)` → reads `neuro_to_bg3.json` → dispatches → immediately writes `result_<id>.json` (`Ext.Json.Stringify` + `Ext.IO.SaveFile`): `{success, error_code, error_detail}`.
3. Long actions (movement/cast) → intermediate `success:true, running:true` + final via a `RegisterListener` event (`CastedSpell`, `CharacterMoveToCancelled`) — never block the thread with `WaitFor`.
4. Timeout: **5 s** ACK from C#; missing result file after N polls = error per the dictionary (§6.5). No timer-based waits for game effects in Lua.
5. BG3SE Lua single-threading confirmed → commands are serialized: one in-flight action per context, queues in C# and Lua.

### 6.2 Key BG3SE APIs (research digest)

| Gesture | Primary call | Reliability |
|---|---|---|
| Movement | `Osi.CharacterMoveTo(character, target, speed, event, moveID)` / `Osi.CharacterMoveToPosition(...)` | ✔ |
| Teleport helper | `Osi.TeleportTo` / `Osi.TeleportToPosition` | ✔ |
| Player cast/attack | `Ext.System.ServerCastRequest.OsirisCastRequests` (**FromClient** — pipeline rails, honest AP/cooldowns) | ⚠→✔ |
| Cast fallback | `Osi.UseSpell` / `Osi.UseSpellAtPosition` | ⚠ |
| Attack (NPC/fallback) | `Osi.Attack(character, target, alwaysHit)` — one-shot, no resource accounting | ⚠ |
| Item | `Osi.Use(character, item, useItem, isInteraction, event)`; equip `Osi.Equip` | ✔ |
| Dialogue start | `Osi.CharacterMoveToAndTalk` / `Osi.StartDialog_Internal` | ✔ |
| Dialogue option select | **no public function** → §7 (X1) | ✘ |
| Rest | `Osi.RequestLongRest(initiator, isForced)` (+ `RequestLongRestConfirmed`); gate `Osi.CanAllPartiesLongRest` | ✔ |
| Stealth | **no public function** → §5.3 (X3) | ✘ |
| Loot | `Osi.Pickup`, `Osi.OpenCharacterLootUI`, `Osi.MoveAllLootableItemsTo`, `Osi.ToInventory` | ✔ |
| Turn/combat | Events `TurnStarted/TurnEnded/CombatStarted/CombatEnded/CombatRoundStarted`, `Osi.CombatGetActiveEntity`, `Osi.EndTurn` | ✔ |
| Spell/ability list | `Ext.Entity.Get(char).SpellBookPrepares.PreparedSpells` (full stat id via `OriginatorPrototype`/`Prototype`) + `Ext.Stats.Get(name)` (`UseCosts` → `cost`, `SpellType`/`TargetRadius`/`AreaRadius` → range/AoE) + `Ext.Stats.Get(name).DisplayName` → `Ext.Loca.GetTranslatedString` (friendly `name`, slugged; curated `ABILITY_NAME_FALLBACK` when there is no translation) | ✔ |
| Inventory | `Ext.Entity.Get(char).Inventory` + `Osi.IterateInventory`, `Osi.GetGold` | ✔ |
| Turn order | `Ext.Entity.Get(combatGuid).TurnOrder` (`EocCombatTurnOrderComponent.Groups/Groups2/field_40`=round) | ✔ |

Full catalog with signatures and sources: `.scratch/bg3-neuro-integration/research/bg3se-lua-action-api.md`.

### 6.3 Resource Handling (AP/cooldowns)

- For players — `FromClient` casts (native resource handling), no manual AP juggling.
- Utilities: `Osi.CharacterResetCooldowns(char)`, `Osi.GetActionResourceValuePersonal(char, resourceName, resourceLevel)`, `Ext.Entity.Get(c).SpellBookCooldowns`.

### 6.4 Attacks and Spells — Single Pipeline

Basic player attacks (`attack_entity`) and `cast_spell` run through `Ext.System.ServerCastRequest.OsirisCastRequests` (honest with AP/cooldowns). `Osi.Attack` (one-shot, no resources) — only for enemies/NPC/fallback. `spell_name` — the prototype name (`Ext.Stats.Get`), normalization in StateExtractor (X5).

### 6.4a Honest-vs-legacy hybrid (ticket 03) and `force_legacy`

Stored in the mod's `ScriptExtender/Config.json` (`force_legacy`, `legacy_fail_limit`), read at startup via `Ext.IO.LoadFile("Mods/" .. MOD_NAME .. "/ScriptExtender/Config.json", "data")` + `Ext.Json.Parse` (kept in memory; the fail counter resets on restart). Notes: `Ext.Mod.GetConfig` does not exist, and the engine ignores custom Config.json keys, so the file is read manually; the `"data"` context reads through the game VFS (the mod's pak), and the path must have **no leading slash**.

- **`force_legacy: true`** — every combat action (attack/cast/bonus) takes the legacy path:
  - cast/attack/bonus → `Osi.UseSpell` (Osiris: resolution + rolls + combat log happen in-game); honest AP spending is not guaranteed (the attack tops up `Osi.AddActionPoints(actor, -1)` manually);
  - NPC fallback — `Osi.Attack`.
  - Acts as the kill-switch for the whole action family; the per-action `data.use_osi_spell` flag still overrides on top of it.
- **`legacy_fail_limit` (default 3)** — the hybrid: a failure of the **honest** path (an `enqueue` error in `ServerCastRequest`) increments the counter; after N consecutive failures a **stable legacy mode is enabled until restart** (`legacyStable`). A successful honest path resets the counter. `CastSpellFailed` / `cast_failed` (a valid cast outcome) do **not** count — that is not a machinery failure.
- Implementation: `readModConfig()`, `useLegacyNow()`, `pipelineFailed(where)`, `pipelineSucceeded()` in `BG3Neuro.lua`. Cast/attack branches taken via `useOsiSpell` count as the legacy path.

### 6.4b Resource snapshots (ticket 02) and `bonus_action` (ticket 05)

- Every resource-spending action (`attack_entity`, `cast_spell`, `bonus_action`) writes `writeResourceSnapshot(id, actor, "before"/"after")` — the `SNAPSHOT_RESOURCES` set (`ActionPoint`/`BonusActionPoint`/`ReactionActionPoint`/`Movement`/`WeaponActionPoint`, via `Osi.GetActionResourceValuePersonal(actor, name, 0)`); cooldowns are captured separately under `out.cooldowns` (`SpellBookCooldowns`, unwrapped by `unwrapField`) — spell slots are **not** part of the snapshot. The AP/BA delta is the honest-economy acceptance criterion on the test bench.
- `bonus_action` (v0.8.25): v1 supports only `offhand_attack`. It runs through the same honest `enqueueCastRequest` with `bonusAction=true`, but casts the dedicated weapon stat **`OffhandAttack`** (`Target_OffhandAttack` / `Projectile_OffhandAttack`) — there is no `CastOffhand` option in `SpellCastOptions` in this game version, so off-hand is resolved by the engine through the offhand weapon's own action. The game spends **BonusActionPoint natively** (bench-verified: snapshot BA 1.0→0.0, AP untouched). Verified mechanics:
  - `isPlayer` comes from the `ServerCharacter` component (`InParty`/`IsPlayer`/`PartyFollower`); a "Player" name check is only a fallback — clean UUIDs (e.g. Astarion's `c7c13742-…`) carry no `Player` marker, and a missed player sends a NPC cast (double-prefixed `OriginatorPrototype` + NULL source) that the engine silently swallows.
  - `NoMovement` is **removed** from `CastOptions` for bonus attacks — otherwise the engine refuses to close into range (`CastSpellFailed`/`BlockedRequiredMove` on a distant target).
  - The offhand weapon is mandatory: without it the engine grants no `OffhandAttack` spell and a cast stalls without a finalize event; `executeBonusAction` guards with `Osi.HasSpell` first and returns `action_failed` (`offhand_attack requires a light weapon in the off-hand`).
  - The remaining `action_type` enum values (`drink_potion`, `help`, `shove`, `disengage`, `dash`, `dodge`) return `not_supported` until later versions.

### 6.5 error_code Dictionary (two channels)

**Principle (ticket 08, review D):** `action/result` goes to Neuro **immediately after validation** (R6, §8) — before in-game execution. So **validation** codes (Channel A) physically reach Neuro via `action/result`, while **execution failures** (Channel B) do not: report them **through the next state + context**, not a late `action/result` (the server drops late results, ~20s window).

**Channel A — via `action/result` (Neuro sees it immediately; validation before the game):**

| Code | When |
|---|---|
| `target_missing` | Target does not exist / not found |
| `not_in_combat` | The action requires combat; there is no combat |
| `no_spell` | Spell unavailable (not in SpellBook / on cooldown / no resources) |
| `no_camp` | Cannot rest (no camp / no valid spot) |
| `not_supported` | There is a schema slot but execution comes later (`throw`) |
| `target_not_in_range` / `invalid_parameters` | Parameter validation failed |
| `wrong_phase` | The action requires a controlled character's turn (`bonus_action`, `set_reaction`), but it is someone else's turn / no combat |
| `not_your_character` | Multi-agent (§12): `actor` is a **controlled party member owned by a different agent** (criss-cross). Single-agent never emits it — every controlled character belongs to the one agent. Actionable message names your owned alias ("You are playing Karlach, not Astarion — only act for your own character.") |
| `dialogue_closed` | `select_dialogue_option` without an active dialogue |
| `mod_unavailable` | Mod unavailable **at validation time** (stale heartbeat) — C# answers failure without driving the game |

**Channel B — via the next state + context (Neuro sees it as "game truth"; execution already went into the game):**

| Code | When |
|---|---|
| `action_failed` | Validation passed, but the action did not happen in-game (cast failed, movement blocked) — details in `error_detail` + the next state |
| `mod_unavailable` | Mod crashed **during execution** (stale heartbeat after a successful result was sent) — re-init per R7, the picture via state |

> **`mod_unavailable` timing:** before validation → Channel A (immediate failure in `action/result`), during execution → Channel B (do not push a late `action/result`). Determined by position relative to validation, not by the code. **Do not send a late `action/result` for Channel B codes** — the server drops it; the Neuro picture is restored by the next state/force (§1.6 dialogue/combat triggers).

---

## 7. Dialogue: How `select_dialogue_option` Executes (X1)

There is **no public Osiris function** to select an option (research §7.2). Execution — **client highlight + click** through a single executor (Neuro sees one action and one format `{success, error_code, error_detail}`):

- **`ClientAutoselectExecutor`**: the client-context Lua finds the option element in the dialogue window by `option_index` (= UI order), **highlights it and clicks it itself** — the human presses nothing. (The earlier `confirm` mode was collapsed into this — the difference between "highlight + manual Enter" and "autoselect" is gone.)
- Toggling — the `dialogue.mode` flag in `config.json` (the value `confirm` kept as an alias, behavior unified).
- If the client script is unavailable (no client context / server-only mod) → **fallback to `not_supported` + a warning in the log** — do not send Neuro into a loop without a channel.
```
select_dialogue_option (schema from §5.2)
        │
        ▼
Action Layer: validate option_index → dispatch
        │
        ▼
ClientAutoselectExecutor
      • client Lua finds the element by option_index, highlights it, clicks
      • (no separate key is required from the human)
```

---

## 8. Resilience and Error Handling

- **R1 — Neuro WS reconnect**: after recovery → re-send `startup` + re-register actions. Handle `actions/reregister_all` (PROPOSALS.md): respond by registering the whole persistent (fixed) set.
- **R2 — BG3SE Mod restart**: the mod writes `heartbeat.json` every **2 s**; C# considers the heartbeat stale when older than **> 10 s** → status "mod unavailable", waits for recovery; for an unfinished action → failure `mod_unavailable`; after recovery — re-init (the mod recreates polling). The 10 s threshold favors resilience to engine pauses (level loading, cutscenes) rather than detection speed — in a turn-based game detection latency is harmless. The 5s timeout is an additional signal.
- **R3 — force/self-action race**: always dispatch whatever actions Neuro sends (README: listen regardless of force). C# validation rejects the impossible with an actionable failure. Clarified (review C): force is a context push, replaced without a queue; a new force on top of an active one **cancels and replaces** (SPEC §Force Actions), safe because every force carries the full fresh state.
- **R4 — Disposables**: no disposable actions, everything PERSISTENT. An invalid repeat → a consistent actionable failure ("dialogue already closed").
- **R5 — Force replacement**: forces are replaced idempotently (a new force is a new push, see R3).
- **R6 — 20s timeout**: two-stage — `action/result` success immediately after C# validation (before in-game execution, <20s); the actual outcome (failed cast) is seen by Neuro in the next state. There are no overdue results.
- **R7 — Full game crash**: a game restart = full re-init through the common reconnect path (same as R1): re-send `startup` (if required), reinstall the file mode, reset the decision loop, a fresh force with a new state. The Neuro WS is either already reconnected or we wait.
- **R8 — Invalid data**: invalid JSON / unknown command → log and skip (no reply, to avoid clutter); an unknown/invalid action or wrong parameters → failure with an actionable message + a list of valid options (BEST_PRACTICES).

---

## 9. Testing Architecture

### 9.1 Randy

Randy (Random Dot Range) — a simple WS server emulating Neuro: `ws://localhost:8000`, HTTP POST `localhost:1337` for manual emulation. Randy limitations: it does not send invalid data, only calls forced actions, answers instantly (no 20s timeouts).

- Use it **as is, do not fork**: basic e2e cycle (register → force → action → result) + POST for manual scenarios.
- "Bad" cases — unit/integration tests, not Randy.

### 9.2 Unit Tests

Minimal module set:
- **StateSerializer** — mocked BG3 data → format check
- **ActionRouter** — JSON schema validation, dispatch by name
- **IpcClient** — writing/reading action_/result_ (with fake files)
- **ConfigLoader** — config.json → structures with defaults
- **ErrorMapper** — error_code → actionable message
- **CoverageAuto** — "range/AoE coverage" automaton — a **separate pure module** with its own unit tests (single code path with StateSerializer; this is the main logic chunk)

The Lua part (BG3SE mod) against mocked `Ext.*` — light smoke on the bench, **not in CI**.

### 9.3 Integration Tests

- **A in CI**: C# pipeline without the game — mocked BG3SE files (action_/result_) + a fake WS.
- **B in CI**: C# ↔ Randy (real WS `ws://localhost:8000`) + mocked BG3SE files.
- **C (manual regression)**: real Neuro — before release, not in CI.

### 9.4 Smoke Test

- Auto in CI: fake BG3SE (mock files) — the scenario "sees the battlefield → attack_entity → result".
- **A mandatory manual test on a real game** (a test scene with 1 enemy) before release — the main trust anchor.

### 9.5 Scenario Set

- Automated tests on **simulated state** cover the logic (formatter/validator/coverage/router) as much as possible.
- All scenarios — in a **manual regression checklist** on a real game:
  - Combat: 1v1, 1v-many, AoE, healing
  - Dialogue: simple choice, quest
  - Exploration: movement, interaction
- Trading — out of scope, excluded from the checklist.

---

## 10. Out of Scope (v1)

- Voice chat (Voice Chat API)
- Multiplayer — supporting other players in the session. Multi-agent (2+ Neuro, §12) is also **post-v1 — not part of this spec's contract**; the reference model is defined below so the v1 single-agent contract is explicitly a special case of it.
- Real-time camera control — Neuro does not control the camera directly
- Performance optimization
- Packaging and deployment
- Trading (buy/sell) — a separate UI screen outside dialogue options
- `throw` (item throwing) — `not_supported` (bench-proven 2026-09-23, ticket 28: engine rejects the synthetic cast in all queues — forced `osiris/network/item/anubis` and honest `FromClient` `item/network` — with `CastSpellFailed(..., storyActionID=0)`; a live manual throw shows the engine itself picking the item into the caster's hand first, a stage the synthetic request lacks).
- Stealth mode `"stealth"` for `toggle_mode` — no public API

**Post-v1 experiments** (not part of the current spec): stealth-status experiment (for `"stealth"` in `toggle_mode`).

---

## 11. Sources

- Wayfinder map: `.scratch/bg3-neuro-integration/map.md`
- Tickets: `.scratch/bg3-neuro-integration/issues/01..09`
- IPC research: `.scratch/bg3-neuro-integration/research/ipc-named-pipes.md`
- `throw` bench verdict 2026-09-23 (6/6 rejections, all queues/flags): `.scratch/bg3-neuro-followups/issues/28-throw-hide-combat-actions.md`
- BG3SE API research: `.scratch/bg3-neuro-integration/research/bg3se-lua-action-api.md`
- Neuro SDK: `neuro-sdk/neuro-sdk/API/SPECIFICATION.md`, `API/BEST_PRACTICES.md`, `API/README.md`, `API/PROPOSALS.md`
- Randy: `neuro-sdk/neuro-sdk/Randy/README.md`

---

## 12. Multi-Agent Reference Model (post-v1)

Research-backed (`.scratch/bg3-neuro-multi-agent/`, tickets 01–03, resolved 2026-09-23). **Not a v1 contract** — the definition that turns every v1 rule into a special case (`|agent→ownedAlias map| = 1`). Presenting it in the spec so single-agent semantics (§1–§10) remain the game truth for one agent, while a second Neuro changes only framing, not the engine loop.

### 12.1 Process & communication

- **One host process holds all Neuro characters** (ticket 01). The server-Lua sees and manages every party member; "human vs Neuro" is not a host distinction — it is our config (which `characterId` owns which alias).
- **One WS connection per agent, no multiplexing** (ticket 02): each agent = its own `NeuroWebSocketClient` + `DecisionLoop`. Agent identity is the owning client instance; SDK `characterId` (`neuro`/`evil`) is assigned by the server per connection — no in-band agent field is added to `action`.
- **File bridge stays single-slot** (ticket 02): one `neuro_to_bg3.json`, one in-flight action globally. The C# writer serializes command-file writes (queue/lock); `result_<id>.json` is already per-`id`, so concurrent agents never collide. The mod does not change for delivery.
- **`actions/force` is per-agent**: each agent's `DecisionLoop` keeps its own `_lastForcedContent` and its own `SendForceAsync` — one forced action per channel, per SDK force policy. Two agents force independently; replacement is per-agent.

### 12.2 State ownership — fixed owned character, projected frames

- **Ownership is fixed, not turn-floating** (ticket 03). Config carries `agent → ownedAlias` (e.g. agent-`neuro` → `Karlach`, agent-`evil` → `Astarion`). An agent acts for its owned alias only; it does not ride the shared-turn window as "whoever's turn it is".
- **Per-agent frame is a C# projection over the one shared state** (ticket 03), not additional Lua emission:
  - The mod emits **one** `bg3_to_neuro.json` (v1 §2.2) with `position_x/y/z` per entity (present since v0.8.58) and `distance_reference` saying whose frame it is (`BG3Neuro.lua:2585`, `:3397`).
  - Each agent's `StateSerializer.ToMarkdown(state, ownedAlias)` recomputes `distance` lines from `position_*` **against its owned character**, so "nearest" is honest per agent (AGENTS.md:24 — never reuse a distance measured for another actor).
  - The `Turn:` header (§3.2) becomes `Turn: Karlach (initiative 3/5)` when the agent owns the current actor, else `Turn: (your character: Astarion) Karlach (initiative 3/5)` — every agent knows whose window it is and who acts. Single-agent output is byte-identical to §3.2.
- **Spells stay turn-actor-scoped** (§3.2 `## Spells (turn actor)`), and co-actor honesty is already in the mod: action validation gates per-caster via `canAct`/spellbook (`BG3Neuro.lua:4611-4620`; router skips spell checks for co-actors, v0.8.56). A non-turn-owner's own book is produced when its `actor` is the current `turn_actor`; otherwise the Mod's per-caster gate answers honestly. No per-agent spell buckets are needed in v1.1.
- **Exploration** (§3.5): the mod still frames free-roam from the first party avatar (`BG3Neuro.lua:3341-3361`, `:3397`); the C# projection re-frames `objects`/`allies` distances against each owned `position_*`. Same single file.

### 12.3 Routing and ownership validation

- **Mapping lives in C#, not the mod** (ticket 03). `ActionRouter` gains an `agent → ownedAlias` table (or the router becomes per-agent). The mod stays a dumb executor — it never learns about agents; `actor` remains party-scoped (v1 §5.1).
- **Allowed set narrows**: validation in `ValidateAndDispatch` (`ActionRouter.cs:28`, `:199-208`, `:337-363`) first requires `actor == ownedAlias` of the calling agent, then the existing turn/`canAct` phase checks. With one agent the narrowing is empty — v1 behavior unchanged.
- **Criss-cross** (`actor` = another agent's owned member) → validation error `not_your_character` (Channel A, §6.5): "You are playing Karlach, not Astarion — only act for your own character."

### 12.4 Changes vs v1

C# only (`src/BG3Neuro.Core`):
- `agent → ownedAlias` map in configuration (§4) and `ActionRouter`.
- `StateSerializer.ToMarkdown(state, ownedAlias?)` + exploration framing (§3.2/§3.5) projected from `position_*`.
- `ErrorCode.NotYourCharacter` (`ErrorCode.cs`, `ErrorMapper.cs` Channel A, §6.5).
- `Program.cs`: N agents → N `(NeuroWebSocketClient, DecisionLoop)` pairs; serialized command-file writes.

The mod (`BG3Neuro.lua`) and the IPC file set (§2.2) — **unchanged** in v1.1 post-v1 work; any Lua change would re-verify the 200-local budget and `luaparse` (AGENTS.md). Sources for this section: `.scratch/bg3-neuro-multi-agent/issues/01-bg3-multiplayer-model.md`, `02-communication-delivery.md`, `03-state-ownership.md`.

**Implemented** (2026-09-23, post-research): `AppConfig.Agents` + `AgentConfig` (§4); `ErrorCode.NotYourCharacter` (Channel A); `ActionRouter.ValidateAndDispatch(..., ownedAlias?)` ownership validation + actor defaulting (criss-cross → `not_your_character`, §12.3); `StateSerializer.ToMarkdown(state, exploration?, ownedAlias?)` Turn-marker + per-agent `distance` projection over `position_*` (§12.2, byte-identical to v1 when owned == turn actor / single-agent); `DecisionLoop(..., ownedAlias?)` owned-aware force gate; `IpcPaths.WriteCommandFile` serialized via static lock (§12.1); `Program.cs` N agent pairs (empty `agents` = v1).