# Research 01 — Weapon spell candidate: main vs ranged

Type: research-findings
Status: done
Feeds: issues/01-weapon-spell-candidate.md

## Conclusion (spell selection rule in the honest path)

**There are exactly two canonical "base weapon attack" prototypes in vanilla data:**

- **Melee (main-hand):** `Target_MainHandAttack`
  - SpellType `Target`, WeaponTypes `Melee`, SpellFlags `IsAttack; IsMelee; IsHarmful; CanDualWield`
  - SpellRoll `Attack(AttackType.MeleeWeaponAttack)` (+ `CastOffhand[Attack(AttackType.MeleeOffHandWeaponAttack)]`)
  - `TargetRadius = "MeleeMainWeaponRange"`, `TooltipAttackSave = "MeleeWeaponAttack"`, `Sheathing = "Melee"`
  - `UseCosts = "ActionPoint:1"`, `DualWieldingUseCosts = "BonusActionPoint:1"`
  - Data: `// Main Hand Attack`, Description = «Make a melee attack with your equipped weapon.»
- **Ranged (main-hand):** `Projectile_MainHandAttack` — **this is a ranged attack despite the name**
  - SpellType `Projectile`, WeaponTypes `Ammunition`, SpellFlags `IsAttack; HasHighGroundRangeExtension; RangeIgnoreVerticalThreshold; IsHarmful; CanDualWield` (IsMelee **absent**)
  - SpellRoll `Attack(AttackType.RangedWeaponAttack)`
  - `TargetRadius = "RangedMainWeaponRange"`, `TooltipAttackSave = "RangedWeaponAttack"`, `Sheathing = "Ranged"`
  - `UseCosts = "ActionPoint:1"`; data: `// Ranged Attack`

**Rule:** choose between these two **by equipment/range**, not by their order in the list: melee weapon → `Target_MainHandAttack`, ranged → `Projectile_MainHandAttack`.

### Reliable melee/ranged discriminator (per stat docs)
Ranked by reliability:
1. `Ext.Stats.Get(sid).TargetRadius`: `MeleeMainWeaponRange` → melee, `RangedMainWeaponRange` → ranged, `ThrownObjectRange` → thrown. This is exactly how Brawl (Pick.lua) distinguishes base attacks (source completeness — the spellbook snapshot, see ticket 02).
2. `SpellFlags` contains `IsMelee` (only `Target_MainHandAttack` has it).
3. `TooltipAttackSave` = `MeleeWeaponAttack` vs `RangedWeaponAttack`; `WeaponTypes` = `Melee` vs `Ammunition`; `Sheathing` = `Melee` vs `Ranged`.

### Correctness of the current `attackCandidates` set
The current set (`executeAttack`, BG3Neuro.lua:2216-2218):
```lua
{ "MainHandAttack", "Projectile_MainHandAttack", "Target_MainHandAttack",
  "MainHandRangedAttack", "Projectile_MainHandRangedAttack", "Target_MainHandRangedAttack" }
```
**Of the 6 names, only 2 exist in vanilla SpellData.** In the bg3.norbyte.dev index (stat-data dump) there are **0 results** for:
- `MainHandAttack` (plain) — no such SpellData at all
- `MainHandRangedAttack`, `Projectile_MainHandRangedAttack`, `Target_MainHandRangedAttack` — phantoms
- `TwoHandedAttack` — none (see below)
- `OffHandAttack` — no separate prototype (see below)

