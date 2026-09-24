# 29 — `Osi.Attack` fallback (Fallback 2) spends no AP + live trigger map

Type: bug (honest economy — attack path)
Status: open (fix in repo, unreleased; bench partial 2026-09-24, success-delta pending interior geometry)
Blocked by: —

## Finding

`executeAttack` (`mod/BG3Neuro/BG3Neuro.lua:5333-5461`) has three paths:

1. **Honest** — `enqueueCastRequest` via `OsirisCastRequests` (native AP/cooldowns).
2. **Fallback 1** — `Osi.UseSpell` + manual `Osi.AddActionPoints(actor, -1)` (`:5440-5445`, proven live v0.8.22).
3. **Fallback 2** — `Osi.Attack(actor, target, 0)` (`:5429-5432`) with **no AP deduction**:
   the engine does not spend AP for the story call, and the mod never did either —
   an attack through this path was free. `writeResourceSnapshot(after)` still ran,
   so the 0-delta was detectable post-factum but never repaired or warned about.

**Fix (repo HEAD, unreleased):** symmetric manual deduction after a successful
`Osi.Attack`, with a log warning on failure (`atkApOk/atkApErr`,
`[BG3Neuro] attack AP spend failed (Osi.Attack fallback)`). No new main-chunk
locals (199/200 before and after), `luaparse -v 5.4` OK. Spec §6.2 row updated
(one-shot, manual AP accounting).

## Trigger map (code + live-verified 2026-09-24)

Fallback 2 fires **iff** `pcall(Osi.UseSpell, …)` throws on every candidate sid
(`if not ok` gate, `:5429`). Established:

- `knownSpellCandidates` (:4245-4263) never returns empty (second loop appends
  everything) — no empty-list shortcut exists.
- `preValidateCastTarget` (:4327-4380): melee sids (`Target_*`) are **fail-open**
  (`castRangeOf` → nil, `:4299`), so range never gates them; the only failing
  verdict is `no_los`. Ranged-first actors still fall through to the fail-open
  `Target_*` second, so range alone can never route to Fallback 2 either.
- `Osi.UseSpell` pcall success = "call accepted", not "cast worked": out-of-range
  casts fire and fail later via `CastedSpell(cancelled)` → `cast_failed`
  (`finalizeCast`, `:4458-4460`), never reaching Fallback 2.
- Attack targets must additionally pass the perception gate (`no_perception`
  otherwise, ticket 23 machinery) — synthetic GUIDs are rejected before
  `preValidate`, so the fallback cannot be probed with fake targets.

Net: in open geometry Fallback 2 is **unreachable by construction** (any target
`Osi.Attack` would accept, `UseSpell` also accepts at call time). Reachable
cases: a `no_los` pair (interiors, walls) or a synchronous engine rejection of
`UseSpell` (no natural case observed).

## Bench evidence (2026-09-24, gate combat, bench PAK)

Bench PAK: repo Lua + `force_legacy:true`, MOD_VERSION 0.8.79 (no bump, bench-only),
MD5 `F666710884430FCC5DFB1BBCC030445A`, `paktool2 list` prefix `Mods/BG3Neuro/` OK,
installed with MD5 in both `ModuleShortDesc` nodes (backups kept). SE log:
`[BG3Neuro] v0.8.79 loaded (server)`, `config: force_legacy=true legacy_fail_limit=3`.
Restored to pre-bench PAK (`E853D10D…`) + MD5 after the session.

- `fb2probe1` tav→bugbear_1 (21.9 m): `prevalidate_latest.json` verdict `pass`
  (range skipped, LOS=1) → `UseSpell` fired → `cast_failed` (engine refused at
  range). Snapshots: AP 1.0→0.0, Movement 9.0→0.0 — engine spent honestly.
- `hunt1/hunt2` (tracker_3, booyahg): same shape, `pass` → `cast_failed`.
  Open courtyard has no no-LOS pair — hunt abandoned (correct call, no AP left to burn).
- `fb2entry` (synthetic GUID target): `action_failed` / `no_perception` —
  perception gate holds; preValidate never ran (stale debug file confirmed).

Side effect on the live save: tav spent AP/movement on the failed casts
(transient, next turn restores). No other state touched.

## Honest status

- PROVEN live: bench-PAK loads and runs; legacy `UseSpell` path executes;
  preValidate fail-open/LOS-only behavior; perception gate rejects synthetic targets.
- PROVEN static: patch parses, respects the 200-local budget, reuses the proven
  `AddActionPoints` call with failure logging.
- NOT proven live: AP 1.0→0.0 delta on an `Osi.Attack` success — no trigger exists
  in open geometry (see map above). This is a defense-in-depth fix for a
  nearly-unreachable branch, stated as such.

## Follow-up

1. Interior-geometry bench (walls → real `no_los` pair): force the Fallback-2
   success branch live, confirm AP delta + no
   `attack AP spend failed (Osi.Attack fallback)` line in the SE log.
2. Release: bump MOD_VERSION → 0.8.80, build PAK v120 (`force_legacy:false`),
   install + MD5, update heartbeat examples if they pin 0.8.79.
3. Open question (bench): Fallback-2 fire at 0 AP — `AddActionPoints(-1)` clamps
   at 0, delta uninformative; consider a router-side AP>0 precheck for
   `attack_entity` (would also cover the UseSpell path).

## Evidence

- `mod/BG3Neuro/BG3Neuro.lua` `:5429-5445` (fallback block + deduction),
  `:4245-4263`, `:4327-4380`, `:4458-4460`, `:5333-5348`.
- `BG3_Neuro_Spec.md` §6.2 Attack row.
- IPC dir 2026-09-24: `result_fb2probe1.json`, `resource_snapshot_fb2probe1_{before,after}.json`,
  `prevalidate_latest.json`, `result_hunt1/2.json`, `result_fb2entry.json`.
- SE log `Extender Runtime 2026-09-24 05-35-36.log` (UTC name): load + config lines.
