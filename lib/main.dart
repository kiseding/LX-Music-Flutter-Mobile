import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audio_service/audio_service.dart';
import 'package:lx_music_flutter/app.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';
import 'package:lx_music_flutter/core/audio/playback_cache_service.dart';
import 'package:lx_music_flutter/core/network/play_url_result.dart';
import 'package:lx_music_flutter/features/custom_source/presentation/custom_source_provider.dart';
import 'package:lx_music_flutter/features/search/presentation/search_provider.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_provider.dart';
import 'package:lx_music_flutter/features/download/presentation/download_provider.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';
import 'package:audio_session/audio_session.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. 初始化 audio_service 基础实例
  audioHandler = await AudioService.init(
    builder: () => LxAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.lxmusic.flutter.audio',
      androidNotificationChannelName: 'LX Music Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
      // 预加载锁屏控件，减少后台切歌时控件丢失
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
    ),
  );

  // Handler 必须先存在，中断与路由事件才能应用同一套播放所有权策略。
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  if (audioHandler is LxAudioHandler) {
    final lxHandler = audioHandler as LxAudioHandler;
    session.interruptionEventStream.listen((event) async {
      if (event.type == AudioInterruptionType.duck) return;
      if (event.begin) {
        await lxHandler.beginAudioInterruption();
      } else {
        await lxHandler.endAudioInterruption(
          mayResume: event.type == AudioInterruptionType.pause,
        );
      }
    });
    session.becomingNoisyEventStream.listen((_) async {
      await lxHandler.handleBecomingNoisy();
    });
  }

  // 2. 创建 Riverpod Container 以在应用启动前访问 Providers
  final container = ProviderContainer();

  // 3. 初始化自定义音源
  await container.read(customSourceServiceProvider).init();

  // 3.5 初始化歌单持久化
  await container.read(playlistServiceProvider).init();

  // 3.6 初始化下载服务持久化
  await container.read(downloadServiceProvider).init();

  // 4. 关键：连接 AudioHandler 和 MusicSourceService + 播放缓存
  final playbackCache = PlaybackCacheService();
  await playbackCache.init();

  if (audioHandler is LxAudioHandler) {
    final lxHandler = audioHandler as LxAudioHandler;
    final sourceService = container.read(musicSourceServiceProvider);

    // 设置 URL 解析器：解析远程地址 → 下载到本地缓存 → 返回 file:// 供播放
    lxHandler.urlResolver = (mediaId, [extras]) async {
      debugPrint('[urlResolver] 开始解析: mediaId=$mediaId');
      // 优先用调用方传入的 extras（预加载下一首时 mediaItem 仍是当前曲）
      final Map<String, dynamic>? rawExtras = extras ??
          (lxHandler.mediaItem.value?.id == mediaId
              ? lxHandler.mediaItem.value?.extras
              : null) ??
          () {
            // 仅按 id 从队列查找，禁止回落到“当前曲”extras（会播错歌）
            if (audioHandler is LxAudioHandler) {
              for (final m in (audioHandler as LxAudioHandler).queueItems) {
                if (m.id == mediaId && m.extras != null) {
                  return Map<String, dynamic>.from(m.extras!);
                }
              }
            }
            return null;
          }();
      if (rawExtras != null) {
        final musicItem =
            MusicItem.fromJson(Map<String, dynamic>.from(rawExtras));
        debugPrint(
            '[urlResolver] 歌曲信息: platform=${musicItem.platform}, source=${musicItem.source}, songmid=${musicItem.songmid}');
        final qualityOption = container.read(audioQualityProvider);
        const qualityMap = {
          AudioQualityOption.low: '128k',
          AudioQualityOption.high: '320k',
          AudioQualityOption.lossless: 'flac',
          AudioQualityOption.lossless24: 'flac24bit',
          AudioQualityOption.hires: 'hires',
        };
        // extras 可携带强制音质（改设置后 re-resolve）；否则读全局设置
        final forced = rawExtras['requestedQuality']?.toString();
        final requested = (forced != null && forced.isNotEmpty)
            ? forced
            : (qualityMap[qualityOption] ?? '320k');
        if (audioHandler is LxAudioHandler) {
          (audioHandler as LxAudioHandler).preferredQuality = requested;
        }
        final result = await sourceService.resolvePlayableUrl(
          musicItem,
          preferredQuality: requested,
        );
        if (result == null || !isPlayableMediaUrl(result.url)) {
          debugPrint('[urlResolver] 源未返回可播地址(q=$requested)');
          return null;
        }
        final songId = (musicItem.songmid?.isNotEmpty == true)
            ? musicItem.songmid!
            : (musicItem.hash?.isNotEmpty == true
                ? musicItem.hash!
                : musicItem.id);
        final qualityKey =
            result.actualQuality.isNotEmpty ? result.actualQuality : requested;
        final localPath = await playbackCache.getOrDownload(
          remoteUrl: result.url,
          platform: result.platform,
          songId: songId,
          quality: qualityKey,
        );
        final playUrl = PlaybackCacheService.cachedPlayableUri(localPath);
        if (playUrl == null) {
          debugPrint('[urlResolver] 本地缓存失败(q=$qualityKey)');
          return null;
        }
        final qualityExtras = <String, dynamic>{
          'url': playUrl,
          'remoteUrl': result.url,
          'actualQuality': result.actualQuality,
          'requestedQuality': result.requestedQuality,
          'platform': result.platform,
        };
        final current = lxHandler.mediaItem.value;
        if (current != null && current.id == mediaId) {
          final extras = Map<String, dynamic>.from(current.extras ?? {});
          extras.addAll(qualityExtras);
          lxHandler.mediaItem.add(current.copyWith(extras: extras));
        }
        lxHandler.patchQueueItemExtras(mediaId, qualityExtras);
        return playUrl;
      }
      debugPrint(
          '[urlResolver] 无法获取歌曲信息: mediaId=$mediaId hasExtras=${rawExtras != null}');
      return null;
    };

    // 设置错误消息回调
    lxHandler.onError = (message) {
      container.read(playerMessageProvider.notifier).state = message;
    };
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const LxMusicApp(),
    ),
  );
}
