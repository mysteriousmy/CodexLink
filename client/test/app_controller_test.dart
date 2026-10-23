import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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
