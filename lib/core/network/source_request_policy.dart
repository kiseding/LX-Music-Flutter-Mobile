import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' show FormData;

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

  String? singleHeader(String name) {
    final values = headers.entries
        .where((entry) => entry.key.toLowerCase() == name.toLowerCase())
        .expand((entry) => entry.value)
        .toList();
    if (values.isEmpty) return null;
    if (values.length != 1) {
      throw const SourceRequestPolicyException(
          'ambiguous_redirect', 'Redirect has multiple Location values');
    }
    return values.single;
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
  static const _ipv4DeniedPrefixes = <(List<int>, int)>[
    ([0], 8),
    ([10], 8),
    ([100, 64], 10),
    ([127], 8),
    ([169, 254], 16),
    ([172, 16], 12),
    ([192, 0, 0], 24),
    ([192, 0, 2], 24),
    ([192, 31, 196], 24),
    ([192, 52, 193], 24),
    ([192, 88, 99], 24),
    ([192, 168], 16),
    ([192, 175, 48], 24),
    ([198, 18], 15),
    ([198, 51, 100], 24),
    ([203, 0, 113], 24),
    ([224], 4),
    ([240], 4),
  ];
  static const _ipv6DeniedPrefixes = <(List<int>, int)>[
    ([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 96),
    ([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff], 96),
    ([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0], 96),
    ([0x00, 0x64, 0xff, 0x9b, 0x00, 0x01], 48),
    ([0x01, 0x00, 0, 0, 0, 0, 0, 0], 64),
    ([0x20, 0x01, 0x00], 23),
    ([0x20, 0x01, 0x0d, 0xb8], 32),
    ([0x20, 0x02], 16),
    ([0x3f, 0xff, 0x00], 20),
    ([0x5f, 0x00], 16),
    ([0xfc], 7),
    ([0xfe, 0x80], 10),
    ([0xff], 8),
  ];
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
      return !_ipv4DeniedPrefixes
          .any((prefix) => _matchesPrefix(bytes, prefix.$1, prefix.$2));
    }
    final globallyRoutable = (bytes[0] & 0xe0) == 0x20;
    return globallyRoutable &&
        !_ipv6DeniedPrefixes
            .any((prefix) => _matchesPrefix(bytes, prefix.$1, prefix.$2));
  }

  static bool _matchesPrefix(List<int> address, List<int> prefix, int bits) {
    final wholeBytes = bits ~/ 8;
    for (var i = 0; i < wholeBytes; i++) {
      if (address[i] != prefix[i]) return false;
    }
    final remainingBits = bits % 8;
    if (remainingBits == 0) return true;
    final mask = 0xff << (8 - remainingBits) & 0xff;
    return address[wholeBytes] & mask == prefix[wholeBytes] & mask;
  }
}

typedef SourceTransport = Future<SourceTransportResponse> Function(
  ValidatedSourceRequest request,
  SourceRequestCancellation cancellation,
);

class SourceRequestSandbox {
  static const _crossOriginHeaders = {
    'accept',
    'accept-language',
    'user-agent',
  };
  final SourceRequestPolicy policy;
  final SourceTransport transport;
  final int maximumRedirects;
  final int maximumInFlightBytes;
  final int maximumConcurrentResponseBodies;
  int _inFlightBytes = 0;
  int _activeResponseBodies = 0;

  SourceRequestSandbox({
    required this.policy,
    required this.transport,
    this.maximumRedirects = 5,
    this.maximumInFlightBytes = 20 * 1024 * 1024,
    this.maximumConcurrentResponseBodies = 4,
  });

