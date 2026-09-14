# 05 — Dialogue Action Schemas

Type: grilling
Status: resolved
Blocked by: 01, 03
Depended by: 07

## Answer

Dialogue Action Schemas — final. (Refined in dialogue.)

### Action

**One action — `select_dialogue_option`** (D1). Leaving/interrupting/skipping — regular options in the state (BG3 provides them in the answer list). No `skip_dialogue`/`end_dialogue`.

**Schema:**
```json
{
  "name": "select_dialogue_option",
  "description": "Select one of the proposed dialogue response options.",
  "schema": {
    "type": "object",
    "required": ["option_index"],
    "properties": {
      "option_index": { "type": "integer", "minimum": 1 },
      "option_text":   { "type": "string" }
    }
  }
}
```

- `option_index` — **primary**: the option number, matching the order in the BG3 dialogue window UI (1-based, see ticket 03 S4). Matches streamer mode.
- `option_text` — fallback: if Neuro wrote the text but missed the index, the plugin matches by text itself and substitutes the index.

### Dynamic registration — PERSISTENT (D2)

`select_dialogue_option` is registered **once at startup** (together with the combat and exploration actions). No reg/dereg when opening/closing a dialogue.

- Inactive dialogue → validation returns a failure: «There is no active dialogue right now.»
- Matches BEST_PRACTICES: "Register everything you can once at startup, and avoid rapidly registering and unregistering actions".
- Race protection: the dialogue closed, Neuro sends the choice late → failure, not a missing action.

### Dialogue context (state, D5)

```markdown
## Dialogue: Astarion (attitude: neutral)

Astarion: "I don't think we should go there..."

## Reply options
1. "We must go. This is important."
2. "You're right, let's postpone it."
3. "I have a question about Cazador." [Persuasion]
4. [Leave the dialogue]
```

- Header: who is speaking with + attitude (the player-visible part)
- The last NPC line
- Options with type hints ([Persuasion], etc., from S4)
- Don't show reputation numbers (the math) — only what the player sees
- Option number = order in the UI window

### Edge cases

**Forced dialogue (an enemy attacks during dialogue)** (D4):
- The dialogue is interrupted by the game automatically
- DecisionLoop switches the state mode: combat > dialogue (surprise attack)
- `select_dialogue_option` stays registered (persistent), validation will return a failure if there is no active dialogue

### Out of scope

**Trading (buy/sell)** (D3) — outside this ticket and the whole map. «[Trading]» in dialogue is a regular option; selecting it opens the trading screen — a separate UI type (outside scope). Noted in the map's Out of scope.

### Registration format

As an `Action` (SPECIFICATION.md): name, description (plain text), schema (JSON Schema object, type object). Enum/stability requirements — from BEST_PRACTICES.md.