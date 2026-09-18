using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BG3Neuro.Core.Actions;

public static class ActionRegistry
{
    private const string ResourceName = "BG3Neuro.Core.Actions.action_schemas.json";

    private static readonly Lazy<IReadOnlyList<ActionDefinition>> All = new(Load);

    public static IReadOnlyList<ActionDefinition> Get() => All.Value;

    public static ActionDefinition? Find(string name) =>
        All.Value.FirstOrDefault(a => a.Name == name);

    private static IReadOnlyList<ActionDefinition> Load()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException($"Embedded resource not found: {ResourceName}");
        using var reader = new StreamReader(stream);
        var json = reader.ReadToEnd();

        var nodes = JsonSerializer.Deserialize<List<JsonNode>>(json, JsonOptions)
            ?? throw new InvalidOperationException("Failed to parse the action registry");

        var result = new List<ActionDefinition>(nodes.Count);
        foreach (var node in nodes)
        {
            if (node["internal"]?.GetValue<bool>() == true)
            {
                continue;
            }

            result.Add(new ActionDefinition
            {
                Name = node["name"]?.GetValue<string>() ?? throw new InvalidOperationException("Action without name"),
                Description = node["description"]?.GetValue<string>() ?? "",
                Schema = node["schema"]?.AsObject() ?? new JsonObject(),
            });
        }

        return result;
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };
}