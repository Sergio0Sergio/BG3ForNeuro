using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;

namespace BG3Neuro.Core.Tests.Neuro;

public sealed class FakeNeuroServer : IAsyncDisposable
{
    private readonly HttpListener _listener = new();
    private readonly List<WebSocket> _sockets = new();
    private readonly ConcurrentQueue<string> _received = new();
    private readonly CancellationTokenSource _cts = new();
    private Task? _acceptLoop;
    private int _port;

    public string Url => $"ws://127.0.0.1:{_port}/";
    public IReadOnlyCollection<string> Received => _received.ToArray();

    public int ReceiveCount => _received.Count;

    public void Start()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        _port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();

        _listener.Prefixes.Add($"http://127.0.0.1:{_port}/");
        _listener.Start();
        _acceptLoop = Task.Run(AcceptLoopAsync);
    }

    public void Send(string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        lock (_sockets)
        {
            foreach (var socket in _sockets)
            {
                socket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, CancellationToken.None)
                    .GetAwaiter().GetResult();
            }
        }
    }

    public void Send(JsonNode node) => Send(node.ToJsonString());

    public void CloseAllConnections()
    {
        List<WebSocket> snapshot;
        lock (_sockets)
        {
            snapshot = _sockets.ToList();
            _sockets.Clear();
        }

        foreach (var socket in snapshot)
        {
            socket.Abort();
        }
    }

    public async Task<List<JsonNode>> WaitForMessagesAsync(
        Func<IReadOnlyList<JsonNode>, bool> predicate,
        int timeoutMs = 5000)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            var nodes = Received
                .Where(t => !string.IsNullOrWhiteSpace(t))
                .Select(t => JsonNode.Parse(t)!)
                .ToList();
            if (predicate(nodes))
            {
                return nodes;
            }

            await Task.Delay(25);
        }

        var snapshot = Received.Where(t => !string.IsNullOrWhiteSpace(t)).Select(t => JsonNode.Parse(t)!).ToList();
        throw new TimeoutException($"FakeNeuro server: условие не выполнено за {timeoutMs}мс. Получено сообщений: {snapshot.Count}.");
    }

    public async Task WaitForCountAsync(int count, int timeoutMs = 5000)
    {
        var sw = Stopwatch.StartNew();
        while (ReceiveCount < count)
        {
            if (sw.ElapsedMilliseconds >= timeoutMs)
            {
                throw new TimeoutException($"Ожидалось {count} сообщений, получено {ReceiveCount}.");
            }

            await Task.Delay(25);
        }
    }

    private async Task AcceptLoopAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            HttpListenerContext context;
            try
            {
                context = await _listener.GetContextAsync();
            }
            catch
            {
                break;
            }

            try
            {
                var contextWs = await context.AcceptWebSocketAsync(null);
                lock (_sockets)
                {
                    _sockets.Add(contextWs.WebSocket);
                }

                _ = ReceiveLoopAsync(contextWs.WebSocket);
            }
            catch
            {
            }
        }
    }

    private async Task ReceiveLoopAsync(WebSocket socket)
    {
        var buffer = new byte[64 * 1024];
        try
        {
            while (socket.State == WebSocketState.Open)
            {
                ValueWebSocketReceiveResult result;
                using var ms = new MemoryStream();
                do
                {
                    result = await socket.ReceiveAsync(buffer.AsMemory(), _cts.Token);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        return;
                    }

                    ms.Write(buffer, 0, result.Count);
                }
                while (!result.EndOfMessage);

                _received.Enqueue(Encoding.UTF8.GetString(ms.ToArray()));
            }
        }
        catch
        {
        }
        finally
        {
            lock (_sockets)
            {
                _sockets.Remove(socket);
            }

            socket.Dispose();
        }
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        CloseAllConnections();
        _listener.Stop();
        _listener.Close();
        if (_acceptLoop is not null)
        {
            try
            {
                await _acceptLoop;
            }
            catch
            {
            }
        }

        _cts.Dispose();
    }
}