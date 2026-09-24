# 07 - Unknown spell is not rejected on the honest path: hanging running:true

Type: bug
Status: verified (v0.8.61, live 2026-09-21)
Blocked by: -

## Symptom (live, v0.8.60, 2026-09-21, id `reg8_refuse`)

`cast_spell` through the file bridge (without the App/C#-router) with a name that is not in the
caster's book: `{ "spell_name": "wish", "target_id": "poc_player_cleric" }`, cleric's turn
(Shadowheart) → `result_reg8_refuse.json` stays `{ "running": true,
"success": true }` forever — the action **is not finalized**, no refusal arrives.

Expected: an honest refusal `no_spell` (as on the legacy `use_osi_spell` path,
`mod/BG3Neuro/BG3Neuro.lua:4443` — `"no_spell: <name> is not in the caster's book"`),
and as the C# router does it (`ActionRouter.ValidateCast` validates the name before the mod).

## Evidence

- `prevalidate_latest.json`: `sid="wish"`, `los_1=1`, `verdict="pass"` — the pre-validation
  honestly checks only range/LOS, but NOT book membership.
- `cast_debug.json`: `spell = { Prototype:"wish", OriginatorPrototype:"Target_wish",
  SourceType:"Osiris" }`, `castOptions = [IgnoreHasSpell, IgnoreCastChecks,
  IgnoreSpellRolls, IgnoreTargetChecks, Forced, Immediate]`, `queue=osiris`.
- `cast_queues_65709f18-…_0ms.json`: `OsirisCastRequests` **size=1, not drained**.
- `resource_snapshot_reg8_refuse_before.json` was written, `_after` — **not**:
  execution never reached `CastSpell`, so the result was not finalized.

## Root cause (hypothesis)

`executeCast` on the honest path does not check the caster's book (unlike `executeAttack`,
where `knownSpellCandidates`/`Osi.HasSpell` exist, `:4852-4866`, `:4431-4446`). The name
resolves into a synthetic spell (`SourceType=Osiris`) and is force-pushed with
`IgnoreHasSpell` → the engine silently does not execute → `CastSpell` does not arrive → the pending hangs.

In production the C# router cuts unknown names off earlier, so the bug is not visible through the App;
the direct mod path/bench is what gets hit.

## Fix direction

On the honest path, before enqueue, check the book (`knownSpellCandidates` or
`Osi.HasSpell(actor, sid)`) and on a miss return
`false, nil, "action_failed", "no_spell: <name> is not in the caster's book"`
(same code as `:4443`). Optionally — a timeout for the hanging pending, so the result
is guaranteed to finalize.

## Repro

```powershell
$env:BG3NEURO_DATA='{"spell_name":"wish","target_id":"poc_player_cleric"}'
powershell -File "$env:TEMP\opencode\drive_action.ps1" -Id reg8_refuse -Name cast_spell
# then read result_reg8_refuse.json → running:true forever
# and cast_debug.json / cast_queues_*.json in
# %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\BG3Neuro\
```

## Fix (v0.8.61, 2026-09-21)

A single **book guard** was added in `executeCast` (`mod/BG3Neuro/BG3Neuro.lua`) right
after target pre-validation and BEFORE any cast executor (shared by the honest and legacy paths):

- candidates `{ spellName, "Projectile_"..spellName, "Target_"..spellName }` are checked
  via `Osi.HasSpell(actor, sid)` (the lazy resolver is warmed up with `pcall(function() return Osi.HasSpell end)`
  before the loop, each call wrapped in `pcall(function() return Osi.HasSpell(actor, sid) end)`);
- no match on a successful read (`probed and not bookHit`) → honest refusal
  `action_failed` → `"no_spell: <name> is not in the caster's book"` (the same code as on the legacy path);
- **fail-open**: if `Osi.HasSpell` is unavailable/reading failed (`probed == false`) — we do NOT refuse.

The duplicate legacy `bookHit` block (former lines ~4431–4446) was removed — the check is now
a single one. The mod was bumped to `v0.8.61`; `luaparse` → `PARSE_OK` (237 nodes).

**Build/install (2026-09-21):**
- build tree: `%TEMP%\opencode\v092_build` (copy of v091 + 4 lua from the repo);
- PAK: `%TEMP%\opencode\BG3Neuro_v092.pak` (88501 bytes), `MD5 = aac0b9104d0c672db0d2b7b096ce0983`,
  `paktool2 list` → all 6 entries start with `Mods/BG3Neuro/`, `get BG3Neuro.lua` == repo filehash;
- installed: `…\BG\Mods\BG3Neuro.pak` replaced, `MD5` in **both** `ModuleShortDesc`
  (`ModOrder` + `Mods`) of `modsettings.lsx` updated; backup — `%TEMP%\opencode\modsettings.backup.20260921_173221.lsx`.
- `heartbeat.json` after launch: `version: 0.8.61` (the PAK was picked up).

## Live verification (v0.8.61, 2026-09-21, combat save)

1. **Negative (bug closed):** `cast_spell { spell_name:"wish" }` (Tav's turn) →
   `result_t07_wish.json` **finalized immediately**:
   `{ "success": false, "error_code": "action_failed",
   "error_detail": "no_spell: wish is not in the caster's book" }` — without `running:true`.
   The osiris queue is untouched (the request is not pushed at all).
2. **Fail-open (valid cast not broken):** `cast_spell { spell_name:"fire_bolt",
   target_id:"goblin_tracker_2" }` → the friendly name resolved into `Projectile_FireBolt`
   (`cast_debug.json`), the cast went through: final `success:true`, the economy
   `resource_snapshot_t07_firebolt_{before,after}.json`: **ActionPoint 1.0 → 0.0**
   (BonusAction 1.0, slots — unchanged).
3. **Pipeline alive after the refusal:** `heartbeat.json` fresh (age ~1 s, seq growing),
   `cast_debug.json` `queueSize=0`, the last queue file contains only fire_bolt.

## Context

Found during §9.5 regression after enabling the perception filter (see
`docs/manual-regression-checklist.md`, section "Run 2026-09-21 (v0.8.60…)").