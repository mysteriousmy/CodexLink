import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class FixtureSink extends Fake implements WebSocketSink {
  bool closed = false;
  final messages = <Object?>[];
  @override
  void add(Object? value) => messages.add(value);
  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }
}

class FixtureSocket extends Fake implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  @override
  final FixtureSink sink = FixtureSink();
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  Future<void> get ready async {}
  void event(String method) => incoming.add(
    jsonEncode({'method': method, 'epoch': 'fixture', 'seq': 1}),
  );
}

class FixtureApi extends ApiClient {
  FixtureApi(Future<http.Response> Function(http.Request) handler)
    : super(client: MockClient(handler));
  final sockets = <FixtureSocket>[];
  final epochs = <String?>[];
  @override
  WebSocketChannel events(String? epoch, int after) {
    epochs.add(epoch);
    final socket = FixtureSocket();
    sockets.add(socket);
    return socket;
  }
}

Future<void> ready(
  WidgetTester t,
  FixtureApi api, {
  bool resync = false,
}) async {
  api.sockets.last.event(resync ? 'stream/resync' : 'stream/replay');
  api.sockets.last.event('stream/ready');
  await t.pump();
}

app.AppController controller(FixtureApi api) => app.AppController(api: api)
  ..authenticated = true
  ..initialized = true
  ..status = {'codex': 'ready'};

class LifecycleController extends app.AppController {
  int resumes = 0;
  int suspends = 0;
  @override
  Future<void> initialize() async => initialized = true;
  @override
  Future<void> foreground() async => resumes++;
  @override
  void background() => suspends++;
}

