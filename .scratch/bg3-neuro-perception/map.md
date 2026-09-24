# bg3-neuro-perception — map: honest perception (fair perception)

Tracker: local markdown (`.scratch/<effort>/`), per `docs/agents/issue-tracker.md` → "Wayfinding operations". This map is an **index**: decisions live in the tickets, here only a summary + link.

## Destination

**Spec of honest perception**: the mod emits a state containing only what the party has perceived, and the router honestly refuses actions on an unperceived target. Behavior contract for Neuro: the agent never gets knowledge of the ambush (entities through fog/walls/stealth).

Scope after grilling: **exploration + combat**; **all entities** under a single principle; **the party is always known**; the representation — **binary model v1** (decided at the contract, ticket 03): `visible` — on screen → emitted with the current position; not visible → not emitted at all; **memory/`known`/`last_seen` removed entirely** (a stale coordinate lies); perception gates both **emission and actions** (honest refusal).

## Notes

- Domains: BG3SE mod (Lua, `mod/BG3Neuro/BG3Neuro.lua`) + C# router/App (`src/BG3Neuro.Core`, `ActionRouter`).
- Session skills: `grilling` + `domain-modeling` (HITL), `research`/`prototype` (by ticket type).
- Principles: X1 "honest refusal" (`CONTEXT.md`), honest economy (ticket 18, `bg3-neuro-followups`).
- Starting facts of the hole (2026-09-20, exploration save at the gate):
  - `seen_by = "player"` is **hardcoded** (`BG3Neuro.lua:2743`), there is no real visibility check;
  - `scanNearbyObjects` (`:2722`) filters only by type + `EXPLORE_MAX_DISTANCE`;
  - in combat `state.enemies` = all `CombatState` participants (see `:2450`) without perception;
  - live: 18 hostile entities (goblins/bugbears/sappers) sat in `objects` before the ambush cutscene.
- Session rule: **one ticket per session** (exception — research).
- Tracker notes: claim = `Status: claimed`; resolve = `## Answer` + `Status: resolved` + a line in "Decisions so far".

## Decisions so far

<!-- index: one line per closed ticket -->

