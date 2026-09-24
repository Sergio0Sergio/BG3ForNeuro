# 04b — Mod-side authoritative perception gate (honest refusal at execution)

Type: implementation
Status: resolved
Blocked by: 04, 03 (contract)

## Problem

The C# router gates the target against the emitted state (mirror, ticket 04). But between validation
and execution the world changes (the target left the field of view, the character died/stealthed) — a stale mirror
may let through an action the player physically did not see at execution time. In addition, the
`bonus_action`/`use_item` router does not mirror by target at all. An authoritative gate in the mod is needed.

## Task

- Maintain a current perception set in the mod: `party_guids ∪ emitted-this-tick` (the emitted
  entities are already known — the same set that is written into the state).
- Before executing an action with an entity target, check the target against the perception set; when absent —
  an honest refusal `action_failed` + `no_perception` + English detail ("target not in current
  perception set — it may be out of view; only act on entities the state reports").
- Do not gate: targetless actions (`end_turn`, `rest`, `travel_to`), positional AoE (ticket 04).
- The party is not gated (always in the set).
- Do not break `feasible` honest refusals (no_spell_slot/no_action_point and the like) — check order:
  perception gate → existing honest refusals → execution.

## Deliverable

- Lua edits to `mod/BG3Neuro/BG3Neuro.lua` (target handlers: attack, cast_spell, move,
  interact, loot, bonus_action, use_item).
- Live refusal scenario on the bench: a target in the state disappears from screen → a cached action
  rejected with `no_perception`.
- Regression: existing successful paths and `feasible` honest refusals are not broken.

## Verification

- Bench: a series of inject tests "target visible → ok", "target off-screen → no_perception", "party → ok".
- Cross-check with the router `TargetMissing`: both layers answer consistently in one scenario.

## Result (v082, 2026-09-20)

**Implemented in BG3Neuro.lua (04b):**
- `refreshPerceptionSet(state)` (globals `perceptionActors`/`perceptionObjects`) — rebuilds
  the perception set from the full build: allies + enemies → `actors`, emitted objects → `objects`,
  plus `partyAvatars()` always in both (the party is not gated). Called from `buildExplorationState`
  (every tick, before `return state`) and from `captureCombatState` (full combat build before writing).
- Gate in `executeAction` (after parsing data, BEFORE dispatch): mirror of the router matrix of ticket 04:
  `attack_entity/cast_spell/move_to_target/bonus_action/use_item` → `actors`;
  `move_to_entity/interact_with/loot` → `objects`. Targetless and positional AoE — not gated.
  Refusal: `action_failed` + `no_perception: target not in current perception set ...`.
  The PERCEPTION_GATE/target structure — inside the function's `do..end` (not top-level locals — we preserve the 200 limit).
  Perception symbols are global (like `build*`), so as not to hit the 200-local merge limit.
- Order: perception gate → existing honest refusals (canAct/AP/slots/Movement) → execution.

**Bench verification (exploration at the gate, v082, serial injects):**
- R1 `move_to_entity sword_spider_1` (visible object) → `running=true` (passed the objects gate).
- R2 `cast_spell firebolt` on `goblin_tracker_1` (visible, but objects category; cast=actors) →
  `no_perception` (mirrors the router: cast only for enemies∪allies).
- R3 `cast_spell guidance` on `tav` (party member) → perception PASSED, then the honest
  `not_caster_turn` (the "gate → honest refusal" order confirmed).
- R4 `move_to_entity` on the guid of a goblin behind the barricade (LOS=0, not emitted) → `no_perception`.
- SE log without Lua errors (no FAILED/attempt).

Locals 199 (≤200 merge limit), parse OK, PAK v082 installed (MD5 1F0F921033F074BBBE24E83CD2AE0F50).