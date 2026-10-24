import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/data/conversation_controller.dart';
import 'package:codex_link/ui/conversation_screen.dart';
import 'package:codex_link/ui/permission_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'permission_picker_applies_confirmed_mode_and_hides_disallowed_actions',
    (t) async {
      final writes = <String>[];
      final reply = Completer<http.Response>();
      final c =
          ConversationController(
              ApiClient(
                client: MockClient((r) async {
                  if (r.method == 'PUT') {
                    writes.add(r.body);
                    return reply.future;
                  }
                  return json({
                    'current': {'preset': 'default', 'label': '默认'},
                    'options': [
                      for (final (id, name) in [
                        ('read-only', '只读'),
                        ('default', '默认'),
                        ('auto-review', '自动审查'),
                        ('full-access', '完全访问'),
                      ])
                        {
                          'id': id,
                          'label': name,
                          'description': '$name 权限说明',
                          'allowed': id != 'full-access',
                          'reason': '管理策略限制',
                        },
                    ],
                  });
                }),
              ),
              onError: (e) => fail('$e'),
              onTurnFinished: () {},
            )
            ..threadId = 't'
            ..permissions = {'preset': 'default', 'label': '默认'}
            ..draft = 'next task';
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) =>
                  PermissionPicker(controller: c, onError: (e) => fail('$e')),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('permission-picker')));
      await t.pumpAndSettle();
      expect(find.text('会话权限'), findsOneWidget);
      expect(find.text('只读'), findsOneWidget);
      expect(find.text('完全访问'), findsOneWidget);
      expect(
        t.widget<ListTile>(find.widgetWithText(ListTile, '完全访问')).enabled,
        isFalse,
      );
      await t.tap(find.text('自动审查'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 250));
      expect(writes.map(jsonDecode), [
        {'preset': 'auto-review'},
      ]);
      expect(c.permissionLabel, '默认');
      expect(c.canSend, isFalse);
      reply.complete(json({'preset': 'auto-review', 'label': '自动审查'}));
      await t.pumpAndSettle();
      expect(c.permissionLabel, '自动审查');
      expect(find.text('自动审查'), findsOneWidget);
      expect(c.canSend, isTrue);
    },
  );

  test(
    'permission_events_preserve_custom_modes_and_reject_running_task_changes',
    () async {
      final calls = <String>[];
      final c = ConversationController(
        ApiClient(
          client: MockClient((r) async {
            calls.add(r.method);
            return json({});
          }),
        ),
        onError: (_) {},
        onTurnFinished: () {},
      )..threadId = 't';
      addTearDown(c.dispose);
      c.handleEvent('thread/settings/updated', {
        'threadId': 'other',
        'permissions': {'label': '错误会话'},
      });
      expect(c.permissionLabel, '权限未知');
      c.handleEvent('thread/settings/updated', {
        'threadId': 't',
        'permissions': {'label': '自定义权限', 'preset': null},
      });
      expect(c.permissionLabel, '自定义权限');
      c.activeTurnId = 'active';
      expect(c.canChangePermissions, isFalse);
      await expectLater(
        c.setPermissionPreset('full-access', 't'),
        throwsA(isA<ApiError>()),
      );
      c.activeTurnId = null;
      c.goal = {'status': 'active'};
      expect(c.canChangePermissions, isFalse);
      c.goal = {'status': 'paused'};
      expect(c.canChangePermissions, isTrue);
      await expectLater(
        c.setPermissionPreset('default', 'old-thread'),
        throwsA(isA<ApiError>()),
      );
      expect(calls, isEmpty);
      c.runtimeStopped();
      expect(c.permissionLabel, '权限未知');
    },
  );

  test('new_permission_events_win_over_older_http_responses', () async {
    final read = Completer<http.Response>();
    final update = Completer<http.Response>();
    final c = ConversationController(
      ApiClient(
        client: MockClient(
          (r) => r.method == 'GET' ? read.future : update.future,
        ),
      ),
      onError: (_) {},
      onTurnFinished: () {},
    )..threadId = 't';
    addTearDown(c.dispose);
    final loading = c.loadPermissionOptions();
    c.handleEvent('thread/settings/updated', {
      'threadId': 't',
      'permissions': {'preset': 'auto-review', 'label': '自动审查'},
    });
    read.complete(
      json({
        'current': {'preset': 'default', 'label': '默认'},
        'options': [],
      }),
    );
    await loading;
    expect(c.permissionLabel, '自动审查');
    final changing = c.setPermissionPreset('full-access', 't');
    c.handleEvent('thread/settings/updated', {
      'threadId': 't',
      'permissions': {'preset': 'full-access', 'label': '完全访问'},
    });
    c.handleEvent('thread/settings/updated', {
      'threadId': 't',
      'permissions': {'preset': 'read-only', 'label': '只读'},
    });
    update.complete(json({'preset': 'full-access', 'label': '完全访问'}));
    await changing;
    expect(c.permissionLabel, '只读');
    expect(c.permissionsBusy, isFalse);
  });

  testWidgets(
    'mobile_composer_keeps_permissions_and_actions_visible_without_overflow',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final c =
          app.AppController(
              api: ApiClient(client: MockClient((_) async => json({}))),
            )
            ..initialized = true
            ..authenticated = true
            ..connection = app.ConnectionState.connected;
      addTearDown(c.dispose);
      c.conversation.threadId = 't';
      c.conversation.thread = {'id': 't', 'preview': '权限测试'};
      c.conversation.permissions = {'preset': 'auto-review', 'label': '自动审查'};
      for (final width in [320.0, 390.0, 1100.0]) {
        t.view.physicalSize = Size(width, 750);
        await t.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 750),
                textScaler: TextScaler.linear(1.3),
              ),
              child: Scaffold(
                body: ConversationScreen(
                  appController: c,
                  onCreate: () async {},
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('permission-picker')).hitTestable(),
          findsOneWidget,
        );
        expect(find.byTooltip('添加文件').hitTestable(), findsOneWidget);
        expect(find.text('发送').hitTestable(), findsOneWidget);
        expect(t.takeException(), isNull);
      }
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
}
