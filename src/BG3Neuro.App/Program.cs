using BG3Neuro.Core.Actions;
using BG3Neuro.Core.Config;
using BG3Neuro.Core.Ipc;
using BG3Neuro.Core.Neuro;
using BG3Neuro.Core.State;

namespace BG3Neuro.App;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        var configPath = args.Length > 0 ? args[0] : "config.json";
        AppConfig config;

        try
        {
            config = ConfigLoader.Load(configPath);
        }
        catch (ConfigException ex)
        {
            Console.Error.WriteLine($"[config] {ex.Message}");
            return 1;
        }

        Console.WriteLine($"[bg3neuro] config: {configPath}");
        Console.WriteLine($"[ipc] dir={config.Ipc.Dir}, poll={config.Ipc.PollIntervalMs}ms, heartbeat_stale={config.Ipc.HeartbeatStaleS}s");
        Console.WriteLine($"[neuro] ws={config.Neuro.WsUrl}, reconnect={config.Neuro.ReconnectIntervalS}s, game={config.Game.Name}");

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            cts.Cancel();
        };

        using var ipc = new IpcClient(config.Ipc);
        ipc.HeartbeatChanged += (_, e) =>
        {
            var stamp = DateTimeOffset.Now.ToString("HH:mm:ss.fff");
            Console.WriteLine($"[{stamp}] [ipc] mod: {e.Previous} -> {e.Current}");
        };
        ipc.Start();
        Console.WriteLine($"[ipc] listening heartbeat: {ipc.Directory}");

        var router = new ActionRouter(new IpcPaths(ipc.Directory), config.Game.ControlledPartySize, config.Dialogue);

        using var neuro = new NeuroWebSocketClient(
            config.Neuro.WsUrl,
            config.Game.Name,
            ActionRegistry.Get(),
            TimeSpan.FromSeconds(config.Neuro.ReconnectIntervalS));

        using var decisionLoop = new DecisionLoop(neuro, ipc, router, config.State.Exploration, TimeSpan.FromSeconds(config.Actions.ResultTimeoutS));
        decisionLoop.DebugNote += (_, text) =>
        {
            var stamp = DateTimeOffset.Now.ToString("HH:mm:ss.fff");
            Console.WriteLine($"[{stamp}] {text}");
        };

        neuro.ConnectionStateChanged += (_, e) =>
        {
            var stamp = DateTimeOffset.Now.ToString("HH:mm:ss.fff");
            Console.WriteLine($"[{stamp}] [neuro] {(e.Connected ? "connected" : "disconnected")}");
        };
        neuro.SessionStarted += (_, e) =>
        {
            var stamp = DateTimeOffset.Now.ToString("HH:mm:ss.fff");
            Console.WriteLine($"[{stamp}] [neuro] session: {e.Session.DisplayName} ({e.Session.SessionId})");
        };
        neuro.ActionRequested += (_, e) =>
        {
            var stamp = DateTimeOffset.Now.ToString("HH:mm:ss.fff");
            Console.WriteLine($"[{stamp}] [neuro] action: {e.Name} id={e.Id} data={e.Data ?? "(none)"}");
        };

        neuro.Start();
        decisionLoop.Start();
        Console.WriteLine($"[neuro] connecting to {config.Neuro.WsUrl}, {ActionRegistry.Get().Count} actions registered (Ctrl+C to quit)");

        try
        {
            await Task.Delay(Timeout.Infinite, cts.Token);
        }
        catch (OperationCanceledException)
        {
        }

        await neuro.StopAsync();
        await ipc.StopAsync();
        Console.WriteLine("[bg3neuro] exiting");
        return 0;
    }
}