class PlayUrlResult {
  final String url;
  /// 请求的音质
  final String requestedQuality;
  /// 实际得到的音质（根据 URL 容器或上游返回推断）
  final String actualQuality;
  final String platform;

  const PlayUrlResult({
    required this.url,
    required this.requestedQuality,
    required this.actualQuality,
    required this.platform,
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

/// 根据真实 URL 纠正音质标签（对齐公开解析链策略）
String correctQualityFromUrl(String url, String requested) {
  final u = url.toLowerCase();
  if (u.contains('.flac') && !u.contains('.mflac')) {
    return requested == 'flac24bit' ? 'flac24bit' : 'flac';
  }
  if (u.contains('.mflac')) return '128k';
  if (u.contains('.m4a') || u.contains('.mp3')) {
    if (requested == 'flac' || requested == 'flac24bit') return '320k';
    return requested;
  }
  return requested;
}
