class PlayUrlResult {
  final String url;

  /// 请求的音质
  final String requestedQuality;

  /// 实际得到的音质（根据 URL 容器或上游返回推断）
  final String actualQuality;
  final String platform;

  /// 命中歌曲的源侧 ID；跨平台兜底时可能与原始 MusicItem 不同。
  final String songId;

  const PlayUrlResult({
    required this.url,
    required this.requestedQuality,
    required this.actualQuality,
    required this.platform,
    this.songId = '',
  });
}

String qualityLabel(String q) {
  switch (q) {
    case 'flac24bit':
      return '臻品母带';
    case 'flac':
      return '无损';
    case 'hires':
      return 'Hi-Res';
    case '320k':
      return '320kbps';
    case '192k':
      return '192kbps';
    case '128k':
      return '128kbps';
    default:
      return q;
  }
}

String platformLabel(String p) {
  switch (p) {
    case 'tx':
      return 'QQ音乐';
    case 'kw':
      return '酷我音乐';
    case 'wy':
      return '网易云音乐';
    case 'kg':
      return '酷狗音乐';
    case 'mg':
      return '咪咕音乐';
    default:
      return p.isEmpty ? '未知' : p;
  }
}

/// 判断源返回的播放地址是否可下载/播放。
/// 聆澜等源会在部分歌曲上返回 `http://wx.music.tc.qq.com/` 这种假成功根路径。
bool isPlayableMediaUrl(String? url) {
  if (url == null) return false;
  final s = url.trim();
  if (s.isEmpty) return false;
  final uri = Uri.tryParse(s);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  final path = uri.path;
  if (path.isEmpty || path == '/') return false;
  // 至少要有一段非空 path segment（文件名或资源路径）
  final segments = uri.pathSegments.where((p) => p.isNotEmpty).toList();
  return segments.isNotEmpty;
}

/// 规范化脚本返回的音质字段。
String? normalizeScriptQuality(String? raw) {
  if (raw == null) return null;
  final q = raw.trim().toLowerCase();
  if (q.isEmpty) return null;
  const known = {
    'hires',
    'flac24bit',
    'flac',
    '320k',
    '192k',
    '128k',
    '96k',
    '48k',
  };
  if (known.contains(q)) return q;
  if (q.contains('hires') || q.contains('hi-res') || q.contains('24bit')) {
    return 'flac24bit';
  }
  if (q.contains('flac') || q == 'sq' || q == '999') return 'flac';
  if (q.contains('320')) return '320k';
  if (q.contains('192')) return '192k';
  if (q.contains('128') || q == 'hq' || q == 'mp3') return '128k';
  return null;
}

/// 根据真实 URL 纠正音质标签。
/// 注意：仅扩展名无法区分 128k/320k 的 mp3/m4a，此时返回 requested 仅作弱推断。
String correctQualityFromUrl(String url, String requested) {
  final u = url.toLowerCase();
  if (u.contains('.flac') && !u.contains('.mflac')) {
    return requested == 'flac24bit' || requested == 'hires'
        ? (requested == 'hires' ? 'hires' : 'flac24bit')
        : 'flac';
  }
  if (u.contains('.mflac')) return '128k';
  // C400 前缀是 QQ 低码率 m4a
  if (u.contains('/c400') || u.contains('c400')) return '128k';
  if (u.contains('/m800') || u.contains('m800')) return '320k';
  if (u.contains('/m500') || u.contains('m500')) return '128k';
  if (u.contains('/f000') || u.contains('f000')) return 'flac';
  if (u.contains('.m4a') || u.contains('.mp3')) {
    // 无法从容器区分 128/320：保留 requested，由脚本 type 优先覆盖
    if (requested == 'flac' ||
        requested == 'flac24bit' ||
        requested == 'hires') {
      return '320k';
    }
    return requested;
  }
  return requested;
}
