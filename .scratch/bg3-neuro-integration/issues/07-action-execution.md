# 07 — Action Execution Layer

Type: grilling
Status: resolved
Blocked by: 01, 02, 04, 05, 06
Depended by: —

## Question

Determine how the C# process sends commands back to BG3SE and receives the result:

1. **Execution loop**:
   - Neuro produces a decision (action name + data)
   - C# validates (JSON schema, target existence, spell availability)
   - C# sends the command through Named Pipe to the BG3SE Mod
   - BG3SE Mod executes the Lua API call (MoveTo, CharacterUseSpell, etc.)
   - BG3SE Mod returns the result (success/error + data)
   - C# sends the ActionResult to Neuro

2. **Timeouts**: How long to wait for a response from BG3SE? What if BG3SE doesn't respond?

3. **Execution errors**: What if the action is impossible (spell unavailable, target dead)?

4. **Concurrency**: Can multiple actions be executed simultaneously? (Research: is BG3SE Lua single-threaded?)

5. **Action Result for Neuro**: How to form the success/failure message? See BEST_PRACTICES.md: success: false with actionable error for retry.

See SPECIFICATION.md: action/result must be sent as fast as possible, before it happens in game.

## Answer

### Decisions (HITL)

- **X1 (dialogue)**: `select_dialogue_option` is executed via **`ClientAutoselectExecutor`** — client-side Lua context finds the option element in the dialogue window by `option_index` (= UI order), highlights it, and **clicks it itself**; the human presses nothing. (The `confirm` mode from the earlier version is collapsed: «highlight + manual Enter» ≡ «autoselect», a separate key is not needed.) Switch compatibility — the `dialogue.mode` flag in `config.json` (`"confirm"` is kept as an alias). If the client script is unavailable (no client context / server-side mod) → **fallback to `not_supported` + warning** — Neuro is never left without a communication channel. All runtime settings (including modes) live in the single `config.json` (see 01/03), read at startup.
- **X2 (throw)**: stays in the combat action schemas as `not_supported` — the validator returns an honest failure «implemented later», not silence (BEST_PRACTICES).
- **X3 (stealth)**: no public Osiris API (client-side mechanic, Pomosofter; no `SetStealthEnabled`/`EnterStealth`; grep.app — 0 Lua hits). In v1 the `toggle_mode` enum is only `"normal"`; `"stealth"` will return when a stable solution appears (ApplyStatus — fragile, no status names). The «why unavailable» question is covered in the Answer/research.
- **X4 (attack)**: basic player attacks — via `Ext.System.ServerCastRequest.OsirisCastRequests` (honest about AP/cooldowns, aligned with X-cast); `Osi.Attack` (one-shot, without resources) — only enemies/NPC/fallback.
- **X5 (spell-id)**: normalization in StateExtractor. The state and `cast_spell` operate with prototype names (`Ext.Stats.Get`), a single format throughout the pipeline.
- **E5 (schema reference)**: full JSON-Schema of all 17 actions — in specification §5.4 (8 combat + dialogue §5.2 + 8 exploration), `Action` format (name/description/schema) PERSISTENT at startup.

### Executor flow (summary)

1. C# validates schema + target existence + prechecks against the state (IsInCombat, CanAllPartiesLongRest, spell presence in SpellBook) → writes `action_<id>.json`.
2. Server Lua poll: `Ext.Timer.WaitForRealtime(100–250ms)` → reads → dispatches → immediately writes `result_<id>.json` (`Ext.Json.Stringify` + `Ext.IO.SaveFile`): `{success, error_code, error_detail}`.
3. Long actions (movement/cast) → intermediate `success:true, running:true` + final via `RegisterListener` event (`CastedSpell`, `CharacterMoveToCancelled`) — never block the `WaitFor` thread.
4. Timeout: **5 s** ACK on the C# side; missing result file after N polls = error per the ticket 08 vocabulary. No waiting for the in-game effect by timer in Lua.
5. Single-threading confirmed → commands are serialized: one in-flight action per context, queue in both C# and Lua.

