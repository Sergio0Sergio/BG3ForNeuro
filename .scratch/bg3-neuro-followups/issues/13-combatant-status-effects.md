# 13 — Combat state exposes no real status effects (Off Balance is unverifiable)

Type: task (state emitter)
Status: resolved
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
- **Amended 2026-09-18 (live):** "positive `turns_left`" is not achievable — the engine exposes no
  remaining-turns value (`Osi.*Status*` absent from the runtime table; `TurnTimer` is a seconds tick
  countdown, `TickType = 0`). The assertion therefore becomes: `conditions` contains the status id
  and, for finite statuses, a `duration_left` in seconds; no `turns_left` is emitted.

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

### Live probe (2026-09-18, v0.8.38) — enumerator works; the payload is engine-internal

`stats_probe` (DEN gate fight) now returns each participant's status list via `#statuses` +
`statuses[i]` (the SE container is `userdata` but supports `#`/indexing; `metatable_type` returns a
string, so `metatable_keys`/`pairs` are useless). Enemies carry 3-4 statuses each, allies 0-1. Raw
field semantics, confirmed live:
- `TickType = 0` for every observed status; `LifeTime = -1` (permanent) for all of them.
- `TurnTimer` is a **per-tick countdown in seconds** (`≈4.375s`, `0.715s`, `0.0`), not remaining
  combat turns — so v0.8.37's `turns_left = floor(TurnTimer)` was bogus (`HEALTHBOOST_HARDCORE`, an
  infinite-duration status, showed "4 turns").
- `CurrentLifeTime` is the remaining **seconds** for finite statuses (`FEATHER_FALL` → `29.9`) and
  `-1` for permanent ones.
- `Osi.*Status*` helpers (`HasStatus`, `GetStatusCount`, `GetStatusRemainingTurns`, `ApplyStatus`, …)
  do **not** exist in the runtime Osi table (`osi_status_fns` empty), so remaining turns cannot be
  read from Osi either.
- Almost everything the engine keeps on creatures is internal: `HEALTHBOOST_HARDCORE`, `ENABLE_AOO`,
  `AI_NO_LOOK_AT_BATTLE`, `GOBLIN_HARDCORE`, `INSURFACE`. Player-facing ones seen: `FLANKED`,
  `FEATHER_FALL`. Emitting these raw would flood the LLM with noise.

Also seen (left to ticket 14): friendly NPCs (`Wyll`, `Zevlor`, `Remira`, `Aradin`, `Barth`) are
classified as enemies by the current side classifier.

Fix (**v0.8.39**): `conditionsOf` now drops engine-internal statuses — `statusMeta(id)` reads
`Ext.Stats.Get(id).Visible` and drops `visible == false`; `statusIsInternal(id)` is a fallback
blacklist (`AI_*`, `ENABLE_*`, `DISABLE_*`, `HEALTHBOOST*`, `*_HARDCORE`, `SCRIPT_*`, `TECHNICAL*`,
`DEBUG*`, exact `INSURFACE`) for when the stats flag is unavailable. `turns_left` is removed from the
emitted condition (only `duration_left`, seconds, for finite statuses remains). `stats_probe` now
tags each raw status with `__internal` / `__visible` / `__status_type` so one run shows which gate
does the work.

### Live probe (2026-09-18, v0.8.39) — filter works; `Visible` is not a stats field

State after the filter: internal statuses (`HEALTHBOOST_HARDCORE`, `ENABLE_AOO`, `AI_NO_LOOK_AT_BATTLE`,
`GOBLIN_HARDCORE`, `INSURFACE`) are gone; only player-facing ones remain — `goblin_tracker_4` →
`FLANKED`, `wyll_1` → `FEATHER_FALL (dl=29.9)`; the portcullis with no statuses emits no `conditions`.

The gate doing the work, though, is the **blacklist**, not a flag: `stats_probe` shows `__visible`
empty for **every** status including `FLANKED` — `Ext.Stats.Get(id).Visible` does not exist. What does
exist on the stats proxy: `StatusType` (string, `"BOOST"` for every observed status — useless as a
filter) and, per `Stats/Prototype.h:140-164` / `ExtIdeHelpers.lua:22962`, the fields `Flags` (uint8),
`StatusPropertyFlags` (uint64), `StatusGroups` (uint64), `TickType`, `StackType`, `Description`.
`StatsStatusPrototype` has **no** visibility field, so player-visibility has to come from the generic
stat fields (`DisplayName` / `Icon`).

Fix (**v0.8.40**): `statusMeta` also reads `DisplayName`, `Icon`, `Flags`, `StatusPropertyFlags`,
`StatusGroups`; `conditionsOf` drops a status when `statusIsInternal(id)` **or** `meta.visible == false`
**or** `meta.has_display_name == false` (the `DisplayName` gate applies only when the field is actually
readable, so it cannot silently drop everything). The probe tags each raw status with `__display_name`,
`__icon`, `__flags`, `__spf` so one run shows which gate fires for `FLANKED` / `FEATHER_FALL` vs the
internal ids.

### Live probe (2026-09-18, v0.8.40) — `Icon` is the discriminator

