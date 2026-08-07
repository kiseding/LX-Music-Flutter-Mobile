import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/music_source_service.dart';
import 'package:lx_music_flutter/core/music_source/platform/built_in_source_manager.dart';
import 'package:lx_music_flutter/core/music_source/platform/music_platform.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

void main() {
  test('quality candidates deduplicate equal adapter attempt keys', () {
    final calls = <String>[];
    final qualities = MusicSourceService.uniqueQualityCandidates(
      'hires',
      attemptKey: (quality) {
        calls.add(quality);
        return switch (quality) {
          'hires' || 'flac24bit' || 'flac' => 'flac',
          '320k' || '192k' || '128k' => 'mp3',
          _ => null,
        };
      },
    );

    expect(qualities, ['hires', '320k']);
    expect(calls, MusicSourceService.qualityChain('hires'));
  });

  test('coordinator invokes each underlying adapter attempt key once',
      () async {
    final platform = _RecordingPlatform();
    final service = MusicSourceService(
      CustomSourceService(),
      builtInSources: BuiltInSourceManager(platforms: [platform]),
      hasEnabledCustomSources: () => false,
    );
    final music = MusicItem(
      id: 'song',
      name: 'Song',
      singer: 'Singer',
      source: 'kw',
      platform: 'kw',
    );

    await service.resolvePlayableUrl(music, preferredQuality: 'hires');

    expect(platform.attemptKeys, ['flac', 'mp3']);
  });
}

class _RecordingPlatform extends MusicPlatform {
  final attemptKeys = <String>[];

  @override
  String get id => 'kw';

  @override
  String get name => 'Recording';

  @override
  String? exactAttemptKey(String quality) =>
      quality == 'hires' || quality == 'flac24bit' || quality == 'flac'
          ? 'flac'
          : 'mp3';

  @override
  Future<ExactPlayUrl?> getMusicUrlExactDetailed(MusicItem music,
      {required String quality}) async {
    attemptKeys.add(exactAttemptKey(quality)!);
    return null;
  }

  @override
  Future<String?> getMusicUrl(MusicItem music,
          {String quality = '128k'}) async =>
      null;

  @override
  Future<String?> getLyric(MusicItem music) async => null;

  @override
  MusicItem parseItem(Map<String, dynamic> raw, String source) =>
      throw UnimplementedError();

  @override
  Future<List<MusicItem>> search(String keyword,
          {int page = 1, int limit = 20}) async =>
      [];
}
