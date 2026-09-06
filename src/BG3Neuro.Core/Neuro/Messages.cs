using System.Text.Json.Nodes;

namespace BG3Neuro.Core.Neuro;

public sealed class StartupMessage
{
    public string Command { get; init; } = "startup";
    public required string Game { get; init; }
}

public sealed class RegisterActionsMessage
{
    public string Command { get; init; } = "actions/register";
    public required string Game { get; init; }
    public RegisterData Data { get; init; } = new();
}

public sealed class RegisterData
{
    public List<ActionEntry> Actions { get; init; } = new();
}

public sealed class ActionEntry
{
    public required string Name { get; init; }
    public required string Description { get; init; }
    public required JsonObject Schema { get; init; }
}

public sealed class ActionResultMessage
{
    public string Command { get; init; } = "action/result";
    public required string Game { get; init; }
    public ResultData Data { get; init; } = new();
}

public sealed class ResultData
{
    public string Id { get; init; } = "";
    public bool Success { get; init; }
    public string? Message { get; init; }
}

public sealed class ForceActionMessage
{
    public string Command { get; init; } = "actions/force";
    public required string Game { get; init; }
    public ForceData Data { get; init; } = new();
}

public sealed class ForceData
{
    public string? State { get; init; }
    public string Query { get; init; } = "";
    public bool EphemeralContext { get; init; } = true;
    public string Priority { get; init; } = "low";
    public List<string> ActionNames { get; init; } = new();
}