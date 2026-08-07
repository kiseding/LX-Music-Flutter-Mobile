import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/logging/app_log.dart';
import 'package:lx_music_flutter/core/network/app_http_client.dart';

class _ResponseAdapter implements HttpClientAdapter {
  _ResponseAdapter(this.statusCode);

  final int statusCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString('{}', statusCode);

  @override
  void close({bool force = false}) {}
}

void main() {
  test('records successful requests without query parameters', () async {
    final log = AppLog.instance..clear();
    final client = AppHttpClient.create();
    addTearDown(client.close);
    addTearDown(log.clear);
    client.httpClientAdapter = _ResponseAdapter(200);

    await client.get('https://example.test/health?access_token=secret');

    final output = log.exportText();
    expect(output, contains('[network.request] GET https://example.test/health'));
    expect(output, contains('[network.response] GET https://example.test/health'));
    expect(output, contains('status=200'));
    expect(output, isNot(contains('access_token')));
    expect(output, isNot(contains('secret')));
  });

  test('records failed HTTP responses', () async {
    final log = AppLog.instance..clear();
    final client = AppHttpClient.create();
    addTearDown(client.close);
    addTearDown(log.clear);
    client.httpClientAdapter = _ResponseAdapter(503);

    await expectLater(
      client.get('https://example.test/unavailable'),
      throwsA(isA<DioException>()),
    );

    expect(log.exportText(), contains('[network.error]'));
    expect(log.exportText(), contains('status=503'));
  });
}
