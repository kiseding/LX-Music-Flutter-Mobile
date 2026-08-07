import 'package:dio/dio.dart';

import '../logging/app_log.dart';

final class AppHttpClient {
  static Dio create({BaseOptions? options}) {
    final client = Dio(options ?? BaseOptions());
    client.interceptors.add(_DiagnosticNetworkInterceptor());
    return client;
  }
}

final class _DiagnosticNetworkInterceptor extends Interceptor {
  static const _startedAtKey = '_diagnosticRequestStartedAt';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startedAtKey] = DateTime.now();
    AppLog.instance.record(
      'network.request',
      '${options.method} ${_target(options)}',
    );
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    final statusCode = response.statusCode;
    AppLog.instance.record(
      'network.response',
      '${response.requestOptions.method} ${_target(response.requestOptions)} '
          'status=$statusCode elapsed=${_elapsed(response.requestOptions)}ms',
      level: statusCode != null && statusCode >= 400
          ? AppLogLevel.warning
          : AppLogLevel.info,
    );
    handler.next(response);
  }

  @override
  void onError(DioException error, ErrorInterceptorHandler handler) {
    final responseStatus = error.response?.statusCode;
    final cancelled = error.type == DioExceptionType.cancel;
    AppLog.instance.record(
      cancelled ? 'network.cancel' : 'network.error',
      '${error.requestOptions.method} ${_target(error.requestOptions)} '
          'type=${error.type.name} status=$responseStatus '
          'elapsed=${_elapsed(error.requestOptions)}ms error=${error.message}',
      level: cancelled ? AppLogLevel.info : AppLogLevel.error,
    );
    handler.next(error);
  }

  String _target(RequestOptions options) {
    final uri = options.uri;
    final port = uri.hasPort ? ':${uri.port}' : '';
    final path = uri.path.isEmpty ? '/' : uri.path;
    return '${uri.scheme}://${uri.host}$port$path';
  }

  int _elapsed(RequestOptions options) {
    final startedAt = options.extra[_startedAtKey];
    if (startedAt is! DateTime) return -1;
    return DateTime.now().difference(startedAt).inMilliseconds;
  }
}
