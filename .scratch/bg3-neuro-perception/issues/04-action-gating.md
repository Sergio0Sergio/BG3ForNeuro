# 04 — Gating actions by perception (honest refusal)

Type: grilling
Status: resolved
Blocked by: 03

## Question

Determine how perception gates **actions** (decision Q6 = b), not just emission.

Sub-questions:

- **Which actions** are gated: `cast_spell` (by target), `attack_entity`, `move_to_target`/`move_to_entity`, `loot`, `interact_with`, `travel_to`? What about targetless actions (`end_turn`, `rest`)?
- **Refusal code and message**: the name (`no_perception`?) and the text in the style of the existing honest refusals (`no_spell_slot`, `no_action_point`, X1).
- **Where the barrier sits**: the mod (authoritative, ground truth) + C# router (mirror over the state for a clear message before sending). Separation of responsibilities.
- **Positional AoE**: a point outside perception but with entities on it — make a decision or explicitly defer to "Not yet specified".
- **Borderline**: a `known` (not `visible`) target — action allowed or refused? The party is always known — not gated.

## Deliverable

- Contract section on gating: the action × rule list; codes/messages; where the check happens (mod/router).
- C# router updates/tickets if needed (create child tickets if the spec already allows).

## Verification

- For every gated action a live refusal scenario is reproducible.
- The refusal does not break existing successful paths (honest-economy regression).

## Claim (2026-09-20)

Captured for the session. Plan: 1) inventory of the current gates in the C# router and in the mod, 2) the "action × rule" matrix under the binary model, 3) decision on the refusal code and separation of barriers, 4) a child ticket for the mod layer.

## Answer

**Decision: in the binary model perception already gates actions at the router; only the message semantics and the mod layer are needed.**

### What was found in the code

- The C# router **already rejects** an action referencing an entity absent from the emitted state (`TargetMissing`): `ValidateTarget` (move_to_target/attack_entity, `ActionRouter.cs:563`), `ValidateCastTarget` (cast_spell target_id, `:461`), `ValidateExplorationTarget` (move_to_entity/interact_with/loot, `:232`). In the binary model "in state ⇔ in view" — meaning **the perception gate at the router is already done by construction**.
- `travel_to` uses `state.Regions` (`:286`) — a curated disclosed list of waypoints, not entities, so it is not a perception gate.
- The `TargetMissing` code — Channel A (instant refusal before the game), the message rewritten for the perception rule: "…only act on entities the mod currently reports (party, objects, combatants) — they are exactly what you can see…" (dictionary §6.5 style, English).
- A new `ErrorCode.NotPerceived` is **not introduced** (user decision: reuse `TargetMissing` — zero behavior change, compatibility, minimal surface).

### "Action × rule" matrix (v1)

| Action | Target | Perception gate (router mirror) |
|---|---|---|
| `attack_entity` | enemy | must be in the `enemies` roster (combat reveals everyone) → otherwise refusal |
| `cast_spell` (+`target_id`) | enemy/ally | must be in `enemies` ∪ `allies` (party buffs are valid, trap v0.8.56 §§16/18) → otherwise refusal |
| `move_to_target` | enemy/ally | must be in `enemies` ∪ `allies` → otherwise refusal |
| `move_to_entity` / `interact_with` / `loot` | object | must be in `objects` → otherwise refusal |
| `bonus_action` (main_target) | enemy | **mod** (the router has no mirror; in combat the target is in the roster) → mod-side refusal in 04b |
| `use_item` (target) | enemy | **mod** (likewise) → 04b |
| `end_turn`, `rest`, reaction, dialog | none | not gated |
| `travel_to` | region | not gated — curated disclosed list |
| positional AoE (`position`/`coverage`) | point | **not gated in v1**: no entity reference; a "blind" AoE is unlucky, not a knowledge leak |

- **The party (`allies`) is never gated** — always visible/known. This includes casting on allies and moving to allies.
- **The "known (not visible)" borderline is removed by construction**: the binary model (ticket 03) — entities are either in the state (visible) or not; there is no third state.

### Separation of barriers

1. **C# router (Channel A, mirror)** — the main UX barrier: refusal immediately, without going to the game, with a clear "not in view" message. Accuracy = the emitted state. Already implemented; this session's change = the message.
2. **Mod (authoritative)** — repeats the gate at execution time: the target must be in the mod's current emission set (party ∪ emitted this tick) → otherwise an honest refusal. Protection against a stale router mirror and paths that bypass the state. **→ child ticket 04b (Lua + bench).**
3. `feasible` (engine mechanics: range/LOS/statuses/AP) — as before, in the mod, on top of the perception gate.

### Not yet specified

- Positional AoE on an invisible point: a "point is in view" check would require the B module (camera/fog) — deferred; in v1 we take it as is.
- `bonus_action`/`use_item` router mirror — if we decide to mirror, it will be added to 04b based on the mod-layer bench results.