# 06 — Honest movement deduction (API)

Type: research
Status: resolved
Blocked by:

## Question

Q6, the owner's default: movement is deducted manually before/after (available AP is re-snapshotted, the "extra" is refunded). What does the current BG3SE offer for this node?

Research the API and facts:
- `Osi.CharacterMoveTo`/`CharacterMoveToPosition` — do they consume AP themselves? (in live tests, movement didn't spend AP)
- Is there an honest "with AP" movement channel (e.g., parameters/Overloaded versions), or will we have to manually track AP before/after the movement and refund the difference.
- APIs for reading/writing movement resources: `Osi.GetActionResourceValuePersonal`, `Osi.TransferActionResource` — signatures and applicability to movement.
- What the native movement cost looks like in BG3 (movement points vs AP) — what the game deducts during normal character movement through the client.
- Coordination with `cancelActiveMove`/`blockingUntil` in Lua (BG3SE single-threaded).

Output: facts + a working "manually before/after" variant (which calls, in what order) that the optional ticket-decision will rely on.

## Answer

`CharacterMoveTo`/`CharacterMoveToPosition` do NOT deduct AP (resource-less signature, scenario mechanism; Brawl precedent) — confirmed by live tests. `Osi.TransferActionResource` does NOT exist in Osi.lua (983 symbols) — a made-up name. The "before/after" variant works with two fixes: (1) snapshot by the `"Movement"` resource (meters, resourceLevel=0; `MovementPoint` is not valid), (2) since the game itself deducts nothing for Osiris movement, there's nothing to "refund as extra" — the mod manages the spent distance itself. Order: snapshot in dispatch → movement → final ONLY from the event (`EntityEvent`/`CharacterMoveToCancelled`), deduct/refund in the same callback. Writing APIs: `AddActionPoints` (AP only, −1 proven live), `PartyIncreaseActionResourceValue` (any resource, but party risk — a bench test is needed). Findings: research/06-movement-ap-spend.md