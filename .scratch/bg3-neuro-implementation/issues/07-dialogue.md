# 07: Dialogue (select_dialogue_option)

**What to build:** The full dialogue path: a dialogue starts → Neuro receives the dialogue state (lines and options, numbered in UI order) → Neuro sends `select_dialogue_option` with `option_index`. There is no public Osiris selection function (research §7.2), so execution goes through `ClientAutoselectExecutor`: the client context (Lua script on the game side) finds the UI option by index, highlights it and clicks it; the human clicks nothing. If the client script is unavailable → `not_supported` + warning. The dialogue closed earlier → `dialogue_closed`.

**Blocked by:** 03 (combat loop/execution pattern).

**Status:** done

- [x] The dialogue state exposes options with numbers matching the UI order (option_index). — `CombatState.Dialogue{SpeakerName,Line,Options[]}` (+ snake_case parsing), `## Dialogue` render with `[1]..[N]`; the "option_index == UI order" principle — the source of the options is the same (client), fallback `not_supported`.
- [x] `select_dialogue_option` with `option_index` performs the selection via ClientAutoselectExecutor (highlight + click), success/failure in the unified action/result format. — Lua v0.5.0 `executeDialogueOption` (client context, `running:true` + final on `DialogEnded`); action file + `action/result` (Channel A) on C#.
- [x] Client script unavailable → `not_supported` + warning, the dialogue does not hang. — Router: `DialogueConfig.IsEnabled` (mode `autoselect`/`confirm`, alias `confirm`) → `NotSupported` (Channel A) without writing an action file; Lua: `Ext.UI == nil` → `not_supported` (Channel B detail).
- [x] Dialogue closed before the choice → `dialogue_closed` (Channel A/B per §6.5 dictionary). — Router: mode != dialogue / no block → `DialogueClosed`; index out of range → `InvalidParameters` with the range.
- [x] End-to-end test: dialogue opened → option selected → state advances. — Randy E2E: dialogue state → force (`## Dialogue`, `[1] Yes, I am ready.`) → selection → action file → mode=combat → second force confirmed.

**Summary:** `Dialogue`/`DialogueOption` in the model + dialogue force in `DecisionLoop` (content-based dedup) + `ValidateDialogueOption` (dialogue_closed / invalid_parameters by range / not_supported by flag) + Lua v0.5.0; 104/104 tests (was 98), build 0 warnings, 0 node processes after the run. The client click (real UI click) — TODO(client) in Lua, isolated behind the action layer, degrades to not_supported.