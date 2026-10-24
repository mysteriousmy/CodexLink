import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart' as app;
import 'package:codex_link/ui/conversation_screen.dart';
import 'package:codex_link/ui/diff_view.dart';
import 'package:codex_link/ui/file_preview.dart';
import 'package:codex_link/ui/home_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const title = '导航回归会话';
const conversationPage = ValueKey('android-conversation-page');
const draft = '返回操作保留的草稿';

http.Response json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<app.AppController> showHome(WidgetTester t, {bool wide = false}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(wide ? 1200 : 390, 844);
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final c =
      app.AppController(
          api: ApiClient(
            client: MockClient((r) async {
              if (r.url.path.endsWith('/file')) {
                if (r.url.queryParameters['image'] == 'true') {
                  return http.Response.bytes(
                    base64Decode(
                      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
                    ),
                    200,
                    headers: {'content-type': 'image/png'},
                  );
                }
                return http.Response(
                  'preview body',
                  200,
                  headers: {'content-type': 'text/plain'},
                );
              }
              if (r.url.path.endsWith('/items')) {
                return json({
                  'data': [
                    {
                      'turnId': 'turn',
                      'item': {
                        'id': 'changed',
                        'type': 'fileChange',
                        'status': 'completed',
                        'changes': [
                          {
                            'path': 'navigation.dart',
                            'kind': {'type': 'update'},
                            'diff': '@@ -1 +1 @@\n-old navigation\n+new navigation\n',
                          },
                        ],
                      },
                    },
                  ],
                });
              }
              if (r.url.path.endsWith('/goal')) return json({'goal': null});
              return json({
                'thread': {'id': 't', 'preview': title},
              });
            }),
          ),
        )
        ..initialized = true
        ..authenticated = true
        ..connection = app.ConnectionState.connected
        ..threads = [
          {'id': 't', 'preview': title},
        ];
  addTearDown(c.dispose);
  await t.pumpWidget(
    MaterialApp(
      home: ListenableBuilder(
        listenable: c,
        builder: (context, _) => HomeScreen(controller: c),
      ),
    ),
  );
  await t.pumpAndSettle();
  return c;
}

Future<void> openConversation(WidgetTester t) async {
  await t.tap(find.text(title));
  await t.pumpAndSettle();
}

Finder get composerField => find.descendant(
  of: find.byType(Composer),
  matching: find.byType(TextField),
);

