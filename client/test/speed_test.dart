import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/data/conversation_controller.dart';
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

  testWidgets('fast_toggle_left_of_model_tracks_confirmed_session_state', (
    t,
  ) async {
    final writes = <http.Request>[];
    var reply = Completer<http.Response>();
    final c =
        app.AppController(
            api: ApiClient(
              client: MockClient((r) {
                writes.add(r);
                return reply.future;
              }),
            ),
          )
          ..authenticated = true
          ..connection = app.ConnectionState.connected;
    addTearDown(c.dispose);
    final conversation = c.conversation
      ..threadId = 'old-standard'
      ..model = 'gpt-6-astra'
      ..effort = 'xhigh'
      ..serviceTierKnown = true
      ..draft = '保留草稿'
      ..permissions = {'preset': 'full-access', 'label': '完全访问'};
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
    final button = find.byKey(const ValueKey('fast-mode-toggle'));
    expect(
      t.getCenter(button).dx,
      lessThan(t.getCenter(find.byTooltip('模型与推理强度')).dx),
    );
    expect(t.widget<IconButton>(button).isSelected, isFalse);
    await t.tap(button);
    await t.pump();
    expect(writes.single.url.path, '/api/threads/old-standard/speed');
    expect(jsonDecode(writes.single.body), {'mode': 'fast'});
    expect(t.widget<IconButton>(button).isSelected, isFalse);
    expect(t.widget<IconButton>(button).onPressed, isNull);
    expect(conversation.canSend, isFalse);
    reply.complete(json({'serviceTier': 'priority', 'serviceTierKnown': true}));
    await t.pumpAndSettle();
    expect(t.widget<IconButton>(button).isSelected, isTrue);
    expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
    expect(conversation.canSend, isTrue);
    reply = Completer<http.Response>();
    await t.tap(button);
    await t.pump();
    expect(jsonDecode(writes.last.body), {'mode': 'standard'});
    expect(t.widget<IconButton>(button).isSelected, isTrue);
    reply.complete(json({'serviceTier': 'default', 'serviceTierKnown': true}));
    await t.pumpAndSettle();
    expect(t.widget<IconButton>(button).isSelected, isFalse);
    expect(conversation.draft, '保留草稿');
    expect(conversation.model, 'gpt-6-astra');
    expect(conversation.effort, 'xhigh');
    expect(conversation.permissionLabel, '完全访问');
    expect(writes, hasLength(2));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

  test(
    'fast_snapshot_and_external_events_preserve_old_session_modes',
    () async {
      final writes = <http.Request>[];
      final c = ConversationController(
        ApiClient(
          client: MockClient((r) async {
            if (r.method != 'GET') writes.add(r);
            if (r.url.path.endsWith('/items')) return json({'data': []});
            if (r.url.path.endsWith('/goal')) return json({'goal': null});
            final id = r.url.path.split('/').last;
            return json({
              'thread': {'id': id},
              'permissions': {'preset': 'default', 'label': '默认'},
              'serviceTierKnown': true,
              'serviceTier': id == 'fast' ? 'priority' : null,
            });
          }),
        ),
        onError: (e) => fail('$e'),
        onTurnFinished: () {},
      );
      addTearDown(c.dispose);
      await c.select('fast');
      expect(c.fastMode, isTrue);
      await c.select('standard');
      expect(c.fastMode, isFalse);
      expect(c.serviceTierKnown, isTrue);
      c.handleEvent('thread/settings/updated', {
        'threadId': 'fast',
        'threadSettings': {'serviceTier': 'priority'},
        'permissions': {'label': '完全访问'},
      });
      expect(c.fastMode, isFalse);
      expect(c.permissionLabel, '默认');
      c.handleEvent('thread/settings/updated', {
        'threadId': 'standard',
        'threadSettings': {'serviceTier': 'fast'},
        'permissions': {'label': '完全访问'},
      });
      expect(c.fastMode, isTrue);
      expect(c.permissionLabel, '完全访问');
      await c.reload();
      expect(c.fastMode, isFalse);
      expect(c.permissionLabel, '默认');
      expect(writes, isEmpty);
      c.runtimeStopped();
      expect(c.serviceTierKnown, isFalse);
      expect(c.canChangeSpeed, isFalse);
      expect(c.permissionLabel, '权限未知');
    },
  );

  test('fast_update_failure_and_newer_event_preserve_actual_state', () async {
    var reply = Completer<http.Response>();
    final c =
        ConversationController(
            ApiClient(client: MockClient((_) => reply.future)),
            onError: (_) {},
            onTurnFinished: () {},
          )
          ..threadId = 't'
          ..serviceTierKnown = true;
    addTearDown(c.dispose);
    final rejected = c.setFastMode(true);
    reply.complete(
      json({'detail': 'not allowed', 'code': 'codex_rpc_error'}, 409),
    );
    await expectLater(rejected, throwsA(isA<ApiError>()));
    expect(c.fastMode, isFalse);
    expect(c.serviceTierKnown, isTrue);
    expect(c.speedBusy, isFalse);
    reply = Completer<http.Response>();
    final pending = c.setFastMode(true);
    c.handleEvent('thread/settings/updated', {
      'threadId': 't',
      'threadSettings': {'serviceTier': 'priority'},
    });
    c.handleEvent('thread/settings/updated', {
      'threadId': 't',
      'threadSettings': {'serviceTier': 'default'},
    });
    reply.complete(json({'serviceTier': 'priority', 'serviceTierKnown': true}));
    await pending;
    expect(c.fastMode, isFalse);
    expect(c.serviceTier, 'default');
    reply = Completer<http.Response>();
    final unconfirmed = c.setFastMode(true);
    reply.complete(
      json({'detail': 'not confirmed', 'code': 'speed_unconfirmed'}, 504),
    );
    await expectLater(unconfirmed, throwsA(isA<ApiError>()));
    expect(c.serviceTierKnown, isFalse);
    expect(c.canChangeSpeed, isFalse);
    c.handleEvent('thread/settings/updated', {
      'threadId': 't',
      'threadSettings': {'serviceTier': null},
    });
    expect(c.canChangeSpeed, isTrue);
    reply = Completer<http.Response>();
    final oldLogin = c.setFastMode(true);
    c.reset();
    c.threadId = 't';
    reply.complete(json({'serviceTier': 'priority', 'serviceTierKnown': true}));
    await oldLogin;
    expect(c.serviceTierKnown, isFalse);
    expect(c.fastMode, isFalse);
  });

  testWidgets('unknown_and_busy_speed_controls_are_disabled', (t) async {
    final writes = <http.Request>[];
    final c =
        app.AppController(
            api: ApiClient(
              client: MockClient((r) async {
                writes.add(r);
                return json({});
              }),
            ),
          )
          ..authenticated = true
          ..connection = app.ConnectionState.connected;
    addTearDown(c.dispose);
    c.conversation.threadId = 't';
    final button = find.byKey(const ValueKey('fast-mode-toggle'));
    for (final state in [
      'unknown',
      'loading',
      'sending',
      'readonly',
      'permissions',
      'uncertain',
    ]) {
      final conversation = c.conversation
        ..serviceTierKnown = state != 'unknown'
        ..loading = state == 'loading'
        ..sending = state == 'sending'
        ..canControl = state != 'readonly'
        ..permissionsBusy = state == 'permissions'
        ..uncertain = state == 'uncertain';
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Composer(key: ValueKey(state), appController: c),
          ),
        ),
      );
      await t.pump();
      expect(t.widget<IconButton>(button).onPressed, isNull, reason: state);
      await conversation.setFastMode(true);
    }
    expect(writes, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
