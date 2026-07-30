import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../network/outbound_url.dart';
import 'artwork_disk_cache.dart';

/// Headers / client identity required by some music CDNs (especially NetEase).
///
/// Critical: [NetworkImage] uses `HttpHeaders.add`, so a custom User-Agent is
/// **appended** to the default `Dart/x.x (dart:io)` UA. NetEase CDN then still
/// sees the Dart UA and returns 403 HTML. We must set [HttpClient.userAgent]
/// (or `headers.set`) so only one browser UA is sent.
const String kArtworkUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

Map<String, String> artworkRequestHeaders(String url) {
  final lower = url.toLowerCase();
  final isNetease = lower.contains('music.126.net') ||
      lower.contains('126.net') ||
      lower.contains('music.163.com');
  if (!isNetease) return const {};
  return const {
    'User-Agent': kArtworkUserAgent,
    'Referer': 'https://music.163.com/',
  };
}

bool artworkNeedsBrowserClient(String url) {
  return artworkRequestHeaders(url).isNotEmpty;
}

class ArtworkLimitException implements Exception {
  ArtworkLimitException(this.message);
  final String message;

  @override
  String toString() => 'ArtworkLimitException: $message';
}

/// Minimal HTTP client surface used by [ArtworkBytesLoader].
abstract interface class ArtworkHttpClient {
  Future<HttpClientRequest> getUrl(Uri url);
  void close({bool force = false});
  set userAgent(String? value);
}

typedef ArtworkClientFactory = ArtworkHttpClient Function();

class _IoArtworkHttpClient implements ArtworkHttpClient {
  _IoArtworkHttpClient() : _client = HttpClient();

  final HttpClient _client;

  @override
  set userAgent(String? value) {
    _client.userAgent = value;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _client.getUrl(url);

  @override
  void close({bool force = false}) => _client.close(force: force);
}

/// Bounded download of artwork bytes with forced client close.
class ArtworkBytesLoader {
  ArtworkBytesLoader({
    ArtworkClientFactory? createClient,
    this.maximumBytes = 8 * 1024 * 1024,
    this.timeout = const Duration(seconds: 12),
  }) : createClient = createClient ?? _IoArtworkHttpClient.new;

  final ArtworkClientFactory createClient;
  final int maximumBytes;
  final Duration timeout;

  Future<Uint8List> load(
    Uri uri,
    Map<String, String> headers,
    void Function(int, int?) onProgress,
  ) async {
    final client = createClient();
    try {
      return await _loadWithClient(client, uri, headers, onProgress)
          .timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _loadWithClient(
    ArtworkHttpClient client,
    Uri uri,
    Map<String, String> headers,
    void Function(int, int?) onProgress,
  ) async {
    final userAgent = _headerValue(headers, 'user-agent');
    if (userAgent != null) {
      client.userAgent = userAgent;
    }

    final request = await client.getUrl(uri);
    headers.forEach((name, value) {
      if (name.toLowerCase() == 'user-agent') return;
      request.headers.set(name, value);
    });

    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw NetworkImageLoadException(
        statusCode: response.statusCode,
        uri: uri,
      );
    }

    final declared = response.contentLength;
    if (declared > maximumBytes) {
      await response.drain<void>();
      throw ArtworkLimitException(
        'Content-Length $declared exceeds maximumBytes $maximumBytes',
      );
    }

    final builder = BytesBuilder(copy: false);
    var cumulative = 0;
    final expected = declared >= 0 ? declared : null;

    await for (final chunk in response) {
      cumulative += chunk.length;
      if (cumulative > maximumBytes) {
        throw ArtworkLimitException(
          'Streamed body $cumulative exceeds maximumBytes $maximumBytes',
        );
      }
      builder.add(chunk);
      onProgress(cumulative, expected);
    }

    return builder.takeBytes();
  }

  static String? _headerValue(Map<String, String> headers, String name) {
    final target = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == target) return entry.value;
    }
    return null;
  }
}

class ArtworkImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;
  final Widget Function(BuildContext, Widget, int?, bool)? frameBuilder;

  const ArtworkImage(
    this.url, {
    super.key,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.errorBuilder,
    this.frameBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Image(
      image: ArtworkNetworkImage(url),
      fit: fit,
      width: width,
      height: height,
      errorBuilder: errorBuilder,
      frameBuilder: frameBuilder,
    );
  }
}

@immutable
class ArtworkNetworkImage extends ImageProvider<ArtworkNetworkImage> {
  const ArtworkNetworkImage(this.url, {this.scale = 1.0, this.loader});

  final String url;
  final double scale;
  final ArtworkBytesLoader? loader;

  String get resolvedUrl => normalizeOutboundUrl(url);

  ArtworkBytesLoader get _loader => loader ?? ArtworkBytesLoader();

  @override
  Future<ArtworkNetworkImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<ArtworkNetworkImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    ArtworkNetworkImage key,
    ImageDecoderCallback decode,
  ) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<ArtworkNetworkImage>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    ArtworkNetworkImage key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      assert(key == this);
      final uri = Uri.parse(key.resolvedUrl);
      final headers = artworkRequestHeaders(key.resolvedUrl);
      // Prefer 12h disk cache (shared with lock-screen art download).
      Uint8List? bytes = await ArtworkDiskCache.instance.bytesForUrl(
        key.resolvedUrl,
      );
      bytes ??= await key._loader.load(
        uri,
        headers,
        (cumulative, total) {
          chunkEvents.add(ImageChunkEvent(
            cumulativeBytesLoaded: cumulative,
            expectedTotalBytes: total,
          ));
        },
      );
      if (bytes.isNotEmpty) {
        unawaited(ArtworkDiskCache.instance.put(key.resolvedUrl, bytes));
      }

      if (bytes.lengthInBytes == 0) {
        throw Exception('ArtworkNetworkImage is an empty file: $uri');
      }
      // NetEase sometimes returns tiny HTML error pages with 200; reject them.
      if (bytes.lengthInBytes < 200 &&
          bytes.isNotEmpty &&
          (bytes[0] == 0x3C /* < */)) {
        throw Exception('ArtworkNetworkImage got HTML instead of image: $uri');
      }

      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return decode(buffer);
    } catch (e) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      chunkEvents.close();
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is ArtworkNetworkImage &&
        other.url == url &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'ArtworkNetworkImage')}("$url", scale: ${scale.toStringAsFixed(1)})';
}
