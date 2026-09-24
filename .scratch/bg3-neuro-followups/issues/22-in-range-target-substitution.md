# 22 - Investigation of the target substitution of an in-range player cast (mechanism No. 2 of the server cast)

Type: research
Status: resolved (2026-09-21, v0.8.61)
Blocked by: 06 (resolved)

## Symptom (live bench 2026-09-21, v090, c07b)
In-range player cast by a friendly caster: `cast_spell bless → tav` from the cleric
(c07b, distance 2.2 m, LOS=1, `prevalidate: verdict="pass"`, `result: success:true`, slot
L1 spent) — the engine executor **itself puts Bless on the caster-cleric**, not on the request target
`e6090219…` (tav). The user confirmed visually: the blessing icon on the cleric.

Earlier evidence of the same (v083, the same battle, from ticket 06):
- r11: Astarion sneak → point-blank target → projectile "at the caster", damage 0, success:true.
- r13: bless Shadowheart → tav (6 m, in-range) → bless landed on Shadowheart.
- r14/r15: Gale witch bolt → worg 22 m (out-of-range) → visual beam "into the corpse of the first
  tracker". That case is closed by pre-validation (mechanism №1), the other two are in-range.

## What is known
- Pre-validation (no_range/no_los, v090) has NO influence on the substitution: the target was valid
  (range=9, dist=2.2, los=1), the request went through, and the execution still substituted the caster.
- Manual UI-casting of the same spells works perfectly (bow sneak — into the target, killed; cleric
  Guidance→ally — caught live): the differentiator = client-side target binding on a manual cast
  vs a server cast-request without it.
- Our request: `queue=osiris`, `castOptions=[IgnoreHasSpell, IgnoreCastChecks, IgnoreSpellRolls,
  IgnoreTargetChecks, Forced, Immediate]`, `forceFlags=true` (c07b cast_debug.json).
- The request is structurally identical to the tinybike/Brawl reference (brawl casts on companions and it works) —
  see ticket 06, "offline analysis of the request construction".

## Live comparison (2026-09-21, the same battle): manual UI-cast vs our synthetic one
Captured a real client cast with `q_capture`/`cast_capture.json` (window polling 60 s)
during a manual Guidance click Shadowheart→ally (tag capsh10):
- `castOptions = ["ShowPrepareAnimation", "FromClient"]` — **soft client set**,
  NO `Forced/Immediate/IgnoreTargetChecks`.
- `clientInitiated = true`, `Phase=LogicExecutionUpdate`, `storyActionId=787`.
- `targets[1] = { TargetingType="Target", targetHandle=Entity(02000001000000fc) (ally,
  NOT the caster), position=(216.63, 33.29, 410.81) }` — the target is in the list and it is not the caster.
- Same-window control: manual MainHandAttack `[NoUnsheath, FromClient, IsHoverPreview,
  IsPreview]`, `clientInitiated=true`.

Our synthetic bench (c07b bless→tav): `[…IgnoreTargetChecks, Forced, Immediate]`,
`clientInitiated=false`, the target is correct in the list, but in the end Bless landed on the caster.

### Hard vs soft options (2026-09-21, repeat bench) — FIRST HYPOTHESIS REFUTED
Repeat on a clean save (before combat), in combat, fresh cleric turn, distance 5.8 m:
- c16a: `cast_spell Bless → tav`, `force_flags=false` → cast_debug confirmed the **soft** set
  `castOptions=[FromClient, ShowPrepareAnimation, AvoidDangerousAuras, NoMovement]`,
  `forceFlags=false`, target `e6090219…` correct; `prevalidate: verdict=pass (range=9,
  dist=5.8, los=1)`; `result: success:true`. **User: Bless is still on Shadowheart**,
  although "visually it looked as if the cast went onto Tav" (the projectile flew at Tav → the status
  stuck to the caster). Slot L1 spent.
- Conclusion: switching to the soft FromClient set does NOT fix the self-cast — the force-flags are NOT
  the cause of the substitution. The cause is deeper (see "What is known" / hypotheses 4-6).
