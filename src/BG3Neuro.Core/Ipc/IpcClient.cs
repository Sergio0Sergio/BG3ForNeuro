using BG3Neuro.Core.Config;

namespace BG3Neuro.Core.Ipc;

public sealed class HeartbeatChangedEventArgs : EventArgs
{
    public required ModStatus Previous { get; init; }
    public required ModStatus Current { get; init; }
}

public sealed class IpcClient : IDisposable
{
    private readonly IpcConfig _config;
    private readonly IClock _clock;
    private readonly IpcPaths _paths;
    private readonly TimeSpan _staleAfter;
    private readonly CancellationTokenSource _cts = new();
    private Task? _pollTask;
    private ModStatus _status = ModStatus.Unknown;
    private HeartbeatPayload? _lastHeartbeat;

    public IpcClient(IpcConfig config, IClock? clock = null)
    {
        _config = config;
        _clock = clock ?? new SystemClock();
        _staleAfter = TimeSpan.FromSeconds(config.HeartbeatStaleS);
        var dir = ResolveDir(config);
        _paths = new IpcPaths(dir);
    }

    public ModStatus Status => _status;

    public string Directory => _paths.Dir;

    public void CleanStand() => _paths.CleanDeadStand();

    public event EventHandler<HeartbeatChangedEventArgs>? HeartbeatChanged;
    public event EventHandler<string>? StateChanged;

    private string? _lastStateContent;

    public void Start()
    {
        System.IO.Directory.CreateDirectory(_paths.Dir);
        _pollTask = Task.Run(PollLoopAsync);
    }

    public async Task StopAsync()
    {
        _cts.Cancel();
        if (_pollTask is not null)
        {
            try
            {
                await _pollTask;
            }
            catch (OperationCanceledException)
            {
            }
        }
    }

    public void Dispose() => _cts.Dispose();

    public ModStatus PollOnce(DateTimeOffset? nowUtc = null)
    {
        var now = nowUtc ?? _clock.UtcNow;
        var heartbeat = HeartbeatFile.TryRead(_paths.HeartbeatFile);
        if (heartbeat is not null)
        {
            _lastHeartbeat = heartbeat;
        }

        var next = HeartbeatStatus.Evaluate(_lastHeartbeat, now, _staleAfter);

        if (next != _status)
        {
            var previous = _status;
            _status = next;
            HeartbeatChanged?.Invoke(this, new HeartbeatChangedEventArgs
            {
                Previous = previous,
                Current = next,
            });
        }

        return _status;
    }

    public string? LastStateContent => _lastStateContent;

    public ActionExecutionResult? ReadExecutionResult(string actionId) =>
        ActionResultFile.TryRead(_paths.ResultFile(actionId));

    public string? ReadState()
    {
        var content = StateFile.TryReadContent(_paths.StateFile);
        if (content is not null && content != _lastStateContent)
        {
            _lastStateContent = content;
            StateChanged?.Invoke(this, content);
        }

        return content;
    }

    private async Task PollLoopAsync()
    {
        var interval = TimeSpan.FromMilliseconds(_config.PollIntervalMs);
        while (!_cts.IsCancellationRequested)
        {
            PollOnce();
            ReadState();
            try
            {
                await Task.Delay(interval, _cts.Token);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private static string ResolveDir(IpcConfig config)
    {
        if (!string.IsNullOrWhiteSpace(config.Dir) &&
            config.Dir != "<BG3ScriptExtender appdata>/BG3Neuro")
        {
            return config.Dir;
        }

        return ConfigLoader.DefaultConfigDir;
    }
}