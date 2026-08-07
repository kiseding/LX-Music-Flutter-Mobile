import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'source_request_policy.dart';

typedef SourceDioFactory = Dio Function();
typedef SourceDioExecutor = Future<Response<dynamic>> Function(
  Dio dio,
  ValidatedSourceRequest request,
  CancelToken cancelToken,
);
typedef SourceSocketStarter = Future<ConnectionTask<Socket>> Function(
  InternetAddress address,
  int port, {
  required String host,
  required bool useTls,
});
typedef SourceDioCloser = void Function(Dio dio);

class SourcePinnedTransport {
  final SourceDioFactory createDio;
  final SourceDioExecutor execute;
  final SourceDioCloser closeDio;

  SourcePinnedTransport({
    SourceDioFactory? createDio,
    SourceDioExecutor? execute,
    SourceDioCloser? closeDio,
  })  : createDio = createDio ?? Dio.new,
        execute = execute ?? _execute,
        closeDio = closeDio ?? ((dio) => dio.close(force: true));

  Future<SourceTransportResponse> call(
    ValidatedSourceRequest request,
    SourceRequestCancellation cancellation,
  ) async {
    if (cancellation.isCancelled) _throwCancelled();
    final dio = createDio();
    final cancelToken = CancelToken();
    var closed = false;

    void close() {
      if (closed) return;
      closed = true;
      closeDio(dio);
    }

    cancellation.future.then((reason) {
      cancelToken.cancel(reason);
      close();
    });
    if (cancellation.isCancelled) {
      close();
      _throwCancelled();
    }

    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.connectionFactory = connectionFactory(request);
        return client;
      },
    );
    try {
      final response = await Future.any([
        execute(dio, request, cancelToken),
        cancellation.future.then<Response<dynamic>>((reason) =>
            throw SourceRequestPolicyException('cancelled', reason)),
      ]);
      if (cancellation.isCancelled) {
        close();
        _throwCancelled();
      }
      final responseBody = response.data as ResponseBody;
      final body = (() async* {
        try {
          await for (final chunk in responseBody.stream) {
            yield chunk;
          }
        } finally {
          close();
        }
      })();
      final responseHeaders = <String, List<String>>{};
      response.headers.forEach((name, values) {
        responseHeaders[name] = List.unmodifiable(values);
      });
      return SourceTransportResponse(
        statusCode: response.statusCode,
        statusMessage: response.statusMessage ?? '',
        headers: responseHeaders,
        body: body,
        close: close,
      );
    } catch (_) {
      close();
      rethrow;
    }
  }

  static Future<ConnectionTask<Socket>> Function(Uri, String?, int?)
      connectionFactory(
    ValidatedSourceRequest request, [
    SourceSocketStarter? startSocket,
  ]) {
    var nextAddress = 0;
    final starter = startSocket ?? startPinnedSocket;
    return (uri, proxyHost, proxyPort) {
      // 按需求放开代理：不再拦截 proxy，改为直连已校验的目标地址。
      // 轮转起始 IP，但连接层负责 failover 到列表里的其它 IP。
      final start = nextAddress % request.addresses.length;
      nextAddress++;
      final rotated = <InternetAddress>[
        for (var i = 0; i < request.addresses.length; i++)
          request.addresses[(start + i) % request.addresses.length],
      ];
      return starterWithFailover(
        rotated,
        uri.port,
        host: uri.host,
        useTls: uri.scheme.toLowerCase() == 'https',
        connect: starter,
      );
    };
  }

  /// 连接单个 IP，TLS 用原 hostname（SNI + 证书校验匹配）。
  static Future<ConnectionTask<Socket>> startPinnedSocket(
    InternetAddress address,
    int port, {
    required String host,
    required bool useTls,
  }) async {
    final rawTask = await Socket.startConnect(address, port);
    if (!useTls) return rawTask;
    final secureFuture = rawTask.socket.then(
      (socket) => SecureSocket.secure(socket, host: host),
    );
    return ConnectionTask.fromSocket(secureFuture, rawTask.cancel);
  }

  /// 依次尝试候选 IP，首个真正建立连接（含 TLS）的即返回。
  /// 修复：DNS 解析常返回多个 IP（如 onrender 的两个 Cloudflare 地址），
  /// 其中个别 IP 的 TCP 通但 TLS/HTTP 挂起。盲目轮流 pin 会导致
  /// “第一首能播、后续解析卡死”。这里对每个 IP 等连接+TLS 完成，
  /// 超时或失败立即 cancel 并换下一个。
  static const _connectFailoverTimeout = Duration(seconds: 5);

  static Future<ConnectionTask<Socket>> starterWithFailover(
    List<InternetAddress> addresses,
    int port, {
    required String host,
    required bool useTls,
    SourceSocketStarter? connect,
  }) async {
    final connectFn = connect ?? startPinnedSocket;
    Object? lastError;
    for (final address in addresses) {
      ConnectionTask<Socket>? task;
      try {
        // connectFn 是 async：await 它拿到 ConnectionTask 时 TCP 已建立，
        // 但 TLS（SecureSocket.secure）仍在 task.socket 里推进。
        // 必须在这里等 task.socket，才能确认 TLS 握手真正完成；
        // 否则对“TCP通但TLS挂起”的 IP 会误判为成功。
        task = await connectFn(address, port, host: host, useTls: useTls);
        // 等连接（含 TLS）真正建立，确认该 IP 可用后再交给 Dio 使用。
        await task.socket.timeout(_connectFailoverTimeout);
        return task;
      } catch (e) {
        lastError = e;
        try {
          task?.cancel();
        } catch (_) {}
      }
    }
    if (lastError != null) throw lastError;
    throw const SocketException('No addresses to connect to');
  }

  static Future<Response<dynamic>> _execute(
    Dio dio,
    ValidatedSourceRequest request,
    CancelToken cancelToken,
  ) {
    return dio.request<dynamic>(
      request.uri.toString(),
      data: request.body,
      options: Options(
        method: request.method,
        headers: request.headers,
        responseType: ResponseType.stream,
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (_) => true,
        sendTimeout: request.timeout,
        receiveTimeout: request.timeout,
      ),
      cancelToken: cancelToken,
    );
  }

  Never _throwCancelled() => throw const SourceRequestPolicyException(
      'cancelled', 'Source request was cancelled');
}
