@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:codex_link/platform/transport_web.dart' as transport;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

void main() {
  web.File file(String name, String content, String type) =>
      web.File([content.toJS].toJS, name, web.FilePropertyBag(type: type));
  web.ClipboardEvent paste(web.DataTransfer data) => web.ClipboardEvent(
    'paste',
    web.ClipboardEventInit(
      clipboardData: data,
      bubbles: true,
      cancelable: true,
    ),
  );

  test('clipboard_files_replace_path_text_once', () async {
    final batches = <List<PlatformFile>>[];
    final stop = transport.registerFilePaste(batches.add, enabled: () => true);
    addTearDown(stop);
    final data = web.DataTransfer();
    data.items.add(file('notes.txt', 'clipboard document', 'text/plain'));
    data.items.add(file('image.png', 'image bytes', 'image/png'));
    data.setData('text/plain', '/home/user/image.png');
    final event = paste(data);
    web.document.body!.dispatchEvent(event);
    expect(event.defaultPrevented, isTrue);
    expect(batches, hasLength(1));
    expect(batches.single.map((f) => f.name), ['notes.txt', 'image.png']);
    final source = await web.window
        .fetch(batches.single.first.uri.toString().toJS)
        .toDart;
    expect((await source.text().toDart).toDart, 'clipboard document');
    for (final f in batches.single) {
      transport.releaseFile(f);
    }
  });

  test('clipboard_plain_text_and_unfocused_editor_keep_default_behavior', () {
    var enabled = false;
    final batches = <List<PlatformFile>>[];
    final stop = transport.registerFilePaste(
      batches.add,
      enabled: () => enabled,
    );
    final data = web.DataTransfer();
    data.items.add(file('notes.txt', 'content', 'text/plain'));
    final unfocused = paste(data);
    web.document.body!.dispatchEvent(unfocused);
    expect(unfocused.defaultPrevented, isFalse);
    expect(batches, isEmpty);
    enabled = true;
    final text = web.DataTransfer()
      ..setData('text/plain', '/a/path is plain text');
    final plain = paste(text);
    web.document.body!.dispatchEvent(plain);
    expect(plain.defaultPrevented, isFalse);
    expect(batches, isEmpty);
    stop();
    final disposed = paste(data);
    web.document.body!.dispatchEvent(disposed);
    expect(disposed.defaultPrevented, isFalse);
    expect(batches, isEmpty);
  });
}
