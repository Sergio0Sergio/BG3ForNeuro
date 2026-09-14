# 04 — Combat Action Schemas

Type: grilling
Status: resolved
Blocked by: 01, 03
Depended by: 07

## Answer

Combat Action Schemas — final. (Refined in dialogue.)

**8 actions** — the context provides information, the actions provide the gestures. The LLM itself classifies spells by the description in the context.

### Final schemas

**Common parameter of all actions: `actor?: string`** — alias of the controlled character (from state). Required when `controlledPartySize > 1`, omitted when `party = 1` (the active/turn-taking one acts). The validator checks the turn right against `actor`. **Phase validation (E7):** `bonus_action`/`set_reaction` require the controlled character's turn; another character's turn or not combat → `wrong_phase` (ticket 08, Channel A) with an actionable message, not `invalid_parameters`.

| # | Action | Parameters | Description (for Neuro) |
|---|---|---|---|
| 1 | `move_to_target` | `actor?: string`, `target_id: string` | Move to the specified target |
| 2 | `attack_entity` | `actor?: string`, `target_id: string` | Attack the specified enemy with the main weapon |
| 3 | `cast_spell` | `actor?: string`, `spell_name: string`, `target_id?: string`, `coverage?: string[]`, `position?: {x, y, z}` | Use a spell |
| 4 | `use_item` | `actor?: string`, `item_id: string`, `target_id?: string` | Use an item from the inventory |
| 5 | `throw` | `actor?: string`, `item_id: string`, `target_id: string` | Throw an item at the target |
| 6 | `bonus_action` | `actor?: string`, `action_type: enum` | Perform a bonus action |
| 7 | `set_reaction` | `actor?: string`, `reaction_type: enum` | Choose a reaction for this turn |
| 8 | `end_turn` | `actor?: string` | End the turn |

### Per action

**1. `move_to_target`** — `target_id` (entity alias or point from state) + `actor`. Neuro sees the available movement targets in the state. Schema: `{ "type": "object", "required": ["target_id"], "properties": { "target_id": {"type": "string"}, "actor": {"type": "string"} } }`

**2. `attack_entity`** — `target_id` + `actor` (main hand always, no `weapon_slot` — offhand only via bonus_action). C2: variant B.

**3. `cast_spell`** — C1 (AoE decision):
- `actor` — the caster (required when party > 1)
- `spell_name` — the spell name (from state, source of truth)
- `target_id` — the primary center (enemy/ally)
- `coverage` (optional) — the desired target list for AoE; the plugin centers the blast on the coverage optimum, failure with a list if not everything is reachable
- `position` (optional) — raw center coordinates `{x, y, z}`, fallback path (enabled in config), disabled by default
- AoE coverage and range are computed by the plugin (single code path with StateSerializer, see 03 S3)

**4. `use_item`** — `item_id` + `target_id` (optional). Drinking a potion as an action — here. C3: both paths remain.

**5. `throw`** — `item_id` + `target_id`. **X2 (ticket 07): in v1 the action stays in the schema, but the validator returns `not_supported`** (no public Osiris call; only Anubis/client input — fragile). An honest failure «implemented later», not silence (BEST_PRACTICES).

**6. `bonus_action`** — C4: enum **full always**, an unavailable option → failure with an actionable message (no enum resize; only the action as a whole is reg/dered). C3: includes `drink_potion`.

**7. `set_reaction`** — C4: enum full always, same principle.

**8. `end_turn`** — no parameters.

### Enums (full, fixed)

**bonus_action.action_type:**
- `offhand_attack` — attack with the second hand (requires offhand weapon)
- `drink_potion` — drink a potion (as a second tempo / bonus)
- `help` — help an ally (free from grapple, grant advantage)
- `shove` — shove the target
- `disengage` — avoid opportunity attacks
- `dash` — additional movement
- `dodge` — dodge (attacks against you at disadvantage)

**set_reaction.reaction_type:**
- `opportunity_attack` — opportunity attack (target leaves the reach zone)
- `shield` — Shield reaction (defense against an incoming attack)
- `counterspell` — counterspell (against an enemy spell)
- `none` — don't use a reaction this turn

### Rationale

1. **Single `cast_spell`** — Neuro reads `spell_name` + description in the context and understands the type itself. Splitting into offensive/heal/buff is redundant.
2. **bonus_action with a fixed enum** — bonus actions are mechanically limited (one per turn).
3. **set_reaction with a fixed enum** — reactions are configured before the turn.
4. **offhand via bonus_action, not weapon_slot** — one verb per mechanic (C2 B).
5. **AoE via target_id + coverage** — Neuro can hit one target OR a group with center optimization (C1).
6. **Registration — fixed full set (B, ticket 09-review)**: all 17 actions (8 combat + 1 dialogue + 8 exploration) are registered once at startup and never change. **«Neuro sees 4–8» from the original version — CANCELED** — a stable set speeds up responses (BEST_PRACTICES); relevance is achieved via the state (what is available per turn) + actionable failure, not via registration.

### Execution (X4, ticket 07)

Basic player attacks (`attack_entity`) and `cast_spell` are executed via `Ext.System.ServerCastRequest.OsirisCastRequests` (honest about AP/cooldowns; casting rides the real pipeline rails). `Osi.Attack` (one-shot, without resource accounting) — only enemies/NPC/fallback. `spell_name` — prototype name (`Ext.Stats.Get`), normalization in StateExtractor (X5).

### Risk

BEST_PRACTICES.md: "she tends to fixate on a few of them". Compensation: full fixed set (B, all 17 at startup, set never changes) + a relevant subset via state + actionable failure with a list of options.

### Registration format

Each action is registered as an `Action` (SPECIFICATION.md): `name` (lowercase, underscore), `description` (plain text, 1–2 sentences), `schema` (JSON Schema object). See SPECIFICATION.md and BEST_PRACTICES.md.