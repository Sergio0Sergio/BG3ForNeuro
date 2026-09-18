# 17 — file-bridge `cast_spell` intermittently returns "spell_name is required" (decode race in mod read)

Type: task (live bench)
Status: resolved
Blocked by: —

## Root cause (2026-09-18, live bench v0.8.48 / PAK v054, gate scene)

**Not a mod bug and not a file race — a harness (caller) bug.** Passing the JSON payload as
`-Data '{"spell_name":"bless","target_id":"tav"}'` **through a child `powershell -File ...`**
strips every `"` during the child's argv re-tokenization. The script received
`{spell_name:bless,target_id:tav}`, ConvertTo-Json escaped nothing (no quotes left), and the
written file carried `"data":"{spell_name:bless,target_id:tav}"` — **invalid** inner JSON.

Caught on the bench with a 5 ms file watcher:
`{"name":"cast_spell","id":"t17c2","data":"{spell_name:bless,target_id:tav}"}`.

The mod then ran `Ext.Json.Parse("{spell_name:bless,target_id:tav}")`, which is **lenient**
(does not error on the bare keys/values) and returned a table **without** `spell_name`;
`executeCast` reported `spell_name is required`. Replayed manually byte-for-byte (`t17m`)
→ same result, and `cast_data_debug.json` was **not** written (parse "succeeded") — which also
explains why the v0.8.48 instrumentation (dump on `Ext.Json.Parse` *failure*) never fired.

Why manual writes worked 3/3: they were authored inline in the agent shell (string literal,
quotes preserved) — no argv boundary. Why `state_capture`/`probe` were immune: `data='{}'`
has no double quotes to strip.

## Fix (bench harness, not in repo)

`drive_action.ps1` now takes data via **environment variable** `BG3NEURO_DATA` (immune to argv
re-tokenization), self-validates it as JSON (fail fast on malformed payload), keeps the atomic
write. The temporary retry-once was **removed** — the "transient decode race" theory it was
built on is disproven.

Left in place (in repo, v0.8.48 / PAK v054, commit `7eb7576`):
- `executeAction` instrumentation: on a **strict** `Ext.Json.Parse` failure of `data` it dumps
  `cast_data_debug.json` (id, `data_raw`, `file_raw` at read time). Kept as a diagnostic net.
- Modified observations as we go; no further mod changes required for this ticket.

Optional future diagnostics (not implemented): make the mod distinguish "data is not valid
JSON" from "spell_name missing" (currently both surface as `spell_name is required`), and/or
strictly pre-validate the inner JSON so garbage yields a precise error.

## Bench gotcha (documented in AGENTS.md)

Do **not** pass JSON with double quotes to the game-bridge injectors through a child
`powershell -File -Data '...'` — the child drops all `"`. Use `$env:BG3NEURO_DATA` (or write
the file inline). Verify with the harness's JSON self-check or a file watcher.

## Evidence

- `watch_cmd.ps1` 5 ms file watcher: `10:02:36.363` — cmd file held `data` with **no quotes**
  (`...data":"{spell_name:bless,target_id:tav}"`), cleared `10:02:36.452`.
- Reproductions: `t17c1`, `t17c2` (drive_action), `t17m` (manual identical malformed bytes) —
  all `action_failed: spell_name is required`, no `cast_data_debug.json`.
- Fix proof (live): same payload via `BG3NEURO_DATA` → `t17fix1` `running: true, success: true`,
  no debug dump.
- Earlier 3/3 vs 3/3 correlation (`b2/b4/b8` fail vs `b2s/b4m/b8m` ok) fully explained by the
  argv boundary, not by file contents (byte-compare `p_script.json`/`p_manual.json` matched
  because it did not cross the child-process boundary).

## Historical trail (kept for traceability)

### Finding (2026-09-18, v0.8.47 / PAK v053, gate scene, file bridge)

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

## Progress (superseded by Root cause above)

The v0.8.48 instrumentation + atomic-write + temporary retry-once were all built on the
("transient decode race") hypothesis above; the live bench disproved it — see **Root cause**
at the top. The instrumentation is kept (strict-parse diagnostic net), the retry-once and the
old `-Data` convention were removed.

## Note on luaparse invocation

`luaparse` CLI defaults to Lua 5.1; this file uses 5.3 bitwise ops (`|`, L861 pre-existing).
Validate with `luaVersion: "5.3"` (Node API), e.g.:
`node -e "...lua.parse(fs.readFileSync(f,'utf8'),{luaVersion:'5.3'})"`.

## Verification

- Live (v0.8.48): payload via `BG3NEURO_DATA` → `t17fix1` `running: true / success: true`;
  malformed quotes-stripped payload (`t17m`) reproduces the old error and (correctly) no debug
  dump. The mod is confirmed correct on valid input; the harness now stops corrupting input.
- Regression: enemy-target casts, `state_capture`, `probe` unaffected (env-var path passes
  through unchanged JSON).

## Evidence

- Session ids: fails `b2`, `b4`, `b8` (drive_action); successes `b2s`, `b4m`, `b8m` (manual,
  identical bytes); `race1..3` state_captures OK after atomic-write change.
- `mod/BG3Neuro/BG3Neuro.lua:3851` (`resolveAbilityStatName`), `:3844` (error site),
  `:4659-4665` (`data` string decode), `pollActions` read + `clearInFlight` (`""`) loop.
- Byte-compare scratch: `%TEMP%\opencode\p_script.json` vs `p_manual.json` (89/89, key order only).