import 'dart:async';
import 'dart:io';

typedef SourceAddressResolver = Future<List<InternetAddress>> Function(
  String host,
);

class SourceRequestPolicyException implements Exception {
  final String code;
  final String message;

  const SourceRequestPolicyException(this.code, this.message);

  @override
  String toString() => 'SourceRequestPolicyException($code): $message';
}

class ValidatedSourceRequest {
  final Uri uri;
  final List<InternetAddress> addresses;
  final String method;
  final Map<String, String> headers;
  final dynamic body;
  final Duration timeout;

  const ValidatedSourceRequest({
    required this.uri,
    required this.addresses,
    required this.method,
    required this.headers,
    required this.body,
    required this.timeout,
  });
}

class SourceTransportResponse {
  final int? statusCode;
  final String statusMessage;
  final Map<String, List<String>> headers;
  final Stream<List<int>> body;
  final void Function()? close;

  const SourceTransportResponse({
    required this.statusCode,
    this.statusMessage = '',
    required this.headers,
    required this.body,
    this.close,
  });

  String? header(String name) {
    final values = headers.entries
        .where((entry) => entry.key.toLowerCase() == name.toLowerCase())
        .expand((entry) => entry.value)
        .toList();
    return values.isEmpty ? null : values.join(', ');
  }
}

class SourceRequestResponse {
  final int? statusCode;
  final String statusMessage;
  final Map<String, List<String>> headers;
  final List<int> bytes;

  const SourceRequestResponse({
    required this.statusCode,
    required this.statusMessage,
    required this.headers,
    required this.bytes,
  });
}

class SourceRequestCancellation {
  final Completer<String> _completer = Completer<String>();

  bool get isCancelled => _completer.isCompleted;
  Future<String> get future => _completer.future;

  void cancel([String reason = 'cancelled']) {
    if (!_completer.isCompleted) _completer.complete(reason);
  }
}

class SourceRequestPolicy {
  static const _hopByHop = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'host',
    'content-length',
  };
  static const _sensitive = {
    'authorization',
    'cookie',
    'proxy-authorization',
    'x-forwarded-for',
    'x-forwarded-host',
    'x-forwarded-proto',
  };

  final SourceAddressResolver resolve;
  final int maximumResponseBytes;

  SourceRequestPolicy({
    SourceAddressResolver? resolve,
    this.maximumResponseBytes = 10 * 1024 * 1024,
  }) : resolve = resolve ?? ((host) => InternetAddress.lookup(host));

  Future<ValidatedSourceRequest> validate(
      Uri uri, Map<String, dynamic> options) async {
    final timeoutValue = options['timeout'];
    final timeoutMs = timeoutValue is num ? timeoutValue.toInt() : 15000;
    final timeout = Duration(milliseconds: timeoutMs.clamp(1, 60000));
    if (uri.scheme.toLowerCase() != 'https') {
      throw const SourceRequestPolicyException('scheme', 'HTTPS is required');
    }
    if (uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort && uri.port <= 0) {
      throw const SourceRequestPolicyException('url', 'Invalid source URL');
    }

    List<InternetAddress> addresses;
    try {
      final literal = InternetAddress.tryParse(uri.host);
      addresses = literal == null
          ? await resolve(uri.host).timeout(timeout)
          : [literal];
    } on TimeoutException {
      throw const SourceRequestPolicyException(
          'timeout', 'DNS resolution timed out');
    } catch (_) {
      throw const SourceRequestPolicyException(
          'dns_failed', 'DNS resolution failed');
    }
    if (addresses.isEmpty) {
      throw const SourceRequestPolicyException(
          'dns_failed', 'DNS returned no addresses');
    }
    if (addresses.any((address) => !_isPublic(address))) {
      throw const SourceRequestPolicyException(
          'blocked_address', 'Destination is not public');
    }

    final rawHeaders = options['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        final name = key.toString();
        final lower = name.toLowerCase();
        if (!_hopByHop.contains(lower) && !_sensitive.contains(lower)) {
          headers[name] = value.toString();
        }
      });
    }
    if (!headers.keys.any((key) => key.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36';
    }
    return ValidatedSourceRequest(
      uri: uri,
      addresses: List.unmodifiable(addresses),
      method: (options['method']?.toString() ?? 'GET').toUpperCase(),
      headers: Map.unmodifiable(headers),
      body: options['body'],
      timeout: timeout,
    );
  }

  static bool _isPublic(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = bytes[0], b = bytes[1];
      return !(a == 0 ||
          a == 10 ||
          a == 127 ||
          (a == 100 && b >= 64 && b <= 127) ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 192 && b == 0 && bytes[2] == 0) ||
          (a == 192 && b == 0 && bytes[2] == 2) ||
          (a == 198 && (b == 18 || b == 19)) ||
          (a == 198 && b == 51 && bytes[2] == 100) ||
          (a == 203 && b == 0 && bytes[2] == 113) ||
          a >= 224);
    }
    final first = bytes[0], second = bytes[1];
    final globalUnicast = (first & 0xe0) == 0x20;
    return globalUnicast &&
        !(bytes.every((byte) => byte == 0) ||
            bytes.skip(1).every((byte) => byte == 0) ||
            (first & 0xfe) == 0xfc ||
            (first == 0xfe && (second & 0xc0) == 0x80) ||
            first >= 0xff ||
            (first == 0x20 &&
                second == 0x01 &&
                bytes[2] == 0x0d &&
                bytes[3] == 0xb8) ||
            (first == 0x20 && second == 0x02));
  }
}

