# BG3Neuro

File-based IPC bridge between Neuro (AI companion) and Baldur's Gate 3 via BG3 Script Extender: combat, dialog and exploration. Spec: `BG3_Neuro_Spec.md` — final, accepted.

## Repository contents

| Path | What it is |
|---|---|
| `src/BG3Neuro.Core` | C# core: IpcClient (heartbeat/stale), Neuro WebSocket client, ActionRouter (validation §6.5), DecisionLoop (force), StateSerializer |
| `src/BG3Neuro.App` | Console process — launch point of the C# part |
| `mod/BG3Neuro` | BG3SE Lua mod: heartbeat 2s, state file, execution of `action_*.json` |
| `tests` | xUnit: unit (StateSerializer/ActionRouter/IpcClient/ErrorMapper…), integration (A: FakeNeuroServer; B: Randy), smoke |
| `tests/smoke.ps1` | Smoke in one command (see below) |
| `docs/manual-regression-checklist.md` | Manual regression checklist §9.5 |
| `.scratch/bg3-neuro-implementation` | Tickets 01–10 + status map |

## Quick start

```powershell
# build
dotnet build BG3Neuro.sln

# full test suite (unit + integration A/B; the Randy part starts itself if installed)
dotnet test tests\BG3Neuro.Core.Tests\BG3Neuro.Core.Tests.csproj

# smoke in one command: connect -> state -> end_turn -> new state (no game, no Randy)
powershell -ExecutionPolicy Bypass -File tests\smoke.ps1
powershell -ExecutionPolicy Bypass -File tests\smoke.ps1 -Full   # full suite
```

## Test bench (§9 Testing Architecture)

- **Unit** — pure modules: StateSerializer, ActionRouter, IpcClient (fake files), ConfigLoader, ErrorMapper, CoverageAuto.
- **A (CI, no game)** — `FakeNeuroServer` (my WS server in place of Neuro) + mock BG3SE files in a temp directory: combat loop, exploration, dialog, resilience (reconnect, mod restart, corrupted files).
- **B (CI, with simulator)** — real Randy over a real WS `ws://localhost:8000`. Randy is prepared once:

  ```powershell
  cd neuro-sdk\neuro-sdk\Randy
  npm install
  ```

  The tests start Randy themselves with ports from env (`RANDY_WS_PORT`/`RANDY_HTTP_PORT`); if `node_modules/tsx` is missing or the port didn't open within 40s — Randy tests are skipped and the rest of the suite stays green. The run uses `node` on the machine (Randy is a `node` process).
- **C (manual regression)** — real Neuro before release: checklist §9.5 in `docs/manual-regression-checklist.md`.

The smoke scenario "connected → state arrived → end_turn executed → state updated" is implemented by the `FullLoopSmokeTests` test and runs with the single command `tests\smoke.ps1`.

## Running the C# process and connecting Neuro

Requirements: .NET 9 (Runtime to run / SDK for the tests), BG3 + BG3 Script Extender, Neuro (or Randy for verification).

1. **Mod**: the script `mod\BG3Neuro\BG3Neuro.lua` connects in the **server-context** of BG3SE (Lua runs on the game server, not in the UI client) — e.g. appended to the end of `Script Extender\Lua\BootstrapServer.lua`; context and requirements are in `.scratch\bg3-neuro-integration\research\bg3se-lua-action-api.md`. Default IPC directory: `<LocalAppData>\Larian Studios\Baldur's Gate 3\Script Extender\BG3Neuro`.
2. **Start the game** — the mod writes `heartbeat.json` (2s) and `bg3_to_neuro.json`, and listens for `neuro_to_bg3.json`.
3. **Start Neuro/Randy**, then the C# process:

   ```powershell
   dotnet run --project src\BG3Neuro.App -- config.json
   # or the compiled exe:
   src\BG3Neuro.App\bin\Debug\net9.0\BG3Neuro.App.exe config.json
   ```

   Example `config.json` (all keys optional, defaults from `AppConfigDefaults` apply):

   ```json
   {
     "neuro": { "ws_url": "ws://localhost:8000", "reconnect_interval_s": 3 },
     "ipc": { "poll_interval_ms": 50, "heartbeat_interval_s": 2, "heartbeat_stale_s": 10 },
     "game": { "name": "Baldur's Gate 3", "controlled_party_size": 1 }
   }
   ```

4. Log check: `[ipc] mod: Unknown -> Alive`, `[neuro] connected`, `[neuro] session: …` — the loop is up. Entering combat/dialog/exploration sends `actions/force`, Neuro responds with `action`, validation goes to `action/result` (Channel A), successful actions go to `action_*.json` for the mod.

## Questions resolved in the spec

- Error channels, the "one action" force policy, result timings — §6.5/§1.6 of the spec.
- Resilience: WS reconnect, mod/game restart (re-init on `Stale→Alive`), corrupted files — ticket 09.
- Out of scope v1 — §10 of the spec (voice, multiplayer, camera, purchasing, `throw`, stealth).