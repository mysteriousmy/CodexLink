import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/task_notice.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/ui/home_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:codex_link/data/task_notification_controller.dart';
import 'package:codex_link/platform/task_notifications_api.dart';
import 'package:codex_link/ui/task_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FixtureNotifications extends TaskNotificationPlatform {
  TaskNotificationSettings value = const TaskNotificationSettings(
    platform: 'android',
    permission: 'denied',
  );
  int enables = 0;
  int clears = 0;
  int batteryRequests = 0;
  Completer<TaskNotificationSettings>? pending;
  @override
  Future<TaskNotificationSettings> configure(
    Uri base,
    String? token,
    bool supported,
  ) async => value;
  @override
  Future<TaskNotificationSettings> settings() async => value;
  @override
  Future<TaskNotificationSettings> enable() async {
    enables++;
    if (pending != null) return pending!.future;
    return value = const TaskNotificationSettings(
      platform: 'android',
      permission: 'granted',
      enabled: true,
      connection: 'connected',
    );
  }

  @override
  Future<TaskNotificationSettings> disable() async =>
      value = const TaskNotificationSettings(
        platform: 'android',
        permission: 'granted',
      );
  @override
  Future<void> backgroundAccess() async {
    batteryRequests++;
  }

  @override
  Future<void> notificationSettings() async {}
  @override
  Future<void> clear() async {
    clears++;
  }

  @override
  void dispose() {}
}

TaskNotice notice(int number, {String? thread}) => TaskNotice(
  id: 'turn-$number',
  threadId: thread ?? 'thread-$number',
  failed: false,
);

void main() {
  testWidgets(
    'system_notification_click_schedules_idle_ui_and_opens_matching_thread',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final platform = FixtureNotifications();
      final notifications = TaskNotificationController(platform: platform);
      final paths = <String>[];
      final controller =
          app.AppController(
              notifications: notifications,
              api: ApiClient(
                client: MockClient((request) async {
                  paths.add(request.url.path);
                  return http.Response(
                    jsonEncode(
                      request.url.path == '/api/threads/notice-target'
                          ? {
                              'thread': {
                                'id': 'notice-target',
                                'preview': 'Notification target',
                              },
                              'canControl': true,
                            }
                          : {'data': []},
                    ),
                    200,
                  );
                }),
              ),
            )
            ..initialized = true
            ..authenticated = true
            ..connection = app.ConnectionState.connected;
      addTearDown(controller.dispose);
      await notifications.configure(
        Uri.parse('https://example.invalid'),
        'fixture',
        true,
      );
      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      platform.onOpenThread?.call('notice-target');
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpAndSettle();
      expect(paths, contains('/api/threads/notice-target'));
      expect(controller.conversation.threadId, 'notice-target');
      expect(notifications.openedThread.value, isNull);
      expect(find.text('Notification target'), findsOneWidget);
    },
  );

  testWidgets('notification_bubbles_deduplicate_replace_and_bound_backlog', (
    tester,
  ) async {
    final c = TaskNotificationController(platform: FixtureNotifications());
    addTearDown(c.dispose);
    c.foreground(false);
    c.receive(notice(1));
    c.receive(notice(1));
    c.receive(notice(2, thread: 'thread-1'));
    expect(c.notices.map((n) => n.id), ['turn-2']);
    for (var i = 3; i < 8; i++) {
      c.receive(notice(i));
    }
    expect(c.notices.map((n) => n.id), ['turn-7', 'turn-6', 'turn-5']);
    await tester.pump(const Duration(minutes: 2));
    expect(c.notices, hasLength(3));
    c.foreground(true);
    await tester.pump(const Duration(seconds: 9));
    expect(c.notices, hasLength(3));
    await tester.pump(const Duration(seconds: 1));
    expect(c.notices, isEmpty);
  });

  testWidgets(
    'notification_bubble_opens_exact_thread_and_dismisses_without_opening',
    (tester) async {
      final c = TaskNotificationController(platform: FixtureNotifications());
      addTearDown(c.dispose);
      c.receive(notice(1));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: 320,
                child: TaskNotificationToasts(controller: c),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Codex 本轮任务已完成'));
      expect(c.openedThread.value, 'thread-1');
      expect(c.notices, isEmpty);
      c.openedThread.value = null;
      c.receive(notice(2));
      await tester.pump();
      await tester.tap(find.byTooltip('关闭任务提醒'));
      expect(c.openedThread.value, isNull);
      expect(c.notices, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'notification_settings_request_permissions_only_after_user_action',
    (tester) async {
      final platform = FixtureNotifications();
      final c = TaskNotificationController(platform: platform);
      addTearDown(c.dispose);
      await c.configure(Uri.parse('https://example.invalid'), 'fixture', true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTaskNotificationSettings(context, c),
                child: const Text('设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(platform.enables, 0);
      expect(find.text('后台通知未开启'), findsOneWidget);
      await tester.tap(find.text('开启系统通知'));
      await tester.pumpAndSettle();
      expect(platform.enables, 1);
      expect(find.text('提醒连接正常'), findsOneWidget);
      await tester.tap(find.text('允许锁屏后台运行'));
      await tester.pump();
      expect(platform.batteryRequests, 1);
      await tester.tap(find.text('关闭后台通知'));
      await tester.pump();
      expect(c.settings.enabled, isFalse);
    },
  );

  testWidgets(
    'notification_old_server_explains_upgrade_without_enable_action',
    (tester) async {
      final platform = FixtureNotifications();
      final c = TaskNotificationController(platform: platform);
      addTearDown(c.dispose);
      await c.configure(Uri.parse('https://example.invalid'), 'fixture', false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTaskNotificationSettings(context, c),
                child: const Text('设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('电脑服务需升级后才能开启任务通知。'), findsOneWidget);
      expect(find.text('开启系统通知'), findsNothing);
      expect(platform.enables, 0);
    },
  );

  testWidgets(
    'notification_logout_clears_pending_clicks_and_ignores_late_permission_result',
    (tester) async {
      final platform = FixtureNotifications()..pending = Completer();
      final c = TaskNotificationController(platform: platform);
      addTearDown(c.dispose);
      await c.configure(Uri.parse('https://example.invalid'), 'fixture', true);
      final enabling = c.enable();
      c.receive(notice(1));
      platform.onOpenThread?.call('thread-1');
      await c.clear();
      platform.pending!.complete(
        const TaskNotificationSettings(
          platform: 'android',
          permission: 'granted',
          enabled: true,
        ),
      );
      await enabling;
      platform.onOpenThread?.call('late-thread');
      expect(c.notices, isEmpty);
      expect(c.openedThread.value, isNull);
      expect(c.settings.enabled, isFalse);
      expect(platform.clears, 1);
      await tester.pump(const Duration(seconds: 12));
      expect(tester.takeException(), isNull);
    },
  );
}
