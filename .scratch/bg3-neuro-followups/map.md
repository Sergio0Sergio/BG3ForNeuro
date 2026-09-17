# bg3-neuro-followups — post-review bucket

Tracked: 7 tickets produced from the two-axis code-review of `HEAD` -> working tree (docs translation + honest combat economy + language-independent aliases). The two cross-cutting defects found there were fixed before commit; everything else lives here.

Tracker: local markdown (`.scratch/<effort>/`), conventions of `issue-tracker-local.md`.

## Status
- [x] 01-bonus-legacy-ba-spend — done (live bench: `Osi.UseSpell` spends NO BA/AP natively; `PartyIncreaseActionResourceValue` is a no-op for personal resources; public write set = `AddActionPoints`(AP) + `PartyIncrease…`(no-op) — no single-actor BA writer exists. Decision: enforce BA budget in-router on the legacy path, engine writer impossible). **Implementation verified live** (v0.8.30, PAK v036L legacy): legacy `bonus_action` #1 accepted + marked + logged, #2/#3 REFUSED `action_failed "Bonus action already used this turn (BA budget enforced in-router)"`; reset-on-`TurnStarted` code-verified, bench-pending (static save, turn never leaves Tav)
- [x] 02-movement-manual-cost — done (v0.8.29 live bench: honest path = budget CLAMP only, `m0` gate "No movement left" when pool 0; game drains Movement natively on scripted combat movement (9→0 verified), so no manual writer needed — PartyIncrease personal no-op stands disqualified; legacy fallback dash-equivalent `AddActionPoints(actor,-1)` gated by `forceLegacy`/`legacyStable`. Evidence: move 14m→clamped 9.4m, 2nd move rejected at Movement=0; PAK v035)
- [x] 03-attack-candidate-narrowing — done (executeAttack: 2 real prototypes, weapon discriminator, real pendingCasts default)
- [x] 04-enqueue-seam — done (options table, reason threading in all 3 callers; PAK EED60034)
- [x] 05-alias-statslug-fallback — done (already fixed in HEAD 7697f11: statSlug guards vs~=""/non-ASCII/"entity" -> nil, registerAlias falls back to slug(rawName))
- [x] 06-docs-consistency — done (spec §6.4b snapshot set, map over-claim, stale GetConfig claims, research/02 aspirational markers)
- [x] 07-duplication-smells — done (extracted knownSpellCandidates + honestEnqueue, characterPartyFlags boolean|nil decode, bonusCandidates trimmed to resolved AttackType-free set; PAK 5B4925F2)
- [ ] 08-enemies-faction-misclassification — open (state `enemies` includes allied NPCs `wyll_1`/`zevlor_1`/`remira_1`/`aradin_1`/`barth_1` and the object `overgrown_portcullis_1`; classifier at `BG3Neuro.lua:1673` uses `CombatTeam`, not a real hostility signal. Filed 2026-09-17 from the v0.8.34 verification run; `ready-for-agent`)
- [x] 09-ability-catalog-friendly-names — implemented v0.8.35 (state `spells[]` gain `name` (loca + curated fallback) and `cost` from `UseCosts`; `available_actions` advertises `cast_spell: [names]`; C# `ActionRouter` resolves friendly name → engine `spell_name`; Lua `executeCast` resolves defensively. Tests 94/94 in State; PAK v041 `3C1274B1…` built, not installed). Bench assertion pending (install v041 + restart app): `cast_spell {"spell_name":"flourish"}` spends one BA + Off Balance. `bonus_action` stays offhand-only (bonus-action abilities run through `cast_spell`).
- [ ] 10-action-count-test-drift — open (5 pre-existing test failures, unrelated to 09: `action_schemas.json` has **24** actions but `NeuroWebSocketClientTests` (4 asserts) and `RandyIntegrationTests:154` hardcode **21**. The extra 3 are debug/bench (`bench_snapshot`, `bench_party_increase`, `bench_use_spell`) — decide: exclude debug/bench actions from Neuro registration, or derive the expected count. Filed 2026-09-17; `ready-for-agent`)

## Fixed before commit (not tickets)
- auto `insertAtFront` now uses `detectIsPlayer` (ServerCharacter) instead of `actor:find("Player")` — `executeCast`.
- empty TODO "manual BA spend on legacy fallback" removed from `executeBonusAction` (dead block) — its real behavior gap became ticket 01.