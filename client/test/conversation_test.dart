import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/conversation_controller.dart';
import 'package:codex_link/data/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ApiClient api;
  late ConversationController c;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  void setup(Future<http.Response> Function(http.Request) handler) {
    api = ApiClient(client: MockClient(handler));
    c = ConversationController(api, onError: (_) {}, onTurnFinished: () {})
      ..threadId = 'thread';
  }

  tearDown(() {
    c.dispose();
    api.close();
  });
  test(
    'goal send preserves rejected drafts and cancels back to normal messages',
    () async {
      final calls = <http.Request>[];
      setup((r) async {
        calls.add(r);
        return http.Response(
          r.method == 'PUT' ? '{"detail":"目标不可用"}' : '{}',
          r.method == 'PUT' ? 409 : 200,
          headers: {'content-type':'application/json; charset=utf-8'},
        );
      });
      c.setDraft('目标草稿');
      c.setGoalMode(true);
      expect(await c.send(), isFalse);
      expect(c.goalMode, isTrue);
      expect(c.draft, '目标草稿');
      expect(c.uncertain, isFalse);
      c.setGoalMode(false);
      expect(await c.send(), isTrue);
      expect(calls.map((r) => r.method), ['PUT', 'POST']);
      expect(calls.last.url.path, '/api/threads/thread/turns');
      expect(jsonDecode(calls.last.body)['text'], '目标草稿');
      expect(c.draft, isEmpty);
    },
  );
  test(
    'uncertain goal submission reconciles native state without resending',
    () async {
      var puts = 0;
      setup((r) async {
        if (r.method == 'PUT') {
          puts++;
          return http.Response('{}', 502);
        }
        return http.Response(
          jsonEncode(
            r.url.path.endsWith('/goal')
                ? {
                    'goal': {'objective': '明确目标', 'status': 'complete'},
                  }
                : r.url.path.endsWith('/items')
                ? {'data': []}
                : {
                    'thread': {'id': 'thread'},
                  },
          ),
          200,
          headers: {'content-type':'application/json; charset=utf-8'},
        );
      });
      c.setDraft('明确目标');
      c.setGoalMode(true);
      expect(await c.send(), isFalse);
      expect(c.uncertain, isTrue);
      expect(c.draft, '明确目标');
      expect(await c.send(), isFalse);
      expect(puts, 1);
      await c.reconcile();
      expect(puts, 1);
      expect(c.uncertain, isFalse);
      expect(c.draft, isEmpty);
      expect(c.goalMode, isFalse);
      expect(c.goal?['status'], 'complete');
    },
  );
  test(
    'goal submission keeps newer text and does not silently consume references',
    () async {
      final pending = Completer<http.Response>();
      var calls = 0;
      setup((r) {
        calls++;
        return pending.future;
      });
      c.setDraft('原目标');
      c.setGoalMode(true);
      c.references = [
        {'type': 'file', 'name': 'plan.md', 'path': '/project/plan.md'},
      ];
      expect(await c.send(), isFalse);
      expect(calls, 0);
      expect(c.references.length, 1);
      expect(c.draft, '原目标');
      c.references = [];
      final accepted = c.send();
      c.setDraft('下一条草稿');
      pending.complete(
        http.Response('{"goal":{"objective":"原目标","status":"active"}}', 200,
          headers: {'content-type':'application/json; charset=utf-8'}),
      );
      expect(await accepted, isTrue);
      expect(calls, 1);
      expect(c.draft, '下一条草稿');
      expect(c.goalMode, isTrue);
    },
  );
  test('context uses latest usage and preserves unknown values', () {
    setup((_) async => http.Response('{}', 200));
    final u = TokenUsage.fromJson({
      'total': {'totalTokens': 900000},
      'last': {'totalTokens': 25000},
      'modelContextWindow': 100000,
    });
    expect(u.total, 900000);
    expect(u.fraction, .25);
    expect(TokenUsage.fromJson({}).fraction, isNull);
    expect(
      TokenUsage.fromJson({
        'last': {'totalTokens': 5},
        'modelContextWindow': 0,
      }).fraction,
      isNull,
    );
  });
  test('snapshot plus replayed Unicode deltas never duplicate text', () async {
    setup((_) async => http.Response('{}', 200));
    c.handleEvent('item/started', {
      'threadId': 'thread',
      'turnId': 'turn',
      'item': {'id': 'item', 'type': 'agentMessage', 'text': 'Hello 世界'},
    });
    for (final d in [(0, 'Hello '), (6, '世界!')]) {
      c.handleEvent('item/agentMessage/delta', {
        'threadId': 'thread',
        'turnId': 'turn',
        'itemId': 'item',
        'clientOffset': d.$1,
        'delta': d.$2,
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.items.single.text, 'Hello 世界!');
  });
  test(
    '100 streaming deltas repaint one item once without rebuilding page',
    () async {
      setup((_) async => http.Response('{}', 200));
      c.handleEvent('item/started', {
        'threadId': 'thread',
        'turnId': 'turn',
        'item': {'id': 'item', 'type': 'agentMessage', 'text': ''},
      });
      var pages = 0, items = 0;
      c.addListener(() => pages++);
      c.items.single.addListener(() => items++);
      for (var i = 0; i < 100; i++) {
        c.handleEvent('item/agentMessage/delta', {
          'threadId': 'thread',
          'turnId': 'turn',
          'itemId': 'item',
          'clientOffset': i,
          'delta': 'x',
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 55));
      expect(pages, 0);
      expect(items, 1);
      expect(c.items.single.text.length, 100);
    },
  );
  test(
    'accepted message preserves newer draft while request was in flight',
    () async {
      final response = Completer<http.Response>();
      setup((_) => response.future);
      c.setDraft('first');
      final pending = c.send();
      c.setDraft('next draft');
      response.complete(http.Response('{}', 200));
      expect(await pending, isTrue);
      expect(c.draft, 'next draft');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'draft:${api.base.origin}:thread',
        ),
        'next draft',
      );
    },
  );
  test(
    'timeout preserves draft and reconciliation never auto retries',
    () async {
      var posts = 0;
      setup((r) async {
        if (r.method == 'POST') {
          posts++;
          throw const ApiError('timeout', status: 504);
        }
        return http.Response(
          r.url.path.contains('operations')
              ? '{"state":"unknown"}'
              : r.url.path.endsWith('/items')
              ? '{"data":[]}'
              : '{}',
          200,
        );
      });
      c.setDraft('do work');
      expect(await c.send(), isFalse);
      expect(c.uncertain, isTrue);
      expect(c.draft, 'do work');
      await c.reconcile();
      expect(posts, 1);
      expect(c.uncertain, isTrue);
      await expectLater(c.retrySameRequest(), throwsA(isA<ApiError>()));
      expect(posts, 1);
    },
  );
  test('steer targets current turn and conflict preserves draft', () async {
    String? path;
    setup((r) async {
      path = r.url.path;
      return http.Response(
        '{"detail":"turn changed","code":"turn_changed"}',
        409,
      );
    });
    c.activeTurnId = 'turn-a';
    c.setDraft('new direction');
    expect(await c.send(), isFalse);
    expect(path, '/api/threads/thread/turns/turn-a/steer');
    expect(c.uncertain, isFalse);
    expect(c.draft, 'new direction');
  });
  test('goal budget omission differs from explicitly unlimited', () async {
    final bodies = <JsonMap>[];
    setup((r) async {
      bodies.add(asMap(jsonDecode(r.body)));
      return http.Response('{"goal":{"status":"paused"}}', 200);
    });
    await c.setGoal(status: 'paused');
    await c.setGoal(status: 'active', budgetSpecified: true);
    expect(bodies[0]['budgetSpecified'], isFalse);
    expect(bodies[1]['budgetSpecified'], isTrue);
    expect(bodies[1]['tokenBudget'], isNull);
  });
  test('HTTP 502 is uncertain and keeps the original draft', () async {
    setup((_) async => http.Response('{"detail":"upstream closed"}', 502));
    c.setDraft('must not repeat');
    expect(await c.send(), isFalse);
    expect(c.uncertain, isTrue);
    expect(c.draft, 'must not repeat');
    expect(c.pendingRequestId, isNotNull);
  });
  test('late accepted send cannot clear a new login draft', () async {
    final response = Completer<http.Response>();
    setup((_) => response.future);
    c.setDraft('old submission');
    final pending = c.send();
    c.reset();
    c.threadId = 'new-thread';
    c.setDraft('new account draft');
    response.complete(http.Response('{}', 200));
    await pending;
    expect(c.draft, 'new account draft');
    expect(c.threadId, 'new-thread');
  });
  test(
    'reset clears private state and ignores late history response',
    () async {
      final response = Completer<http.Response>();
      setup((_) => response.future);
      final pending = c.reload();
      c.reset();
      response.complete(http.Response('{"thread":{"id":"old"}}', 200));
      await pending;
      expect(c.threadId, isNull);
      expect(c.thread, isEmpty);
      expect(c.items, isEmpty);
    },
  );
  test(
    'history reload retains intermediate commentary and later final events',
    () async {
      final snapshot = Completer<http.Response>();
      setup((r) async {
        if (r.url.path == '/api/threads/thread') return snapshot.future;
        if (r.url.path.endsWith('/items')) {
          return http.Response(
            '{"data":[{"turnId":"t","item":{"id":"progress","type":"agentMessage","phase":"commentary","text":"older"}}]}',
            200,
          );
        }
        return http.Response('{}', 200);
      });
      final reload = c.reload();
      c.handleEvent('item/completed', {
        'threadId': 'thread',
        'turnId': 't',
        'item': {
          'id': 'progress',
          'type': 'agentMessage',
          'phase': 'commentary',
          'text': 'new progress',
        },
      });
      c.handleEvent('item/completed', {
        'threadId': 'thread',
        'turnId': 't',
        'item': {
          'id': 'final',
          'type': 'agentMessage',
          'phase': 'final_answer',
          'text': 'finished',
        },
      });
      c.handleEvent('turn/completed', {
        'threadId': 'thread',
        'turn': {'id': 't', 'status': 'completed'},
      });
      snapshot.complete(
        http.Response('{"thread":{"id":"thread"},"activeTurnId":"t"}', 200),
      );
      await reload;
      expect(c.items.map((i) => i.text), ['new progress', 'finished']);
      expect(c.items.first.data['phase'], 'commentary');
      expect(c.items.every((i) => !i.streaming), isTrue);
      expect(c.activeTurnId, isNull);
    },
  );
  test(
    'skill and file selections travel with steer and clear only on acceptance',
    () async {
      JsonMap? body;
      setup((r) async {
        body = asMap(jsonDecode(r.body));
        return http.Response('{}', 200);
      });
      c.activeTurnId = 'running';
      c.addReference({
        'type': 'skill',
        'name': 'review',
        'path': '/repo/SKILL.md',
      });
      c.addReference({
        'type': 'file',
        'name': 'main.dart',
        'path': '/repo/main.dart',
      });
      c.setDraft('review this');
      expect(await c.send(), isTrue);
      expect(asMaps(body?['references']).map((r) => r['type']), [
        'skill',
        'file',
      ]);
      expect(c.references, isEmpty);
    },
  );
}
