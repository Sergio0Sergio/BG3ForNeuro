# 03 — State Format

Type: grilling
Status: resolved
Blocked by: 01
Depended by: 04, 05, 06

## Answer

State format is defined. (Resolved in live dialogue.)

### S1 — Branching by scenario

Three generators: `combat`, `dialogue`, `exploration`. Switched by the active mode. One `StateSerializer`, branching. Less noise for the LLM.

### S2 — Combat state

Markdown, no `#` top-level, structure via `##`. Meters as the distance unit (the BG3 engine works in meters, the same language used in the spell UI). Full set of actions (8 from ticket 04): `move_to_target`, `attack_entity`, `cast_spell`, `throw`, `use_item`, `bonus_action`, `set_reaction`, `end_turn`. Distance to enemies/targets — in meters, not close/medium/far.

```markdown
## Turn: Karlach (initiative 3/5)
## Controlled characters
- Karlach: HP 45/60, distance from (reference point) 6m, effects: Rage (3 rounds)...
## Enemies
- goblin_1 (Goblin Raider): HP 12/18, distance 6m, status: —
## Spells (Karlach)
- Fireball: slot 3, radius 18m, AoE 4m → in radius: [goblin_1, goblin_2]
## Available actions (Karlach)
- move_to_target: [<movement targets>]
- attack_entity: [goblin_1, goblin_2]
- cast_spell: [Fireball, Magic Missile] (slot 3: 2)
- throw: [health_potion, javelin] → [goblin_1, goblin_2]
- use_item: [health_potion]
- bonus_action: [offhand_attack, help, shove]
- set_reaction: [opportunity_attack, shield]
- end_turn
```

### S3 — Hybrid: distance + in radius/AoE

Both layers together:
- `distance: 6m` per enemy (O(N))
- `→ in radius: [list]` per spell (O(N) per spell), computed by the plugin from coordinates + range
- For AoE: `→ covers: [goblin_1, goblin_2] (2 targets)` — the plugin computes the optimal centering
- Spell with no targets in radius: `(no targets in radius)`
- NOT O(spells × enemies) — avoid noise
- Requirement: **single code path** for range/AoE calculations in StateSerializer and ActionRouter (state ↔ validator consistency)

### S4 — Dialogue state: text + hint, numbers = UI window

```markdown
## Dialogue with Astarion (attitude: neutral)
He says: "..."
## Reply options
1. "We must go. This is important."
2. "You're right, let's postpone it."
3. "I have a question about Cazador." [Persuasion]
4. [Leave the dialogue]
```

- **Option numbers = order in the BG3 dialogue window UI (1-based)** — the plugin numbers them the same way the game shows them. Matches streamer mode (viewers suggest a number, Neuro sees the same one).
- `select_dialogue_option` accepts `option_index` (primary) + `option_text` (fallback, matched by text).
- Do not show difficulty metadata (DC).

### S5 — Exploration state: awareness as a filter

- **Filter = character awareness** (game's visibility/perception, not radius, not top-N). Each controlled character has its own set. **Characters in stealth/invisibility are not visible** (BEST_PRACTICES: don't enable cheating, human-like).
- `maxVisibleObjects: 20` (config) — upper limit with "and N more" note.
- Entity data — only from what is visible to the player, never from absolute coordinates.

```markdown
## Mode: normal
## Objects (visible to Karlach, 5)
- goblin_camp_sign (readable, 5m)
...
## Objects (visible to Shadowheart, 3)
...
## Available actions
- move_to_entity: [...]
- interact_with: [...]
- open_map
- toggle_mode: [normal]
```

### S5 config

Everything is moved into `config.json`, three blocks `combat`/`dialogue`/`exploration` with defaults:

```json
"state": {
  "combat":     { "showQuestMarker": false },
  "dialogue":   { },
  "exploration": {
    "showQuestMarker": true,
    "maxVisibleObjects": 20,
    "objectInfo": { "visible": true, "skillRequirements": false },
    "distanceFormat": "hybrid",     // meters | region | hybrid
    "showPosition": false
  }
}
```

- S5.2 quest marker: exploration true (compass), combat false
- S5.3 visible signs true, skill requirements false (no cheating)
- S5.4 distanceFormat: hybrid — close ones ≤50m in meters, far ones "region: name"
- S5.5 showPosition: false — absolute position not needed, geometry in distances

### S6 — Identity: DON'T write "You are Neuro" in the header

Following BEST_PRACTICES:
- The identity "Neuro, playing BG3" — she knows it from `startup` + characterId. Not repeated.
- Startup context (silent=true, one time) — game rules, how to read the state, the meaning of actions, style (human-like).
- Header of each force — **only dynamics**: «You control: Karlach [+ party]. Mode: combat. Turn: Karlach.»
- No periodic repetition of static information.