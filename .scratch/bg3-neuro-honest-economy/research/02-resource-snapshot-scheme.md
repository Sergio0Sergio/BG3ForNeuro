# 02 — Resource snapshot scheme (draft, honesty criterion)

Type: task
Status: draft (AFK draft; bench facts — HITL checklist)
Feeds: 04 "Moving casts to the honest path", 05 "Bonus actions", 06 (valid resourceName)

## 1. Purpose

The snapshot is an objective criterion of honest deduction: before and after the action we capture the combat-resource values the action affects and compare them. The fact "delta = expected cost" is recorded as proof of honesty in a live bench test.

What gets captured: personal resources (AP/BA/Movement/cooldowns), the party AP aggregate (the BonusAction factor), spell cooldowns.

## 2. File scheme

File: `RESULT_DIR/resource_snapshot_<action_id>_<phase>.json` (`<phase>` = `before` / `after`).

```json
{
  "schema": "resource-snapshot/v1",
  "action_id": "attack-7",
  "action": "attack_entity",
  "actor": "S_Player_Astarion_0e6090219-…",
  "phase": "before",
  "in_combat": true,
  "caster_turn": true,
  "resources_personal": {
    "ActionPoint": 3.0,
    "BonusActionPoint": 1.0,
    "ReactionActionPoint": 0.0,
    "Movement": 7.5,
    "WeaponActionPoint": 0.0,
    "SpellSlot": { "1": 2, "2": 1 }
  },
  "resources_party": { "ActionPoint": 4.0 },
  "cooldowns": [
    { "prototype": "Projectile_FireBolt", "remaining": 0 },
    { "prototype": "Target_MainHandAttack", "remaining": 0 }
  ]
}
```

## 3. Read API (verified in research 06, Osi.lua 983 symbols)

| Field | Call | Level |
|---|---|---|
| ActionPoint | `Osi.GetActionResourceValuePersonal(actor, "ActionPoint", 0)` | 0 |
| BonusActionPoint | `…(actor, "BonusActionPoint", 0)` | 0 |
| ReactionActionPoint | `…(actor, "ReactionActionPoint", 0)` | 0 |
| Movement | `…(actor, "Movement", 0)` (meters; `MovementPoint` does NOT exist) | 0 |
| WeaponActionPoint | `…(actor, "WeaponActionPoint", 0)` | 0 |
| SpellSlot 1..9 | `…(actor, "SpellSlot", level)` | 1..9 |
| Party AP | `Osi.PartyGetActionResourceValue(actor, "ActionPoint")` | — |
| Cooldowns | `Ext.Entity.Get(actor).SpellBookCooldowns` (spell cooldowns by prototypes) | — |

Rule: every call strictly inside `pcall`; on `nil`/error — the field gets the value `null` + a mark. `resourceLevel` of non-slot resources = 0 (otherwise `nil`).

## 4. Capture points (BG3SE is single-threaded — event points only)

> **Status (v0.8.28):** the `before` snapshot exists for `executeCast` (BG3Neuro.lua:3003), `executeAttack` (3392) and `executeBonusAction` (3585); the `after` snapshot is written for the honest cast/attack finalize (`finalizeCast`, 2837) and for the `Osi.Attack` one-shot fallback (3528). The movement points below are **planned/aspirational**, not implemented yet — aligned with followup 02 (movement manual cost) in `bg3-neuro-followups`.

- `before` — planned in dispatch (executeCast / executeAttack / `executeMoveToTarget` / `bonus_action` — the last three not yet all wired), AFTER `cancelActiveMove`, BEFORE the pipeline/movement starts.
- `after` — from the game's completion event, NOT `WaitFor`:
  - cast/attack: the `CastedSpell` / `CastSpellFailed` (finalizeCast) listener — implemented;
  - movement: planned via `EntityEvent` by `event == activeMove.event` (BG3Neuro.lua:2198) or `CharacterMoveToCancelled` (2181, currently a no-op ack).

On movement cancel/interruption (`cancelActiveMove`) the `after` snapshot is planned to be written in `CharacterMoveToCancelled` — **not implemented** (see followup 02).

## 5. What to compare (expected deltas)

| Action | Expected delta (honest) | Criterion |
|---|---|---|
| `attack_entity` (main attack) | `ActionPoint` −1 | after − before == −1.0 |
| `cast_spell` (enemy cast, FireBolt) | `ActionPoint` −1 (or the spell's cost from `Ext.Stats.Get(sid).UseCosts`) | after − before == −cost |
| bonus cast/`drink_potion` | `BonusActionPoint` −1 | after − before == −1.0 |
| `move_to_target` | `Movement` −≈meters traveled (see research 06 §5B; the game itself deducts nothing for `Osi.CharacterMoveTo`) | movement is a special zone: honest cost = deduction by distance (the "Honesty Criterion" decision from 04/05 or a separate ticket) |
| cooldown | for `cast_spell` — the spell has `remaining > 0` after the cast | a cast with an active cooldown is unavailable (`no_spell` validation) |

## 6. Notes

- Core resources are double (eoc::ActionResourceEntry.Amount, bg3se ActionResources.h); compare with `>= EPSILON`, not strict `==`.
- The `PartyGetActionResourceValue` party aggregate — for reference (the bonus/buffs factor), NOT a criterion.
- Bench run: the checklist in section 7 of ticket 02 (HITL); the actual values are recorded in the Answer by the owner.
- A cast on the honest path (04) must yield a delta of −1 natively (Source from PreparedSpells); if there's no delta — the pipeline is dishonest → that's the signal "fallback/force_legacy needed".

## 7. Bench-run checklist (HITL, owner)

1. The game is on the bench, combat is running, the turn belongs to Astarion.
2. Write out "before": `API.Command("…")` in the SE console or via the snapshot: AP, BonusActionPoint, Movement meters.
3. `attack_entity` with a sword at an enemy → wait for `CastedSpell` → capture "after": AP must drop by 1.
4. `cast_spell` FireBolt at an enemy → `after`: AP −1, FireBolt got a cooldown (remaining>0).
5. A second FireBolt in the same turn → is it really unavailable (`no_spell` / cooldown).
6. (`drink_potion`/bonus) → check whether BonusActionPoint drops.
7. `move_to_target` → capture Movement before/after (confirm whether it changes at all; the party semantics of `PartyIncreaseActionResourceValue` — leave as an open fact from ticket 06).
8. Copy the values into the Answer of ticket 02.