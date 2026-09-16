# bg3-neuro-followups — post-review bucket

Tracked: 7 tickets produced from the two-axis code-review of `HEAD` -> working tree (docs translation + honest combat economy + language-independent aliases). The two cross-cutting defects found there were fixed before commit; everything else lives here.

Tracker: local markdown (`.scratch/<effort>/`), conventions of `issue-tracker-local.md`.

## Status
- [ ] 01-bonus-legacy-ba-spend — open (blocked by bench)
- [ ] 02-movement-manual-cost — open (blocked by bench; map over-claims)
- [x] 03-attack-candidate-narrowing — done (executeAttack: 2 real prototypes, weapon discriminator, real pendingCasts default)
- [x] 04-enqueue-seam — done (options table, reason threading in all 3 callers; PAK EED60034)
- [x] 05-alias-statslug-fallback — done (already fixed in HEAD 7697f11: statSlug guards vs~=""/non-ASCII/"entity" -> nil, registerAlias falls back to slug(rawName))
- [x] 06-docs-consistency — done (spec §6.4b snapshot set, map over-claim, stale GetConfig claims, research/02 aspirational markers)
- [x] 07-duplication-smells — done (extracted knownSpellCandidates + honestEnqueue, characterPartyFlags boolean|nil decode, bonusCandidates trimmed to resolved AttackType-free set; PAK 5B4925F2)

## Fixed before commit (not tickets)
- auto `insertAtFront` now uses `detectIsPlayer` (ServerCharacter) instead of `actor:find("Player")` — `executeCast`.
- empty TODO "manual BA spend on legacy fallback" removed from `executeBonusAction` (dead block) — its real behavior gap became ticket 01.