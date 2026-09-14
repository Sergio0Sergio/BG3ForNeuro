# 01 — Weapon spell candidate: main vs ranged

Type: research
Status: resolved
Blocked by:

## Question

When player base attacks ("weapon attack") go through the honest pipeline, which prototype spell should be chosen? In live tests, the strike landed as a ranged attack (`Projectile_MainHandRangedAttack` or an analog) even for melee weapons, because the candidate to use was picked from the caster's spellbook by `Osi.HasSpell == 1`. Decision: pin down the exact rule for choosing the weapon spell in the honest path — what "main attack" (main-hand) means, how to correctly distinguish melee from ranged, what to pick by default.

Facts the decision awaits:
- The candidate set `attackCandidates` in `executeAttack` is correct by name (whether there are missing variants like two-handed/dual weapons). Sources: stat-data `Ext.Stats`, the Brawl spec (weapon/combo), BG3-attack community docs.
- How BG3 names the "main attack" in the UI/journal vs the prototype name in the spellbook.
- Which prototypes the engine actually resolves as a base attack for melee and ranged.
- A live snapshot of the caster's `SpellBookPrepares.PreparedSpells` (e.g., Astarion on the bench) — a fact gathered AT THE EXECUTION STAGE via ticket 02 (the spellbook snapshot is part of the bench task ticket), not this research ticket.

Output: a spell selection rule based on stat docs; the spellbook snapshot of the target character is wired in from ticket 02.
## Answer

The vanilla engine resolves the main attack via exactly two prototypes: Target_MainHandAttack (melee, SpellType=Target, IsMelee, TargetRadius MeleeMainWeaponRange) and Projectile_MainHandAttack (ranged, SpellType=Projectile, TargetRadius RangedMainWeaponRange). Of the current `attackCandidates` set, four names are phantoms (0 results in the stat index): MainHandAttack, MainHandRangedAttack, Projectile_MainHandRangedAttack, Target_MainHandRangedAttack. Two-handed uses the same Target_MainHandAttack (no separate TwoHandedAttack exists), off-hand is encoded via the CastOffhand+BonusActionPoint:1 fields. Selection rule: weapon-melee → Target_, ranged → Projectile_ (the discriminator — TargetRadius/IsMelee — as in Brawl Pick.lua). The default in pendingCasts (BG3Neuro.lua:2297) is the phantom MainHandAttack; it must be replaced with the actually selected spell. Findings: research/01-weapon-spell-candidate.md