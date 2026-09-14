# 02 — Movement manual cost is specified but not implemented

Type: follow-up (code-review)
Status: open
Blocked by: bench (writer selection)

## Finding

The honest-economy map claims full delivery — `map.md:32` "All 5 map tickets (01-06) are resolved and executed" — but ticket 06's deliverable is **not in the code**:

- `map.md:5` — "movement is deducted manually (before/after)"; `map.md:24` — "the mod manages the distance itself … deduction finalizes only in the movement-completion event callback".
- Code: `executeMoveToTarget` (BG3Neuro.lua:2384-2414) only calls `CharacterMoveTo(...)`/`CharacterMoveToPosition`; the completion callback (right after) only writes the result. No `AddActionPoints`/`PartyIncreaseActionResourceValue` for movement anywhere.
- `research/06:143` itself defers the deduction "to a separate ticket" — so the map's "executed" claim over-reaches (its executed bullets list only 4 items, none for 06).

## Fix proposal

1. Create the movement-deduction ticket the research promised: before/after Movement-resource snapshot (`resourceLevel=0`, meters) + deduction in the movement-completion event callback, writer picked on the bench (no `TransferActionResource`; `PartyIncreaseActionResourceValue` has party semantics risk).
2. Once implemented, correct the map: split the "executed" claim from "specified, backend pending".