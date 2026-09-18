# 17 — file-bridge `cast_spell` intermittently returns "spell_name is required" (decode race in mod read)

Type: task (live bench)
Status: open
Blocked by: bench (live game test scene)

## Finding (2026-09-18, v0.8.47 / PAK v053, gate scene, file bridge)

During the controlled battle, `cast_spell` injected through `drive_action.ps1` (the bench
harness) failed **3/3** with `action_failed: "spell_name is required"` (`b2` flourish, `b4`
piercing_strike, `b8` bless). The exact same payload written **manually** to `neuro_to_bg3.json`
by an inline PowerShell `[System.IO.File]::WriteAllText` executed cleanly **3/3** (`b2s`, `b4m`,
`b8m`) — decoded, enqueued, `success: true`. Non-cast actions (`state_capture` `'{}'`,
`probe`) via `drive_action.ps1` worked 5/5.

Byte-level check: the two writers produce identical JSON (89/89 bytes, only key order differs,
`name,id,data` vs `id,name,data`) — semantically equivalent, so a format difference is ruled out.

Steps taken that did **not** fix it: `drive_action.ps1` was changed to an atomic write (write
`*.tmp`, then `Move-Item` rename) — next cast (`b8`) still failed, so a torn-file theory is
disproven.

## Mechanism note

The error string exists **only** in `mod/BG3Neuro/BG3Neuro.lua:3844` (C# router says
`Parameter spell_name is required`; not running here). `executeCast` reaches it when
`action.data` has no `spell_name`; `executeAction` (L4659-4665) sets `data = {}` whenever
`action.data` is a string whose `Ext.Json.Parse` fails. So the mod is receiving the file with a
`data` member it cannot re-parse (or an empty table) on these runs — while identical bytes
decode fine on manual runs. Root cause unidentified; write mechanism alone cannot explain it.

Note: `state_capture`/`probe` are insensitive to a broken `data` (they don't require it), which
is why only `cast_spell` jitters.

## Change proposal

Instrument first, reason later (one bench iteration):

1. Echo the **raw file bytes the mod actually read** at poll time — dump `readInFlightAction`'s
   content (or the raw `action.data` before `executeAction`'s string branch) to a debug file
   (mirror `cast_debug.json` pattern in `enqueueCastRequest`, `BG3Neuro.lua:3569`).
2. Reproduce `cast_spell` via `drive_action.ps1` (subprocess) until the failure, then diff the
   echoed raw bytes vs the intended write.
3. Fix from evidence: known candidates are
   (a) `Ext.Json.Parse` on an escaped-inner-string that isn't re-parseable (double-escape path),
   (b) a stale/mixed-read from `Ext.IO.LoadFile` caching in this BG3SE build,
   (c) a second writer racing (mod's `clearInFlight` writes `""`; any overlap with our write
   that still yields a *parsed* outer JSON with an empty `data`).
4. If no root cause is found, harden `drive_action.ps1` reads: retry-once on
   `spell_name is required` for `cast_spell` (safe — failed pre-cast does not consume the
   action, verified: `b2`→`b2s`, `b4`→`b4m` both re-ran).

## Progress (2026-09-18, game closed — ground truth pending next session)

Implemented both game-independent legs:

1. **Instrumentation (v0.8.48, PAK v054)** — `executeAction` (`BG3Neuro.lua:4662-4685`): when
   `action.data` is a string and `Ext.Json.Parse` fails, the failure branch now dumps
   `cast_data_debug.json` with ground truth: `id`, `name`, `data_raw` (the undecodable string),
   `data_raw_len`, `file_raw` (the full `Ext.IO.LoadFile` re-read of the command file — still
   un-cleared at this point, `clearInFlight` runs after `executeAction`), `file_raw_len`, `mtime`.
   This makes the next bench one-shot: reproduce → diff `file_raw` vs the intended write.
   luaparse (Lua 5.3) OK on both Lua files.
2. **Harness retry-once** — `drive_action.ps1`: for `cast_spell`, if the result is
   `action_failed` + `spell_name is required`, rewrite the identical payload once and poll again
   (safe: failed pre-cast does not consume the action, proven `b2`→`b2s`, `b4`→`b4m`).

Static analysis of the decode (L4659-4665 + `readInFlightAction` L81-93) rules out any
deterministic byte-dependence: a clean read of the written JSON always produces a parseable
`data`. The failure must be a read-time artifact (torn/mixed content that still yields a valid
outer parse with a bad `data`, or a `data` that survives with escapes). `cast_data_debug.json`
will show which.

## Note on luaparse invocation

`luaparse` CLI defaults to Lua 5.1; this file uses 5.3 bitwise ops (`|`, L861 pre-existing).
Validate with `luaVersion: "5.3"` (Node API), e.g.:
`node -e "...lua.parse(fs.readFileSync(f,'utf8'),{luaVersion:'5.3'})"`.

## Verification

- Failure reproduced with echo vs write diff, or harness retry-once removes visible flakiness
  across N=5 `cast_spell` runs.
- Regression: enemy-target casts (tracker HP), non-cast commands unchanged.

## Evidence

- Session ids: fails `b2`, `b4`, `b8` (drive_action); successes `b2s`, `b4m`, `b8m` (manual,
  identical bytes); `race1..3` state_captures OK after atomic-write change.
- `mod/BG3Neuro/BG3Neuro.lua:3851` (`resolveAbilityStatName`), `:3844` (error site),
  `:4659-4665` (`data` string decode), `pollActions` read + `clearInFlight` (`""`) loop.
- Byte-compare scratch: `%TEMP%\opencode\p_script.json` vs `p_manual.json` (89/89, key order only).