import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_app_group_directory/flutter_app_group_directory.dart';
import 'package:home_widget/home_widget.dart';
import 'package:live_activities/live_activities.dart';

import '../../../core/audio/audio_handler.dart';
import '../../../core/widgets/artwork_disk_cache.dart';
import '../domain/music_item.dart';

const String _appGroupId = 'group.com.lxmusic.lxMusicFlutter';
const String _widgetKind = 'LXMusicHomeWidget';
const String _activityId = 'lx_music_now_playing';

/// Syncs the current song to the iOS home widget and Live Activity.
class LockScreenSyncService {
  LockScreenSyncService(this._handler);

  final LxAudioHandler _handler;
  final LiveActivities _liveActivities = LiveActivities();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _positionTimer;
  String? _lastMusicKey;
  String? _artworkPath;
  bool _disposed = false;

  Future<void> init() async {
    try {
      await HomeWidget.setAppGroupId(_appGroupId);
      await _liveActivities.init(
        appGroupId: _appGroupId,
        requestAndroidNotificationPermission: false,
      );
      _subscriptions.add(_handler.mediaItem.listen((_) => _syncNow()));
      _subscriptions.add(_handler.playbackState.listen((_) => _syncNow()));
      _positionTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _syncPosition(),
      );
      await _syncNow();
    } catch (e) {
      debugPrint('[LockScreenSync] init failed: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _positionTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> _syncNow() async {
    if (_disposed) return;
    try {
      final item = _handler.mediaItem.value;
      if (item == null) {
        await _clearNowPlaying();
        return;
      }
      final playing = _handler.playbackState.value.playing;
      final music = _musicFromItem(item);
      final key = '${music.id}|${music.artwork}';
      if (key != _lastMusicKey) {
        _lastMusicKey = key;
        _artworkPath = null;
      }
      await _saveArtwork(music);
      final positionMs = _positionMs();
      final durationMs = _durationMs(music);
      await HomeWidget.saveWidgetData<String>('title', music.name);
      await HomeWidget.saveWidgetData<String>('artist', music.singer);
      await HomeWidget.saveWidgetData<String>('album', music.album);
      await HomeWidget.saveWidgetData<String>('artworkPath', _artworkPath);
      await HomeWidget.saveWidgetData<bool>('playing', playing);
      await HomeWidget.saveWidgetData<double>(
        'positionMs',
        positionMs.toDouble(),
      );
      await HomeWidget.saveWidgetData<double>(
        'durationMs',
        durationMs.toDouble(),
      );
      await HomeWidget.updateWidget(iOSName: _widgetKind);

      if (Platform.isIOS) {
        await _liveActivities.createOrUpdateActivity(
          _activityId,
          {
            'title': music.name,
            'artist': music.singer,
            'album': music.album,
            'artworkPath': _artworkPath ?? '',
            'playing': playing,
            'positionMs': positionMs.toDouble(),
            'durationMs': durationMs.toDouble(),
          },
          iOSEnableRemoteUpdates: false,
        );
      }
    } catch (e) {
      debugPrint('[LockScreenSync] sync failed: $e');
    }
  }

  Future<void> _syncPosition() async {
    if (_disposed || _handler.mediaItem.value == null) return;
    try {
      await HomeWidget.saveWidgetData<double>(
        'positionMs',
        _positionMs().toDouble(),
      );
      await HomeWidget.updateWidget(iOSName: _widgetKind);
    } catch (e) {
      debugPrint('[LockScreenSync] position sync failed: $e');
    }
  }

  Future<void> _clearNowPlaying() async {
    _lastMusicKey = null;
    _artworkPath = null;
    for (final key in ['title', 'artist', 'album', 'artworkPath']) {
      await HomeWidget.saveWidgetData<String>(key, null);
    }
    await HomeWidget.saveWidgetData<bool>('playing', false);
    await HomeWidget.saveWidgetData<double>('positionMs', 0);
    await HomeWidget.saveWidgetData<double>('durationMs', 0);
    await HomeWidget.updateWidget(iOSName: _widgetKind);
    if (Platform.isIOS) {
      try {
        await _liveActivities.endActivity(_activityId);
      } catch (e) {
        debugPrint('[LockScreenSync] end activity failed: $e');
      }
    }
  }

  MusicItem _musicFromItem(MediaItem item) {
    if (item.extras != null) {
      final music = MusicItem.fromJson(Map<String, dynamic>.from(item.extras!));
      final platform = item.extras!['platform']?.toString();
      if (platform != null &&
          platform.isNotEmpty &&
          music.platform != platform) {
        return music.copyWith(platform: platform);
      }
      return music;
    }
    return MusicItem(
      id: item.id,
      name: item.title,
      singer: item.artist ?? '未知歌手',
      album: item.album ?? '',
      duration: item.duration ?? Duration.zero,
      source: 'unknown',
      artwork: item.artUri?.toString(),
    );
  }

  int _positionMs() {
    final position = _handler.player.position;
    final duration = _handler.player.duration;
    if (duration != null &&
        duration > Duration.zero &&
        position > duration) {
      return duration.inMilliseconds;
    }
    return position.inMilliseconds.clamp(0, 1 << 40).toInt();
  }

  int _durationMs(MusicItem music) {
    final playerDuration = _handler.player.duration;
    if (playerDuration != null && playerDuration > Duration.zero) {
      return playerDuration.inMilliseconds;
    }
    return music.duration.inMilliseconds;
  }

  Future<void> _saveArtwork(MusicItem music) async {
    if (_artworkPath != null) return;
    final url = music.artwork;
    if (url == null || url.isEmpty) return;
    try {
      final file = await ArtworkDiskCache.instance.ensureLocalFile(url);
      if (file == null || !await file.exists()) return;
      final bytes = await file.readAsBytes();
      final directory = await FlutterAppGroupDirectory.getAppGroupDirectory(
        _appGroupId,
      );
      if (directory == null) return;
      final artworkFile = File('${directory.path}/home_widget/artwork.img');
      await artworkFile.parent.create(recursive: true);
      await artworkFile.writeAsBytes(bytes, flush: true);
      _artworkPath = artworkFile.path;
      await HomeWidget.saveWidgetData<String>('artworkPath', _artworkPath);
    } catch (e) {
      debugPrint('[LockScreenSync] artwork save failed: $e');
    }
  }
}
