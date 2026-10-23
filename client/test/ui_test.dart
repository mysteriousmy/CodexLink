import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/models.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/ui/conversation_screen.dart';
import 'package:codex_link/ui/composer_commands.dart';
import 'package:codex_link/ui/home_screen.dart';
import 'package:codex_link/ui/usage_panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  app.AppController controller() =>
      app.AppController(
          api: ApiClient(
            client: MockClient((_) async => http.Response('{}', 200)),
          ),
        )
        ..initialized = true
        ..authenticated = true
        ..connection = app.ConnectionState.connected
        ..projects = [
          {'id': 'p', 'name': '我的项目'},
        ]
        ..projectId = 'p';
  testWidgets(
    'missing five hour quota is hidden with weekly quota and unknown today',
    (t) async {
      final c = controller();
      addTearDown(c.dispose);
      c.accountUsage = {
        'today': '2026-10-23',
        'tokens': {
          'summary': {'lifetimeTokens': 1234},
          'dailyUsageBuckets': [],
        },
        'rateLimits': {
          'rateLimits': {
            'secondary': {'windowDurationMins': 10080, 'usedPercent': 20},
          },
        },
      };
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AccountPanel(controller: c)),
        ),
      );
      expect(find.text('5 小时额度'), findsNothing);
      expect(find.text('Weekly · 每周额度'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('1234'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets(
      'conversation fits ${size.width.toInt()}px with larger text and keyboard',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final c = controller();
        addTearDown(c.dispose);
        c.conversation.threadId = 'thread';
        c.conversation.activeTurnId = 'running';
        c.conversation.goal = {
          'objective': '完成一个具体任务',
          'status': 'active',
          'tokensUsed': 1000,
          'tokenBudget': 5000,
        };
        await t.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(1.2),
                viewInsets: const EdgeInsets.only(bottom: 280),
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
        await t.pump();
        expect(t.takeException(), isNull);
        expect(find.byType(TextField), findsOneWidget);
        await t.enterText(find.byType(TextField), '请检查代码');
        await t.pump();
        expect(c.conversation.draft, '请检查代码');
        await t.tap(find.byTooltip('设为 Goal'));await t.pump(const Duration(milliseconds:200));
        expect(t.takeException(),isNull);expect(c.conversation.goalMode,isTrue);
        c.conversation.sending = true;
        c.conversation.notifyListeners();
        await t.pump();
        expect(t.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
        await t.pump(const Duration(milliseconds: 600));
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('desktop sidebar and chat share one screen', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final c = controller();
    c.threads = [
      {
        'id': 'existing',
        'cwd': '/other/project',
        'preview': '已有会话',
        'source': 'cli',
      },
    ];
    c.conversation.threadId = 'existing';
    addTearDown(c.dispose);
    await t.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    await t.pump();
    expect(find.text('CodexLink'), findsOneWidget);
    expect(find.byType(ConversationScreen), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'composer goal toggle submits draft only on send and supports pause',
    (t) async {
      final bodies = <JsonMap>[];
      final api = ApiClient(
        client: MockClient((r) async {
          expect(r.method, 'PUT');
          expect(r.url.path, '/api/threads/t/goal');
          final body = asMap(jsonDecode(r.body));
          bodies.add(body);
          return http.Response(
            jsonEncode({
              'goal': {
                'objective': body['objective'] ?? '目标测试',
                'status': body['status'] ?? 'active',
                'tokenBudget': body['tokenBudget'],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final c = app.AppController(api: api)
        ..initialized = true
        ..authenticated = true
        ..connection = app.ConnectionState.connected;
      c.conversation.threadId = 't';
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationScreen(appController: c, onCreate: () async {}),
          ),
        ),
      );
      await t.enterText(find.byType(TextField), '目标测试');
      await t.tap(find.byTooltip('设为 Goal'));
      await t.pumpAndSettle();
      expect(bodies, isEmpty);
      expect(find.byType(GoalDialog), findsNothing);
      expect(c.conversation.draft, '目标测试');
      expect(find.byTooltip('取消 Goal 模式'), findsOneWidget);
      await t.tap(find.byTooltip('取消 Goal 模式'));
      await t.pumpAndSettle();
      expect(c.conversation.goalMode, isFalse);
      expect(c.conversation.draft, '目标测试');
      expect(bodies, isEmpty);
      await t.tap(find.byTooltip('设为 Goal'));
      await t.pumpAndSettle();
      await t.tap(find.text('发送'));
      await t.pumpAndSettle();
      expect(bodies.first['status'], 'active');
      expect(bodies.first['objective'], '目标测试');
      expect(bodies.first['budgetSpecified'], false);
      expect(c.conversation.draft, isEmpty);
      expect(c.conversation.goalMode, isFalse);
      expect(c.error.value, isNull);
      expect(c.conversation.goal?['status'], 'active');
      await t.tap(find.byTooltip('暂停目标'));
      await t.pumpAndSettle();
      expect(bodies.last['status'], 'paused');
      expect(find.byTooltip('继续目标'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('slash commands open features without submitting prompt text', (
    t,
  ) async {
    final paths = <String>[];
    final api = ApiClient(
      client: MockClient((r) async {
        paths.add('${r.method} ${r.url.path}');
        return http.Response('{"data":[]}', 200);
      }),
    );
    final c = app.AppController(api: api)
      ..initialized = true
      ..authenticated = true
      ..connection = app.ConnectionState.connected;
    c.conversation.threadId = 't';
    addTearDown(c.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Composer(appController: c)),
      ),
    );
    await t.enterText(find.byType(TextField), '/skills');
    await t.pump();
    await t.tap(find.widgetWithText(ListTile, '/skills'));
    await t.pumpAndSettle();
    expect(find.text('选择技能'), findsOneWidget);
    expect(paths, ['GET /api/threads/t/skills']);
    expect(c.conversation.draft, isEmpty);
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '/mcp');
    await t.pump();
    await t.tap(find.widgetWithText(ListTile, '/mcp'));
    await t.pumpAndSettle();
    expect(find.text('MCP 工具与资源'), findsOneWidget);
    expect(paths.last, 'GET /api/threads/t/mcp');
    expect(paths.any((p) => p.startsWith('POST')), isFalse);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('intermediate commentary renders as a separate visible message', (
    t,
  ) async {
    final c = controller();
    addTearDown(c.dispose);
    final item = ConversationItem('p', 'turn', {
      'id': 'p',
      'type': 'agentMessage',
      'phase': 'commentary',
      'text': '我正在检查中途回复。',
    });
    addTearDown(item.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageTile(
            item: item,
            controller: c.conversation,
            onError: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('Codex · 进展'), findsOneWidget);
    expect(find.text('我正在检查中途回复。'), findsOneWidget);
  });
  testWidgets('command palette stays usable on phone with goal and keyboard', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    t.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetViewInsets);
    final c = controller();
    addTearDown(c.dispose);
    c.conversation.threadId = 't';
    c.conversation.goal = {'objective': 'A goal', 'status': 'paused'};
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationScreen(appController: c, onCreate: () async {}),
        ),
      ),
    );
    await t.enterText(find.byType(TextField), '/');
    await t.pump();
    expect(t.takeException(), isNull);
    await t.drag(
      find.descendant(
        of: find.byType(CommandPalette),
        matching: find.byType(ListView),
      ),
      const Offset(0, -220),
    );
    await t.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '/goal'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
