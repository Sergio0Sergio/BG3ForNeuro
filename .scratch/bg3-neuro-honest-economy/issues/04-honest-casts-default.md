# 04 — Moving casts to the honest path by default

Type: grilling
Status: resolved
Blocked by:

## Answer

Owner's decisions (grill 2026-09-13):

- **Players honest, NPCs — Osiris.** The honest path is the default for players only (native resources/cooldowns from PreparedSpells, `enqueueCastRequest`); NPC casts stay on the Osiris source (`IgnoreHasSpell` + SourceType "Osiris") — minimal risk, scripted NPC casts don't break.
- **Queue ordering — auto insertAtFront on own turn.** If the caster is a player and the turn is active (canAct/actingChar), the request is placed AT THE FRONT of the queue (like brawl during an FTB pause) — the cast resolves now, not after foreign requests. `data.insert_at_front` is kept as a manual override; when the flag is absent — the rule by canAct.
- **Honest-path failure (hybrid counter of 03) = an enqueue error only** (the request didn't enter ServerCastRequest). CastSpellFailed does NOT increment — it's a valid in-game outcome (no target/resources), not a failure of the cast machinery.
- **Fallback (BG3Neuro.lua:2185)** — replace the current unconditional `not ok → Osi.UseSpell` with the hybrid of ticket 03: on an enqueue error pick up legacy for the call, after 3 in a row — persistent legacy until restart. The per-action `data.use_osi_spell` remains an explicit command on top of the hybrid.
- Finalization via `pendingCasts`/`CastedSpell`/`CastSpellFailed` — works, does NOT change.
- For NPCs: `enqueueCastRequest` already splits players/NPCs (PreparedSpells vs Osiris, lines 1743-1774) — we reuse it, no new code added.

Output for implementation: `executeCast` — `enqueueCastRequest` for players by default (already safe as is), insertAtFront selection by canAct, fallback via `pipelineFallback()` with the shared counter from 03. Ticket 05's answer uses the same nodes for bonus actions.

## Question

Fact v0.8.24 (bench/code): player casts ALREADY go the honest path by default — `use_osi_spell=false` → `enqueueCastRequest` (BG3Neuro.lua:2175), Osi.UseSpell only on an explicit flag.

Output: a list of changes in `executeCast`, ready for implementation.