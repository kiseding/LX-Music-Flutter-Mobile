import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/download_service.dart';
import '../domain/download_task.dart';
import '../../player/domain/music_item.dart';
import '../../search/presentation/search_provider.dart';
import '../../settings/presentation/settings_provider.dart';
import '../../../startup_lifecycle.dart';

final downloadServiceProvider = Provider<DownloadService>((ref) {
  // 不要 watch wifiOnlyDownloadProvider：开关变化会重建本 Provider，
  // 触发 onDispose 取消全部下载且新实例未 init。改为读取一次初始值，
  // 后续开关变化通过 setWifiOnlyDownloadProvider 同步到服务实例。
  final wifiOnly = ref.read(wifiOnlyDownloadProvider);
  final connectivity = Connectivity();
  final service = DownloadService(
    wifiOnly: wifiOnly,
    connectivity: connectivity.onConnectivityChanged.map((results) {
      if (results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet)) {
        return DownloadNetwork.wifi;
      }
      if (results.contains(ConnectivityResult.none)) {
        return DownloadNetwork.none;
      }
      return DownloadNetwork.mobile;
    }),
    currentNetwork: () async {
      final results = await connectivity.checkConnectivity();
      if (results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet)) {
        return DownloadNetwork.wifi;
      }
      if (results.contains(ConnectivityResult.none)) {
        return DownloadNetwork.none;
      }
      return DownloadNetwork.mobile;
    },
  );
  final musicSourceService = ref.watch(musicSourceServiceProvider);
  final disposals = ref.read(resourceDisposalTrackerProvider);
  final disposeService = disposals.register(service.dispose);
  service.setMusicSourceService(musicSourceService);
  final sub = service.tasksStream.listen((_) {
    Future.microtask(() {
      try {
        ref.read(downloadVersionProvider.notifier).state++;
      } catch (_) {}
    });
  });
  ref.onDispose(() {
    sub.cancel();
    disposeService();
  });
  return service;
});

// 同步「仅 WiFi 下载」到下载服务（服务实例保持存活）
final setWifiOnlyDownloadProvider = Provider<void Function(bool)>((ref) {
  return (value) {
    ref.read(downloadServiceProvider).setWifiOnly(value);
  };
});

// 版本号，用于触发 UI 刷新
final downloadVersionProvider = StateProvider<int>((ref) => 0);

// 下载任务列表（同步读取，通过版本号触发刷新）
final downloadTasksProvider = Provider<List<DownloadTask>>((ref) {
  ref.watch(downloadVersionProvider);
  final downloadService = ref.watch(downloadServiceProvider);
  return downloadService.tasks;
});

final downloadCountProvider = Provider<int>((ref) {
  final tasks = ref.watch(downloadTasksProvider);
  return tasks.where((t) => t.status == DownloadStatus.downloading).length;
});

final downloadedCountProvider = Provider<int>((ref) {
  final tasks = ref.watch(downloadTasksProvider);
  return tasks.where((t) => t.status == DownloadStatus.completed).length;
});

// 下载歌曲，使用 downloadQuality 设置
final downloadSongProvider = Provider<Future<void> Function(MusicItem)>((ref) {
  return (MusicItem music) async {
    final downloadService = ref.read(downloadServiceProvider);
    final qualityOption = ref.read(downloadQualityProvider);
    const qualityMap = {
      AudioQualityOption.low: '128k',
      AudioQualityOption.high: '320k',
      AudioQualityOption.lossless: 'flac',
      AudioQualityOption.lossless24: 'flac24bit',
      AudioQualityOption.hires: 'hires',
    };
    await downloadService.addTask(music,
        quality: qualityMap[qualityOption] ?? '320k');
    ref.read(downloadVersionProvider.notifier).state++;
  };
});

// 下载操作（暂停/恢复/取消/重试/删除），操作后刷新 UI
final downloadActionProvider =
    Provider<void Function(String action, String taskId)>((ref) {
  return (String action, String taskId) {
    final downloadService = ref.read(downloadServiceProvider);
    switch (action) {
      case 'pause':
        downloadService.pauseTask(taskId);
        break;
      case 'resume':
        downloadService.resumeTask(taskId);
        break;
      case 'cancel':
        downloadService.cancelTask(taskId);
        break;
      case 'retry':
        downloadService.retryTask(taskId);
        break;
      case 'delete':
        downloadService.deleteDownloaded(taskId);
        break;
    }
    ref.read(downloadVersionProvider.notifier).state++;
  };
});

// 清空缓存
final clearDownloadCacheProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final downloadService = ref.read(downloadServiceProvider);
    await downloadService.clearCache();
    ref.read(downloadVersionProvider.notifier).state++;
  };
});
