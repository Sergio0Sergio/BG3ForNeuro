# 10 — Test drift: registered action count is 24, tests hardcode 21

Type: task (tests / registration surface)
Status: done
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

## Resolution (2026-09-17)

Chose **option 1, widened**: the model must not see dev/bench knobs at all, so **all 7** dev-only
entries are now hidden — not just the 3 `bench_*` that the old tests happened to exclude.

- `action_schemas.json`: added `"internal": true` to `state_capture`, `end_turn_ecs`, `probe`,
  `diag_skip`, `bench_snapshot`, `bench_party_increase`, `bench_use_spell` (24 → 17 exposed).
  (`end_turn_ecs` also stops shadowing the real `end_turn` in the model's view.)
- `ActionRegistry.Load` skips internal entries, so they are neither registered (`Get()`) nor routable
  (`Find()`) — the register frame carries 17 gameplay actions. `ActionDefinition` gained no field: the
  flag stays an input-file concern.
- Bench/dev workflow is unaffected: internal actions are still executable in the mod when injected
  directly into `neuro_to_bg3.json` (`drive_action.ps1`), as done for the ticket-09 `piercing_strike`
  check.
- Tests updated: `Get_Returns17GameplayActions_CombatDialogueExploration`, new
  `Get_NeverExposesInternalDebugOrBenchActions`, the register/reregister/reconnect counts (21 → 17)
  and `RandyIntegrationTests`. Full suite **153/153 green**.
- `DEVELOPER.md`: documented the `internal` flag (and fixed the stale `"parameters"` key in the
  add-an-action example — the registry reads `"schema"`).

## Evidence

- `dotnet test` → 153 passed, 0 failed (2026-09-17).
- `action_schemas.json` — 24 entries, 7 `internal`, 17 exposed.
- Prior failure record (unchanged, historical): 147 passed / 5 failed `Expected: 21 / Actual: 24`.
