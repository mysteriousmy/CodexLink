import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response response(Object data, {int status = 200}) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

app.AppController ready(Future<http.Response> Function(http.Request) handler) =>
    app.AppController(api: ApiClient(client: MockClient(handler)))
      ..initialized = true
      ..authenticated = true
      ..connection = app.ConnectionState.connected;

Future<void> showHome(WidgetTester t, app.AppController c) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(c.dispose);
  await t.pumpWidget(
    MaterialApp(
      home: ListenableBuilder(
        listenable: c,
        builder: (context, _) => HomeScreen(controller: c),
      ),
    ),
  );
}

Future<void> pull(WidgetTester t) async {
  final list = find.byKey(const ValueKey('thread-list'));
  await t.dragFrom(
    t.getTopLeft(list) + const Offset(150, 40),
    const Offset(0, 360),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  for (final scenario in [
    (name: 'empty', count: 0),
    (name: 'short', count: 1),
  ]) {
    testWidgets('pull_refresh_${scenario.name}_list', (t) async {
      final pending = Completer<http.Response>();
      final calls = <http.Request>[];
      final c = ready((r) {
        calls.add(r);
        return pending.future;
      });
      c.threads = List.generate(
        scenario.count,
        (i) => {'id': 'old-$i', 'preview': '旧会话'},
      );
      await showHome(t, c);
      await t.pumpAndSettle();
      expect(calls, isEmpty);
      await pull(t);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'GET');
      expect(calls.single.url.path, '/api/threads');
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      pending.complete(
        response({
          'data': [
            {'id': 'new', 'preview': '新会话'},
          ],
          'nextCursor': null,
        }),
      );
      await t.pumpAndSettle();
      expect(find.text('新会话'), findsOneWidget);
      expect(find.text('旧会话'), findsNothing);
      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('pull_refresh_preserves_filters_and_ignores_stale_page', (
    t,
  ) async {
    final oldPage = Completer<http.Response>();
    final freshPage = Completer<http.Response>();
    final calls = <http.Request>[];
    final c = ready((r) {
      calls.add(r);
      return r.url.queryParameters.containsKey('cursor')
          ? oldPage.future
          : freshPage.future;
    });
    c.projects = [
      {'id': 'project', 'name': '筛选项目'},
    ];
    c.projectId = 'project';
    c.threadSearch = '匹配';
    c.archivedThreads = true;
    c.threadCursor = 'old-cursor';
    c.threads = List.generate(30, (i) => {'id': 'old-$i', 'preview': '旧列表 $i'});
    c.conversation.threadId = 'old-0';
    c.conversation.setDraft('保留的草稿');
    await showHome(t, c);
    final loadingOldPage = c.loadThreads(more: true);
    await t.pump();
    expect(calls.single.url.queryParameters['cursor'], 'old-cursor');
    await pull(t);
    expect(calls, hasLength(2));
    expect(calls.last.url.queryParameters, {
      'projectId': 'project',
      'search': '匹配',
      'archived': 'true',
    });
    expect(find.text('旧列表 0'), findsOneWidget);
    // A second gesture while awaiting the first refresh does not send another request.
    await pull(t);
    expect(calls, hasLength(2));
    freshPage.complete(
      response({
        'data': List.generate(
          30,
          (i) => {'id': 'new-$i', 'preview': '刷新结果 $i'},
        ),
        'nextCursor': 'fresh-cursor',
      }),
    );
    await t.pumpAndSettle();
    expect(find.text('刷新结果 0'), findsOneWidget);
    expect(find.text('旧列表 0'), findsNothing);
    oldPage.complete(
      response({
        'data': [
          {'id': 'stale', 'preview': '过期分页'},
        ],
        'nextCursor': 'stale-cursor',
      }),
    );
    await loadingOldPage;
    await t.pumpAndSettle();
    expect(c.threads, hasLength(30));
    expect(c.threads.any((thread) => thread['id'] == 'stale'), isFalse);
    expect(c.threadCursor, 'fresh-cursor');
    expect(c.projectId, 'project');
    expect(c.threadSearch, '匹配');
    expect(c.archivedThreads, isTrue);
    expect(c.conversation.threadId, 'old-0');
    expect(c.conversation.draft, '保留的草稿');
    expect(t.takeException(), isNull);
  });

  testWidgets('pull_refresh_failure_keeps_list_and_allows_retry', (t) async {
    var calls = 0;
    final c = ready((r) async {
      calls++;
      return calls == 1
          ? response({'message': '刷新暂不可用'}, status: 503)
          : response({
              'data': [
                {'id': 'new', 'preview': '重试后的会话'},
              ],
              'nextCursor': null,
            });
    });
    c.threads = [
      {'id': 'old', 'preview': '保留旧会话'},
    ];
    await showHome(t, c);
    await pull(t);
    await t.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('保留旧会话'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    await pull(t);
    await t.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('重试后的会话'), findsOneWidget);
    expect(find.text('保留旧会话'), findsNothing);
    expect(c.threadListError, isNull);
    expect(t.takeException(), isNull);
  });
}
