# 03 — State ownership: per-agent frames and agent→character mapping

Type: research
Status: resolved (2026-09-23)
Sprint: bg3-neuro-multi-agent
Opened: 2026-09-23

## Question

How do two Neuro agents each receive "their own first-person frame" when the engine emits party-wide state, and how does the router know which agent owns which character?

Current facts (bench-verified):
- `bg3_to_neuro.json` holds ONE party-wide state: `turn_actor` = the current turn holder, `distance_reference` = `actingClean` (`BG3Neuro.lua:2575,2585`), `allies` = the whole party (`:2510-2573`), book/spells = the turn actor's. `state_capture`/`bg3_to_neuro.json` distances measured from the acting avatar (AGENTS.md:24, CONTEXT.md).
- Lua `actingChar` is one global latch (`BG3Neuro.lua:450,505-517`); free-roam acting = first party avatar (`buildExplorationState`, `:3321-3348`).
- Router validates executor against `TurnActor` (`ActionRouter.cs:342-363`) and party `Allies` (`:199-208`); `actor?: string` is an executor alias but has no owner.
- Shared turn already allows co-actors (`availability="can act"`, `ActionRouter.cs:350-363`).

Sub-questions:
1. **Per-agent actor model**: does each agent need a *fixed* owned character (agent A → Karlach, agent B → Astarion), or does ownership float with the turn (whoever's turn it is, that character belongs to "the acting agent")? Which matches the current single-agent semantics best and least?
2. **Per-agent state emission**: can ONE `bg3_to_neuro.json` serve both agents (each filters by its owned character from the same payload), or does the mod need to emit `bg3_to_neuro_<char>.json` per owned character? What does the serializer (`StateSerializer.ToMarkdown`, `StateSerializer.cs:51-171`) need to produce per-agent `## Turn`/identity lines? (`Turn: Karlach` vs `Turn: <your character> Karlach`.)
3. **Ownership validation**: where should `agent→character` mapping live — C# `ActionRouter` (a dictionary agent_id → owned alias, validated before dispatch) or the mod (the `actor` param gated to the agent's set)? Current `actor` validation touches `controlledPartySize` (`ActionRouter.cs:199-202`); how does that generalize?
4. **Criss-cross actions**: what should the router do when agent A asks to move agent B's character (refuse / re-route / let-turn-leader-decide)? Honest `action_failed` with which `error_code` (reuse `wrong_phase`? new `not_your_character`?) — spec §6/§9 error vocabulary (Channel A/B).
5. **Exploration mode**: free-roam `acting` = first avatar; with two agents, each should see itself first-person. Does `buildExplorationState` need per-owned-avatar frames?

## Deliverable

A recommended state-ownership model (fixed owned character vs turn-floating; single shared state file vs per-agent files) with the mapping layer placement, the minimum `StateSerializer`/Lua emission changes, and an ownership error-code proposal. Answer whether the existing shared-turn seam (`availability="can act"`) is the natural ownership anchor or a red herring for multi-agent.

## Answer

### 1. Actor model: FIXED owned character per agent (agent A → Karlach, agent B → Astarion). NOT turn-floating.

- Turn-floating ("whichever character's turn it is becomes 'the acting agent'") is exactly the **current single-agent semantics**: `actor?: string` is the executor alias the one Neuro picks, validated against `TurnActor`/`availability` (`ActionRouter.cs:342-363`). With two agents, floating would make both agents fight over the same `turn_actor` when a shared window opens — no ownership, no way to route. Floating is a red herring.
- Fixed ownership matches what the engine already lets us express: every party member is an independent entity with its own `position_x/y/z` (v0.8.58), its own `TurnBased` (so its own `availability`), its own spellbook bucket — verified in ticket 01 (per-entity turn/hostility). The shared-turn seam (`availability="can act"`, `ActionRouter.cs:350-363`) is **not** the ownership anchor: it only says "this character may act NOW" but says nothing about "which agent owns it". Ownership must precede it.

### 2. State emission: ONE shared `bg3_to_neuro.json` stays; per-agent framing is a C#-side projection. Per-agent files not needed.

- The engine payload already carries everything needed for per-agent geometry: every combatant and every exploration object has `position_x/y/z` (`BG3Neuro.lua:2547-2549`, `:2939-2941`), and `distance_reference` says whose frame it is (`:2585`, `:3397`). So a second file is redundant — the reader can recompute `distance` from `position_*` against its own owned character. This is the same rule as AGENTS.md:24 but projected, not remeasured in the mod.
- **Only `spells` needs per-agent work.** The spellbook is emitted for the turn actor (`buildCombatSpellsBlock(state, acting…)`, `:2610`) — with two agents in one window, agent B's `actor` ≠ `turn_actor`, and the C# router already skips spell validation for co-actors (`ActionRouter.cs:444-451`, v0.8.56). For honesty the mod already re-gates per-caster on `canAct` (`BG3Neuro.lua:4611-4620`). So the sharing seam stays as-is; per-agent book is NOT needed in v1 — the engine+mod already gate by caster.
- `StateSerializer.ToMarkdown` (`:51-171`) needs an `owned actor` parameter: `## Turn:` line becomes `Turn: Karlach` when the agent owns the current actor, `Turn: <NPC> Karlach`-style (i.e., `Turn: (not your character) Karlach`) when it is someone else's turn — so each agent sees whose window it is and who acts. Allied/enemy `distance` lines are recomputed from `position_*` by the C# projection; `distance_reference` is still emitted by Lua for debugging but the reader overrides it with its own `agent→ownedAlias`.

### 3. Ownership mapping lives in C# (ActionRouter), not the mod.

- `agent → character alias` is a **config-time fact** (which `characterId`/agent owns which party member), so it belongs in C#: `ActionRouter` gains an `agentId → ownedAlias` dictionary (or the router instance is per-agent). The mod does **not** learn about agents — it stays a dumb executor (`actor` param already party-scoped), consistent with ticket 02's "mod unchanged" verdict.
- The existing `actor` validation (`ActionRouter.cs:199-208`, `:337-341`) generalizes by narrowing the allowed set: in multi-agent mode, `actor` must equal the owning agent's `ownedAlias` (plus turn/`canAct` checks already there). Single-agent mode = current behavior (any controlled member).
- Placement: same layer as `ValidateAndDispatch` (`ActionRouter.cs:28-91`) — before phase checks, so ownership is rejected up-front.

### 4. Criss-cross actions: refuse with a NEW `not_your_character` code.

- Existing `wrong_phase` ("It is not your turn", `ErrorMapper.cs:69-70`) would falsely imply timing; a criss-cross is not a phase problem. Proposal: add **`ErrorCode.NotYourCharacter`** (validation Channel A) with actionable default `"You are playing Karlach, not Astarion — only act for your own character."` Add to `ChannelACodes` (`ErrorMapper.cs:17-29`). The personality detail ("play only your own") is a good actionable message per §6/§9 vocabulary.

### 5. Exploration mode: first-avatar acting is per-agent projected, same one file.

- `buildExplorationState` uses "first party avatar" as `acting` when free-roam (`BG3Neuro.lua:3341-3361`, `:3397`). With one shared file the C# projection recomputes `objects[].distance` and `allies[].distance` from the agent's owned `position_*`; `distance_reference` per agent is that owned alias. This gives each agent its own "first-person" exploration without a second Lua emission.

### Final recommendation

| Question | Verdict |
| --- | --- |
| Actor model | Fixed owned character per agent (config `agent→ownedAlias`), NOT turn-floating. Shared-turn `availability` stays a per-action gate, not an ownership anchor. |
| State emission | One shared `bg3_to_neuro.json`; per-agent frame = C# projection (`StateSerializer.ToMarkdown(state, ownedAlias)`) over existing `position_*`; per-agent files unnecessary. Water: spell list is turn-actor scoped, but co-actor honesty already handled by mod `canAct` gate. |
| Mapping layer | C# `ActionRouter` dictionary/instance; mod unchanged (dumb executor). |
| Criss-cross | Refuse: new `ErrorCode.NotYourCharacter` (Channel A) + actionable message. |
| Exploration | Same one file; C# projects `objects/allies` distances from owned `position_*`; free-roam acting frame is per-owned. |

### Minimum changes

C#:
- `StateSerializer.ToMarkdown(state, ownedAlias?)` (`:51`): `## Turn:` identity line + per-agent `distance` recompute from `position_x/y/z`; exploration similarly (`ToExplorationMarkdown`, `:211`).
- `ActionRouter` constructor/state: `agentId → ownedAlias` map; `ValidateAndDispatch` (`:28`) rejects `actor ≠ ownedAlias` with `NotYourCharacter` (multi-agent only; single-agent unchanged).
- `ErrorCode.NotYourCharacter` + `ErrorMapper` (`ErrorCode.cs:3-17`, `ErrorMapper.cs:17-29,53-78`).
- `Program.cs:46-54`: two agents → two `DecisionLoop`s each with its own `NeuroWebSocketClient` (ticket 02) passing its owned alias into `StateSerializer`/router.

Lua / `BG3Neuro.lua`:
- **No changes required** for ownership: `position_*`, `distance_reference`, `availability`, `turn_actor` already present; `canAct` gate already per-caster. (Optional: none.)

Sources: `StateSerializer.cs:51-171,211-332`, `ActionRouter.cs:28-91,199-208,337-363`, `ErrorCode.cs`, `ErrorMapper.cs:17-29,53-78`, `BG3Neuro.lua:771-785,2547-2549,2585,2610,2939-2941,3341-3361,3397,4611-4620`.