import 'source_pinned_transport.dart';
import 'source_request_policy.dart';

/// Source requests must use the validated addresses from the Dart policy.
/// URLSession resolves the hostname again, so using it here would reintroduce
/// DNS rebinding between validation and connection.
class IOSSourceTransport {
  final SourcePinnedTransport fallback;

  IOSSourceTransport({
    SourcePinnedTransport? fallback,
    int maximumResponseBytes = 10 * 1024 * 1024,
  }) : fallback = fallback ?? SourcePinnedTransport();

  Future<SourceTransportResponse> call(
    ValidatedSourceRequest request,
    SourceRequestCancellation cancellation,
  ) => fallback.call(request, cancellation);
}
