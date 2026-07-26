import '../../player/domain/music_item.dart';

class Playlist {
  final String id;
  final String name;
  final String? description;
  final String? coverUrl;
  final List<MusicItem> songs;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Playlist({
    required this.id,
    required this.name,
    this.description,
    this.coverUrl,
    this.songs = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  Playlist copyWith({
    String? id,
    String? name,
    String? description,
    String? coverUrl,
    List<MusicItem>? songs,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      coverUrl: coverUrl ?? this.coverUrl,
      songs: songs ?? this.songs,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  int get songCount => songs.length;
  Duration get totalDuration => songs.fold(
        Duration.zero,
        (total, song) => total + song.duration,
      );
}
