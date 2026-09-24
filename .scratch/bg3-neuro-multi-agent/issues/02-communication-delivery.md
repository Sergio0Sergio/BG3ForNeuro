# 02 — Communication delivery: per-agent actions and results

Type: research
Status: resolved (2026-09-23)
Sprint: bg3-neuro-multi-agent
Opened: 2026-09-23

## Question

How do two Neuro agents deliver actions and receive results over the current single-WS + single-file-bridge architecture, without breaking the single-slot file bridge?

Current facts (bench-verified):
- Incoming WS `action` carries only `{id, name, data}` (`NeuroWebSocketClient.cs:257-278`); `SessionInfo.CharacterId` (`:13`) is logged but never routes. No `agent_id` in `action/result` (`Messages.cs:30-42`).
- One command file `neuro_to_bg3.json` (`IpcPaths.cs:21-28`); parallel injects clobber each other (AGENTS.md rule, 2026-09-19 bench). One state file `bg3_to_neuro.json`.
- `DecisionLoop.OnActionRequested` dispatches fire-and-forget (`DecisionLoop.cs:209-227`), no queue/in-flight gate; single `_lastForcedContent` (`:31`).
- Mod polls only the single command file (`BG3Neuro.lua:86-98, 6672-6696`) and clears it after read (`clearInFlight`, `:6662`).

Design candidates to evaluate for FEASIBILITY against the file bridge and WS protocol:

1. **Transport `agent_id` into action data** (extend `{id,name,data}` with `data.agent_id`) and keep a single WS connection — the external Neuro server multiplexes two agents onto one socket (is that real, or does each agent own a socket?). Is `SessionInfo` able to carry two identities?
2. **Per-agent command/result files** (`neuro_to_bg3_<char>.json`, `result_<id>_<char>.json`) vs keeping the shared file with a serialization lock. The mod's file name for commands is hardcoded (`IpcPaths.CommandFile`) — changing it is a mod+router change, not just config.
3. **A queue** to serialize actions from both agents (single slot stays, ordering by turn); what happens to the second agent while the first's action is `running:true`?
4. **Force channel**: `DecisionLoop` can force only once (`_lastForcedContent`); can two agents share one force stream, or does each need its own state push? State is one file — split leads back to ticket 03 (state ownership).

## Constraints (do not rediscover — already proven)

- File bridge is single-slot; parallel file writes clobber (AGENTS.md:20).
- Mod reads only ONE hardcoded command filename; `action_<id>.json` is a trace copy, not read (spec `BG3_Neuro_Spec.md:118-119`, `DEVELOPER.md:80-81`).
- WS send is serialized by `_sendLock` (`NeuroWebSocketClient.cs:47,310-327`) — that serializes frames, not execution.

## Deliverable

A recommended delivery topology (which candidate, or combination), with the exact files/lines to change in C# and Lua to carry per-agent identity end-to-end, and a stated answer whether one WS connection can multiplex two agents or we need N sockets (and whether N sockets even fit the external Neuro server contract).

## Answer

**Verdict 1 — sockets: N separate WS connections, one per agent; multiplexing two agents into one socket is not possible.**

- The Neuro protocol assigns exactly one character to a connection at startup: `startup.data.session.characterId` ∈ `{neuro, evil}` with `displayName` (`SPECIFICATION.md:198-216`); the server selects the character by its own config at connection time (`VOICE_CHAT.md:137`: "which character a connection talks to is backend configuration"). One socket = one character/agent fork.
- The server is **natively built for several simultaneous connections**: `BEST_PRACTICES.md:22` — "Action names are scoped to the character and shared with any other integration connected at the same time" (registrations from several integrations coexist), and `VOICE_CHAT.md:135-138` describes "Neuro and Evil in one lobby" as an official scenario (each via "each game process connects on behalf of its own character"). That is, N sockets fit the server contract directly.
- The only server restriction — not "how many sockets", but "one action force at a time" (`SPECIFICATION.md:139-140`, `Unity/USAGE.md:165`): this constraint is **per channel**, and it also gives us the separation: each agent has its own force channel thanks to its own socket (question 4 → "each agent forces its own channel").

Our `NeuroWebSocketClient` is already structured as **one instance = one connection** (fields `_url/_game/_actions/_reconnectInterval` in the constructor, `:52-58`; its own `_ws`/`_sendLock`/`_cts`; `SessionInfo.CharacterId` is already read in `HandleStartupAck`, `:246-254`). One instance = one agent; the second agent = a second instance (same or its own URL). No multiplexing in the class.

**Verdict 2 — file bridge: candidate 3 (queue/serialization) in its pure form; per-agent files (candidate 2) are unneeded and harmful; candidate 1 is rejected together with the multiplex.**

| | Command write | Result write | Mod |
| --- | --- | --- | --- |
| Now | C# → `neuro_to_bg3.json` (`IpcPaths.WriteCommandFile:48-58`) | Lua → `result_<id>.json` (`BG3Neuro.lua:124`) | reads **one** file `NEURO_TO_BG3_FILE` (`:36, 89`), polls every `ACTION_POLL_MS` (`:33`), clears it right after reading (`clearInFlight:6662`) |
| Two agents | both C# agents write **to the same file** — a lock/queue is needed | `result_<id>.json` is already unique by id — **no conflict** | the mod stays **single-threaded single-slot**: it already executes one action at a time — that's its doctrine; it must NOT be changed |

