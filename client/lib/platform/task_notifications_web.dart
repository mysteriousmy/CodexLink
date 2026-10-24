import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';

import 'package:web/web.dart' as web;

import '../data/task_notice.dart';
import 'task_notifications_api.dart';

TaskNotificationPlatform createTaskNotificationPlatform() =>
    WebTaskNotifications();

class WebTaskNotifications extends TaskNotificationPlatform {
  web.EventSource? _source;
  Future<web.ServiceWorkerRegistration>? _registration;
  final Map<String, web.Notification> _transient = {};
  int _generation = 0;
  bool _enabled = true;
  bool _disposed = false;
  String _identity = '';
  String _connection = 'stopped';
  final List<({String type, String id, String data})> _queue = [];
  Future<void>? _processing;
  JSFunction? _messageListener;
  static const _key = 'codexlink.task-notifications';
  Map<String, dynamic> _saved = {};

  String get _permission {
    if (!web.window.isSecureContext ||
        !globalContext.hasProperty('Notification'.toJS).toDart) {
      return 'unavailable';
    }
    return web.Notification.permission;
  }

  void _save() {
    try {
      web.window.localStorage.setItem(_key, jsonEncode(_saved));
    } catch (_) {
      /* Private browsing may deny storage; the current tab still works. */
    }
  }

