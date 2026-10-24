@TestOn('browser')
library;

import 'dart:convert';

import 'package:codex_link/platform/task_notifications_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

void main() {
  test(
    'notification_browser_starts_feed_without_permission_and_clears_session',
    () async {
      // No grant is needed to establish the fallback feed. In particular, use a
      // browser-valid random bound: Dart's web bit shifts truncate to 32 bits.
      final platform = WebTaskNotifications();
      addTearDown(platform.dispose);
      await platform.clear();
      final settings = await platform.configure(Uri.base, null, true);
      expect(settings.platform, 'browser');
      expect(settings.connection, 'connecting');
      final saved = jsonDecode(
        web.window.localStorage.getItem('codexlink.task-notifications')!,
      ) as Map;
      expect(
        saved['identity'],
        isA<String>().having((s) => s.length, 'length', greaterThan(16)),
      );
      expect(saved.keys, isNot(contains('token')));
      await platform.clear();
      expect(
        web.window.localStorage.getItem('codexlink.task-notifications'),
        isNull,
      );
      expect((await platform.settings()).connection, 'stopped');
    },
  );
}
