namespace BG3Neuro.Core.Config;

public sealed class AppConfig
{
    public NeuroConfig Neuro { get; set; } = new();
    public IpcConfig Ipc { get; set; } = new();
    public GameConfig Game { get; set; } = new();
    public ActionsConfig Actions { get; set; } = new();
    public DialogueConfig Dialogue { get; set; } = new();
    public StateConfig State { get; set; } = new();
}