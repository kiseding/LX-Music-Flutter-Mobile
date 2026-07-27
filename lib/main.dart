import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audio_service/audio_service.dart';
import 'package:lx_music_flutter/app.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';
import 'package:lx_music_flutter/core/audio/playback_cache_service.dart';
import 'package:lx_music_flutter/core/network/music_source_service.dart';
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

  // 初始化音频会话，确保正确处理音频焦点 / 锁屏后台连播
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  // 播放开始时激活会话；中断结束后若用户仍想播则恢复
  session.interruptionEventStream.listen((event) async {
    if (event.begin) return;
    if (audioHandler is LxAudioHandler) {
      final h = audioHandler as LxAudioHandler;
      if (h.player.playing == false) {
        // 不强制恢复；由系统/用户控制
      }
    }
  });

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
        // 完整降级链：hires→flac24bit→flac→320k→…→128k
        final qualitiesToTry = MusicSourceService.qualityChain(requested);
        String? lastFail;
        PlayUrlResult? bestBelow;
        for (final cacheQuality in qualitiesToTry) {
          debugPrint('[urlResolver] 尝试音质 q=$cacheQuality');
          final result = await sourceService.getPlayUrlDetailed(
            musicItem,
            quality: cacheQuality,
          );
          if (result == null) {
            lastFail = '源未返回地址(q=$cacheQuality)';
            debugPrint('[urlResolver] $lastFail');
            continue;
          }
          if (!isPlayableMediaUrl(result.url)) {
            lastFail =
                '无效地址(q=$cacheQuality host=${Uri.tryParse(result.url)?.host} path=${Uri.tryParse(result.url)?.path})';
            debugPrint('[urlResolver] $lastFail');
            continue;
          }
          // 源用低码率冒充高音质：继续降级尝试，最后再接受偏低结果
          if (MusicSourceService.isQualityBelow(
                  result.actualQuality, requested) &&
              cacheQuality == requested) {
            debugPrint(
                '[urlResolver] q=$cacheQuality 实际=${result.actualQuality} 偏低，继续');
            bestBelow ??= result;
            continue;
          }
          bestBelow = null;
          final songId = (musicItem.songmid?.isNotEmpty == true)
              ? musicItem.songmid!
              : (musicItem.hash?.isNotEmpty == true
                  ? musicItem.hash!
                  : musicItem.id);
          final qualityKey = result.actualQuality.isNotEmpty
              ? result.actualQuality
              : cacheQuality;
          debugPrint(
              '[urlResolver] 开始缓存 q=$qualityKey songId=$songId host=${Uri.tryParse(result.url)?.host}');
          final localPath = await playbackCache.getOrDownload(
            remoteUrl: result.url,
            platform: result.platform,
            songId: songId,
            quality: qualityKey,
          );
          // 方案 A：只播放本地缓存。缓存失败时不回退网络直播。
          final playUrl = PlaybackCacheService.cachedPlayableUri(localPath);
          if (playUrl == null) {
            lastFail = '本地缓存失败(q=$cacheQuality)';
            debugPrint('[urlResolver] $lastFail，尝试下一级音质');
            continue;
          }
          // 写回 mediaItem + 队列同 id 项，保证 UI 读到 actualQuality
          final qualityExtras = <String, dynamic>{
            'url': playUrl,
            'remoteUrl': result.url,
            'actualQuality': result.actualQuality,
            'requestedQuality': requested,
            'platform': result.platform,
          };
          final current = lxHandler.mediaItem.value;
          if (current != null && current.id == mediaId) {
            final extras = Map<String, dynamic>.from(current.extras ?? {});
            extras.addAll(qualityExtras);
            lxHandler.mediaItem.add(current.copyWith(extras: extras));
          }
          lxHandler.patchQueueItemExtras(mediaId, qualityExtras);
          debugPrint(
              '[urlResolver] 成功 q=${result.actualQuality} local=true ${playUrl.length > 80 ? playUrl.substring(0, 80) : playUrl}');
          return playUrl;
        }
        // 请求档全部失败时，接受之前保留的偏低可播结果
        if (bestBelow != null) {
          final songId = (musicItem.songmid?.isNotEmpty == true)
              ? musicItem.songmid!
              : (musicItem.hash?.isNotEmpty == true
                  ? musicItem.hash!
                  : musicItem.id);
          final qualityKey = bestBelow.actualQuality.isNotEmpty
              ? bestBelow.actualQuality
              : requested;
          final localPath = await playbackCache.getOrDownload(
            remoteUrl: bestBelow.url,
            platform: bestBelow.platform,
            songId: songId,
            quality: qualityKey,
          );
          final playUrl = PlaybackCacheService.cachedPlayableUri(localPath);
          if (playUrl != null) {
            final qualityExtras = <String, dynamic>{
              'url': playUrl,
              'remoteUrl': bestBelow.url,
              'actualQuality': bestBelow.actualQuality,
              'requestedQuality': requested,
              'platform': bestBelow.platform,
            };
            final current = lxHandler.mediaItem.value;
            if (current != null && current.id == mediaId) {
              final extras = Map<String, dynamic>.from(current.extras ?? {});
              extras.addAll(qualityExtras);
              lxHandler.mediaItem.add(current.copyWith(extras: extras));
            }
            lxHandler.patchQueueItemExtras(mediaId, qualityExtras);
            debugPrint('[urlResolver] 使用偏低结果 q=${bestBelow.actualQuality}');
            return playUrl;
          }
        }
        debugPrint('[urlResolver] 全部失败 last=$lastFail');
        return null;
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
