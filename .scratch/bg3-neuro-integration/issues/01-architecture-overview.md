# 01 — Architecture Overview

Type: grilling
Status: resolved
Blocked by: —
Depended by: 02, 03, 04, 05, 06, 07, 08, 09

## Answer

Architecture is defined. (Resolved in live dialogue.)

### 1. Modules

**BG3SE Mod (Lua)** — dumb, no decision logic:
- `StateExtractor` — subscribes to BG3 events, extracts state → JSON → file `bg3_to_neuro.json`
- `ActionExecutor` — receives commands from file `neuro_to_bg3.json`, calls `Ext/Osi` API
- `IpcFileHandler` — works with files (`Ext.IO.SaveFile/LoadFile`, `Ext.Json`, polling `Ext.Timer.WaitForRealtime`)

**C# Standalone Process** — all Neuro-interaction logic (decision in C#):
- `NeuroWebSocketClient` — WebSocket to Neuro: reconnect, startup, actions/register, actions/force, action/result
- `IpcClient` — file-based IPC: FileSystemWatcher for reads, writes commands (JSON)
- `StateSerializer` — BG3 state JSON → Markdown context for Neuro
- `ActionRouter` — validates JSON from Neuro (name→entity_id, schema), regular failure → routing to ActionExecutor
- `DecisionLoop` — orchestration: event → context/force → validation → execute → result; owns the "when to force" rules

### 2. Data flows

**BG3 → Neuro:**
Event in BG3 → `StateExtractor` → JSON → `bg3_to_neuro.json` → `IpcClient` (FileSystemWatcher) → `StateSerializer` (JSON→Markdown) → `NeuroWebSocketClient` (context or state in force)

**Neuro → BG3:**
Neuro decision → `ActionRouter` (validation, alias→id) → `IpcClient` (writes JSON) → `neuro_to_bg3.json` → `IpcFileHandler` → `ActionExecutor` → `Ext/Osi` API → result → back through the state

### 3. Lifecycle

- **C# startup**: reads `config.json` → starts `IpcClient` (file-based) → `NeuroWebSocketClient.Connect()` → on connect: `startup` + `actions/register`
- **BG3SE startup**: the mod creates IPC files, subscribes to events, sends the first state (SessionLoaded)
- **WS reconnect**: `NeuroWebSocketClient` auto-reconnect (interval ~3s) → after open: re-send `startup` + re-register actions (BEST_PRACTICES)
- **Game/mod reconnect**: the mod recreates the files on startup; C# waits if there is no new state file
- **Mod error/panic**: C# logs, waits for the heartbeat file

### 4. Configuration (`config.json`)

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
  }
}
```

### Key specific decisions

- **Decision-in-C#**: BG3SE is dumb. All "when to send force/context" logic lives in C# (testable).
- **Entity aliases**: the context contains an id↔name table; Neuro works with short names (`goblin_1`), `ActionRouter` translates them to entity_id.
- **`controlledPartySize` (1..4)**: setting for the number of controlled characters. State shows everyone; the current turn-taker is determined by initiative. Parameter `actor` in action schemas when >1.
- **Force + state**: each force carries fresh markdown state (`ephemeral_context: true` per BEST_PRACTICES for bulky state each turn); rare context — for rules/tasks (silent=true), rarely.

### 1.6 Force policy (DecisionLoop) — refined in ticket 01 (review C)

Triggers: **combat** — start of a controlled character's turn, leaving combat; **dialogue** — DialogStarted; **exploration** — SessionLoaded/leaving combat/mode change + timeout-then-force for open periods (BEST_PRACTICES). **Priority: always `low`** (BG3 is turn-based; medium/high/critical are not used in v1 — no hard realtime). **Replacement, not queue**: a new force over an active one cancels and replaces it (SPEC §Force Actions), safe because each force carries complete fresh state. The discipline "force only at decision points where the game waits for Neuro" is preserved.

### Note

Q5-IPC is corrected by a research fact: not named pipe, but file-based IPC. The `NamedPipe` module in the question is outdated; current: `IpcFileHandler` + `IpcClient`.