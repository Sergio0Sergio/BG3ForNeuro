namespace BG3Neuro.Core.Config;

public sealed class AppConfig
{
    public NeuroConfig Neuro { get; set; } = new();
    public IpcConfig Ipc { get; set; } = new();
    public GameConfig Game { get; set; } = new();
    public ActionsConfig Actions { get; set; } = new();
    public DialogueConfig Dialogue { get; set; } = new();
    public StateConfig State { get; set; } = new();
    public AutopilotConfig Autopilot { get; set; } = new();

    /// <summary>Multi-agent (spec §12): one entry per Neuro. Kept empty = single-agent v1
    /// (one WS client with no owned character).</summary>
    public List<AgentConfig> Agents { get; set; } = new();
}

/// <summary>Multi-agent entry (spec §12): which character this agent owns and where to connect.
/// <see cref="WsUrl"/> empty = fall back to <see cref="NeuroConfig.WsUrl"/>.</summary>
public sealed class AgentConfig
{
    public string CharacterId { get; set; } = "";
    public string OwnedAlias { get; set; } = "";
    public string WsUrl { get; set; } = "";
}