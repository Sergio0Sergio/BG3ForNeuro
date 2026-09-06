using System.Text.Json.Nodes;
using BG3Neuro.Core.Actions;
using BG3Neuro.Core.Neuro;
using Xunit;

namespace BG3Neuro.Core.Tests.Neuro;

public class ActionRegistryTests
{
    private static readonly string[] Combat = { "move_to_target", "attack_entity", "cast_spell", "use_item", "throw", "bonus_action", "set_reaction", "end_turn" };
    private static readonly string[] Exploration = { "move_to_entity", "interact_with", "loot", "open_map", "open_inventory", "toggle_mode", "rest", "travel_to" };

    [Fact]
    public void Get_Returns17Actions_CombatDialogueExploration()
    {
        var actions = ActionRegistry.Get();

        Assert.Equal(17, actions.Count);
        Assert.Equal(Combat, actions.Take(8).Select(a => a.Name).ToArray());
        Assert.Equal("select_dialogue_option", actions[8].Name);
        Assert.Equal(Exploration, actions.Skip(9).Select(a => a.Name).ToArray());
    }

    [Fact]
    public void Get_EveryAction_HasSchema_WithTypeObject()
    {
        foreach (var action in ActionRegistry.Get())
        {
            Assert.NotNull(action.Schema);
            Assert.Equal("object", action.Schema["type"]?.GetValue<string>());
            Assert.NotNull(action.Schema["properties"]);
        }
    }

    [Fact]
    public void Get_EndTurnRequiresNothing()
    {
        var endTurn = ActionRegistry.Find("end_turn");
        Assert.NotNull(endTurn);
        Assert.Empty(endTurn!.Schema["required"]!.AsArray());
    }

    [Fact]
    public void Find_KnownAndUnknown()
    {
        Assert.NotNull(ActionRegistry.Find("cast_spell"));
        Assert.NotNull(ActionRegistry.Find("select_dialogue_option"));
        Assert.Null(ActionRegistry.Find("no_such_action"));
    }
}

public class NeuroWebSocketClientTests
{
    private const string Game = "Baldur's Gate 3";
    private static readonly TimeSpan QuickReconnect = TimeSpan.FromMilliseconds(100);

    private static async Task<List<JsonNode>> WaitForRegisterAsync(FakeNeuroServer server, int expectedRegisterCount, int timeoutMs = 5000)
    {
        return await server.WaitForMessagesAsync(m =>
        {
            var registers = m.Where(n => n["command"]?.GetValue<string>() == "actions/register").ToList();
            return registers.Count >= expectedRegisterCount;
        }, timeoutMs);
    }

    private static string[] ExtractActionNames(JsonNode message)
    {
        return message["data"]!["actions"]!.AsArray()
            .Select(a => a!["name"]!.GetValue<string>())
            .ToArray();
    }

    [Fact]
    public async Task Connect_SendsStartupThenRegister_WithAll17Actions()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        using var client = new NeuroWebSocketClient(server.Url, Game, ActionRegistry.Get(), QuickReconnect);

        client.Start();

        var messages = await server.WaitForMessagesAsync(m =>
            m.Count >= 2 &&
            m[0]["command"]?.GetValue<string>() == "startup" &&
            m[1]["command"]?.GetValue<string>() == "actions/register");

        Assert.Equal("startup", messages[0]["command"]!.GetValue<string>());
        Assert.Equal(Game, messages[0]["game"]!.GetValue<string>());

