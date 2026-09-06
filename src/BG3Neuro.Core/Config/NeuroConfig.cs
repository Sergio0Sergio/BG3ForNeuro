namespace BG3Neuro.Core.Config;

public sealed class NeuroConfig
{
    public string WsUrl { get; set; } = "ws://localhost:8000";
    public int ReconnectIntervalS { get; set; } = 3;
}