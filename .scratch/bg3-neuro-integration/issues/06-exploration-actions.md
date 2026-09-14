# 06 — Exploration Action Schemas

Type: grilling
Status: resolved
Blocked by: 01, 03
Depended by: 07

## Answer

Exploration Action Schemas — final. (Refined in dialogue.)

### Action set

**Common parameter of all actions: `actor?: string`** — alias of the controlled character (from state). Required when `controlledPartySize > 1`, omitted when `party = 1`. Analogous to combat actions (04).

| # | Action | Parameters | Description |
|---|---|---|---|
| 1 | `move_to_entity` | `actor?: string`, `target_id: string` | Move to the target |
| 2 | `interact_with` | `actor?: string`, `target_id: string`, `interaction_type?: string` | Interact with an object |
| 3 | `loot` | `actor?: string`, `target_id: string` | Loot a corpse/container |
| 4 | `open_map` | `actor?: string` | Open the map (view) |
| 5 | `open_inventory` | `actor?: string` | Open the inventory (view) |
| 6 | `toggle_mode` | `actor?: string`, `target_id?: string`, `mode: "normal"` | Switch mode |
| 7 | `rest` | `actor?: string`, `rest_type: "full" \| "partial"` | Rest |
| 8 | `travel_to` | `actor?: string`, `destination: string`, `region_id?: string` | Travel to a location |

### Per action

**1. `move_to_entity`** — `target_id` by the alias of an aware object.

**2. `interact_with`** — E4: free-form `interaction_type` (not an enum!) from the state:
```json
{ "target_id": "wooden_door", "interaction_type": "lockpick" }
```
- Matches BEST_PRACTICES: a changing set of interactions → free-form parameter + runtime validation
- In the state (03) show the available interactions: `wooden_door (closed, 3m): [open, bash, shove]`
- Validation: mismatch → failure with an actionable message («The door has available: open, bash, shove»)
- `interaction_type` omitted → default (first/«open»)

**3. `loot`** — E5: separate action (a frequent gesture in BG3, Neuro orders it explicitly).

**4/5. `open_map` / `open_inventory`** — E3: **variant B** — view + existing actions.
- `open_map` → map screen state (locations/areas for `travel_to`)
- `open_inventory` → inventory state (items; usage — via `use_item` from the combat schemas)
- Equip/drop/sort/trade — out of scope

**6. `toggle_mode`** — E2: `target_id?` (default: the active one; required when party > 1) + `mode` enum. **X3 (ticket 07): in v1 the enum is only `["normal"]`, `"stealth"` removed** — no public Osiris API for toggling stealth (client-side mechanic; ApplyStatus — fragile, status names change). `"stealth"` will return when a stable solution appears (client-UI / status experiment).

**7. `rest`** — E1: `rest_type` enum [full, partial]. Neuro chooses how many supplies to spend.

**8. `travel_to`** — E2 (refined): `destination` = **region name** (primary); `region_id?` — optional, for disambiguation with ambiguous names. The state (03 S5.4) shows the mapping `[Region name (id: xxx)]` with distance in hybrid format.

### Notes

- Combat transition from exploration — automatic (DecisionLoop, ticket 01), not via actions.
- Aliases and awareness — from tickets 01, 03.
- UI clicks inside map/inventory — not given to Neuro (state view only).

### Registration format

As an `Action` (SPECIFICATION.md): name, description (plain text), schema (JSON Schema object). These actions are registered at startup (persistent, see 05 D2).