# 06 — Ranged cast projectile goes «at the caster», not at the target

Type: prototype
Status: resolved
Blocked by: -

## Symptom (2× on the bench, v083, 2026-09-20)
`cast_spell "Sneak Attack (Ranged)"` from the turn of **origin_astarion** on an entity 11 m away
(target selected correctly: r6 by state, r11 by coordinates from Tav — `goblin_tracker_2`,
2.0 m from Tav) → `result_*.json: success:true` (CastSpell-event fired), BUT visually
the projectile flies IN PLACE at the caster (first time «into his own cell», second «next to himself»),
no damage on the target. User: «endless error loop», the combat was abandoned.

## What is already excluded
- Aliases/guids are not mixed up (entity_probe by raw guid: the entity exists, cast_ok).
- Distance reference frame (fix v083): r11 target was selected by coordinates from Tav, correctly.
  Distance to the target 11 m — within the Sneak (Ranged) range.
- `success:true` ≠ damage: missed rolls are possible, BUT «projectile at the caster's feet» twice in a row — not
  a roll, but an artifact of cast issuing.
- Perception gate (04b) does not block in combat (actors = all participants) — not it.

## Investigation 2026-09-21 (offline, without the game): the request is CORRECT
Data from `cast_debug.json` (last enqueue = r11), written on each enqueue:
- `targetUuid = 7fbfb1b0-184b-4889-935b-f916a7ad1177`, `targetPos = [211.05, 29.44, 411.94]`
  — targetPos **by coordinates matches the current position of `goblin_tracker_2`** in the state
  (211.1/29.4/411.9). The request aimed at the right entity at the right point.
- `queue = osiris` (OsirisCastRequests), `castOptions = {FromClient, ShowPrepareAnimation,
  AvoidDangerousAuras, NoMovement}`, `isPlayer=true`, `forceFlags=false`.