  Future<SourceRequestResponse> request(
    Uri uri,
    Map<String, dynamic> options, {
    SourceRequestCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? SourceRequestCancellation();
    var current = uri;
    var currentOptions = Map<String, dynamic>.from(options);
    for (var redirects = 0;; redirects++) {
      if (cancel.isCancelled) _throwCancelled();
      final request = await Future.any([
        policy.validate(current, currentOptions),
        cancel.future.then<ValidatedSourceRequest>((reason) =>
            throw SourceRequestPolicyException('cancelled', reason)),
      ]);
      if (cancel.isCancelled) _throwCancelled();
      final transportFuture = transport(request, cancel);
      if (cancel.isCancelled) _throwCancelled();
      final response = await Future.any([
        transportFuture.timeout(
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
      if (cancel.isCancelled) {
        response.close?.call();
        _throwCancelled();
      }
      final status = response.statusCode;
      final isRedirect = status == 301 ||
          status == 302 ||
          status == 303 ||
          status == 307 ||
          status == 308;
      if (isRedirect) {
        String? location;
        try {
          location = response.singleHeader('location');
        } catch (_) {
          response.close?.call();
          rethrow;
        }
        if (location == null) {
          final bytes = await _readBody(response, request.timeout, cancel);
          return SourceRequestResponse(
            statusCode: response.statusCode,
            statusMessage: response.statusMessage,
            headers: response.headers,
            bytes: bytes,
          );
        }
        if (redirects >= maximumRedirects) {
          response.close?.call();
          throw const SourceRequestPolicyException(
              'too_many_redirects', 'Redirect limit exceeded');
        }
        final next = current.resolve(location);
        currentOptions = _redirectOptions(
          request,
          status!,
          crossOrigin: !_sameOrigin(current, next),
        );
        response.close?.call();
        current = next;
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

  Map<String, dynamic> _redirectOptions(
    ValidatedSourceRequest request,
    int status, {
    required bool crossOrigin,
  }) {
    var method = request.method;
    var body = request.body;
    final dropsBody = status == 303 ||
        ((status == 301 || status == 302) && request.method == 'POST');
    if (dropsBody) {
      method = 'GET';
      body = null;
    } else if (body != null && (body is Stream || body is FormData)) {
      throw const SourceRequestPolicyException('redirect_body_not_replayable',
          'Redirect cannot replay a one-shot request body');
    }

    final headers = <String, String>{};
    for (final entry in request.headers.entries) {
      final lower = entry.key.toLowerCase();
      if (lower.startsWith('content-')) continue;
      if (!crossOrigin || _crossOriginHeaders.contains(lower)) {
        headers[entry.key] = entry.value;
      }
    }
    if (body != null) {
      final contentType = _headerValue(request.headers, 'content-type');
      if (contentType != null) headers['Content-Type'] = contentType;
    }
    return {
      'method': method,
      'headers': headers,
      'body': body,
      'timeout': request.timeout.inMilliseconds,
    };
  }

  bool _sameOrigin(Uri first, Uri second) =>
      first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
      first.host.toLowerCase() == second.host.toLowerCase() &&
      first.port == second.port;

  String? _headerValue(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  Future<List<int>> _readBody(
    SourceTransportResponse response,
    Duration timeout,
    SourceRequestCancellation cancellation,
  ) async {
    if (_activeResponseBodies >= maximumConcurrentResponseBodies) {
      response.close?.call();
      throw const SourceRequestPolicyException('too_many_response_bodies',
          'Concurrent response body limit exceeded');
    }
    final reservedBytes = policy.maximumResponseBytes;
    if (reservedBytes > maximumInFlightBytes - _inFlightBytes) {
      response.close?.call();
      throw const SourceRequestPolicyException(
          'response_budget_exceeded', 'In-flight response budget exceeded');
    }
    _inFlightBytes += reservedBytes;
    _activeResponseBodies++;
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
        if (chunk.length > policy.maximumResponseBytes - bytes.length) {
          completeError(const SourceRequestPolicyException(
              'response_too_large', 'Response exceeds byte limit'));
          unawaited(subscription.cancel());
          return;
        }
        bytes.addAll(chunk);
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
      _inFlightBytes -= reservedBytes;
      _activeResponseBodies--;
    }
  }

  Never _throwCancelled() => throw const SourceRequestPolicyException(
      'cancelled', 'Source request was cancelled');
}
