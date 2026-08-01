import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/storage_service.dart';
import '../data/lyrics_translation_service.dart';
import '../domain/lyric.dart';
import 'lyric_provider.dart';

final lyricsTranslationServiceProvider = Provider<LyricsTranslationService>(
  (ref) {
    final service = LyricsTranslationService(() => StorageService.instance);
    unawaited(service.load());
    return service;
  },
);

/// 翻译开关（持久化）。
final lyricsTranslationEnabledProvider = StateNotifierProvider<TranslationEnabledNotifier, bool>(
  (ref) => TranslationEnabledNotifier(() => StorageService.instance),
);

class TranslationEnabledNotifier extends StateNotifier<bool> {
  TranslationEnabledNotifier(this._storageLoader) : super(false) {
    _load();
  }

  final StorageLoader _storageLoader;

  Future<void> _load() async {
    try {
      final storage = await _storageLoader();
      state = storage.getBool('lyrics_translation_enabled') ?? false;
    } catch (_) {
      // 测试环境无 SharedPreferences mock 时静默降级
    }
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    try {
      final storage = await _storageLoader();
      await storage.setBool('lyrics_translation_enabled', value);
    } catch (_) {}
  }
}

/// 当前歌曲每行歌词的翻译结果（key = 歌词行原文）。
final lyricsTranslationsProvider = StateNotifierProvider<LyricsTranslationNotifier, Map<String, String>>(
  (ref) => LyricsTranslationNotifier(
    service: ref.read(lyricsTranslationServiceProvider),
    currentLyric: () => ref.read(currentLyricProvider),
  ),
);

class LyricsTranslationNotifier extends StateNotifier<Map<String, String>> {
  LyricsTranslationNotifier({
    required this.service,
    required this.currentLyric,
  }) : super(const {});

  final LyricsTranslationService service;
  final Lyrics Function() currentLyric;
  final Set<String> _inFlight = {};
  bool _started = false;

  /// 针对当前歌词启动翻译（按顺序逐行填充）。
  void ensureForCurrent() {
    if (_started) return;
    _started = true;
    _run();
  }

  Future<void> _run() async {
    final lyrics = currentLyric();
    for (final line in lyrics.lines) {
      final text = line.text.trim();
      if (text.isEmpty) continue;
      if (line.translation != null && line.translation!.isNotEmpty) continue;
      if (state.containsKey(text)) continue;
      if (_inFlight.contains(text)) continue;

      final cached = service.cached(text, 'zh-CN');
      if (cached != null) {
        if (!mounted) return;
        state = {...state, text: cached};
        continue;
      }
      if (service.isMarkedFailed(text, 'zh-CN')) continue;

      _inFlight.add(text);
      final translated = await service.translate(text);
      _inFlight.remove(text);
      if (translated == null) continue;
      if (!mounted) return;
      state = {...state, text: translated};
    }
  }

  void reset() {
    state = const {};
    _started = false;
    _inFlight.clear();
  }
}
