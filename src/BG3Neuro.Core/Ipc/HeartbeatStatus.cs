namespace BG3Neuro.Core.Ipc;

public static class HeartbeatStatus
{
    public static ModStatus Evaluate(HeartbeatPayload? heartbeat, DateTimeOffset nowUtc, TimeSpan staleAfter)
    {
        if (heartbeat is null)
        {
            return ModStatus.Unknown;
        }

        return nowUtc - heartbeat.Timestamp > staleAfter ? ModStatus.Stale : ModStatus.Alive;
    }
}