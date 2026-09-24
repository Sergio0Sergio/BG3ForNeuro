# Research 01 — Perception signals in BG3SE

Date: 2026-09-20. Ticket: `issues/01-perception-signal-api.md`.
Sources: local copy of the BG3SE sources and the game's Lua libraries:
- `%TEMP%\opencode\bg3se\Osi.lua` (list of Osi functions), `osi_signatures.txt`, `Docs\API.md`
- `%TEMP%\opencode\bg3se\brawl_Pick.lua`, `brawl_Actions.lua`, `brawl_AI.lua` (game AI libraries that read visibility)
- `%TEMP%\opencode\research_bg3\brawl_Utils.lua` (`isVisible`), `brawl_Memo.lua` (list of cacheable Osi calls), `ExtIdeHelpers.lua` (reversal of component/flag fields)

Note: the research subagent returned an empty result this session; the work was done directly on a map session.

## Candidates

| Signal | What it provides | Limitations | Verdict |
|---|---|---|---|
| `Osi.CanSee(source, target)` → int bool (`Osi.lua:216`) | Engine answer "can source see target" (careful: includes LOS + invisibility + stealth) | Semantics undocumented; cost per call; a live probe is needed | **Primary candidate** |
| `Osi.CanSeeCached(source, target)` → int bool (`Osi.lua:221`) | Same, with the engine cache | Cache freshness unknown | Candidate for performance |
| `Osi.HasLineOfSight(source, target)` → 1/0 (`Osi.lua:1373`) | Pure geometry (walls/obstacles), without statuses | Does not account for invisibility/stealth | **Geometry refinement** |
| `Osi.IsInvisible(object)` → int (`Osi.lua:1686`) | Target invisibility | Not about LOS | Explanatory signal |
| `Osi.HasActiveStatus(uuid, "SNEAKING"/"INVISIBLE")` | Stealth/invisibility as a status | An exact status set is needed | Explanatory signal |
| Viewshed components: `Sight`, `SightEntityViewshed`, `ServerViewshedParticipant`, `ServerSightAggregatedData`, `ServerSightEntityViewshedContentsChanged`, `ServerSightEntityLosCheckQueue` (`ExtIdeHelpers.lua:857-868, 1080`) | Internal server viewshed system (authoritative, event-driven) | Reading from Lua not confirmed; complex | Deferred (candidate for the future) |
| Flags `ServerCharacterFlags.Invisible/SpotSneakers`, `StatCharacterFlags.Invisible/IsSneaking/Blind` | Coarse flags | Not about party perception | Auxiliary |
| `Osi.ShroudRender` / `NETMSG_SHROUD_UPDATE` | **Map** fog (territory reveal) | Not about entity visibility | Not our signal |

## What the engine itself does (reference)

The game's AI library `brawl_Utils.lua:266`:
```lua
local function isVisible(uuid, targetUuid)
    if HasActiveStatus(uuid,"TRUESIGHT") or HasActiveStatus(uuid,"MOD_Generic_Truesight") then return true end
    local hasSeeInvisibility = HasActiveStatus(uuid,"SEE_INVISIBILITY")
        or HasActiveStatus(uuid,"MAG_SEE_INVISIBILITY_HIDDEN_IGNORE_RESTING")
    if hasSeeInvisibility and GetDistanceTo(uuid,targetUuid) <= 9 then return true end
    return Osi.IsInvisible(targetUuid) == 0 and Osi.HasActiveStatus(targetUuid,"SNEAKING") == 0
end
```
Important: this is **statuses only** (invisibility/stealth/truesight) and **without geometry** — walls are not taken into account. The game adds geometry separately elsewhere: `brawl_Pick.lua:551` → `Osi.CanSee(...) == 1`; `brawl_Actions.lua:339`/`brawl_Pick.lua:293` → `Osi.HasLineOfSight(...) == 0/1`.

## Recommendation

Composition, not a single signal:

1. **`Osi.CanSee(partyMember, target) == 1`** — iterate over any party member (OR). This is the engine's "sees", the closest to "perceived".
2. If a "why"/cheap refinement is needed — **`Osi.HasLineOfSight`** (geometry) + `IsInvisible`/`SNEAKING` (status). Provides material for `known` (LOS loss for a non-status reason).
3. Performance: if `CanSee` is expensive — `CanSeeCached`, or restrict the check to entities within radius (`EXPLORE_MAX_DISTANCE`) and recompute only on viewshed events.

Explicitly: **there is no clean single "does the party perceive" API** — composition is needed, and the `CanSee`/`CanSeeCached` semantics must be confirmed with a live probe (this is the input to ticket 02).

## Open questions for the prototype (02)

- Exact `CanSee` semantics: does it include light/darkness, FOV cones, height?
- Client/server difference: are `CanSee`/`HasLineOfSight` available in both mod contexts.
- Cost per tick with N×M calls; whether a cache is worth it.
- Does `CanSee` catch stealth (SNEAKING) — or does it need to be mixed in via a status.