- **perception-signal-api** (research, ticket `01`, 2026-09-20): there is no single "party perception" signal — **composition** is needed. Primary candidate `Osi.CanSee` (+`CanSeeCached`) OR over the party; geometry separately — `Osi.HasLineOfSight`; explanatory statuses — `IsInvisible`/`IsInvisibleByScript`/`HasActiveStatus("SNEAKING"|"INVISIBLE")`; engine reference `brawl_Utils.isVisible` (statuses, without geometry). Shroud — map fog, not perception. Server viewshed deferred. → open question to the prototype (semantics/client-server/cost). See `issues/01-perception-signal-api.md` + `research/01-perception-signal-api.md`.
- **perception-emitter-prototype** (prototype, ticket `02`, 2026-09-20): draft filter live. **In combat raw Osi predicates suffice** (`CanSee` is alive, everything honestly `visible`). **In exploration — no:** `CanSee=0` everywhere, `IsInvisible`≈"hidden from the camera", `HasLineOfSight` — collision without cone/back; the ambush leaked as `known`, known NPCs falsely cut. **Decision on fork #1:** two different sensors — **emission `visible` = the player's eyes (camera/fog)**, **action gates `feasible` = engine mechanics** (`CanSee`/LOS/statuses). Fallback: camera-fog unavailable in client-Lua → frustum+LOS from the camera; otherwise — documented blind spot. Emitter cost 11–15 ms/tick. See `issues/02-perception-emitter-prototype.md`.
- **perception-contract** (grilling, ticket `03`, 2026-09-20): contract fixed — **`spec.md` rev 2, binary model**. Two sensors: emission = B (camera/fog, "the engine rendered it to the player"), actions = A (mechanics). **Memory removed**: `known`/`last_seen` are not in v1 (a stale position lies); visible → with the current position, not visible → not. Combat: participants always in `state.enemies` (the game reveals via initiative + map), an invisible participant — silhouette at the true location. `seen_by` removed. Non-visual channels (noise/smell) — documented blind spot. For the bench: camera-fog in client-Lua, `StartSightEvents`, debounce. See `issues/03-perception-contract.md`.
- **action-gating** (grilling, ticket `04`, 2026-09-20): **the perception gate at the router is already done by construction** — the router rejects actions on an entity absent from the emitted state (`TargetMissing`); in the binary model "in state ⇔ in view". The refusal code is NOT changed (user: reuse `TargetMissing`), only the default message is tuned to the perception rule. Matrix: entity targets are gated by the mirror (attack — `enemies`, cast/move — `enemies`∪`allies`, interact/loot — `objects`, the party never); targetless (`end_turn`, `rest`), `travel_to` (curated disclosed), positional AoE — not gated (v1). **Mod-side authoritative perception gate** — child ticket `04b` (Lua + bench; target ∈ party ∪ emitted-this-tick → refusal `no_perception`). See `issues/04-action-gating.md`, `issues/04b-mod-perceptual-gate.md`.
- **cast-projectile-location** (prototype, ticket `06`, 2026-09-21): "projectile at the caster / cast not aimed there" in game target casts. **Decision:** building the request is NOT a bug (vs the reference `tinybike/Brawl` Actions.lua — structurally identical: FromClient, Ext.Entity target, field_A8); mechanism #1 = **missing range/LOS pre-validation**: out of radius the engine rejects the request target (CastSpellFailed) and **picks the nearest candidate itself** (live: witch bolt from 22 m with an 18 m radius → "beam into a corpse"). Mechanism #2 (in-range: sneak→at the caster, bless→on self) — open, requires a clean controlled bench. **Mod change:** pre-validation `no_range`/`no_los` like brawl (distance by spell.Range/weapon.Range + `Osi.HasLineOfSight`), positional casts NOT gated; `success:true`/`cast_failed` treated as "the event executed/not", not as a hit verdict. See `issues/06-cast-projectile-location.md`.
- **acceptance-and-bench** (grilling, ticket `05`, 2026-09-20): acceptance plan (paper) fixed under the binary model — scenarios P1–P8 "input → expected outcome" (ambush not emitted / LOS / disappearance / combat roster / refusal on an invisible target / invisible in frame / party / AoE point), proof = snapshots + SE log + serial injects, **cost threshold ≤ 20 ms/tick** (median of 5 runs), criteria "spec ready for implementation" (research §8 → tickets B/A + 04b green). Draft lines added to `docs/manual-regression-checklist.md` (section Perception). Execution — the next bench pass. See `issues/05-acceptance-and-bench.md`.
- **acceptance-executed** (bench, ticket `05`, 2026-09-21, v0.8.60): acceptance **executed on the bench**. P2/P3 clean (distance control: 14 entities at 17.5–51.9 m `<60` ⇒ drop by LOS, not by range); P4/P7/P8 confirmed, P1/P5 (v082). **P6 closed in v2** (2026-09-21, v0.8.63, PAK v095, followup `24-invisible-b-gate.md`): the B gate cuts `INVISIBLE`/`SNEAKING` (raw `StatusMachine`; excl. `TRUESIGHT`/see-invisibility ≤9 m) — live `masked=["Ogre Brute"]`, `objects` 18→17, remove → 18. **§9.5 regression green** (roster, turn loop `tav→aradin→astarion→za_krug→remira→cleric`, healing `healing_word` BA+L1 HP 9→13, attack AP 1→0). **Cost under the threshold**: exploration `exploreLoop` med **11.20 ms** (n=336), combat `TurnStarted` med **9.51 ms** (n=25) — the former 23.4/38.5 ms (ticket 21) do not reproduce. Feed-back: an unknown spell is not rejected on the honest path → hanging `running:true`, ticket `07`. See `issues/05-acceptance-and-bench.md`, `issues/07-unknown-spell-stuck-cast.md`.
- **unknown-spell-stuck-cast** (bug, ticket `07`, 2026-09-21): `cast_spell` with a name outside the book is not rejected on the honest path — the mod force-pushes a synthetic spell (`SourceType=Osiris`, castOptions `IgnoreHasSpell,…`) into `OsirisCastRequests`, the queue is not drained, the `result` hangs with `running:true` forever. The `no_spell` refusal exists only on the legacy path (`:4443`) and in the C# router. **Fixed and verified live in v0.8.61** (2026-09-21): a single book guard (`Osi.HasSpell` over candidates, with resolver warm-up, fail-open) before any cast executor; `cast_spell wish` → instant `success:false, no_spell: …`, `cast_spell fire_bolt` → `success:true` (AP 1.0→0.0). See `issues/07-unknown-spell-stuck-cast.md`.

## Not yet specified

- Positional AoE under perception: a hit point outside perception, but with entities standing on it — how to behave (not gated in v1; the "point in view" check — after the B module).
- Router mirror for `bonus_action`/`use_item` targets (the mod gates for now; 04b will decide whether the router needs it).
- Memory/`known` (deferred from v1): if we bring back "remember what we saw", then WITHOUT stale positions — only the fact of existence (question: is it useful without a position).
- Cost of LOS/raycasts every tick with many entities; budget and cache.
- Detection/hearing model details (what exactly removes stealth, how noise/open-door affects it).
- How perception affects `turn_order`/initiative: whether to hide unperceived combat participants from the turn order.

## Out of scope

- Explored-map geometry / region fog (a separate layer later).
- Dialogue.
- Multiplayer per-player individual perception.