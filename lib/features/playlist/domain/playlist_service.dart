import 'dart:async';

import '../../player/domain/music_item.dart';
import '../data/playlist_repository.dart';
import 'playlist.dart';

class PlaylistService {
  PlaylistService({
    required PlaylistRepository repository,
    DateTime Function()? clock,
    String Function()? createId,
  })  : _repository = repository,
        _clock = clock ?? DateTime.now,
        _createId = createId ??
            (() => DateTime.now().microsecondsSinceEpoch.toString());

  final PlaylistRepository _repository;
  final DateTime Function() _clock;
  final String Function() _createId;
  final List<Playlist> _playlists = [];
  final StreamController<int> _revisionController =
      StreamController<int>.broadcast();

  Future<void> _tail = Future.value();
  bool _initialized = false;
  int _revision = 0;

  List<Playlist> get playlists => List.unmodifiable(_playlists);
  int get revision => _revision;
  Stream<int> get revisions => _revisionController.stream;

  Future<void> init() async {
    if (_initialized) return;

    final loaded = await _repository.load();
    final repaired = _withSystemPlaylists(loaded.playlists);
    final needsRepair = repaired.length != loaded.playlists.length;
    if (needsRepair) {
      await _mutate<void>((_) => (
            next: repaired,
            result: null,
            changed: true,
          ));
    } else {
      _playlists.addAll(loaded.playlists);
    }
    _initialized = true;
  }

  Future<Playlist> createPlaylist({
    required String name,
    String? description,
    List<MusicItem> songs = const [],
    String? id,
  }) {
    return _mutate((current) {
      final now = _clock();
      final created = Playlist(
        id: id ?? _createId(),
        name: name,
        description: description,
        songs: List.unmodifiable(songs),
        createdAt: now,
        updatedAt: now,
      );
      return (
        next: [...current, created],
        result: created,
        changed: true,
      );
    });
  }

  Future<Playlist> updatePlaylist({
    required String id,
    String? name,
    String? description,
    String? coverUrl,
    List<MusicItem>? songs,
  }) {
    return _mutate((current) {
      final index = _indexOf(current, id);
      final existing = current[index];
      final changed = (name != null && name != existing.name) ||
          (description != null && description != existing.description) ||
          (coverUrl != null && coverUrl != existing.coverUrl) ||
          (songs != null && !_sameSongOrder(songs, existing.songs));
      if (!changed) {
        return (next: current, result: existing, changed: false);
      }

      final updated = existing.copyWith(
        name: name,
        description: description,
        coverUrl: coverUrl,
        songs: songs == null ? null : List.unmodifiable(songs),
        updatedAt: _clock(),
      );
      final next = [...current]..[index] = updated;
      return (next: next, result: updated, changed: true);
    });
  }

  Future<bool> deletePlaylist(String id) {
    if (_isSystemPlaylist(id)) {
      return Future.error(StateError('System playlists cannot be deleted'));
    }
    return _mutate((current) {
      final index = current.indexWhere((playlist) => playlist.id == id);
      if (index < 0) return (next: current, result: false, changed: false);
      final next = [...current]..removeAt(index);
      return (next: next, result: true, changed: true);
    });
  }

  Playlist? getPlaylist(String id) {
    final index = _playlists.indexWhere((playlist) => playlist.id == id);
    return index < 0 ? null : _playlists[index];
  }

  Future<bool> addSongToPlaylist(String playlistId, MusicItem song) {
    return _mutate((current) {
      final index = _indexOf(current, playlistId);
      final existing = current[index];
      if (existing.songs.any((item) => item.id == song.id)) {
        return (next: current, result: false, changed: false);
      }
      final updated = existing.copyWith(
        songs: List.unmodifiable([...existing.songs, song]),
        updatedAt: _clock(),
      );
      final next = [...current]..[index] = updated;
      return (next: next, result: true, changed: true);
    });
  }

  Future<bool> removeSongFromPlaylist(String playlistId, String songId) {
    return _mutate((current) {
      final index = _indexOf(current, playlistId);
      final existing = current[index];
      if (!existing.songs.any((song) => song.id == songId)) {
        return (next: current, result: false, changed: false);
      }
      final updated = existing.copyWith(
        songs: List.unmodifiable(
          existing.songs.where((song) => song.id != songId),
        ),
        updatedAt: _clock(),
      );
      final next = [...current]..[index] = updated;
      return (next: next, result: true, changed: true);
    });
  }

  bool isSongInPlaylist(String playlistId, String songId) {
    return getPlaylist(playlistId)?.songs.any((song) => song.id == songId) ??
        false;
  }

  Future<bool> sortSongsInPlaylist(
    String playlistId, {
    required int oldIndex,
    required int newIndex,
  }) {
    return _mutate((current) {
      final index = _indexOf(current, playlistId);
      final existing = current[index];
      final songs = [...existing.songs];
      var destination = newIndex;
      if (oldIndex < destination) destination--;
      if (oldIndex == destination) {
        return (next: current, result: false, changed: false);
      }
      final item = songs.removeAt(oldIndex);
      songs.insert(destination, item);
      final updated = existing.copyWith(
        songs: List.unmodifiable(songs),
        updatedAt: _clock(),
      );
      final next = [...current]..[index] = updated;
      return (next: next, result: true, changed: true);
    });
  }