void main() {
  for (final outcome in ['timeout', 'unauthorized', 'success']) {
    testWidgets('stale_retry_${outcome}_cannot_replace_resumed_connection', (
      t,
    ) async {
      final old = Completer<http.Response>();
      var statusCalls = 0;
      final api = FixtureApi((r) async {
        if (r.url.path == '/api/status' && ++statusCalls == 1) {
          return old.future;
        }
        return json({'codex': 'ready'});
      });
      final c = controller(api);
      addTearDown(c.dispose);
      await c.connectEvents();
      await ready(t, api);
      await api.sockets.single.incoming.close();
      await t.pump(const Duration(seconds: 2));
      expect(statusCalls, 1);
      await c.foreground();
      await ready(t, api, resync: true);
      expect(c.connection, app.ConnectionState.connected);
      expect(api.sockets, hasLength(2));
      switch (outcome) {
        case 'timeout':
          old.completeError(http.ClientException('Connection timed out'));
        case 'unauthorized':
          old.complete(json({'detail': 'stale login rejection'}, 401));
        case 'success':
          old.complete(json({'codex': 'stopped'}));
      }
      await t.pump();
      await t.pump(const Duration(seconds: 3));
      expect(c.error.value, isNull);
      expect(c.authenticated, isTrue);
      expect(c.status['codex'], 'ready');
      expect(c.connection, app.ConnectionState.connected);
      expect(api.sockets, hasLength(2));
      expect(api.sockets.last.sink.closed, isFalse);
      c.background();
    });
  }

  testWidgets('background_defers_network_and_resume_reconciles_task', (
    t,
  ) async {
    final requests = <String>[];
    final api = FixtureApi((r) async {
      requests.add(r.url.path);
      return json(switch (r.url.path) {
        '/api/status' => {'codex': 'ready'},
        '/api/threads/task' => {
          'thread': {'id': 'task'},
          'activeTurnId': null,
          'canControl': true,
        },
        '/api/threads/task/items' => {
          'data': [
            {
              'turnId': 'finished',
              'item': {
                'id': 'answer',
                'type': 'agentMessage',
                'text': 'Completed while asleep',
              },
            },
          ],
        },
        _ => {},
      });
    });
    final c = controller(api);
    addTearDown(c.dispose);
    c.conversation
      ..threadId = 'task'
      ..activeTurnId = 'finished'
      ..draft = 'Keep my draft';
    await c.connectEvents();
    await ready(t, api);
    c.background();
    c.background();
    expect(api.sockets.single.sink.closed, isTrue);
    await c.connectEvents();
    await t.pump(const Duration(minutes: 2));
    expect(requests, isEmpty);
    expect(api.sockets, hasLength(1));
    expect(api.sockets.single.sink.messages, isEmpty);
    await c.foreground();
    expect(api.epochs.last, isNull);
    await ready(t, api, resync: true);
    expect(c.connection, app.ConnectionState.connected);
    expect(c.conversation.activeTurnId, isNull);
    expect(c.conversation.draft, 'Keep my draft');
    expect(c.conversation.items.single.text, 'Completed while asleep');
    expect(
      requests,
      containsAll([
        '/api/status',
        '/api/threads/task',
        '/api/threads/task/items',
        '/api/threads/task/goal',
      ]),
    );
    c.background();
  });

  testWidgets('current_retry_unauthorized_requires_login', (t) async {
    var calls = 0;
    final api = FixtureApi((r) async {
      calls++;
      return json({'detail': '请重新登录'}, 401);
    });
    final c = controller(api);
    addTearDown(c.dispose);
    await c.connectEvents();
    await ready(t, api);
    await api.sockets.single.incoming.close();
    await t.pump(const Duration(seconds: 2));
    expect(c.connection, app.ConnectionState.loginRequired);
    expect(c.authenticated, isFalse);
    expect(c.error.value, '请重新登录');
    await t.pump(const Duration(minutes: 2));
    expect(calls, 1);
    expect(api.sockets, hasLength(1));
  });

  testWidgets('background_cancels_scheduled_reconnect', (t) async {
    var calls = 0;
    final api = FixtureApi((r) async {
      calls++;
      return json({'codex': 'ready'});
    });
    final c = controller(api);
    addTearDown(c.dispose);
    await c.connectEvents();
    await ready(t, api);
    await api.sockets.single.incoming.close();
    expect(c.connection, app.ConnectionState.offline);
    c.background();
    await t.pump(const Duration(minutes: 2));
    expect(calls, 0);
    expect(api.sockets, hasLength(1));
    expect(c.error.value, isNull);
  });

  testWidgets('retry_timeout_recovers_without_error_snackbar', (t) async {
    var calls = 0;
    final api = FixtureApi((r) async {
      if (++calls == 1) throw TimeoutException('network suspended');
      return json({'codex': 'ready'});
    });
    final c = controller(api);
    addTearDown(c.dispose);
    await c.connectEvents();
    await ready(t, api);
    await api.sockets.single.incoming.close();
    await t.pump(const Duration(seconds: 2));
    expect(c.connection, app.ConnectionState.offline);
    expect(c.error.value, isNull);
    await t.pump(const Duration(seconds: 3));
    await ready(t, api);
    expect(calls, 2);
    expect(c.connection, app.ConnectionState.connected);
    expect(c.error.value, isNull);
    c.background();
  });

  testWidgets('stale_resync_failure_cannot_disconnect_new_session', (t) async {
    final old = Completer<http.Response>();
    var statusCalls = 0;
    final api = FixtureApi((r) async {
      if (r.url.path == '/api/status' && ++statusCalls == 1) {
        return old.future;
      }
      return json({'codex': 'ready'});
    });
    final c = controller(api);
    addTearDown(c.dispose);
    await c.connectEvents();
    await ready(t, api, resync: true);
    expect(c.connection, app.ConnectionState.syncing);
    c.background();
    await c.foreground();
    await ready(t, api, resync: true);
    expect(c.connection, app.ConnectionState.connected);
    old.completeError(TimeoutException('old snapshot'));
    await t.pump();
    await t.pump(const Duration(seconds: 3));
    expect(c.error.value, isNull);
    expect(c.connection, app.ConnectionState.connected);
    expect(api.sockets, hasLength(2));
    c.background();
  });

  testWidgets('failed_resync_retries_with_full_snapshot', (t) async {
    final calls = <String>[];
    final api = FixtureApi((r) async {
      calls.add(r.url.path);
      if (calls.length == 1) throw http.ClientException('connection closed');
      if (r.url.path == '/api/threads') {
        return json({
          'data': [
            {
              'id': 'running',
              'status': {'type': 'active'},
            },
          ],
        });
      }
      return json({'codex': 'ready'});
    });
    final c = controller(api);
    addTearDown(c.dispose);
    await c.connectEvents();
    await ready(t, api, resync: true);
    expect(c.connection, app.ConnectionState.offline);
    expect(c.error.value, isNull);
    await t.pump(const Duration(seconds: 2));
    expect(api.epochs.last, isNull);
    await ready(t, api, resync: true);
    expect(c.connection, app.ConnectionState.connected);
    expect(calls, [
      '/api/status',
      '/api/status',
      '/api/status',
      '/api/threads',
    ]);
    expect(c.threads.single['id'], 'running');
    expect(asMap(c.threads.single['status'])['type'], 'active');
    c.background();
  });

  testWidgets('disposed_connection_ignores_pending_retry_failure', (t) async {
    final pending = Completer<http.Response>();
    final api = FixtureApi((r) => pending.future);
    final c = controller(api);
    await c.connectEvents();
    await ready(t, api);
    await api.sockets.single.incoming.close();
    await t.pump(const Duration(seconds: 2));
    c.dispose();
    pending.completeError(TimeoutException('disposed request'));
    await t.pump();
    await t.pump(const Duration(minutes: 2));
    expect(t.takeException(), isNull);
    expect(api.sockets, hasLength(1));
  });

  testWidgets('app_forwards_suspension_and_resume_but_not_focus_loss', (
    t,
  ) async {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final c = LifecycleController();
    await t.pumpWidget(CodexLinkApp(controller: c));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(c.suspends, 0);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(c.suspends, greaterThan(0));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(c.resumes, 1);
    await t.pumpWidget(const SizedBox());
  });
}
