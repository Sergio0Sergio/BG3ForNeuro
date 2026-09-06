using System.Text.Json;

namespace BG3Neuro.Core.Ipc;

public sealed class IpcPaths
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    private readonly string _dir;

    public IpcPaths(string dir)
    {
        _dir = dir;
    }

    public string Dir => _dir;

    public string StateFile =>
        Path.Combine(_dir, "bg3_to_neuro.json");

    public string CommandFile =>
        Path.Combine(_dir, "neuro_to_bg3.json");

    public string HeartbeatFile =>
        Path.Combine(_dir, "heartbeat.json");

    public string ActionFile(string actionId) =>
        Path.Combine(_dir, $"action_{actionId}.json");

    public string ResultFile(string actionId) =>
        Path.Combine(_dir, $"result_{actionId}.json");

    public void WriteActionFile(string actionId, string name, string dataJson)
    {
        System.IO.Directory.CreateDirectory(_dir);
        var payload = JsonSerializer.Serialize(new
        {
            id = actionId,
            name,
            data = dataJson,
        }, JsonOptions);
        System.IO.File.WriteAllText(ActionFile(actionId), payload);
    }

    public void WriteCommandFile(string actionId, string name, string dataJson)
    {
        System.IO.Directory.CreateDirectory(_dir);
        var payload = JsonSerializer.Serialize(new
        {
            id = actionId,
            name,
            data = dataJson,
        }, JsonOptions);
        System.IO.File.WriteAllText(CommandFile, payload);
    }

    public void CleanDeadStand()
    {
        try
        {
            if (!System.IO.Directory.Exists(_dir))
            {
                return;
            }

            foreach (var stale in System.IO.Directory.EnumerateFiles(_dir, "action_*.json"))
            {
                System.IO.File.Delete(stale);
            }

            foreach (var stale in System.IO.Directory.EnumerateFiles(_dir, "result_*.json"))
            {
                System.IO.File.Delete(stale);
            }

            if (System.IO.File.Exists(CommandFile))
            {
                System.IO.File.Delete(CommandFile);
            }
        }
        catch (IOException)
        {
        }
    }
}