### Critical limitations (affect 04/05/06)

- `select_dialogue_option` — **no** public function to select an option (only dialogue start + `instanceID`). → resolved by X1.
- stealth — **no** public function. → resolved by X3.
- `throw` — no public call (Anubis/client input). → resolved by X2.
- SpellId normalization — resolved by X5 (affects 03).
- Recommended cast: `ServerCastRequest.OsirisCastRequests` (validated on the SE build). Turn detection: TurnStarted/TurnEnded/CombatRoundStarted/CombatStarted/CombatEnded events + `CombatGetActiveEntity`; turn order: `Ext.Entity.Get(combatGuid).TurnOrder`. Movement: `CharacterMoveTo`/`CharacterMoveToPosition` (Speed "Run"/"Walk"). Lists: `SpellBook.Spells` + `Ext.Stats.GetStats("SpellData")` + `Ext.Stats.Get(name)`.

## Research results (2026-09-05)

Full research: [research/bg3se-lua-action-api.md](../research/bg3se-lua-action-api.md) — exact signatures, sample code, source references, reliability matrix. In short:

- **Loop/pipe (Q1)**: file-based IPC confirmed (see `research/ipc-named-pipes.md`); server-side Lua poll via `Ext.Timer.WaitForRealtime(100–250ms)` → dispatch → `Ext.Json.Stringify` + `Ext.IO.SaveFile` to `result_<id>.json`.
- **Timeouts (Q2)**: ACK from BG3SE — 5 s on the C# side; missing result file after N polls → error per ticket 08. Do not wait for the final in-game effect by timer in Lua — long-running actions (movement/cast) respond with `running:true` and complete via event (`CastedSpell`, `CharacterMoveToCancelled`).
- **Errors (Q3)**: validation-before-send in C# (target, `IsInCombat`, `CanAllPartiesLongRest`, spell presence in `SpellBook`); on the Lua side — action error code pool (`target_missing/not_in_combat/no_spell/no_camp/not_supported`).
- **Concurrency (Q4)**: **yes, BG3SE Lua is single-threaded** (the engine's main thread; `Ext.Timer` defers callbacks, doesn't create threads). → commands are serialized: one in-flight action per context, queue in both C# and Lua.
- **Action Result (Q5)**: `{success, error_code, error_detail}`; for long actions two-phase `running:true` → final.
- **Critical limitations (important for schemas 04/05/06)**: `select_dialogue_option` — **no** public Osiris function to select an option (only dialogue start `CharacterMoveToAndTalk`/`StartDialog_Internal` + getting `instanceID`); stealth toggle — **no** public function; `throw` — no public call (only Anubis/client input). For dialogue and stealth, experimental paths were proposed (client UI, statuses) — move to separate mini-tickets.
- **Recommended spell cast**: `Ext.System.ServerCastRequest.OsirisCastRequests` (real pipeline, `FromClient` for resources/cooldowns); fallback — `Osi.UseSpell/UseSpellAtPosition`.
- **Turn detection**: `TurnStarted/TurnEnded/CombatRoundStarted/CombatStarted/CombatEnded` events, query `Osi.CombatGetActiveEntity(combatGuid)`; turn order — `Ext.Entity.Get(combatGuid).TurnOrder` (`EocCombatTurnOrderComponent.Groups/Groups2/field_40`=round).
- **Movement**: native (`Osi.CharacterMoveTo (Speed "Run"/"Walk")` / `CharacterMoveToPosition`), no custom A* needed; `TeleportTo/TeleportToPosition` as auxiliary.
- **Lists (for 03)**: spells — `Ext.Entity.Get(char).SpellBook.Spells` + `Ext.Stats.GetStats("SpellData")` + `Ext.Stats.Get(name)` (UseCosts/SpellType/Range); inventory — `.Inventory` (EntityHandle) + `Osi.IterateInventory`, `Osi.GetGold`. SpellId normalization (prototype vs root template) — resolve before finalizing 03.