Candidate conclusions:
- **Candidate 1 (`agent_id` in `data.action`) — not for the bridge, but for distinction.** The Neuro server's `action` has no agent — but the agent is known from the **client/socket instance** that raised the event (`Program.cs` subscribes to each `NeuroWebSocketClient`'s `ActionRequested` separately, `:71`). `agent_id` does not need to be swallowed into JSON — the identity lives in C#, and the agent is irrelevant to the mod (it needs `actor` from `data`/`actingChar`, which is already party-scoped). `SessionInfo` does not "carry two identities" — it is one per connection by construction.
- **Candidate 2 (per-agent files `neuro_to_bg3_<char>.json`)** — rejected: the mod reads one hardcoded file (`:36`); splitting the polling across N files means changing the mod, and the benefit is zero — the engine already executes one action at a time. Two files give no execution parallelism, only a race risk on the game side.
- **Candidate 3 (queue)** — **this is exactly the model**: the C# side serializes writes to `neuro_to_bg3.json` with a single writer thread. The second agent "waits for the slot" naturally: `DecisionLoop.WaitForExecutionResultAsync` (`:232-254`) already waits for `result_<id>.json` (until the `result_timeout_s` timeout); while the first agent is `running:true`/without a result, the second does not write to the same queue. This turns the bench rule "inject strictly serially" into code. One "action in flight" in the file — exactly like single-party today.

**Verdict 3 — result/attribution.** `result_<id>.json` is unique by id (each agent has its own `NeuroWebSocketClient` and its own id stream). The "id → which agent to return to" mapping is stored on the C# side: `DecisionLoop` has its own `_neuro` (`:24`) and `SendResultAsync` goes to the specific client (`:221,226`). Two `DecisionLoop`s ≠ one shared one — each has its own `_neuro` and `_lastForcedContent` (`:31`), so `_lastForcedContent` won't clobber each other (question 4).

**Verdict 4 — force.** One force channel per agent: each `DecisionLoop` has its own `SendForceAsync` to its own `NeuroWebSocketClient`. The server's "one force at a time" holds within a channel — and there is no cross-channel restriction. `_lastForcedContent` deduplication is per-agent, not global.

### Final topology (recommendation)

```
Neuro #1 (characterId=neuro) ──ws──▶ NeuroWebSocketClient#1 ──▶ DecisionLoop#1 ──▶ ActionRouter(request) ─▶ IpcPaths (single writer-lock) ─▶ neuro_to_bg3.json ─▶ BG3Neuro.lua (single-threaded poll)
Neuro #2 (characterId=evil)  ──ws──▶ NeuroWebSocketClient#2 ──▶ DecisionLoop#2 ──▶ (same) ActionRouter ──🔒 serialized──┘                                          │
```
- Two independent `NeuroWebSocketClient` instances (agent = instance).
- One shared `ActionRouter` (validation) + **a single writer thread** for `IpcPaths.WriteCommandFile` (SemaphoreSlim or a single-threaded queue; location — a shared writer in `Program.cs` / `DecisionLoop`).
- The mod is **unchanged** for delivery: one `neuro_to_bg3.json`, one poll, one-slot. `pollActions:6672-6696` untouched.
- For "who owns which character" — changes outside delivery, see ticket 03 (`agent→character` map, `actor` is already carried into `data`).

### Exact changes (if we go into implementation)

C#:
- `Program.cs:46-54`: create **two** `NeuroWebSocketClient` (+ a second `DecisionLoop`), subscriptions to `SessionStarted`/`ActionRequested`/`ConnectionStateChanged` per agent; `CharacterId` already distinguishes the agents (`NeuroWebSocketClient.cs:246-254`).
- `IpcPaths.WriteCommandFile` (`:48-58`): wrap in serialization (SemaphoreSlim/queue). Change nothing in signatures: `data` is already a JSON string, the command is one.
- `DecisionLoop.DispatchAsync` (`:215-227`): already per-agent via `_neuro`; ensure the validation-write and the result wait go through the shared writer-lock (or a single writer in Program.cs). `_lastForcedContent` stays per-instance.
- `Messages.cs/`ActionRequestedEventArgs`: optionally add `AgentId` — the identity is known from the event subscription/argument.

Lua / `mod/BG3Neuro/BG3Neuro.lua`:
- **No changes required** for delivery (the bridge stays single-slot, and the mod shouldn't even know about 2 agents). The action's character is already gated by the mod itself via `actor`/`actingChar` — character separation is ticket 03.

Sources: `neuro-sdk/API/SPECIFICATION.md:198-240` (startup/characterId, one force at a time), `BEST_PRACTICES.md:22,36` (multiple simultaneous integrations, force per channel), `VOICE_CHAT.md:135-138` (Neuro+Evil in one lobby — each via its own connection), `Unity/USAGE.md:165`, `NeuroWebSocketClient.cs:34-58,238-254`, `DecisionLoop.cs:24-31,209-254`, `IpcPaths.cs:21-58`, `BG3Neuro.lua:33-37,86-130,6662-6696`.