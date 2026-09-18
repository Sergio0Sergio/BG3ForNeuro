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
