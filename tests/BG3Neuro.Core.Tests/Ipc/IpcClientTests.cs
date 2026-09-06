using BG3Neuro.Core.Config;
using BG3Neuro.Core.Ipc;
using Xunit;

namespace BG3Neuro.Core.Tests.Ipc;

public class HeartbeatStatusTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 5, 12, 0, 0, TimeSpan.Zero);
    private static readonly TimeSpan StaleAfter = TimeSpan.FromSeconds(10);

    [Fact]
    public void Evaluate_NullHeartbeat_Unknown()
    {
        Assert.Equal(ModStatus.Unknown, HeartbeatStatus.Evaluate(null, Now, StaleAfter));
    }

    [Fact]
    public void Evaluate_FreshHeartbeat_Alive()
    {
        var hb = new HeartbeatPayload { Timestamp = Now.AddSeconds(-5) };
        Assert.Equal(ModStatus.Alive, HeartbeatStatus.Evaluate(hb, Now, StaleAfter));
    }

    [Fact]
    public void Evaluate_ExactlyAtThreshold_Alive()
    {
        var hb = new HeartbeatPayload { Timestamp = Now.AddSeconds(-10) };
        Assert.Equal(ModStatus.Alive, HeartbeatStatus.Evaluate(hb, Now, StaleAfter));
    }

    [Fact]
    public void Evaluate_JustPastThreshold_Stale()
    {
        var hb = new HeartbeatPayload { Timestamp = Now.AddSeconds(-10 - 1e-6) };
        Assert.Equal(ModStatus.Stale, HeartbeatStatus.Evaluate(hb, Now, StaleAfter));
    }

    [Fact]
    public void Evaluate_FutureTimestamp_Alive()
    {
        var hb = new HeartbeatPayload { Timestamp = Now.AddSeconds(30) };
        Assert.Equal(ModStatus.Alive, HeartbeatStatus.Evaluate(hb, Now, StaleAfter));
    }

    [Fact]
    public void Evaluate_MuchOlder_Stale()
    {
        var hb = new HeartbeatPayload { Timestamp = Now.AddSeconds(-120) };
        Assert.Equal(ModStatus.Stale, HeartbeatStatus.Evaluate(hb, Now, StaleAfter));
    }
}

public class HeartbeatFileTests : IDisposable
{
    private readonly string _tmpDir = Path.Combine(Path.GetTempPath(), "bg3neuro-heartbeat-" + Guid.NewGuid().ToString("N"));

    public HeartbeatFileTests()
    {
        Directory.CreateDirectory(_tmpDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tmpDir))
        {
            Directory.Delete(_tmpDir, recursive: true);
        }
    }

    private string PathFor() => Path.Combine(_tmpDir, "heartbeat.json");

    [Fact]
    public void TryRead_MissingFile_Null()
    {
        Assert.Null(HeartbeatFile.TryRead(PathFor()));
    }

    [Fact]
    public void TryRead_EmptyFile_Null()
    {
        File.WriteAllText(PathFor(), "");
        Assert.Null(HeartbeatFile.TryRead(PathFor()));
    }

    [Fact]
    public void TryRead_WhitespaceOnly_Null()
    {
        File.WriteAllText(PathFor(), "   \n\t ");
        Assert.Null(HeartbeatFile.TryRead(PathFor()));
    }

    [Fact]
    public void TryRead_InvalidJson_Null()
    {
        File.WriteAllText(PathFor(), "{ not json");
        Assert.Null(HeartbeatFile.TryRead(PathFor()));
    }

    [Fact]
    public void TryRead_TruncatedJson_Null()
    {
        File.WriteAllText(PathFor(), """{ "mod": "BG3Neuro", "seq": 1, "timestamp": """);
        Assert.Null(HeartbeatFile.TryRead(PathFor()));
    }

    [Fact]
    public void TryRead_ValidJson_ReturnsPayload()
    {
        File.WriteAllText(PathFor(), """{ "mod": "BG3Neuro", "version": "0.1.0", "seq": 42, "timestamp": "2026-09-05T12:00:05Z" }""");
        var payload = HeartbeatFile.TryRead(PathFor());

        Assert.NotNull(payload);
        Assert.Equal("BG3Neuro", payload.Mod);
        Assert.Equal("0.1.0", payload.Version);
        Assert.Equal(42, payload.Seq);
        Assert.Equal(new DateTimeOffset(2026, 9, 5, 12, 0, 5, TimeSpan.Zero), payload.Timestamp);
    }

    [Fact]
    public void TryRead_MissingTimestampField_Null()
    {
        File.WriteAllText(PathFor(), """{ "mod": "BG3Neuro", "seq": 1 }""");
        var payload = HeartbeatFile.TryRead(PathFor());

        Assert.NotNull(payload);
        Assert.Equal(default, payload.Timestamp);
    }
}