Future<void> backGesture(
  WidgetTester t,
  String method, {
  double progress = 0,
  double x = 5,
  double y = 300,
}) async {
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, {
        'touchOffset': [x, y],
        'progress': progress,
        'swipeEdge': 0,
      }),
    ),
    (_) {},
  );
  await t.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('android_entry_animates_while_web_keeps_inline_conversation', (
    t,
  ) async {
    await showHome(t);
    await t.tap(find.text(title));
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    if (kIsWeb) {
      expect(find.byKey(conversationPage), findsNothing);
      expect(
        ModalRoute.of(t.element(find.byType(ConversationScreen)))!.isFirst,
        isTrue,
      );
    } else {
      final route = ModalRoute.of(t.element(find.byKey(conversationPage)))!;
      expect(route.isFirst, isFalse);
      expect(route.animation!.value, lessThan(1));
      await t.pump(const Duration(milliseconds: 120));
      expect(route.animation!.value, inExclusiveRange(0, 1));
      await t.pumpAndSettle();
      expect(route.animation!.value, 1);
      expect(route.popGestureEnabled, isTrue);
      expect(find.byKey(const ValueKey('thread-list')), findsNothing);
      expect(
        find.byKey(const ValueKey('thread-list'), skipOffstage: false),
        findsOneWidget,
      );
    }
    await t.pumpAndSettle();
    expect(find.byType(Composer), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('wide_layout_keeps_list_and_conversation_side_by_side', (
    t,
  ) async {
    await showHome(t, wide: true);
    await openConversation(t);
    expect(find.byKey(conversationPage), findsNothing);
    expect(
      find.byKey(const ValueKey('thread-list')).hitTestable(),
      findsOneWidget,
    );
    expect(find.byType(Composer).hitTestable(), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    expect(t.takeException(), isNull);
  });

  if (!kIsWeb) {
    testWidgets('expired_login_closes_android_detail_routes', (t) async {
      final c = await showHome(t);
      await openConversation(t);
      await t.tap(find.text('navigation.dart').last);
      await t.pumpAndSettle();
      expect(find.byType(FileDiffScreen), findsOneWidget);
      c.authenticated = false;
      c.notifyListeners();
      await t.pumpAndSettle();
      expect(find.byType(FileDiffScreen), findsNothing);
      expect(find.byType(ConversationScreen), findsNothing);
      expect(find.byType(ConnectionPage), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets(
      'conversation_predictive_back_cancels_then_commits_with_draft',
      (t) async {
        final c = await showHome(t);
        await openConversation(t);
        await t.enterText(composerField, draft);
        FocusManager.instance.primaryFocus?.unfocus();
        await t.pumpAndSettle();
        final page = find.byKey(conversationPage);
        final route = ModalRoute.of(t.element(page))!;
        final before = t.getRect(page);
        await backGesture(t, 'startBackGesture');
        await backGesture(
          t,
          'updateBackGestureProgress',
          progress: .4,
          x: 160,
          y: 390,
        );
        expect(route.popGestureInProgress, isTrue);
        final preview = t.getRect(page);
        expect(preview.width, lessThan(before.width));
        expect(preview.left, greaterThan(before.left));
        expect(find.byKey(const ValueKey('thread-list')), findsOneWidget);
        await backGesture(t, 'cancelBackGesture');
        await t.pumpAndSettle();
        expect(t.getRect(page), before);
        expect(c.conversation.draft, draft);
        expect(find.byType(Composer), findsOneWidget);
        expect(route.popGestureInProgress, isFalse);
        await backGesture(t, 'startBackGesture');
        await backGesture(t, 'updateBackGestureProgress', progress: .7, x: 270);
        await backGesture(t, 'commitBackGesture');
        await t.pumpAndSettle();
        expect(page, findsNothing);
        expect(
          find.byKey(const ValueKey('thread-list')).hitTestable(),
          findsOneWidget,
        );
        expect(c.conversation.threadId, 't');
        expect(c.conversation.draft, draft);
        await openConversation(t);
        expect(t.widget<TextField>(composerField).controller!.text, draft);
        expect(t.takeException(), isNull);
      },
    );

    testWidgets('diff_predictive_back_returns_to_same_conversation', (t) async {
      final c = await showHome(t);
      await openConversation(t);
      await t.enterText(composerField, draft);
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pumpAndSettle();
      await t.tap(find.text('navigation.dart').last);
      await t.pumpAndSettle();
      final diff = find.byType(FileDiffScreen);
      final route = ModalRoute.of(t.element(diff))!;
      expect(route.popGestureEnabled, isTrue);
      final before = t.getRect(diff);
      await backGesture(t, 'startBackGesture');
      await backGesture(t, 'updateBackGestureProgress', progress: .35, x: 150);
      expect(t.getRect(diff).width, lessThan(before.width));
      expect(find.byType(ConversationScreen), findsOneWidget);
      await backGesture(t, 'cancelBackGesture');
      await t.pumpAndSettle();
      expect(t.getRect(diff), before);
      expect(find.text('new navigation'), findsOneWidget);
      await backGesture(t, 'startBackGesture');
      await backGesture(t, 'updateBackGestureProgress', progress: .7, x: 270);
      await backGesture(t, 'commitBackGesture');
      await t.pumpAndSettle();
      expect(diff, findsNothing);
      expect(find.byKey(conversationPage), findsOneWidget);
      expect(t.widget<TextField>(composerField).controller!.text, draft);
      expect(c.conversation.threadId, 't');
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('thread-list')), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('system_back_closes_image_preview_before_conversation', (
      t,
    ) async {
      final c = await showHome(t);
      await openConversation(t);
      final page = find.byKey(conversationPage);
      final route = ModalRoute.of(t.element(page))!;
      unawaited(
        showFilePreview(
          t.element(find.byType(ConversationScreen)),
          c.conversation,
          c.api.uri('/api/threads/t/file', {'image': 'true'}),
          'preview.png',
          (error) => fail('$error'),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      await backGesture(t, 'startBackGesture');
      await backGesture(t, 'updateBackGestureProgress', progress: .5, x: 200);
      // A preview owns back; the covered conversation must not start popping.
      expect(route.popGestureInProgress, isFalse);
      await backGesture(t, 'commitBackGesture');
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(page, findsOneWidget);
      expect(find.byType(Composer), findsOneWidget);
      expect(c.conversation.threadId, 't');
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('system_back_closes_preview_and_sheet_before_conversation', (
    t,
  ) async {
    final c = await showHome(t);
    final systemPops = <MethodCall>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') systemPops.add(call);
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await openConversation(t);
    await t.enterText(composerField, draft);
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pumpAndSettle();
    unawaited(
      showFilePreview(
        t.element(find.byType(ConversationScreen)),
        c.conversation,
        c.api.uri('/api/threads/t/file'),
        'preview.txt',
        (error) => fail('$error'),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('preview body'), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(Composer), findsOneWidget);
    expect(c.conversation.draft, draft);
    expect(systemPops, isEmpty);
    await t.tap(find.byTooltip('会话附件'));
    await t.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(Composer), findsOneWidget);
    expect(systemPops, isEmpty);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('thread-list')), findsOneWidget);
    expect(systemPops, isEmpty);
    expect(c.conversation.draft, draft);
    await t.binding.handlePopRoute();
    expect(systemPops, hasLength(1));
    expect(t.takeException(), isNull);
  });
}
