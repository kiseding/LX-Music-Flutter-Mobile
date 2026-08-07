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

  test('connection factory allows proxies and dials only validated address',
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

    // 代理不再被拦截：无论是否配置代理，都直连已校验的目标地址。
    expect(
      () => factory(originalUri, 'proxy.example', 8080),
      throwsA(isA<SocketException>()),
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

  test('failover skips a hanging address and connects to the next', () async {
    var attempts = 0;
    // 用真实本地回环 socket 构造可成功连接的 ConnectionTask。
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    final acceptFuture = server.first;
    final clientTask = Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    await acceptFuture; // 建立真实 TCP 连接

    final task = await SourcePinnedTransport.starterWithFailover(
      [InternetAddress('10.0.0.1'), InternetAddress('10.0.0.2')],
      443,
      host: 'source.example',
      useTls: false,
      connect: (address, port, {required String host, required bool useTls}) async {
        attempts++;
        if (address.address == '10.0.0.1') {
          // 第一个地址的 task.socket 永不完成（模拟 TCP 通但 TLS 挂起）
          return ConnectionTask.fromSocket(
            Completer<Socket>().future,
            () {},
          );
        }
        return ConnectionTask.fromSocket(clientTask, () {});
      },
    );

    expect(attempts, 2);
    final socket = await task.socket;
    socket.destroy();
  });
}
