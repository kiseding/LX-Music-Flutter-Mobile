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
  void Function()? _close;

  SourceTransportResponse({
    required this.statusCode,
    this.statusMessage = '',
    required this.headers,
    required this.body,
    void Function()? close,
  }) : _close = close;

  void close() {
    final close = _close;
    if (close == null) return;
    _close = null;
    close();
  }

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
  final _SourceRequestLease _lease;

  SourceRequestResponse({
    required this.statusCode,
    required this.statusMessage,
    required this.headers,
    required this.bytes,
    required void Function() release,
    required SourceRequestCancellation cancellation,
  }) : _lease = _SourceRequestLease(release, cancellation);

  void release() => _lease.release();
  bool get isCancelled => _lease.isCancelled;

  bool _beginDelivery() => _lease.beginDelivery();
  void _finishDelivery() => _lease.finishDelivery();
}

enum _SourceRequestLeaseState { pending, delivering, released }

class _SourceRequestLease {
  void Function()? _release;
  final SourceRequestCancellation _cancellation;
  _SourceRequestLeaseState _state = _SourceRequestLeaseState.pending;
  bool _cancelled = false;

  _SourceRequestLease(this._release, this._cancellation) {
    _cancellation.future.then((_) => _cancel());
  }

  bool get isCancelled {
    if (_cancellation.isCancelled) _cancel();
    return _cancelled;
  }

  bool beginDelivery() {
    if (_cancellation.isCancelled) _cancel();
    if (_state != _SourceRequestLeaseState.pending || _cancelled) return false;
    _state = _SourceRequestLeaseState.delivering;
    return true;
  }

  void finishDelivery() {
    if (_state == _SourceRequestLeaseState.delivering) _releaseNow();
  }

  void release() {
    if (_state == _SourceRequestLeaseState.pending) _releaseNow();
  }

  void _cancel() {
    _cancelled = true;
    if (_state == _SourceRequestLeaseState.pending) _releaseNow();
  }

  void _releaseNow() {
    if (_state == _SourceRequestLeaseState.released) return;
    _state = _SourceRequestLeaseState.released;
    final release = _release;
    _release = null;
    release?.call();
  }
}

