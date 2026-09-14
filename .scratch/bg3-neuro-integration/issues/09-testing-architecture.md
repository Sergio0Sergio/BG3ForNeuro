# 09 — Testing Architecture

Type: grilling
Status: resolved
Blocked by: 01
Depended by: —

## Answer

### Decisions (HITL)

- **T1 — Randy as-is**: base e2e loop (register → force → action → result) + HTTP POST `localhost:1337` for manual scenarios. Randy is not modified (foreign code, known constraints: JSONSchemaFaker, only forced actions, instant responses). "Bad" cases — unit/integration, not Randy.
- **T2 — Unit tests**:
  - Minimal module set: **StateSerializer**, **ActionRouter** (JSON schema validation, dispatch by name), **IpcClient** (with fake action_/result_ files), **ConfigLoader** (config.json → structures with defaults), **ErrorMapper** (error_code → actionable message dictionary).
  - The "range/AoE coverage" automaton — **a separate clean module** (single code path with StateSerializer, 03 S3) with its own unit tests (this is the main logic piece).
  - The Lua part (BG3SE mod) against `Ext.*` mocks — light smoke on the bench, **not in CI**; in v1 isolated C# tests + a manual run of the mod in the game are enough.
- **T3 — Integration tests**: **A + B in CI**: (A) C# pipeline without the game — BG3SE mock files (action_/result_) + fake WS; (B) C# ↔ Randy (real WS, ws://localhost:8000) + BG3SE mock files. (C) Real Neuro — manual regression run before release, not in CI.
- **T4 — Smoke**: fake BG3SE (mock files) in CI (automated, the "sees the battlefield → attack_entity → result" scenario) + **mandatory manual test on a real game** (test scene with 1 enemy) before release. Automating on a real game is not honestly possible — this is the main trust anchor.
- **T5 — Scenarios**: automated tests on **simulated states** cover the logic (formatter/validator/coverage/router) to the maximum; all scenarios (combat 1v1/1v many/AoE/healing; dialogue choice/quest; exploration movement/interaction) go into the **manual regression checklist** on a real game. Trading — out of scope (05), excluded from the checklist.

## Question

Determine the testing architecture:

1. **Randy testing**: How to connect the plugin to Randy? Which WS commands does Randy support? (See Randy/README.md: random actions, action forces, POST API for simulation)
2. **Unit tests**: Which modules do we test in isolation?
   - State Serializer: BG3 mock data → format check
   - Action Router: JSON schema validation
   - IPC Message Parser: message deserialization
3. **Integration tests**: Full mock-state → decision → action loop
4. **Smoke test**: Minimal scenario "Neuro sees the battlefield, attacks the enemy, gets a result"
5. **Test scenarios**: Which specific scenarios to test?
   - Combat: 1v1, 1v many, AoE, healing
   - Dialogue: simple choice, trading, quest
   - Exploration: movement, interaction

See Randy/README.md for the Randy API (ws://localhost:8000, HTTP POST port 1337).