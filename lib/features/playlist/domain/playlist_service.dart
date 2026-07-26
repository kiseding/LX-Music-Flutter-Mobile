import '../domain/playlist.dart';
import '../../player/domain/music_item.dart';
import '../../../core/storage/storage_service.dart';

class PlaylistService {
  final List<Playlist> _playlists = [];
  StorageService? _storage;
  bool _initialized = false;

  List<Playlist> get playlists => List.unmodifiable(_playlists);

  PlaylistService() {
    // 创建默认歌单
    _playlists.add(Playlist(
      id: 'favorites',
      name: '我喜欢',
      description: '收藏的歌曲',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
    _playlists.add(Playlist(
      id: 'recent',
      name: '最近播放',
      description: '最近播放的歌曲',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
  }

  /// 初始化：从本地存储恢复数据
  Future<void> init() async {
    if (_initialized) return;
    _storage = await StorageService.instance;
    _loadFromStorage();
    _initialized = true;
  }

  void _loadFromStorage() {
    final saved = _storage!.getJsonList('playlists');
    if (saved.isEmpty) return;

    _playlists.clear();
    for (final json in saved) {
      final songs = (json['songs'] as List?)
              ?.map((s) => MusicItem.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [];
      _playlists.add(Playlist(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        coverUrl: json['coverUrl'] as String?,
        songs: songs,
        createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int),
      ));
    }
  }

  Future<void> _saveToStorage() async {
    if (_storage == null) return;
    final data = _playlists.map((p) => {
      'id': p.id,
      'name': p.name,
      'description': p.description,
      'coverUrl': p.coverUrl,
      'songs': p.songs.map((s) => s.toJson()).toList(),
      'createdAt': p.createdAt.millisecondsSinceEpoch,
      'updatedAt': p.updatedAt.millisecondsSinceEpoch,
    }).toList();
    await _storage!.setJsonList('playlists', data);
  }

  // 创建歌单
  Playlist createPlaylist({
    required String name,
    String? description,
  }) {
    final playlist = Playlist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      description: description,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    _playlists.add(playlist);
    _saveToStorage();
    return playlist;
  }

  // 删除歌单
  void deletePlaylist(String id) {
    _playlists.removeWhere((p) => p.id == id);
    _saveToStorage();
  }

  // 更新歌单
  Playlist updatePlaylist({
    required String id,
    String? name,
    String? description,
    List<MusicItem>? songs,
  }) {
    final index = _playlists.indexWhere((p) => p.id == id);
    if (index < 0) throw Exception('歌单不存在');

    final updated = _playlists[index].copyWith(
      name: name,
      description: description,
      songs: songs,
      updatedAt: DateTime.now(),
    );
    _playlists[index] = updated;
    _saveToStorage();
    return updated;
  }

  // 获取歌单
  Playlist? getPlaylist(String id) {
    try {
      return _playlists.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  // 添加歌曲到歌单
  void addSongToPlaylist(String playlistId, MusicItem song) {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index < 0) throw Exception('歌单不存在');

    final playlist = _playlists[index];
    if (playlist.songs.any((s) => s.id == song.id)) return;

    final updated = playlist.copyWith(
      songs: [...playlist.songs, song],
      updatedAt: DateTime.now(),
    );
    _playlists[index] = updated;
    _saveToStorage();
  }

  // 从歌单移除歌曲
  void removeSongFromPlaylist(String playlistId, String songId) {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index < 0) throw Exception('歌单不存在');

    final playlist = _playlists[index];
    final updated = playlist.copyWith(
      songs: playlist.songs.where((s) => s.id != songId).toList(),
      updatedAt: DateTime.now(),
    );
    _playlists[index] = updated;
    _saveToStorage();
  }

  // 检查歌曲是否在歌单中
  bool isSongInPlaylist(String playlistId, String songId) {
    final playlist = getPlaylist(playlistId);
    return playlist?.songs.any((s) => s.id == songId) ?? false;
  }

  // 歌单内歌曲排序
  void sortSongsInPlaylist(String playlistId, {required int oldIndex, required int newIndex}) {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index < 0) throw Exception('歌单不存在');

    final playlist = _playlists[index];
    final songs = List<MusicItem>.from(playlist.songs);

    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    final item = songs.removeAt(oldIndex);
    songs.insert(newIndex, item);

    _playlists[index] = playlist.copyWith(
      songs: songs,
      updatedAt: DateTime.now(),
    );
    _saveToStorage();
  }

  // 按名称排序歌曲
  void sortSongsByName(String playlistId, {bool ascending = true}) {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index < 0) throw Exception('歌单不存在');

    final playlist = _playlists[index];
    final songs = List<MusicItem>.from(playlist.songs);

    songs.sort((a, b) {
      final compare = a.name.compareTo(b.name);
      return ascending ? compare : -compare;
    });

    _playlists[index] = playlist.copyWith(
      songs: songs,
      updatedAt: DateTime.now(),
    );
    _saveToStorage();
  }

  // 按歌手排序歌曲
  void sortSongsByArtist(String playlistId, {bool ascending = true}) {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index < 0) throw Exception('歌单不存在');

    final playlist = _playlists[index];
    final songs = List<MusicItem>.from(playlist.songs);

    songs.sort((a, b) {
      final compare = a.singer.compareTo(b.singer);
      return ascending ? compare : -compare;
    });

    _playlists[index] = playlist.copyWith(
      songs: songs,
      updatedAt: DateTime.now(),
    );
    _saveToStorage();
  }

  // 按时长排序歌曲
  void sortSongsByDuration(String playlistId, {bool ascending = true}) {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index < 0) throw Exception('歌单不存在');

    final playlist = _playlists[index];
    final songs = List<MusicItem>.from(playlist.songs);

    songs.sort((a, b) {
      final compare = a.duration.compareTo(b.duration);
      return ascending ? compare : -compare;
    });

    _playlists[index] = playlist.copyWith(
      songs: songs,
      updatedAt: DateTime.now(),
    );
    _saveToStorage();
  }

  // 添加到"最近播放"
  void addToRecent(MusicItem song) {
    final recentPlaylist = getPlaylist('recent');
    if (recentPlaylist == null) return;

    final songs = recentPlaylist.songs.where((s) => s.id != song.id).toList();
    songs.insert(0, song);
    if (songs.length > 100) {
      songs.removeRange(100, songs.length);
    }

    final index = _playlists.indexWhere((p) => p.id == 'recent');
    _playlists[index] = recentPlaylist.copyWith(
      songs: songs,
      updatedAt: DateTime.now(),
    );
    _saveToStorage();
  }

  // 获取"我喜欢"歌单
  Playlist? get favorites => getPlaylist('favorites');

  // 获取"最近播放"歌单
  Playlist? get recent => getPlaylist('recent');
}
