# 13 — Combat state exposes no real status effects (Off Balance is unverifiable)

Type: task (state emitter)
Status: claimed
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

## Implementation (2026-09-18, pending live verification)

Research confirming the SE API: `research/13-status-effects-api.md` — server-side statuses live in
`esv::StatusMachine.Statuses`, reachable from Lua via `ServerCharacter.StatusManager`
(`BG3SE PropertyMaps/ServerObjects.inl:18-43`).

Mod (`BG3Neuro.lua`, v0.8.37):
- New helpers `statusDisplayName` / `statusListOf` / `conditionsOf` / `entityStatusDump`; status field
  whitelist `STATUS_FIELDS`.
- Combat emitter: every combatant (ally **and** enemy) gets `conditions = [{ id, name, turns_left?,
  duration_left? }]`; the ally `effects` availability string is renamed to `availability` (no longer
  implies statuses). Enemy `status` (`defeated` / `cannot act`) is unchanged.
- `stats_probe` now dumps a raw status machine per participant (`entry.status_dump`), so the first live
  run can confirm the `StatusId` format, `TickType` semantics and `TurnTimer` (remaining vs total).
- `turns_left` policy: `TurnTimer` when > 0, else omitted; `duration_left` = `CurrentLifeTime` seconds
  (research/13 §4.1 — to be confirmed live).

App (`CombatState.cs` / `StateSerializer.cs`): `Combatant.Effects` → `Availability`; new
`StatusCondition { Id, Name, TurnsLeft, DurationLeft }` + `Conditions` list; markdown renders
`conditions: Off Balance (1)` for both sides.

Tests: `StateSerializerTests` extended — conditions round-trip on an ally and an enemy plus markdown
assertions. `dotnet test` **155/155**. `luaparse` OK on both Lua files.

PAK **v043** built + installed (MD5 `643A42E69153F69CB9C49B4281493938`, entries `Mods/BG3Neuro/…`,
`modsettings.lsx` L19/L39 updated; the previous PAK is backed up as `BG3Neuro.pak.bak-v042`).

### Live probe (2026-09-18, v0.8.37) — right handle, wrong container type

`stats_probe` in the DEN gate fight (12 combatants, v0.8.37) returned per participant:
`has_status_manager = true` (so `ServerCharacter.StatusManager` **is** the right handle) but
`statuses_type = "userdata"` and `status_count = 0` for **all 12**. Root cause: `statusListOf`
required `type(statuses) == "table"`, but BG3SE exposes the status array as **userdata**, so the
list was dropped before iteration. Whether anyone actually had a status is unknown from that dump,
because the count came from the same gated path.

Fix (**v0.8.38**): `statusListOf` accepts `table` or `userdata`; new `statusItemsOf` enumerates an SE
container via `#`/`[i]`, then `:GetCount`/`:Size`, `:GetAll`/`:ToArray`, `:Get(i)`, then `pairs`.
`entityStatusDump` now reports `status_len`, `status_index1`, `status_count`, `metatable_type` /
`metatable_keys`, `get_status_ent` / `get_status_comp` (`GetStatus` bound?) and `osi_status_fns`
(which `Osi.*Status*` helpers exist at runtime) — one run decides the final accessor.

**Still to do (needs the game):** re-probe on v0.8.38 to pick the working accessor, then the
flourish/Off Balance bench from `## Verification`.
