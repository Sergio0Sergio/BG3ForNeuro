# 19 — AoE cast_spell with empty coverage has no autonomous targeting

Type: task (design + implement + live bench)
Status: ready-for-agent
Blocked by: none

## Question

`cast_spell` with an AoE spell and no `target_id`/`coverage`/`position` passes
router validation trivially but nothing picks the impact point, so the §9.5 item
"AoE with empty coverage → autonomous target from CoverageAuto" cannot pass.

## Findings (2026-09-19, code reading, v0.8.55 / App HEAD `91e6735`)

- Router (`ActionRouter.ValidateCast`): target optional; if absent + `spell.Aoe > 0`
  + `coverage` given → validates against `CoverageAuto.BestAoECenter`. If coverage
  absent too → passes with no position injected. `ValidateTarget` ignores
  `cast_spell` entirely.
- Router ALSO requires `actor == TurnActor` (`WrongPhase` otherwise) — group-turn
  casting via stack is refused; AoE bench needs the caster's own turn.
- `CoverageAuto.BestAoECenter(caster, enemies, range, aoe)` returns
  `AoECoverage(CenterX, CenterY, Covered)` — **no Z coordinate**, but the mod's
  position path (`pos.x/y/z`, `Osi.UseSpellAtPosition`) needs one. Z source
  undecided (caster `position_z`? ground raycast? `0`?).
- Mod side (`executeCast`): targetless + positionless Zone cast behavior unverified —
  likely honest refusal or hang; needs a probe once the router injects a position.

## Design direction (not decided)

1. Router: when `spell.Aoe > 0` and no target/coverage/position → compute
   `BestAoECenter` over enemies, inject `position {x, y, z}` (resolve Z), proceed.
2. Decide Z source first (blocks implementation).
3. Bench: Gale `Zone_Thunderwave` on clustered enemies via stack; assert damage in
   next state + AP/slot deduction via the ticket-18 machinery (action + L1).

## Verification

- AoE via stack with empty coverage → damage visible in next state, resources
  deducted, result `success:true` over WS.
- Record in `docs/manual-regression-checklist.md` (§9.5 AoE box).
