import 'dart:async';
import 'dart:js_interop';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker_web/file_picker_web.dart';
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;
import 'package:web_socket_channel/web_socket_channel.dart';

http.Client createClient() => BrowserClient()..withCredentials = true;
WebSocketChannel openSocket(Uri uri, String? token) =>
    WebSocketChannel.connect(uri);
Future<String?> loadToken() async => null;
Future<void> saveToken(String? token) async {}

PlatformFile _browserFile(web.File file) => WebPlatformFile(
  name: file.name,
  uri: Uri.parse(web.URL.createObjectURL(file)),
  bytesLength: file.size,
);

void Function() registerFilePaste(
  void Function(List<PlatformFile>) onPaste, {
  required bool Function() enabled,
}) {
  final paste = ((web.ClipboardEvent event) {
    if (!enabled()) return;
    final data = event.clipboardData;
    if (data == null) return;
    final files = <PlatformFile>[];
    for (var i = 0; i < data.files.length; i++) {
      files.add(_browserFile(data.files.item(i)!));
    }
    // Some browsers expose pasted images only through DataTransferItem.
    if (files.isEmpty) {
      for (var i = 0; i < data.items.length; i++) {
        final item = data.items[i];
        if (item.kind == 'file') {
          final file = item.getAsFile();
          if (file != null) files.add(_browserFile(file));
        }
      }
    }
    if (files.isEmpty) return; // Plain text keeps the normal editor behavior.
    // Capture before Flutter inserts the clipboard's text/path representation.
    event.preventDefault();
    event.stopImmediatePropagation();
    onPaste(files);
  }).toJS;
  web.window.addEventListener('paste', paste, true.toJS);
  return () => web.window.removeEventListener('paste', paste, true.toJS);
}

void Function() registerFileDrop(void Function(List<PlatformFile>) onDrop) {
  final over = ((web.DragEvent event) {
    event.preventDefault();
  }).toJS;
  final drop = ((web.DragEvent event) {
    event.preventDefault();
    final list = event.dataTransfer?.files;
    if (list == null) return;
    final files = <PlatformFile>[];
    for (var i = 0; i < list.length; i++) {
      files.add(_browserFile(list.item(i)!));
    }
    onDrop(files);
  }).toJS;
  web.document.addEventListener('dragover', over);
  web.document.addEventListener('drop', drop);
  return () {
    web.document.removeEventListener('dragover', over);
    web.document.removeEventListener('drop', drop);
  };
}

void releaseFile(PlatformFile file) {
  if (file.uri.scheme == 'blob') web.URL.revokeObjectURL(file.uri.toString());
}

Future<http.Response> uploadFile({
  required PlatformFile file,
  required int size,
  required Uri uri,
  required String? token,
  required void Function(double) progress,
  required Future<void> cancel,
}) async {
  // Keep the browser File/Blob out of Dart's heap, including for large uploads.
  final source = await web.window.fetch(file.uri.toString().toJS).toDart;
  final blob = await source.blob().toDart;
  final result = Completer<http.Response>();
  final xhr = web.XMLHttpRequest();
  xhr.open('POST', uri.toString());
  xhr.withCredentials = true;
  xhr.timeout = 120000;
  xhr.setRequestHeader('Content-Type', 'application/octet-stream');
  xhr.setRequestHeader('X-File-Name', Uri.encodeComponent(file.name));
  xhr.upload.onprogress = ((web.ProgressEvent event) {
    if (event.lengthComputable) progress(event.loaded / event.total);
  }).toJS;
  xhr.onload = ((web.Event _) {
    if (!result.isCompleted) {
      result.complete(http.Response(xhr.responseText, xhr.status));
    }
  }).toJS;
  void fail(String message) {
    if (!result.isCompleted) result.completeError(StateError(message));
  }

  xhr.onerror = ((web.Event _) => fail('上传连接中断')).toJS;
  xhr.ontimeout = ((web.Event _) => fail('上传超时，请重试')).toJS;
  xhr.onabort = ((web.Event _) => fail('上传已取消')).toJS;
  unawaited(
    cancel.then((_) {
      if (!result.isCompleted) xhr.abort();
    }),
  );
  xhr.send(blob);
  return result.future;
}

Future<void> downloadFile(Uri uri, String? token, String name) async {
  final anchor = web.HTMLAnchorElement()
    ..href = uri.toString()
    ..download = name;
  anchor.click();
}
