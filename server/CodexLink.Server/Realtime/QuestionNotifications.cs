using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexLink.Server.Realtime;

public sealed partial class TaskNotifications
{
    private static string QuestionNoticeId(string thread, string question, string status) =>
        "q:" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(thread + "\n" + question))) + ":" + status;

    private static bool ValidNotice(TaskNotice n) => n.QuestionId is null
        ? n.Id == n.ThreadId + ":" + n.TurnId && n.Status is "completed" or "failed" && n.Preview is null
        : n.QuestionId.Length is > 0 and <= 1024 && n.Status is "question" or "resolved" &&
          n.Id == QuestionNoticeId(n.ThreadId, n.QuestionId, n.Status) && (n.Preview?.Length ?? 0) <= 240;

    private void AddNotice(TaskNotice notice)
    {
        foreach (var expired in _history.Where(n => DateTimeOffset.UtcNow - n.CompletedAt > Retention).ToArray())
        {
            _discardedThrough = Math.Max(_discardedThrough, expired.Sequence);
            _history.Remove(expired);
        }
        _history.Add(notice);
        if (_history.Count > Capacity)
        {
            var count = _history.Count - Capacity;
            _discardedThrough = Math.Max(_discardedThrough, _history[count - 1].Sequence);
            _history.RemoveRange(0, count);
        }
        var changed = _changed;
        _changed = NewSignal();
        changed.TrySetResult();
        _dirty.Writer.TryWrite(true);
    }

    private void Question(string? thread, string? turn, string question, string preview)
    {
        if (string.IsNullOrEmpty(thread) || string.IsNullOrEmpty(turn) || thread.Length > 256 || turn.Length > 256 || question.Length > 1024) return;
        if (_history.Any(n => n.ThreadId == thread && n.QuestionId == question)) return;
        preview = string.Join(' ', preview.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (preview.Length > 240) preview = preview[..(char.IsHighSurrogate(preview[238]) ? 238 : 239)] + "…";
        if (preview.Length == 0) preview = "Codex 有一个问题，请打开会话回答。";
        AddNotice(new(++_sequence, QuestionNoticeId(thread, question, "question"), thread, turn, "question", DateTimeOffset.UtcNow, question, preview));
    }

    private void ResolveQuestions(Func<TaskNotice, bool> matches)
    {
        foreach (var notice in _history.Where(n => n.Status == "question" && matches(n)).ToArray())
        {
            // Replace the earlier alert so reconnect replay cannot briefly
            // re-alert a question that has already been answered elsewhere.
            _history.Remove(notice);
            AddNotice(notice with { Sequence = ++_sequence, Id = QuestionNoticeId(notice.ThreadId, notice.QuestionId!, "resolved"), Status = "resolved", Preview = null, CompletedAt = DateTimeOffset.UtcNow });
        }
    }

    private void CaptureQuestions(string method, JsonNode? parameters)
    {
        var thread = parameters.String("threadId");
        if (method == "approval/requested" && parameters.String("method") == "item/tool/requestUserInput")
        {
            var p = parameters?["params"];
            if (p?["questions"] is not JsonArray questions) return;
            var preview = string.Join("；", questions.Take(16).Select(q => q?["isSecret"]?.GetValue<bool>() == true ? "有一项私密问题，请在会话中查看" : q.String("question") ?? ""));
            Question(p.String("threadId"), p.String("turnId"), "native:" + parameters.String("id"), preview);
        }
        else if (method == "approval/resolved") ResolveQuestions(n => n.QuestionId == "native:" + parameters.String("id"));
        else if (method == "runtime/stopped") ResolveQuestions(n => n.QuestionId!.StartsWith("native:", StringComparison.Ordinal));
        else if (method == "thread/archived") ResolveQuestions(n => n.ThreadId == thread);
        else if (method is "item/started" or "item/completed")
        {
            var item = parameters?["item"];
            if (method == "item/completed" && item.String("type") == "agentMessage" && item?["questions"] is JsonArray questions && item.String("id") is { Length: > 0 and <= 256 } itemId)
            {
                for (var index = 0; index < Math.Min(16, questions.Count); index++)
                {
                    var questionId = Json.Compact(new JsonArray("request_user_input_async", itemId, index));
                    Question(thread, parameters.String("turnId"), questionId,
                        questions[index]?["isSecret"]?.GetValue<bool>() == true ? "有一项私密问题，请在会话中查看" : questions[index].String("title") ?? "");
                }
            }
            else if (item.String("type") == "userMessage") ResolveAsyncReplies(thread, item?["content"] as JsonArray);
        }
    }

    private void ResolveAsyncReplies(string? thread, JsonArray? content)
    {
        var parts = content?.Where(p => p.String("type") is not ("skill" or "mention")).ToArray();
        if (parts is not { Length: 1 } || parts[0].String("type") != "text") return;
        var text = (parts[0].String("text") ?? "").Trim();
        if (text.StartsWith("# Context from my IDE setup:\n", StringComparison.Ordinal))
            text = text.Split("\n## My request for Codex:\n").Last().Trim();
        const string open = "<send_user_message_question_reply>", close = "</send_user_message_question_reply>";
        if (!text.StartsWith(open, StringComparison.Ordinal) || !text.EndsWith(close, StringComparison.Ordinal)) return;
        try
        {
            var decoded = JsonNode.Parse(text[open.Length..^close.Length]);
            var replies = decoded is JsonArray array ? array.ToArray() : [decoded];
            if (replies.Any(r => r?["questionItemId"] is not JsonValue q || !q.TryGetValue<string>(out _) ||
                r?["question"] is not JsonValue t || !t.TryGetValue<string>(out _) || r?["answer"] is not JsonValue a || !a.TryGetValue<string>(out _))) return;
            foreach (var reply in replies)
            {
                var id = reply.String("questionItemId");
                ResolveQuestions(n => n.ThreadId == thread && !n.QuestionId!.StartsWith("native:", StringComparison.Ordinal) && AsyncMatches(n.QuestionId, id));
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { }
    }

    private static bool AsyncMatches(string question, string? answered)
    {
        var id = JsonNode.Parse(question) as JsonArray;
        if (id?[1]?.GetValue<string>() == answered) return true; // Older clients answered a complete question group.
        try { return JsonNode.DeepEquals(id, JsonNode.Parse(answered ?? "")); }
        catch (JsonException) { return false; }
    }
}
