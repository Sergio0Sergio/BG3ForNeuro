# BG3 Neuro multi-agent (2 Neuro + N humans) — Wayfinder Map

## Destination

Understand and specify what it takes for **more than one independent Neuro agent** to be online in the same BG3 session, each controlling its own party character, alongside human players. Target scenarios: **2 Neuro + 2 humans** (full 4-party co-op) and **2 Neuro + 1 human** (3-party). Deliverable: a research-backed answer — either a concrete multi-agent design (state/communication/ownership model) or a documented verdict that one of the scenarios is infeasible under current BG3/BG3SE constraints.

Opened: 2026-09-23, after ticket 28 (throw) was closed and all followups 01–28 resolved.

## Current architecture (baseline, bench-verified)

- **One agent per session, one party-wide state.** `Program.cs:46-54` creates exactly ONE `ActionRouter` + ONE `NeuroWebSocketClient` + ONE `DecisionLoop`. `DecisionLoop` has a single `_combatState` and single `_lastForcedContent` (`DecisionLoop.cs:30-31`).
- **One WS client, no agent id.** Incoming `action` carries only `{id, name, data}` (`NeuroWebSocketClient.cs:257-278`) — no author. `SessionInfo.CharacterId` (`:13`) is logged but never routes.
- **File bridge is single-slot.** One `neuro_to_bg3.json` command file, one `bg3_to_neuro.json` state file (`IpcPaths.cs:21-28`). Parallel injects clobber each other (AGENTS.md rule, bench-proven).
- **One acting character.** Lua `actingChar` is a single global latch (`BG3Neuro.lua:450, 505-517`); state builds around the turn leader / first party avatar. `actor?: string` is an executor alias (required when `controlledPartySize > 1`) but is party-scoped, not agent-scoped.
- **Shared turn already works** (`CanActInCombat`, `activeTurnEntities`, co-actor with `availability="can act"`) — the validation seam for "two Neuro characters in one turn window" already exists.
- **Multiplayer/multi-agent is currently Out of Scope v1** (`BG3_Neuro_Spec.md:653`; multple `.scratch` maps list it as excluded). No explicit "single agent" contract exists in the spec.

## Open (research) questions

See `issues/`:
- [x] 01-bg3-multiplayer-model — **resolved 2026-09-23**: один host-процесс держит двух Neuro; server-Lua управляет всеми партийными членами безотносительно «человек/neuro»; два процесса игры не дают второго server-мира и не нужны. Отличимость «человек vs Neuro» — через `ClientControlComponent` (ClientControl есть у перса, ведомого клиентом-человеком) + свой mapping `agent→character` (тикет 03). Turn/hostility — per-entity, движок не навязывает «один actor». Два «слота агента» = два WS-соединения с `characterId` `neuro`/`evil` (SDK SPECIFICATION.md:215). Client-контекст один на процесс — диалог/rest клики сериализуются (тикет 02).
- [x] 02-communication-delivery — **resolved 2026-09-23**: N отдельных WS-соединений (агент = экземпляр `NeuroWebSocketClient`, агент известен по какого экземпляра событие; мультиплекс в один socket невозможен — characterId назначается сервером на соединение). Файловый мост остаётся single-slot: C#-писатель сериализует запись в `neuro_to_bg3.json` (очередь); `result_<id>.json` уже per-id не конфликтует; мод НЕ меняется (один poll-файл, однопоточный). Per-agent файлы отклонены. Force — per-agent канал (свой `_lastForcedContent`+`SendForceAsync` в своём `DecisionLoop`).
- [x] 03-state-ownership — **resolved 2026-09-23**: fixed owned character per agent (config `agent→ownedAlias`), НЕ turn-floating; `availability="can act"` — вторичный гейт, не anchor владения. Один shared `bg3_to_neuro.json`; per-agent frame = C#-проекция `StateSerializer.ToMarkdown(state, ownedAlias)` из уже имеющихся `position_x/y/z` (per-agent files не нужны; spells остаются turn-actor в самих данных, честность co-actor — в моде через `canAct`). Mapping — в C# `ActionRouter` (dictionary agent→owned), мод не меняется. Criss-cross → новый `ErrorCode.NotYourCharacter` (Channel A). Exploration — та же проекция от owned `position_*`.

## Out of scope (this sprint)

- Implementing multi-agent code. This sprint was research + a spec amendment (both done).
- Networked BG3 multiplayer where Neuro drives both host and guest processes — local co-op/single-process model preferred unless research disproves it.
- Voice chat, camera control, trading — never in v1 (integration map).

## Status

- 2026-09-23: sprint created from the "2 Neuro + N humans" question; architecture baseline confirmed by three parallel codebase probes.
- 2026-09-23: ticket 01 resolved — process model verdict: ONE host process holds both Neuro characters; two game processes don't add a second server world. Human/Neuro distinction is ours (ClientControl + `agent→character` map), not the engine's. Next research: 02-communication-delivery (two WS = two `characterId`; single-slot bridge).
- 2026-09-23: ticket 02 resolved — transport verdict: N WS sockets (one per agent; agent known by which `NeuroWebSocketClient` raised the event; no multiplex possible). File bridge stays single-slot with a serialized C# writer-queue; `result_<id>.json` already per-id; mod unchanged. Force is per-agent channel. Next: 03-state-ownership.
- 2026-09-23: ticket 03 resolved — ownership verdict: fixed owned character per agent; ONE shared state file + C# projection (per-agent `ToMarkdown` over existing `position_*`); mapping in `ActionRouter`; new `not_your_character` code; mod unchanged. All three research tickets done — the multi-agent answer is feasible with a concrete design. Next: spec amendment.
- 2026-09-23: **spec amendment done** — `BG3_Neuro_Spec.md` §12 "Multi-Agent Reference Model (post-v1)" added (process/communication, state ownership, routing/validation, changes-vs-v1); single-agent v1 = `|agent→ownedAlias| = 1` special case, marked in §1.5/§10; `not_your_character` added to §6.5 Channel A. v1 contract untouched (additive). Sprint goal met: research + spec amendment.

## Sprint outcome

Feasible. Multi-agent is additive over the existing single-agent stack: N WS channels + one shared state file + C#-side ownership map and per-agent framing projection; the mod and the IPC file set remain unchanged. Full detail in the three issue answers and spec §12.