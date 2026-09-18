# 14 — Classify enemies by engine hostility (and skip non-character participants)

Type: task (state emitter)
Status: claimed
Blocked by: 08 (resolved)

## Decision (from ticket 08's research)

`research/08-enemies-hostility-relation-api.md` settled the two open questions. Do NOT re-derive:

1. `TurnBased.CombatTeam` is a **per-combat side/team GUID** — not the combat GUID (`Combat` /
   `EocCombatStateComponent.MyGuid`), not a faction. It's part of team-keyed turn order, so allied
   factions legitimately sit on different teams. **Remove it from the classifier** — it can never
   separate "party + allies" from hostiles.
2. Real hostility = **`Osi.IsEnemy(partyRef, participant)`** (complement `Osi.IsAlly`), the engine
   hostility evaluator; it reflects temporary/individual hostility, not just faction relations.
3. Non-character participants (doors, portcullises) are **items**: they have no `ServerCharacter`
   component. Filter them out before classifying; `Health`/`Stats`/`Data` are NOT safe discriminators.

## Change

In `captureCombatState` (`mod/BG3Neuro/BG3Neuro.lua`, classifier around L1673, per-participant loop
L1820-1867):

- Resolve a `partyRef` once: the acting controlled avatar's full GUID (the engine wants real
  characters, not aliases). Reuse the existing avatar/controlled detection.
- Per participant:
  1. **Skip** (or route to `objects`, not `enemies`) if `Ext.Entity.Get(g):GetComponent("ServerCharacter")`
     is nil — matches how `insertAtFront`'s `detectIsPlayer` already relies on `ServerCharacter`.
  2. `isAlly` = existing party signals (`isControlled`, `avatars[g]`, `partyFlag[g]`) **or** truthy
     `Osi.IsAlly(partyRef, g)`.
  3. Otherwise it is an **enemy** only if truthy `Osi.IsEnemy(partyRef, g)`.
  4. Otherwise neutral — do not put it in `enemies`; keep it out of both hostile lists (or in a
     neutral list if the schema gains one).
- Delete `teamOf`/`alliesTeam` usage from the classifier (and the now-dead `diag.teams`/`diag.allies_team`
  plumbing, or repurpose the diag to record the hostility verdicts for debugging).
