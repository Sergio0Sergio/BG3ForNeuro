# Developer Guide

Architecture, IPC protocol, and how to extend BG3Neuro.

## Architecture

BG3Neuro uses a **two-process architecture**:

1. **C# Standalone Process** — all Neuro-facing logic: WebSocket client, state serialization, action validation, decision orchestration
2. **BG3SE Lua Mod** — dumb pipeline: state extraction and action execution via Ext/Osi API

```
Neuro (WS) ←→ C# Process ←→ File IPC (JSON) ←→ Lua Mod ←→ BG3
```

The C# process is the "brain." The Lua mod is the "hands."

### Key Components

| Component | Location | Role |
|---|---|---|
| `NeuroWebSocketClient` | `src/BG3Neuro.Core/Neuro/` | WebSocket to Neuro: reconnect, startup, actions/register, action/result |
| `IpcClient` | `src/BG3Neuro.Core/Ipc/` | File IPC: FileSystemWatcher, heartbeat, write action files, read results |
| `ActionRouter` | `src/BG3Neuro.Core/State/` | Validates JSON from Neuro (name→entity_id, schema), dispatches |
| `DecisionLoop` | `src/BG3Neuro.Core/State/` | Orchestration: event → context/force → validate → execute → result |
| `StateSerializer` | `src/BG3Neuro.Core/State/` | BG3 state JSON → Markdown context for Neuro |
| `CoverageAuto` | `src/BG3Neuro.Core/State/` | Range/AoE coverage calculations (shared with StateSerializer) |
| `ActionRegistry` | `src/BG3Neuro.Core/Actions/` | 17+ action schemas from `action_schemas.json` |
| `ErrorMapper` | `src/BG3Neuro.Core/State/` | error_code → actionable message mapping |

### Lua Mod

| File | Role |
|---|---|
| `BG3Neuro.lua` | Server-side: heartbeat, state emission, action execution (v0.8.31) |
| `BG3NeuroClient.lua` | Client-side: dialog snapshot + Noesis UI click via NetChannel |
| `BootstrapServer.lua` | Server entry point for BG3SE |
| `BootstrapClient.lua` | Client entry point for BG3SE |

## IPC Protocol

Communication between the C# process and the Lua mod happens through JSON files in a shared directory:

```
%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\BG3Neuro\
```

### File Types

| File | Writer | Purpose |
|---|---|---|
| `heartbeat.json` | Lua mod | Mod liveness signal (every 2s) |
| `bg3_to_neuro.json` | Lua mod | Game state (combat/dialog/exploration) |
| `action_<id>.json` | C# process | Action command for the mod |
| `result_<id>.json` | Lua mod | Action execution result |

### Heartbeat

```json
{
  "timestamp": "2026-09-16T12:00:00Z",
  "mod_version": "0.8.31",
  "sequence": 42
}
```

The C# process considers the mod dead if heartbeat is older than 10 seconds (configurable via `ipc.heartbeat_stale_s`).

### State (`bg3_to_neuro.json`)

Emitted on game events (TurnStarted, DialogStarted, SessionLoaded, etc.). Branches by scenario:

- **Combat** — turn order, current actor, resources (AP/BA), positions, available actions
- **Dialog** — conversation options (index + text), speaker, context
- **Exploration** — visible objects, regions, inventory, rest availability

### Action (`action_<id>.json`)

Written by the C# process when Neuro decides an action:

```json
{
  "command": "action",
  "data": {
    "id": "bax1",
    "name": "attack_entity",
    "actor": "goblin_1",
    "entity_id": "uuid-of-target",
    "data": "{\"weapon_slot\":\"main\"}"
  }
}
```

**Important:** The `data` field must be a JSON **string**, not an object. The mod reads it with `data["data"]:GetValue<string>()`.

### Result (`result_<id>.json`)

Written by the Lua mod after executing an action:

```json
{
  "success": true,
  "action_id": "bax1",
  "timestamp": "2026-09-16T12:00:01Z"
}
```

On failure:

```json
{
  "success": false,
  "action_id": "bax1",
  "error_code": "action_failed",
  "error_detail": "Bonus action already used this turn (BA budget enforced in-router)"
}
```

## Adding a New Action

### 1. Define the Schema

Add a new entry to `src/BG3Neuro.Core/Actions/action_schemas.json`:

```json
{
  "name": "my_new_action",
  "description": "Does something useful",
  "parameters": {
    "type": "object",
    "properties": {
      "actor": { "type": "string", "description": "Entity alias" },
      "target": { "type": "string", "description": "Target entity alias" }
    },
    "required": ["actor", "target"]
  }
}
```

### 2. Add Validation (if needed)

If the action has custom validation beyond schema matching, add a validator in `ActionRouter`.

### 3. Implement the Lua Executor

In `mod/BG3Neuro/BG3Neuro.lua`, add a handler in the `ActionExecutor` section. The pattern:

```lua
elseif action.name == "my_new_action" then
    local entity_id = resolveEntityId(action.data.target)
    if not entity_id then
        return { success = false, error_code = "actor_not_found", error_detail = "Target not found" }
    end
    -- Call Ext/Osi API
    Osi.MyAction(entity_id)
    return { success = true }
```

### 4. Add Tests

- **Unit test:** Add a test in `tests/BG3Neuro.Core.Tests/State/ActionRouterTests.cs`
- **Schema validation:** Ensure `ActionRegistry` picks up the new schema
- **Integration test (optional):** Add a scenario in `FakeNeuroServer` tests

### 5. Update Documentation

- Update `BG3_Neuro_Spec.md` action tables
- Update this file if the action has special semantics

## State Serialization

`StateSerializer` converts the raw JSON state from the mod into Markdown for Neuro. It branches by scenario:

- **Combat** — turn order, actor stats, resources, distances, AoE coverage
- **Dialog** — available options (index + text), conversation context
- **Exploration** — visible objects, regions, inventory, rest/travel availability

The Markdown format is designed for Neuro's context window — concise but complete.

## Error Handling

Two error channels:

- **Channel A (engine errors)** — the BG3 engine rejects the action (e.g., not enough resources, out of range). The mod returns `error_code` from the engine.
- **Channel B (validation errors)** — the C# process rejects the action before sending it (e.g., unknown entity, invalid schema). The `ActionRouter` returns a validation error.

Common error codes:

| Code | Meaning |
|---|---|
| `action_failed` | Generic failure (check `error_detail`) |
| `actor_not_found` | Entity alias not in the current state |
| `not_your_turn` | Action sent for wrong actor |
| `schema_violation` | Action doesn't match its schema |
| `timeout` | Action didn't complete in time |

## Resilience

| Scenario | Recovery |
|---|---|
| WebSocket disconnect | Auto-reconnect (configurable interval, default 3s) |
| Mod restart | C# detects `Stale → Alive` heartbeat transition, re-initializes |
| Corrupted IPC files | Graceful degradation — skip malformed JSON, log warning |
| Game crash | Heartbeat goes stale, C# waits for mod to come back |
| Action timeout | `result_timeout_s` (default 20s) — action is dropped, state resets |

## Testing

### Unit Tests

Pure module tests, no external dependencies:

```powershell
dotnet test tests\BG3Neuro.Core.Tests\BG3Neuro.Core.Tests.csproj --filter "Category=Unit"
```

### Integration Tests (CI-safe)

**FakeNeuroServer** — a mock WebSocket server that simulates Neuro. No game required:

```powershell
dotnet test tests\BG3Neuro.Core.Tests\BG3Neuro.Core.Tests.csproj --filter "Category=Integration"
```

**Randy Integration** — real Randy via WebSocket. Auto-skipped if Randy is not running:

```powershell
cd neuro-sdk\neuro-sdk\Randy && npm install
dotnet test tests\BG3Neuro.Core.Tests\BG3Neuro.Core.Tests.csproj
```

### Smoke Test

Single command — connect → state → end_turn → new state:

```powershell
powershell -ExecutionPolicy Bypass -File tests\smoke.ps1
powershell -ExecutionPolicy Bypass -File tests\smoke.ps1 -Full   # full suite
```

## Build & Release

### Building the Mod PAK

```powershell
# Build PAK from the build directory (parent of Mods\)
& "path\to\paktool2.exe" create "path\to\vNNN_build" "output\BG3Neuro.pak"
```

**Important:** The source directory must contain `Mods\BG3Neuro\` as a child — pass the parent, not `Mods\BG3Neuro` itself.

Verify:

```powershell
& "path\to\paktool2.exe" list "output\BG3Neuro.pak"
# Entries should start with: Mods/BG3Neuro/
```

### Installing

Copy the PAK to:

```
%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\BG3Neuro.pak
```

The mod auto-creates a backup of the previous version (`BG3Neuro.pak.bak-vNNN`).

### Versioning

- **Mod version** — in `BG3Neuro.lua` (`MOD_VERSION`) and `BG3NeuroClient.lua`
- **Mod version (exported)** — `_G["BG3Neuro_VERSION"]` for Bootstrap detection
- **PAK backup suffix** — `bak-vNNN` (incremental build number)

## Code Style

### C#

- .NET 9, nullable enabled, warnings as errors
- Follow existing naming conventions (PascalCase for public, _camelCase for private fields)
- Use `System.Text.Json` for JSON serialization
- No external NuGet packages (test-only: xUnit)

### Lua

- BG3SE Lua API: `Ext.*`, `Osi.*`, `Ext.Json`, `Ext.IO`
- Use local variables where possible
- Comment non-obvious logic in Russian (project convention)
- Keep mod "dumb" — no decision logic, only extraction and execution