        var register = messages[1];
        Assert.Equal("actions/register", register["command"]!.GetValue<string>());
        Assert.Equal(Game, register["game"]!.GetValue<string>());
        Assert.Equal(17, register["data"]!["actions"]!.AsArray().Count);
    }

    [Fact]
    public async Task RegisterPayload_HasNameDescriptionSchema_ForEveryAction()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        using var client = new NeuroWebSocketClient(server.Url, Game, ActionRegistry.Get(), QuickReconnect);

        client.Start();

        var messages = await server.WaitForMessagesAsync(m =>
            m.Count >= 2 && m[1]["command"]?.GetValue<string>() == "actions/register");
        var actions = messages[1]["data"]!["actions"]!.AsArray();

        foreach (var action in actions)
        {
            Assert.NotNull(action!["name"]);
            Assert.NotNull(action!["description"]);
            Assert.Equal("object", action!["schema"]?["type"]?.GetValue<string>());
        }
    }

    [Fact]
    public async Task ReregisterAll_ResendsSameFixedSet_NoDuplicates()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        using var client = new NeuroWebSocketClient(server.Url, Game, ActionRegistry.Get(), QuickReconnect);

        client.Start();

        await server.WaitForCountAsync(2);
        server.Send(new JsonObject { ["command"] = "actions/reregister_all" });

        var messages = await WaitForRegisterAsync(server, 2);

        var firstNames = ExtractActionNames(messages.First(m => m["command"]!.GetValue<string>() == "actions/register"));
        var registers = messages.Where(m => m["command"]!.GetValue<string>() == "actions/register").ToList();
        var secondNames = ExtractActionNames(registers[1]);

        Assert.Equal(17, firstNames.Length);
        Assert.Equal(17, secondNames.Length);
        Assert.Equal(firstNames, secondNames);
        Assert.Equal(17, secondNames.Distinct().Count());
    }

    [Fact]
    public async Task Reconnect_RepairsRegistration_StableSetBetweenReconnects()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        using var client = new NeuroWebSocketClient(server.Url, Game, ActionRegistry.Get(), QuickReconnect);

        client.Start();

        await server.WaitForCountAsync(2);
        server.CloseAllConnections();

        var messages = await WaitForRegisterAsync(server, 2, timeoutMs: 10000);

        var registers = messages.Where(m => m["command"]!.GetValue<string>() == "actions/register").ToList();
        var beforeReconnect = ExtractActionNames(registers[0]);
        var afterReconnect = ExtractActionNames(registers[1]);

        Assert.Equal(beforeReconnect, afterReconnect);
        Assert.Equal(17, afterReconnect.Distinct().Count());
    }

    [Fact]
    public async Task ActionReceived_RaisesActionRequested()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        using var client = new NeuroWebSocketClient(server.Url, Game, ActionRegistry.Get(), QuickReconnect);

        var tcs = new TaskCompletionSource<ActionRequestedEventArgs>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.ActionRequested += (_, e) => tcs.TrySetResult(e);
        client.Start();

        await server.WaitForCountAsync(2);

        server.Send(new JsonObject
        {
            ["command"] = "action",
            ["data"] = new JsonObject
            {
                ["id"] = "42",
                ["name"] = "end_turn",
                ["data"] = "{\"actor\":\"player\"}",
            },
        });

        var e = await tcs.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("42", e.Id);
        Assert.Equal("end_turn", e.Name);
        Assert.Equal("{\"actor\":\"player\"}", e.Data);
    }

    [Fact]
    public async Task StartupAck_RaisesSessionStarted()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        using var client = new NeuroWebSocketClient(server.Url, Game, ActionRegistry.Get(), QuickReconnect);

        var tcs = new TaskCompletionSource<SessionInfo>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.SessionStarted += (_, e) => tcs.TrySetResult(e.Session);
        client.Start();

        await server.WaitForCountAsync(2);

        server.Send(new JsonObject
        {
            ["command"] = "startup",
            ["data"] = new JsonObject
            {
                ["session"] = new JsonObject
                {
                    ["sessionId"] = "sess-1",
                    ["characterId"] = "char-1",
                    ["displayName"] = "Gale",
                },
            },
        });

        var session = await tcs.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("sess-1", session.SessionId);
        Assert.Equal("char-1", session.CharacterId);
        Assert.Equal("Gale", session.DisplayName);
    }

    [Fact]
    public async Task UnknownCommand_IsIgnored_ConnectionStaysAlive()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        using var client = new NeuroWebSocketClient(server.Url, Game, ActionRegistry.Get(), QuickReconnect);

        client.Start();
        await server.WaitForCountAsync(2);

        server.Send(new JsonObject { ["command"] = "unknown/thing" });

        var tcs = new TaskCompletionSource<ActionRequestedEventArgs>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.ActionRequested += (_, e) => tcs.TrySetResult(e);
        server.Send(new JsonObject
        {
            ["command"] = "action",
            ["data"] = new JsonObject { ["id"] = "7", ["name"] = "rest" },
        });

        var e = await tcs.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("rest", e.Name);
    }

    [Fact]
    public async Task SendResult_EmitsActionResultMessage()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        using var client = new NeuroWebSocketClient(server.Url, Game, ActionRegistry.Get(), QuickReconnect);

        client.Start();
        await server.WaitForCountAsync(2);

        await client.SendResultAsync("42", true, "ok");

        var messages = await server.WaitForMessagesAsync(m =>
            m.Count >= 3 && m[2]["command"]?.GetValue<string>() == "action/result");
        var result = messages[2];
        Assert.Equal("action/result", result["command"]!.GetValue<string>());
        Assert.Equal(Game, result["game"]!.GetValue<string>());
        Assert.Equal("42", result["data"]!["id"]!.GetValue<string>());
        Assert.True(result["data"]!["success"]!.GetValue<bool>());
        Assert.Equal("ok", result["data"]!["message"]!.GetValue<string>());
    }

    [Fact]
    public async Task SendForce_EmitsActionsForceMessage_WithStateAndActions()
    {
        await using var server = new FakeNeuroServer();
        server.Start();
        using var client = new NeuroWebSocketClient(server.Url, Game, ActionRegistry.Get(), QuickReconnect);

        client.Start();
        await server.WaitForCountAsync(2);

        await client.SendForceAsync("## Ход: Karlach", "Сейчас твой ход. Выбери действие.", new[] { "end_turn" });

        var messages = await server.WaitForMessagesAsync(m =>
            m.Count >= 3 && m[2]["command"]?.GetValue<string>() == "actions/force");
        var force = messages[2];
        Assert.Equal("actions/force", force["command"]!.GetValue<string>());
        Assert.Equal(Game, force["game"]!.GetValue<string>());
        Assert.Equal("## Ход: Karlach", force["data"]!["state"]!.GetValue<string>());
        Assert.Equal("low", force["data"]!["priority"]!.GetValue<string>());
        Assert.True(force["data"]!["ephemeral_context"]!.GetValue<bool>());
        Assert.Equal("end_turn", force["data"]!["action_names"]![0]!.GetValue<string>());
    }
}