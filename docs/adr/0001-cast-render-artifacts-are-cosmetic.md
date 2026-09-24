# ADR-0001: Cast render artifacts at the caster are cosmetic, not a signal

- **Status:** accepted (2026-09-21)
- **Context:** tickets 16 and 22 (`bg3-neuro-followups`)
- **Related:** `CONTEXT.md` → «Diagnostic pitfalls»

## Context

During server-side casting of a single-target friendly buff (Bless, Guidance) by the player onto an ally,
"self-casts" were observed: the icon/projectile visually at the caster, making it seem that the
status landed not on the requested target. A series of live benches reading **raw `StatusManager`**
(`stats_probe`) showed: the status always lands on the `targetUuid` of the request under any
combination of `force_flags` × queue (osiris/network) × soft/hard CastOptions set.
"Icon at the caster" is an indicator of the caster's **concentration**, not the status carrier.

Control check on v0.8.61 (2026-09-21), combat at the gate: `bless` cleric → Tav at 4.6 m →
`stats_probe` after: `tav [RALLY, BLESS]`, `cleric [RALLY]`; economy AP 1.0→0.0,
SpellSlot L1 1.0→0.0.

## Decision

1. **Source of truth for the status carrier is the state model, not the game visuals:**
   raw `StatusManager` (`stats_probe`), the turn owner's status inventory,
   `bg3_to_neuro.json`/`state_capture`. Portrait icons and visual effects of the game
   are not indicative for cast mechanics.
2. **Visual artifacts at the caster are accepted as cosmetic.** The mod and the app
   do not try to "fix" them; rendering is outside our layer. Neuro/the app get the
   truth from the state/status model.
3. Diagnostic texts and tickets do not use the term "self-cast" for this
   observation (closed in tickets 16/22).

## Consequences

- Savings: we do not spend budget on a "render fix" that does not affect mechanics.
- Risk: if the UX will need visual alignment — that is a separate rendering task,
  not cast targeting (outside the mod's scope).
- If "self-cast" reports reappear — run `stats_probe` first, rather than trusting the
  icon.