import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

http.Client createClient() => http.Client();

WebSocketChannel openSocket(Uri uri, String? token) =>
    IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $token'},
      connectTimeout: const Duration(seconds: 15),
      pingInterval: const Duration(seconds: 20),
    );

const _secure = FlutterSecureStorage();
Future<String?> loadToken() => _secure.read(key: 'access_token');
Future<void> saveToken(String? token) => token == null
    ? _secure.delete(key: 'access_token')
    : _secure.write(key: 'access_token', value: token);

void Function() registerFileDrop(void Function(List<PlatformFile>) onDrop) =>
    () {};
void Function() registerFilePaste(
  void Function(List<PlatformFile>) onPaste, {
  required bool Function() enabled,
}) => () {};
void releaseFile(PlatformFile file) {}

Future<http.Response> uploadFile({
  required PlatformFile file,
  required int size,
  required Uri uri,
  required String? token,
  required void Function(double) progress,
  required Future<void> cancel,
}) async {
  final client = http.Client();
  final request =
      http.AbortableStreamedRequest('POST', uri, abortTrigger: cancel)
        ..contentLength = size
        ..headers.addAll({
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/octet-stream',
          'X-File-Name': Uri.encodeComponent(file.name),
        });
  var sent = 0;
  try {
    Future<void> writeBody() async {
      await request.sink.addStream(
        file.readAsByteStream().map((chunk) {
          sent += chunk.length;
          progress(sent / size);
          return chunk;
        }),
      );
      await request.sink.close();
    }

    // Observe both futures immediately: an early HTTP failure must not become
    // an unhandled error while a large file is still being read.
    final results = await Future.wait<Object?>([
      client.send(request),
      writeBody(),
    ], eagerError: true);
    return await http.Response.fromStream(
      results.first! as http.StreamedResponse,
    );
  } finally {
    client.close();
  }
}

Future<void> downloadFile(Uri uri, String? token, String name) async {
  final client = http.Client();
  try {
    final response = await client.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '下载失败');
    }
    await FilePicker.saveFile(fileName: name, bytes: response.bodyBytes);
  } finally {
    client.close();
  }
}
