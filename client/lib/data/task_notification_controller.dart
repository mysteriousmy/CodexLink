import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/task_notifications.dart';
import 'task_notice.dart';

class TaskNotificationController extends ChangeNotifier {
  TaskNotificationController({TaskNotificationPlatform? platform})
    : platform = platform ?? createTaskNotificationPlatform() {
    this.platform.onNotice = (notice) {
      if (_active && !_disposed) receive(notice);
    };
    this.platform.onOpenThread = (thread) {
      if (_active && !_disposed) openedThread.value = thread;
    };
    this.platform.onWarning = (message) {
      if (_active && !_disposed) {
        warning = message;
        _notify();
      }
    };
  }
  final TaskNotificationPlatform platform;
  final openedThread = ValueNotifier<String?>(null);
  TaskNotificationSettings settings = const TaskNotificationSettings();
  bool serverSupported = false;
  bool busy = false;
  bool _foreground = true;
  bool _disposed = false;
  bool _active = false;
  int _generation = 0;
  String? warning;
  final _seen = <String>{};
  final List<TaskNotice> _notices = [];
  final Map<String, Timer> _timers = {};
  List<TaskNotice> get notices => List.unmodifiable(_notices);

  Future<void> configure(Uri base, String? token, bool supported) async {
    serverSupported = supported;
    _active = supported;
    final generation = _generation;
    try {
      final value = await platform.configure(base, token, supported);
      if (generation == _generation && !_disposed) settings = value;
    } catch (_) {
      if (generation == _generation) warning = '通知连接暂不可用，请打开任务通知设置重试';
    }
    _notify();
  }

  void receive(TaskNotice notice) {
    if (_disposed || !_seen.add(notice.id)) return;
    while (_seen.length > 256) {
      _seen.remove(_seen.first);
    }
    _notices.removeWhere((item) => item.threadId == notice.threadId);
    _notices.insert(0, notice);
    while (_notices.length > 3) {
      _notices.removeLast();
    }
    // Pending background bubbles get their full display duration on return.
    _schedule();
    _notify();
  }

  void dismissWarning() {
    warning = null;
    _notify();
  }

  void dismiss(String id) {
    _notices.removeWhere((notice) => notice.id == id);
    _timers.remove(id)?.cancel();
    _notify();
  }

  void open(TaskNotice notice) {
    dismiss(notice.id);
    openedThread.value = notice.threadId;
  }

  void foreground(bool value) {
    _foreground = value;
    _schedule();
    if (value) unawaited(refresh());
  }

  void _schedule() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    if (!_foreground) return;
    for (final notice in _notices) {
      _timers[notice.id] = Timer(
        const Duration(seconds: 10),
        () => dismiss(notice.id),
      );
    }
  }

  Future<void> refresh() => _action(platform.settings);
  Future<void> enable() => _action(platform.enable);
  Future<void> disable() => _action(platform.disable);
  Future<void> _action(
    Future<TaskNotificationSettings> Function() action,
  ) async {
    if (busy || _disposed) return;
    final generation = _generation;
    busy = true;
    warning = null;
    _notify();
    try {
      final result = await action();
      if (generation == _generation && !_disposed) settings = result;
    } catch (_) {
      if (generation == _generation) warning = '通知设置未能完成，请重试或检查系统设置';
    } finally {
      if (generation == _generation) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> backgroundAccess() async {
    try {
      await platform.backgroundAccess();
    } catch (_) {
      warning = '无法打开后台运行设置，请在系统设置中允许 CodexLink 后台运行';
      _notify();
    }
  }

  Future<void> notificationSettings() async {
    try {
      await platform.notificationSettings();
    } catch (_) {
      warning = '无法打开系统通知设置，请手动检查浏览器或系统权限';
      _notify();
    }
  }

  Future<void> clear() async {
    _generation++;
    _active = false;
    busy = false;
    _notices.clear();
    _seen.clear();
    openedThread.value = null;
    warning = null;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    await platform.clear();
    settings = const TaskNotificationSettings();
    serverSupported = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    platform.onNotice = null;
    platform.onOpenThread = null;
    platform.onWarning = null;
    platform.dispose();
    openedThread.dispose();
    super.dispose();
  }
}
