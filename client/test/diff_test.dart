import 'dart:convert';
import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/conversation_controller.dart';
import 'package:codex_link/data/file_diff.dart';
import 'package:codex_link/ui/diff_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const patch = 'diff --git a/main.dart b/main.dart\n--- a/main.dart\n+++ b/main.dart\n@@ -10,2 +10,3 @@\n context\n-old value\n+new value\n+another value\n';

void main() {
  test('diff parsing distinguishes additions deletions hunks and line numbers', () {
    final file = parseUnifiedDiff(patch).single;
    expect(file.path, 'main.dart'); expect(file.additions, 2); expect(file.deletions, 1);
    final removed = file.lines.singleWhere((l) => l.kind == DiffLineKind.deletion);
    expect(removed.oldLine, 11); expect(removed.newLine, isNull);
    final added = file.lines.where((l) => l.kind == DiffLineKind.addition).toList();
    expect(added.map((l) => l.newLine), [11,12]);
    expect(file.lines.where((l) => l.kind == DiffLineKind.hunk).length, 1);
    final modes = parseUnifiedDiff('diff --git a/old b/new\nsimilarity index 100%\nrename from old\nrename to new\n'
      'diff --git a/gone b/gone\ndeleted file mode 100644\n--- a/gone\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye\n');
    expect(modes.first.path, 'new'); expect(modes.first.previousPath, 'old');
    expect(modes.last.kind, 'delete'); expect(modes.last.path, 'gone');
    expect(FileDiff(path:'new.txt',kind:'add',diff:'one\ntwo\n').additions,2);
  });

  test('live and final turn diff stays available with history fallback', () async {
    final api = ApiClient(client: MockClient((r) async => http.Response(jsonEncode(
      r.url.path.endsWith('/items') ? {'data':[{'turnId':'history-turn','item':{'id':'history-file','type':'fileChange','status':'completed','changes':[{'path':'old.txt','kind':{'type':'add'},'diff':'+old history'}]}}]}
      : r.url.path.endsWith('/goal') ? {'goal':null} : {'thread':{'id':'t'},'activeTurnId':null}),200)));
    final c = ConversationController(api, onError: (e) => fail('$e'), onTurnFinished: () {})..threadId='t';
    addTearDown(c.dispose);
    await c.reload();
    expect(c.items.last.type, 'turnDiff'); expect(c.items.last.fileDiffs.single.path, 'old.txt');
    c.handleEvent('turn/started', {'threadId':'t','turn':{'id':'live'}});
    c.handleEvent('turn/diff/updated', {'threadId':'t','turnId':'live','diff':patch});
    final summary = c.items.last;
    expect(summary.streaming, isTrue); expect(summary.fileDiffs.single.additions, 2);
    c.handleEvent('item/completed', {'threadId':'t','turnId':'live','item':{'id':'final','type':'agentMessage','text':'Done'}});
    c.handleEvent('turn/completed', {'threadId':'t','turn':{'id':'live','status':'completed'}});
    expect(c.items.last, same(summary)); expect(summary.streaming,isFalse);
    expect(summary.fileDiffs.single.deletions,1);
  });

  testWidgets('file click opens full screen colored diff', (t) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(body: FileDiffCard(files:parseUnifiedDiff(patch)))));
    await t.tap(find.text('main.dart')); await t.pumpAndSettle();
    expect(find.byType(FileDiffScreen), findsOneWidget);
    expect(t.getSize(find.byType(FileDiffScreen)), t.view.physicalSize / t.view.devicePixelRatio);
    final addition=t.widget<Text>(find.text('new value')).style!;
    final deletion=t.widget<Text>(find.text('old value')).style!;
    expect(addition.color,isNot(deletion.color));
    expect(find.byTooltip('复制 Diff'), findsOneWidget);
    await t.tap(find.byType(CloseButton)); await t.pumpAndSettle();
    expect(find.byType(FileDiffScreen), findsNothing);
    expect(t.takeException(),isNull);
  });
}
