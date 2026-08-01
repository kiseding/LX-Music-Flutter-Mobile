import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/storage_service.dart';
import '../../player/domain/music_item.dart';
import '../../playlist/presentation/playlist_provider.dart';
import '../../stats/presentation/play_history_provider.dart';
import '../domain/smart_playlist.dart';
import '../domain/smart_playlist_engine.dart';

const String _storageKey = 'smart_playlists_v1';

class SmartPlaylistController extends StateNotifier<List<SmartPlaylist>> {
  SmartPlaylistController(this._storageLoader) : super(const []) {
    unawaited(_load());
  }

  final StorageLoader _storageLoader;
  StorageService? _storage;
  int _revision = 0;
  final StreamController<int> _revisionController =
      StreamController<int>.broadcast();

  Stream<int> get revisions => _revisionController.stream;

  Future<StorageService> _storageAsync() async =>
      _storage ??= await _storageLoader();

  Future<void> _load() async {
    try {
      final storage = await _storageAsync();
      final list = storage
          .getJsonList(_storageKey)
          .map(SmartPlaylist.fromJson)
          .toList();
      state = list;
    } catch (_) {
      state = const [];
    }
  }

  Future<void> create(String name) async {
    final now = DateTime.now();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final smart = SmartPlaylist(id: id, name: name, createdAt: now, updatedAt: now);
    state = [...state, smart];
    await _persist();
  }

  Future<void> update(SmartPlaylist smart) async {
    final updated = _copyWithUpdatedAt(smart);
    state = [
      for (final s in state) s.id == smart.id ? updated : s,
    ];
    await _persist();
  }

  Future<void> delete(String id) async {
    state = state.where((s) => s.id != id).toList();
    await _persist();
  }

  Future<void> _persist() async {
    _revisionController.add(++_revision);
    final storage = await _storageAsync();
    await storage.setJsonList(
      _storageKey,
      state.map((s) => s.toJson()).toList(),
    );
  }

  SmartPlaylist _copyWithUpdatedAt(SmartPlaylist smart) {
    return SmartPlaylist(
      id: smart.id,
      name: smart.name,
      groupCombinator: smart.groupCombinator,
      groups: smart.groups,
      sortField: smart.sortField,
      sortDirection: smart.sortDirection,
      limit: smart.limit,
      createdAt: smart.createdAt,
      updatedAt: DateTime.now(),
    );
  }
}

final smartPlaylistControllerProvider =
    StateNotifierProvider<SmartPlaylistController, List<SmartPlaylist>>(
  (ref) {
    return SmartPlaylistController(() => StorageService.instance);
  },
);

final smartPlaylistRevisionProvider = StreamProvider<int>((ref) {
  return ref.watch(smartPlaylistControllerProvider.notifier).revisions;
});

/// 计算某个智能歌单的命中结果。
final smartPlaylistResultsProvider =
    Provider.family<List<MusicItem>, String>((ref, smartId) {
  SmartPlaylist? smart;
  for (final s in ref.watch(smartPlaylistControllerProvider)) {
    if (s.id == smartId) {
      smart = s;
      break;
    }
  }
  if (smart == null) return const [];

  // 依赖播放历史 / 歌单变更时自动重算
  ref.watch(playHistoryRevisionProvider).value;
  ref.watch(playlistServiceProvider).revisions;

  final playlistService = ref.read(playlistServiceProvider);
  final history = ref.read(playHistoryStoreProvider);

  final songs = <String, MusicItem>{};
  final membership = <String, Set<String>>{};
  for (final playlist in playlistService.playlists) {
    for (final song in playlist.songs) {
      songs[song.id] = song;
      membership.putIfAbsent(song.id, () => <String>{}).add(playlist.id);
    }
  }

  final engine = SmartPlaylistEngine(
    songs: songs.values.toList(),
    playStats: history.playStats,
    playlistMembership: membership,
  );
  return engine.match(smart);
});

final allSongsProvider = Provider<List<MusicItem>>((ref) {
  ref.watch(playlistServiceProvider).revisions;
  final playlistService = ref.read(playlistServiceProvider);
  final seen = <String, MusicItem>{};
  for (final playlist in playlistService.playlists) {
    for (final song in playlist.songs) {
      seen[song.id] = song;
    }
  }
  return seen.values.toList();
});
