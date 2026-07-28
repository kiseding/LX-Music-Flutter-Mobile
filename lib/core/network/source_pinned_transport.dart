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
  int port,
);
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
    final starter = startSocket ?? Socket.startConnect;
    return (uri, proxyHost, proxyPort) {
      if (proxyHost != null) {
        throw const SourceRequestPolicyException(
          'proxy_blocked',
          'Proxy connections are not allowed',
        );
      }
      final address = request.addresses[nextAddress % request.addresses.length];
      nextAddress++;
      return starter(address, uri.port);
    };
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
