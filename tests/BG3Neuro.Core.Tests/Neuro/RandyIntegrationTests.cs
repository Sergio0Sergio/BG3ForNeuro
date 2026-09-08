using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using BG3Neuro.Core.Actions;
using BG3Neuro.Core.Neuro;
using Xunit;

namespace BG3Neuro.Core.Tests.Neuro;

[CollectionDefinition("Randy", DisableParallelization = true)]
public class RandyCollection
{
}

[Collection("Randy")]
public class RandyIntegrationTests
{
    private const string Game = "Baldur's Gate 3";

    private static string RandyDir => LocateRandyDir();

    private static (string FileName, string Args)? BuildStartCommand(string randyDir)
    {
        var tsxCli = Path.Combine(randyDir, "node_modules", "tsx", "dist", "cli.mjs");
        if (!File.Exists(tsxCli))
        {
            return null;
        }

        return ("node", $"\"{tsxCli}\" index.ts");
    }

    private static string LocateRandyDir()
    {
        var dir = AppContext.BaseDirectory;
        while (dir is not null && !File.Exists(Path.Combine(dir, "BG3Neuro.sln")))
        {
            dir = Directory.GetParent(dir)?.FullName;
        }

        if (dir is null)
        {
            return "";
        }

        var sdkDir = Directory.GetDirectories(dir).FirstOrDefault(d =>
            new DirectoryInfo(d).Name.EndsWith("-sdk", StringComparison.OrdinalIgnoreCase));
        if (sdkDir is null)
        {
            return "";
        }

        var inner = Directory.GetDirectories(sdkDir).FirstOrDefault(d =>
            new DirectoryInfo(d).Name.EndsWith("-sdk", StringComparison.OrdinalIgnoreCase));
        if (inner is null)
        {
            return "";
        }

        return Path.Combine(inner, "Randy");
    }

    private readonly Process? _randy;
    private readonly string _randyStartupError = "";
    private readonly bool _randyStarted;
    private readonly int _wsPort;
    private readonly int _httpPort;
    private readonly HashSet<int> _preexistingNodePids = new();

    public RandyIntegrationTests()
    {
        if (!Directory.Exists(RandyDir))
        {
            _randyStartupError = $"Папка Randy не найдена: {RandyDir}";
            return;
        }

        if (!Directory.Exists(Path.Combine(RandyDir, "node_modules", "tsx")))
        {
            _randyStartupError = "node_modules/tsx отсутствует: выполните npm install в папке Randy";
            return;
        }

        var cmd = BuildStartCommand(RandyDir);
        if (cmd is null)
        {
            _randyStartupError = "node_modules/tsx/dist/cli.mjs не найден";
            return;
        }

        _wsPort = GetFreePort();
        _httpPort = GetFreePort();

        foreach (var p in Process.GetProcessesByName("node"))
        {
            _preexistingNodePids.Add(p.Id);
        }

        _randy = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = cmd.Value.FileName,
                Arguments = cmd.Value.Args,
                WorkingDirectory = RandyDir,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            },
        };
        _randy.StartInfo.Environment["RANDY_WS_PORT"] = _wsPort.ToString();
        _randy.StartInfo.Environment["RANDY_HTTP_PORT"] = _httpPort.ToString();
        _randy.Start();
        _ = Task.Run(() => _randy.StandardOutput.ReadToEndAsync());
        _ = Task.Run(() => _randy.StandardError.ReadToEndAsync());
        _randyStarted = WaitForOpenPort(_wsPort, TimeSpan.FromSeconds(40));
        if (!_randyStarted)
        {
            _randyStartupError = $"Randy не открыл порт {_wsPort} за 40с. stderr: {_randy.StandardError.ReadToEnd()}";
        }
    }

    [Fact]
    public async Task ConnectToRandy_Registers21Actions_AndHandlesReregister()
    {
        Assert.True(_randyStarted, $"Randy не готов: {_randyStartupError}");

        try
        {
            using var client = new NeuroWebSocketClient($"ws://localhost:{_wsPort}", Game, ActionRegistry.Get(), TimeSpan.FromSeconds(1));
            var sentMessages = new List<string>();
            client.MessageSent += (_, text) => sentMessages.Add(text);

            var actionTcs = new TaskCompletionSource<ActionRequestedEventArgs>(TaskCreationOptions.RunContinuationsAsynchronously);
            client.ActionRequested += (_, e) => actionTcs.TrySetResult(e);

            client.Start();

            var startupSeen = await WaitUntilAsync(() => sentMessages.Any(m => m.Contains("\"startup\"")), TimeSpan.FromSeconds(10));
            Assert.True(startupSeen, "Клиент не отправил startup в Randy за 10с");

            var registerSeen = await WaitUntilAsync(() => sentMessages.Count(m => m.Contains("\"actions/register\"")) >= 2, TimeSpan.FromSeconds(10));
            Assert.True(registerSeen, "Клиент не выполнил повторную регистрацию после reregister_all от Randy");

            var registerMessages = sentMessages.Where(m => m.Contains("\"actions/register\"")).ToList();
            foreach (var msg in registerMessages)
            {
                var node = JsonNode.Parse(msg);
                var names = node!["data"]!["actions"]!.AsArray().Select(a => a!["name"]!.GetValue<string>()).ToArray();
                Assert.Equal(21, names.Length);
                Assert.Equal(21, names.Distinct().Count());
            }

            using var http = new HttpClient(new HttpClientHandler { UseProxy = false, Proxy = null });
            var force = new StringContent(
                "{\"command\":\"action\",\"data\":{\"id\":\"blegh\",\"name\":\"end_turn\",\"data\":\"{\\\"target\\\":\\\"goblin\\\"}\"}}",
                Encoding.UTF8,
                "application/json");
            var response = await http.PostAsync($"http://localhost:{_httpPort}/", force);

            var action = await actionTcs.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal("end_turn", action.Name);
            Assert.False(string.IsNullOrEmpty(action.Id));

            await client.SendResultAsync(action.Id, true, "ok");
            await Task.Delay(200);
        }
        finally
        {
            await CleanupRandyAsync();
        }
    }

    private static async Task<bool> WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed < timeout)
        {
            if (condition())
            {
                return true;
            }

            await Task.Delay(100);
        }

        return false;
    }

    private static bool WaitForOpenPort(int port, TimeSpan timeout)
    {
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed < timeout)
        {
            try
            {
                using var tcp = new TcpClient();
                tcp.Connect(IPAddress.Loopback, port);
                return true;
            }
            catch (Exception)
            {
                Thread.Sleep(250);
            }
        }

        return false;
    }

    private static int GetFreePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private async Task CleanupRandyAsync()
    {
        if (_randy is null)
        {
            return;
        }

        try
        {
            _randy.Kill(entireProcessTree: true);
        }
        catch
        {
        }

        await _randy.WaitForExitAsync();

        await Task.Delay(500);
        var orphans = Process.GetProcessesByName("node")
            .Where(p => !_preexistingNodePids.Contains(p.Id) && p.Id != _randy.Id)
            .ToList();
        foreach (var orphan in orphans)
        {
            try
            {
                orphan.Kill(entireProcessTree: true);
            }
            catch
            {
            }

            await orphan.WaitForExitAsync();
            orphan.Dispose();
        }

        _randy.Dispose();
    }
}