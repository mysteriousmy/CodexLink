class TaskNotice {
  const TaskNotice({
    required this.id,
    required this.threadId,
    required this.failed,
  });
  factory TaskNotice.fromJson(Map<String, dynamic> value) => TaskNotice(
    id: value['id'] as String,
    threadId: value['threadId'] as String,
    failed: value['status'] == 'failed',
  );
  final String id;
  final String threadId;
  final bool failed;
  String get title => failed ? 'Codex 本轮任务失败' : 'Codex 本轮任务已完成';
}

class TaskNotificationSettings {
  const TaskNotificationSettings({
    this.platform = 'unsupported',
    this.permission = 'unavailable',
    this.enabled = false,
    this.batteryExempt = false,
    this.connection = 'stopped',
    this.error,
  });
  factory TaskNotificationSettings.fromJson(Map<String, dynamic> value) =>
      TaskNotificationSettings(
        platform: value['platform'] as String? ?? 'unsupported',
        permission: value['permission'] as String? ?? 'unavailable',
        enabled: value['enabled'] == true,
        batteryExempt: value['batteryExempt'] == true,
        connection: value['connection'] as String? ?? 'stopped',
        error: value['error'] as String?,
      );
  final String platform;
  final String permission;
  final bool enabled;
  final bool batteryExempt;
  final String connection;
  final String? error;
  bool get android => platform == 'android';
  bool get browser => platform == 'browser';
  bool get available => android || browser;
}
