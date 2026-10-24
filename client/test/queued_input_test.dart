import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/data/conversation_controller.dart';
import 'package:codex_link/data/models.dart';
import 'package:codex_link/ui/conversation_screen.dart';
import 'package:codex_link/ui/queued_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
JsonMap queued({String id = 'queued-1'}) => {
  'id': id,
  'clientUserMessageId': 'codexlink-queue-text-original',
  'text': '保留待发送内容',
  'references': [
    {'type': 'file', 'name': 'notes.txt', 'path': '/work/notes.txt'},
  ],
  'attachments': [
    {'id': 'file', 'name': 'photo.png', 'size': 123, 'isImage': true},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'default_followup_exposes_send_now_and_withdraw_before_submission',
    (t) async {
      final posts = <http.Request>[];
      var queue = <JsonMap>[];
      final a =
          app.AppController(
              api: ApiClient(
                client: MockClient((r) async {
                  if (r.method == 'GET') return json({'data': queue});
                  posts.add(r);
                  if (r.url.path.endsWith('/input')) {
                    queue = [
                      queued()
                        ..['attachments'] = []
                        ..['references'] = [],
                    ];
                    return json({'submission': queue.single});
                  }
                  if (r.url.path.endsWith('/send')) {
                    queue = [];
                    return json({'state': 'sent'});
                  }
                  throw StateError('Unexpected request: ${r.url.path}');
                }),
              ),
            )
            ..authenticated = true
            ..connection = app.ConnectionState.connected;
      addTearDown(a.dispose);
      final c = a.conversation
        ..threadId = 't'
        ..activeTurnId = 'running'
        ..queueSupported = true
        ..automaticInputSupported = true;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (context, _) => Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  QueuedInputBar(controller: c),
                  Composer(appController: a),
                ],
              ),
            ),
          ),
        ),
      );
      await t.enterText(find.byType(TextField), '默认先排队');
      await t.pump();
      await t.tap(find.text('补充'));
      await t.pumpAndSettle();
      expect(posts.single.url.path, '/api/threads/t/input');
      expect(c.acceptedSteers, isEmpty);
      expect(find.text('待发送 · 本轮结束后发送'), findsOneWidget);
      expect(find.byTooltip('立即 steer').hitTestable(), findsOneWidget);
      expect(find.byTooltip('撤回').hitTestable(), findsOneWidget);
      await t.tap(find.byTooltip('立即 steer'));
      await t.pumpAndSettle();
      expect(posts.last.url.path, '/api/threads/t/queue/queued-1/send');
      expect(jsonDecode(posts.last.body)['expectedTurnId'], 'running');
      expect(posts, hasLength(2));
      expect(c.queuedInputs, isEmpty);
      expect(find.byTooltip('撤回'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  test(
    'automatic_send_uses_runtime_selection_and_tracks_native_consumption',
    () async {
      final posts = <http.Request>[];
      final c =
          ConversationController(
              ApiClient(
                client: MockClient((r) async {
                  if (r.method == 'GET') return json({'data': []});
                  posts.add(r);
                  return json({'turnId': 'native-running'});
                }),
              ),
              onError: (e) => fail('$e'),
              onTurnFinished: () {},
            )
            ..threadId = 't'
            ..automaticInputSupported = true
            ..queueSupported = true
            ..draft = '自动选择发送时机';
      addTearDown(c.dispose);
      // The UI may still look idle while the runtime has an active turn.
      expect(await c.send(), isTrue);
      expect(posts.single.url.path, '/api/threads/t/input');
      final id = jsonDecode(posts.single.body)['requestId'];
      expect(c.acceptedSteers.single['id'], id);
      expect(c.draft, isEmpty);
      c.handleEvent('item/started', {
        'threadId': 't',
        'turnId': 'native-running',
        'item': {
          'type': 'userMessage',
          'id': 'accepted-item',
          'clientId': id,
          'content': [],
        },
      });
      expect(c.acceptedSteers, isEmpty);
      c.activeTurnId = 'native-running';
      c.draft = '手动排到本轮结束';
      expect(await c.send(queue: true), isTrue);
      expect(posts.last.url.path, '/api/threads/t/queue');
      expect(c.acceptedSteers, isEmpty);
    },
  );

  test('automatic_steer_acceptance_before_response_and_restart_do_not_leave_stale_bar', () async {
    late ConversationController c;
    var immediate = true;
    JsonMap? historyItem;
    ApiClient api() => ApiClient(
      client: MockClient((r) async {
        if (r.method == 'POST') {
          final id = jsonDecode(r.body)['requestId'];
          final data = {
            'type': 'userMessage',
            'id': 'message-$id',
            'clientId': id,
            'content': [],
          };
          if (immediate) {
            c.handleEvent('item/started', {
              'threadId': 't',
              'turnId': 'running',
              'item': data,
            });
          } else {
            historyItem = {'turnId': 'running', 'item': data};
          }
          return json({'turnId': 'running'});
        }
        if (r.url.path.endsWith('/items')) {
          return json({
            'data': historyItem == null ? [] : [historyItem],
          });
        }
        return json({
          'thread': {'id': 't'},
          'activeTurnId': 'running',
        });
      }),
    );
    c =
        ConversationController(
            api(),
            onError: (e) => fail('$e'),
            onTurnFinished: () {},
          )
          ..threadId = 't'
          ..activeTurnId = 'running'
          ..automaticInputSupported = true
          ..draft = 'already consumed';
    expect(await c.send(), isTrue);
    expect(c.acceptedSteers, isEmpty);
    immediate = false;
    c.draft = 'pending until model resumes';
    expect(await c.send(), isTrue);
    expect(c.acceptedSteers, hasLength(1));
    c.dispose();
    final restored = ConversationController(
      api(),
      onError: (e) => fail('$e'),
      onTurnFinished: () {},
    );
    addTearDown(restored.dispose);
    await restored.select('t');
    expect(restored.acceptedSteers, isEmpty);
    expect(
      restored.items.single.data['clientId'],
      historyItem!['item']['clientId'],
    );
  });

  test(
    'running_messages_queue_and_withdraw_merge_draft_files_and_references',
    () async {
      final posts = <http.Request>[];
      var queue = <JsonMap>[];
      final c =
          ConversationController(
              ApiClient(
                client: MockClient((r) async {
                  if (r.method == 'GET') return json({'data': queue});
                  posts.add(r);
                  if (r.url.path.endsWith('/withdraw')) {
                    final item = queue.single;
                    queue = [];
                    return json({'state': 'withdrawn', 'submission': item});
                  }
                  queue = [queued()];
                  return json({'submission': queue.single});
                }),
              ),
              onError: (e) => fail('$e'),
              onTurnFinished: () {},
            )
            ..threadId = 't'
            ..activeTurnId = 'running'
            ..queueSupported = true
            ..draft = '保留待发送内容';
      addTearDown(c.dispose);
      expect(await c.send(queue: true), isTrue);
      await c.refreshQueue();
      expect(posts.single.url.path, '/api/threads/t/queue');
      expect(c.draft, isEmpty);
      expect(c.queuedInputs.single['text'], '保留待发送内容');
      c.draft = '正在编辑的新草稿';
      c.references = [
        {'type': 'skill', 'name': 'existing', 'path': '/work/SKILL.md'},
      ];
      await c.actOnQueuedInput(c.queuedInputs.single, sendNow: false);
      expect(c.draft, '正在编辑的新草稿\n保留待发送内容');
      expect(c.references.map((r) => r['name']), ['existing', 'notes.txt']);
      expect(c.uploads.single.uploaded?['id'], 'file');
      expect(c.uploads.single.file.name, 'photo.png');
      expect(c.uploads.single.size, 123);
      expect(c.queuedInputs, isEmpty);
      expect(c.pendingQueueAction, isNull);
      expect(posts.map((r) => r.url.path), [
        '/api/threads/t/queue',
        '/api/threads/t/queue/queued-1/withdraw',
      ]);
    },
  );

  test(
    'send_now_unknown_survives_restart_and_reconciles_without_resending',
    () async {
      final posts = <http.Request>[];
      var accepted = false;
      final errors = <Object>[];
      ApiClient api() => ApiClient(
        client: MockClient((r) async {
          if (r.method == 'POST') {
            posts.add(r);
            throw const ApiError('connection lost');
          }
          if (r.url.path.contains('/operations/')) {
            return json({
              'state': accepted ? 'accepted' : 'unknown',
              if (accepted) 'result': {'state': 'sent'},
            });
          }
          if (r.url.path.endsWith('/items') || r.url.path.endsWith('/queue')) {
            return json({'data': []});
          }
          if (r.url.path.endsWith('/goal')) return json({'goal': null});
          return json({
            'thread': {'id': 't'},
            'activeTurnId': 'running',
          });
        }),
      );
      ConversationController make() => ConversationController(
        api(),
        onError: errors.add,
        onTurnFinished: () {},
      )..queueSupported = true;
      final first = make()
        ..threadId = 't'
        ..activeTurnId = 'running'
        ..draft = '独立草稿';
      await first.actOnQueuedInput(queued(), sendNow: true);
      expect(jsonDecode(posts.single.body)['expectedTurnId'], 'running');
      expect(first.pendingQueueAction, isNotNull);
      expect(first.draft, '独立草稿');
      first.dispose();
      final second = make();
      addTearDown(second.dispose);
      await second.select('t');
      expect(second.pendingQueueAction?['submission']['text'], '保留待发送内容');
      await second.reconcileQueueAction();
      expect(second.pendingQueueAction, isNotNull);
      accepted = true;
      await second.reconcileQueueAction();
      expect(second.pendingQueueAction, isNull);
      expect(posts, hasLength(1));
      expect(errors, isNotEmpty);
    },
  );

  test('withdraw_lost_response_restores_once_after_receipt_lookup', () async {
    var posts = 0;
    final c =
        ConversationController(
            ApiClient(
              client: MockClient((r) async {
                if (r.method == 'POST') {
                  posts++;
                  return json({'detail': 'timeout'}, 504);
                }
                if (r.url.path.contains('/operations/')) {
                  return json({
                    'state': 'accepted',
                    'result': {'state': 'withdrawn', 'submission': queued()},
                  });
                }
                if (r.url.path.endsWith('/items') ||
                    r.url.path.endsWith('/queue')) {
                  return json({'data': []});
                }
                if (r.url.path.endsWith('/goal')) return json({'goal': null});
                return json({
                  'thread': {'id': 't'},
                });
              }),
            ),
            onError: (_) {},
            onTurnFinished: () {},
          )
          ..threadId = 't'
          ..queueSupported = true
          ..draft = 'existing';
    addTearDown(c.dispose);
    await c.actOnQueuedInput(queued(), sendNow: false);
    expect(c.draft, 'existing');
    await c.reconcileQueueAction();
    await c.reconcileQueueAction();
    expect(c.draft, 'existing\n保留待发送内容');
    expect(c.uploads, hasLength(1));
    expect(posts, 1);
  });

  test(
    'queue_action_rejection_and_old_gateway_preserve_existing_behavior',
    () async {
      final posts = <http.Request>[];
      final c =
          ConversationController(
              ApiClient(
                client: MockClient((r) async {
                  if (r.method == 'GET') {
                    return json({
                      'data': [queued()],
                    });
                  }
                  posts.add(r);
                  if (r.url.path.endsWith('/send')) {
                    return json({'detail': 'turn changed'}, 409);
                  }
                  return json({});
                }),
              ),
              onError: (_) {},
              onTurnFinished: () {},
            )
            ..threadId = 't'
            ..activeTurnId = 'running'
            ..draft = 'legacy';
      addTearDown(c.dispose);
      expect(await c.send(), isTrue);
      expect(posts.single.url.path, '/api/threads/t/turns/running/steer');
      c.queueSupported = true;
      c.draft = 'new draft';
      await c.actOnQueuedInput(queued(), sendNow: true);
      expect(c.pendingQueueAction, isNull);
      expect(c.queuedInputs, hasLength(1));
      expect(c.draft, 'new draft');
    },
  );

  testWidgets(
    'queue_events_coalesce_and_old_thread_response_cannot_replace_current_queue',
    (t) async {
      final delayed = Completer<http.Response>();
      final paths = <String>[];
      final c =
          ConversationController(
              ApiClient(
                client: MockClient((r) async {
                  paths.add(r.url.path);
                  if (r.url.path == '/api/threads/old/queue') {
                    return delayed.future;
                  }
                  return json({
                    'data': [queued(id: 'current')],
                  });
                }),
              ),
              onError: (e) => fail('$e'),
              onTurnFinished: () {},
            )
            ..threadId = 'old'
            ..queueSupported = true;
      addTearDown(c.dispose);
      final old = c.refreshQueue();
      await t.pump();
      c.threadId = 'new';
      for (var i = 0; i < 5; i++) {
        c.handleEvent('thread/queue/changed', {'threadId': 'new'});
      }
      await t.pump(const Duration(milliseconds: 100));
      await t.pump();
      delayed.complete(
        json({
          'data': [queued(id: 'stale')],
        }),
      );
      await old;
      expect(c.queuedInputs.single['id'], 'current');
      expect(paths, ['/api/threads/old/queue', '/api/threads/new/queue']);
    },
  );

  testWidgets('withdraw_button_updates_visible_editor_and_next_submission', (
    t,
  ) async {
    final input = queued()
      ..['attachments'] = []
      ..['references'] = [];
    final posts = <http.Request>[];
    final a =
        app.AppController(
            api: ApiClient(
              client: MockClient((r) async {
                if (r.method == 'GET') return json({'data': []});
                posts.add(r);
                if (r.url.path.endsWith('/withdraw')) {
                  return json({'state': 'withdrawn', 'submission': input});
                }
                return json({'submission': input});
              }),
            ),
          )
          ..authenticated = true
          ..connection = app.ConnectionState.connected;
    addTearDown(a.dispose);
    final c = a.conversation
      ..threadId = 't'
      ..activeTurnId = 'running'
      ..queueSupported = true
      ..draft = 'existing draft'
      ..queuedInputs = [input];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                QueuedInputBar(controller: c),
                Composer(appController: a),
              ],
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byTooltip('撤回'));
    await t.pumpAndSettle();
    final field = find.byType(TextField);
    expect(
      t.widget<TextField>(field).controller!.text,
      'existing draft\n保留待发送内容',
    );
    await t.enterText(field, 'existing draft\n保留待发送内容\n继续编辑');
    await t.tap(find.byTooltip('本轮结束后发送'));
    await t.pumpAndSettle();
    expect(posts.last.url.path, '/api/threads/t/queue');
    expect(
      jsonDecode(posts.last.body)['text'],
      'existing draft\n保留待发送内容\n继续编辑',
    );
    expect(t.widget<TextField>(field).controller!.text, isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'goal_questions_queue_and_keyboard_remain_scrollable_without_overlap',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      final a =
          app.AppController(
              api: ApiClient(client: MockClient((r) async => json({}))),
            )
            ..authenticated = true
            ..connection = app.ConnectionState.connected;
      addTearDown(a.dispose);
      final c = a.conversation
        ..threadId = 't'
        ..thread = {'preview': '三栏布局'}
        ..activeTurnId = 'running'
        ..queueSupported = true
        ..acceptedSteers = [
          {
            'id': 'accepted-preview',
            'turnId': 'running',
            'text': '这条补充等待 Codex 处理',
          },
        ]
        ..goal = {'objective': '同时保留三个提示栏', 'status': 'active'}
        ..queuedInputs = [queued(), queued(id: 'second')];
      c.items.add(
        ConversationItem('question', 'running', {
          'id': 'question',
          'type': 'agentMessage',
          'questions': [
            {
              'question': '选择实现方案？',
              'options': ['推荐方案', '备选方案'],
            },
          ],
        }),
      );
      for (final (size, inset) in [
        (const Size(390, 844), 0.0),
        (const Size(320, 568), 240.0),
        (const Size(800, 400), 180.0),
      ]) {
        t.view.physicalSize = size;
        t.view.viewInsets = FakeViewPadding(bottom: inset);
        await t.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Scaffold(
              body: ConversationScreen(appController: a, onCreate: () async {}),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 200));
        expect(find.byKey(const ValueKey('active-goal-bar')), findsOneWidget);
        expect(find.byKey(const ValueKey('question-bar')), findsOneWidget);
        expect(find.byKey(const ValueKey('queued-input-bar')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('accepted-steer-accepted-preview')),
          findsOneWidget,
        );
        final field = find.descendant(
          of: find.byType(Composer),
          matching: find.byType(TextField),
        );
        await t.ensureVisible(field);
        await t.pump(const Duration(milliseconds: 200));
        expect(field.hitTestable(), findsOneWidget);
        await t.ensureVisible(find.byTooltip('撤回').last);
        await t.pump(const Duration(milliseconds: 200));
        expect(find.byTooltip('撤回').last.hitTestable(), findsOneWidget);
        await t.ensureVisible(find.byTooltip('同步补充指令状态'));
        await t.pump(const Duration(milliseconds: 200));
        expect(find.byTooltip('同步补充指令状态').hitTestable(), findsOneWidget);
        expect(
          t.getRect(find.byKey(const ValueKey('composer-status-bars'))).bottom,
          lessThanOrEqualTo(t.getRect(find.byType(Composer)).top + .1),
        );
        expect(t.takeException(), isNull, reason: '$size, keyboard $inset');
      }
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
}
