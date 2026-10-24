import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/conversation_controller.dart';
import 'package:codex_link/data/models.dart';
import 'package:codex_link/data/questions.dart';
import 'package:codex_link/ui/conversation_screen.dart';
import 'package:codex_link/ui/question_prompt.dart';
import 'package:codex_link/ui/task_activity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response reply(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const questionData = [
  {
    'id': 'choice',
    'header': '方案',
    'question': '选择实现方式？',
    'isOther': false,
    'isSecret': false,
    'options': [
      {'label': '分步完成（推荐）', 'description': '先验证核心流程，再发布。'},
      {'label': '一次完成', 'description': '直接提交完整实现。'},
    ],
  },
  {
    'id': 'other',
    'header': '范围',
    'question': '平台要求？',
    'isOther': true,
    'isSecret': false,
    'options': [
      {'label': '手机', 'description': '移动端优先。'},
    ],
  },
  {
    'id': 'secret',
    'header': '私密输入',
    'question': '私密回答',
    'isOther': false,
    'isSecret': true,
    'options': null,
  },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConversationController c;
  late ApiClient api;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  void setup(Future<http.Response> Function(http.Request) handler) {
    api = ApiClient(client: MockClient(handler));
    c = ConversationController(api, onError: (_) {}, onTurnFinished: () {})
      ..threadId = 't';
  }

  tearDown(() {
    c.dispose();
    api.close();
  });
  JsonMap approval({bool blocking = true}) => {
    'id': 'pending',
    'method': 'item/tool/requestUserInput',
    'params': {
      'threadId': 't',
      'isBlocking': blocking,
      'questions': questionData,
    },
  };
  QuestionDraft draft({bool native = false}) => c.questionDraft('q', [
    CodexQuestion(
      id: native ? 'q' : '0',
      title: '你希望怎么做？',
      options: [(label: '分步完成', description: '')],
    ),
  ], approvalId: native ? 'pending' : null)..selections[native ? 'q' : '0'] = 0;
  Future<void> show(WidgetTester t, Widget child) =>
      t.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  testWidgets(
    'question_options_show_descriptions_validate_all_answers_and_hide_secrets',
    (t) async {
      final posts = <JsonMap>[];
      setup((r) async {
        posts.add(asMap(jsonDecode(r.body)));
        return http.Response('', 204);
      });
      c.approvals = [approval()];
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await show(
        t,
        ApprovalCard(
          approval: c.approvals.single,
          controller: c,
          onError: (e) => fail('$e'),
        ),
      );
      await t.tap(find.byTooltip('回答问题'));
      await t.pumpAndSettle();
      expect(find.text('先验证核心流程，再发布。'), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交回答'))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const ValueKey('question-choice-other')), findsNothing);
      await t.tap(find.byKey(const ValueKey('question-choice-option-0')));
      await t.pump();
      await t.ensureVisible(find.byKey(const ValueKey('question-other-other')));
      await t.tap(find.byKey(const ValueKey('question-other-other')));
      await t.pump();
      await t.enterText(
        find.byKey(const ValueKey('question-other-text')),
        '手机和网页',
      );
      await t.ensureVisible(find.byKey(const ValueKey('question-secret-text')));
      final secret = t.widget<TextField>(
        find.byKey(const ValueKey('question-secret-text')),
      );
      expect(secret.obscureText, isTrue);
      expect(secret.enableSuggestions, isFalse);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交回答'))
            .onPressed,
        isNull,
      );
      await t.enterText(
        find.byKey(const ValueKey('question-secret-text')),
        'private fixture',
      );
      t.view.viewInsets = const FakeViewPadding(bottom: 280);
      t.view.physicalSize = const Size(320, 640);
      addTearDown(t.view.resetViewInsets);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.text('提交回答'));
      await t.pumpAndSettle();
      expect(posts, [
        {
          'result': {
            'answers': {
              'choice': {
                'answers': ['分步完成（推荐）'],
              },
              'other': {
                'answers': ['手机和网页'],
              },
              'secret': {
                'answers': ['private fixture'],
              },
            },
          },
        },
      ]);
      expect(find.byType(QuestionDialog), findsNothing);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  testWidgets(
    'question_failure_keeps_answers_when_dismissed_and_prevents_duplicate_submit',
    (t) async {
      var count = 0;
      final pending = Completer<http.Response>();
      setup((_) {
        count++;
        return count == 1
            ? Future.value(reply({'detail': '暂时不可用'}, 503))
            : pending.future;
      });
      c.approvals = [approval()];
      final d = draft(native: true);
      await show(
        t,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => QuestionDialog(controller: c, response: d),
            ),
            child: const Text('打开'),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      await t.tap(find.text('提交回答'));
      await t.pumpAndSettle();
      expect(find.text('暂时不可用'), findsOneWidget);
      expect(d.answer(d.questions.single), '分步完成');
      await t.tap(find.text('稍后回答'));
      await t.pumpAndSettle();
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      expect(
        t
            .widget<ListTile>(find.byKey(const ValueKey('question-q-option-0')))
            .selected,
        isTrue,
      );
      await t.tap(find.text('提交回答'));
      await t.pump();
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '正在提交…'))
            .onPressed,
        isNull,
      );
      await c.submitQuestion(d);
      expect(count, 2);
      pending.complete(http.Response('', 204));
      await t.pumpAndSettle();
      expect(d.sent, isTrue);
      expect(c.approvals, isEmpty);
    },
  );

  testWidgets('question_resolved_remotely_disables_open_dialog', (t) async {
    var calls = 0;
    setup((_) async {
      calls++;
      return reply({});
    });
    c.approvals = [approval()];
    final d = draft(native: true);
    await show(t, QuestionDialog(controller: c, response: d));
    c.handleEvent('approval/resolved', {'id': 'pending'});
    await t.pumpAndSettle();
    expect(find.text('问题已处理或失效，请返回会话查看最新状态。'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '提交回答'))
          .onPressed,
      isNull,
    );
    await expectLater(c.submitQuestion(d), throwsA(isA<ApiError>()));
    expect(calls, 0);
  });

  test(
    'native_expiry_response_removes_stale_prompt_without_losing_other_requests',
    () async {
      setup(
        (_) async => reply({'code': 'approval_expired', 'detail': '已失效'}, 409),
      );
      c.approvals = [
        approval(),
        {...approval(), 'id': 'second'},
      ];
      final d = draft(native: true);
      await expectLater(c.submitQuestion(d), throwsA(isA<ApiError>()));
      expect(c.approvals.map((a) => a['id']), ['second']);
      expect(c.questionAvailable(d), isFalse);
    },
  );

  test('question_reload_preserves_in_memory_draft_and_runtime_exit_expires_native_request', () async {
    setup(
      (r) async => reply(
        r.url.path.endsWith('/items')
            ? {'data': []}
            : r.url.path.endsWith('/goal')
            ? {}
            : {
                'thread': {'id': 't'},
                'approvals': [approval()],
              },
      ),
    );
    c.approvals = [approval()];
    final d = draft(native: true);
    d.text['q'] = 'private memory';
    await c.reload();
    expect(
      identical(c.questionDraft('q', d.questions, approvalId: 'pending'), d),
      isTrue,
    );
    expect(d.answer(d.questions.single), '分步完成');
    expect(c.questionAvailable(d), isTrue);
    c.runtimeStopped();
    expect(c.questionAvailable(d), isFalse);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  for (final active in [false, true]) {
    test(
      'async_question_${active ? 'steers_active_turn' : 'starts_idle_turn'}_preserving_composer',
      () async {
        final calls = <http.Request>[];
        setup((r) async {
          calls.add(r);
          return reply({});
        });
        c.activeTurnId = active ? 'running' : null;
        c.draft = '原来的草稿';
        c.goalMode = true;
        c.goal = {'status': 'active', 'objective': '已有目标'};
        c.references = [
          {'type': 'file', 'path': '/project/a.txt'},
        ];
        c.model = 'keep-model';
        c.effort = 'high';
        final d = draft();
        await c.submitQuestion(d);
        expect(calls.map((r) => r.url.path), [
          active
              ? '/api/threads/t/turns/running/steer'
              : '/api/threads/t/turns',
        ]);
        final body = asMap(jsonDecode(calls.single.body));
        expect(
          QuestionReply.parse(body['text']).single.id,
          '["request_user_input_async","q",0]',
        );
        expect(QuestionReply.parse(body['text']).single.answer, '分步完成');
        expect(body.keys.toSet(), {'requestId', 'text'});
        expect(body['requestId'], isNotEmpty);
        expect(c.draft, '原来的草稿');
        expect(c.goalMode, isTrue);
        expect(c.goal?['objective'], '已有目标');
        expect(c.references, [
          {'type': 'file', 'path': '/project/a.txt'},
        ]);
        expect(d.sent, isTrue);
        await c.submitQuestion(d);
        expect(calls.length, 1);
      },
    );
  }

  test(
    'async_unknown_submission_reconciles_without_replaying_or_changing_answer',
    () async {
      final calls = <http.Request>[];
      var state = 'pending';
      setup((r) async {
        calls.add(r);
        return r.method == 'POST' ? reply({}, 502) : reply({'state': state});
      });
      final d = draft();
      await expectLater(c.submitQuestion(d), throwsA(isA<ApiError>()));
      final requestId = d.requestId;
      expect(requestId, isNotNull);
      expect(d.sent, isFalse);
      await expectLater(c.submitQuestion(d), throwsA(isA<ApiError>()));
      expect(d.requestId, requestId);
      expect(calls.last.url.path, '/api/operations/$requestId');
      state = 'accepted';
      await c.submitQuestion(d);
      expect(d.sent, isTrue);
      expect(d.requestId, isNull);
      expect(calls.where((r) => r.method == 'POST').length, 1);
    },
  );

  test(
    'async_turn_change_preserves_answer_and_never_falls_back_to_new_turn',
    () async {
      final paths = <String>[];
      setup((r) async {
        paths.add(r.url.path);
        return reply({'code': 'turn_changed', 'detail': '轮次已变化'}, 409);
      });
      c.activeTurnId = 'previous';
      final d = draft();
      await expectLater(c.submitQuestion(d), throwsA(isA<ApiError>()));
      expect(paths, ['/api/threads/t/turns/previous/steer']);
      expect(d.requestId, isNull);
      expect(d.answer(d.questions.single), '分步完成');
      expect(d.sent, isFalse);
    },
  );

  test(
    'async_unknown_and_failed_operations_never_resend_until_explicit_retry',
    () async {
      var state = 'unknown';
      var posts = 0;
      setup((r) async {
        if (r.method == 'POST') {
          posts++;
          return reply({}, posts == 1 ? 502 : 200);
        }
        return reply({'state': state});
      });
      final d = draft();
      await expectLater(c.submitQuestion(d), throwsA(isA<ApiError>()));
      final id = d.requestId;
      await expectLater(c.submitQuestion(d), throwsA(isA<ApiError>()));
      expect(d.requestId, id);
      expect(posts, 1);
      state = 'failed';
      await expectLater(c.submitQuestion(d), throwsA(isA<ApiError>()));
      expect(d.requestId, isNull);
      expect(posts, 1);
      expect(d.answer(d.questions.single), '分步完成');
      await c.submitQuestion(d);
      expect(posts, 2);
      expect(d.sent, isTrue);
    },
  );

  test(
    'question_drafts_are_isolated_by_thread_and_logout_clears_them',
    () async {
      setup(
        (r) async => reply(
          r.url.path.endsWith('/items')
              ? {'data': []}
              : r.url.path.endsWith('/goal')
              ? {}
              : {
                  'thread': {'id': 't'},
                },
        ),
      );
      final original = draft();
      await c.select('other');
      expect(c.questionAvailable(original), isFalse);
      final other = draft();
      expect(identical(original, other), isFalse);
      await c.select('t');
      expect(
        identical(c.questionDraft('q', original.questions), original),
        isTrue,
      );
      expect(original.answer(original.questions.single), '分步完成');
      c.reset();
      c.threadId = 't';
      expect(c.questionDraft('q', original.questions).selections, isEmpty);
    },
  );

  testWidgets(
    'async_question_bar_allows_custom_answer_and_disappears_after_submission',
    (t) async {
      final posts = <JsonMap>[];
      setup((r) async {
        posts.add(asMap(jsonDecode(r.body)));
        return reply({});
      });
      final item = ConversationItem('async', 'turn', {
        'type': 'agentMessage',
        'text': '',
        'delivery': 'async',
        'questions': [
          {
            'title': '需要哪种风格？',
            'options': ['简洁（推荐）', '详细'],
          },
        ],
      });
      c.items.add(item);
      await show(t, QuestionBar(controller: c));
      expect(find.text('需要哪种风格？'), findsOneWidget);
      await t.tap(find.byTooltip('回答问题'));
      await t.pumpAndSettle();
      expect(find.text('简洁（推荐）'), findsOneWidget);
      await t.tap(find.text('其他回答'));
      await t.pump();
      await t.enterText(find.byType(TextField), '自定义风格');
      await t.pump();
      await t.tap(find.text('提交回答'));
      await t.pumpAndSettle();
      expect(
        QuestionReply.parse(posts.single['text']).single.id,
        '["request_user_input_async","async",0]',
      );
      expect(QuestionReply.parse(posts.single['text']).single.answer, '自定义风格');
      expect(find.byKey(const ValueKey('question-bar')), findsNothing);
    },
  );

  testWidgets('nonblocking_question_keeps_task_running_indicator', (t) async {
    setup((_) async => reply({}));
    c.activeTurnId = 'running';
    c.approvals = [approval(blocking: false)];
    await show(t, TaskActivity(controller: c, connected: true));
    expect(find.text('正在执行'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    c.approvals = [approval()];
    await show(t, TaskActivity(controller: c, connected: true));
    await t.pumpAndSettle();
    expect(find.text('等待你的回复或审批'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
