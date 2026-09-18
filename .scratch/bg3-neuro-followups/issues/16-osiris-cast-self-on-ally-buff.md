# 16 — OsirisCastRequests self-casts ally-targeted buffs despite correct `Targets`

Type: task (live bench)
Status: open
Blocked by: bench (live game test scene)

## Finding (2026-09-18, v0.8.47 / PAK v053, gate scene, file bridge — no C# app)

Controlled battle, injects direct to `neuro_to_bg3.json`. On Shadowheart's turn a
`cast_spell` of `bless` (`Target_Bless`) with `target_id: "tav"` (alias) was issued and
returned `success: true`, but **visually the Bless landed on the caster (Shadowheart),
not on Tav**.

Machine-side evidence the request was correct:

- `cast_debug.json` (written by `enqueueCastRequest`, `BG3Neuro.lua:3569`) right after the
  inject shows: `actor = S_Player_ShadowHeart_...`, `targetUuid = e6090219-081b-bd2d-8a49-88fd52aa8b4b`
  (= Tav's guid, matches `acting_before` from Tav's end of turn), `targetPos` set, `spell =
  Target_Bless`, `queueSize = 0`. So `resolveEntity("tav")` → guid, `Targets = [Tav]` with
  position, pushed into `OsirisCastRequests`.
- SE log (`Osiris Runtime 2026-09-18 06-05-49.log`): `DB_GLO_CastedSpell(
  S_Player_ShadowHeart_..., "Target_Bless", "target", "Enchantment", 762 )` — the 3rd arg is the
  literal Osiris constant `"target"` (self-cast placeholder), **not** Tav's guid.

Contrast: enemy-targeted combat actions through the same bridge landed correctly all session
(`executeAttack`/`executeBonusAction` — Flourish/Piercing dropped `goblin_tracker_4` HP 9→7→1).
The failing shape is specifically `cast_spell` → `enqueueCastRequest` → `OsirisCastRequests` for
a **friendly/ally** target.

## Hypothesis

`OsirisCastRequests` (Osiris-driven server cast queue) self-casts a single-target buff when the
target is a party ally: the cast registers in the engine as self-cast even though the request's
`Targets` carried the correct ally guid + position. Enemy casting through the same queue worked,
so the divergence is presumably target-relationship (friendly buff) specific.

Note: the cast **completed** (`CastedSpell` fired, AP spent) — a same-turn retry is not a
viable workaround.

## Change proposal

1. Bench the alternative path: `cast_spell` with `use_osi_spell: true`
   ("Real gameplay cast" v0.8.19 — direct `Osi.UseSpell(actor, sid, target)` with the book
   prototype) for an ally-targeted buff; verify the `DB_GLO_CastedSpell` fact carries Tav's guid
   as target, and visually.
2. If the Osi path works — prefer it for friendly buffs (or document when to use it).
3. Fallback probe: `queue: "network"` (`NetworkStartRequests` — the real client channel) for
   ally buffs; note `queueName` is already plumbed through `executeCast` (`data.queue`).
4. If no public path targets allies correctly, surface a clear `action_failed` ("engine
   self-casts ally-targeted buffs via osiris queue") instead of a misleading `success: true`,
   so the controller never believes the buff landed on the intended ally.

## Verification

- `cast_debug.json` / SE-log fact target token == Tav's guid (not `"target"`).
- Visual confirmation in-game on the intended ally.
- Regression: enemy-targeted casts (tracker HP) unchanged; AP economy unchanged
  (`exec resource snapshot`).

## Bench recipe (next live session, one-shot)

Precondition: gate scene, party turn, caster with an unused action and a friendly single-target
buff (Shadowheart + `bless`). Follow-up on this session's battle (v0.8.47 / PAK v053).

1. `state_capture` — confirm `turn_actor` can act; note the caster guid + intended ally alias
   (e.g. `poc_player_cleric` → `tav`).
2. Cast `bless` on an ally **4 ways, one per fresh action/turn** (each verified before firing):
   - (a) default osiris queue, `target_id=<ally>` — known: self-cast; log the `cast_debug.json`
     targetUuid anyway;
   - (b) `use_osi_spell=true`, `target_id=<ally>`;
   - (c) `queue:"network"` (`NetworkStartRequests`), `target_id=<ally>`;
   - (d) `use_osi_spell=true` with full guid instead of alias (rules out alias-resolution).
3. For each: record the cast `result_*.json`, the `cast_debug.json` (targetUuid, targetPos,
   queue, option flags), and the SE-log `DB_GLO_CastedSpell` fact around the cast timestamp —
   **the deciding evidence is the fact's target argument**: `"target"` literal = self-cast,
   the ally's guid = real cast.
4. Visual cross-check (if cheap): the buff's green glow on caster vs ally.

Decision to write into the ticket after the bench:
- If (b) or (c) shows the ally's guid → implement priority: friendly-target casts default to that
  path; keep default osiris queue for enemies.
- If none → implement the honest-decline: `executeCast` rejects friendly targets with a clear
  `action_failed` ("engine self-casts ally-targeted buffs via osiris queue; use a client cast"),
  no misleading `success: true`.

## Evidence

- `mod/BG3Neuro/BG3Neuro.lua`: `executeCast` (L3836-3980), `enqueueCastRequest` (L3365-3606,
  `Targets` build L3454-3476, `cast_debug.json` L3569), queue select `network` vs `osiris` L3478-3488.
- SE log `DB_GLO_CastedSpell(..., "Target_Bless", "target", "Enchantment", 762)`.
- Session: `b8m` inject (bless on tav), `cast_debug.json` targetUuid `e6090219-...`, user-observed
  self-cast; enemy hits `b2o`/`b4m` as working contrast.