typedef SourceTransport = Future<SourceTransportResponse> Function(
  ValidatedSourceRequest request,
  SourceRequestCancellation cancellation,
);

class SourceRequestSandbox {
  final SourceRequestPolicy policy;
  final SourceTransport transport;
  final int maximumRedirects;

  const SourceRequestSandbox({
    required this.policy,
    required this.transport,
    this.maximumRedirects = 5,
  });

  Future<SourceRequestResponse> request(
    Uri uri,
    Map<String, dynamic> options, {
    SourceRequestCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? SourceRequestCancellation();
    var current = uri;
    for (var redirects = 0;; redirects++) {
      if (cancel.isCancelled) _throwCancelled();
      final request = await policy.validate(current, options);
      final response = await Future.any([
        transport(request, cancel).timeout(
          request.timeout,
          onTimeout: () {
            cancel.cancel('Source request timed out');
            throw const SourceRequestPolicyException(
                'timeout', 'Source request timed out');
          },
        ),
        cancel.future.then<SourceTransportResponse>((reason) =>
            throw SourceRequestPolicyException('cancelled', reason)),
      ]);
      final location = response.header('location');
      if (response.statusCode != null &&
          response.statusCode! >= 300 &&
          response.statusCode! < 400 &&
          location != null) {
        if (redirects >= maximumRedirects) {
          response.close?.call();
          throw const SourceRequestPolicyException(
              'too_many_redirects', 'Redirect limit exceeded');
        }
        response.close?.call();
        current = current.resolve(location);
        continue;
      }

      final bytes = await _readBody(response, request.timeout, cancel);
      if (cancel.isCancelled) _throwCancelled();
      return SourceRequestResponse(
        statusCode: response.statusCode,
        statusMessage: response.statusMessage,
        headers: response.headers,
        bytes: bytes,
      );
    }
  }

  Future<List<int>> _readBody(
    SourceTransportResponse response,
    Duration timeout,
    SourceRequestCancellation cancellation,
  ) async {
    final bytes = <int>[];
    final done = Completer<List<int>>();
    late StreamSubscription<List<int>> subscription;
    Timer? timer;

    void completeError(Object error, [StackTrace? stackTrace]) {
      if (!done.isCompleted) done.completeError(error, stackTrace);
    }

    subscription = response.body.listen(
      (chunk) {
        if (done.isCompleted) return;
        bytes.addAll(chunk);
        if (bytes.length > policy.maximumResponseBytes) {
          completeError(const SourceRequestPolicyException(
              'response_too_large', 'Response exceeds byte limit'));
          unawaited(subscription.cancel());
        }
      },
      onError: completeError,
      onDone: () {
        if (!done.isCompleted) done.complete(bytes);
      },
      cancelOnError: true,
    );
    timer = Timer(timeout, () {
      completeError(const SourceRequestPolicyException(
          'timeout', 'Source response timed out'));
      unawaited(subscription.cancel());
    });
    cancellation.future.then((reason) {
      completeError(SourceRequestPolicyException('cancelled', reason));
      unawaited(subscription.cancel());
      response.close?.call();
    });

    try {
      return await done.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
      response.close?.call();
    }
  }

  Never _throwCancelled() => throw const SourceRequestPolicyException(
      'cancelled', 'Source request was cancelled');
}
