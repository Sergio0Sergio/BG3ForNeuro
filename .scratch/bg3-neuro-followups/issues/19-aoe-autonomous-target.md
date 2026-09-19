# 19 — AoE cast_spell with empty coverage has no autonomous targeting

Type: task (design + implement + live bench)
Status: resolved (2026-09-19)
Blocked by: none

## Decision (2026-09-19): Z = caster Z via mod fallback

- Router C# has no Z (`Combatant` carries only X/Y) → router injects
  `position {x, y}`; mod fills missing `pos.z` from the caster
  (`positionOf(actor)`, `executeCast`, v0.8.56).
- Implemented: `ActionRouter.FillAoEPosition` (after cast validation; explicit
  target/coverage/position win; empty coverage → honest `TargetNotInRange`) +
  4 unit tests (57/57 router, 160/160 full). PAK v063 (`AA1FF5EA…`) built.

## Blocker found live: state emits aoe=0/range=0 for Zone spells (fixed v0.8.57)
- Gale's `thunderwave` arrived as `aoe=0.0 range=0.0` → `FillAoEPosition` no-ops.
- Root cause: `spellRangeAndAoe` reads only `TargetRadius`/`AreaRadius`; Zone
  spells (Thunderwave: `Range "5"`, `Base "5"`, `Shape "Square"`, no radii) yield
  0/0. Verified against `Public/Shared/Stats/Generated/Data/Spell_Zone.txt`;
  other types checked (`Projectile_FireBolt` TargetRadius 18; melee symbolic
  `MeleeMainWeaponRange`; `Shout_Dash` no radii at all).
- Fix (v0.8.57): `Range`/`Base` fallback gated to non-Target/Projectile/Shout
  types (checked-in behavior for known types unchanged). PAK v064
  (`C877D8F1…`) built. Bench pending restart: Gale Thunderwave via stack → expect
  injected position + damage + AP/slot deduction.

## Mod side verified live (2026-09-19, v0.8.57 / PAK v064, gate scene)
- **(v98t1) Thunderwave, Gale → explicit position (215.3,31.7), NO z, file bridge**:
  `Zone_Thunderwave` via osiris queue (story 824), `force=False` (ground target —
  auto-force correctly stays off); **goblin_tracker_2 (9 HP) KILLED**
  (`DB_DiedInCombat` + `Died` event, gone from state enemies); AP 1.0→0.0 and
  L1 3.0→2.0 **spent natively** (no manual deduction ran — queue ground casts
  spend on their own). **Z-fallback from caster works** (z-less position accepted).
- Still open: (a) state `aoe`/`range` values on Gale's turn (emitter fix unverified
  live); (b) router `FillAoEPosition` E2E via stack (needs `turn_actor` == Gale —
  the router's strict `WrongPhase` rule blocks group-turn casting; file-bridge
  group casts work via the mod's `canAct`).
- Bench hygiene note: turn-chasing via `end_turn` gives enemies free hits on
  wounded allies (Remira 6/23, Barth 8/23) — prefer the user pinging Gale's turn.

## Resolution (2026-09-19)

- **Group-turn casting via stack** (found blocked, fixed v0.8.56, commit `18a36dc`):
  router required `actor == turnActor`; group co-actors got `WrongPhase`. Now allows
  exact `"can act"` / `"acting now, can act"` (exact-match — `"cannot act"` contains
  `"can act"`); the mod remains the enforcer (`canAct` + `not_caster_turn`).
  Tests: 3 new (allow/refuse-null/refuse-cannot) + book-delegation tests.
- **Book check delegated for group casts**: state carries the turn actor's book, so
  `ValidateCast` skips book/cooldown/slot verification when `actor != turnActor`
  (new `ValidateCastTarget(data, state, spell?)` split); the mod decides with honest
  errors. Turn-actor path unchanged.
- **Zone guard in mod**: targetless + positionless Zone → honest `no_aoe_target`
  instead of a `running:true` hang.
- **Live E2E (t99-7)**: Thunderwave, Gale (group co-actor) + explicit position
  (no z) via stack → FIRED, **goblin_tracker_1 killed**, AP 1.0→0.0, L1 2.0→1.0.
  Group rule + mod Z-fallback proven live.
- **State emitter fix (v0.8.57) NOT live-verified**: needs Gale's solo
  `turn_actor` (grouped in this save). Risk accepted as low (fallback gated to
  non-Target/Projectile/Shout; inputs proven from `Spell_Zone.txt`; checked-in
  behavior for known types byte-identical). Verify opportunistically in the next
  combat with a wizard turn (read `thunderwave` aoe/range from state).
- `FillAoEPosition` auto-inject itself: covered by 4 unit tests (pure function over
  state); live trigger needs a solo Gale `turn_actor` (grouped in this save —
  may never occur). Accepted: mod position path proven live twice (v98t1, t99-7).
- **Stale-binary lesson** (cost ~1h): `dotnet build` while App runs leaves
  `App\bin\Core.dll` stale (locked copy silently skipped) — every "broken" symptom
  was old code. Ritual in AGENTS.md: stop App → build → verify method strings in
  the App-bin dll → restart.

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
