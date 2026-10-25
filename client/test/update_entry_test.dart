import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/data/release_info.dart';
import 'package:codex_link/data/update_controller.dart';
import 'package:codex_link/data/task_notification_controller.dart';
import 'package:codex_link/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_lifecycle_test.dart' show FixtureApi;
import 'task_notifications_test.dart' show FixtureNotifications;
import 'updates_test.dart' show json, releaseJson;

class LoginApi extends FixtureApi {
  LoginApi(super.handler);
  @override
  Future<void> login(String secret) async {
    token = secret;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('auto_notice_and_manual_menu_check', (t) async {
    var releaseCalls = 0;
    var now = DateTime.utc(2026, 10, 25);
    final api = LoginApi(
      (r) async => switch (r.url.path) {
        '/api/status' => json({'gateway': 'ready', 'codex': 'ready'}),
        '/api/version' => json({
          'version': '0.1.9',
          'packageTarget': 'linux-x64',
        }),
        _ => json({'data': []}),
      },
    );
    final updates = UpdateController(
      api: api,
      releaseClient: MockClient((_) async {
        releaseCalls++;
        return json(releaseJson());
      }),
      installation: () async => const ClientInstallation(
        version: '0.1.8',
        platform: 'android',
        abis: ['arm64-v8a'],
      ),
      clock: () => now,
    );
    final c = app.AppController(
      api: api,
      updates: updates,
      notifications: TaskNotificationController(
        platform: FixtureNotifications(),
      ),
    )..initialized = true;
    addTearDown(c.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: c,
          builder: (_, _) => HomeScreen(controller: c),
        ),
      ),
    );
    await updates.setAutomatic(true);
    await c.login(api.base.origin, 'fixture-key');
    await updates.check();
    api.sockets.last.event('stream/ready');
    await t.pumpAndSettle();
    expect(releaseCalls, 1);
    expect(find.text('App、服务端有新版本 v0.2.0'), findsOneWidget);
    await t.tap(find.byTooltip('更多会话操作'));
    await t.pumpAndSettle();
    await t.tap(find.text('检查更新 · 有新版本'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('当前版本：0.1.8'), findsOneWidget);
    expect(find.text('当前版本：0.1.9'), findsOneWidget);
    expect(releaseCalls, 2);
    await t.tap(find.text('关闭'));
    await t.pumpAndSettle();
    c.background();
    now = now.add(const Duration(hours: 5));
    await c.foreground();
    await t.pumpAndSettle();
    expect(releaseCalls, 2);
    c.background();
    now = now.add(const Duration(hours: 1));
    await c.foreground();
    await t.pumpAndSettle();
    expect(releaseCalls, 3);
    c.background();
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('desktop_and_disconnected_clients_can_check_manually', (t) async {
    final api = ApiClient(
      client: MockClient(
        (_) async =>
            json({'version': '0.2.0', 'packageTarget': 'windows-arm64'}),
      ),
    );
    var calls = 0;
    final updates = UpdateController(
      api: api,
      releaseClient: MockClient((_) async {
        calls++;
        return json(releaseJson());
      }),
      installation: () async =>
          const ClientInstallation(version: '0.2.0', platform: 'web'),
    );
    final c = app.AppController(
      api: api,
      updates: updates,
      notifications: TaskNotificationController(
        platform: FixtureNotifications(),
      ),
    )..initialized = true;
    addTearDown(c.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: c,
          builder: (_, _) => HomeScreen(controller: c),
        ),
      ),
    );
    await t.ensureVisible(find.text('检查更新'));
    await t.tap(find.text('检查更新'));
    await t.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('已是最新版本'), findsNWidgets(2));
    expect(find.text('下载 App'), findsNothing);
    expect(find.text('下载服务端'), findsNothing);
    await t.tap(find.text('关闭'));
    await t.pumpAndSettle();
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    c.authenticated = true;
    c.connection = app.ConnectionState.connected;
    await t.pumpWidget(
      MaterialApp(
        home: HomeScreen(key: const ValueKey('desktop'), controller: c),
      ),
    );
    await t.tap(find.byTooltip('检查更新'));
    await t.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
