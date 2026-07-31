import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audio_service/audio_service.dart';
import 'package:lx_music_flutter/app.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';
import 'package:lx_music_flutter/core/audio/audio_runtime.dart';
import 'package:lx_music_flutter/core/audio/playback_cache_service.dart';
import 'package:lx_music_flutter/features/custom_source/presentation/custom_source_provider.dart';
import 'package:lx_music_flutter/features/search/presentation/search_provider.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_provider.dart';
import 'package:lx_music_flutter/features/download/presentation/download_provider.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lx_music_flutter/features/playlist/data/file_playlist_repository.dart';
import 'package:lx_music_flutter/startup_lifecycle.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 创建 Riverpod Container 以在应用启动前访问 Providers
  final preferences = await SharedPreferences.getInstance();
  final documents = await getApplicationDocumentsDirectory();
  final playlistRepository = FilePlaylistRepository(
    directory: () async => documents,
    preferences: preferences,
  );
  final disposals = ResourceDisposalTracker();
  final container = ProviderContainer(overrides: [
    playlistRepositoryProvider.overrideWithValue(playlistRepository),
    resourceDisposalTrackerProvider.overrideWithValue(disposals),
  ]);
  final lifecycle = StartupLifecycle(container, disposals);

  await lifecycle.run(() async {
    final lxHandler = LxAudioHandler();
    final runtime = await initializeOwnedAudioRuntime(
      registerDisposal: disposals.register,
      disposeHandler: lxHandler.dispose,
      initialize: (_) async {},
    );
    audioHandler = await AudioService.init(
      builder: () => lxHandler,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.lxmusic.flutter.audio',
        androidNotificationChannelName: 'LX Music Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationIcon: 'mipmap/ic_launcher',
        fastForwardInterval: Duration(seconds: 10),
        rewindInterval: Duration(seconds: 10),
      ),
    );
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    runtime.attachAudioSession<AudioInterruptionEvent>(
      interruptionEvents: session.interruptionEventStream,
      noisyEvents: session.becomingNoisyEventStream,
      onInterruption: (event) async {
        if (event.type == AudioInterruptionType.duck) return;
        if (event.begin) {
          await lxHandler.beginAudioInterruption();
        } else {
          await lxHandler.endAudioInterruption(
            mayResume: event.type == AudioInterruptionType.pause,
          );
        }
      },
      onNoisy: lxHandler.handleBecomingNoisy,
    );

    // 3. 初始化自定义音源
    await container.read(customSourceServiceProvider).init();

    // 3.5 初始化歌单持久化
    await container.read(playlistServiceProvider).init();

    // 3.6 初始化下载服务持久化
    await container.read(downloadServiceProvider).init();

    // 4. 关键：连接 AudioHandler 和 MusicSourceService + 播放缓存
    final playbackCache = PlaybackCacheService();
    runtime.ownCache(playbackCache.dispose);
    await playbackCache.init();

    {
      final sourceService = container.read(musicSourceServiceProvider);
      final playbackResolver = PlaybackUrlResolver<MusicItem>(
        resolvePlayableUrl: (music, {required preferredQuality}) {
          return sourceService.resolvePlayableUrl(
            music,
            preferredQuality: preferredQuality,
          );
        },
        acquireOrDownload: playbackCache.acquireOrDownload,
        cancelCacheKey: playbackCache.cancelKey,
        songIdFor: (music) {
          if (music.songmid?.isNotEmpty == true) return music.songmid!;
          if (music.hash?.isNotEmpty == true) return music.hash!;
          return music.id;
        },
      );
      lxHandler.attachPlaybackCache(
        classifyExisting: playbackCache.classifyExisting,
        acquireExisting: playbackCache.acquireExisting,
        cancelCacheKey: playbackCache.cancelKey,
        cancelAllTrackedCacheWork: playbackResolver.cancelAllTracked,
      );

      // 设置 URL 解析器：音质一次解析 → 租约缓存或已校验流式 HTTPS
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
          final isCurrent = lxHandler.mediaItem.value?.id == mediaId;
          final resolution = await playbackResolver.resolve(
            musicItem,
            preferredQuality: requested,
            exclusive: isCurrent,
          );
          if (resolution == null) {
            debugPrint('[urlResolver] 源未返回可播地址(q=$requested)');
            return null;
          }
          final resolutionGeneration = rawExtras['_playbackGeneration'];
          final preloadRequestToken = rawExtras['_preloadRequestToken'];
          if (resolutionGeneration is int) {
            lxHandler.acceptResolvedPlayback(
              mediaId: mediaId,
              generation: resolutionGeneration,
              resolution: resolution,
            );
          } else if (preloadRequestToken is int) {
            lxHandler.acceptPreloadedPlayback(
              mediaId: mediaId,
              requestToken: preloadRequestToken,
              resolution: resolution,
            );
          } else {
            // Resolutions without handler authority retain no playback lease.
            await resolution.leaseOrNull?.release();
          }
          return resolution.playableUrl;
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

    // 恢复上次播放会话：默认只加载队列并暂停，自动恢复由设置控制
    await restorePlaybackSession(
      container: container,
      autoplay: preferences.getBool('auto_resume_playback') ?? false,
    );

    runApp(
      OwnedProviderScope(
        lifecycle: lifecycle,
        child: const LxMusicApp(),
      ),
    );
  });
}