  Future<bool> sortSongsByName(String playlistId, {bool ascending = true}) {
    return _sortSongs(
      playlistId,
      (a, b) => a.name.compareTo(b.name),
      ascending,
    );
  }

  Future<bool> sortSongsByArtist(String playlistId, {bool ascending = true}) {
    return _sortSongs(
      playlistId,
      (a, b) => a.singer.compareTo(b.singer),
      ascending,
    );
  }

  Future<bool> sortSongsByDuration(String playlistId, {bool ascending = true}) {
    return _sortSongs(
      playlistId,
      (a, b) => a.duration.compareTo(b.duration),
      ascending,
    );
  }

  Future<bool> addToRecent(MusicItem song) {
    return _mutate((current) {
      final index = _indexOf(current, 'recent');
      final existing = current[index];
      if (existing.songs.isNotEmpty &&
          existing.songs.first.id == song.id &&
          existing.songs.length <= 100) {
        return (next: current, result: false, changed: false);
      }

      final songs = [
        song,
        ...existing.songs.where((item) => item.id != song.id),
      ];
      if (songs.length > 100) songs.removeRange(100, songs.length);
      final updated = existing.copyWith(
        songs: List.unmodifiable(songs),
        updatedAt: _clock(),
      );
      final next = [...current]..[index] = updated;
      return (next: next, result: true, changed: true);
    });
  }

  Future<int> addAllSongsToFavorites(String playlistId) {
    return _mutate((current) {
      final source = current[_indexOf(current, playlistId)];
      final favoritesIndex = _indexOf(current, 'favorites');
      final favorites = current[favoritesIndex];
      final ids = favorites.songs.map((song) => song.id).toSet();
      final additions = source.songs.where((song) => ids.add(song.id)).toList();
      if (additions.isEmpty) {
        return (next: current, result: 0, changed: false);
      }
      final updated = favorites.copyWith(
        songs: List.unmodifiable([...favorites.songs, ...additions]),
        updatedAt: _clock(),
      );
      final next = [...current]..[favoritesIndex] = updated;
      return (next: next, result: additions.length, changed: true);
    });
  }

  Future<void> replaceAll(List<Playlist> playlists) {
    return _mutate<void>((_) => (
          next: List<Playlist>.unmodifiable(playlists),
          result: null,
          changed: true,
        ));
  }

  Playlist? get favorites => getPlaylist('favorites');
  Playlist? get recent => getPlaylist('recent');

  Future<void> dispose() => _revisionController.close();

  Future<bool> _sortSongs(
    String playlistId,
    int Function(MusicItem, MusicItem) compare,
    bool ascending,
  ) {
    return _mutate((current) {
      final index = _indexOf(current, playlistId);
      final existing = current[index];
      final songs = [...existing.songs]
        ..sort((a, b) => ascending ? compare(a, b) : -compare(a, b));
      if (_sameSongOrder(songs, existing.songs)) {
        return (next: current, result: false, changed: false);
      }
      final updated = existing.copyWith(
        songs: List.unmodifiable(songs),
        updatedAt: _clock(),
      );
      final next = [...current]..[index] = updated;
      return (next: next, result: true, changed: true);
    });
  }

  Future<T> _mutate<T>(
    FutureOr<({List<Playlist> next, T result, bool changed})> Function(
      List<Playlist> current,
    ) operation,
  ) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        final mutation =
            await operation(List<Playlist>.unmodifiable(_playlists));
        if (!mutation.changed) {
          completer.complete(mutation.result);
          return;
        }

        final snapshot = PlaylistSnapshot(
          schemaVersion: 1,
          playlists: _withSystemPlaylists(mutation.next),
        );
        await _repository.save(snapshot);
        _playlists
          ..clear()
          ..addAll(snapshot.playlists);
        _revisionController.add(++_revision);
        completer.complete(mutation.result);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  List<Playlist> _withSystemPlaylists(List<Playlist> source) {
    final result = [...source];
    if (!result.any((playlist) => playlist.id == 'favorites')) {
      result.add(_systemPlaylist(
        id: 'favorites',
        name: '我喜欢',
        description: '收藏的歌曲',
      ));
    }
    if (!result.any((playlist) => playlist.id == 'recent')) {
      result.add(_systemPlaylist(
        id: 'recent',
        name: '最近播放',
        description: '最近播放的歌曲',
      ));
    }
    return List.unmodifiable(result);
  }

  Playlist _systemPlaylist({
    required String id,
    required String name,
    required String description,
  }) {
    final now = _clock();
    return Playlist(
      id: id,
      name: name,
      description: description,
      createdAt: now,
      updatedAt: now,
    );
  }

  int _indexOf(List<Playlist> playlists, String id) {
    final index = playlists.indexWhere((playlist) => playlist.id == id);
    if (index < 0) throw StateError('Playlist $id does not exist');
    return index;
  }

  bool _sameSongOrder(List<MusicItem> left, List<MusicItem> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index].id != right[index].id) return false;
    }
    return true;
  }

  bool _isSystemPlaylist(String id) => id == 'favorites' || id == 'recent';
}
