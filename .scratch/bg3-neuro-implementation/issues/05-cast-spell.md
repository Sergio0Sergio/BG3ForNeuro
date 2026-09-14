# 05: cast_spell (AoE coverage, resources)

**What to build:** Casting a spell from the known-spells list: Neuro casts a known spell by `spell_id` from the state (list from `SpellBook`), with an AoE target and coverage when needed. Range/AoE coverage is computed by a single code path shared with StateSerializer (CoverageAuto), so the state and the validator see the same thing. Resource honesty: a spell can only be cast if enough AP/charges/cooldown are available. A `throw` cast (throwing a spell/item) → `not_supported`.

**Blocked by:** 03 (combat loop), 04 (movement/attack as base).

**Status:** done

- [x] The state gives the list of known spells and their prerequisites (AP, charges, cooldown) — from `SpellBook`/`GetSpell`. → `SpellInfo{CastsLeft, OnCooldown, Slot, Range, Aoe}` + "charges left / on cooldown" render in `StateSerializer`.
- [x] `cast_spell` validates: whether the spell is known (`no_spell` + list of known spells), whether enough resources are available (cooldown/0 charges → `no_spell`), whether it is in range (unified coverage code via `CoverageAuto`). Violation → actionable failure (`target_missing`, `target_not_in_range` with the list of reachable/unreachable).
- [x] Cast executes in the game (channelled or instant), `running:true` + a final event for long ones. → Lua v0.4.0 `executeCast` via `ServerCastRequest` (CastOptions `FromClient/ShowPrepareAnimation/NoMovement`, `SourceType="Osiris"`), fallback `Osi.UseSpell(AtPosition)`; final — `CastedSpell`/`CastSpellFailed` → `running:false`. The truth also goes out through the next state (Channel B).
- [ ] Normalization spell-id (X5): the server spell id is matched against the Russian name in the state. → deferred: `SourceType="Osiris"` stub, the prototype name is used as-is until a real SpellBook extractor is introduced.
- [x] AoE: center/coverage selection is consistent between state and execution (CoverageAuto). → clean `CoverageAuto` module (single code path), deterministic `BestAoECenter` (candidate centers = target positions + centroid; the center must be within the caster's range).
- [x] End-to-end test: cast from the list with resources and a state check. → Randy E2E: known cast (action file + spent charge in the next force), unknown (`no_spell` without an action file), AoE coverage with an unreachable target (`target_not_in_range`).

**Summary:** 90/90 tests (was 71), build 0 warnings, 0 node processes after the run.