public class IpcClientTests : IDisposable
{
    private readonly string _tmpDir = Path.Combine(Path.GetTempPath(), "bg3neuro-ipc-" + Guid.NewGuid().ToString("N"));

    public IpcClientTests()
    {
        Directory.CreateDirectory(_tmpDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tmpDir))
        {
            Directory.Delete(_tmpDir, recursive: true);
        }
    }

    private static IpcConfig ConfigFor(string dir) => new()
    {
        Dir = dir,
        PollIntervalMs = 10,
        HeartbeatIntervalS = 2,
        HeartbeatStaleS = 10,
    };

    private static readonly DateTimeOffset T0 = new(2026, 9, 5, 12, 0, 0, TimeSpan.Zero);

    private void WriteHeartbeat(string dir, long seq, DateTimeOffset ts) =>
        File.WriteAllText(
            Path.Combine(dir, "heartbeat.json"),
            System.Text.Json.JsonSerializer.Serialize(new
            {
                mod = "BG3Neuro",
                version = "0.1.0",
                seq,
                timestamp = ts.ToString("O"),
            }));

    [Fact]
    public void PollOnce_NoFile_Unknown()
    {
        var client = new IpcClient(ConfigFor(_tmpDir));
        Assert.Equal(ModStatus.Unknown, client.PollOnce(T0));
    }

    [Fact]
    public void PollOnce_FreshHeartbeat_Alive()
    {
        WriteHeartbeat(_tmpDir, 1, T0);
        var client = new IpcClient(ConfigFor(_tmpDir));

        Assert.Equal(ModStatus.Alive, client.PollOnce(T0.AddSeconds(1)));
    }

    [Fact]
    public void PollOnce_HearbeatGoneStale_Stale()
    {
        WriteHeartbeat(_tmpDir, 1, T0);
        var client = new IpcClient(ConfigFor(_tmpDir));
        Assert.Equal(ModStatus.Alive, client.PollOnce(T0));

        WriteHeartbeat(_tmpDir, 2, T0.AddSeconds(1));
        Assert.Equal(ModStatus.Alive, client.PollOnce(T0.AddSeconds(2)));
        Assert.Equal(ModStatus.Stale, client.PollOnce(T0.AddSeconds(30)));
    }

    [Fact]
    public void PollOnce_PartialWrite_KeepsStatusByLastValid()
    {
        WriteHeartbeat(_tmpDir, 1, T0);
        var client = new IpcClient(ConfigFor(_tmpDir));
        Assert.Equal(ModStatus.Alive, client.PollOnce(T0.AddSeconds(1)));

        File.WriteAllText(Path.Combine(_tmpDir, "heartbeat.json"), "{ partial");
        Assert.Equal(ModStatus.Alive, client.PollOnce(T0.AddSeconds(2)));

        Assert.Equal(ModStatus.Stale, client.PollOnce(T0.AddSeconds(30)));
    }

    [Fact]
    public void PollOnce_RemovedFile_StaleAfterThreshold()
    {
        WriteHeartbeat(_tmpDir, 1, T0);
        var client = new IpcClient(ConfigFor(_tmpDir));
        Assert.Equal(ModStatus.Alive, client.PollOnce(T0));

        File.Delete(Path.Combine(_tmpDir, "heartbeat.json"));
        Assert.Equal(ModStatus.Alive, client.PollOnce(T0.AddSeconds(5)));
        Assert.Equal(ModStatus.Stale, client.PollOnce(T0.AddSeconds(30)));
    }

    [Fact]
    public void HeartbeatChanged_FiresOnTransition()
    {
        var transitions = new List<(ModStatus prev, ModStatus curr)>();
        var client = new IpcClient(ConfigFor(_tmpDir));
        client.HeartbeatChanged += (_, e) => transitions.Add((e.Previous, e.Current));

        client.PollOnce(T0);
        Assert.Empty(transitions);

        WriteHeartbeat(_tmpDir, 1, T0);
        client.PollOnce(T0.AddSeconds(1));
        Assert.Equal(new[] { (ModStatus.Unknown, ModStatus.Alive) }, transitions);

        client.PollOnce(T0.AddSeconds(30));
        Assert.Equal(2, transitions.Count);
        Assert.Equal((ModStatus.Alive, ModStatus.Stale), transitions[1]);
    }
}