- `spell.Prototype = Projectile_SneakAttack`, `SourceType = ProgressionClass` (taken from
  the caster's PreparedSpells — the human name resolved to the prototype correctly).
- The alias registry **self-heals on combat change**: on `CombatTeam` change
  (`BG3Neuro.lua:2380-2384`) `combatAliases` and `ENTITY_BY_ALIAS` are cleaned. The roster change
  (was tracker_2/3/4 → became tracker_1/2/3) means: by the time of r11 the registry was fresh,
  and `7fbfb1b0` is the **current** tracker near Tav (the same NPC, previously registered as
  «tracker_4» in the same combat). => The HYPOTHESIS «stale alias/name confusion» **FALLS**.

### Conclusion
The target request is correct at all levels (alias→guid→position). «Projectile at the caster» is
**how the engine executes a ranged weapon action**, not a missed target of the request.
Leading hypothesis: **Sneak Attack (Ranged) requires an equipped ranged weapon**; Astarion
does not have one (daggers) → the engine executes the cast as a throw/melee weapon attack with a short/melee
resolution, the projectile resolves at the caster, damage 0. This also matches r6 (point-blank target, 1.8 m from
Tav — «goblin in the adjacent cell»: point-blank throw does not reach).

## LIVE confirmation 2026-09-21: osiris/network DO NOT BIND THE TARGET for targeted player casts
Three independent live cases in one combat (all game casts via inject):
1. **sneak (osiris, r11, Astarion's turn)** → projectile «at the caster», damage 0, `success:true`.
2. **bless (osiris, r13, Shadowheart's turn, target=tav)** → `success:true`, AP+slot spent, BUT
   the blessing landed **on Shadowheart herself**, not on Tav (noticed by a real user).
3. **witch bolt (r14 queue=network, r15 osiris; Gale's turn, target=worg_1, 22 m)** → both returned
   `cast_failed: Cast interrupted/failed` (honestly: AP=0 + out of radius), BUT the engine STILL
   fired a visual beam far to the side — **into the corpse of the first tracker**, not into worg.

### What it means
- The request REACHES the engine, but **the target from the request list is NOT bound**; the engine itself
  substitutes the slot (self for bless, nearest valid/corpse — for witch bolt, «at the caster» —
  for the sneak projectile). `success:true` and `cast_failed` **do not reflect the real execution**
  (false positive/visual on a «refusal»).
- A MANUAL UI cast of THE SAME sneak (this combat, with a bow) works perfectly (hit, killed) — i.e.
  the difference = **server-side cast request vs client-side target binding** (manual = the client itself selects
  and binds the target; inject = server pool without client binding).
- The «no bow» expectation FELL (Astarion always had a ranged weapon).

## Offline analysis (2026-09-21): request construction — NOT a bug; the bug — missing pre-validation
### Comparison to the brawl reference (tinybike/Brawl, Actions.lua — queueSpellRequest)
Our enqueueCastRequest and brawl.queueSpellRequest are **structurally identical**:
- `{{CastOptions={FromClient,ShowPrepareAnimation,AvoidDangerousAuras,NoMovement}, Caster=Ext.Entity.Get(uuid),
  Spell={OriginatorPrototype,ProgressionSource,Source,SourceType}, Targets={{Target=Ext.Entity.Get(target), TargetingType=Ext.Stats.Get(name).SpellType,
  Position={...}}}, field_A8=1, RequestGuid=<uuid>}}` (brawl: Originator/NetGuid commented out
  right in the source — like ours).
- brawl casts **to game companions** (Companion AI) through OsirisCastRequests+FromClient and that
  **works**. ⇒ Request construction is NOT the cause of the target desync.

### Key difference: brawl PRE-CHECKS distance and LOS before the push
`Actions.useSpell`: `if distance > spellRange then return onFailed("cast failed, out of range")`;
`if LOS == 0 and not autoPathfinding then return onFailed("cast failed, no line of sight")`.
We do NOT do such a check → we push a knowingly invalid request.

### What explains today's misses
- **witch bolt r14/r15 (Gale→worg, 22 m at radius 18 m)**: the engine rejected the requested target as
  out of reach (CastSpellFailed — this is what came back as `Cast interrupted/failed`) and **itself
  picked the nearest valid candidate** — the visual «beam into the first tracker's corpse» near Tav. The request
  was correct (0ms-queue snapshot: target=0cf3, pos=204/25/426), the target selection was an engine error
  caused by out-of-range.
- From this, r11 (sneak, target 2 m) and r13 (bless→tav, 6 m) are NOT explained — those are in range, but
  went to the caster/self. So there are TWO independent mechanisms:
  1. **out-of-range ⇒ the engine itself picks the target** (can be fixed right now with an honest refusal).
  2. **in-range, but FromClient in turn-based** — the client previewer for some reason
     rerolls the target (point-blank sneak → at the caster; bless→tav → on self). Requires a clean
     controlled bench (see the protocol below).
- Question for the next bench: the in-range cases — the same «self-pick», or a specificity of the
  cast coming from a non-controlled avatar whose TURN is currently active.

### Pre-validation BUILT IN (2026-09-21, offline, code ready; NOT in the PAK, bench stopped)
Implemented in `mod/BG3Neuro/BG3Neuro.lua` (marked `v0.8.58 (ticket 06)`):
- New `castRangeOf(sid)` — radius from `Ext.Stats.Get(sid).Range`: numbers as-is,
  spell strings (`"RangedMainWeaponRange"`→15 m, `"MeleeMainWeaponRange"`→1.5 m,
  `"ThrownObjectRange"`→18 m, `"MainWeaponRange"`→15 m), nil → fail-open (we do not gate).
- New `preValidateCastTarget(actor, sid, target)`: (a) distance `Osi.GetDistanceTo`
  > range + 1 m → refusal `no_range`; (b) `Osi.HasLineOfSight == 0` → refusal `no_los`;
  nil-target (positional/GroundTarget) is NOT gated; returns `(true)` or
  `(false, code, reason)`.
- `executeCast`: guard right after the no_aoe_target gate (before enqueue AND before Osi.UseSpell) →
  honest refusal `action_failed` with a code.
- `honestEnqueue`: pre-validation of every candidate before enqueue; failed → `lastErr`,
  next candidate, nothing for the engine to re-pick. Covers attack/bonus paths.
- Legacy fallbacks `executeAttack`/`executeBonusAction` (Osi.UseSpell by candidates) —
  the same guard (otherwise legacy would give the same re-pick).
- Check: `luaparse` → `PARSE_OK` (235 top-level nodes).
- Live bench on the next entry: witch bolt out of radius → must return
  `no_range`, the projectile must NOT go «into the corpse»; sneak/bless in range → expect analysis
  of mechanism №2 (confirmation/refutation of the «self-pick» hypothesis).

### Follow-up (API, not ticket 06): bless on multiple targets
Live bench 2026-09-21 (r13): `cast_spell` accepts ONE `target_id`; the user
confirmed «the cast went only on shadowheart. each bless target must be selected».
Multi-target requires either a list of `target_ids` in the action, or a series of single casts —
write a separate ticket (dispatcher API feature, not a miss fix).

### Decisive bench protocol (next live session)
A. Fix the cast-request construction: find out why `Targets[1].Target` (Ext.Entity
   userdata) + `Position` do not bind in OsirisCastRequests/NetworkStartRequests for players
   (brawl reference; uuid-string instead of userdata? caster's network NetworkId? `field_A8`?).
B. Pragmatic alternative: **the mod routes player casts through the client UI bridge** (like
   the dialogue click) — the manual cast is PROVEN to work; leave server requests for NPCs.
   Until decision B is taken — honest refusal for targeted player casts (do not emit
   `success`/visual if the target cannot be bound).

### Decisive bench protocol (next live session)
1. Give Astarion a ranged weapon (bow/crossbow) → the same cast `Sneak Attack (Ranged) →
   nearest-to-Tav tracker` → the blinds: the projectile flies TO the target (hypothesis confirmed) or
   again «at the caster» (the engine ignores the target — another level).
2. Paired run: the same cast `manual UI` (goes to the target?) vs `inject` — separation «the game
   itself» from «the mod path»; record both `cast_debug.json` (targetPos) and `result_<id>`.
3. If it works with a weapon — DECISION: for weapon casts (flourish, sneak melee/ranged)
   an honest refusal `no_ranged_weapon` is needed when the weapon is missing OR execution via
   the strike API (RequestAttack/bonus attack), not CastStartRequests; options and context
   (osiris/network misfires, 16/18/11 followups) — in `bg3-neuro-followups`.

## Reproduction data (record as a pair)
- Before the cast: `turn_actor`, `distance_reference`, caster/target positions, caster's weapon slot.
- After: `result_<id>.json`, `cast_debug.json` (targetPos), trajectory visually.

## LIVE bench 2026-09-21: mechanism №1 CONFIRMED (v0.8.59+v090, combat at the gates)
Protocol: ambush (`move_to_entity → ogre_brute_1`, dialogue 6 nodes option_index=1) → combat,
wait for `turn_actor=tav` (`end_turn` by the turns) → `cast_spell fire_bolt` on an enemy.

Diagnostic path to the root (two false versions, both checked on the bench):
- v086/v087: expected `no_range`, got the engine's `cast_failed` + **nil** in
  `prevalidate_latest.json.range`. Cause — the lazy Osi resolver: in a fresh process the first
  call of `Osi.GetDistanceTo`/`Osi.HasLineOfSight` throws, `pcall` swallowed (`dOk=false`), the gate
  silently passed. Fix: warming the resolvers at startup + a retry loop of 2 attempts in
  `preValidateCastTarget`.
- v088 (diagnostics `prevalidate_latest.json` + `caststats_latest.json` added):
  `verdict: pass` at a 20.1 m target — `castRangeOf("Projectile_FireBolt")` returned nil.
  `caststats`: `Range=0` (NUMBER), `TargetRadius=18`, `SpellType=Projectile`. The clue: my
  number-branch `rng > 0 and rng or nil` on numeric 0 silently gave nil — it did not reach the TargetRadius/
  Projectile_ fallback → fail-open → engine's `cast_failed`.
- v090 (normalization fix): Range=number 0 / string «0» → unified numeric branch → at ≤0
  first `TargetRadius` (18 for firebolt), then `^Projectile_`→15, otherwise fail-open.

Bench results (v090, MD5 40F45BC5470724BEDBB1A8733319D625):
- **c05**: `fire_bolt` tav → `goblin_tracker_3`, 20.2 m (range=18) →
  `action_failed "no_range: Projectile_FireBolt target ... is 20.2 m away (range 18 m)"`;
  `prevalidate_latest.json`: `range=18, dist_1=20.17812, verdict="no_range"`. The projectile did NOT go out
  (the user visually confirmed: the cast was rejected before the engine, no «beam into the corpse»).
- **c06** (in-range control): `fire_bolt` tav → `goblin_tracker_1`, 1.9 m →
  `verdict="pass"`, `success:true` (the engine accepted the cast).
- Earlier (v085, same combat): b07g Gale `fire_bolt` on a ~7 m target → `success` + the projectile
  visually flies EXACTLY at the target (user confirmed), honest miss (no damage).
  Sneak without stealth the engine rejects itself (`cast_failed`) — unfit as the primary
  projectile test in this combat (without advantage).
- The pre-validator now correctly distinguishes out-of-range (no_range) from in-range (pass).

## Status
Mechanism №1 (out-of-range) **closed with live confirmation**: honest `no_range` before the engine,
the projectile is not re-picked. Remaining: (2) controlled bench of mechanism №2 in range (fresh
turn, first action, comparison of the CastOptions set; in-range is definitely NOT like out-of-range —
but bless to self / sneak at the caster are not yet reproduced after the fix); (3) follow-up ticket
for multi-target bless; (4) production PAK based on v090 + updating the MD5 in modsettings.lsx
(the bench version stays in %TEMP%\opencode\BG3Neuro_v090.pak).

## MECHANISM №2 REPRODUCED (v090, c07b, same combat) — 2026-09-21
Protocol: wait for the cleric's turn, `move_to_entity → tav` (2.1 m from the caster), then
`cast_spell bless → tav`:
- `prevalidate_latest.json`: `range=9 (Target_Bless), dist=2.2, los=1, verdict="pass"` —
  the pre-validation honestly lets it through (target in range, LOS exists).
- `result_c07b.json`: `success:true`, `economy.slot: level=1 before=1.0 ok=true` — the engine
  accepted the request, the slot spent.
- `cast_debug.json`: `queue=osiris`, `targetUuid=e6090219…` (Tav), `castOptions=[IgnoreHasSpell,
  IgnoreCastChecks, IgnoreSpellRolls, IgnoreTargetChecks, Forced, Immediate]`, `forceFlags=true`.
- **The user (visually): Bless landed ON THE CLERIC-CASTER, Tav has no buff.**

### Conclusion
Mechanism №2 lives even fully in-range and with LOS clear: the engine executor for a targeted
player cast **itself substitutes the slot, ignoring the request's `targetUuid`** — bless on self with
an ally target (r13), the projectile at the caster (r11 sneak). The reference discriminator — a manual UI cast
of the same spell works (the client itself binds the target). => The self-pick happens at the level
of «server cast-request without client binding vs client UI-cast», NOT dependent on
range/LOS (our pre-validator has no influence on it).

### Consequences for the decision
- Honest refusal №1 (no_range/no_los) — a correct but partial measure: it saves the player from a «projectile
  into the corpse» on out-of-range, but not from in-range target substitution.
- A full solution needs an ANALYSIS of the execution layer: why a player cast through
  `OsirisCastRequests` with FromClient/Forced puts the target on the caster, while the manual UI — on the target
  (client target binding? RNG/next valid slot? a different CastOptions set?).
  A separate bench: compare the CastOptions set of a successful manual UI cast (intercepted via
  `EXTVME_CLIENT_CastSpellUsingPos`/prototype change) vs our `[…Forced, Immediate]`.
- Alternative from protocol B: route player game casts through the client UI bridge
  (provably works), leave server requests to NPCs. Until decided — the honest
  refusal remains, but for in-range it does not protect from substitution; document in the spec.

## Status (rev 2)
Mechanism №1 closed (no_range/no_los, v090). Mechanism №2 **reproduced** in-range
(bless→cleric-caster instead of Tav, c07b) — handed over to the execution-layer investigation
(client binding vs server request). Ticket 06 stays `resolved` (the primary refusal
fixed); items (3) multi-target bless → ticket 20; (3b) investigation of in-range target
substitution → a new follow-up ticket (to open in `bg3-neuro-followups`); (4) prod-PAK v090 installed.