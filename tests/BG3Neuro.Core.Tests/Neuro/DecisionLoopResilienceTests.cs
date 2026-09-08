using System.Diagnostics;
using System.Text.Json.Nodes;
using BG3Neuro.Core.Actions;
using BG3Neuro.Core.Config;
using BG3Neuro.Core.Ipc;
using BG3Neuro.Core.Neuro;
using BG3Neuro.Core.State;
using Xunit;

namespace BG3Neuro.Core.Tests.Neuro;

public class DecisionLoopResilienceTests : IDisposable
{
    private const string Game = "Baldur's Gate 3";
    private static readonly TimeSpan QuickReconnect = TimeSpan.FromMilliseconds(100);

    private readonly string _tmpDir = Path.Combine(Path.GetTempPath(), "bg3neuro-resilience-" + Guid.NewGuid().ToString("N"));

    public DecisionLoopResilienceTests()
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

    private static string CombatStateJson(string turnActor) => $$"""
    {
      "mode": "combat",
      "turn_actor": "{{turnActor}}",
      "turn_initiative_index": 1,
      "turn_initiative_total": 2,
      "allies": [
        { "alias": "{{turnActor}}", "name": "{{turnActor}}", "hp": 45, "max_hp": 60, "distance": 6 }
      ],
      "enemies": [
        { "alias": "goblin_1", "name": "Goblin Raider", "hp": 12, "max_hp": 18, "distance": 6 }
      ],
      "available_actions": ["end_turn"]
    }
    """;

    private void WriteCombatState(string turnActor = "karlach") =>
        RobustWrite(Path.Combine(_tmpDir, "bg3_to_neuro.json"), CombatStateJson(turnActor));

    private void WriteHeartbeat(double ageSeconds) =>
        RobustWrite(
            Path.Combine(_tmpDir, "heartbeat.json"),
            System.Text.Json.JsonSerializer.Serialize(new
            {
                mod = "BG3Neuro",
                version = "0.7.0",
                seq = 1,
                timestamp = DateTimeOffset.UtcNow.AddSeconds(-ageSeconds).ToString("O"),
            }));

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

    private void WriteExecutionResult(string id, bool success)
    {
        var result = success
            ? $$"""{"id":"{{id}}","success":true}"""
            : $$"""{"id":"{{id}}","success":false,"error_code":"action_failed"}""";
        RobustWrite(Path.Combine(_tmpDir, $"result_{id}.json"), result);
    }

    private (FakeNeuroServer Server, IpcClient Ipc, NeuroWebSocketClient Client, List<string> Sent) StartStack(FakeNeuroServer server, TimeSpan? executionResultTimeout = null)
    {
        var sent = new List<string>();
        var ipc = new IpcClient(new IpcConfig
        {
            Dir = _tmpDir,
            PollIntervalMs = 25,
            HeartbeatIntervalS = 2,
            HeartbeatStaleS = 1,
        });
        ipc.Start();
        var client = new NeuroWebSocketClient(server.Url, Game, ActionRegistry.Get(), QuickReconnect);
        client.MessageSent += (_, text) => sent.Add(text);
        var router = new ActionRouter(new IpcPaths(_tmpDir), controlledPartySize: 1);
        var loop = new DecisionLoop(client, ipc, router, executionResultTimeout: executionResultTimeout);
        client.Start();
        loop.Start();
        return (server, ipc, client, sent);
    }

