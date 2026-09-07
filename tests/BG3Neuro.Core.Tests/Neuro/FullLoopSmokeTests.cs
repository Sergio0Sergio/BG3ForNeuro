using System.Diagnostics;
using System.Text.Json.Nodes;
using BG3Neuro.Core.Actions;
using BG3Neuro.Core.Config;
using BG3Neuro.Core.Ipc;
using BG3Neuro.Core.Neuro;
using BG3Neuro.Core.State;
using Xunit;

namespace BG3Neuro.Core.Tests.Neuro;

// §9.4 smoke: connect → state → end_turn → new state. Без реальной игры и без Randy
// (FakeNeuroServer + mock-файлы BG3SE) — то, что гоняется одной командой (tests/smoke.ps1).
public class FullLoopSmokeTests : IDisposable
{
    private const string Game = "Baldur's Gate 3";
    private static readonly TimeSpan QuickReconnect = TimeSpan.FromMilliseconds(100);

    private readonly string _tmpDir = Path.Combine(Path.GetTempPath(), "bg3neuro-smoke-t-" + Guid.NewGuid().ToString("N"));

    public FullLoopSmokeTests()
    {
        Directory.CreateDirectory(_tmpDir);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_tmpDir))
            {
                Directory.Delete(_tmpDir, recursive: true);
            }
        }
        catch (IOException)
        {
        }
    }

    [Fact]
    public async Task Connect_StateIn_EndTurnExecuted_UpdatedStateSendsNewForce()
    {
        await using var server = new FakeNeuroServer();
        server.Start();

        WriteState("karlach");
        WriteHeartbeat();

        var sent = new List<string>();
        var ipc = new IpcClient(new IpcConfig
        {
            Dir = _tmpDir,
            PollIntervalMs = 25,
            HeartbeatIntervalS = 2,
            HeartbeatStaleS = 10,
        });
        ipc.Start();
        var client = new NeuroWebSocketClient(server.Url, Game, ActionRegistry.Get(), QuickReconnect);
        client.MessageSent += (_, text) => sent.Add(text);
        var loop = new DecisionLoop(client, ipc, new ActionRouter(new IpcPaths(_tmpDir), controlledPartySize: 1));
        client.Start();
        loop.Start();

        try
        {
            // 1) подключился (startup + register) и state пришёл (force)
            await server.WaitForMessagesAsync(m =>
                m.Any(n => n["command"]?.GetValue<string>() == "startup") &&
                m.Any(n => n["command"]?.GetValue<string>() == "actions/register") &&
                m.Any(n => n["command"]?.GetValue<string>() == "actions/force"));

            // 2) end_turn выполнен: success по Каналу A + action-файл для Lua-мода
            server.Send(new JsonObject
            {
                ["command"] = "action",
                ["data"] = new JsonObject { ["id"] = "smoke-1", ["name"] = "end_turn", ["data"] = "{}" },
            });
            WriteExecutionResult("smoke-1", success: true, running: false);
            Assert.True(
                await WaitUntilAsync(
                    () => sent.Any(m => m.Contains("\"action/result\"") && m.Contains("smoke-1") && m.Contains("\"success\":true")),
                    TimeSpan.FromSeconds(10)),
                "end_turn не вернул success за 10с");

            var actionFile = JsonNode.Parse(File.ReadAllText(Path.Combine(_tmpDir, "action_smoke-1.json")))!;
            Assert.Equal("end_turn", actionFile["name"]!.GetValue<string>());

            // 3) state обновился (следующий актор) → новый force с новым состоянием
            WriteState("shadowheart");
            Assert.True(
                await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 2, TimeSpan.FromSeconds(10)),
                "force на обновлённый state не отправлен");
            var secondForce = sent.Where(m => m.Contains("\"actions/force\"")).Skip(1).First();
            Assert.Contains("shadowheart", JsonNode.Parse(secondForce)!["data"]!["state"]!.GetValue<string>());
        }
        finally
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            try
            {
                await Task.WhenAll(ipc.StopAsync(), client.StopAsync()).WaitAsync(timeout.Token);
            }
            catch (TimeoutException)
            {
            }

            client.Dispose();
            ipc.Dispose();
            loop.Dispose();
        }
    }

    private void WriteState(string turnActor) =>
        RobustWrite(
            Path.Combine(_tmpDir, "bg3_to_neuro.json"),
            $$"""{"mode":"combat","turn_actor":"{{turnActor}}","turn_initiative_index":1,"turn_initiative_total":2,"allies":[{"alias":"{{turnActor}}","name":"{{turnActor}}","hp":45,"max_hp":60,"distance":6}],"enemies":[{"alias":"goblin_1","name":"Goblin Raider","hp":12,"max_hp":18,"distance":6}],"available_actions":["end_turn"]}""");

    private void WriteHeartbeat() =>
        RobustWrite(
            Path.Combine(_tmpDir, "heartbeat.json"),
            System.Text.Json.JsonSerializer.Serialize(new
            {
                mod = "BG3Neuro",
                version = "0.7.0",
                seq = 1,
                timestamp = DateTimeOffset.UtcNow.AddMilliseconds(-50).ToString("O"),
            }));

    private void WriteExecutionResult(string id, bool success, bool running) =>
        RobustWrite(
            Path.Combine(_tmpDir, $"result_{id}.json"),
            running
                ? $$"""{"id":"{{id}}","success":{{(success ? "true" : "false")}},"running":true}"""
                : $$"""{"id":"{{id}}","success":{{(success ? "true" : "false")}}}""");

    private static void RobustWrite(string path, string content)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                File.WriteAllText(path, content);
                return;
            }
            catch (IOException) when (attempt < 50)
            {
                Thread.Sleep(10);
            }
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

            await Task.Delay(50);
        }

        return false;
    }
}