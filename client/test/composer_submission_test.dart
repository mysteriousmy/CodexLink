import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/ui/conversation_screen.dart';
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (outcome, status) in [
    ('accepted', 200),
    ('rejected', 409),
    ('uncertain', 504),
  ]) {
    testWidgets(
      'steer_${outcome}_during_sync_restores_composer_and_navigation',
      (t) async {
        final steer = Completer<http.Response>();
        final posts = <http.Request>[];
        final requests = <http.Request>[];
        final c =
            app.AppController(
                api: ApiClient(
                  client: MockClient((r) async {
                    requests.add(r);
                    if (r.method == 'POST') {
                      posts.add(r);
                      return posts.length == 1 ? json({}) : steer.future;
                    }
                    if (r.url.path.contains('/operations/')) {
                      return json({'state': 'accepted'});
                    }
                    if (r.url.path.endsWith('/items')) {
                      return json({'data': []});
                    }
                    if (r.url.path.endsWith('/goal')) {
                      return json({'goal': null});
                    }
                    return json({
                      'thread': {'id': r.url.path.split('/').last},
                      if (r.url.path.endsWith('/original'))
                        'activeTurnId': 'running',
                    });
                  }),
                ),
              )
              ..authenticated = true
              ..connection = app.ConnectionState.connected;
        addTearDown(c.dispose);
        c.conversation.threadId = 'original';
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Spacer(),
                  Composer(appController: c),
                ],
              ),
            ),
          ),
        );
        final field = find.byType(TextField);
        await t.enterText(field, '开始任务');
        await t.pump();
        await t.tap(find.widgetWithText(FilledButton, '发送'));
        await t.pumpAndSettle();
        c.conversation.handleEvent('turn/started', {
          'threadId': 'original',
          'turn': {'id': 'running'},
        });
        await t.pump();
        await t.enterText(field, '补充方向');
        await t.pump();
        await t.tap(find.widgetWithText(FilledButton, '补充'));
        await t.pump();
        expect(c.conversation.sending, isTrue);
        expect(t.widget<TextField>(field).readOnly, isTrue);

        // Reconnection refreshes history while this HTTP request is in flight.
        await c.conversation.reload();
        expect(c.conversation.loading, isFalse);
        expect(c.conversation.sending, isTrue);
        steer.complete(json({'detail': 'fixture response'}, status));
        await t.pump();
        await t.pump(const Duration(milliseconds: 200));

        expect(c.conversation.sending, isFalse);
        expect(c.conversation.uncertain, outcome == 'uncertain');
        expect(c.conversation.draft, outcome == 'accepted' ? '' : '补充方向');
        expect(posts.map((r) => r.url.path), [
          '/api/threads/original/turns',
          '/api/threads/original/turns/running/steer',
        ]);
        expect(jsonDecode(posts.last.body)['text'], '补充方向');
        if (outcome == 'uncertain') {
          expect(t.widget<TextField>(field).readOnly, isTrue);
          await c.conversation.reconcile();
          await t.pumpAndSettle();
          expect(
            requests.where((r) => r.url.path.contains('/operations/')),
            hasLength(1),
          );
          expect(c.conversation.uncertain, isFalse);
          expect(posts, hasLength(2));
        }
        expect(t.widget<TextField>(field).readOnly, isFalse);
        await t.enterText(field, '下一条可以继续输入');
        expect(c.conversation.draft, '下一条可以继续输入');
        expect(c.conversation.canSend, isTrue);
        await c.selectThread('other');
        await t.pumpAndSettle();
        expect(c.conversation.threadId, 'other');
        expect(t.widget<TextField>(field).readOnly, isFalse);
        await t.enterText(field, '另一会话也能输入');
        expect(c.conversation.draft, '另一会话也能输入');
        expect(c.conversation.canSend, isTrue);
        expect(posts, hasLength(2));
        expect(t.takeException(), isNull);
        await t.pump(const Duration(milliseconds: 600));
        await t.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final status in [200, 504]) {
    test('old_send_${status}_cannot_unlock_new_login_submission', () async {
      final old = Completer<http.Response>();
      final current = Completer<http.Response>();
      var posts = 0;
      final c = app.AppController(
        api: ApiClient(
          client: MockClient((_) => ++posts == 1 ? old.future : current.future),
        ),
      );
      addTearDown(c.dispose);
      final conversation = c.conversation..threadId = 'same-thread';
      conversation.setDraft('old login');
      final oldSend = conversation.send();
      conversation.reset();
      conversation.threadId = 'same-thread';
      conversation.setDraft('new login');
      final currentSend = conversation.send();
      final currentId = conversation.pendingRequestId;
      old.complete(json({}, status));
      await oldSend;
      expect(conversation.sending, isTrue);
      expect(conversation.pendingRequestId, currentId);
      expect(conversation.draft, 'new login');
      expect(conversation.uncertain, isFalse);
      expect(c.error.value, isNull);
      current.complete(json({}));
      expect(await currentSend, isTrue);
      expect(conversation.sending, isFalse);
      expect(conversation.draft, isEmpty);
      expect(posts, 2);
    });
  }
}
