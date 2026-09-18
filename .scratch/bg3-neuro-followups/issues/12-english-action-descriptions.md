# 12 — Action descriptions sent to Neuro are in Russian

Type: bug (Neuro contract / language policy)
Status: resolved
Blocked by: —

## Finding (live bench 2026-09-17)

`ActionRegistry` embeds `src/BG3Neuro.Core/Actions/action_schemas.json` and registers every entry with
Neuro at connect time. **All 24 `description` strings are in Russian**, so the model receives a
Russian-language action contract:

```
move_to_target         [RU] Переместиться к выбранной цели.
attack_entity          [RU] Атаковать выбранного противника …
cast_spell             [RU] Использовать заклинание; цель AoE …
… (24/24 Russian)
```

Evidence: the `actions/register` WS frame captured at `11:55:03`,
`{"command":"actions/register", … "description":"\u041F\u0435\u0440\u0435\u043C\u0435\u0441\u0442\u0438…
(\u041F\u0435\u0440\u0435\u043C\u0435\u0441\u0442\u0438\u0442\u044C\u0441\u044F = "Переместиться)`.

## Why it matters

`AGENTS.md` is explicit: the app and mod are used with the **English** version of BG3 and "everything
must function and read correctly in English"; "Keep the mod's user-facing strings … in English". The
action descriptions are the model-facing contract — the most user-visible surface there is. They are
also the only place the model learns what each action does.

## Fix

Translate all 24 `description` values to English in `action_schemas.json`. Keep the `name` keys and
JSON schemas unchanged. No code change needed.

Follow-up worth checking: are there other model-facing / user-facing strings still emitted in Russian
by the app (e.g. `ErrorMapper.ToMessage`, force queries in `DecisionLoop`, exploration prompts)? Those
were English in the review, but this ticket should sweep the whole Neuro-facing surface.

## Scope update (after ticket 10)

Ticket 10 hid 7 dev/bench entries (`"internal": true`), so only **17** descriptions now reach the
model in `actions/register`. Translate **all 24** in `action_schemas.json` anyway — `AGENTS.md`
requires English for everything mod-facing, and the internal entries are still the mod's documented
surface. The no-Cyrillic test should sweep the whole file, not just the registered subset.

## Verification

- Static: a test asserting no `ActionDefinition.Description` contains Cyrillic, e.g.
  `Assert.DoesNotMatch(@"[\u0400-\u04FF]", d.Description)` across `ActionRegistry.Get()`; plus a
  file-wide check that also covers the `internal` entries.
- Bench: the `actions/register` frame no longer contains `\u04xx` escapes.

## Answer (2026-09-18)

All 24 `description` values translated to English in `action_schemas.json`; `name` keys, `internal`
flags and JSON schemas unchanged. Two tests added to `NeuroWebSocketClientTests`:

- `Get_ActionDescriptions_AreEnglish_NoCyrillic` — every `ActionRegistry.Get()` description is
  non-empty and contains no `[\u0400-\u04FF]`.
- `EmbeddedSchema_HasNoCyrillic_EvenForInternalEntries` — reads the embedded
  `BG3Neuro.Core.Actions.action_schemas.json` manifest resource and asserts the whole file (internal
  entries included) has no Cyrillic.

`dotnet test` → **155/155** (was 153).

Live bench (`run_app.cmd` with `bench_config.json`, autopilot off; the App was rebuilt first — the
schema is an embedded resource, so the App's copied `BG3Neuro.Core.dll` had to be refreshed): the
`actions/register` frame now contains **no `\u04xx` escapes**, **17** actions, **0** Cyrillic
descriptions — e.g. `move_to_target='Move to the specified target.'`,
`use_item='Use an inventory item (healing, armour, food) on yourself or the specified target.'`.

Sweep of the rest of the Neuro-facing surface — **no unintended Cyrillic**:

- `src/**/*.cs` and non-`.cs` assets under `src/` — zero Cyrillic occurrences. (Checked with a
  UTF-8-aware read: `Select-String` on PowerShell 5.1 decodes UTF-8 as CP1251 and reports em-dashes
  `—` as Cyrillic mojibake — a false positive.)
- `mod/BG3Neuro/*.lua` — Cyrillic appears only in `--` comments and in the intentional Russian→Latin
  `translitMap` (`BG3Neuro.lua:830-837`). No user/model-facing string literal is Russian.

Scope: only 17 descriptions reach the model after ticket 10, but all 24 were translated and the
file-wide test guards the `internal` entries too, per `AGENTS.md`.

## Evidence

- `actions/register` frame in the WS capture log, 2026-09-17 11:55:03.
- `src/BG3Neuro.Core/Actions/action_schemas.json` (24/24 Russian descriptions).
