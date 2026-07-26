import 'package:flutter/material.dart';

/// Headers required by some music CDNs (especially NetEase).
/// Dart/Flutter default User-Agent (`Dart/x.x (dart:io)`) is blocked with 403 HTML.
Map<String, String> artworkRequestHeaders(String url) {
  final lower = url.toLowerCase();
  final isNetease = lower.contains('music.126.net') ||
      lower.contains('126.net') ||
      lower.contains('music.163.com');
  if (!isNetease) return const {};
  return const {
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'Referer': 'https://music.163.com/',
  };
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
    final headers = artworkRequestHeaders(url);
    return Image.network(
      url,
      fit: fit,
      width: width,
      height: height,
      headers: headers.isEmpty ? null : headers,
      errorBuilder: errorBuilder,
      frameBuilder: frameBuilder,
    );
  }
}
