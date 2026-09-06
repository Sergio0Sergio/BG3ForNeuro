namespace BG3Neuro.Core.Config;

public sealed class IpcConfig
{
    public string Dir { get; set; } = "";
    public string StateFile { get; set; } = "bg3_to_neuro.json";
    public string CommandFile { get; set; } = "neuro_to_bg3.json";
    public int PollIntervalMs { get; set; } = 100;
    public int HeartbeatIntervalS { get; set; } = 2;
    public int HeartbeatStaleS { get; set; } = 10;
}