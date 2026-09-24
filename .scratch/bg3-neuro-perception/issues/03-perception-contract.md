# 03 — Perception contract: semantics and state schema

Type: grilling
Status: resolved
Blocked by: 02

## Question

Fix the **perception contract** — the exact semantics of the three-state and the form in which it travels in the state.

**Agreed basis (decision of ticket 02 — fork #1):** visibility is not one signal, but **two different sensors for two different functions**:

- **`visible` (emission) — the player's eyes (B):** player camera/fog. Camera frustum + fog-revealed zone + local occlusion. This is what is actually "on screen".
- **`feasible` (action gates) — engine mechanics (A):** `CanSee`/`HasLineOfSight`/statuses — what the engine uses to decide the feasibility of an action (being able to aim/attack/move). Window into ticket `04-action-gating`.

Sub-questions (decided on the basis of prototype 02):

- **Research question B (embedded in this ticket, one bench pass):** what of the camera/fog is available in client-Lua (`BG3NeuroClient.lua`, `Ext.Client`)? Is there a camera position/matrix and an "open zone" (fog of war)? **Fallback:** fog unavailable → `visible` = frustum + `HasLineOfSight` from the camera (documented approximation); if that is also impossible — the blind spot is fixed in the contract as a known one.
- **Research question A (same pass):** `Osi.StartSightEvents` on the party — does it bring `CanSee` alive in idle exploration? (Needed not for `visible`, but as confirmation that the A `feasible` gates can be honestly implemented outside combat.)
- **Transition semantics**: `visible → known`; what `last_seen` fixes (position on the last perceived tick); `known` in combat and in exploration — the same rules or different (in combat the engine knows more than the player sees); which of B/A serves what.
- **JSON schema**: the field (`perception`), the enum, the form of `last_seen` (`{x,y}`/`{x,y,z}`), where it lives (in each entity), how "the party is always known" is encoded; separately — the `feasible` field/rule for gates.
- **Entity coverage**: allies-NPCs, corpses, containers, doors — do all of them carry `perception`?
- **Memory**: the scene as a unit (decision Q10); what resets memory (location change, load, long rest).

### RESOLVED (2026-09-20, contract revision) — binary model, memory removed

User: "let's remove the `last_seen` position. Visible means visible. Not visible means not visible."

- `known`/`last_seen` **are not in v1**: a stale coordinate — a position where the entity no longer is (a marker on an empty spot + a reason to act on a nonexistent target + a "could have been nearby" leak).
- The emission gate is **binary**: on screen (B sensor) → emit with the current position (`perception="visible"`), not on screen → do not emit at all. Memory is an empty set → no scene resets needed.
- Combat: we always emit participants (the game reveals them via turn order and the tactical map — the B gate is off by construction), positions current.
- To be clarified in the sub-questions: the remaining transition/`last_seen`/memory items below — removed (verified: schema, coverage, memory updated in `spec.md` rev 2).
- Other contract items (two sensors, `feasible`, coverage, fallback B, research checklist) — as in `spec.md`.

## Deliverable

- Contract section in `spec.md` (`.scratch/bg3-neuro-perception/spec.md`, rev 2, binary model): semantics, schema, per-mode rules, coverage, fallback B, blind spots.
- Result of the research pass (camera-fog availability + `StartSightEvents`) — **deferred to the next bench** (see `## 8` of the spec): the contract does not depend on the result, only the implementation changes.
- `CONTEXT.md` glossary update — done (terms `emission`, `perception`, `visible`/`known`/`unknown`, `last_seen`, `party`); `known`/`last_seen` removed from v1 — the terms remain as a deferred vocabulary.
- ADR: not required (the binary model is a barely-reversible simplification toward honesty; see the Answer below).

## Verification

- The schema is unambiguous: the emitter can be implemented from it without additional questions. ✓ (`spec.md` rev 2)
- Edge cases covered: an entity appeared in and left LOS within one tick; an invisible entity in combat (silhouette) and outside combat (not rendered); "mechanics know, the screen does not" → `perception` (B, emission) vs `feasible` (A, gates). ✓
- Research facts: recorded as a checklist (`spec.md` `## 8`), the run — the next pass.

## Claim (2026-09-20)

Captured for the session. Plan: 1) down-level the research pass into the contract (no game this session — the paper part), 2) discuss/finalize the contract and schema sub-questions up to a `spec` draft, 3) a "what to verify on the bench" list as the task of the next pass (camera-fog in client-Lua, `StartSightEvents` idle).

## Answer

**Contract fixed** (`spec.md` rev 2), the ticket is closed. Summary:

1. **Two sensors for two functions** (decision of ticket 02): `visible` emission = B (player camera/fog), `feasible` gates = A (engine mechanics: `CanSee`/LOS/statuses).
2. **Binary emission gate, no memory** (session revision): `known`/`last_seen` are not in v1. Visible → emitted with the current position; not visible → not. Stale coordinates are impossible by construction.
3. **Definition of B = "the engine actually rendered it to the player"**: invisible outside combat is not rendered → not emitted; `IsInvisible` is not used as a visibility signal (trap of 02).
4. **Combat** — the B gate is off by construction: combat participants are always in `state.enemies` (the game reveals them via turn order + the tactical map), positions true; an invisible participant — a shimmering silhouette at the true location, emitted as `visible`.
5. **`seen_by` removed** (that was the "lie"). Rev 2 addition on the bench (v0.8.62+, followup `23-remove-seen-by.md`): the `perception` field is **also not emitted** — binary emission = the very fact of presence in `state` (verified in live acceptance P2); coordinates always current.
6. **Non-visual channels** (noise/smell in exploration): there is no honest sensor in BG3SE → documented blind spot; potential "presence without position" — not in v1.
7. **Left for the bench** (`spec.md` `## 8`): camera-fog availability in client-Lua (B implementation), `StartSightEvents` idle (A implementation), flicker debounce, confirmation that "combat reveals all participants".