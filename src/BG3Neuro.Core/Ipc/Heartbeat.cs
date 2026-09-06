namespace BG3Neuro.Core.Ipc;

public enum ModStatus
{
    Unknown,
    Alive,
    Stale,
}

public sealed class HeartbeatPayload
{
    public string Mod { get; set; } = "";
    public string Version { get; set; } = "";
    public long Seq { get; set; }
    public DateTimeOffset Timestamp { get; set; }
}