Future<T?> withSourceResponseLease<T>(
  SourceRequestResponse response,
  FutureOr<T> Function(SourceRequestResponse response) operation,
) async {
  if (!response._beginDelivery()) return null;
  try {
    return await operation(response);
  } finally {
    response._finishDelivery();
  }
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
    ([0, 0, 0, 0], 8),
    ([10, 0, 0, 0], 8),
    ([100, 64, 0, 0], 10),
    ([127, 0, 0, 0], 8),
    ([169, 254, 0, 0], 16),
    ([172, 16, 0, 0], 12),
    ([192, 0, 0, 0], 24),
    ([192, 0, 2, 0], 24),
    ([192, 31, 196, 0], 24),
    ([192, 52, 193, 0], 24),
    ([192, 88, 99, 0], 24),
    ([192, 168, 0, 0], 16),
    ([192, 175, 48, 0], 24),
    ([198, 18, 0, 0], 15),
    ([198, 51, 100, 0], 24),
    ([203, 0, 113, 0], 24),
    ([224, 0, 0, 0], 4),
    ([240, 0, 0, 0], 4),
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
  // Only strip hop/proxy/forwarding headers on the first hop. Authorization and
  // Cookie must reach same-origin sponsored custom sources (2033247 parity).
  // Cross-origin redirects still drop them via _crossOriginHeaders allowlist.
  static const _sensitive = {
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
    // 放行 http/https：部分音源（如 onrender 代理）返回 http 播放地址，
    // 强制 https 会导致这类音源解析失败。
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw const SourceRequestPolicyException('scheme', 'Only http/https are allowed');
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
    final publicAddresses =
        addresses.where(_isPublic).toList(growable: false);
    if (publicAddresses.isEmpty) {
      throw const SourceRequestPolicyException(
          'blocked_address', 'Destination is not public');
    }
    final orderedAddresses = [...publicAddresses]..sort((left, right) {
        if (left.type == right.type) return 0;
        return left.type == InternetAddressType.IPv4 ? -1 : 1;
      });

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
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    }
    return ValidatedSourceRequest(
      uri: uri,
      addresses: List.unmodifiable(orderedAddresses),
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
  final SourceRequestPolicy policy;
  final SourceTransport transport;
  final int maximumRedirects;
  final int maximumInFlightBytes;
  final int maximumConcurrentResponseBodies;
  final int maximumConcurrentRequests;
  int _inFlightBytes = 0;
  int _activeResponseBodies = 0;
  int _activeRequests = 0;

  SourceRequestSandbox({
    required this.policy,
    required this.transport,
    this.maximumRedirects = 5,
    this.maximumInFlightBytes = 20 * 1024 * 1024,
    this.maximumConcurrentResponseBodies = 4,
    this.maximumConcurrentRequests = 4,
  });

  Future<SourceRequestResponse> request(
    Uri uri,
    Map<String, dynamic> options, {
    SourceRequestCancellation? cancellation,
  }) async {
    if (_activeRequests >= maximumConcurrentRequests) {
      throw const SourceRequestPolicyException(
          'too_many_requests', 'Concurrent request limit exceeded');
    }
    _activeRequests++;
    var permitTransferred = false;
    final cancel = cancellation ?? SourceRequestCancellation();
    var current = uri;
    var currentOptions = Map<String, dynamic>.from(options);
    try {
      for (var redirects = 0;; redirects++) {
        if (cancel.isCancelled) _throwCancelled();
        final request = await Future.any([
          policy.validate(current, currentOptions),
          cancel.future.then<ValidatedSourceRequest>((reason) =>
              throw SourceRequestPolicyException('cancelled', reason)),
        ]);
        if (cancel.isCancelled) _throwCancelled();
        final transportFuture = transport(request, cancel);
        transportFuture.then((lateResponse) {
          if (cancel.isCancelled) lateResponse.close();
        }, onError: (_) {});
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
          response.close();
          _throwCancelled();
        }
        final status = response.statusCode;
        final isRedirect = status == 301 ||
            status == 302 ||
            status == 303 ||
            status == 307 ||
            status == 308;
        if (isRedirect) {
          final redirectStatus =
              status ?? (throw StateError('Redirect status must not be null'));
          Uri? next;
          try {
            final location = response.singleHeader('location');
            if (location == null) {
              final bytes = await _readBody(response, request.timeout, cancel);
              final result = _responseWithLease(response, bytes, cancel);
              permitTransferred = true;
              return result;
            }
            if (redirects >= maximumRedirects) {
              throw const SourceRequestPolicyException(
                  'too_many_redirects', 'Redirect limit exceeded');
            }
            next = current.resolve(location);
            currentOptions = _redirectOptions(
              request,
              redirectStatus,
              crossOrigin: !_sameOrigin(current, next),
            );
          } finally {
            response.close();
          }
          current = next;
          continue;
        }

        final bytes = await _readBody(response, request.timeout, cancel);
        if (cancel.isCancelled) {
          _inFlightBytes -= bytes.length;
          _throwCancelled();
        }
        final result = _responseWithLease(response, bytes, cancel);
        permitTransferred = true;
        return result;
      }
    } finally {
      if (!permitTransferred) _activeRequests--;
    }
  }

  SourceRequestResponse _responseWithLease(
    SourceTransportResponse response,
    List<int> bytes,
    SourceRequestCancellation cancellation,
  ) {
    var released = false;
    late SourceRequestResponse result;
    result = SourceRequestResponse(
      statusCode: response.statusCode,
      statusMessage: response.statusMessage,
      headers: response.headers,
      bytes: bytes,
      cancellation: cancellation,
      release: () {
        if (released) return;
        released = true;
        _inFlightBytes -= bytes.length;
        _activeRequests--;
      },
    );
    return result;
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
      if (crossOrigin && (lower == 'authorization' || lower == 'cookie')) {
        continue;
      }
      headers[entry.key] = entry.value;
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

  bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

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
      response.close();
      throw const SourceRequestPolicyException('too_many_response_bodies',
          'Concurrent response body limit exceeded');
    }
    _activeResponseBodies++;
    final bytes = <int>[];
    var retainedBytes = 0;
    var transferredBytes = false;
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
        if (chunk.length > maximumInFlightBytes - _inFlightBytes) {
          completeError(const SourceRequestPolicyException(
              'response_budget_exceeded',
              'In-flight response budget exceeded'));
          unawaited(subscription.cancel());
          return;
        }
        _inFlightBytes += chunk.length;
        retainedBytes += chunk.length;
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
      response.close();
    });

    try {
      final result = await done.future;
      transferredBytes = true;
      return result;
    } finally {
      timer.cancel();
      await subscription.cancel();
      response.close();
      _activeResponseBodies--;
      if (!transferredBytes) _inFlightBytes -= retainedBytes;
    }
  }

  Never _throwCancelled() => throw const SourceRequestPolicyException(
      'cancelled', 'Source request was cancelled');
}
