import '../../player/domain/music_item.dart';

enum DownloadStatus {
  pending,
  downloading,
  completed,
  failed,
  paused,
}

class DownloadTask {
  final String id;
  final String musicId;
  final String name;
  final String singer;
  final String? url;
  final String? savePath;
  final DownloadStatus status;
  final double progress;
  final int speed;
  final String? errorMsg;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? quality;
  final int fileSize;
  // 完整的歌曲元数据
  final String? platform;
  final String? source;
  final String? songmid;
  final String? hash;
  final String? album;
  final String? artwork;
  final int? duration;
  final int attemptRevision;

  const DownloadTask({
    required this.id,
    required this.musicId,
    required this.name,
    required this.singer,
    this.url,
    this.savePath,
    this.status = DownloadStatus.pending,
    this.progress = 0.0,
    this.speed = 0,
    this.errorMsg,
    required this.createdAt,
    this.completedAt,
    this.quality,
    this.fileSize = 0,
    this.platform,
    this.source,
    this.songmid,
    this.hash,
    this.album,
    this.artwork,
    this.duration,
    this.attemptRevision = 0,
  });

  DownloadTask copyWith({
    String? id,
    String? musicId,
    String? name,
    String? singer,
    String? url,
    String? savePath,
    bool clearSavePath = false,
    DownloadStatus? status,
    double? progress,
    int? speed,
    String? errorMsg,
    bool clearErrorMsg = false,
    DateTime? createdAt,
    DateTime? completedAt,
    String? quality,
    int? fileSize,
    String? platform,
    String? source,
    String? songmid,
    String? hash,
    String? album,
    String? artwork,
    int? duration,
    int? attemptRevision,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      musicId: musicId ?? this.musicId,
      name: name ?? this.name,
      singer: singer ?? this.singer,
      url: url ?? this.url,
      savePath: clearSavePath ? null : (savePath ?? this.savePath),
      status: status ?? this.status,
      progress: progress ?? this.progress,
      speed: speed ?? this.speed,
      errorMsg: clearErrorMsg ? null : (errorMsg ?? this.errorMsg),
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      quality: quality ?? this.quality,
      fileSize: fileSize ?? this.fileSize,
      platform: platform ?? this.platform,
      source: source ?? this.source,
      songmid: songmid ?? this.songmid,
      hash: hash ?? this.hash,
      album: album ?? this.album,
      artwork: artwork ?? this.artwork,
      duration: duration ?? this.duration,
      attemptRevision: attemptRevision ?? this.attemptRevision,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'musicId': musicId,
      'name': name,
      'singer': singer,
      'url': url,
      'savePath': savePath,
      'status': status.index,
      'progress': progress,
      'speed': speed,
      'errorMsg': errorMsg,
      'createdAt': createdAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'quality': quality,
      'fileSize': fileSize,
      'platform': platform,
      'source': source,
      'songmid': songmid,
      'hash': hash,
      'album': album,
      'artwork': artwork,
      'duration': duration,
      'attemptRevision': attemptRevision,
    };
  }

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: json['id'],
      musicId: json['musicId'],
      name: json['name'],
      singer: json['singer'],
      url: json['url'],
      savePath: json['savePath'],
      status: DownloadStatus.values[json['status']],
      progress: json['progress'] ?? 0.0,
      speed: json['speed'] ?? 0,
      errorMsg: json['errorMsg'],
      createdAt: DateTime.parse(json['createdAt']),
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'])
          : null,
      quality: json['quality'],
      fileSize: json['fileSize'] ?? 0,
      platform: json['platform'],
      source: json['source'],
      songmid: json['songmid'],
      hash: json['hash'],
      album: json['album'],
      artwork: json['artwork'],
      duration: json['duration'],
      attemptRevision: json['attemptRevision'] ?? 0,
    );
  }

  /// 从 DownloadTask 恢复为 MusicItem
  MusicItem toMusicItem() {
    return MusicItem(
      id: musicId,
      name: name,
      singer: singer,
      album: album ?? '',
      duration: Duration(seconds: duration ?? 0),
      source: source ?? 'download',
      platform: platform ?? 'kw',
      artwork: artwork,
      songmid: songmid,
      hash: hash,
    );
  }
}