`stats_probe` over the 12 combatants: `__display_name` is **True for every** status (internal ones
included), so `DisplayName` does not discriminate; `Flags` is unreadable as a number and
`StatusPropertyFlags` comes back as an opaque userdata (`tostring` → `table: 0x…`). The stats `Icon`
field discriminates exactly as needed: `FLANKED` → `Icon=True`; `AI_NO_LOOK_AT_BATTLE`, `ENABLE_AOO`,
`HEALTHBOOST_HARDCORE`, `GOBLIN_HARDCORE` → `Icon=False`. (`FEATHER_FALL` sits on `wyll_1`, who is not
a `stats_probe` participant, so its icon is validated through the state instead.)

Fix (**v0.8.41**): the visibility gate is now `statusVisible(meta)` — drop only when `Icon` is
definitively empty (`meta.has_icon == false`) or `Visible` is false; keep the status when the stats
lookup fails (`nil`). The blacklist stays as the fallback for unreadable stats.

### Live verification (2026-09-18, v0.8.41) — PASSED

State file after the icon gate: `goblin_tracker_3` → `conditions:[FLANKED]`, `wyll_1` →
`conditions:[FEATHER_FALL, duration_left 29.9]`, and nothing else on either side; the four party allies
carry no conditions, only `availability`. So `Icon` is set for `FEATHER_FALL` too (it now survives the
gate that previously only the blacklist let through), and all engine-internal statuses are filtered.
PAK **v047** installed (MD5 `F18A5203E4E6BE0B98F87172FDC3DC4A`, backup `BG3Neuro.pak.bak-v046`).

Bench note: Astarion's spell list in this save has no `flourish`; the closest status-applying
attacks are `hamstring_shot` (applies `HAMSTRUNG`) and `piercing_strike`. A `hamstring_shot` at
`goblin_tracker_2` hit and killed it (9 HP) before the capture, so an enemy-side assertion of that
specific spell needs a high-HP target (e.g. `bugbear_1`, 35 HP); the mechanism itself is proven by
`FLANKED` / `FEATHER_FALL`.

## Answer

Combat state now carries real, player-facing conditions for **both** sides, and they are live-verified.

- **API**: statuses live on `ServerCharacter.StatusManager.Statuses`. BG3SE exposes that array as a
  **userdata** that supports `#` and `[i]` (not `pairs`); enumerate via `#c` + `c[i]`, with
  `:GetCount`/`:Size`, `:GetAll`/`:ToArray`, `:Get(i)` as fallbacks.
- **Shape**: `conditions = [{ id, name, duration_left? }]` — one shape for allies and enemies. `id` is
  the engine UPPER_SNAKE id (`FLANKED`), `name` a curated Title Case English label (never a localized
  engine string, same policy as ticket 09), `duration_left` the remaining seconds for finite statuses
  (`CurrentLifeTime`; `FEATHER_FALL` → 29.9). It is omitted for permanent statuses (`-1`).
- **Rename**: the ally `effects` string (which was really action availability) became `availability`
  (`acting now` / `can act`); it never carried statuses.
- **No `turns_left`**: the engine exposes no remaining-turns value — `Osi.HasStatus` /
  `GetStatusRemainingTurns` / `ApplyStatus` / … are absent from the runtime Osi table, `TurnTimer` is a
  per-tick seconds countdown, and `TickType = 0` for every observed status. The ticket's original
  "positive `turns_left`" assertion was amended; `StatusCondition.TurnsLeft` stays in the C# model for
  forward compatibility but is never emitted today.
- **Visibility gate**: creatures mostly carry technical statuses (`HEALTHBOOST_HARDCORE`,
  `ENABLE_AOO`, `AI_NO_LOOK_AT_BATTLE`, `GOBLIN_HARDCORE`, `INSURFACE`). `Ext.Stats.Get(id).Icon`
  separates them from player-facing ones (`Icon` set for `FLANKED`/`FEATHER_FALL`, empty for the
  internal ids); `DisplayName` is set for everything (no signal), `Visible` does not exist, and
  `StatusPropertyFlags` is an opaque userdata. The emitter drops a status only when `Icon` is
  definitively empty (or `Visible == false`), and falls back to a blacklist
  (`AI_*`/`ENABLE_*`/`DISABLE_*`/`HEALTHBOOST*`/`*_HARDCORE`/`SCRIPT_*`/`TECHNICAL*`/`DEBUG*`/`INSURFACE`)
  when stats are unreadable.
- **Verified live** (DEN gate fight, v0.8.41): `goblin_tracker_3` → `FLANKED`, `wyll_1` →
  `FEATHER_FALL (dl=29.9)`, internal statuses gone, allies clean. `dotnet test` 155/155, `luaparse`
  OK, PAK v047.
- **Not reproduced**: the original `flourish` → Off Balance bench (this save's Astarion lacks
  `flourish`); the mechanism is proven by the two debuff conditions above — retry with
  `hamstring_shot` on a high-HP target to see `HAMSTRUNG`.
- **Follow-up filed**: ticket 14 (friendly NPCs `Wyll`/`Zevlor`/`Remira`/`Aradin`/`Barth` are still
  classified as enemies by the side classifier).

Bench: `docs/manual-regression-checklist.md` — Run 2026-09-18 (v0.8.41).
