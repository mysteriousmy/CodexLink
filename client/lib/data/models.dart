import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'file_diff.dart';

class ConversationItem extends ChangeNotifier {
  ConversationItem(
    this.id,
    this.turnId,
    JsonMap value, {
    this.streaming = false,
  }) : data = Map.of(value);
  final String id;
  final String turnId;
  JsonMap data;
  final Map<String, StringBuffer> _pending = {};
  bool streaming;
  List<FileDiff>? _diffs;
  List<FileDiff> get fileDiffs =>
      _diffs ??= type == 'turnDiff' && data['diff'] is String
      ? parseUnifiedDiff(data['diff'] as String)
      : combineFileChanges(asMaps(data['changes']));
  String get type => data['type'] as String? ?? 'unknown';
  String get text => data['text'] as String? ?? '';
  void replace(JsonMap value, {required bool isStreaming}) {
    _pending.clear();
    _diffs = null;
    data = Map.of(value);
    streaming = isStreaming;
    notifyListeners();
  }

  void append(String field, String delta) {
    _pending.putIfAbsent(field, StringBuffer.new).write(delta);
  }

  int fieldLength(String field) =>
      (data[field] as String? ?? '').length + (_pending[field]?.length ?? 0);
  void flush() {
    for (final entry in _pending.entries) {
      data[entry.key] = '${data[entry.key] ?? ''}${entry.value}';
    }
    _pending.clear();
    notifyListeners();
  }
}

class TokenUsage {
  const TokenUsage(
    this.total,
    this.last,
    this.window,
    this.input,
    this.output,
    this.cached,
    this.reasoning,
  );
  factory TokenUsage.fromJson(JsonMap value) {
    final total = asMap(value['total']);
    final last = asMap(value['last']);
    return TokenUsage(
      (total['totalTokens'] as num?)?.toInt(),
      (last['totalTokens'] as num?)?.toInt(),
      (value['modelContextWindow'] as num?)?.toInt(),
      (total['inputTokens'] as num?)?.toInt(),
      (total['outputTokens'] as num?)?.toInt(),
      (total['cachedInputTokens'] as num?)?.toInt(),
      (total['reasoningOutputTokens'] as num?)?.toInt(),
    );
  }
  final int? total, last, window, input, output, cached, reasoning;
  double? get fraction =>
      last != null && last! >= 0 && window != null && window! > 0
      ? (last! / window!).clamp(0, 1).toDouble()
      : null;
}

String compactNumber(num? value) {
  if (value == null) return '—';
  if (value >= 1000000000) return '${(value / 1000000000).toStringAsFixed(1)}B';
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
  return value.toString();
}

String goalStatus(String? value) => switch (value) {
  'active' => '进行中',
  'paused' => '已暂停',
  'blocked' => '等待处理',
  'usageLimited' => '额度受限',
  'budgetLimited' => '预算已用完',
  'complete' => '已完成',
  _ => '未知状态',
};

String threadTitle(JsonMap thread) {
  final name = (thread['name'] as String?)?.trim();
  if (name != null && name.isNotEmpty) return name;
  final raw = (thread['preview'] as String? ?? '').trim();
  final text = raw
      .split(RegExp(r'用户为本条消息上传了以下附件|<codexlink_attachments>'))
      .first
      .trim();
  return text.isNotEmpty
      ? text
      : raw.isNotEmpty
      ? '附件消息'
      : '新会话';
}

String threadLocation(JsonMap thread) {
  final path = (thread['cwd'] as String? ?? '').replaceAll('\\', '/');
  final parts = path.split('/').where((p) => p.isNotEmpty);
  return parts.isEmpty ? '本机' : parts.last;
}

String threadSourceLabel(JsonMap thread) {
  final source = thread['source'];
  if (source is Map) return '子任务';
  return switch (source) {
    'cli' => 'CLI',
    'vscode' => 'VS Code',
    'exec' => 'Exec',
    'appServer' => 'App',
    _ => 'Codex',
  };
}
