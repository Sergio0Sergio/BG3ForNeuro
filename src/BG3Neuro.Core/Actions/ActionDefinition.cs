using System.Text.Json.Nodes;

namespace BG3Neuro.Core.Actions;

public sealed class ActionDefinition
{
    public required string Name { get; init; }
    public required string Description { get; init; }
    public required JsonObject Schema { get; init; }
}