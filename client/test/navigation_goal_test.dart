import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/ui/conversation_screen.dart';
import 'package:codex_link/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  http.Response response(Object value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  app.AppController ready(ApiClient api) => app.AppController(api: api)
    ..initialized = true
    ..authenticated = true
    ..connection = app.ConnectionState.connected;

  testWidgets('mobile_sidebar_prioritizes_threads', (t) async {
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final c = ready(ApiClient(client: MockClient((_) async => response({}))));
    addTearDown(c.dispose);
    c.threads = List.generate(
      30,
      (i) => {
        'id': 'thread-$i',
        'preview': '会话 $i',
        'cwd': '/workspace/project',
        'updatedAt': 1792756800,
      },
    );
    c.projects = [
      {'id': 'p', 'name': '测试项目'},
    ];
    for (final size in [const Size(390, 690), const Size(320, 568)]) {
      t.view.physicalSize = size;
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(1.2),
            ),
            child: HomeScreen(controller: c),
          ),
        ),
      );
      await t.pumpAndSettle();
      final list = find.byKey(const ValueKey('thread-list'));
      expect(t.getSize(list).height / size.height, greaterThan(.70));
      expect(find.text('会话 4').hitTestable(), findsOneWidget);
      expect(find.text('今日 Token'), findsNothing);
      expect(find.byTooltip('新建会话').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
    }
    await t.tap(find.byTooltip('会话范围：全部本机会话'));
    await t.pumpAndSettle();
    expect(
      find.widgetWithText(CheckedPopupMenuItem<String>, '测试项目').hitTestable(),
      findsOneWidget,
    );
    await t.tapAt(const Offset(5, 400));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('更多会话操作'));
    await t.pumpAndSettle();
    expect(find.text('新建 Goal').hitTestable(), findsOneWidget);
    expect(find.text('查看已归档会话').hitTestable(), findsOneWidget);
    expect(find.text('刷新会话').hitTestable(), findsOneWidget);
    await t.tapAt(const Offset(5, 450));
    await t.pumpAndSettle();
    await t.tap(find.text('账号与用量'));
    await t.pumpAndSettle();
    expect(find.text('账号用量'), findsOneWidget);
    expect(find.text('今日 Token'), findsOneWidget);
    expect(t.takeException(), isNull);
    // Search remains usable when browser chrome and keyboard reduce the height.
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 690),
            viewInsets: EdgeInsets.only(bottom: 280),
          ),
          child: HomeScreen(controller: c),
        ),
      ),
    );
    await t.enterText(find.byType(TextField), '会话');
    await t.pump();
    expect(
      t.getSize(find.byKey(const ValueKey('thread-list'))).height,
      greaterThan(100),
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('system_back_returns_to_list_and_preserves_draft', (t) async {
    t.view.physicalSize = const Size(390, 690);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final calls = <http.Request>[];
    final c = ready(
      ApiClient(
        client: MockClient((r) async {
          calls.add(r);
          if (r.url.path.endsWith('/items')) return response({'data': []});
          if (r.url.path.endsWith('/goal')) return response({'goal': null});
          return response({
            'thread': {'id': 't', 'preview': '返回键测试'},
          });
        }),
      ),
    );
    addTearDown(c.dispose);
    c.threads = [
      {'id': 't', 'preview': '返回键测试'},
    ];
    await t.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    await t.tap(find.text('返回键测试'));
    await t.pumpAndSettle();
    expect(find.byType(Composer), findsOneWidget);
    await t.enterText(
      find.descendant(
        of: find.byType(Composer),
        matching: find.byType(TextField),
      ),
      '未发送的草稿',
    );
    await t.pump();
    // The same navigation signal used by Android's system back dispatcher.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byType(Composer), findsNothing);
    expect(find.byKey(const ValueKey('thread-list')), findsOneWidget);
    expect(c.conversation.threadId, 't');
    expect(c.conversation.draft, '未发送的草稿');
    expect(calls.every((r) => r.method == 'GET'), isTrue);
    expect(
      t.widget<PopScope>(find.byWidgetPredicate((w) => w is PopScope)).canPop,
      isTrue,
    );
    await t.tap(find.text('返回键测试'));
    await t.pumpAndSettle();
    expect(
      t
          .widget<TextField>(
            find.descendant(
              of: find.byType(Composer),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      '未发送的草稿',
    );
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'completed goal is hidden and active goal has compact icon controls',
    (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final calls = <http.Request>[];
      final text = '完整目标内容 ${'需要在详情中阅读。' * 30}';
      final c = ready(
        ApiClient(
          client: MockClient((r) async {
            calls.add(r);
            return response(
              r.method == 'DELETE'
                  ? {}
                  : {
                      'goal': {
                        'objective': text,
                        'status': asMap(jsonDecode(r.body))['status'],
                      },
                    },
            );
          }),
        ),
      );
      addTearDown(c.dispose);
      c.conversation.threadId = 't';
      c.conversation.goal = {'objective': text, 'status': 'complete'};
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationScreen(appController: c, onCreate: () async {}),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('active-goal-bar')), findsNothing);
      expect(find.text(text), findsNothing);
      expect(find.byTooltip('查看 Goal'), findsNothing);
      expect(find.byTooltip('设置 Goal'), findsNothing);
      c.conversation.goal = {'objective': text, 'status': 'active'};
      c.conversation.notifyListeners();
      await t.pumpAndSettle();
      final bar = find.byKey(const ValueKey('active-goal-bar'));
      expect(t.getSize(bar).height, lessThan(76));
      expect(
        t.getBottomLeft(bar).dy,
        lessThan(t.getTopLeft(find.byType(Composer)).dy + 1),
      );
      expect(find.text('暂停目标'), findsNothing);
      expect(find.byTooltip('暂停目标'), findsOneWidget);
      await t.tap(find.text(text));
      await t.pumpAndSettle();
      expect(find.widgetWithText(SelectableText, text), findsOneWidget);
      await t.tap(find.text('关闭'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('暂停目标'));
      await t.pumpAndSettle();
      expect(c.conversation.goal?['status'], 'paused');
      expect(find.byTooltip('继续目标'), findsOneWidget);
      await t.tap(find.byTooltip('继续目标'));
      await t.pumpAndSettle();
      expect(c.conversation.goal?['status'], 'active');
      await t.tap(find.byTooltip('编辑目标'));
      await t.pumpAndSettle();
      expect(find.widgetWithText(TextField, '目标'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('删除目标'));
      await t.pumpAndSettle();
      expect(calls.last.method, 'DELETE');
      expect(find.byKey(const ValueKey('active-goal-bar')), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('thread list scroll automatically loads the next page once', (
    t,
  ) async {
    var calls = 0;
    final c = ready(
      ApiClient(
        client: MockClient((r) async {
          calls++;
          expect(r.url.queryParameters['cursor'], 'next');
          return response({
            'data': List.generate(
              20,
              (i) => {'id': 'next-$i', 'preview': '下一页 $i'},
            ),
            'nextCursor': null,
          });
        }),
      ),
    );
    addTearDown(c.dispose);
    c.threads = List.generate(
      30,
      (i) => {'id': 'first-$i', 'preview': '第一批 $i'},
    );
    c.threadCursor = 'next';
    await t.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    await t.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('加载更多会话'), findsNothing);
    await t.drag(
      find.byKey(const ValueKey('thread-list')),
      const Offset(0, -3500),
    );
    await t.pumpAndSettle();
    expect(calls, 1);
    expect(c.threads.length, 50);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'older messages load on upward scroll and preserve reading position',
    (t) async {
      final older = Completer<http.Response>();
      var calls = 0;
      JsonMap item(int n) => {
        'turnId': 'turn-$n',
        'item': {
          'id': 'm$n',
          'type': 'agentMessage',
          'text': '消息 $n\n${'这一段用来检查阅读位置。\n' * 10}',
        },
      };
      final c = ready(
        ApiClient(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/items')) {
              if (r.url.queryParameters['cursor'] == 'older') {
                calls++;
                return older.future;
              }
              return response({
                'data': List.generate(10, (i) => item(9 - i)),
                'nextCursor': 'older',
              });
            }
            if (r.url.path.endsWith('/goal')) return response({'goal': null});
            return response({
              'thread': {'id': 't'},
            });
          }),
        ),
      );
      addTearDown(c.dispose);
      c.conversation.threadId = 't';
      await c.conversation.reload();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationScreen(appController: c, onCreate: () async {}),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('加载更早消息'), findsNothing);
      await t.drag(
        find.byKey(const ValueKey('conversation-history')),
        const Offset(0, 6000),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(calls, 1);
      final anchor = find.byKey(const ValueKey('m0'));
      expect(anchor, findsOneWidget);
      final before = t.getTopLeft(anchor).dy;
      older.complete(
        response({
          'data': List.generate(5, (i) => item(-i - 1)),
          'nextCursor': null,
        }),
      );
      await t.pumpAndSettle();
      expect(c.conversation.items.length, 15);
      expect(t.getTopLeft(anchor).dy, closeTo(before, 1));
      expect(calls, 1);
      expect(t.takeException(), isNull);
    },
  );
}
