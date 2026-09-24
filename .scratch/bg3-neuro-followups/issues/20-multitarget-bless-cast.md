# 20 — `cast_spell` supports only one `target_id`; bless needs each target picked separately

Type: task (API design + implement)
Status: resolved (2026-09-21 — live bench verified, PAK `BG3Neuro_v091.pak`, MD5 `fd498b605b660c2d8cb1fb51c46b63f4`, SHA256 `CD5D36BE909BE8C60797EA91E5374D83C5B13E3C96A7F164DF943DA97FBA873B`)
Blocked by: none

## Symptom (live bench 2026-09-21, v083)

`cast_spell "bless"` with `target_id=tav` (Shadowheart's turn, osiris queue):
`result: success:true`, slot + AP spent natively — but the buff landed on
**Shadowheart herself**, not on Tav. User confirmed: "the cast went only onto
Shadowheart; each bless target must be picked separately."

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

## Implemented decision (2026-09-21, v0.8.60)

**Option 1, engine-honest variant**: `target_ids` feeds ONE engine cast with
`Targets` = the full list (bless covers up to 3 allies in a single action; N
separate casts would be N× slot/AP — dishonest economy). Details:

- Lua `executeCast`: single `target_id` + `target_ids` merged into a list
  (`targetIds`, `BG3Neuro.lua:4290`). First element doubles as back-compat
  `target`. `enqueueCastRequest` accepts `opts.targets` and builds
  `Targets[]` from every member (`BG3Neuro.lua:3700`); `opts.target` remains
  for single/attack/bonus callers.
- Honesty gates per target: `preValidateCastTarget` runs for **each** list
  member (range + LOS, ticket-06 rule) — a single out-of-range/LOS target is a
  clean refusal, no silent engine re-pick.
- auto-force (ticket-16): force-flags set only when **every** target is a known
  non-enemy (`verdict ~= nil and verdict ~= "enemy"`); any unknown/enemy target
  → honest path untouched (matches old single-target semantics).
- `use_osi_spell` honestly refusals multi-target (`multi_target_not_supported_with_osi`)
  — `Osi.UseSpell` holds one target. Legacy fallback also skips multi (would
  silently cast on the first one only).
- C# `ActionRouter.ValidateCastTarget`: `target_ids[]` merged with optional
  `target_id`; each member must exist (`TargetMissing`) and be in range
  (`TargetNotInRange`). `FillAoEPosition` skips when `target_ids` present.
- `action_schemas.json`: `target_ids: array<string>` added to `cast_spell`;
  description documents the multi-target use.
- Tests (4 new, `ActionRouterTests`): all-in-range success (+ passes
  `target_ids` through to the action file), missing member refused, out-of-range
  member refused, friendly single stays green. Full suite: 166/166 green.

Live-verification to do (once game is closed for PAK install):**
Shadowheart bless → `target_ids: [tav, shadowheart, gale]` in one inject; all
three show `BLESSED` in a later `stats_probe`; slot/AP spent once.

## Live bench (2026-09-21, gate battle, v0.8.60 / PAK v091)

Inject (drive_action.ps1, env `BG3NEURO_DATA`): `cast_spell`,
`actor:poc_player_cleric` (Shadowheart), `spell_name:bless`,
`target_ids:[tav, origin_astarion, poc_player_wizard]` — ID `c24m2`.

- Result `success:true`, `running:true`, no `error_code`; economy block reports
  `slot.ok=true (before 1.0)`, `ap.ok=true`.
- `cast_debug.json` confirms the full list was queued: `targetUuids` = all 3
  member guids, `targetPos` = first target, `forceFlags:true` (all targets known
  non-enemies), engine request `34a730a8…`, queue `osiris`.
- `stats_probe` (raw StatusManager, server truth) shows **`BLESS` on 3/3
  targets**, duration_left 60.0:
  - `e6090219…` (Tav) → BLESS
  - `c7c13742…` (Astarion) → BLESS
  - `ad9af97d…` (poc_player_wizard) → BLESS
- Economy snapshots `resource_snapshot_c24m2_before/after.json`:
  - SpellSlot lvl1: **1.0 → 0.0** — ONE slot spent for one multi-target cast.
  - ActionPoint: **1.0 → 0.0** — ONE AP spent.
  - BonusActionPoint 1.0 → 1.0, Movement 9.0 → 9.0 (untouched).
- No Lua errors in the SE log for this cast (only `[BG3Neuro] economy deduct
  c24m2`).
- Confirms the OPTION-1 engine-honest design: N separate casts would have spent
  N× slot/AP; the single `Targets[]` request spent exactly once.

## Verification idea

Shadowheart bless → Tav + Shadowheart + Gale in one inject; all three show
`BLESSED` in a later state; result per target.

## Notes

- Discovered while benching ticket 06; recorded here so the 06 fix stays about
  aim, not about API shape.
- Multi-target LoS/range still subject to ticket-06 pre-validation per target.
- Key nuance for the bench: N separate casts would spend N slot/AP — the mod
  casts ONE request with `Targets[]` so the native economy (1 slot) holds.
  Confirmed by probe variants (`step_5_targets`/`step_8_position`) that the
  engine accepts a multi-member `Targets` array.