using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using BG3Neuro.Core.Config;

namespace BG3Neuro.Core.State;

public static class StateSerializer
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
    };

    public static CombatState? Parse(string json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return null;
        }

        try
        {
            var node = JsonNode.Parse(json);
            NormalizeKeys(node);
            return node.Deserialize<CombatState>(JsonOptions);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static void NormalizeKeys(JsonNode? node)
    {
        if (node is not JsonObject obj)
        {
            return;
        }

        var entries = obj.ToList();
        obj.Clear();
        foreach (var (key, value) in entries)
        {
            obj[ConfigLoader.ToSnakeCase(key)] = value;
            NormalizeKeys(value);
        }
    }

    public static string ToMarkdown(CombatState state, ExplorationStateConfig? exploration = null)
    {
        if (state.Mode == "dialogue" && state.Dialogue is not null)
        {
            return ToDialogueMarkdown(state);
        }

        if (IsExplorationMode(state.Mode))
        {
            return ToExplorationMarkdown(state, exploration ?? new ExplorationStateConfig());
        }

        var sb = new StringBuilder();

        var active = state.Allies.FirstOrDefault(c => c.Alias == state.TurnActor);
        var activeName = active?.Name ?? state.TurnActor;
        sb.Append("## Turn: ").Append(activeName);
        if (state.TurnInitiativeTotal > 0)
        {
            sb.Append(" (initiative ").Append(state.TurnInitiativeIndex).Append('/').Append(state.TurnInitiativeTotal).Append(')');
        }

        sb.AppendLine();

        sb.AppendLine("## Allied characters");
        foreach (var ally in state.Allies)
        {
            sb.Append("- ").Append(ally.Name)
              .Append(": HP ").Append(ally.Hp).Append('/').Append(ally.MaxHp)
              .Append(", distance ").Append(FormatDistance(ally.Distance)).Append('m');
            if (!string.IsNullOrWhiteSpace(ally.Availability))
            {
                sb.Append(", availability: ").Append(ally.Availability);
            }

            AppendConditions(sb, ally.Conditions);

            sb.AppendLine();
        }

        sb.AppendLine("## Enemies");
        foreach (var enemy in state.Enemies)
        {
            sb.Append("- ").Append(enemy.Alias).Append(" (").Append(enemy.Name).Append(')')
              .Append(": HP ").Append(enemy.Hp).Append('/').Append(enemy.MaxHp)
              .Append(", distance ").Append(FormatDistance(enemy.Distance)).Append('m')
              .Append(", status: ").Append(string.IsNullOrWhiteSpace(enemy.Status) ? "—" : enemy.Status);
            AppendConditions(sb, enemy.Conditions);
            sb.AppendLine();
        }

        if (state.Spells.Count > 0)
        {
            sb.Append("## Spells (").Append(activeName).Append(')').AppendLine();
            foreach (var spell in state.Spells)
            {
                var friendly = string.IsNullOrWhiteSpace(spell.Name) ? spell.SpellName : spell.Name;
                sb.Append("- ").Append(friendly);
                if (!string.IsNullOrWhiteSpace(spell.Name) &&
                    !string.Equals(spell.Name, spell.SpellName, StringComparison.OrdinalIgnoreCase))
                {
                    sb.Append(" (").Append(spell.SpellName).Append(')');
                }

                sb.Append(": ");
                if (!string.IsNullOrWhiteSpace(spell.Cost))
                {
                    sb.Append("cost ").Append(spell.Cost).Append(", ");
                }

                if (!string.IsNullOrWhiteSpace(spell.Slot) && spell.Slot != "0")
                {
                    sb.Append("slot ").Append(spell.Slot).Append(", ");
                }

                sb.Append("range ").Append(FormatDistance(spell.Range)).Append('m');
                if (spell.Aoe > 0)
                {
                    sb.Append(", AoE ").Append(FormatDistance(spell.Aoe)).Append('m');
                }

                if (spell.CastsLeft.HasValue)
                {
                    sb.Append(", charges left: ").Append(spell.CastsLeft.Value);
                }

                if (spell.OnCooldown)
                {
                    sb.Append(", on cooldown");
                }

                sb.Append(" → in range: ").Append(FormatInRange(state, spell));
                sb.AppendLine();
            }
        }

        sb.Append("## Available actions (").Append(activeName).Append(')').AppendLine();
        if (state.AvailableActions.Count == 0)
        {
            sb.AppendLine("- end_turn");
        }
        else
        {
            foreach (var action in state.AvailableActions)
            {
                sb.Append("- ").Append(action).AppendLine();
            }
        }

        if (state.Events.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("## Events");
            foreach (var ev in state.Events)
            {
                sb.Append("- ").Append(ev).AppendLine();
            }
        }

        return sb.ToString();
    }

    private static string ToDialogueMarkdown(CombatState state)
    {
        var sb = new StringBuilder();
        var dialogue = state.Dialogue!;

        sb.AppendLine("## Dialogue");
        sb.Append("Speaker: ").Append(string.IsNullOrWhiteSpace(dialogue.SpeakerName) ? "—" : dialogue.SpeakerName).AppendLine();
        sb.Append("Line: ").Append(string.IsNullOrWhiteSpace(dialogue.Line) ? "—" : dialogue.Line).AppendLine();
        sb.AppendLine("Reply options:");
        foreach (var option in dialogue.Options)
        {
            sb.Append("- [").Append(option.OptionIndex).Append("] ")
              .Append(string.IsNullOrWhiteSpace(option.Text) ? "—" : option.Text).AppendLine();
        }

        sb.AppendLine();
        sb.AppendLine("## Available actions");
        foreach (var action in state.AvailableActions)
        {
            sb.Append("- ").Append(action).AppendLine();
        }

        if (state.Events.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("## Events");
            foreach (var ev in state.Events)
            {
                sb.Append("- ").Append(ev).AppendLine();
            }
        }

        return sb.ToString();
    }

    private static bool IsExplorationMode(string mode) =>
        mode is "exploration" or "map" or "inventory";

    private static string ToExplorationMarkdown(CombatState state, ExplorationStateConfig exploration)
    {
        var sb = new StringBuilder();

        sb.AppendLine(state.Mode == "map"
            ? "## Screen: map"
            : state.Mode == "inventory"
                ? "## Screen: inventory"
                : "## Mode: exploration");

        if (state.Mode == "exploration" && state.Objects.Count > 0)
        {
            sb.AppendLine();
            var objects = state.Objects;
            var capped = exploration.MaxVisibleObjects > 0 && objects.Count > exploration.MaxVisibleObjects
                ? objects.Take(exploration.MaxVisibleObjects).ToList()
                : objects;
            sb.Append("## Objects (").Append(objects.Count).Append(')').AppendLine();
            foreach (var obj in capped)
            {
                sb.Append("- ").Append(obj.Alias);
                if (!string.IsNullOrWhiteSpace(obj.Name))
                {
                    sb.Append(" (").Append(obj.Name).Append(')');
                }

                if (state.Mode == "exploration")
                {
                    sb.Append(' ').Append(FormatExplorationDistance(obj.Distance, obj.Region, exploration.DistanceFormat));
                }

                if (!string.IsNullOrWhiteSpace(obj.Status))
                {
                    sb.Append(", ").Append(obj.Status);
                }

                if (obj.Interactions.Count > 0)
                {
                    sb.Append(": [").Append(string.Join(", ", obj.Interactions)).Append(']');
                }
                else if (obj.Lootable)
                {
                    sb.Append(": [take]");
                }

                sb.AppendLine();
            }

            if (objects.Count > capped.Count)
            {
                sb.Append("- … and ").Append(objects.Count - capped.Count).Append(" more").AppendLine();
            }

            sb.AppendLine();
        }

        if (state.Regions.Count > 0)
        {
            sb.AppendLine("## Locations (travel)");
            foreach (var region in state.Regions)
            {
                sb.Append("- ").Append(region.Name);
                if (!string.IsNullOrWhiteSpace(region.RegionId))
                {
                    sb.Append(" (id: ").Append(region.RegionId).Append(')');
                }

                sb.Append(": ").Append(FormatExplorationDistance(region.Distance, region.Region, exploration.DistanceFormat)).AppendLine();
            }

            sb.AppendLine();
        }

        if (state.Mode == "inventory" && state.Inventory.Count > 0)
        {
            sb.AppendLine("## Items");
            foreach (var item in state.Inventory)
            {
                sb.Append("- ").Append(item.Name).Append(" (").Append(item.Alias).Append(')');
                if (item.Quantity > 1)
                {
                    sb.Append(" ×").Append(item.Quantity);
                }

                if (!string.IsNullOrWhiteSpace(item.Category))
                {
                    sb.Append(", ").Append(item.Category);
                }

                sb.AppendLine();
            }

            sb.AppendLine();
        }

        sb.AppendLine("## Rest");
        sb.AppendLine(state.CanRest
            ? "- rest: [full, partial]"
            : "- Unavailable: no camp or supplies (no_camp)");

        sb.AppendLine();
        sb.AppendLine("## Available actions");
        var actions = state.AvailableActions.Count > 0
            ? state.AvailableActions
            : DefaultExplorationActions(state);
        foreach (var action in actions)
        {
            sb.Append("- ").Append(action).AppendLine();
        }

        if (state.Events.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("## Events");
            foreach (var ev in state.Events)
            {
                sb.Append("- ").Append(ev).AppendLine();
            }
        }

        return sb.ToString();
    }

    private static List<string> DefaultExplorationActions(CombatState state)
    {
        var actions = new List<string>();
        if (state.Objects.Count > 0)
        {
            actions.Add($"move_to_entity: [{string.Join(", ", state.Objects.Select(o => o.Alias))}]");
            var interactable = state.Objects.Where(o => o.Interactions.Count > 0).Select(o => o.Alias).Distinct().ToList();
            if (interactable.Count > 0)
            {
                actions.Add($"interact_with: [{string.Join(", ", interactable)}]");
            }

            var lootable = state.Objects.Where(o => o.Lootable).Select(o => o.Alias).Distinct().ToList();
            if (lootable.Count > 0)
            {
                actions.Add($"loot: [{string.Join(", ", lootable)}]");
            }
        }

        if (state.Regions.Count > 0)
        {
            actions.Add($"travel_to: [{string.Join(", ", state.Regions.Select(r => r.Name))}]");
        }

        if (state.CanRest)
        {
            actions.Add("rest: [full, partial]");
        }

        actions.Add(state.Mode == "map"
            ? "open_map"
            : state.Mode == "inventory"
                ? "open_inventory"
                : "open_map, open_inventory, toggle_mode: [normal]");
        return actions;
    }

    private static string FormatExplorationDistance(double meters, string? region, string format)
    {
        if (format == "region" && !string.IsNullOrWhiteSpace(region))
        {
            return $"region: {region}";
        }

        if (format == "hybrid" && meters > 50 && !string.IsNullOrWhiteSpace(region))
        {
            return $"region: {region}";
        }

        return $"{FormatDistance(meters)}m";
    }

    private static string FormatInRange(CombatState state, SpellInfo spell)
    {
        if (state.TurnActor is null)
        {
            return "(no data)";
        }

        var caster = state.Allies.FirstOrDefault(a => a.Alias == state.TurnActor);
        if (caster is null)
        {
            return "(no data)";
        }

        if (spell.Aoe > 0)
        {
            var coverage = CoverageAuto.BestAoECenter(caster, state.Enemies, spell.Range, spell.Aoe);
            return coverage.Covered.Count > 0
                ? $"covers: [{string.Join(", ", coverage.Covered)}] ({coverage.Covered.Count} targets)"
                : "(no targets in range)";
        }

        var inRange = CoverageAuto.TargetsInRange(caster, state.Enemies, spell.Range);
        return inRange.Count > 0
            ? $"[{string.Join(", ", inRange)}]"
            : "(no targets in range)";
    }

    private static string FormatDistance(double meters)
    {
        return meters.ToString("0.##").Replace(',', '.');
    }

    private static void AppendConditions(StringBuilder sb, List<StatusCondition> conditions)
    {
        if (conditions.Count == 0)
        {
            return;
        }

        var parts = conditions.Select(condition =>
        {
            var label = string.IsNullOrWhiteSpace(condition.Name) ? condition.Id : condition.Name;
            return condition.TurnsLeft is int turns ? $"{label} ({turns})" : label;
        });
        sb.Append(", conditions: ").Append(string.Join(", ", parts));
    }
}
