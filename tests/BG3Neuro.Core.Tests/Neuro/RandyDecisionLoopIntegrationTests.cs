using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using BG3Neuro.Core.Actions;
using BG3Neuro.Core.Config;
using BG3Neuro.Core.Ipc;
using BG3Neuro.Core.Neuro;
using BG3Neuro.Core.State;
using Xunit;

namespace BG3Neuro.Core.Tests.Neuro;

[Collection("Randy")]
public class RandyDecisionLoopIntegrationTests : IDisposable
{
    private const string Game = "Baldur's Gate 3";

    private readonly string _tmpDir = Path.Combine(Path.GetTempPath(), "bg3neuro-e2e-" + Guid.NewGuid().ToString("N"));
    private readonly Process? _randy;
    private readonly int _wsPort;
    private readonly int _httpPort;
    private readonly HashSet<int> _preexistingNodePids = new();

    public RandyDecisionLoopIntegrationTests()
    {
        Directory.CreateDirectory(_tmpDir);

        var randyDir = LocateRandyDir();
        if (!Directory.Exists(randyDir) ||
            !Directory.Exists(Path.Combine(randyDir, "node_modules", "tsx")))
        {
            return;
        }

        var tsxCli = Path.Combine(randyDir, "node_modules", "tsx", "dist", "cli.mjs");
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
                FileName = "node",
                Arguments = $"\"{tsxCli}\" index.ts",
                WorkingDirectory = randyDir,
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
        WaitForOpenPort(_wsPort, TimeSpan.FromSeconds(40));
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
        return inner is null ? "" : Path.Combine(inner, "Randy");
    }

    private static string CombatStateJson(string turnActor) => $$"""
    {
      "mode": "combat",
      "turn_actor": "{{turnActor}}",
      "turn_initiative_index": 1,
      "turn_initiative_total": 2,
      "allies": [
        { "alias": "karlach", "name": "Karlach", "hp": 45, "max_hp": 60, "distance": 6 },
        { "alias": "shadowheart", "name": "Shadowheart", "hp": 30, "max_hp": 40, "distance": 4 }
      ],
      "enemies": [
        { "alias": "goblin_1", "name": "Goblin Raider", "hp": 12, "max_hp": 18, "distance": 6 }
      ],
      "available_actions": ["end_turn"]
    }
    """;

    private void WriteState(string turnActor) =>
        File.WriteAllText(Path.Combine(_tmpDir, "bg3_to_neuro.json"), CombatStateJson(turnActor));

    private void WriteStateContent(string json) =>
        File.WriteAllText(Path.Combine(_tmpDir, "bg3_to_neuro.json"), json);

    // Моделируем ack Lua-мода: result_<ackId>.json. Для долгих действий Lua пишет running:true
    // (запущено, итог — следующий state/Канал B), для instant (end_turn) — без running.
    private void WriteAck(string id, bool running = false) =>
        File.WriteAllText(
            Path.Combine(_tmpDir, $"result_{id}.json"),
            running
                ? $$"""{"id":"{{id}}","success":true,"running":true}"""
                : $$"""{"id":"{{id}}","success":true}""");

    private static string CastStateJson(string turnActor, bool farEnemy) => $$"""
    {
      "mode": "combat",
      "turn_actor": "{{turnActor}}",
      "turn_initiative_index": 1,
      "turn_initiative_total": 2,
      "allies": [
        { "alias": "karlach", "name": "Karlach", "hp": 45, "max_hp": 60, "distance": 0, "position_x": 0, "position_y": 0 },
        { "alias": "shadowheart", "name": "Shadowheart", "hp": 30, "max_hp": 40, "distance": 2, "position_x": 0, "position_y": 2 }
      ],
      "enemies": [
        { "alias": "goblin_1", "name": "Goblin Raider", "hp": 18, "max_hp": 18, "distance": 5, "position_x": 3, "position_y": 4 },
        { "alias": "goblin_2", "name": "Goblin Archer", "hp": 12, "max_hp": 12, "distance": {{(farEnemy ? "100" : "10")}}, "position_x": {{(farEnemy ? "100" : "6")}}, "position_y": {{(farEnemy ? "100" : "8")}} }
      ],
      "spells": [
        { "spell_name": "Fireball", "slot": "3", "range": 18, "aoe": 4, "casts_left": 2 }
      ],
      "available_actions": ["cast_spell", "end_turn"]
    }
    """;

    private void WriteCastState(string turnActor, bool farEnemy) =>
        File.WriteAllText(Path.Combine(_tmpDir, "bg3_to_neuro.json"), CastStateJson(turnActor, farEnemy));