  @override
  Future<TaskNotificationSettings> configure(
    Uri base,
    String? token,
    bool supported,
  ) async {
    if (!supported) {
      _stop();
      return settings();
    }
    if (_source != null) return settings();
    if (_identity.isEmpty) {
      try {
        _saved = jsonDecode(
          web.window.localStorage.getItem(_key) ?? '{}',
        ) as Map<String, dynamic>;
      } catch (_) {
        _saved = {};
      }
      _identity =
          _saved['identity'] as String? ??
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff)}';
      _enabled = _saved['enabled'] != false;
      _saved['identity'] = _identity;
      _save();
      _listenForClicks();
    }
    final generation = ++_generation;
    final url = base.replace(
      path: '/api/notifications/events',
      queryParameters: {
        if (_saved['epoch'] is String) 'epoch': _saved['epoch'] as String,
        if (_saved['cursor'] is int) 'after': '${_saved['cursor']}',
      },
    );
    final source = web.EventSource(
      url.toString(),
      web.EventSourceInit(withCredentials: true),
    );
    _source = source;
    _connection = 'connecting';
    source.onopen = ((web.Event _) {
      if (generation == _generation) _connection = 'connected';
    }).toJS;
    source.onerror = ((web.Event _) {
      if (generation == _generation) _connection = 'reconnecting';
    }).toJS;
    for (final type in ['task', 'question', 'ready']) {
      source.addEventListener(
        type,
        ((web.MessageEvent event) {
          if (generation != _generation) return;
          if (_queue.length >= 512) {
            _stop();
            onWarning?.call('任务提醒积压，请刷新页面以重新同步');
            return;
          }
          _queue.add((
            type: type,
            id: event.lastEventId,
            data: (event.data as JSString).toDart,
          ));
          _startDrain();
        }).toJS,
      );
    }
    return settings();
  }

  void _startDrain() {
    if (_processing != null || _queue.isEmpty || _source == null) return;
    _processing = _drain(_generation).whenComplete(() {
      _processing = null;
      _startDrain();
    });
  }

  Future<void> _drain(int generation) async {
    while (_queue.isNotEmpty && generation == _generation && !_disposed) {
      final frame = _queue.removeAt(0);
      try {
        final data = jsonDecode(frame.data) as Map<String, dynamic>;
        if (frame.type == 'task' || frame.type == 'question') {
          final notice = TaskNotice.fromJson(data);
          final seen = List<String>.from(_saved['seen'] as List? ?? []);
          if (notice.resolved) {
            await _closeNotice(notice, generation);
            if (generation != _generation) return;
            onNotice?.call(notice);
          } else if (!seen.contains(notice.id)) {
            final shown =
                _enabled &&
                _permission == 'granted' &&
                await _show(notice, generation);
            if (generation != _generation) return;
            if (!shown) onNotice?.call(notice);
          }
          if (generation != _generation) return;
          if (!seen.contains(notice.id)) seen.add(notice.id);
          _saved['seen'] = seen.skip(max(0, seen.length - 256)).toList();
        } else if (data['gap'] == true) {
          onWarning?.call('部分任务提醒已过期，请打开会话查看最新状态');
        }
        if (generation != _generation) return;
        final separator = frame.id.lastIndexOf(':');
        if (separator > 0) {
          final cursor = int.tryParse(frame.id.substring(separator + 1));
          if (cursor != null && cursor >= 0) {
            _saved['epoch'] = frame.id.substring(0, separator);
            _saved['cursor'] = cursor;
            _save();
          }
        }
      } catch (_) {
        _stop();
        onWarning?.call('任务通知数据无法读取，请刷新页面重试');
        return;
      }
    }
  }

  Future<void> _closeNotice(TaskNotice notice, int generation) async {
    _transient.remove(notice.key)?.close();
    try {
      final registration = await (_registration ??= _worker());
      final notifications =
          (await registration.getNotifications().toDart).toDart;
      if (generation != _generation) return;
      for (final item in notifications.where(
        (item) => item.tag == 'codexlink:${notice.key}',
      )) {
        item.close();
      }
    } catch (_) {
      _registration = null;
    }
  }

  Future<web.ServiceWorkerRegistration> _worker() async {
    final registration = await web.window.navigator.serviceWorker
        .register(
          '/task-notifications.js'.toJS,
          web.RegistrationOptions(scope: '/notifications/'),
        )
        .toDart;
    if (registration.active != null) return registration;
    final worker = registration.installing ?? registration.waiting;
    if (worker == null) throw StateError('Notification worker unavailable');
    final activated = Completer<void>();
    final listener = ((web.Event _) {
      if (worker.state == 'activated' && !activated.isCompleted) {
        activated.complete();
      }
    }).toJS;
    worker.addEventListener('statechange', listener);
    try {
      if (worker.state == 'activated') activated.complete();
      await activated.future.timeout(const Duration(seconds: 5));
    } finally {
      worker.removeEventListener('statechange', listener);
    }
    return registration;
  }

  Future<bool> _show(TaskNotice notice, int generation) async {
    try {
      final registration = await (_registration ??= _worker());
      if (generation != _generation) return true;
      final existing = (await registration.getNotifications().toDart).toDart
          .where((item) => item.tag != 'codexlink:${notice.key}')
          .toList();
      if (generation != _generation) return true;
      for (final item in existing.take(max(0, existing.length - 19))) {
        item.close();
      }
      await registration
          .showNotification(
            notice.title,
            web.NotificationOptions(
              body: notice.body,
              tag: 'codexlink:${notice.key}',
              icon: '/icons/Icon-192.png',
              data: {'threadId': notice.threadId, 'session': _identity}.jsify(),
            ),
          )
          .toDart;
      return true;
    } catch (_) {
      _registration = null;
      // Desktop browsers without worker support may still support Notification.
      try {
        if (generation != _generation) return true;
        _transient.remove(notice.key)?.close();
        while (_transient.length >= 20) {
          _transient.remove(_transient.keys.first)?.close();
        }
        final notification = web.Notification(
          notice.title,
          web.NotificationOptions(
            body: notice.body,
            tag: 'codexlink:${notice.key}',
          ),
        );
        _transient[notice.key] = notification;
        notification.onclose = ((web.Event _) {
          if (identical(_transient[notice.key], notification)) {
            _transient.remove(notice.key);
          }
        }).toJS;
        notification.onclick = ((web.Event _) {
          notification.close();
          if (generation == _generation) {
            web.window.focus();
            onOpenThread?.call(notice.threadId);
          }
        }).toJS;
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  void _listenForClicks() {
    if (web.window.isSecureContext && _messageListener == null) {
      try {
        _messageListener = ((web.MessageEvent event) {
          final data = event.data.dartify();
          if (data is Map &&
              data['type'] == 'open-task' &&
              data['session'] == _identity &&
              data['threadId'] is String) {
            onOpenThread?.call(data['threadId'] as String);
          }
        }).toJS;
        web.window.navigator.serviceWorker.addEventListener(
          'message',
          _messageListener,
        );
      } catch (_) {
        _messageListener = null;
      }
    }
    final hash = web.window.location.hash;
    if (hash.startsWith('#notice=')) {
      final values = Uri.splitQueryString(hash.substring(1));
      web.window.history.replaceState(
        null,
        '',
        web.window.location.pathname + web.window.location.search,
      );
      if (values['session'] == _identity &&
          values['notice']?.isNotEmpty == true) {
        onOpenThread?.call(values['notice']!);
      }
    }
  }

  @override
  Future<TaskNotificationSettings> settings() async => TaskNotificationSettings(
    platform: 'browser',
    permission: _permission,
    enabled: _enabled,
    connection: _connection,
  );
  @override
  Future<TaskNotificationSettings> enable() async {
    if (_permission == 'default') {
      await web.Notification.requestPermission().toDart;
    }
    _enabled = true;
    _saved['enabled'] = true;
    _save();
    return settings();
  }

  @override
  Future<TaskNotificationSettings> disable() async {
    _enabled = false;
    _saved['enabled'] = false;
    _save();
    return settings();
  }

  @override
  Future<void> backgroundAccess() async {}
  @override
  Future<void> notificationSettings() async {
    onWarning?.call('请在浏览器地址栏的网站权限中允许通知；未授权时仍显示页面气泡');
  }

  void _stop() {
    _generation++;
    _source?.close();
    _source = null;
    _queue.clear();
    _connection = 'stopped';
  }

  @override
  Future<void> clear() async {
    _stop();
    await _processing;
    for (final item in _transient.values.toList()) {
      item.close();
    }
    _transient.clear();
    try {
      final registration = await web.window.navigator.serviceWorker
          .getRegistration('/notifications/')
          .toDart;
      if (registration != null) {
        final notifications = await registration.getNotifications().toDart;
        for (final notification in notifications.toDart) {
          notification.close();
        }
      }
    } catch (_) {
      /* No service worker exists on insecure origins. */
    }
    _saved = {};
    _identity = '';
    _enabled = true;
    try {
      web.window.localStorage.removeItem(_key);
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    if (_messageListener != null) {
      web.window.navigator.serviceWorker.removeEventListener(
        'message',
        _messageListener,
      );
    }
  }
}
