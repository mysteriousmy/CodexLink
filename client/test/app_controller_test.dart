import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('runtime_start_is_shared_by_callers_and_failure_can_retry', () async {
    final start = Completer<http.Response>();
    var calls = 0;
    final c = AppController(
      api: ApiClient(
        client: MockClient((r) async {
          expect(r.url.path, '/api/runtime/start');
          calls++;
          if (calls == 1) return start.future;
          return http.Response(
            '{"codex":"ready","codexTransport":"shared"}',
            200,
          );
        }),
      ),
    )..authenticated = true;
    addTearDown(c.dispose);
    c.status = {'onDemandRuntime': true, 'codex': 'idle'};
    final first = c.ensureRuntime();
    final second = c.ensureRuntime();
    expect(c.startingRuntime, isTrue);
    expect(c.connectionLabel, '正在启动 Codex');
    final firstCheck = expectLater(first, throwsA(isA<ApiError>()));
    final secondCheck = expectLater(second, throwsA(isA<ApiError>()));
    start.complete(http.Response('{"detail":"CLI unavailable"}', 503));
    await Future.wait([firstCheck, secondCheck]);
    expect(calls, 1);
    expect(c.startingRuntime, isFalse);
    expect(c.connection, ConnectionState.codexUnavailable);
    expect(c.threadListError, 'CLI unavailable');
    await c.ensureRuntime();
    expect(calls, 2);
    expect(c.status['codex'], 'ready');
    expect(c.status['codexTransport'], 'shared');
    expect(c.status['codexError'], isNull);
    await c.ensureRuntime();
    expect(calls, 2);
  });

  test(
    'late project response cannot replace a newly selected project',
    () async {
      final first = Completer<http.Response>();
      final api = ApiClient(
        client: MockClient((r) async {
          if (r.url.queryParameters['projectId'] == 'first') {
            return first.future;
          }
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'second-thread'},
              ],
            }),
            200,
          );
        }),
      );
      final app = AppController(api: api)..authenticated = true;
      final pending = app.selectProject('first');
      await app.selectProject('second');
      first.complete(http.Response('{"data":[{"id":"first-thread"}]}', 200));
      await pending;
      expect(app.projectId, 'second');
      expect(app.threads.single['id'], 'second-thread');
      app.dispose();
    },
  );
  test(
    'default list includes all local threads and preserves pagination filters',
    () async {
      final queries = <Map<String, String>>[];
      final api = ApiClient(
        client: MockClient((r) async {
          queries.add(r.url.queryParameters);
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': r.url.queryParameters.containsKey('cursor')
                      ? 'second'
                      : 'first',
                },
              ],
              'nextCursor': r.url.queryParameters.containsKey('cursor')
                  ? null
                  : 'next',
            }),
            200,
          );
        }),
      );
      final c = AppController(api: api)..authenticated = true;
      await c.loadThreads();
      expect(queries.first.containsKey('projectId'), isFalse);
      await c.loadThreads(more: true);
      expect(queries.last['cursor'], 'next');
      expect(c.threads.map((t) => t['id']), ['first', 'second']);
      await c.searchThreads('keyword');
      expect(queries.last['search'], 'keyword');
      await c.showArchivedThreads(true);
      expect(queries.last['archived'], 'true');
      c.dispose();
    },
  );
}
