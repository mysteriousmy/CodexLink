import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/data/conversation_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class EventSink extends Fake implements WebSocketSink {
  @override
  void add(Object? value) {}
  @override
  Future<void> close([int? code, String? reason]) async {}
}

class EventSocket extends Fake implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  int sequence = 0;
  @override
  final sink = EventSink();
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  Future<void> get ready async {}
  void emit(String method, [JsonMap params = const {}]) => incoming.add(
    jsonEncode({
      'method': method,
      'params': params,
      'epoch': 'test',
      'seq': ++sequence,
    }),
  );
}

class EventApi extends ApiClient {
  EventApi(Future<http.Response> Function(http.Request) handler)
    : super(client: MockClient(handler));
  final socket = EventSocket();
  @override
  WebSocketChannel events(String? epoch, int after) => socket;
}

app.AppController ready(ApiClient api) => app.AppController(api: api)
  ..authenticated = true
  ..connection = app.ConnectionState.connected
  ..status = {'codex': 'ready', 'threadActions': true}
  ..threads = [
    {
      'id': 'one',
      'status': {'type': 'active'},
    },
  ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('thread_actions_preserve_drafts_and_block_duplicate_submits', () async {
    final pending = Completer<http.Response>();
    final sent = Completer<void>();
    final requests = <http.Request>[];
    final c = ready(
      ApiClient(
        client: MockClient((r) {
          requests.add(r);
          sent.complete();
          return pending.future;
        }),
      ),
    );
    addTearDown(c.dispose);
    c.conversation.threadId = 'one';
    c.conversation.setDraft('未发送的草稿');
    c.conversation.references = [
      {'type': 'file', 'path': '/notes.txt'},
    ];
    final action = c.changeThreadLifecycle('one', 'close');
    await c.changeThreadLifecycle('one', 'close');
    await sent.future;
    expect(c.threadActionBusy('one'), isTrue);
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/api/threads/one/close');
    expect(
      jsonDecode(requests.single.body)['requestId'],
      matches(RegExp(r'^[a-f0-9-]{36}$')),
    );
    pending.complete(json({'state': 'closing'}));
    await action;
    expect(c.threadActionBusy('one'), isFalse);
    expect(c.threads.single['closePending'], isTrue);
    expect(asMap(c.threads.single['status'])['type'], 'active');
    expect(c.conversation.detached, isTrue);
    expect(c.conversation.canControl, isFalse);
    expect(c.conversation.draft, '未发送的草稿');
    expect(c.conversation.references.single['path'], '/notes.txt');
    await c.conversation.reload();
    expect(requests, hasLength(1));
  });

  test('archive_failure_preserves_row_and_draft_and_unknown_response_reconciles_once', () async {
    for (final accepted in [false, true]) {
      var posts = 0;
      var reads = 0;
      final c = ready(
        ApiClient(
          client: MockClient((r) async {
            if (r.method == 'POST') {
              posts++;
              return json({'detail': 'operation failed'}, accepted ? 502 : 409);
            }
            reads++;
            expect(r.url.path, startsWith('/api/operations/'));
            return json({
              'state': 'accepted',
              'result': {'state': 'archived'},
            });
          }),
        ),
      );
      c.conversation.threadId = 'one';
      c.conversation.setDraft('保留');
      if (accepted) {
        await c.changeThreadLifecycle('one', 'archive');
        expect(c.threads, isEmpty);
        expect(c.conversation.archived, isTrue);
        expect(c.conversation.canControl, isFalse);
      } else {
        await expectLater(
          c.changeThreadLifecycle('one', 'archive'),
          throwsA(isA<ApiError>()),
        );
        expect(c.threads.single['id'], 'one');
        expect(c.conversation.detached, isFalse);
      }
      expect(posts, 1);
      expect(reads, accepted ? 1 : 0);
      expect(c.conversation.draft, '保留');
      expect(c.threadActionBusy('one'), isFalse);
      c.dispose();
    }
  });

  test('unfinished_message_prevents_thread_action', () async {
    var calls = 0;
    final c = ready(
      ApiClient(
        client: MockClient((r) async {
          calls++;
          return json({});
        }),
      ),
    );
    addTearDown(c.dispose);
    c.conversation.threadId = 'one';
    c.conversation.sending = true;
    await expectLater(
      c.changeThreadLifecycle('one', 'archive'),
      throwsA(isA<ApiError>()),
    );
    expect(calls, 0);
    expect(c.threads.single['id'], 'one');
  });

  testWidgets('thread_status_refresh_does_not_overwrite_newer_events', (
    t,
  ) async {
    final pending = Completer<http.Response>();
    var lists = 0;
    final api = EventApi((r) async {
      if (++lists == 1) return pending.future;
      return json({
        'data': [
          {
            'id': 'one',
            'name': 'fresh',
            'status': {'type': 'idle'},
          },
        ],
      });
    });
    final c = ready(api);
    addTearDown(c.dispose);
    await c.connectEvents();
    api.socket.emit('stream/ready');
    await t.pump();
    api.socket.emit('thread/status/changed', {
      'threadId': 'one',
      'status': {'type': 'active'},
    });
    await t.pump();
    final load = c.loadThreads();
    api.socket.emit('thread/name/updated', {
      'threadId': 'one',
      'name': 'new name',
    });
    await t.pump();
    pending.complete(
      json({
        'data': [
          {
            'id': 'one',
            'name': 'old name',
            'status': {'type': 'idle'},
          },
        ],
      }),
    );
    await load;
    expect(c.threads.single['name'], 'new name');
    expect(asMap(c.threads.single['status'])['type'], 'idle');
    final refresh = c.loadThreads();
    api.socket.emit('thread/status/changed', {
      'threadId': 'one',
      'status': {'type': 'active'},
    });
    await t.pump();
    await refresh;
    expect(asMap(c.threads.single['status'])['type'], 'active');
    c.background();
  });

  testWidgets('native_close_event_wins_over_late_closing_response', (t) async {
    final pending = Completer<http.Response>();
    final api = EventApi((r) => pending.future);
    final c = ready(api);
    addTearDown(c.dispose);
    c.conversation.threadId = 'one';
    await c.connectEvents();
    api.socket.emit('stream/ready');
    await t.pump();
    final close = c.changeThreadLifecycle('one', 'close');
    api.socket.emit('thread/closed', {'threadId': 'one'});
    await t.pump();
    pending.complete(json({'state': 'closing'}));
    await close;
    expect(c.threads.single['closePending'], isFalse);
    expect(asMap(c.threads.single['status'])['type'], 'notLoaded');
    expect(c.conversation.detached, isTrue);
    c.background();
  });

  testWidgets(
    'archive_event_prevents_stale_list_resurrection_and_restore_updates_filter',
    (t) async {
      final pending = Completer<http.Response>();
      final api = EventApi((r) => pending.future);
      final c = ready(api);
      addTearDown(c.dispose);
      await c.connectEvents();
      api.socket.emit('stream/ready');
      await t.pump();
      final refresh = c.loadThreads();
      api.socket.emit('thread/archived', {'threadId': 'one'});
      await t.pump();
      pending.complete(
        json({
          'data': [
            {'id': 'one'},
          ],
        }),
      );
      await refresh;
      expect(c.threads, isEmpty);
      c.archivedThreads = true;
      c.threads = [
        {'id': 'one', 'archived': true},
      ];
      api.socket.emit('thread/unarchived', {'threadId': 'one'});
      await t.pump();
      expect(c.threads, isEmpty);
      c.background();
    },
  );

  testWidgets('late_thread_action_cannot_change_new_account_state', (t) async {
    final pending = Completer<http.Response>();
    final api = EventApi(
      (r) => r.method == 'POST' ? pending.future : Future.value(json({})),
    );
    final c = ready(api);
    addTearDown(c.dispose);
    await c.connectEvents();
    api.socket.emit('stream/ready');
    await t.pump();
    final archive = c.changeThreadLifecycle('one', 'archive');
    api.socket.emit('account/updated');
    await t.pump();
    pending.complete(json({'state': 'archived'}));
    await archive;
    expect(c.threads.single['id'], 'one');
    expect(c.threads.single['archived'], isNull);
    expect(c.threadActionBusy('one'), isFalse);
    c.background();
  });

  test(
    'detached_conversation_reopens_explicitly_and_ignores_old_snapshot',
    () async {
      final snapshot = Completer<http.Response>();
      final requests = <http.Request>[];
      var first = true;
      final api = ApiClient(
        client: MockClient((r) async {
          requests.add(r);
          if (first) {
            first = false;
            return snapshot.future;
          }
          if (r.url.path == '/api/threads/one') {
            expect(r.url.queryParameters['reopen'], 'true');
            return json({
              'thread': {'id': 'one'},
              'canControl': true,
              'closed': false,
            });
          }
          return json({'data': []});
        }),
      );
      final c = ConversationController(
        api,
        onError: (_) {},
        onTurnFinished: () {},
      )..threadId = 'one';
      addTearDown(c.dispose);
      addTearDown(api.close);
      c.setDraft('draft survives');
      final load = c.reload();
      c.detach('one');
      snapshot.complete(
        json({
          'thread': {'id': 'one'},
          'activeTurnId': 'old',
          'canControl': true,
        }),
      );
      await load;
      expect(c.detached, isTrue);
      expect(c.canControl, isFalse);
      expect(c.activeTurnId, isNull);
      c.handleEvent('turn/started', {
        'threadId': 'one',
        'turn': {'id': 'old'},
      });
      expect(c.activeTurnId, isNull);
      final before = requests.length;
      await c.reload();
      expect(requests, hasLength(before));
      await c.reload(reopen: true);
      expect(c.canControl, isTrue);
      expect(c.detached, isFalse);
      expect(c.draft, 'draft survives');
    },
  );
}
