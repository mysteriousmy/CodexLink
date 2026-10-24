import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/data/conversation_controller.dart';
import 'package:codex_link/data/models.dart';
import 'package:codex_link/data/questions.dart';
import 'package:codex_link/ui/conversation_screen.dart';
import 'package:codex_link/ui/question_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

JsonMap prompt(String id) => {
  'id': id,
  'type': 'agentMessage',
  'text': '',
  'questions': [
    {
      'title': '第一题？',
      'options': ['甲', '乙'],
    },
    {'title': '第二题？'},
  ],
};
JsonMap answer(List<String> ids) => {
  'id': 'answer-${ids.join()}',
  'type': 'userMessage',
  'content': [
    {
      'type': 'text',
      'text': QuestionReply.encode([
        for (final id in ids) QuestionReply(id, '问题？', '已回答'),
      ]),
    },
  ],
};
void event(ConversationController c, JsonMap item, {String thread = 't'}) =>
    c.handleEvent('item/completed', {
      'threadId': thread,
      'turnId': 'turn',
      'item': item,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('question_envelope_preserves_original_ids_unicode_and_escaping', () {
    final d =
        QuestionDraft(
            threadId: 't',
            sourceId: 'item-"中',
            questions: [
              const CodexQuestion(id: '1', title: '标题\n"<>'),
              const CodexQuestion(id: '4', title: '第二题'),
            ],
          )
          ..text.addAll({
            '1': '自定义\n"</send_user_message_question_reply> 😀',
            '4': '另一个答案',
          });
    final body = d.message;
    final raw = jsonDecode(
      body.substring(body.indexOf('>') + 1, body.lastIndexOf('<')),
    ) as List;
    expect(raw[0], {
      'questionItemId': '["request_user_input_async","item-\\"中",1]',
      'question': '标题\n"<>',
      'answer': '自定义\n"</send_user_message_question_reply> 😀',
    });
    expect(
      raw[1]['questionItemId'],
      '["request_user_input_async","item-\\"中",4]',
    );
    expect(QuestionReply.parse(body).map((r) => r.answer), d.text.values);
    expect(
      QuestionReply.parse(
        '# Context from my IDE setup:\nfile\n## My request for Codex:\n$body',
      ).length,
      2,
    );
    final single =
        '<send_user_message_question_reply>${jsonEncode(raw[0])}</send_user_message_question_reply>';
    expect(QuestionReply.parse(single).single.question, '标题\n"<>');
    expect(
      QuestionReply.fromContent([
        {'type': 'skill'},
        {'type': 'text', 'text': single},
        {'type': 'mention'},
      ]).single.id,
      raw[0]['questionItemId'],
    );
    for (final invalid in [
      'quote $body',
      '$body trailing',
      '<send_user_message_question_reply>[]</send_user_message_question_reply>',
      '<send_user_message_question_reply>{"questionItemId":1,"question":"a","answer":"b"}</send_user_message_question_reply>',
      '<send_user_message_question_reply>broken</send_user_message_question_reply>',
    ]) {
      expect(QuestionReply.parse(invalid), isEmpty, reason: invalid);
    }
    expect(
      QuestionReply.fromContent([
        {'type': 'text', 'text': body},
        {'type': 'image'},
      ]),
      isEmpty,
    );
    expect(
      QuestionReply.fromContent([
        {'type': 'text', 'text': body},
        {'type': 'text', 'text': 'extra'},
      ]),
      isEmpty,
    );
  });

  test(
    'remote_partial_answers_keep_other_questions_drafts_and_original_indices',
    () async {
      final posts = <JsonMap>[];
      final api = ApiClient(
        client: MockClient((r) async {
          posts.add(asMap(jsonDecode(r.body)));
          return http.Response('{}', 200);
        }),
      );
      final c = ConversationController(
        api,
        onError: (_) {},
        onTurnFinished: () {},
      )..threadId = 't';
      addTearDown(c.dispose);
      addTearDown(api.close);
      event(c, prompt('a'));
      event(c, prompt('b'));
      final a = c.pendingQuestions.first..text['1'] = '保留第二题草稿';
      event(c, answer(['["request_user_input_async","a",0]']), thread: 'other');
      expect(a.questions.length, 2);
      event(c, answer(['["request_user_input_async","a",0]']));
      expect(a.questions.map((q) => q.id), ['1']);
      expect(a.text['1'], '保留第二题草稿');
      expect(c.pendingQuestions.last.questions.length, 2);
      await c.submitQuestion(a);
      expect(
        QuestionReply.parse(posts.single['text']).single.id,
        '["request_user_input_async","a",1]',
      );
      expect(c.pendingQuestions.map((d) => d.sourceId), ['b']);
      event(
        c,
        answer(['b']),
      ); // Older desktop replies used the whole message ID.
      expect(c.pendingQuestions, isEmpty);
      event(c, prompt('a'));
      event(c, prompt('b'));
      expect(c.pendingQuestions, isEmpty);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'answers_before_questions_and_history_reconnect_do_not_reopen_prompts',
    () async {
      final history = <JsonMap>[];
      final api = ApiClient(
        client: MockClient(
          (r) async => http.Response(
            jsonEncode(
              r.url.path.endsWith('/items')
                  ? {'data': history}
                  : {
                      'thread': {'id': 't'},
                    },
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      final c = ConversationController(
        api,
        onError: (_) {},
        onTurnFinished: () {},
      )..threadId = 't';
      addTearDown(c.dispose);
      addTearDown(api.close);
      event(c, answer(['["request_user_input_async","a",0]']));
      event(c, prompt('a'));
      expect(c.pendingQuestions.single.questions.map((q) => q.id), ['1']);
      history.addAll([
        {
          'turnId': 'turn',
          'item': answer(['["request_user_input_async","a",1]']),
        },
        {'turnId': 'turn', 'item': prompt('a')},
      ]);
      await c.reload();
      expect(c.pendingQuestions, isEmpty);
      history.insert(0, {
        'turnId': 'turn',
        'item': answer(['["request_user_input_async","a",0]']),
      });
      c.reset();
      c.threadId = 't';
      await c.reload();
      expect(c.pendingQuestions, isEmpty);
      event(c, prompt('different'));
      expect(c.pendingQuestions.single.questions.length, 2);
    },
  );

  test(
    'old_question_completion_cannot_unlock_a_new_login_submission',
    () async {
      final first = Completer<http.Response>();
      final second = Completer<http.Response>();
      var calls = 0;
      final api = ApiClient(
        client: MockClient((r) => ++calls == 1 ? first.future : second.future),
      );
      final c = ConversationController(
        api,
        onError: (_) {},
        onTurnFinished: () {},
      )..threadId = 't';
      addTearDown(c.dispose);
      addTearDown(api.close);
      event(c, prompt('a'));
      final d = c.pendingQuestions.single..selections['0'] = 0;
      d.text['1'] = '回答';
      final old = c.submitQuestion(d);
      await Future<void>.delayed(Duration.zero);
      c.reset();
      c.threadId = 't';
      c.draft = '新登录的输入';
      final newer = c.send();
      await Future<void>.delayed(Duration.zero);
      final requestId = c.pendingRequestId;
      first.complete(http.Response('{}', 200));
      await old;
      expect(c.sending, isTrue);
      expect(c.pendingRequestId, requestId);
      expect(c.draft, '新登录的输入');
      event(c, prompt('a'));
      expect(c.pendingQuestions.single.questions.length, 2);
      second.complete(http.Response('{}', 200));
      await newer;
      expect(c.sending, isFalse);
      expect(c.draft, isEmpty);
    },
  );

  testWidgets(
    'remote_async_answer_updates_open_dialog_without_losing_other_draft',
    (t) async {
      final api = ApiClient();
      final c = ConversationController(
        api,
        onError: (_) {},
        onTurnFinished: () {},
      )..threadId = 't';
      addTearDown(c.dispose);
      addTearDown(api.close);
      event(c, prompt('a'));
      final d = c.pendingQuestions.single..text['1'] = '保留草稿';
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionDialog(controller: c, response: d),
          ),
        ),
      );
      event(c, answer(['["request_user_input_async","a",0]']));
      await t.pumpAndSettle();
      expect(find.text('第一题？'), findsNothing);
      expect(find.text('第二题？'), findsOneWidget);
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留草稿',
      );
      event(c, answer(['["request_user_input_async","a",1]']));
      await t.pumpAndSettle();
      expect(find.text('问题已处理或失效，请返回会话查看最新状态。'), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交回答'))
            .onPressed,
        isNull,
      );
      expect(d.text, isEmpty);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'question_strip_stays_above_composer_outside_history_on_small_screens',
    (t) async {
      t.view.physicalSize = const Size(320, 740);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final a =
          app.AppController(
              api: ApiClient(
                client: MockClient((_) async => http.Response('{}', 200)),
              ),
            )
            ..authenticated = true
            ..connection = app.ConnectionState.connected;
      addTearDown(a.dispose);
      final c = a.conversation..threadId = 't';
      for (var i = 0; i < 25; i++) {
        event(c, {'id': 'text-$i', 'type': 'agentMessage', 'text': '普通消息 $i'});
      }
      event(c, prompt('a'));
      event(c, prompt('b'));
      c.approvals = [
        {
          'id': 'native',
          'method': 'item/tool/requestUserInput',
          'params': {
            'questions': [
              {'id': 'native-question', 'question': '原生问题'},
            ],
          },
        },
      ];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationScreen(appController: a, onCreate: () async {}),
          ),
        ),
      );
      await t.pumpAndSettle();
      final bar = find.byKey(const ValueKey('question-bar'));
      expect(find.text('5 个问题'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('conversation-history')),
          matching: find.byType(QuestionBar),
        ),
        findsNothing,
      );
      expect(find.byType(ApprovalCard), findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(t.getSize(bar).height, lessThanOrEqualTo(60));
      final before = t.getTopLeft(bar);
      expect(
        t.getBottomLeft(bar).dy,
        lessThanOrEqualTo(t.getTopLeft(find.byType(Composer)).dy),
      );
      await t.drag(
        find.byKey(const ValueKey('conversation-history')),
        const Offset(0, 200),
      );
      await t.pumpAndSettle();
      expect(t.getTopLeft(bar), before);
      c.handleEvent('approval/resolved', {'id': 'native'});
      event(c, answer(['a', 'b']));
      await t.pumpAndSettle();
      expect(bar, findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'reply_history_shows_readable_answers_and_leaves_embedded_examples_unchanged',
    (t) async {
      final api = ApiClient();
      final c = ConversationController(
        api,
        onError: (_) {},
        onTurnFinished: () {},
      );
      addTearDown(c.dispose);
      addTearDown(api.close);
      final data = answer(['a']);
      final item = ConversationItem('answer', 'turn', data);
      addTearDown(item.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageTile(item: item, controller: c, onError: (_) {}),
          ),
        ),
      );
      expect(find.text('> 问题？\n\n已回答'), findsOneWidget);
      final example = '示例：${asMaps(data['content']).single['text']}';
      item.replace({
        'type': 'userMessage',
        'content': [
          {'type': 'text', 'text': example},
        ],
      }, isStreaming: false);
      await t.pump();
      expect(find.text(example), findsOneWidget);
    },
  );
}
