import '../../player/domain/music_item.dart';

class Playlist {
  final String id;
  final String name;
  final String? description;
  final String? coverUrl;
  final List<MusicItem> songs;
  final int songCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Playlist({
    required this.id,
    required this.name,
    this.description,
    this.coverUrl,
    this.songs = const [],
    int? songCount,
    required this.createdAt,
    required this.updatedAt,
  }) : songCount = songCount ?? songs.length;

  Playlist copyWith({
    String? id,
    String? name,
    String? description,
    String? coverUrl,
    List<MusicItem>? songs,
    int? songCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      coverUrl: coverUrl ?? this.coverUrl,
      songs: songs ?? this.songs,
      songCount: songCount ?? (songs == null ? this.songCount : songs.length),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Duration get totalDuration => songs.fold(
        Duration.zero,
        (total, song) => total + song.duration,
      );
}