    private void WriteFreshHeartbeat() =>
        File.WriteAllText(
            Path.Combine(_tmpDir, "heartbeat.json"),
            System.Text.Json.JsonSerializer.Serialize(new
            {
                mod = "BG3Neuro",
                version = "0.2.0",
                seq = 1,
                timestamp = DateTimeOffset.UtcNow.AddSeconds(-1).ToString("O"),
            }));

    private static IpcConfig IpcConfigFor(string dir) => new()
    {
        Dir = dir,
        PollIntervalMs = 25,
        HeartbeatIntervalS = 2,
        HeartbeatStaleS = 10,
    };

    [Fact]
    public async Task EndTurn_OnControlledTurn_WritesActionFile_AndSendsSuccessResult()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteState("karlach");
            WriteFreshHeartbeat();
            WriteAck("e2e-1");

            var result = await RunEndTurnAsync("e2e-1", "{}");

            Assert.Equal("action/result", result["command"]!.GetValue<string>());
            Assert.Equal("e2e-1", result["data"]!["id"]!.GetValue<string>());
            Assert.True(result["data"]!["success"]!.GetValue<bool>());

            Assert.True(File.Exists(Path.Combine(_tmpDir, "action_e2e-1.json")), "action_<id>.json должен быть записан");
            Assert.True(File.Exists(Path.Combine(_tmpDir, "neuro_to_bg3.json")), "neuro_to_bg3.json должен быть записан");

