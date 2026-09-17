# 12 — Action descriptions sent to Neuro are in Russian

Type: bug (Neuro contract / language policy)
Status: ready-for-agent
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

## Verification

- Static: a test asserting every `ActionDefinition.Description` is ASCII / contains no Cyrillic,
  e.g. `Assert.DoesNotMatch(@"[А-Яа-яЁё]", d.Description)` across `ActionRegistry.Get()`.
- Bench: the `actions/register` frame no longer contains `\u04xx` escapes.

## Evidence

- `actions/register` frame in the WS capture log, 2026-09-17 11:55:03.
- `src/BG3Neuro.Core/Actions/action_schemas.json` (24/24 Russian descriptions).
