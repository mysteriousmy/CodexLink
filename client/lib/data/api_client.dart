import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../platform/transport.dart' as transport;

typedef JsonMap = Map<String, dynamic>;
JsonMap asMap(dynamic value) =>
    value is Map<String, dynamic> ? value : <String, dynamic>{};
List<JsonMap> asMaps(dynamic value) => value is List
    ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : <JsonMap>[];

class ApiError implements Exception {
  const ApiError(this.message, {this.status, this.code});
  final String message;
  final int? status;
  final String? code;
  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({http.Client? client})
    : _client = client ?? transport.createClient();
  final http.Client _client;
  Uri base = Uri.parse(kIsWeb ? Uri.base.origin : 'http://127.0.0.1:47821');
  String? token;

  void configure(String address, String? secret) {
    final uri = Uri.tryParse(address.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const ApiError('请输入完整的服务地址，例如 https://电脑地址');
    }
    if (kIsWeb && uri.origin != Uri.base.origin) {
      throw const ApiError('网页版与服务端需要使用同一地址。');
    }
    base = Uri.parse(uri.origin);
    token = kIsWeb ? null : secret;
  }

  Uri uri(String path, [Map<String, String>? query]) =>
      base.replace(path: path, queryParameters: query);
  Map<String, String> get headers => {
    'Content-Type': 'application/json',
    if (!kIsWeb && token != null) 'Authorization': 'Bearer $token',
  };

  Future<dynamic> request(
    String method,
    String path, {
    JsonMap? body,
    Map<String, String>? query,
  }) async {
    final request = http.Request(method, uri(path, query))
      ..headers.addAll(headers);
    if (body != null || method == 'POST' || method == 'PUT') {
      request.body = jsonEncode(body ?? {});
    }
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 75)),
    );
    return decode(response);
  }

  static dynamic decode(http.Response response) {
    dynamic data;
    if (response.bodyBytes.isNotEmpty) {
      try {
        data = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        throw ApiError(
          '服务返回了无效响应 (${response.statusCode})，请检查地址与反向代理。',
          status: response.statusCode,
        );
      }
    }
    if (response.statusCode >= 400) {
      final problem = asMap(data);
      throw ApiError(
        problem['detail'] as String? ?? '请求失败 (${response.statusCode})',
        status: response.statusCode,
        code: problem['code'] as String?,
      );
    }
    return data;
  }

  Future<void> login(String secret) async {
    if (kIsWeb) {
      await request('POST', '/api/auth/session', body: {'token': secret});
    } else {
      token = secret;
      await request('GET', '/api/status');
      await transport.saveToken(secret);
    }
  }

  Future<http.Response> getFile(Uri uri) async {
    if (uri.origin != base.origin) throw const ApiError('文件地址必须来自当前网关。');
    final response = await _client.get(uri, headers: headers);
    if (response.statusCode >= 400) decode(response);
    return response;
  }

  WebSocketChannel events(String? epoch, int after) {
    final endpoint = uri('/api/events', {
      'epoch': epoch ?? '',
      'after': '$after',
    });
    return transport.openSocket(
      endpoint.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws'),
      token,
    );
  }

  void close() => _client.close();
}
