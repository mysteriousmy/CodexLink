import '../data/task_notice.dart';

/// The Android service outlives Flutter; browsers use their same-origin session.
abstract class TaskNotificationPlatform {
  void Function(TaskNotice)? onNotice;
  void Function(String)? onOpenThread;
  void Function(String)? onWarning;
  Future<TaskNotificationSettings> configure(
    Uri base,
    String? token,
    bool supported,
  );
  Future<TaskNotificationSettings> settings();
  Future<TaskNotificationSettings> enable();
  Future<TaskNotificationSettings> disable();
  Future<void> backgroundAccess();
  Future<void> notificationSettings();
  Future<void> clear();
  void dispose();
}
