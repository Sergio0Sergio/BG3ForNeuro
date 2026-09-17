using System.Text.Json;
using System.Text.Json.Nodes;
using BG3Neuro.Core.Actions;
using BG3Neuro.Core.Config;
using BG3Neuro.Core.Ipc;

namespace BG3Neuro.Core.State;

public sealed class ActionRouter
{
    private static readonly string[] ExplorationActionNames =
    {
        "move_to_entity", "interact_with", "loot",
        "open_map", "open_inventory", "toggle_mode", "rest", "travel_to",
    };

    private readonly IpcPaths _paths;
    private readonly bool _multiParty;
    private readonly DialogueConfig _dialogue;

    public ActionRouter(IpcPaths paths, int controlledPartySize, DialogueConfig? dialogue = null)
    {
        _paths = paths;
        _multiParty = controlledPartySize > 1;
        _dialogue = dialogue ?? new DialogueConfig();
    }

    public ValidationResult ValidateAndDispatch(string actionId, string actionName, string? dataJson, CombatState? combatState, ModStatus modStatus)
    {
        if (modStatus == ModStatus.Stale)
        {
            return ValidationResult.Fail(ErrorCode.ModUnavailable, "Mod unavailable (heartbeat is stale)");
        }

        var definition = Actions.ActionRegistry.Find(actionName);
        if (definition is null)
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, $"Unknown action: {actionName}");
        }

        JsonNode? data = null;
        if (!string.IsNullOrWhiteSpace(dataJson))
        {
            try
            {
                data = JsonNode.Parse(dataJson);
            }
            catch (JsonException)
            {
                return ValidationResult.Fail(ErrorCode.InvalidParameters, "Malformed JSON in action parameters");
            }
        }
        else
        {
            data = new JsonObject();
        }

        if (data is not JsonObject dataObj)
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, "Action parameters must be a JSON object");
        }

        var schemaResult = ValidateSchema(definition, dataObj);
        if (schemaResult is not null)
        {
            return schemaResult;
        }

        var phaseResult = ValidatePhase(actionName, dataObj, combatState);
        if (phaseResult is not null)
        {
            return phaseResult;
        }

        var dialogueResult = ValidateDialogueOption(actionName, dataObj, combatState);
        if (dialogueResult is not null)
        {
            return dialogueResult;
        }

        var explorationResult = ValidateExploration(actionName, dataObj, combatState);
        if (explorationResult is not null)
        {
            return explorationResult;
        }

        _paths.WriteActionFile(actionId, actionName, dataObj.ToJsonString());
        _paths.WriteCommandFile(actionId, actionName, dataObj.ToJsonString());

        return ValidationResult.Ok();
    }

    private ValidationResult? ValidateSchema(ActionDefinition definition, JsonObject data)
    {
        var required = definition.Schema["required"]?.AsArray();
        if (required is not null)
        {
            foreach (var item in required)
            {
                var key = item?.GetValue<string>();
                if (key is not null && !data.ContainsKey(key))
                {
                    return ValidationResult.Fail(ErrorCode.InvalidParameters, $"Missing required parameter: {key}");
                }
            }
        }

        var properties = definition.Schema["properties"]?.AsObject();
        if (properties is not null)
        {
            foreach (var (propName, propSchema) in properties)
            {
                if (!data.TryGetPropertyValue(propName, out var value) || value is null)
                {
                    continue;
                }

                var allowed = propSchema?["enum"]?.AsArray()
                    .Select(e => e?.GetValue<string>())
                    .Where(s => s is not null)
                    .ToHashSet();
                if (allowed is { Count: > 0 } && value is JsonValue)
                {
                    var actual = value.GetValue<string>();
                    if (!allowed.Contains(actual))
                    {
                        return ValidationResult.Fail(
                            ErrorCode.InvalidParameters,
                            $"Parameter {propName} has invalid value '{actual}'. Allowed: {string.Join(", ", allowed)}");
                    }
                }
            }
        }

        return null;
    }

    private ValidationResult? ValidateDialogueOption(string actionName, JsonObject data, CombatState? combatState)
    {
        if (actionName != "select_dialogue_option")
        {
            return null;
        }

        if (!_dialogue.IsEnabled)
        {
            return ValidationResult.Fail(ErrorCode.NotSupported,
                $"ClientAutoselectExecutor unavailable: dialogue.mode='{_dialogue.Mode}'. Enable 'autoselect'/'confirm' in config.json");
        }

        if (combatState is null || combatState.Mode != "dialogue" || combatState.Dialogue is null)
        {
            return ValidationResult.Fail(ErrorCode.DialogueClosed,
                "No active dialogue: the dialogue closed or never started. Start the dialogue again and repeat your choice.");
        }

        if (combatState.Dialogue.Options.Count == 0)
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, "Dialogue has no reply options (option_index has nothing to apply to).");
        }

        int index;
        try
        {
            index = data["option_index"]?.GetValue<int>() ?? 0;
        }
        catch (JsonException)
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, "Parameter option_index must be a number.");
        }

        if (index < 1 || index > combatState.Dialogue.Options.Count)
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters,
                $"Reply option {index} out of range: available 1..{combatState.Dialogue.Options.Count}. Provide a number from the reply list.");
        }

        return null;
    }

    private ValidationResult? ValidateExploration(string actionName, JsonObject data, CombatState? combatState)
    {
        if (!ExplorationActionNames.Contains(actionName))
        {
            return null;
        }

        if (combatState is null)
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, "No game state data");
        }

        if (combatState.Mode is not ("exploration" or "map" or "inventory"))
        {
            return ValidationResult.Fail(ErrorCode.WrongPhase,
                $"Action '{actionName}' is only available outside combat. Current mode '{combatState.Mode}' — use an action of that mode.");
        }

        if (_multiParty && data["actor"] is null)
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, "Parameter actor is required when party size is greater than one");
        }

        var actor = data["actor"]?.GetValue<string>();
        if (actor is not null && !combatState.Allies.Any(a => a.Alias == actor))
        {
            return ValidationResult.Fail(ErrorCode.WrongPhase, $"Character '{actor}' is not in the party");
        }

        if (actionName is "move_to_entity" or "interact_with" or "loot")
        {
            return ValidateExplorationTarget(actionName, data, combatState);
        }

        if (actionName == "travel_to")
        {
            return ValidateTravel(data, combatState);
        }

        if (actionName == "rest")
        {
            if (!combatState.CanRest)
            {
                return ValidationResult.Fail(ErrorCode.NoCamp,
                    "Cannot rest: no camp/valid rest point or insufficient supplies. Move to the camp and try again (rest full/partial).");
            }
        }

        return null;
    }

    private ValidationResult? ValidateExplorationTarget(string actionName, JsonObject data, CombatState state)
    {
        var targetId = data["target_id"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(targetId))
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, "Parameter target_id is required");
        }

        var target = state.Objects.FirstOrDefault(o => o.Alias == targetId);
        if (target is null)
        {
            var known = state.Objects.Select(o => o.Alias).OrderBy(a => a, StringComparer.Ordinal).ToList();
            return ValidationResult.Fail(ErrorCode.TargetMissing,
                $"Object '{targetId}' not found. Visible objects: {string.Join(", ", known)}");
        }

        if (actionName == "interact_with")
        {
            var interaction = data["interaction_type"]?.GetValue<string>();
            if (string.IsNullOrWhiteSpace(interaction))
            {
                if (target.Interactions.Count == 0)
                {
                    return ValidationResult.Fail(ErrorCode.InvalidParameters, $"Object '{target.Name}' has no available interactions.");
                }

                data["interaction_type"] = target.Interactions[0];
                return null;
            }

            if (target.Interactions.Count == 0)
            {
                return ValidationResult.Fail(ErrorCode.InvalidParameters, $"Object '{target.Name}' has no available interactions.");
            }

            var match = target.Interactions.FirstOrDefault(i =>
                string.Equals(i, interaction, StringComparison.OrdinalIgnoreCase));
            if (match is null)
            {
                return ValidationResult.Fail(ErrorCode.InvalidParameters,
                    $"Interaction '{interaction}' is not available for '{target.Name}'. Available: {string.Join(", ", target.Interactions)}");
            }

            data["interaction_type"] = match;
        }

        if (actionName == "loot" && !target.Lootable)
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, $"'{target.Name}' has no loot: the object has no inventory.");
        }

        return null;
    }

    private ValidationResult? ValidateTravel(JsonObject data, CombatState state)
    {
        var destination = data["destination"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(destination))
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, "Parameter destination is required");
        }

        if (state.Regions.Count == 0)
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, "No known locations to travel to");
        }

        var regionId = data["region_id"]?.GetValue<string>();
        TravelLocation? match;
        if (!string.IsNullOrWhiteSpace(regionId))
        {
            match = state.Regions.FirstOrDefault(r =>
                !string.IsNullOrWhiteSpace(r.RegionId) &&
                string.Equals(r.RegionId, regionId, StringComparison.OrdinalIgnoreCase));
        }
        else
        {
            match = state.Regions.FirstOrDefault(r =>
                string.Equals(r.Name, destination, StringComparison.OrdinalIgnoreCase));
        }

        if (match is null)
        {
            var available = state.Regions
                .Select(r => r.Name + (string.IsNullOrWhiteSpace(r.RegionId) ? "" : $" (id: {r.RegionId})"))
                .ToList();
            return ValidationResult.Fail(ErrorCode.InvalidParameters,
                $"Location '{destination}'{(string.IsNullOrWhiteSpace(regionId) ? "" : $" (region_id: {regionId})")} not found. Available: {string.Join(", ", available)}");
        }

        return null;
    }

    private ValidationResult? ValidatePhase(string actionName, JsonObject data, CombatState? combatState)
    {
        var requiresCombatPhase = actionName is "end_turn" or "bonus_action" or "set_reaction" or
            "move_to_target" or "attack_entity" or "cast_spell" or "use_item" or "throw";

        if (requiresCombatPhase)
        {
            if (combatState is null || string.IsNullOrEmpty(combatState.TurnActor))
            {
                return ValidationResult.Fail(ErrorCode.NotInCombat, "No active combat");
            }

            if (_multiParty && data["actor"] is null)
            {
                return ValidationResult.Fail(ErrorCode.InvalidParameters, "Parameter actor is required when party size is greater than one");
            }

            var actor = data["actor"]?.GetValue<string>() ?? combatState.TurnActor;

            var isControlled = combatState.Allies.Any(a => a.Alias == actor);
            if (!isControlled)
            {
                return ValidationResult.Fail(ErrorCode.WrongPhase, $"It is not the controlled character '{actor}' turn. It is: {combatState.TurnActor}");
            }

            if (actor != combatState.TurnActor)
            {
                return ValidationResult.Fail(ErrorCode.WrongPhase, $"It is '{combatState.TurnActor}' turn now, not '{actor}'");
            }
        }

        var targetResult = ValidateTarget(actionName, data, combatState);
        if (targetResult is not null)
        {
            return targetResult;
        }

        if (actionName == "cast_spell")
        {
            var castResult = ValidateCast(data, combatState);
            if (castResult is not null)
            {
                return castResult;
            }
        }

        if (actionName == "throw")
        {
            return ValidationResult.Fail(ErrorCode.NotSupported, "Action throw is not supported in v1");
        }

        return null;
    }

    private ValidationResult? ValidateCast(JsonObject data, CombatState? combatState)
    {
        var spellName = data["spell_name"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(spellName))
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, "Parameter spell_name is required");
        }

        if (combatState is null || combatState.Spells is null || combatState.Spells.Count == 0)
        {
            return ValidationResult.Fail(ErrorCode.NoSpell, "Spell list is empty: no known spells");
        }

        var spell = combatState.Spells.FirstOrDefault(s =>
            string.Equals(s.SpellName, spellName, StringComparison.OrdinalIgnoreCase));
        if (spell is null)
        {
            // v0.8.35 (тикет 09): Neuro зовёт способности по понятному имени
            // (state.spells[].name, напр. "flourish"); принимаем и его, и stat-id.
            spell = combatState.Spells.FirstOrDefault(s =>
                !string.IsNullOrWhiteSpace(s.Name) &&
                string.Equals(s.Name, spellName, StringComparison.OrdinalIgnoreCase));
        }

        if (spell is null)
        {
            var known = combatState.Spells
                .Select(s => string.IsNullOrWhiteSpace(s.Name) ? s.SpellName : s.Name)
                .OrderBy(n => n, StringComparer.Ordinal)
                .ToList();
            return ValidationResult.Fail(ErrorCode.NoSpell, $"Spell '{spellName}' unavailable. Known: {string.Join(", ", known)}");
        }

        // Понятное имя -> движковый stat-id: мод исполняет по stat-id (проверено на Flourish).
        if (!string.Equals(spell.SpellName, spellName, StringComparison.OrdinalIgnoreCase))
        {
            data["spell_name"] = spell.SpellName;
        }

        if (spell.OnCooldown)
        {
            return ValidationResult.Fail(ErrorCode.NoSpell, $"Spell '{spellName}' is on cooldown");
        }

        if (spell.CastsLeft is 0)
        {
            return ValidationResult.Fail(ErrorCode.NoSpell, $"Spell '{spellName}' has no charges left");
        }

        var actor = data["actor"]?.GetValue<string>() ?? combatState.TurnActor;
        var caster = combatState.Allies.FirstOrDefault(a => a.Alias == actor);

        var targetId = data["target_id"]?.GetValue<string>();
        if (!string.IsNullOrWhiteSpace(targetId))
        {
            var target = combatState.Enemies.FirstOrDefault(e => e.Alias == targetId);
            if (target is null)
            {
                return ValidationResult.Fail(ErrorCode.TargetMissing, $"Target '{targetId}' not found among enemies");
            }

            if (caster is not null && !CoverageAuto.IsInRange(caster, target, spell.Range))
            {
                return ValidationResult.Fail(ErrorCode.TargetNotInRange, $"Target '{targetId}' is out of range of '{spellName}'");
            }
        }
        else if (spell.Aoe > 0 && data["coverage"] is not null)
        {
            var requested = data["coverage"]!.AsArray()
                .Select(x => x?.GetValue<string>())
                .Where(x => x is not null)
                .ToList();
            if (caster is not null && requested.Count > 0)
            {
                var coverage = CoverageAuto.BestAoECenter(caster, combatState.Enemies, spell.Range, spell.Aoe);
                var achievable = coverage.Covered.ToHashSet();
                var missing = requested.Where(r => r is not null && !achievable.Contains(r)).OrderBy(r => r, StringComparer.Ordinal).ToList();
                if (missing.Count > 0)
                {
                    return ValidationResult.Fail(ErrorCode.TargetNotInRange,
                        $"Not all targets are covered: {string.Join(", ", missing)}. Covered: [{string.Join(", ", coverage.Covered)}]");
                }
            }
        }

        return null;
    }

    private ValidationResult? ValidateTarget(string actionName, JsonObject data, CombatState? combatState)
    {
        if (actionName is not ("move_to_target" or "attack_entity"))
        {
            return null;
        }

        var targetId = data["target_id"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(targetId))
        {
            return ValidationResult.Fail(ErrorCode.InvalidParameters, "Parameter target_id is required");
        }

        if (combatState is null)
        {
            return null;
        }

        var enemyAlias = combatState.Enemies.Any(e => e.Alias == targetId);
        var allyAlias = combatState.Allies.Any(a => a.Alias == targetId);

        var targetIsKnown = actionName == "attack_entity" ? enemyAlias : enemyAlias || allyAlias;
        if (!targetIsKnown)
        {
            return ValidationResult.Fail(ErrorCode.TargetMissing, $"Target '{targetId}' not found among enemies");
        }

        return null;
    }
}
