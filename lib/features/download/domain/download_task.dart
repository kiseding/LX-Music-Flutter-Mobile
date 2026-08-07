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
    return DownloadTask.decodePersisted(json);
  }

  static DownloadTask decodePersisted(Object? raw) {
    if (raw is! Map) {
      throw FormatException(
        'DownloadTask expected Map, got ${raw.runtimeType}',
      );
    }
    final json = Map<String, dynamic>.from(raw);

    final id = _requireString(json, 'id');
    final musicId = _requireString(json, 'musicId');
    final name = _requireString(json, 'name');
    final singer = _requireString(json, 'singer');
    final statusIndex = _requireInt(json, 'status');
    if (statusIndex < 0 || statusIndex >= DownloadStatus.values.length) {
      throw FormatException('invalid status index: $statusIndex');
    }
    final progress = _optionalDouble(json, 'progress') ?? 0.0;
    if (!progress.isFinite || progress < 0.0 || progress > 1.0) {
      throw FormatException('invalid progress: $progress');
    }
    final speed = _optionalInt(json, 'speed') ?? 0;
    if (speed < 0) {
      throw FormatException('invalid speed: $speed');
    }
    final fileSize = _optionalInt(json, 'fileSize') ?? 0;
    if (fileSize < 0) {
      throw FormatException('invalid fileSize: $fileSize');
    }
    final attemptRevision = _optionalInt(json, 'attemptRevision') ?? 0;
    if (attemptRevision < 0) {
      throw FormatException('invalid attemptRevision: $attemptRevision');
    }
    final duration = _optionalNullableInt(json, 'duration');
    if (duration != null && duration < 0) {
      throw FormatException('invalid duration: $duration');
    }

    final createdAt = _requireDate(json, 'createdAt');
    final completedAt = _optionalDate(json, 'completedAt');

    return DownloadTask(
      id: id,
      musicId: musicId,
      name: name,
      singer: singer,
      url: _optionalString(json, 'url'),
      savePath: _optionalString(json, 'savePath'),
      status: DownloadStatus.values[statusIndex],
      progress: progress,
      speed: speed,
      errorMsg: _optionalString(json, 'errorMsg'),
      createdAt: createdAt,
      completedAt: completedAt,
      quality: _optionalString(json, 'quality'),
      fileSize: fileSize,
      platform: _optionalString(json, 'platform'),
      source: _optionalString(json, 'source'),
      songmid: _optionalString(json, 'songmid'),
      hash: _optionalString(json, 'hash'),
      album: _optionalString(json, 'album'),
      artwork: _optionalString(json, 'artwork'),
      duration: duration,
      attemptRevision: attemptRevision,
    );
  }

  static String _requireString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('expected String for $key, got ${value.runtimeType}');
    }
    return value;
  }

  static String? _optionalString(Map<String, dynamic> json, String key) {
    if (!json.containsKey(key) || json[key] == null) return null;
    final value = json[key];
    if (value is! String) {
      throw FormatException('expected String? for $key, got ${value.runtimeType}');
    }
    return value;
  }

  static int _requireInt(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is int) return value;
    throw FormatException('expected int for $key, got ${value.runtimeType}');
  }

  static int? _optionalInt(Map<String, dynamic> json, String key) {
    if (!json.containsKey(key) || json[key] == null) return null;
    final value = json[key];
    if (value is int) return value;
    throw FormatException('expected int for $key, got ${value.runtimeType}');
  }

  static int? _optionalNullableInt(Map<String, dynamic> json, String key) {
    return _optionalInt(json, key);
  }

  static double? _optionalDouble(Map<String, dynamic> json, String key) {
    if (!json.containsKey(key) || json[key] == null) return null;
    final value = json[key];
    if (value is double) return value;
    if (value is int) return value.toDouble();
    throw FormatException('expected double for $key, got ${value.runtimeType}');
  }

  static DateTime _requireDate(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('expected date String for $key, got ${value.runtimeType}');
    }
    try {
      return DateTime.parse(value);
    } on FormatException {
      throw FormatException('invalid date for $key: $value');
    }
  }

  static DateTime? _optionalDate(Map<String, dynamic> json, String key) {
    if (!json.containsKey(key) || json[key] == null) return null;
    return _requireDate(json, key);
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
