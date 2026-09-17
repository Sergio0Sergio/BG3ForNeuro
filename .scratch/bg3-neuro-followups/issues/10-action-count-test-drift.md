# 10 — Test drift: registered action count is 24, tests hardcode 21

Type: task (tests / registration surface)
Status: ready-for-agent
Blocked by: —

## Finding (2026-09-17, post-ticket-09 full `dotnet test`)

The full test suite is red on **5 assertions, all the same drift**, and none of them relate to
ticket 09:

- `tests/BG3Neuro.Core.Tests/Neuro/NeuroWebSocketClientTests.cs` — lines 17, 103, 145/146, 148, 170.
- `tests/BG3Neuro.Core.Tests/Neuro/RandyIntegrationTests.cs` — line 154.

All assert `21`, the real value is `24`:

```
src/BG3Neuro.Core/Actions/action_schemas.json  -> 24 entries
```

The 3 additions beyond the tests' 21 are debug/bench-only actions:

```
bench_snapshot, bench_party_increase, bench_use_spell
```

Reproduced on a clean tree (stash of the ticket-09 work) → **pre-existing, not a regression**.

## Why it matters

`ActionRegistry` embeds `action_schemas.json` and registers **all** entries with Neuro. So the model
currently sees the debug/bench surface (`state_capture`, `end_turn_ecs`, `probe`, `diag_skip`,
`bench_*`) as if it were gameplay. Either the tests are stale, or the registration surface is
over-broad; the two must be reconciled.

## Options

1. **Exclude debug/bench actions from Neuro registration** (e.g. an `internal`/`debug` flag in the
   schema, filtered in `ActionRegistry.Load`), leaving the model-facing set at the intended size, and
   update the tests to that number. Preferred if these actions are not meant for the model.
2. **Derive the expected count in the tests** from `ActionRegistry.Get().Count` (or from the schema
   file) instead of a literal, so the tests track the surface automatically.

Whichever is chosen, decide explicitly between "the model sees 21 gameplay actions" and "the model
sees everything, including bench" — do not just bump the literals to 24 without that decision.

## Evidence

- `dotnet test tests/BG3Neuro.Core.Tests/BG3Neuro.Core.Tests.csproj` → 147 passed, 5 failed
  (`Expected: 21 / Actual: 24`), 2026-09-17.
- `src/BG3Neuro.Core/Actions/action_schemas.json` (24 entries, see list above).
- Clean-tree reproduction (stash) confirming pre-existing status.