- Guard every `Osi` call with `pcall` (the mod's convention) and fall back to the previous
  party-flag/avatar classification if `IsEnemy`/`IsAlly` is unavailable, so a missing API degrades
  instead of erroring.

## Runtime facts to confirm on the bench first (cheap, before finalising)

The research could not verify these from primary sources — the fix must tolerate either shape:

- Return shape of `Osi.IsEnemy`/`IsAlly`: `1/0` integer vs boolean. Use a truthy check
  (`r == 1 or r == true`) and log the raw type/value once.
- That `overgrown_portcullis_1` has no `ServerCharacter` (dump `GetAllComponentNames()` via the
  existing `stats_probe` diagnostic if needed).
- Whether `IsEnemy` reflects mid-combat `SetHostileAndEnterCombat` (the grove defenders may start
  neutral and turn hostile).

## Verification

- Static: `luaparse` 5.3 on the modified `BG3Neuro.lua`; Lua unit-ish checks are limited, so lean on
  the bench.
- Bench (gate fight, the reproduction case): `bg3_to_neuro.json` `enemies` must contain only
  goblinoids/worgs — specifically **not** `wyll_1`, `zevlor_1`, `remira_1`, `aradin_1`, `barth_1`,
  `overgrown_portcullis_1`; and `allies` must still contain `tav`, `poc_player_cleric`,
  `origin_astarion`, `poc_player_wizard`. Compare against the 2026-09-17 reproduction in ticket 08.
- Re-verify no regression in target selection (`targets_in_range`, `move_to_target` on a real enemy).

## Evidence

- Reproduction (2026-09-17, live IPC state): 14 "enemies" including 5 allies + 1 door.
- `research/08-enemies-hostility-relation-api.md` (§4 answers, §5 predicate, §6 bench steps).
- `mod/BG3Neuro/BG3Neuro.lua:1673` (classifier), `:1820-1867` (per-participant emit).
- Previous version bump precedent: mod version goes to `0.8.37`, PAK rebuild + install (game must be
  closed gracefully — `AGENTS.md`).

## Implementation (2026-09-18, v0.8.42, pending live verification)

`mod/BG3Neuro/BG3Neuro.lua`:

- **Removed** `teamOf` and the `CombatTeam`-based `alliesTeam`/`teamCache` plumbing from the
  classifier. (The remaining `CombatTeam`/`Combat` reads are the combat-GUID lookup in
  `captureCombatState` / `combatStateComponentOf` — a different concern.)
- **New helpers** (before `captureCombatState`): `entityIsCharacter(ent)` (non-nil
  `ServerCharacter`), `osiBool(ok, res)` (1/0 or true/false → boolean), and
  `hostilityOf(partyRef, g, diag)` → `"enemy" | "ally" | "neutral" | nil` (`nil` = Osiris
  unavailable/errored).
- **partyRef** = `actingClean` when it is a party avatar / controlled character, else the first
  participant that is one, else `actingClean` (best effort) — so the reference is always on the party
  side even when an NPC is acting.
- **Classify**: party signals (`controlled`/`avatars`/`partyFlag`) → ally (cheap fast path, no Osiris
  round-trip); otherwise `hostilityOf` → `enemy` / `ally` / `neutral`. `neutral` goes into **neither**
  list; `nil` (API unavailable) degrades to the previous behaviour (non-party ⇒ enemy).
- **Skip objects**: a participant without `ServerCharacter` (the portcullis) is not emitted at all,
  counted in `diag.skipped_non_character`.
- **Diagnostics**: `diag.party_ref`, `diag.osi_hostility`, `diag.hostility` (verdict counts) and
  `diag.hostility_raw` (per participant `isEnemy=<ok>/<val> isAlly=<ok>/<val>`), so one bench run
  answers the ticket's open runtime questions (return shape, door component, mid-combat hostility).

Version → 0.8.42; `luaparse` OK on both Lua files. C# schema unchanged.

### Live attempt (2026-09-18, v0.8.42) — allies still in `enemies`; cause not visible

State: `allies` = `tav`/`poc_player_cleric`/`origin_astarion`/`poc_player_wizard` (correct), but
`enemies` = 13, still including `wyll_1`/`zevlor_1`/`remira_1`/`aradin_1`/`barth_1` next to the 8
goblinoids/worg. `state_capture`'s result does not surface `diag`, so it was not visible whether
Osiris returned "enemy" for the tieflings or the call failed and the `nil` → "non-party ⇒ enemy"
fallback ran.

Fix (**v0.8.43**): `hostilityOf` now tries **both** hostility APIs (global `Osi` and `Ext.Osi`, when
either exposes `IsEnemy`) and **both** id forms for the party reference (the pure entity uuid and the
prefixed id `resolveActingCharacter` returns), returning the first decisive `enemy`/`ally` verdict —
covers the SE-version divergence in API location and id form without another guess. `stats_probe` now
also returns `out.osi_api` plus per-participant `entry.osi`
(`isEnemy_actingRaw` / `isEnemy_actingClean` / `isEnemy_host` / `isEnemy_ext` / `isAlly_host` /
`isCharacter`, each `ok|err/<value>`), so one run pins the working call and the `ServerCharacter`
case.

### Root cause found (2026-09-18, v0.8.43 probe) — `Osi.*` members are callable userdata

`stats_probe`'s `osi_api` now reports: `type(Osi)` = **userdata**, `type(Osi.IsEnemy)` = **userdata**,
and every per-participant call came back `<not a function>`. `Osi.*` members are **callable userdata
proxies** (`__call`), not Lua functions — so the guard `type(x) == "function"` is always false,
`hostilityApis()` returned nothing, and every v0.8.42/43 run fell into the `nil` → "non-party ⇒ enemy"
fallback (hence the 13 "enemies"). The mod already calls these proxies successfully elsewhere via raw
`pcall` (e.g. `pcall(Osi.EndTurn, …)`, `pcall(Osi.GetActionResourceValuePersonal, …)`).

Fix (**v0.8.44**): presence-only guard (`x ~= nil`) in `hostilityApis()` and in the probe's
`fmtCall`; the calls stay raw `pcall`, which handles the `__call` proxy. Side note for a future
ticket: `displayName` uses the same `type(Osi.GetDisplayName) == "function"` guard
(`BG3Neuro.lua:721`, `:941`), so it likely never takes the Osiris path either.

### Live attempt (2026-09-18, v0.8.44) — bare `Osi.<member>` indexing raises

`stats_probe` this time errored: `probe_error: [string "BG3Neuro/BG3Neuro.lua"]:1507: attempt to
call a nil value` — L1507 was `global_has_IsEnemy = Osi ~= nil and (Osi.IsEnemy ~= nil) or false`.
Meanwhile `state_capture` did not refresh the state file (`bg3_to_neuro.json` held a stale capture:
`actor=""`, `allies(4)`, `enemies(0)`), i.e. `captureCombatState` likely raised in `hostilityApis()`
too. Contradiction with v0.8.43, where `type(Osi.IsEnemy)` printed **userdata** without raising —
so the exact raising construct was still unproven.

Fix (**v0.8.45**): every access to an Osi proxy is now inside a `pcall` **closure** — not just the
call (`pcall(api.IsEnemy, …)`) but the indexing too (`pcall(function() return api[name] ~= nil end)`
and `pcall(function() return api.IsEnemy(ref, g) end)`). `hostilityApis()` uses `apiHasMethod(api,
name)`; `hostilityWithRef` wraps both `IsEnemy` and `IsAlly`. The probe was rewritten around a
`try(desc, fn)` helper that reports `desc=ok|err:<value>` **per expression** (`type(Osi)`,
`Osi.IsEnemy~=nil`, `Osi.IsAlly~=nil`, `Osi.IsCharacter~=nil`, `type(Ext.Osi)`,
`Ext.Osi.IsEnemy~=nil`, `Osi.GetHostCharacter()`) and per participant (`IsEnemy`/`IsAlly` for the
raw, clean-uuid and host-character refs, `IsCharacter`, `IsItem`) — so a single run names both the
raising expression and the working call. Version → 0.8.45 (`791ad90`), `luaparse` OK, installed as
PAK v051 (`49F3D2404FD4A8FAE3532E5BA07BD323`, backup `BG3Neuro.pak.bak-v050`).

**Not yet done:** the v0.8.45 bench run. Result will settle the ticket. If `IsEnemy` works and
returns truthy for the goblinoids/worgs only, and the 5 tieflings + portcullis drop out, close the
ticket per `## Verification` above (add `## Answer`, `Status: resolved`, tick `map.md`, append
`docs/manual-regression-checklist.md`, commit).
