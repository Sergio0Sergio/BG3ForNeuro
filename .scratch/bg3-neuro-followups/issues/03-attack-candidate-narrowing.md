# 03 — Attack candidate narrowing (ticket 01 resolution)

Type: follow-up (code-review)
Status: resolved
Blocked by:

## Finding

Honest-economy `issues/01-weapon-spell-candidate.md` (resolved) established that of the current `attackCandidates` only two are real — `Target_MainHandAttack` (melee) and `Projectile_MainHandAttack` (ranged); the other four (`MainHandAttack`, `MainHandRangedAttack`, `Projectile_MainHandRangedAttack`, `Target_MainHandRangedAttack`) have 0 entries in the stat index. The resolution said "the `pendingCasts` default (`MainHandAttack`) should be replaced with the actually selected spell."

Code still loops all six candidates (BG3Neuro.lua `executeAttack`, ~2440-2459) and keeps the phantoms as fallbacks; the melee/ranged discriminator (`TargetRadius`/`IsMelee`) was validated for a single actor but not applied to pick the primary candidate.

## Fix proposal

- Resolve the actor's weapon: melee → `Target_MainHandAttack`, ranged → `Projectile_MainHandAttack` (discriminator from Brawl Pick.lua: `TargetRadius`/`IsMelee`).
- Try the resolved candidate first, keep the loop as a tolerant fallback (or trim phantoms if a bench shows they never match).
- Replace the `pendingCasts` default `"MainHandAttack"` with the actually selected spell/stat.

## Answer

Implemented in `executeAttack` (BG3Neuro.lua, v0.8.28):

1. **Candidate set narrowed to the two real prototypes** `Target_MainHandAttack` (melee) and `Projectile_MainHandAttack` (ranged); the four phantoms from the old set (0 in the stat index per research 01) are gone — the loop is trimmed, not just reordered.
2. **Discriminator by the actor's equipment**: `Osi.HasMeleeWeaponEquipped(actor, "Any")` / `Osi.HasRangedWeaponEquipped(actor, "Any")` (both wrapped in pcall, one loose wrapper). Whichever matches decides the first candidate: melee → `Target_` first, ranged → `Projectile_` first. The two-name list stays as the tolerant fallback (unarmed / neither query true → `Target_` first). This is the same weapon-vs-stat discriminator Brawl's Pick.lua uses, expressed via Osiris queries instead of stat `TargetRadius`.
3. **`pendingCasts` default replaced** with the real prototype: `usedSid or "Target_MainHandAttack"` (old `"MainHandAttack"` was a phantom that could never match a `CastedSpell` event).
4. **Bonus cleanup on the `Osi.Attack` fallback path** (same function): the `pendingCasts` entry is now written only when a weapon spell was actually used (`usedWeaponSpell`). On `Osi.Attack` (one-shot, no `CastedSpell` event) we only snap resources + write the result — previously the phantom entry would linger and could spuriously match a later cast by the same caster.

`executeBonusAction`'s own `pendingCasts` default (`"MainHandAttack"`, line ~3621) left untouched: it's the offhand pipeline and its `usedSid` is always set on success (`OffhandAttack` stat), so the default is dead code there; narrowing it belongs to the bonus-actions ticket, not this one.

Syntax check (luaparse) passed; PAK rebuilt and installed (MD5 `195F1087...`). Live weapon-discriminator smoke on the bench is recommended (melee and ranged actor each issuing `attack_entity`), but no decision was deferred on it: the fallback order keeps behavior correct for both.