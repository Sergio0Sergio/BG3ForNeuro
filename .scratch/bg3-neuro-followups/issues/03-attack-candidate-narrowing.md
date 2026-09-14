# 03 — Attack candidate narrowing (ticket 01 resolution)

Type: follow-up (code-review)
Status: open
Blocked by:

## Finding

Honest-economy `issues/01-weapon-spell-candidate.md` (resolved) established that of the current `attackCandidates` only two are real — `Target_MainHandAttack` (melee) and `Projectile_MainHandAttack` (ranged); the other four (`MainHandAttack`, `MainHandRangedAttack`, `Projectile_MainHandRangedAttack`, `Target_MainHandRangedAttack`) have 0 entries in the stat index. The resolution said "the `pendingCasts` default (`MainHandAttack`) should be replaced with the actually selected spell."

Code still loops all six candidates (BG3Neuro.lua `executeAttack`, ~2440-2459) and keeps the phantoms as fallbacks; the melee/ranged discriminator (`TargetRadius`/`IsMelee`) was validated for a single actor but not applied to pick the primary candidate.

## Fix proposal

- Resolve the actor's weapon: melee → `Target_MainHandAttack`, ranged → `Projectile_MainHandAttack` (discriminator from Brawl Pick.lua: `TargetRadius`/`IsMelee`).
- Try the resolved candidate first, keep the loop as a tolerant fallback (or trim phantoms if a bench shows they never match).
- Replace the `pendingCasts` default `"MainHandAttack"` with the actually selected spell/stat.