This is exactly why the honest path fell into ranged in the live test: `HasSpell==1` matched `Projectile_MainHandAttack` (it's in everyone's spellbook — it's the hotbar base spell), and the name in `pendingCasts` is also a phantom (`"MainHandAttack"`, line 2297).

**Recommendation:** narrow the set to `{ "Target_MainHandAttack", "Projectile_MainHandAttack" }`, choose by weapon/`TargetRadius`; in `pendingCasts`, replace the phantom `"MainHandAttack"` default with `"Target_MainHandAttack"`.

## Facts on attack names/kinds

- **UI vs prototype:** in the UI/journal the attack is called "Main Hand Attack" (melee) and "Ranged Attack" (ranged). The prototype names are `Target_MainHandAttack` and `Projectile_MainHandAttack` (comments in the data: `// Main Hand Attack`, `// Ranged Attack`). Both are exported into custom hotbar slots (fixed hotbar slots contain both prototypes).
- **Two-handed weapons:** there's **no** separate prototype (`TwoHandedAttack`); per bg3.wiki "Main Hand Attack" covers "main hand (or in both hands, in the case of Two-Handed weapons)" — two-handed hits via the same `Target_MainHandAttack`.
- **Dual wield / off-hand:** there's no separate `OffHandAttack` SpellData in the index. The off-hand is built into the same prototypes via the `CastOffhand[DealDamage(Offhand...)]` + `DualWieldingUseCosts = "BonusActionPoint:1"` fields (the second attack for a bonus action). bg3.wiki has separate "Off-Hand Attack (Melee)/(Ranged)" actions (bonus action) — these are separate UI tools, not a base attack action.
  - **Refinement after the bench (v0.8.25):** the static stat-data index doesn't show `OffhandAttack` (search `name:OffHandAttack type:spell` → 0), BUT at runtime the engine grants the character the `OffhandAttack` spell (prototypes `Target_OffhandAttack`/`Projectile_OffhandAttack`) **only when there is a weapon in the second hand** — `Osi.HasSpell(actor, "OffhandAttack") == 1`, and an honest cast with this prototype natively deducts BonusActionPoint. The `CastOffhand` option doesn't exist in `SpellCastOptions` of this game version (valid values: IgnoreHasSpell..AvoidDangerousAuras, see ECS.inl). I.e., the engine resolves the off-hand via the second-hand weapon action (dynamic SpellData), not via a flag on MainHandAttack — for bonus_action the `OffhandAttack` stat is exactly what's used.
- **Unarmed/Throw:** the SpellRoll strings have `WeaponAttack`/`UnarmedAttack`/`ThrowAttack` markers (Brawl `Spells.lua: extraAttackSpellCheck`); a quick "weapon vs fist vs throw" discriminator. Not required for ticket 01 (base weapon attack).
- **The engine resolves "base attack"** by the weapon `TargetRadius`/weapon type: melee → `Target_MainHandAttack`, ranged → `Projectile_MainHandAttack`. Status overrides (for example, `TWN_DISTILLERY_OVERRIDE_MHA` references `Target_MainHandAttack`) confirm that the engine internally uses exactly these prototypes as the "main attack".

## Consistency with the BG3Neuro pipeline

- `finalizeCast` (BG3Neuro.lua:1843-1865) matches `spell == spellName` with paired handling of the `Projectile_`/`Target_` prefixes — so the prototype `Target_MainHandAttack`/`Projectile_MainHandAttack` in `pendingCasts[].spell` will correctly map to the `CastedSpell` event (5 arguments, see bg3se-lua-action-api.md §addendum SE v32).
- The research doc bg3se-lua-action-api.md (pp. 116, 295): for party members the `ServerCastRequest` path (§6a) is recommended with "weapon's attack spell (`Target_WeaponRange`-style data)" — i.e., the `Target_`/`Projectile_` prototypes; `Osi.Attack` — only for tests/enemies.
- The spellbook's source of truth is `SpellBook.Spells` (+ `SpellBookPrepares.PreparedSpells` for prepared casters), enriched via `Ext.Stats.Get(spellName)` (bg3se-lua-action-api.md pp. 286-287).

## Confirmation method

1. The stat-data index bg3.norbyte.dev: `name:MainHandAttack type:spell` → 0; `name:MainHandRangedAttack type:spell` → 0; `name:TwoHandedAttack type:spell` → 0; `name:Target_WeaponRange` → 0; `OffHandAttack` (generic) → 0; `Target_MainHandAttack` and `Projectile_MainHandAttack` → full SpellData dumps (the fields above). Searches confirmed on 13.09.2026.
2. bg3.wiki: "Main Hand Attack" (two-handed covered; melee 1.5m, extra reach 2.5m; links to Ranged Attack, Off-Hand Attack (Melee/Ranged)), "Attacks", "Weapon actions".
3. Brawl sources (tinybike/Brawl, `Brawl/Mods/Brawl/ScriptExtender/Lua/Server/`): Pick.lua — attacks distinguished by `spell.TargetRadius` (`MeleeMainWeaponRange`/`RangedMainWeaponRange`/`ThrownObjectRange`); Spells.lua — `extraAttackSpellCheck` by SpellRoll markers; Constants.lua — `MELEE_WEAPON_SLOT=3`, `RANGED_WEAPON_SLOT=5`, `MELEE_RANGE=1.5`, `RANGED_RANGE_MIN/MAX=1.5/18`, `SWEETSPOT=10`; Actions.lua — the path via `ServerCastRequest.OsirisCastRequests` with `Prototype/OriginatorPrototype`.

## Open questions (outside ticket 01)

- The exact behavior of `Osi.HasSpell(actor, "Projectile_MainHandAttack")` for a sword user (always 1 as a hotbar base spell?) — to verify at the execution stage with the spellbook from ticket 02.
- Which exact names arrive in `CastedSpell` for an attack in these versions (build v4.73.98.727, SE v32) — prototype or override-status — supported by the expectation from the addendum: the event arrives with the prototype name, and status overrides can replace the prototype for the duration of the cast (e.g., `TWN_DISTILLERY_OVERRIDE_MHA`). If an override fired, `CastedSpell` may report a `Target_MainHandAttack_Brewer`-like name — `finalizeCast` has no such match (only a caster-suffix match would work, and it would fire incorrectly). Noted as a risk for ticket 08 (error-resilience).

## Sources

- https://bg3.norbyte.dev/search?q=name%3AMainHandAttack%20type%3Aspell (0 results) and the other index queries above
- https://bg3.wiki/wiki/Main_Hand_Attack ; https://bg3.wiki/wiki/Attacks ; https://bg3.wiki/wiki/Weapon_action
- https://github.com/tinybike/Brawl (Pick.lua, Spells.lua, Constants.lua, Actions.lua — `ScriptExtender/Lua/Server/`)
- https://github.com/NellsRelo/bg3-schema/blob/main/stats/types/SpellData.md
- `E:\java_projects\BG3ForNeuro\mod\BG3Neuro\BG3Neuro.lua`: executeAttack (2195), attackCandidates (2216-2218), pendingCasts (2297), finalizeCast (1843-1865), listener CastedSpell (1965)
- `E:\java_projects\BG3ForNeuro\.scratch\bg3-neuro-integration\research\bg3se-lua-action-api.md`: pp. 106-117 (attack), 283-287 (spellbook source of truth), 289-312 (reliability matrix), 320-345 (SE v32 addendum)