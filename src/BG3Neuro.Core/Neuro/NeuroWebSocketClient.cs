using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using BG3Neuro.Core.Actions;
using BG3Neuro.Core.Config;

namespace BG3Neuro.Core.Neuro;

public sealed class SessionInfo
{
    public required string SessionId { get; init; }
    public required string CharacterId { get; init; }
    public required string DisplayName { get; init; }
}

public sealed class ActionRequestedEventArgs : EventArgs
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public string? Data { get; init; }
}

public sealed class SessionEventArgs : EventArgs
{
    public required SessionInfo Session { get; init; }
}

public sealed class ConnectionStateChangedEventArgs : EventArgs
{
    public required bool Connected { get; init; }
}

public sealed class NeuroWebSocketClient : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    private readonly string _url;
    private readonly string _game;
    private readonly TimeSpan _reconnectInterval;
    private readonly IReadOnlyList<ActionDefinition> _actions;
    private readonly CancellationTokenSource _cts = new();
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private Task? _loopTask;
    private ClientWebSocket? _ws;
    private bool _disposed;

    public NeuroWebSocketClient(string wsUrl, string game, IReadOnlyList<ActionDefinition> actions, TimeSpan reconnectInterval)
    {
        _url = wsUrl;
        _game = game;
        _actions = actions;
        _reconnectInterval = reconnectInterval;
    }

    public event EventHandler<SessionEventArgs>? SessionStarted;
    public event EventHandler<ActionRequestedEventArgs>? ActionRequested;
    public event EventHandler<ConnectionStateChangedEventArgs>? ConnectionStateChanged;
    public event EventHandler<string>? MessageSent;

    public void Start()
    {
        _loopTask = Task.Run(ConnectLoopAsync);
    }

    public async Task StopAsync()
    {
        if (_disposed)
        {
            return;
        }

        _cts.Cancel();
        try
        {
            if (_ws is not null)
            {
                _ws.Abort();
            }

            if (_loopTask is not null)
            {
                await _loopTask;
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _cts.Cancel();
        _ws?.Dispose();
        _cts.Dispose();
        _sendLock.Dispose();
    }

    public async Task SendResultAsync(string id, bool success, string? message)
    {
        var payload = new ActionResultMessage
        {
            Game = _game,
            Data = new ResultData { Id = id, Success = success, Message = message },
        };
        await SendAsync(payload);
    }

    public async Task SendForceAsync(string? state, string query, IReadOnlyList<string> actionNames)
    {
        var payload = new ForceActionMessage
        {
            Game = _game,
            Data = new ForceData
            {
                State = state,
                Query = query,
                EphemeralContext = true,
                Priority = "low",
                ActionNames = actionNames.ToList(),
            },
        };
        await SendAsync(payload);
    }

    private async Task ConnectLoopAsync()
    {
        var ct = _cts.Token;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await ConnectAndListenAsync(ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception)
            {
            }

            if (ct.IsCancellationRequested)
            {
                break;
            }

            SetConnectionState(false);
            try
            {
                await Task.Delay(_reconnectInterval, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task ConnectAndListenAsync(CancellationToken ct)
    {
        using var ws = new ClientWebSocket();
        _ws = ws;
        await ws.ConnectAsync(new Uri(_url), ct);
        SetConnectionState(true);

        await SendStartupAsync(ct);
        await RegisterAsync(ct);

        var buffer = new byte[1024 * 64];
        while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
        {
            var memory = new Memory<byte>(buffer);
            ValueWebSocketReceiveResult result;
            using var ms = new MemoryStream();
            do
            {
                result = await ws.ReceiveAsync(memory, ct);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "close", ct);
                    return;
                }

                ms.Write(buffer, 0, result.Count);
            }
            while (!result.EndOfMessage);

            var text = Encoding.UTF8.GetString(ms.ToArray());
            if (string.IsNullOrWhiteSpace(text))
            {
                continue;
            }

            await HandleIncomingAsync(text, ct);
        }
    }

    private async Task HandleIncomingAsync(string text, CancellationToken ct)
    {
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(text);
        }
        catch (JsonException)
        {
            return;
        }

        var command = node?["command"]?.GetValue<string>();
        switch (command)
        {
            case "startup":
                HandleStartupAck(node);
                break;
            case "action":
                HandleAction(node);
                break;
            case "actions/reregister_all":
                await RegisterAsync(ct);
                break;
            default:
                break;
        }
    }

    private void HandleStartupAck(JsonNode? node)
    {
        var session = node?["data"]?["session"];
        if (session is null)
        {
            return;
        }

        SessionStarted?.Invoke(this, new SessionEventArgs
        {
            Session = new SessionInfo
            {
                SessionId = session["sessionId"]?.GetValue<string>() ?? "",
                CharacterId = session["characterId"]?.GetValue<string>() ?? "",
                DisplayName = session["displayName"]?.GetValue<string>() ?? "",
            },
        });
    }

    private void HandleAction(JsonNode? node)
    {
        var data = node?["data"];
        if (data is null)
        {
            return;
        }

        var id = data["id"]?.GetValue<string>();
        var name = data["name"]?.GetValue<string>();
        if (id is null || name is null)
        {
            return;
        }

        ActionRequested?.Invoke(this, new ActionRequestedEventArgs
        {
            Id = id,
            Name = name,
            Data = data["data"]?.GetValue<string>(),
        });
    }

    private async Task SendStartupAsync(CancellationToken ct)
    {
        var payload = new StartupMessage { Game = _game };
        await SendAsync(payload, ct);
    }

    private async Task RegisterAsync(CancellationToken ct)
    {
        var payload = new RegisterActionsMessage
        {
            Game = _game,
            Data = new RegisterData
            {
                Actions = _actions.Select(a => new ActionEntry
                {
                    Name = a.Name,
                    Description = a.Description,
                    Schema = a.Schema,
                }).ToList(),
            },
        };
        await SendAsync(payload, ct);
    }

    private async Task SendAsync(object payload, CancellationToken ct = default)
    {
        var json = JsonSerializer.Serialize(payload, JsonOptions);
        await SendTextAsync(json, ct);
    }

    private async Task SendTextAsync(string text, CancellationToken ct)
    {
        var ws = _ws;
        if (ws is null || ws.State != WebSocketState.Open)
        {
            return;
        }

        var bytes = Encoding.UTF8.GetBytes(text);
        await _sendLock.WaitAsync(ct);
        try
        {
            await ws.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, ct);
        }
        finally
        {
            _sendLock.Release();
        }

        MessageSent?.Invoke(this, text);
    }

    private void SetConnectionState(bool connected)
    {
        ConnectionStateChanged?.Invoke(this, new ConnectionStateChangedEventArgs { Connected = connected });
    }
}