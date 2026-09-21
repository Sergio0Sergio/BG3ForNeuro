# 20 — `cast_spell` supports only one `target_id`; bless needs each target picked separately

Type: task (API design + implement)
Status: open (captured from live bench, not yet argued)
Blocked by: none

## Symptom (live bench 2026-09-21, v083)

`cast_spell "bless"` with `target_id=tav` (Shadowheart's turn, osiris queue):
`result: success:true`, slot + AP spent natively — but the buff landed on
**Shadowheart herself**, not on Tav. User confirmed: «каст прошел только на
shadowheart. необходимо выбирать каждую цель bless».

Turns out it was not (only) the ticket-06 aim issue: the action contract has a
**single** `target_id` field (dispatcher `executeCast`, `BG3Neuro.lua`), so
multi-target blessed to 3 characters cannot be expressed at all.

## What this ticket is

`bless` is the first realistic multi-target support spell. Decide the API
shape, not the aim mechanics (aim mechanics live in `bg3-neuro-perception`
ticket 06). Options seen on the bench:

1. `cast_spell` accepts a list: `data.target_ids = ["id1","id2"]` (single-target
   stays `target_id` for back-compat; dispatch fans out to one cast per target,
   serially, each with its own honest result).
2. Keep `target_id` and run N round-trips from the app (no mod change;
   slow, and the app has no notion of "spell targeting N allies").
3. A dedicated `cast_spell` sub-mode `multi=true` with `target_ids` — same as
   (1) but explicit opt-in to avoid accidental megacasts.

Preference on the bench: (1) — `target_ids` optional, single-target path
byte-identical.

## Verification idea

Shadowheart bless → Tav + Shadowheart + Gale in one inject; all three show
`BLESSED` in a later state; result per target.

## Notes

- Discovered while benching ticket 06; recorded here so the 06 fix stays about
  aim, not about API shape.
- Multi-target LoS/range still subject to ticket-06 pre-validation per target.