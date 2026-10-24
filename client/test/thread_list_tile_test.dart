import 'package:codex_link/ui/thread_list_tile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('running_thread_uses_distinct_color_and_label', (t) async {
    for (final brightness in Brightness.values) {
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: Column(
              children: [
                ThreadListTile(
                  id: 'active',
                  title: '正在编写',
                  subtitle: '项目 · 今天',
                  running: true,
                  selected: true,
                  revealed: false,
                  onReveal: (_) {},
                  onOpen: () {},
                  onArchive: () {},
                  onClose: () {},
                ),
                ThreadListTile(
                  id: 'idle',
                  title: '历史记录',
                  subtitle: '项目 · 昨天',
                  running: false,
                  selected: false,
                  revealed: false,
                  onReveal: (_) {},
                  onOpen: () {},
                  onArchive: () {},
                  onClose: null,
                ),
              ],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final active = t.widget<Material>(
        find.byKey(const ValueKey('thread-surface-active')),
      );
      final idle = t.widget<Material>(
        find.byKey(const ValueKey('thread-surface-idle')),
      );
      expect(active.color, isNot(idle.color));
      expect(active.color!.a, greaterThan(0));
      expect(find.text('运行中 · 项目 · 今天'), findsOneWidget);
      expect(find.textContaining('运行中'), findsOneWidget);
      expect(active.shape, isA<RoundedRectangleBorder>());
      expect(
        (active.shape as RoundedRectangleBorder).side.style,
        BorderStyle.solid,
      );
      expect(t.takeException(), isNull);
    }
  });

  if (kIsWeb) {
    testWidgets('right_swipe_reveals_archive_and_running_close', (t) async {
      t.view.physicalSize = const Size(320, 568);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final calls = <String>[];
      var open = false;
      var running = true;
      var closing = false;
      late StateSetter update;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return ThreadListTile(
                  id: 'one',
                  title: '很长的会话标题用于检验小屏幕',
                  subtitle: '项目 · 来源\n今天',
                  running: running,
                  closing: closing,
                  selected: false,
                  revealed: open,
                  onReveal: (value) => setState(() => open = value),
                  onOpen: () => calls.add('open'),
                  onArchive: () => calls.add('archive'),
                  onClose: () => calls.add('close'),
                );
              },
            ),
          ),
        ),
      );
      expect(find.byTooltip('归档会话').hitTestable(), findsNothing);
      await t.drag(
        find.byKey(const ValueKey('thread-open-one')),
        const Offset(150, 0),
      );
      await t.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.byTooltip('归档会话').hitTestable(), findsOneWidget);
      expect(find.byTooltip('关闭会话').hitTestable(), findsOneWidget);
      expect(t.getCenter(find.byTooltip('关闭会话')).dx, greaterThan(250));
      await t.tap(find.byTooltip('归档会话'));
      await t.pumpAndSettle();
      expect(calls, ['archive']);
      await t.tap(find.byTooltip('关闭会话'));
      expect(calls, ['archive', 'close']);
      update(() => closing = true);
      await t.pumpAndSettle();
      expect(find.byTooltip('关闭会话'), findsNothing);
      expect(find.textContaining('等待卸载'), findsOneWidget);
      update(() {
        running = false;
        closing = false;
      });
      await t.pumpAndSettle();
      expect(find.byTooltip('关闭会话'), findsNothing);
      expect(find.byTooltip('归档会话').hitTestable(), findsOneWidget);
      await t.drag(
        find.byKey(const ValueKey('thread-open-one')),
        const Offset(-130, 0),
      );
      await t.pumpAndSettle();
      expect(find.byTooltip('归档会话').hitTestable(), findsNothing);
      expect(t.takeException(), isNull);
    });
  }

  if (kIsWeb) {
    testWidgets('mouse_hover_and_keyboard_reveal_thread_actions', (t) async {
      final calls = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 340,
                child: ThreadListTile(
                  id: 'one',
                  title: '会话',
                  subtitle: '项目 · 今天',
                  running: true,
                  selected: false,
                  revealed: false,
                  onReveal: (_) {},
                  onOpen: () => calls.add('open'),
                  onArchive: () => calls.add('archive'),
                  onClose: () => calls.add('close'),
                ),
              ),
            ),
          ),
        ),
      );
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(500, 200));
      addTearDown(mouse.removePointer);
      await t.pumpAndSettle();
      expect(find.byTooltip('归档会话').hitTestable(), findsNothing);
      await mouse.moveTo(const Offset(150, 35));
      await t.pumpAndSettle();
      expect(find.byTooltip('关闭会话').hitTestable(), findsOneWidget);
      await t.tap(find.byTooltip('关闭会话'));
      expect(calls, ['close']);
      await mouse.moveTo(const Offset(500, 200));
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pumpAndSettle();
      expect(find.byTooltip('归档会话').hitTestable(), findsNothing);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      expect(find.byTooltip('归档会话').hitTestable(), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(calls, ['close', 'archive']);
      expect(t.takeException(), isNull);
    });
  }

  if (!kIsWeb) {
    testWidgets('native_long_press_actions_cancel_and_live_state', (t) async {
      t.view.physicalSize = const Size(320, 568);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final calls = <String>[];
      var running = true;
      var busy = false;
      var archived = false;
      late StateSetter update;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return ThreadListTile(
                  id: 'one',
                  title: '会话标题',
                  subtitle: '项目 · 今天',
                  running: running,
                  selected: false,
                  revealed: false,
                  busy: busy,
                  archived: archived,
                  onReveal: (_) => calls.add('reveal'),
                  onOpen: () => calls.add('open'),
                  onArchive: () => calls.add(archived ? 'restore' : 'archive'),
                  onClose: () => calls.add('close'),
                );
              },
            ),
          ),
        ),
      );
      final tile = find.byKey(const ValueKey('thread-open-one'));
      await t.drag(tile, const Offset(150, 0));
      await t.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.text('归档会话'), findsNothing);
      await t.longPress(tile);
      await t.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.text('归档会话'), findsOneWidget);
      expect(find.text('关闭会话'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls, isEmpty);
      await t.longPress(tile);
      await t.pumpAndSettle();
      await t.tap(find.text('归档会话'));
      await t.pumpAndSettle();
      expect(calls, ['archive']);
      await t.longPress(tile);
      await t.pumpAndSettle();
      await t.tap(find.text('关闭会话'));
      await t.pumpAndSettle();
      expect(calls, ['archive', 'close']);
      await t.longPress(tile);
      await t.pumpAndSettle();
      update(() {
        running = false;
        archived = true;
      });
      await t.pumpAndSettle();
      expect(find.text('关闭会话'), findsNothing);
      expect(find.text('归档会话'), findsNothing);
      await t.tap(find.text('恢复会话'));
      await t.pumpAndSettle();
      expect(calls, ['archive', 'close', 'restore']);
      update(() => busy = true);
      await t.pump();
      await t.longPress(tile);
      await t.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls, ['archive', 'close', 'restore']);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('vertical_scroll_does_not_reveal_or_trigger_thread_actions', (
    t,
  ) async {
    var reveals = 0;
    var actions = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 250,
            child: ListView(
              children: [
                for (var i = 0; i < 15; i++)
                  ThreadListTile(
                    id: '$i',
                    title: '会话 $i',
                    subtitle: '项目\n今天',
                    running: false,
                    selected: false,
                    revealed: false,
                    onReveal: (_) => reveals++,
                    onOpen: () => actions++,
                    onArchive: () => actions++,
                    onClose: null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final before = t.getTopLeft(find.text('会话 1')).dy;
    await t.drag(find.byType(ListView), const Offset(0, -150));
    await t.pumpAndSettle();
    expect(t.getTopLeft(find.text('会话 1')).dy, lessThan(before));
    expect(reveals, 0);
    expect(actions, 0);
    expect(t.takeException(), isNull);
  });
}
