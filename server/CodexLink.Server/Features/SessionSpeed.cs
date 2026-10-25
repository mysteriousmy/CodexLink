using System.Text.Json.Nodes;

namespace CodexLink.Server.Features;

public sealed partial class SessionService
{
    private static void ReadServiceTier(SessionState session, JsonNode? settings)
    {
        session.ServiceTierKnown = settings is JsonObject value && value.ContainsKey("serviceTier");
        session.ServiceTier = session.ServiceTierKnown ? settings.String("serviceTier") : null;
    }

    private static JsonObject SpeedState(SessionState session) =>
        Json.Object(("serviceTier", session.ServiceTier), ("serviceTierKnown", session.ServiceTierKnown));

    public async Task<JsonObject> SetSpeedAsync(string id, SetSpeedRequest request)
    {
        var tier = request.Mode switch
        {
            "fast" => "priority",
            "standard" => "default",
            _ => throw new ApiException(400, "invalid_speed", "速度模式必须是 fast 或 standard。")
        };
        await AuthorizeAsync(id);
        var session = _sessions[id];
        await session.Gate.WaitAsync();
        try
        {
            if (session.ControlReason is not null) throw new ApiException(409, "thread_read_only", session.ControlReason);
            await ResumeInsideLockAsync(id, session);
            session.PendingServiceTier = tier;
            session.SpeedChanged = new(TaskCreationOptions.RunContinuationsAsynchronously);
            // Explicit standard bypasses global/model defaults. Never modify a
            // thread's model, permissions, goal, or in-progress turn here.
            await _rpc.CallAsync("thread/settings/update", Json.Object(("threadId", id), ("serviceTier", tier)));
            try { return await session.SpeedChanged.Task.WaitAsync(TimeSpan.FromSeconds(10)); }
            catch (TimeoutException)
            {
                session.ServiceTierKnown = false;
                if (session.Materialized) session.Loaded = false;
                throw new ApiException(504, "speed_unconfirmed", "速度设置已提交，但尚未收到 Codex 确认；请同步后核对。");
            }
        }
        finally
        {
            session.PendingServiceTier = null;
            session.SpeedChanged = null;
            session.Gate.Release();
        }
    }
}
