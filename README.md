# BG3Neuro

File-based IPC bridge between [Neuro](https://github.com/VedalAI/neuro-sdk) (AI companion) and **Baldur's Gate 3** via [BG3 Script Extender](https://github.com/norbyte/bg3se). Allows Neuro to play BG3: combat, dialog, and exploration.

## Features

- **Combat** — Neuro controls a party member on their turn: move, attack, cast spells, use bonus actions, end turn
- **Dialog** — Neuro reads conversation options and clicks through Noesis UI (client-side)
- **Exploration** — move to entities, interact, loot, rest, travel, open map/inventory
- **Honest economy** — engine-native resource spending (AP/BA) with in-router budget enforcement
- **Resilient** — WebSocket reconnect, mod restart detection (heartbeat), corrupted file recovery

## Architecture

```
┌─────────────────────────────────────────────┐
│  Neuro (external WS server, ws://localhost)  │
└──────────────────┬──────────────────────────┘
                   │ WebSocket (Neuro SDK protocol)
┌──────────────────▼──────────────────────────┐
│  C# Standalone Process (.NET 9)             │
│  NeuroWebSocketClient · IpcClient ·         │
│  StateSerializer · ActionRouter ·           │
│  DecisionLoop · CoverageAuto ·              │
│  ConfigLoader · ErrorMapper                 │
└──────────────────┬──────────────────────────┘
                   │ File-based IPC (JSON)
┌──────────────────▼──────────────────────────┐
│  BG3SE Mod (Lua)                            │
│  BG3Neuro.lua · BG3NeuroClient.lua          │
│  StateExtractor · ActionExecutor ·          │
│  IpcFileHandler                             │
└──────────────────┬──────────────────────────┘
                   │ Ext / Osi API
              Baldur's Gate 3
```

**Two-process model:** C# handles all Neuro-facing logic ("decide in C#"). The Lua mod is a dumb pipeline — only state extraction and action execution.

## Requirements

- **.NET 9** SDK (to build) or Runtime (to run)
- **Baldur's Gate 3** with [BG3 Script Extender](https://github.com/norbyte/bg3se) installed
- **Neuro** or **Randy** (local emulator from [neuro-sdk](https://github.com/VedalAI/neuro-sdk))
- **English-language** version of BG3

## Quick Start

See [QUICKSTART.md](QUICKSTART.md) for a step-by-step guide (install mod → configure → run).

## Configuration

The C# process reads a JSON config file. All keys are optional — defaults are applied automatically.

```json
{
  "neuro": {
    "ws_url": "ws://localhost:8000",
    "reconnect_interval_s": 3
  },
  "ipc": {
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
  }
}
```

## Running

```powershell
# Build
dotnet build BG3Neuro.sln

# Run (from repo root)
dotnet run --project src\BG3Neuro.App -- config.json
# or the compiled exe:
src\BG3Neuro.App\bin\Debug\net9.0\BG3Neuro.App.exe config.json
```

**Startup sequence:**
1. Start BG3 with the mod loaded — the mod writes `heartbeat.json` (every 2s)
2. Start the C# process — it detects the heartbeat, connects to Neuro
3. Start Neuro/Randy — WS connection established, session begins

**Verify:** Look for `[ipc] mod: Unknown → Alive`, `[neuro] connected`, `[neuro] session: …` in the log.

## Testing

```powershell
# Unit + integration tests
dotnet test tests\BG3Neuro.Core.Tests\BG3Neuro.Core.Tests.csproj

# Smoke test (no game, no Randy needed)
powershell -ExecutionPolicy Bypass -File tests\smoke.ps1
powershell -ExecutionPolicy Bypass -File tests\smoke.ps1 -Full   # full suite
```

Test tiers:
- **Unit** — pure modules: StateSerializer, ActionRouter, IpcClient, ErrorMapper, CoverageAuto
- **Integration A (CI)** — FakeNeuroServer + mock files, no game required
- **Integration B (CI)** — real Randy via WebSocket, auto-skipped if unavailable
- **Manual regression** — checklist in `docs/manual-regression-checklist.md`

## Project Structure

| Path | Description |
|---|---|
| `src/BG3Neuro.Core/` | C# core library — all Neuro interaction logic |
| `src/BG3Neuro.App/` | Console entry point |
| `mod/BG3Neuro/` | BG3SE Lua mod (server + client) |
| `tests/` | xUnit tests + smoke scripts |
| `neuro-sdk/` | Git submodule — [VedalAI/neuro-sdk](https://github.com/VedalAI/neuro-sdk) |
| `docs/` | Regression checklist, agent docs |
| `.scratch/` | Issue tracker (wayfinder maps + tickets) |
| `BG3_Neuro_Spec.md` | Full architecture specification |
| `DEVELOPER.md` | Developer guide (architecture, IPC, adding actions) |

## Documentation

- **[QUICKSTART.md](QUICKSTART.md)** — install and run in 5 minutes
- **[DEVELOPER.md](DEVELOPER.md)** — architecture, IPC protocol, adding actions, testing
- **[BG3_Neuro_Spec.md](BG3_Neuro_Spec.md)** — full specification (authoritative)

## License

Internal project — no public license.
