using System.Text.Json.Nodes;

namespace CodexLink.Server.Features;

public sealed partial class SessionService
{
    public Task<JsonNode?> ArchiveAsync(string id, ThreadActionRequest request, string device) =>
        _operations.RunAsync(device, request.RequestId, "archive:" + id, async () =>
        {
            await AuthorizeAsync(id);
            var session = _sessions[id];
            await session.Gate.WaitAsync();
            try
            {
                if (!session.Archived)
                    await _rpc.CallAsync("thread/archive", Json.Object(("threadId", id)));
                session.Archived = true;
                session.Closed = true;
                session.CloseRequested = false;
                session.Loaded = false;
                session.ActiveTurn = null;
                session.ControlReason = "会话已归档，请先恢复会话。";
                var result = Json.Object(("threadId", id), ("state", "archived"));
                _events.Publish("thread/lifecycle/changed", result);
                return result;
            }
            finally { session.Gate.Release(); }
        });

    public Task<JsonNode?> CloseAsync(string id, ThreadActionRequest request, string device) =>
        _operations.RunAsync(device, request.RequestId, "close:" + id, async () =>
        {
            await AuthorizeAsync(id);
            var session = _sessions[id];
            await session.Gate.WaitAsync();
            try
            {
                // A refresh must not resubscribe while native unload is pending.
                // Explicitly opening the conversation clears this barrier.
                var closeVersion = session.CloseEventVersion;
                JsonNode? response;
                try { response = await _rpc.CallAsync("thread/unsubscribe", Json.Object(("threadId", id))); }
                catch (ApiException e) when (e.Code is "rpc_timeout" or "codex_disconnected")
                {
                    // The peer may have accepted unsubscribe before the response was lost.
                    // Keep refresh from silently undoing it; only an explicit reopen resumes.
                    session.Closed = true;
                    session.Loaded = false;
                    session.CloseRequested = true;
                    session.ControlReason = "关闭结果未知，请刷新列表核对；重新打开后可继续。";
                    throw;
                }
                var status = response.String("status");
                if (status == "notSubscribed")
                    throw new ApiException(409, "thread_not_subscribed", "当前连接未订阅此会话，无法直接卸载；若由其他客户端持有，请先在原客户端关闭。");
                if (status is not ("unsubscribed" or "notLoaded"))
                    throw new ApiException(502, "invalid_close_result", "未收到有效的关闭结果，请刷新会话状态后核对。");
                session.Closed = true;
                session.Loaded = false;
                session.CloseRequested = status != "notLoaded" && session.CloseEventVersion == closeVersion;
                if (!session.CloseRequested) session.ActiveTurn = null;
                session.ControlReason = "此会话已关闭或正在等待卸载，重新打开后可继续。";
                var result = Json.Object(("threadId", id), ("state", session.CloseRequested ? "closing" : "closed"));
                _events.Publish("thread/lifecycle/changed", result);
                return result;
            }
            finally { session.Gate.Release(); }
        });
}
