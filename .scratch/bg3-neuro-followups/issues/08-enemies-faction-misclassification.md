# 08 — Combat state misclassifies allied NPCs (and a scripted object) as `enemies`

Type: task (state emitter)
Status: ready-for-agent
Blocked by: —

## Symptom

In the grove-gate combat the emitted `bg3_to_neuro.json` lists friendly/neutral entities under
`enemies`:

```
enemies (13): goblin_tracker_1, goblin_tracker_2, bugbear_1, goblin_tracker_3, barth_1,
              za_krug_1, goblin_brawler_1, overgrown_portcullis_1, worg_1, wyll_1,
              zevlor_1, remira_1, aradin_1
```

- `wyll_1`, `zevlor_1`, `remira_1`, `aradin_1`, `barth_1` are tiefling/grove defenders — **allies**, not enemies.
- `overgrown_portcullis_1` is a **door/object**, not a creature at all.
- Same class of bug seen in the 2026-09-17 earlier run and in this one (`zevlor_1` was even the
  first combat `turn_actor`, yet also sits in `enemies`).

Impact: `state.enemies` feeds target selection / distances for the app, so allies appear as valid
hostile targets and the object pollutes the list.

## Likely cause (verify)

`captureCombatState` classifies each participant at `BG3Neuro.lua:1673`:

```lua
local isAlly = isControlled or avatars[g] or partyFlag[g] or (team ~= nil and team == alliesTeam)
```

`team` is `TurnBased.CombatTeam` (`teamOf`, L1303) and `alliesTeam` is the party's own team
(L1607-1620). Everything whose team is not the party's is shoved into `enemies` — so a **separate
allied faction** (grove defenders) and any non-character combat object fall through as hostiles.

Open question: what exactly `TurnBased.CombatTeam` encodes (the combat GUID shared by everyone, vs
a per-faction team GUID). In the 2026-09-17 diagnostics the acting Astarion's `CombatTeam` was
`db9418f5-a4b6-883e-f490-0377a145e4e7`; if that value is shared by all combatants then the
`team == alliesTeam` branch cannot be what separates the two groups and the bug is elsewhere —
confirm before coding.

## Fix direction

- Treat an entity as an enemy only on a real **hostility** signal (e.g. the engine's
  hostile/attitude flag or an `Osi` relation query), not merely "different team from the party".
- Exclude non-character entities (no `ServerCharacter`/`Health`) from both lists, or list them
  under objects.
- Add a bench assertion: for the gate fight, `enemies` must contain only goblinoids/worgs and
  must not contain `wyll_1`/`zevlor_1`/`remira_1`/`aradin_1`/`barth_1`/`overgrown_portcullis_1`.

## Evidence

- `docs/manual-regression-checklist.md` — "Run 2026-09-17 (v0.8.34) — exploration → combat transition".
- Live `bg3_to_neuro.json` (IPC dir) during the gate combat, 2026-09-17.
