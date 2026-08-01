import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import 'artwork_disk_cache.dart';

/// 封面主色提取（primuse CoverTintProvider 的 Flutter 版）。
/// 后台解码 + 缓存，供卡片/播放器背景取色。
class CoverTintProvider {
  final Map<String, Color> _cache = {};
  final Set<String> _inFlight = {};

  Color? get(String artworkUrl) => _cache[artworkUrl];

  Future<Color?> resolve(String artworkUrl) async {
    final hit = _cache[artworkUrl];
    if (hit != null) return hit;
    if (_inFlight.contains(artworkUrl)) return null;
    _inFlight.add(artworkUrl);
    try {
      final file = await ArtworkDiskCache.instance.ensureLocalFile(artworkUrl);
      final bytes = await file?.readAsBytes();
      final color = bytes == null ? null : _dominant(bytes);
      if (color != null) _cache[artworkUrl] = color;
      return color;
    } finally {
      _inFlight.remove(artworkUrl);
    }
  }

  Color? _dominant(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final small = img.copyResize(decoded, width: 48);
    final counts = <int, int>{};
    for (final p in small) {
      if (p.a < 40) continue;
      final r = (p.r.toInt() >> 4) << 8;
      final g = (p.g.toInt() >> 4) << 4;
      final b = p.b.toInt() >> 4;
      final key = (r << 16) | (g << 8) | b;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    var bestKey = counts.keys.first;
    var bestCount = 0;
    counts.forEach((key, count) {
      if (count > bestCount) {
        bestCount = count;
        bestKey = key;
      }
    });
    // 4-bit 量化还原
    final rr = ((bestKey >> 16) & 0xFF) | 0x8;
    final gg = ((bestKey >> 8) & 0xFF) | 0x8;
    final bb = (bestKey & 0xFF) | 0x8;
    return Color.fromARGB(255, rr, gg, bb);
  }
}

final coverTintProvider = Provider<CoverTintProvider>((ref) {
  return CoverTintProvider();
});

/// 异步取封面色。已缓存返回该色；未完成返回 null（调用方用默认背景）。
final coverTintColorProvider = FutureProvider.family<Color?, String>((ref, url) {
  if (url.isEmpty) return null;
  return ref.watch(coverTintProvider).resolve(url);
});