- c17g: `cast_spell Guidance → tav`, soft set — honest refusal `no_range` (guidance range=2,
  dist=2.6) — pre-validation works for cantrips too. A fresh slot L1 is unavailable (Bless
  spent on c16a) — the manual Bless reference is deferred until a rest/new combat.

## Hypotheses
1. `Forced` + `Immediate` make the OSIRIS executor skip target binding
   (the target from the request list is not bound in the internal `CastSpellRequest`), and the slot
   selection falls back to a self-cast/nearest valid one. Check: compare the CastOptions/forceFlags set
   of a successful MANUAL UI-cast of the same spell (captured via an event/hook or
   `EXTVME_CLIENT_CastSpellUsingPos`).
2. The problem is not CastOptions but the fact that the client has no "selected target" (selection state):
   a manual cast happens after the user picked the target in the UI — the server request carries
   no such state (although Brawl works... in Brawl the target in `Targets[1]` is the same Ext.Entity userdata).
3. player vs NPC-caster difference: `isPlayerDetail="serverCharacter"`; possibly, for a player-cast the
   engine waits for client confirmation of the target and, lacking it, picks one itself.

## Hypotheses (after c16a — force removed, self-cast persisted)
4. THE SOURCE of the cast object: a server cast (without a client session/`NetId`) in this engine version
   reassigns the target of single-target buffs to the caster, regardless of CastOptions.
   Evidence: manual UI-cast (has a client session) — `clientInitiated=true`, the target
   holds (capsh10). The difference is not in the options but in the presence of a live cast client.
5. Spell-specific: single-target projectile — for Bless, possibly the engine's status consolidator
   (Bless is cancelled if the target already has it / is cast from a queue via the
   "fellow party member" context → everything on the caster). A control cast of a different
   single-target friendly buff in the same context is needed.
6. The `TargetingType` field in the request casts: we set `TargetingType = spellType` (e.g. "Target"),
   brawl too; but the engine may require something more for OSIRIS-select of different spell types
   (Target/Zone/Projectile) (see protocol item 4: field_A8/NetGuid/Originator).

## Bench protocol (next live session)
1. Capture the castOptions of a real manual UI-cast of bless from the cleric onto tav
   (log/instrument `EXTVME_CLIENT_CastSpell` / global proxy) — compare with ours.
2. Repeat our cast without `Forced`/`Immediate` (soft `FromClient, NoMovement`) in-range —
   done (c16a): the self-cast persisted, hypothesis 1 refuted.
3. Try a cast from an NPC companion/emissary (not a player) onto the player — does the target binding
   hold with `queue=osiris`? (separate "player-cast-ness" from "emissary-ness").
