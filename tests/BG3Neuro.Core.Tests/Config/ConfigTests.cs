using BG3Neuro.Core.Config;
using Xunit;

namespace BG3Neuro.Core.Tests.Config;

public class AppConfigDefaultsTests
{
    [Fact]
    public void Defaults_MatchSpec_Section4()
    {
        var c = AppConfigDefaults.Create();

        Assert.Equal("ws://localhost:8000", c.Neuro.WsUrl);
        Assert.Equal(3, c.Neuro.ReconnectIntervalS);

        Assert.Equal("bg3_to_neuro.json", c.Ipc.StateFile);
        Assert.Equal("neuro_to_bg3.json", c.Ipc.CommandFile);
        Assert.Equal(100, c.Ipc.PollIntervalMs);
        Assert.Equal(2, c.Ipc.HeartbeatIntervalS);
        Assert.Equal(10, c.Ipc.HeartbeatStaleS);

        Assert.Equal("Baldur's Gate 3", c.Game.Name);
        Assert.Equal(1, c.Game.ControlledPartySize);

        Assert.Equal(20, c.Actions.ResultTimeoutS);

        Assert.Equal("confirm", c.Dialogue.Mode);

        Assert.False(c.State.Combat.ShowQuestMarker);
        Assert.True(c.State.Exploration.ShowQuestMarker);
        Assert.Equal(20, c.State.Exploration.MaxVisibleObjects);
        Assert.False(c.State.Exploration.ObjectInfo.SkillRequirements);
        Assert.Equal("hybrid", c.State.Exploration.DistanceFormat);
        Assert.False(c.State.Exploration.ShowPosition);
    }
}

public class ConfigLoaderTests : IDisposable
{
    private readonly string _tmpDir;

    public ConfigLoaderTests()
    {
        _tmpDir = Path.Combine(Path.GetTempPath(), "bg3neuro-config-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tmpDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tmpDir))
        {
            Directory.Delete(_tmpDir, recursive: true);
        }
    }

    private string WriteConfig(string json)
    {
        var path = Path.Combine(_tmpDir, "config.json");
        File.WriteAllText(path, json);
        return path;
    }

    [Fact]
    public void Load_MissingFile_ReturnsDefaults()
    {
        var path = Path.Combine(_tmpDir, "absent.json");
        var config = ConfigLoader.Load(path);

        Assert.Equal(2, config.Ipc.HeartbeatIntervalS);
        Assert.Equal(10, config.Ipc.HeartbeatStaleS);
    }

    [Fact]
    public void Load_PartialFile_MergesOverDefaults()
    {
        var path = WriteConfig("""{ "ipc": { "heartbeat_stale_s": 7 } }""");
        var config = ConfigLoader.Load(path);

        Assert.Equal(7, config.Ipc.HeartbeatStaleS);
        Assert.Equal(2, config.Ipc.HeartbeatIntervalS);
        Assert.Equal("ws://localhost:8000", config.Neuro.WsUrl);
    }

    [Fact]
    public void Load_FullFile_OverridesAll()
    {
        var path = WriteConfig("""
        {
          "neuro": { "ws_url": "ws://192.168.1.10:9000", "reconnect_interval_s": 5 },
          "ipc": {
            "dir": "C:/temp/bg3ipc",
            "state_file": "s.json",
            "command_file": "c.json",
            "poll_interval_ms": 50,
            "heartbeat_interval_s": 1,
            "heartbeat_stale_s": 6
          },
          "game": { "name": "BG3", "controlledPartySize": 2 },
          "actions": { "result_timeout_s": 30 },
          "dialogue": { "mode": "autoselect" },
          "state": {
            "combat": { "showQuestMarker": true },
            "exploration": {
              "showQuestMarker": false,
              "maxVisibleObjects": 5,
              "objectInfo": { "visible": false, "skillRequirements": true },
              "distanceFormat": "meters",
              "showPosition": true
            }
          }
        }
        """);

        var config = ConfigLoader.Load(path);

        Assert.Equal("ws://192.168.1.10:9000", config.Neuro.WsUrl);
        Assert.Equal(5, config.Neuro.ReconnectIntervalS);
        Assert.Equal("C:/temp/bg3ipc", config.Ipc.Dir);
        Assert.Equal("s.json", config.Ipc.StateFile);
        Assert.Equal("c.json", config.Ipc.CommandFile);
        Assert.Equal(50, config.Ipc.PollIntervalMs);
        Assert.Equal(1, config.Ipc.HeartbeatIntervalS);
        Assert.Equal(6, config.Ipc.HeartbeatStaleS);
        Assert.Equal(2, config.Game.ControlledPartySize);
        Assert.Equal(30, config.Actions.ResultTimeoutS);
        Assert.Equal("autoselect", config.Dialogue.Mode);
        Assert.True(config.State.Combat.ShowQuestMarker);
        Assert.False(config.State.Exploration.ShowQuestMarker);
        Assert.Equal(5, config.State.Exploration.MaxVisibleObjects);
        Assert.False(config.State.Exploration.ObjectInfo.Visible);
        Assert.True(config.State.Exploration.ObjectInfo.SkillRequirements);
        Assert.Equal("meters", config.State.Exploration.DistanceFormat);
        Assert.True(config.State.Exploration.ShowPosition);
    }

    [Fact]
    public void Load_Agents_SnakeCaseKeys_BindOwnedAlias()
    {
        var path = WriteConfig("""
        {
          "agents": [
            { "character_id": "neuro", "owned_alias": "tav" },
            { "character_id": "evil",  "owned_alias": "origin_astarion" }
          ]
        }
        """);

        var config = ConfigLoader.Load(path);

        Assert.Equal(2, config.Agents.Count);
        Assert.Equal("neuro", config.Agents[0].CharacterId);
        Assert.Equal("tav", config.Agents[0].OwnedAlias);
        Assert.Equal("", config.Agents[0].WsUrl);
        Assert.Equal("evil", config.Agents[1].CharacterId);
        Assert.Equal("origin_astarion", config.Agents[1].OwnedAlias);
    }

    [Fact]
    public void Load_Agents_CamelCaseKeys_NormalizedToSnakeCase()
    {
        var path = WriteConfig("""
        {
          "agents": [
            { "characterId": "neuro", "ownedAlias": "tav" }
          ]
        }
        """);

        var config = ConfigLoader.Load(path);

        Assert.Single(config.Agents);
        Assert.Equal("neuro", config.Agents[0].CharacterId);
        Assert.Equal("tav", config.Agents[0].OwnedAlias);
    }

    [Fact]
    public void Load_InvalidJson_ThrowsConfigException()
    {
        var path = WriteConfig("{ not json ]");
        Assert.Throws<ConfigException>(() => ConfigLoader.Load(path));
    }
}