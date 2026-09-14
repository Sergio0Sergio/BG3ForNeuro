# bg3-neuro-followups — post-review bucket

Tracked: 7 tickets produced from the two-axis code-review of `HEAD` -> working tree (docs translation + honest combat economy + language-independent aliases). The two cross-cutting defects found there were fixed before commit; everything else lives here.

Tracker: local markdown (`.scratch/<effort>/`), conventions of `issue-tracker-local.md`.

## Status
- [ ] 01-bonus-legacy-ba-spend — open (blocked by bench)
- [ ] 02-movement-manual-cost — open (blocked by bench; map over-claims)
- [ ] 03-attack-candidate-narrowing — open
- [ ] 04-enqueue-seam — open
- [ ] 05-alias-statslug-fallback — open
- [ ] 06-docs-consistency — open
- [ ] 07-duplication-smells — open

## Fixed before commit (not tickets)
- auto `insertAtFront` now uses `detectIsPlayer` (ServerCharacter) instead of `actor:find("Player")` — `executeCast`.
- empty TODO "manual BA spend on legacy fallback" removed from `executeBonusAction` (dead block) — its real behavior gap became ticket 01.