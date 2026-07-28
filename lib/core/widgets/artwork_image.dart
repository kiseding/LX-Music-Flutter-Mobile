import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../network/outbound_url.dart';

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
  const ArtworkNetworkImage(this.url, {this.scale = 1.0});

  final String url;
  final double scale;
  String get resolvedUrl => normalizeOutboundUrl(url);

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
      final client = HttpClient();
      final headers = artworkRequestHeaders(key.resolvedUrl);
      if (headers.containsKey('User-Agent')) {
        client.userAgent = headers['User-Agent'];
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

      final bytes = await consolidateHttpClientResponseBytes(
        response,
        onBytesReceived: (cumulative, total) {
          chunkEvents.add(ImageChunkEvent(
            cumulativeBytesLoaded: cumulative,
            expectedTotalBytes: total,
          ));
        },
      );
      client.close(force: true);

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
