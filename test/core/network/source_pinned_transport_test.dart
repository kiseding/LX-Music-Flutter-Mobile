import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/source_pinned_transport.dart';
import 'package:lx_music_flutter/core/network/source_request_policy.dart';

void main() {
  ValidatedSourceRequest request({String scheme = 'https'}) =>
      ValidatedSourceRequest(
        uri: Uri.parse('$scheme://source.example/path'),
        addresses: [InternetAddress('93.184.216.34')],
        method: 'GET',
        headers: const {},
        body: null,
        timeout: const Duration(seconds: 1),
      );

  test('pre-cancellation does not construct Dio', () async {
    var dioCreations = 0;
    final transport = SourcePinnedTransport(
      createDio: () {
        dioCreations++;
        return Dio();
      },
    );
    final cancellation = SourceRequestCancellation()..cancel('disposed');

    await expectLater(
      transport(request(), cancellation),
      throwsA(isA<SourceRequestPolicyException>()),
    );
    expect(dioCreations, 0);
  });

  test(
      'request executor receives original HTTPS URI and force-closes on cancel',
      () async {
    final started = Completer<void>();
    final pending = Completer<Response<dynamic>>();
    final dio = Dio();
    var forceClosed = false;
    Uri? openedUri;
    final transport = SourcePinnedTransport(
      createDio: () => dio,
      closeDio: (_) => forceClosed = true,
      execute: (dio, sourceRequest, cancelToken) {
        openedUri = sourceRequest.uri;
        started.complete();
        return pending.future;
      },
    );
    final cancellation = SourceRequestCancellation();

    final result = transport(request(), cancellation);
    await started.future;
    cancellation.cancel('disposed');

    await expectLater(result, throwsA(isA<SourceRequestPolicyException>()));
    expect(openedUri, Uri.parse('https://source.example/path'));
    expect(forceClosed, isTrue);
  });

  test('connection factory rejects proxies and dials only validated address',
      () async {
    InternetAddress? dialedAddress;
    int? dialedPort;
    String? dialedHost;
    var secure = false;
    final factory = SourcePinnedTransport.connectionFactory(
      request(),
      (address, port, {required String host, required bool useTls}) {
        dialedAddress = address;
        dialedPort = port;
        dialedHost = host;
        secure = useTls;
        throw const SocketException('stop after selection');
      },
    );
    final originalUri = Uri.parse('https://source.example/path');

    expect(
      () => factory(originalUri, 'proxy.example', 8080),
      throwsA(
        isA<SourceRequestPolicyException>()
            .having((error) => error.code, 'code', 'proxy_blocked'),
      ),
    );
    expect(
      () => factory(originalUri, null, null),
      throwsA(isA<SocketException>()),
    );
    expect(dialedAddress?.address, '93.184.216.34');
    expect(dialedPort, 443);
    expect(dialedHost, 'source.example');
    expect(secure, isTrue);
    expect(originalUri.host, 'source.example');
  });

  test('HTTP pinned connect does not force TLS', () async {
    var secure = true;
    final factory = SourcePinnedTransport.connectionFactory(
      request(scheme: 'http'),
      (address, port, {required String host, required bool useTls}) {
        secure = useTls;
        throw const SocketException('stop after selection');
      },
    );

    expect(
      () => factory(Uri.parse('http://source.example/path'), null, null),
      throwsA(isA<SocketException>()),
    );
    expect(secure, isFalse);
  });
}