4. Brawl-style control: the same cast with `field_A8`/NetGuid/Originator` as in brawl.
5. Clean control: in THE SAME combat, cast a single-target friendly buff with another slotless spell
   (Resistance/Guidance inject within ≤2 m) — it will show whether this is spell-specific.
6. Single-target control: inject-cast Bless by the origin ON HIMSELF — if "self-cast worked as expected"
   again, the substitution is only visible with an explicit target (`no-op` for self would make
   the conclusion useless — a genuinely two-entity test is needed).

## SERVER TRUTH vs VISUAL → SUBSTITUTION REFUTED (2026-09-21)
The key to the diagnosis is the difference between "where the status actually is" vs "which icon is seen":
- **The character inventory of whoever currently has the turn shows the real statuses.**
  The "icon" next to the caster for Bless/Guidance is the CONCENTRATION indicator (both spells are
  concentration spells), not a sign that the status landed on the caster.
- `stats_probe` (raw StatusManager across all combatants) is the only reliable, turn-independent
  tool: `bg3_to_neuro.json`/`state_capture` read the same StatusMachine, but show only the status model;
  the UI icons next to the caster were misleading.

Decisive control c23g2 on a clean battle (fresh cleric turn, target Tav 1.03 m, RALLY-only):
- **osiris queue + HARD set** `[Forced, Immediate, IgnoreHasSpell, IgnoreCastChecks,
  IgnoreSpellRolls, IgnoreTargetChecks]`, `forceFlags=true` — the SAME configuration as c07b.
- `prevalidate: pass (range=1.5, dist=1.01, los=1)`, the first run failed (stale
  `GameplayControllerCancelRequests forced=true` in the queues, resources untouched), re-run
  c23g2 → `success:true`, resources unspent (guidance cantrip).
- **stats_probe after: GUIDANCE on Tav (the target), only RALLY on the cleric.**

Verdict: the status of a single-target friendly buff in an in-range cast lands on the request's targetUuid
with ANY combination (soft/hard flags × osiris/network queue). The observed
"self-casts" are an artifact of reading the caster's concentration icon as "status on the caster".
Mechanism No. 2 (target substitution) in its previous form does NOT exist.

Residual risks for closure:
- Icons/projectiles may visually render at the caster (render artifact), but that does not affect
  the mechanics. If the app UX requires a visual match — that is a rendering task,
  not a cast-targeting one.
- Failure of the first cast due to accumulated cancel-requests in the engine queues: resources are not
  spent, a repeat of the same cast succeeds. Documented as a bench gotcha (not a targeting bug).

## Confirmation at >2 m (optional item 1) — 2026-09-21, v0.8.61, live combat

- The turn was advanced to the cleric (`poc_player_cleric`, Shadowheart) in the same battle at the gate; the target —
  **Tav `e6090219…`** at a distance of **4.6 m** (positions (219.9,31.2,408.8) vs (216.1,31.6,411.4)).
- `stats_probe` (raw `StatusManager` across all combatants) **before**: the party has only `RALLY`, `BLESS` no one.
- `cast_spell { spell_name:"bless", target_id:"tav" }` → `cast_debug`: `spellName=Target_Bless`,
  `targetUuid=e6090219…` (Tav), `queue=osiris`, `forceFlags=true`; `result: success:true`.
- Economy (`resource_snapshot_t22_bless_{before,after}`): **AP 1.0→0.0, SpellSlot L1 1.0→0.0**,
  BA 1.0 unchanged — the ticket-18 bug did not return.
- `stats_probe` **after**: **`tav [RALLY, BLESS]`**, `cleric [RALLY]`, astarion/wizard `[RALLY]`.
  → the status landed on the request target; the caster has NO Bless status (what is seen on the caster is concentration).
- Incidental: `cast_spell blessing_of_the_trickster → tav` (4.6 m) honestly rejected by pre-validation
  `no_range: … 4.6 m away (range 2 m)` — the range pre-validation works for cantrips too.

## Answer

Mechanism No. 2 ("in-range cast target substitution") **does not exist** — confirmed twice by server
truth (raw `StatusManager`), including the >2 m control on v0.8.61: the status of a single-target friendly buff
lands on the request's `targetUuid` with any combination of flags and queue. The observed "self-casts"
(tickets 16/22) are an artifact of reading the caster's **concentration** icon as "status on the caster".

**UX decision (item 3, 2026-09-21): accept as cosmetic.** The game's render artifacts (concentration
icon/projectile at the caster) carry no information about the status bearer; the app/Neuro get the truth
from the state/status model, not from the game's portrait icons. No mod/app changes
required. Recorded in `CONTEXT.md` → "Diagnostic traps" and in **`docs/adr/0001-cast-render-artifacts-are-cosmetic.md`**.

Closure criteria met: (1) >2 m control — see above; (2) the trap recorded — `CONTEXT.md`
+ ADR-0001 (+ link from ticket 16); (3) UX decision — taken above.

## Closure criteria (revised)
A server in-range player cast hits the request's targetUuid with all flag/queue
combinations — confirmed by server truth (stats_probe). The ticket is closed after:
1. re-confirmation on another single-target buff from beyond 2 m (access — after
   a rest/new combat, slot L1) — optional, since the mechanism is obvious;
2. recording in ticket 06/ADRs the conclusion "visual icons next to the caster = concentration, not status";
3. a decision on the UX rendering (see residual risks).

## Reproduction data
c07b: actor=3ed74f06… (poc_player_cleric), target=tav e6090219…, Target_Bless range=9,
dist=2.2, los=1, verdict=pass, success:true + cast_debug.json (castOptions/queue/requestGuid).