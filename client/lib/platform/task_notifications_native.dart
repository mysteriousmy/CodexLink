import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/task_notice.dart';
import 'task_notifications_api.dart';

TaskNotificationPlatform createTaskNotificationPlatform() =>
    NativeTaskNotifications();

class NativeTaskNotifications extends TaskNotificationPlatform {
  static const _channel = MethodChannel('codexlink/task_notifications');
  bool _hasPlugin = true;
  bool get _available =>
      _hasPlugin && defaultTargetPlatform == TargetPlatform.android;
  bool _listening = false;
  void _listen() {
    if (_available && !_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'openThread') {
          // Consume the native pending item too, so resume cannot open it twice.
          final thread = await _channel.invokeMethod<String>(
            'takePendingThread',
          );
          if (thread != null) onOpenThread?.call(thread);
        }
      });
    }
  }

  Future<TaskNotificationSettings> _read(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    if (!_available) return const TaskNotificationSettings();
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>(
        method,
        args,
      );
      return TaskNotificationSettings.fromJson(value ?? {});
    } on MissingPluginException {
      _hasPlugin = false;
      return const TaskNotificationSettings();
    }
  }

  @override
  Future<TaskNotificationSettings> configure(
    Uri base,
    String? token,
    bool supported,
  ) async {
    _listen();
    final result = await _read('configure', {
      'origin': base.origin,
      'token': token,
      'supported': supported,
    });
    if (_available) {
      final pending = await _channel.invokeMethod<String>('takePendingThread');
      if (pending != null) onOpenThread?.call(pending);
    }
    return result;
  }

  @override
  Future<TaskNotificationSettings> settings() => _read('status');
  @override
  Future<TaskNotificationSettings> enable() => _read('enable');
  @override
  Future<TaskNotificationSettings> disable() => _read('disable');
  @override
  Future<void> backgroundAccess() async {
    if (_available) await _channel.invokeMethod<void>('batterySettings');
  }

  @override
  Future<void> notificationSettings() async {
    if (_available) await _channel.invokeMethod<void>('notificationSettings');
  }

  @override
  Future<void> clear() async {
    if (_available) {
      try {
        await _channel.invokeMethod<void>('clear');
      } on MissingPluginException {
        _hasPlugin = false;
      }
    }
  }

  @override
  void dispose() {
    if (_listening) {
      _channel.setMethodCallHandler(null);
    }
  }
}