            var actionFile = JsonNode.Parse(File.ReadAllText(Path.Combine(_tmpDir, "action_e2e-1.json")))!;
            Assert.Equal("end_turn", actionFile["name"]!.GetValue<string>());
        }
        finally
        {
            await CleanupAsync();
        }
    }

    [Fact]
    public async Task UnchangedState_DoesNotResendForce()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteState("karlach");
            WriteFreshHeartbeat();

            var (sent, _, _) = await StartStackAsync();
            await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 1, TimeSpan.FromSeconds(10));
            await Task.Delay(1000);
            var forceCount = sent.Count(m => m.Contains("\"actions/force\""));
            Assert.Equal(1, forceCount);
        }
        finally
        {
            await CleanupAsync();
        }
    }

    [Fact]
    public async Task TurnAdvances_NewStateSendsForce_WithNextActor()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteState("karlach");
            WriteFreshHeartbeat();

            var (sent, client, ipc) = await StartStackAsync();

            var firstForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 1, TimeSpan.FromSeconds(10));
            Assert.True(firstForceSeen, "Первый force (ход Karlach) не отправлен");
            var firstForce = sent.First(m => m.Contains("\"actions/force\""));
            var firstForceNode = JsonNode.Parse(firstForce)!;
            Assert.Contains("## Turn: Karlach", firstForceNode["data"]!["state"]!.GetValue<string>());

            // Игра исполнила end_turn: следующий актор — Shadowheart, state перезаписан
            WriteState("shadowheart");
            ipc.ReadState();

            var secondForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 2, TimeSpan.FromSeconds(10));
            Assert.True(secondForceSeen, "Force после смены хода не отправлен");
            var secondForce = JsonNode.Parse(sent.Where(m => m.Contains("\"actions/force\"")).Skip(1).First())!;
            Assert.Contains("## Turn: Shadowheart", secondForce["data"]!["state"]!.GetValue<string>());
        }
        finally
        {
            await CleanupAsync();
        }
    }

    [Fact]
    public async Task MoveToTarget_WritesActionFile_ThenUpdatedPositionSendsForceWithEvent()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteState("karlach");
            WriteFreshHeartbeat();

            var (sent, client, ipc) = await StartStackAsync();
            using (client)
            using (ipc)
            {
                var firstForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 1, TimeSpan.FromSeconds(10));
                Assert.True(firstForceSeen, "Первый force не отправлен");

                WriteAck("e2e-move-1", running: true);
                await PostActionAsync(sent, "e2e-move-1", "move_to_target", """{"target_id":"goblin_1"}""", TimeSpan.FromSeconds(10));

            var actionFile = JsonNode.Parse(File.ReadAllText(Path.Combine(_tmpDir, "action_e2e-move-1.json")))!;
            Assert.Equal("move_to_target", actionFile["name"]!.GetValue<string>());

            // Игра исполнила движение: обновлённый state (новая дистанция) + событие в контекст
            WriteStateContent("""
                {
                  "mode": "combat",
                  "turn_actor": "karlach",
                  "turn_initiative_index": 1,
                  "turn_initiative_total": 2,
                  "allies": [
                    { "alias": "karlach", "name": "Karlach", "hp": 45, "max_hp": 60, "distance": 2 },
                    { "alias": "shadowheart", "name": "Shadowheart", "hp": 30, "max_hp": 40, "distance": 4 }
                  ],
                  "enemies": [
                    { "alias": "goblin_1", "name": "Goblin Raider", "hp": 12, "max_hp": 18, "distance": 2 }
                  ],
                  "available_actions": ["end_turn"],
                  "events": ["Karlach сместилась к goblin_1"]
                }
                """);
            ipc.ReadState();

            var secondForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 2, TimeSpan.FromSeconds(10));
            Assert.True(secondForceSeen, "Force после изменения позиции не отправлен");
            var secondForce = JsonNode.Parse(sent.Where(m => m.Contains("\"actions/force\"")).Skip(1).First())!;
            var state = secondForce["data"]!["state"]!.GetValue<string>();
            Assert.Contains("distance 2m", state);
            Assert.Contains("## Events", state);
            Assert.Contains("- Karlach сместилась к goblin_1", state);
            }
        }
        finally
        {
            await CleanupAsync();
        }
    }

    [Fact]
    public async Task AttackEntity_WritesActionFile_ThenDamageShowsInNextForce()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteState("karlach");
            WriteFreshHeartbeat();

            var (sent, client, ipc) = await StartStackAsync();
            using (client)
            using (ipc)
            {
                var firstForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 1, TimeSpan.FromSeconds(10));
                Assert.True(firstForceSeen, "Первый force не отправлен");

                WriteAck("e2e-atk-1", running: true);
                await PostActionAsync(sent, "e2e-atk-1", "attack_entity", """{"target_id":"goblin_1"}""", TimeSpan.FromSeconds(10));

            var actionFile = JsonNode.Parse(File.ReadAllText(Path.Combine(_tmpDir, "action_e2e-atk-1.json")))!;
            Assert.Equal("attack_entity", actionFile["name"]!.GetValue<string>());

            // Игра применила урон: HP врага изменилось + событие попадания
            WriteStateContent("""
                {
                  "mode": "combat",
                  "turn_actor": "karlach",
                  "turn_initiative_index": 1,
                  "turn_initiative_total": 2,
                  "allies": [
                    { "alias": "karlach", "name": "Karlach", "hp": 45, "max_hp": 60, "distance": 6 },
                    { "alias": "shadowheart", "name": "Shadowheart", "hp": 30, "max_hp": 40, "distance": 4 }
                  ],
                  "enemies": [
                    { "alias": "goblin_1", "name": "Goblin Raider", "hp": 5, "max_hp": 18, "distance": 6 }
                  ],
                  "available_actions": ["end_turn"],
                  "events": ["атака цели goblin_1 нанесла 7 урона"]
                }
                """);
            ipc.ReadState();

            var secondForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 2, TimeSpan.FromSeconds(10));
            Assert.True(secondForceSeen, "Force после изменения HP не отправлен");
            var secondForce = JsonNode.Parse(sent.Where(m => m.Contains("\"actions/force\"")).Skip(1).First())!;
            var state = secondForce["data"]!["state"]!.GetValue<string>();
            Assert.Contains("HP 5/18", state);
            Assert.Contains("- атака цели goblin_1 нанесла 7 урона", state);
            }
        }
        finally
        {
            await CleanupAsync();
        }
    }

    [Fact]
    public async Task ExecutionFailure_SurfacesInNextState_WithoutLateActionResult()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteState("karlach");
            WriteFreshHeartbeat();

            var (sent, client, ipc) = await StartStackAsync();
            using (client)
            using (ipc)
            {
            var firstForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 1, TimeSpan.FromSeconds(10));
            Assert.True(firstForceSeen, "Первый force не отправлен");

            WriteAck("e2e-fail-1", running: true);
            var firstResult = await PostActionAsync(sent, "e2e-fail-1", "attack_entity", """{"target_id":"goblin_1"}""", TimeSpan.FromSeconds(10));
            Assert.True(firstResult["data"]!["success"]!.GetValue<bool>(), "Валидация attack_entity должна пройти (Канал A)");
            Assert.True(File.Exists(Path.Combine(_tmpDir, "action_e2e-fail-1.json")));

            // Исполнение провалилось в игре: цель вне досягаемости →
            // НЕ поздний action/result, а Канал B: следующий state + контекст события
            WriteStateContent("""
                {
                  "mode": "combat",
                  "turn_actor": "karlach",
                  "turn_initiative_index": 1,
                  "turn_initiative_total": 2,
                  "allies": [
                    { "alias": "karlach", "name": "Karlach", "hp": 45, "max_hp": 60, "distance": 20 },
                    { "alias": "shadowheart", "name": "Shadowheart", "hp": 30, "max_hp": 40, "distance": 4 }
                  ],
                  "enemies": [
                    { "alias": "goblin_1", "name": "Goblin Raider", "hp": 12, "max_hp": 18, "distance": 20 }
                  ],
                  "available_actions": ["move_to_target", "end_turn"],
                  "events": ["атака не удалась: цель goblin_1 вне досягаемости"]
                }
                """);
            ipc.ReadState();

            var secondForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 2, TimeSpan.FromSeconds(10));
            Assert.True(secondForceSeen, "Force с контекстом провала не отправлен");
            var secondForce = JsonNode.Parse(sent.Where(m => m.Contains("\"actions/force\"")).Skip(1).First())!;
            var state = secondForce["data"]!["state"]!.GetValue<string>();
            Assert.Contains("атака не удалась: цель goblin_1 вне досягаемости", state);

            await Task.Delay(500);
            // Провал исполнения НЕ порождает поздний action/result для действия:
            // для e2e-fail-1 есть только ack валидации (Канал A), контекст ушёл в force (Канал B).
            var failedActionResults = sent.Count(m => m.Contains("e2e-fail-1"));
            Assert.Equal(1, failedActionResults);
            }
        }
        finally
        {
            await CleanupAsync();
        }
    }

    [Fact]
    public async Task CastSpell_KnownSpell_WritesActionFile_ThenSpentChargeShowsInNextForce()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteCastState("karlach", farEnemy: false);
            WriteFreshHeartbeat();

            var (sent, client, ipc) = await StartStackAsync();
            using (client)
            using (ipc)
            {
                var firstForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 1, TimeSpan.FromSeconds(10));
                Assert.True(firstForceSeen, "Первый force не отправлен");

                WriteAck("e2e-cast-1", running: true);
                var result = await PostActionAsync(sent, "e2e-cast-1", "cast_spell", """{"spell_name":"Fireball","target_id":"goblin_1"}""", TimeSpan.FromSeconds(10));
                Assert.True(result["data"]!["success"]!.GetValue<bool>(), "Каст известного заклинания должен пройти валидацию (Канал A)");

                var actionFile = JsonNode.Parse(File.ReadAllText(Path.Combine(_tmpDir, "action_e2e-cast-1.json")))!;
                Assert.Equal("cast_spell", actionFile["name"]!.GetValue<string>());
                var actionData = JsonNode.Parse(actionFile["data"]!.GetValue<string>())!;
                Assert.Equal("Fireball", actionData["spell_name"]!.GetValue<string>());

                // Игра потратила заряд: ресурсы отражены в следующем state → force
                WriteStateContent("""
                    {
                      "mode": "combat",
                      "turn_actor": "karlach",
                      "turn_initiative_index": 1,
                      "turn_initiative_total": 2,
                      "allies": [
                        { "alias": "karlach", "name": "Karlach", "hp": 45, "max_hp": 60, "distance": 0, "position_x": 0, "position_y": 0 },
                        { "alias": "shadowheart", "name": "Shadowheart", "hp": 30, "max_hp": 40, "distance": 2, "position_x": 0, "position_y": 2 }
                      ],
                      "enemies": [
                        { "alias": "goblin_1", "name": "Goblin Raider", "hp": 8, "max_hp": 18, "distance": 5, "position_x": 3, "position_y": 4 },
                        { "alias": "goblin_2", "name": "Goblin Archer", "hp": 12, "max_hp": 12, "distance": 10, "position_x": 6, "position_y": 8 }
                      ],
                      "spells": [
                        { "spell_name": "Fireball", "slot": "3", "range": 18, "aoe": 4, "casts_left": 1 }
                      ],
                      "available_actions": ["cast_spell", "end_turn"],
                      "events": ["Огненный шар попал по goblin_1: 10 урона"]
                    }
                    """);
                ipc.ReadState();

                var secondForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 2, TimeSpan.FromSeconds(10));
                Assert.True(secondForceSeen, "Force после изменения ресурсов не отправлен");
                var secondForce = JsonNode.Parse(sent.Where(m => m.Contains("\"actions/force\"")).Skip(1).First())!;
                var state = secondForce["data"]!["state"]!.GetValue<string>();
                Assert.Contains("charges left: 1", state);
                Assert.Contains("- Огненный шар попал по goblin_1: 10 урона", state);
            }
        }
        finally
        {
            await CleanupAsync();
        }
    }

    [Fact]
    public async Task CastSpell_UnknownSpell_ReturnsNoSpellWithList_NoActionFile()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteCastState("karlach", farEnemy: false);
            WriteFreshHeartbeat();

            var (sent, client, ipc) = await StartStackAsync();
            using (client)
            using (ipc)
            {
                var firstForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 1, TimeSpan.FromSeconds(10));
                Assert.True(firstForceSeen, "Первый force не отправлен");

                var result = await PostActionAsync(sent, "e2e-cast-2", "cast_spell", """{"spell_name":"Disintegrate"}""", TimeSpan.FromSeconds(10));

                Assert.False(result["data"]!["success"]!.GetValue<bool>());
                var message = result["data"]!["message"]!.GetValue<string>();
                Assert.Contains("Disintegrate", message);
                Assert.Contains("Fireball", message);
                Assert.False(File.Exists(Path.Combine(_tmpDir, "action_e2e-cast-2.json")), "action_<id>.json не должен быть записан при no_spell");
            }
        }
        finally
        {
            await CleanupAsync();
        }
    }

    [Fact]
    public async Task CastSpell_AoeCoverageNotAchievable_TargetNotInRange()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteCastState("karlach", farEnemy: true);
            WriteFreshHeartbeat();

            var (sent, client, ipc) = await StartStackAsync();
            using (client)
            using (ipc)
            {
                var firstForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 1, TimeSpan.FromSeconds(10));
                Assert.True(firstForceSeen, "Первый force не отправлен");

                var result = await PostActionAsync(sent, "e2e-cast-3", "cast_spell", """{"spell_name":"Fireball","coverage":["goblin_1","goblin_2"]}""", TimeSpan.FromSeconds(10));

                Assert.False(result["data"]!["success"]!.GetValue<bool>());
                var message = result["data"]!["message"]!.GetValue<string>();
                Assert.Contains("goblin_2", message);
                Assert.False(File.Exists(Path.Combine(_tmpDir, "action_e2e-cast-3.json")), "action_<id>.json не должен быть записан при target_not_in_range");
            }
        }
        finally
        {
            await CleanupAsync();
        }
    }

    [Fact]
    public async Task EndTurn_WhenEnemyTurn_FailsWithWrongPhase_NoActionFile()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteState("goblin_1");
            WriteFreshHeartbeat();

            var actionFile = Path.Combine(_tmpDir, "action_e2e-2.json");
            var result = await RunEndTurnAsync("e2e-2", "{}");

            Assert.Equal("action/result", result["command"]!.GetValue<string>());
            Assert.False(result["data"]!["success"]!.GetValue<bool>());
            Assert.Contains("It is not the controlled character", result["data"]!["message"]!.GetValue<string>());
            Assert.False(File.Exists(actionFile), "action_<id>.json не должен быть записан при wrong_phase");
        }
        finally
        {
            await CleanupAsync();
        }
    }

    [Fact]
    public async Task ModUnavailable_StaleAtValidation_ReturnsFailureViaActionResult_NoActionFile()
    {
        // Канал A (§6.5): mod_unavailable НА МОМЕНТ ВАЛИДАЦИИ → немедленный action/result
        // failure (без запуска игры). action-файл не пишется.
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteState("karlach");
            File.WriteAllText(
                Path.Combine(_tmpDir, "heartbeat.json"),
                System.Text.Json.JsonSerializer.Serialize(new
                {
                    mod = "BG3Neuro",
                    version = "0.4.0",
                    seq = 1,
                    timestamp = DateTimeOffset.UtcNow.AddMinutes(-5).ToString("O"), // старше порога stale
                }));

            var stack = StartStackRawAsync(new IpcConfig
            {
                Dir = _tmpDir,
                PollIntervalMs = 25,
                HeartbeatIntervalS = 2,
                HeartbeatStaleS = 1,
            });
            using (stack.Client)
            using (stack.Ipc)
            {
                var staleSeen = await WaitUntilAsync(() => stack.Ipc.Status == ModStatus.Stale, TimeSpan.FromSeconds(10));
                Assert.True(staleSeen, "Статус мода не перешёл в Stale");

                var client = new HttpClient(new HttpClientHandler { UseProxy = false, Proxy = null });
                using (client)
                {
                    var content = new StringContent(
                        "{\"command\":\"action\",\"data\":{\"id\":\"e2e-modoff-1\",\"name\":\"end_turn\",\"data\":\"{}\"}}",
                        Encoding.UTF8,
                        "application/json");
                    await client.PostAsync($"http://localhost:{_httpPort}/", content);
                }

                var result = await WaitForResultAsync(stack.Sent, "e2e-modoff-1", TimeSpan.FromSeconds(10));
                Assert.NotNull(result);
                Assert.Equal("action/result", result!["command"]!.GetValue<string>());
                Assert.False(result["data"]!["success"]!.GetValue<bool>());
                Assert.Contains("Mod unavailable", result["data"]!["message"]!.GetValue<string>());
                Assert.False(File.Exists(Path.Combine(_tmpDir, "action_e2e-modoff-1.json")), "action_<id>.json не пишется при mod_unavailable (игра не запускается)");
            }
        }
        finally
        {
            await CleanupAsync();
        }
    }

    [Fact]
    public async Task SelectDialogueOption_ActiveDialogue_WritesActionFile_ThenClosedDialogueShowsNextForce()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteStateContent("""
                {
                  "mode": "dialogue",
                  "available_actions": ["select_dialogue_option"],
                  "dialogue": {
                    "speaker_name": "Withers",
                    "line": "Ты принял свою смерть?",
                    "options": [
                      { "option_index": 1, "text": "Да, я готов." },
                      { "option_index": 2, "text": "Расскажи мне ещё." }
                    ]
                  }
                }
                """);
            WriteFreshHeartbeat();

            var (sent, client, ipc) = await StartStackAsync();
            using (client)
            using (ipc)
            {
                var firstForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 1, TimeSpan.FromSeconds(10));
                Assert.True(firstForceSeen, "Force диалога не отправлен");
                var firstForce = JsonNode.Parse(sent.First(m => m.Contains("\"actions/force\"")).ToString())!;
                var firstState = firstForce["data"]!["state"]!.GetValue<string>();
                Assert.Contains("## Dialogue", firstState);
                Assert.Contains("- [1] Да, я готов.", firstState);

                WriteAck("e2e-dlg-1", running: true);
                var result = await PostActionAsync(sent, "e2e-dlg-1", "select_dialogue_option", """{"option_index":1}""", TimeSpan.FromSeconds(10));
                Assert.True(result["data"]!["success"]!.GetValue<bool>(), "Выбор активного диалога должен пройти валидацию (Канал A)");
                var actionFile = JsonNode.Parse(File.ReadAllText(Path.Combine(_tmpDir, "action_e2e-dlg-1.json")))!;
                Assert.Equal("select_dialogue_option", actionFile["name"]!.GetValue<string>());

                // Диалог закрылся после выбора → mode=combat, ход Karlach → новый force
                WriteStateContent("""
                    {
                      "mode": "combat",
                      "turn_actor": "karlach",
                      "turn_initiative_index": 1,
                      "turn_initiative_total": 2,
                      "allies": [
                        { "alias": "karlach", "name": "Karlach", "hp": 45, "max_hp": 60, "distance": 0, "position_x": 0, "position_y": 0 }
                      ],
                      "enemies": [
                        { "alias": "goblin_1", "name": "Goblin Raider", "hp": 12, "max_hp": 18, "distance": 6 }
                      ],
                      "available_actions": ["end_turn"],
                      "events": ["Диалог с Withers завершён"]
                    }
                    """);
                ipc.ReadState();

                var secondForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 2, TimeSpan.FromSeconds(10));
                Assert.True(secondForceSeen, "Force после закрытия диалога не отправлен");
                var secondForce = JsonNode.Parse(sent.Where(m => m.Contains("\"actions/force\"")).Skip(1).First())!;
                var secondState = secondForce["data"]!["state"]!.GetValue<string>();
                Assert.Contains("## Turn: Karlach", secondState);
                Assert.Contains("Диалог с Withers завершён", secondState);
            }
        }
        finally
        {
            await CleanupAsync();
        }
    }

    private async Task<(List<string> Sent, NeuroWebSocketClient Client, IpcClient Ipc)> StartStackAsync()
    {
        var stack = StartStackRawAsync(IpcConfigFor(_tmpDir));
        await WaitUntilAsync(() => stack.Ipc.Status == ModStatus.Alive && stack.Ipc.LastStateContent is not null, TimeSpan.FromSeconds(10));
        return stack;
    }

    private static string ExplorationStateJson() => """
    {
      "mode": "exploration",
      "can_rest": true,
      "objects": [
        { "alias": "wooden_door", "name": "Деревянная дверь", "distance": 3, "status": "закрыта", "interactions": ["открыть", "заламать", "толкнуть"] },
        { "alias": "goblin_corpse", "name": "Труп гоблина", "distance": 5, "lootable": true }
      ],
      "regions": [
        { "name": "Роща", "region_id": "grove_east", "distance": 3 }
      ],
      "available_actions": ["move_to_entity: [wooden_door]", "interact_with: [wooden_door]", "loot: [goblin_corpse]", "rest: [full, partial]", "travel_to: [Роща]"]
    }
    """;

    [Fact]
    public async Task Exploration_MoveToEntity_Interact_Loot_WritesActionFiles_ThenUpdatedStateShowsNextForce()
    {
        try
        {
            if (_randy is null)
            {
                return;
            }

            WriteStateContent(ExplorationStateJson());
            WriteFreshHeartbeat();

            var (sent, client, ipc) = await StartStackAsync();
            using (client)
            using (ipc)
            {
                var firstForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 1, TimeSpan.FromSeconds(10));
                Assert.True(firstForceSeen, "Force режима исследования не отправлен");
                var firstForce = JsonNode.Parse(sent.First(m => m.Contains("\"actions/force\"")))!;
                var firstState = firstForce["data"]!["state"]!.GetValue<string>();
                Assert.Contains("## Mode: exploration", firstState);
                Assert.Contains("- move_to_entity: [wooden_door]", firstState);
                Assert.Contains("## Locations (travel)", firstState);

                WriteAck("e2e-exp-1", running: true);
                var moveResult = await PostActionForIdAsync(sent, "e2e-exp-1", "move_to_entity", """{"target_id":"wooden_door"}""", TimeSpan.FromSeconds(10));
                Assert.True(moveResult["data"]!["success"]!.GetValue<bool>(), "move_to_entity должен пройти валидацию (Канал A)");
                var moveFile = JsonNode.Parse(File.ReadAllText(Path.Combine(_tmpDir, "action_e2e-exp-1.json")))!;
                Assert.Equal("move_to_entity", moveFile["name"]!.GetValue<string>());

                WriteStateContent("""
                    {
                      "mode": "exploration",
                      "can_rest": true,
                      "objects": [
                        { "alias": "wooden_door", "name": "Деревянная дверь", "distance": 1, "status": "закрыта", "interactions": ["открыть", "заламать", "толкнуть"] },
                        { "alias": "goblin_corpse", "name": "Труп гоблина", "distance": 5, "lootable": true }
                      ],
                      "regions": [
                        { "name": "Роща", "region_id": "grove_east", "distance": 3 }
                      ],
                      "available_actions": ["move_to_entity: [wooden_door]", "interact_with: [wooden_door]", "loot: [goblin_corpse]", "rest: [full, partial]"],
                      "events": ["Karlach подошла к двери"]
                    }
                    """);
                ipc.ReadState();

                var secondForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 2, TimeSpan.FromSeconds(10));
                Assert.True(secondForceSeen, "Force после перемещения не отправлен");
                var secondForce = JsonNode.Parse(sent.Where(m => m.Contains("\"actions/force\"")).Skip(1).First())!;
                var secondState = secondForce["data"]!["state"]!.GetValue<string>();
                Assert.Contains("- wooden_door (Деревянная дверь) 1m, закрыта: [открыть, заламать, толкнуть]", secondState);
                Assert.Contains("- Karlach подошла к двери", secondState);

                WriteAck("e2e-exp-2", running: true);
                var interactResult = await PostActionForIdAsync(sent, "e2e-exp-2", "interact_with", """{"target_id":"wooden_door","interaction_type":"открыть"}""", TimeSpan.FromSeconds(10));
                Assert.True(interactResult["data"]!["success"]!.GetValue<bool>(), "interact_with должен пройти валидацию (Канал A)");
                var interactFile = JsonNode.Parse(File.ReadAllText(Path.Combine(_tmpDir, "action_e2e-exp-2.json")))!;
                var interactData = JsonNode.Parse(interactFile["data"]!.GetValue<string>())!;
                Assert.Equal("открыть", interactData["interaction_type"]!.GetValue<string>());

                WriteStateContent("""
                    {
                      "mode": "exploration",
                      "can_rest": true,
                      "objects": [
                        { "alias": "wooden_door", "name": "Деревянная дверь", "distance": 1, "status": "открыта", "interactions": ["закрыть", "заламать", "толкнуть"] },
                        { "alias": "goblin_corpse", "name": "Труп гоблина", "distance": 5, "lootable": true }
                      ],
                      "regions": [
                        { "name": "Роща", "region_id": "grove_east", "distance": 3 }
                      ],
                      "available_actions": ["interact_with: [wooden_door]", "loot: [goblin_corpse]", "rest: [full, partial]"],
                      "events": ["Дверь открыта"]
                    }
                    """);
                ipc.ReadState();

                var thirdForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 3, TimeSpan.FromSeconds(10));
                Assert.True(thirdForceSeen, "Force после открытия двери не отправлен");
                var thirdForce = JsonNode.Parse(sent.Where(m => m.Contains("\"actions/force\"")).Skip(2).First())!;
                var thirdState = thirdForce["data"]!["state"]!.GetValue<string>();
                Assert.Contains("закрыть, заламать, толкнуть", thirdState);
                Assert.Contains("- Дверь открыта", thirdState);

                WriteAck("e2e-exp-3", running: true);
                var lootResult = await PostActionForIdAsync(sent, "e2e-exp-3", "loot", """{"target_id":"goblin_corpse"}""", TimeSpan.FromSeconds(10));
                Assert.True(lootResult["data"]!["success"]!.GetValue<bool>(), "loot должен пройти валидацию (Канал A)");
                var lootFile = JsonNode.Parse(File.ReadAllText(Path.Combine(_tmpDir, "action_e2e-exp-3.json")))!;
                Assert.Equal("loot", lootFile["name"]!.GetValue<string>());

                WriteStateContent("""
                    {
                      "mode": "inventory",
                      "can_rest": true,
                      "inventory": [
                        { "alias": "potion_healing", "name": "Малый эликсир лечения", "quantity": 2, "category": "Зелье" }
                      ],
                      "available_actions": ["use_item", "open_inventory", "toggle_mode"],
                      "events": ["У трупа найдено: Малый эликсир лечения"]
                    }
                    """);
                ipc.ReadState();

                var fourthForceSeen = await WaitUntilAsync(() => sent.Count(m => m.Contains("\"actions/force\"")) >= 4, TimeSpan.FromSeconds(10));
                Assert.True(fourthForceSeen, "Force инвентаря не отправлен");
                var fourthForce = JsonNode.Parse(sent.Where(m => m.Contains("\"actions/force\"")).Skip(3).First())!;
                var fourthState = fourthForce["data"]!["state"]!.GetValue<string>();
                Assert.Contains("## Screen: inventory", fourthState);
                Assert.Contains("- Малый эликсир лечения (potion_healing) ×2, Зелье", fourthState);
                Assert.Contains("- У трупа найдено: Малый эликсир лечения", fourthState);
            }
        }
        finally
        {
            await CleanupAsync();
        }
    }

    private (List<string> Sent, NeuroWebSocketClient Client, IpcClient Ipc) StartStackRawAsync(IpcConfig config)
    {
        var sent = new List<string>();
        var ipc = new IpcClient(config);
        ipc.Start();
        var client = new NeuroWebSocketClient($"ws://localhost:{_wsPort}", Game, ActionRegistry.Get(), TimeSpan.FromSeconds(1));
        client.MessageSent += (_, text) => sent.Add(text);
        var router = new ActionRouter(new IpcPaths(_tmpDir), controlledPartySize: 1);
        var loop = new DecisionLoop(client, ipc, router);
        client.Start();
        loop.Start();
        return (sent, client, ipc);
    }

    private static async Task<JsonNode?> WaitForResultAsync(List<string> sent, string id, TimeSpan timeout)
    {
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed < timeout)
        {
            var result = sent.LastOrDefault(m => m.Contains("\"action/result\"") && m.Contains(id));
            if (result is not null)
            {
                return JsonNode.Parse(result);
            }

            await Task.Delay(20);
        }

        return null;
    }

    private async Task<JsonNode> PostActionForIdAsync(List<string> sent, string id, string name, string dataJson, TimeSpan timeout)
    {
        var client = new HttpClient(new HttpClientHandler { UseProxy = false, Proxy = null });
        using (client)
        {
            var payload = new StringContent(
                $"{{\"command\":\"action\",\"data\":{{\"id\":\"{id}\",\"name\":\"{name}\",\"data\":\"{dataJson.Replace("\"", "\\\"")}\"}}}}",
                Encoding.UTF8,
                "application/json");
            await client.PostAsync($"http://localhost:{_httpPort}/", payload);
        }

        var node = await WaitForResultAsync(sent, id, timeout);
        Assert.NotNull(node);
        return node!;
    }

    private async Task<JsonNode> PostActionAsync(List<string> sent, string id, string name, string dataJson, TimeSpan timeout)
    {
        var resultTcs = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
        _ = Task.Run(() => ListenForResultAsync(sent, resultTcs));

        var client = new HttpClient(new HttpClientHandler { UseProxy = false, Proxy = null });
        using (client)
        {
            var payload = new StringContent(
                $"{{\"command\":\"action\",\"data\":{{\"id\":\"{id}\",\"name\":\"{name}\",\"data\":\"{dataJson.Replace("\"", "\\\"")}\"}}}}",
                Encoding.UTF8,
                "application/json");
            await client.PostAsync($"http://localhost:{_httpPort}/", payload);
        }

        return await resultTcs.Task.WaitAsync(timeout);
    }

    private async Task<JsonNode> RunEndTurnAsync(string id, string dataJson)
    {
        var (sent, client, ipc) = await StartStackAsync();
        using (client)
        using (ipc)
        {
            return await PostActionAsync(sent, id, "end_turn", dataJson, TimeSpan.FromSeconds(10));
        }
    }

    private static async Task ListenForResultAsync(List<string> sent, TaskCompletionSource<JsonNode> tcs)
    {
        while (true)
        {
            var result = sent.LastOrDefault(m => m.Contains("\"action/result\""));
            if (result is not null)
            {
                tcs.TrySetResult(JsonNode.Parse(result)!);
                return;
            }

            await Task.Delay(20);
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

    private async Task CleanupAsync()
    {
        if (_randy is not null)
        {
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

        if (Directory.Exists(_tmpDir))
        {
            try
            {
                Directory.Delete(_tmpDir, recursive: true);
            }
            catch
            {
            }
        }
    }

    public void Dispose()
    {
    }
}