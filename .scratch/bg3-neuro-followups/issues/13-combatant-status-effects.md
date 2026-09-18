# 13 — Combat state exposes no real status effects (Off Balance is unverifiable)

Type: task (state emitter)
Status: ready-for-agent
Blocked by: —

## Symptom

Neither side of `bg3_to_neuro.json` carries the actual conditions a combatant is under, so a debuff
like **Off Balance** (the point of `Target_OpeningAttack` / flourish) cannot be observed, asserted, or
shown to the model.

What is emitted today (`BG3Neuro.lua:1844-1857`):

- **allies** get an `effects` **string** that is not about effects at all — it is built from action
  availability only: `"acting now"` and/or `"can act" | "cannot act"` (`canAct` = the TurnBased
  `CanActInCombat` field, L1829). No status names.
- **enemies** get no `effects` at all — only `status` (`"defeated" | "cannot act"`, L1852-1856).
- Nothing anywhere reports a condition name or its remaining duration.

So Off Balance, Prone, Burning, Haste, etc. are invisible to the app and to the model.

## Impact

- The bench for ticket 09 could verify the *cost* spent by flourish but **not** that it applied Off
  Balance — the effect is simply absent from the state.
- The model cannot reason about conditions when choosing actions (attack the off-balance target, avoid
  the prone ally, dispel the hasted enemy).

## Fix direction (verify first)

1. Confirm the Script Extender API that lists active statuses/boosts for a character — candidates to
   probe on a real character during combat: a `Status`/`Boost`/`Conditions` field on the entity or its
   `ServerCharacter`/`Health` component, an `Osi` query, or the same `fieldOf` probe approach already
   used at `BG3Neuro.lua:737-745`. Extend that probe list rather than guessing.
2. For each combatant, emit a structured list, e.g.
   `effects = [{ name = "off_balance", display = "Off Balance", turns_left = 1, source = "enemy" }]`
   (or, minimally, a `"off_balance(1)"` string) — one consistent shape for **both** allies and
   enemies. Do not overload the existing availability string: keep `"acting now"` / `"can act"` where
   they are and add statuses separately (e.g. `conditions` vs `effects`), so the field name matches
   its meaning.
3. Keep user-facing text English (`AGENTS.md`); the engine supplies localized display strings, so
   prefer the status id + a curated English label, same policy as `abilityDisplayName` (ticket 09).
4. Rename/clarify the ally `effects` field so it no longer implies statuses.

## Verification

- Static: `luaparse` 5.3 on `BG3Neuro.lua`; extend the state round-trip tests with an `effects` /
  `conditions` field on both an ally and an enemy (`CombatStateTests`, `StateSerializerTests`).
- Bench (gate fight, `turn_actor=tav`): cast `flourish` (`Target_OpeningAttack`) at an adjacent enemy,
  then read `bg3_to_neuro.json` and assert the target's effects contain `off_balance` with a positive
  `turns_left`; and confirm the field is populated for enemies as well as allies.

## Evidence

- Live `bg3_to_neuro.json` during the ticket-09 bench (2026-09-17): `Target_OpeningAttack` spent BA
  1.0 → 0.0 with a hit, yet neither the target's nor the caster's entry changed beyond HP/resources.
- `docs/manual-regression-checklist.md` — Run 2026-09-17 (v0.8.35), "Not verified: enemy effects
  (Off Balance unverifiable)".
- `mod/BG3Neuro/BG3Neuro.lua:1844-1857` (allies' pseudo-`effects`, enemies' `status`).
