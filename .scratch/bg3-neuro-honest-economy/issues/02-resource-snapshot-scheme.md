# 02 — Confirming before/after resource snapshots as the readiness criterion

Type: task
Status: resolved
Blocked by:

Assets: `research/02-resource-snapshot-scheme.md` (scheme), v0.8.24 (tool in the mod).

## Answer

The snapshot is implemented and confirmed on the bench (v0.8.24, combat at the gates, Astarion). Live-test facts 2026-09-13:

- **attack_entity (ServerCastRequest, honest path)**: AP `1.0 → 0.0` (−1), BonusActionPoint 1.0→1.0, Movement 9.0→9.0, Reaction 1.0→1.0. The expected main-attack delta of −1 AP is confirmed — the snapshot works as the honesty criterion. Files: `Script Extender/BG3Neuro/resource_snapshot_v024-attack-2_{before,after}.json`.
- **bonus action (dash `Shout_Dash`)**: went into `CastSpellFailed`, BonusActionPoint stayed 1.0→1.0. Dash/hide/disengage are NOT spellbook spells (not in PreparedSpells), they don't deduct BA through ServerCastRequest → this is ticket 05's territory (bonus actions need their own path: `CastOffhand` + `BonusActionPoint:1`), NOT the snapshot's territory.
- **move_to_target**: success (`result_v024-move-1.json success:true`), position changed. No movement snapshot was taken — movement lives in ticket 06.
- **SpellBookCooldowns**: `Ext.Json.Stringify` does NOT serialize `spell::SpellBookCooldownsComponent` (userdata) — it errored and took down the attack itself (Stringify ran outside pcall). Fix: recursive `unwrapField` unpacking into primitives, stringify in pcall. In the snapshot, cooldowns are written as the string `spell::SpellBookCooldownsComponent (…)` — the component's value can only be read as userdata; cooldowns need a separate API layer (decision in tickets 04/05), while the AP/BA/Movement snapshots remain correct.

Practice:
- Tool: `writeResourceSnapshot(id, actor, phase)` + the `before` (after cancelActiveMove, before the pipeline) and `after` (CastedSpell/CastSpellFailed, immediate Osi.Attack) points.
- Snapshot calls only inside `pcall` — a snapshot failure must not crash the action.

Unblocks: 04 (honest-cast criterion — snapshot ready), 05 (bonuses — the AP/BA snapshot is taken from the honest path, a dedicated pipeline is needed).

## Question

The map's readiness criterion (Q3) — "resource snapshots before/after the action in a live bench test, the fact recorded in the ticket". What should the snapshots contain and how should they be collected so they objectively prove the honest deduction of AP/bonus/cooldowns?

Question decomposition:
- Which values to capture: `Osi.GetActionResourceValuePersonal` (which resource names: ActionPoint, BonusActionPoint?), `SpellBookCooldowns` (Ext.Entity.Get(caster).SpellBookCooldowns), what else.
- Capture points: strictly before the pipeline call and after the `CastedSpell`/`CastSpellFailed` event.
- Where to write and in what format (file, a field in diagnostics).
- Ordering: does the value require timing (BG3SE single-threaded — event points only).
- (supplement from ticket 01) A bench snapshot of the caster's `SpellBookPrepares.PreparedSpells` — the set of `OriginatorPrototype` weapon spells (melee/ranged) — the same bench task as the resource snapshot; recorded as a fact for ticket 01.

Output: a draft of the snapshot scheme + a list of the APIs the resolving "Honesty Criterion" ticket relies on. This is a task, not research: the question isn't about external knowledge, but about what to capture from the bench.