    private static async Task StopStackAsync(IpcClient ipc, NeuroWebSocketClient client)
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
    }

    private static void SendAction(FakeNeuroServer server, string id, string name, string dataJson = "{}")
    {
        server.Send(new JsonObject
        {
            ["command"] = "action",
            ["data"] = new JsonObject { ["id"] = id, ["name"] = name, ["data"] = dataJson },
        });
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

    private static int ForceCount(List<string> sent) => sent.Count(m => m.Contains("\"actions/force\""));

    [Fact]
    public async Task WebSocketDrop_Reconnects_RestoresRegistration_ForceReSent_AndActionsContinue()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        WriteCombatState();
        WriteHeartbeat(0.05);

        var stack = StartStack(server);
        try
        {
            await server.WaitForMessagesAsync(m =>
                m.Count(n => n["command"]?.GetValue<string>() == "actions/register") >= 1 &&
                m.Count(n => n["command"]?.GetValue<string>() == "actions/force") >= 1);

            Assert.True(ForceCount(stack.Sent) >= 1, "Первый force не отправлен");

            server.CloseAllConnections();

            var messages = await server.WaitForMessagesAsync(m =>
                m.Count(n => n["command"]?.GetValue<string>() == "actions/register") >= 2, timeoutMs: 10000);
            Assert.Contains(messages, m => m["command"]?.GetValue<string>() == "startup");

            Assert.True(
                await WaitUntilAsync(() => ForceCount(stack.Sent) >= 2, TimeSpan.FromSeconds(10)),
                "После реконнекта не пришёл повторный force (сброс _lastForcedContent)");

            SendAction(server, "r1-1", "end_turn");
            WriteExecutionResult("r1-1", success: true);
            var ok = await WaitUntilAsync(
                () => stack.Sent.Any(m => m.Contains("\"action/result\"") && m.Contains("r1-1")),
                TimeSpan.FromSeconds(10));
            Assert.True(ok, "Действие после реконнекта не обработано");
            Assert.True(File.Exists(Path.Combine(_tmpDir, "action_r1-1.json")), "action_<id>.json должен быть записан");
        }
        finally
        {
            await StopStackAsync(stack.Ipc, stack.Client);
        }
    }

    [Fact]
    public async Task ModRestart_StaleDispatchModUnavailable_ThenAliveCleansStandAndResendsForce()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        WriteCombatState();
        WriteHeartbeat(0.05);

        var stack = StartStack(server);
        try
        {
            await server.WaitForMessagesAsync(m => m.Count(n => n["command"]?.GetValue<string>() == "actions/force") >= 1);

            // Мод/игра погибли: heartbeat протух, в стэнде остался неисполненный action
            WriteHeartbeat(300);
            RobustWrite(Path.Combine(_tmpDir, "neuro_to_bg3.json"), """{"id":"stale-1","name":"end_turn","data":"{}"}""");
            RobustWrite(Path.Combine(_tmpDir, "action_stale-1.json"), """{"id":"stale-1","name":"end_turn","data":"{}"}""");

            var staleSeen = await WaitUntilAsync(() => stack.Ipc.Status == ModStatus.Stale, TimeSpan.FromSeconds(10));
            Assert.True(staleSeen, "Статус не ушёл в Stale");

            // Диспатч в Stale → Канал A: mod_unavailable без записи action-файла
            SendAction(server, "r2-off-1", "end_turn");
            var offOk = await WaitUntilAsync(
                () => stack.Sent.Any(m =>
                    m.Contains("\"action/result\"") &&
                    m.Contains("r2-off-1") &&
                    JsonNode.Parse(m)?["data"]?["message"]?.GetValue<string>()?.Contains("Mod unavailable") == true),
                TimeSpan.FromSeconds(10));
            Assert.True(offOk, "В Stale не вернулся mod_unavailable");
            Assert.False(File.Exists(Path.Combine(_tmpDir, "action_r2-off-1.json")), "action не должен писаться при mod_unavailable");

            // Мод вернулся: свежий heartbeat → re-init: стенд вычищен, force переотправлен
            WriteHeartbeat(0.05);
            var reinitOk = await WaitUntilAsync(
                () => stack.Ipc.Status == ModStatus.Alive &&
                      ForceCount(stack.Sent) >= 2 &&
                      !File.Exists(Path.Combine(_tmpDir, "neuro_to_bg3.json")) &&
                      !File.Exists(Path.Combine(_tmpDir, "action_stale-1.json")),
                TimeSpan.FromSeconds(10));
            Assert.True(reinitOk, "После Alive: стэнд не вычищен и/или force не переотправлен");

            SendAction(server, "r2-on-1", "end_turn");
            WriteExecutionResult("r2-on-1", success: true);
            var onOk = await WaitUntilAsync(
                () => stack.Sent.Any(m => m.Contains("\"action/result\"") && m.Contains("r2-on-1")),
                TimeSpan.FromSeconds(10));
            Assert.True(onOk, "Действие после восстановления мода не обработано");
            Assert.True(File.Exists(Path.Combine(_tmpDir, "action_r2-on-1.json")), "action_<id>.json должен быть записан");
        }
        finally
        {
            await StopStackAsync(stack.Ipc, stack.Client);
        }
    }

    [Fact]
    public async Task PartialStateFile_SkippedWithoutCrash_ThenValidStateSendsForce()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        WriteCombatState();
        WriteHeartbeat(0.05);

        var stack = StartStack(server);
        try
        {
            await server.WaitForMessagesAsync(m => m.Count(n => n["command"]?.GetValue<string>() == "actions/force") >= 1);
            var forceCountAtValid = ForceCount(stack.Sent);

            // Частичная запись state (игра писала и оборвалась) — не должна ронять цикл и не должна слать force
            RobustWrite(Path.Combine(_tmpDir, "bg3_to_neuro.json"), "{ \"mode\": \"combat\", \"turn_actor\": \"");

            var noForceFromPartial = await WaitUntilAsync(
                () => ForceCount(stack.Sent) > forceCountAtValid, TimeSpan.FromMilliseconds(300));
            Assert.False(noForceFromPartial, "Частичный state не должен порождать force");

            // Действие при неизвестном/битом state корректно отклоняется по Каналу A, процесс жив
            SendAction(server, "r8-1", "end_turn");
            var rejected = await WaitUntilAsync(
                () => stack.Sent.Any(m => m.Contains("\"action/result\"") && m.Contains("r8-1") && m.Contains("\"success\":false")),
                TimeSpan.FromSeconds(10));
            Assert.True(rejected, "Действие при частичном state не отклонено");
            Assert.False(File.Exists(Path.Combine(_tmpDir, "action_r8-1.json")), "action не пишется при неизвестном state");

            // Валидный обновлённый state → новый force
            WriteCombatState("shadowheart");
            var newForce = await WaitUntilAsync(
                () => ForceCount(stack.Sent) >= forceCountAtValid + 1, TimeSpan.FromSeconds(10));
            Assert.True(newForce, "После валидного state не пришёл force");
            var lastForce = JsonNode.Parse(stack.Sent.Where(m => m.Contains("\"actions/force\"")).Last())!;
            Assert.Contains("shadowheart", lastForce["data"]!["state"]!.GetValue<string>());
        }
        finally
        {
            await StopStackAsync(stack.Ipc, stack.Client);
        }
    }

    [Fact]
    public void TwoActions_SharedCommandSlot_KeepsOnlyLatestInFlight()
    {
        WriteCombatState();
        var paths = new IpcPaths(_tmpDir);
        var router = new ActionRouter(paths, controlledPartySize: 1);
        var state = StateSerializer.Parse(File.ReadAllText(Path.Combine(_tmpDir, "bg3_to_neuro.json")));

        var first = router.ValidateAndDispatch("p-1", "end_turn", "{}", state, ModStatus.Alive);
        var second = router.ValidateAndDispatch("p-2", "end_turn", "{}", state, ModStatus.Alive);

        Assert.True(first.Success, "Первое действие не прошло валидацию");
        Assert.True(second.Success, "Второе действие не прошло валидацию");

        var command = JsonNode.Parse(File.ReadAllText(Path.Combine(_tmpDir, "neuro_to_bg3.json")))!;
        Assert.Equal("p-2", command["id"]!.GetValue<string>());
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_p-1.json")), "Диагностический action_p-1.json должен сохраниться");
        Assert.Equal("p-1", JsonNode.Parse(File.ReadAllText(Path.Combine(_tmpDir, "action_p-1.json")))!["id"]!.GetValue<string>());
    }

    [Fact]
    public async Task Dispatch_ExecutionResultFailure_ForwardsRealFailureFromLuaAck()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        WriteCombatState();
        WriteHeartbeat(0.05);

        var stack = StartStack(server);
        try
        {
            await server.WaitForMessagesAsync(m => m.Count(n => n["command"]?.GetValue<string>() == "actions/force") >= 1);

            SendAction(server, "r-exec-1", "end_turn");
            // Lua-мод подтвердил (result_<id>.json), но исполнение провалилось
            RobustWrite(
                Path.Combine(_tmpDir, "result_r-exec-1.json"),
                """{"id":"r-exec-1","success":false,"error_code":"action_failed","error_detail":"Target out of range"}""");

            var ok = await WaitUntilAsync(
                () => stack.Sent.Any(m =>
                    m.Contains("\"action/result\"") &&
                    m.Contains("r-exec-1") &&
                    JsonNode.Parse(m)?["data"]?["success"]?.GetValue<bool>() == false &&
                    JsonNode.Parse(m)?["data"]?["message"]?.GetValue<string>()?.Contains("Target out of range") == true),
                TimeSpan.FromSeconds(10));
            Assert.True(ok, "Реальный failure из result_<id>.json не передан в action/result");
        }
        finally
        {
            await StopStackAsync(stack.Ipc, stack.Client);
        }
    }

    [Fact]
    public async Task Dispatch_NoExecutionAck_ReturnsTimeoutFailure()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        WriteCombatState();
        WriteHeartbeat(0.05);

        // Короткий таймаут ожидания ack — без result_<id>.json (мод/игра молчат)
        var stack = StartStack(server, TimeSpan.FromMilliseconds(500));
        try
        {
            await server.WaitForMessagesAsync(m => m.Count(n => n["command"]?.GetValue<string>() == "actions/force") >= 1);

            SendAction(server, "r-ack-1", "end_turn");

            var ok = await WaitUntilAsync(
                () => stack.Sent.Any(m =>
                    m.Contains("\"action/result\"") &&
                    m.Contains("r-ack-1") &&
                    JsonNode.Parse(m)?["data"]?["success"]?.GetValue<bool>() == false &&
                    JsonNode.Parse(m)?["data"]?["message"]?.GetValue<string>()?.Contains("Mod did not confirm") == true),
                TimeSpan.FromSeconds(10));
            Assert.True(ok, "Не вернулся timeout при отсутствии result_<id>.json");
        }
        finally
        {
            await StopStackAsync(stack.Ipc, stack.Client);
        }
    }
}