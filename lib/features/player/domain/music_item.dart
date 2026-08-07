import '../../../core/network/outbound_url.dart';

class MusicItem {
  final String id;
  final String name;
  final String singer;
  final String album;
  final Duration duration;
  final String source; // 脚本 ID
  final String platform; // 平台标识 (kw, tx, wy...)
  final String? artwork;
  final String? url;
  final String? lyricsUrl;
  final bool isPlayable;
  final String? songmid;
  final String? hash;
  final Map<String, dynamic>? meta; // 保存原始元数据，供自定义脚本使用

  MusicItem({
    required this.id,
    required this.name,
    required this.singer,
    this.album = '',
    this.duration = Duration.zero,
    required this.source,
    this.platform = 'kw',
    String? artwork,
    this.url,
    this.lyricsUrl,
    this.isPlayable = true,
    this.songmid,
    this.hash,
    this.meta,
  }) : artwork = _normalizeArtwork(source, platform, artwork);

  MusicItem copyWith({
    String? id,
    String? name,
    String? singer,
    String? album,
    Duration? duration,
    String? source,
    String? platform,
    String? artwork,
    String? url,
    String? lyricsUrl,
    bool? isPlayable,
    String? songmid,
    String? hash,
    Map<String, dynamic>? meta,
  }) {
    return MusicItem(
      id: id ?? this.id,
      name: name ?? this.name,
      singer: singer ?? this.singer,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      source: source ?? this.source,
      platform: platform ?? this.platform,
      artwork: artwork ?? this.artwork,
      url: url ?? this.url,
      lyricsUrl: lyricsUrl ?? this.lyricsUrl,
      isPlayable: isPlayable ?? this.isPlayable,
      songmid: songmid ?? this.songmid,
      hash: hash ?? this.hash,
      meta: meta ?? this.meta,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MusicItem && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'singer': singer,
      'album': album,
      'duration': duration.inSeconds,
      'source': source,
      'platform': platform,
      'artwork': artwork,
      'url': url,
      'lyricsUrl': lyricsUrl,
      'isPlayable': isPlayable,
      'songmid': songmid,
      'hash': hash,
      'meta': meta,
    };
  }

  factory MusicItem.fromJson(Map<String, dynamic> json) {
    final source = json['source'] ?? '';
    final platform = json['platform'] ?? 'kw';
    return MusicItem(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      singer: json['singer'] ?? '',
      album: json['album'] ?? '',
      duration: Duration(seconds: json['duration'] ?? 0),
      source: source,
      platform: platform,
      artwork: json['artwork']?.toString(),
      url: json['url'],
      lyricsUrl: json['lyricsUrl'],
      isPlayable: json['isPlayable'] ?? true,
      songmid: json['songmid'],
      hash: json['hash'],
      meta:
          json['meta'] != null ? Map<String, dynamic>.from(json['meta']) : null,
    );
  }

  static String? _normalizeArtwork(
      String source, String platform, String? artwork) {
    return artwork == null ? null : normalizeOutboundUrl(artwork);
  }
}
