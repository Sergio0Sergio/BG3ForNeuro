# 11 — A failed cast is reported as `success: true`

Type: bug (mod result channel)
Status: fixed + verified (v0.8.36, PAK v042)
Blocked by: —

## Finding (live bench 2026-09-17, v0.8.35 / PAK v041)

A cast that the engine **rejects** comes back to Neuro as a success.

- `BG3Neuro.lua:3293` — `Ext.Osiris.RegisterListener("CastSpellFailed", …)` calls
  `finalizeCast(caster, spell, true)`.
- `BG3Neuro.lua:3184` — `finalizeCast` then writes, for **both** outcomes:

  ```lua
  writeResult(pc.id, true, false, cancelled and "cast_failed" or nil,
      cancelled and "Cast interrupted/failed" or nil)
  ```

  The second argument (the `success` flag) is hardcoded `true`. Only the `error_code`/`error_detail`
  reflect the failure.

Observed evidence (Tav, AP already spent, injected `spell_name:"Target_MainHandAttack"`):

```json
// result_b9r3.json
{ "id": "b9r3", "success": true,
  "error_code": "cast_failed", "error_detail": "Cast interrupted/failed" }
```

The app reads `success` and forwards it verbatim — the WS frame was
`{"command":"action/result","data":{"id":"b9r3","success":true,"message":null}}`. So the model is told
the cast worked when it did not (and `WaitForExecutionResultAsync` also maps the non-empty
`error_detail` into a "message" on a *successful* result, which is contradictory).

Contrast: the sibling path `CastedSpell → finalizeCast(caster, spell, false)` is correct
(`success = true`, no error fields).

## Fix

`finalizeCast` must derive `success` from `cancelled`:

```lua
writeResult(pc.id, not cancelled, false, cancelled and "cast_failed" or nil,
    cancelled and "Cast interrupted/failed" or nil)
```

Consider also asserting the invariant in `writeResult` (`error_code` present ⇒ `success` is false) so a
contradictory payload cannot be written again.

## Verification

- [x] Fix applied (v0.8.36): `success = not cancelled` in `finalizeCast`, plus a `writeResult`
      invariant that forces `success=false` whenever an `error_code` is present (and logs the
      contradiction), so no other call site can write a contradictory payload.
- [x] Static: `luaparse` 5.3 on both `BG3Neuro.lua` / `BG3NeuroClient.lua` → PARSE OK.
- [x] Bench (2026-09-17, v0.8.36 / PAK v042, combat, `turn_actor=tav`):
      `c10a` friendly `flourish` → `success:true`, BA 1.0 → 0.0;
      `c10b` `Target_MainHandAttack` → `success:true`, AP 1.0 → 0.0;
      `c10c` **the same cast again at AP=0** → `result_c10c.json`
      `{"success":false,"error_code":"cast_failed","error_detail":"Cast interrupted/failed"}`, and the
      app forwarded `{"id":"c10c","success":false,"message":"Cast interrupted/failed"}` over WS.
      Previously this exact call produced `success:true`.

## Evidence

- `result_b9r3.json` (pre-fix, `success:true` + `cast_failed`), `result_c10c.json` (post-fix,
  `success:false`), `action_b9r3.json`, `resource_snapshot_c10{a,b,c}_*` in the IPC dir
  (`_archive_v0835` holds the pre-fix run).
- `docs/manual-regression-checklist.md` — Run 2026-09-17 (v0.8.35 finding; verified under v0.8.36).
