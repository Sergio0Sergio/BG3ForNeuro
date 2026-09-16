# Honest combat economy — Wayfinder Map

## Destination

An honest combat economy in code: base attacks, casts, and bonus actions go through `ServerCastRequest` (native AP/cooldowns), movement is deducted manually (before/after). The map's output is a **plan + a slice of facts**, ready to be executed in separate sessions on the owner's command.

## Notes

- The decision and communication language is Russian.
- Tracker: local markdown (`.scratch/<effort>/`), conventions of `issue-tracker-local.md`.
- Affected code: `mod/BG3Neuro/BG3Neuro.lua` — `enqueueCastRequest` (1580), `executeCast` (1992), `executeAttack` (2195), `finalizeCast` (1843), `available_actions` (1188).
- Spec: `BG3_Neuro_Spec.md` §6.3 (resources) / §6.4 (unified attack and spell pipeline).
- Charting decisions (Q1-Q6, adopted in the charting session):
  - Map form: **change in place** — polishing the existing code, not a new document.
  - Completeness: the honest pipeline covers attacks + casts + **bonus actions** + **movement cost**.
  - Fallback paths (`use_osi_spell`, manual `AddActionPoints(-1)`, `Osi.Attack`): remain alive under the `force_legacy` flag (Q2=b) — the honest path is the default, an emergency fallback is possible.
  - Readiness criterion (Q3): resource snapshots before/after the action in a live bench test; the fact is recorded in the ticket.
  - Map form (Q5): the map produces decisions and a plan; execution happens in separate sessions on command.
  - Movement (Q6, default): manually before/after via the resource pipeline; research will clarify the API.

## Decisions so far

- [01 — Weapon spell candidate](issues/01-weapon-spell-candidate.md): The main attack resolves via exactly two prototypes — `Target_MainHandAttack` (melee, SpellType=Target, IsMelee) and `Projectile_MainHandAttack` (ranged, SpellType=Projectile). Four names from the current `attackCandidates` are phantoms (0 in the stat index): `MainHandAttack`, `MainHandRangedAttack`, `Projectile_MainHandRangedAttack`, `Target_MainHandRangedAttack`. Two-handed = the same `Target_MainHandAttack`. Off-hand is a SEPARATE stat `OffhandAttack` (`Target_`/`Projectile_OffhandAttack`), granted by the engine only when there is a weapon in the off-hand; the `CastOffhand` option doesn't exist in SpellCastOptions of this version (confirmed on the bench, ticket 05). The melee/ranged discriminator is `TargetRadius`/IsMelee (Brawl Pick.lua). The `pendingCasts` default (`MainHandAttack`) should be replaced with the actually selected spell.
- [06 — Honest movement deduction (API)](issues/06-movement-ap-spend.md): `CharacterMoveTo`/`CharacterMoveToPosition` do not deduct AP (scenario mechanism; Brawl). `Osi.TransferActionResource` does not exist. The movement snapshot uses the `"Movement"` resource (meters, resourceLevel=0); writers available: `AddActionPoints` (AP) / `PartyIncreaseActionResourceValue` (party risk → bench test). There is nothing to "refund as extra" — the game deducts nothing for Osiris movement; the mod manages the distance itself. The deduction finalizes only in the movement-completion event callback.
- [02 — Resource snapshots as the criterion](issues/02-resource-snapshot-scheme.md): The v0.8.24 tool is implemented and confirmed on the bench. `attack_entity` on the honest path (ServerCastRequest) deducted **AP 1.0 → 0.0 (−1)**; BA/Movement/Reaction untouched — the "honest" criterion works. The snapshot is written before/after (`resource_snapshot_*.json`), all calls inside pcall. Bonus actions (dash `Shout_Dash`) are NOT in the spellbook, go to CastSpellFailed, and don't deduct BA → ticket 05 handles them with its own pipeline. `SpellBookCooldownsComponent` is userdata, Stringify fails; it was unpacked via `unwrapField`, cooldowns as a string (structural read — ticket 04/05).
- [03 — force_legacy flag](issues/03-force-legacy-config.md): HYBRID — the honest path is the default; a failure → auto-pickup of legacy for that call, after N=3 consecutive failures — persistent legacy until restart. One kill-switch for all paths (attacks/casts/bonuses); the per-action `use_osi_spell` stays on top. Storage: `ScriptExtender/Config.json` read at startup via `Ext.IO.LoadFile(..., "data")` + `Ext.Json.Parse` (implemented; `Ext.Mod.GetConfig` does not exist, config read manually — see spec §6.4a); counter in memory, reset on restart. Documentation in BG3_Neuro_Spec.md.
- [04 — Honest-path cast by default](issues/04-honest-casts-default.md): Players — honest path (already the default in v0.8.24), NPCs — Osiris (the split already exists in enqueueCastRequest). Auto `insertAtFront` on own turn (canAct/actingChar), the per-action flag remains an override. A failure for the hybrid of 03 = only an enqueue error; CastSpellFailed doesn't count (a valid in-game outcome). Fallback :2185 — to the hybrid. Finalization of pendingCasts/CastedSpell doesn't change.
- [05 — Bonus actions through the honest pipeline](issues/05-bonus-actions-pipeline.md): v1 = ONLY `offhand_attack` (the other 6 come later, the enum stays complete and isn't resized). The mechanism is the same `ServerCastRequest` in the honest enqueue with `bonusAction=true`, the stat **`OffhandAttack`** (no CastOffhand on MainHandAttack), `NoMovement` removed for the bonus, `Osi.HasSpell` guard; `isPlayer` — from ServerCharacter. The nativity of the BA deduction is CONFIRMED on the bench (BA snapshot −1), per-item diagnostics — the current SNAPSHOT_RESOURCES. A failed honest bonus feeds the shared hybrid counter of 03.

## Not yet specified

- 4 of 5 map tickets (01-05) are resolved and **executed** on v0.8.25 (on the owner's command); 06 (movement cost) is specified, backend pending (see followup 02 in bg3-neuro-followups):

  1. `force_legacy` in Config.json + reading via `Ext.IO.LoadFile(..., "data")` (first time in the mod; `Ext.Mod.GetConfig` doesn't exist) + the hybrid counter N=3 (ticket 03).
  2. `executeCast`: auto `insertAtFront` by canAct, fallback through the hybrid, failure=enqueue (ticket 04).
  3. Lua handler `bonus_action` → `offhand_attack` through the honest path with the `OffhandAttack` stat (ticket 05).
  4. The nativity of the BA deduction is confirmed on the bench by a BA −1 snapshot (ticket 05); no manual deduction was needed.

  `throw`/stealth/dialogue/trade/multiplayer/distribution — excluded from the map, but without combat economy.

## Out of scope

- `throw` (not_supported in v1)
- stealth mode (`toggle_mode: "stealth"`)
- auto dialogue selection (client autoselect)
- trade (buying/selling)
- multiplayer
- packaging/distribution/support for third-party users