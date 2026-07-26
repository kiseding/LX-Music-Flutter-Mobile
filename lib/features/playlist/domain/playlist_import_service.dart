import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'dart:io';
import '../../player/domain/music_item.dart';

class ImportedPlaylist {
  final String name;
  final String source;
  final String sourceId;
  final List<MusicItem> songs;

  const ImportedPlaylist({
    required this.name,
    required this.source,
    required this.sourceId,
    required this.songs,
  });
}

/// 本地解析 QQ / 酷我 / 网易歌单（无需登录）
class PlaylistImportService {
  final Dio _dio = () {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
      validateStatus: (s) => s != null && s < 500,
    ));
    try {
      (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
        return HttpClient()..badCertificateCallback = (c, h, p) => true;
      };
    } catch (_) {}
    return dio;
  }();

  Future<ImportedPlaylist> import({
    required String input,
    String platformHint = 'tx',
  }) async {
    final trimmed = input.trim();
    var source = '';
    var listId = '';

    if (trimmed.contains('y.qq.com') || trimmed.contains('i.y.qq.com')) {
      source = 'tx';
      listId = _matchId(trimmed, [
        r'[?&]id=(\d+)',
        r'playlist/(\d+)',
        r'songList/(\d+)',
        r'taoge/(\d+)',
        r'/(\d{5,})',
      ]);
    } else if (trimmed.contains('kuwo.cn')) {
      source = 'kw';
      listId = _matchId(trimmed, [
        r'[?&]id=(\d+)',
        r'playlist/(\d+)',
        r'pid=(\d+)',
        r'detail/(\d+)',
      ]);
    } else if (trimmed.contains('music.163.com') || trimmed.contains('163.com')) {
      source = 'wy';
      listId = _matchId(trimmed, [r'[?&]id=(\d+)', r'playlist/(\d+)']);
    }

    if (source.isEmpty && RegExp(r'^\d+$').hasMatch(trimmed)) {
      source = platformHint;
      listId = trimmed;
    }

    if (source.isEmpty || listId.isEmpty) {
      throw Exception('无法识别，请选择平台后输入歌单链接或 ID');
    }

    switch (source) {
      case 'tx':
        return _importTx(listId);
      case 'kw':
        return _importKw(listId);
      case 'wy':
        return _importWy(listId);
      default:
        throw Exception('不支持的平台');
    }
  }

  String _matchId(String input, List<String> patterns) {
    for (final p in patterns) {
      final m = RegExp(p).firstMatch(input);
      if (m != null) return m.group(1)!;
    }
    return '';
  }

  Future<ImportedPlaylist> _importTx(String id) async {
    final url =
        'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=$id&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0&g_tk=5381';
    final resp = await _dio.get(url, options: Options(headers: {
      'Referer': 'https://y.qq.com/portal/player.html',
      'Origin': 'https://y.qq.com',
    }));
    final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
    if (data is! Map || data['code'] != 0 || data['cdlist'] is! List || (data['cdlist'] as List).isEmpty) {
      throw Exception('获取 QQ 歌单失败');
    }
    final cd = data['cdlist'][0] as Map;
    final songlist = cd['songlist'] as List? ?? [];
    final songs = songlist.map((s) {
      final m = Map<String, dynamic>.from(s as Map);
      final file = m['file'] is Map ? Map<String, dynamic>.from(m['file']) : <String, dynamic>{};
      final types = <String>[];
      if ('${file['size_hires'] ?? 0}' != '0' && file['size_hires'] != null) types.add('flac24bit');
      if ('${file['size_flac'] ?? 0}' != '0' && file['size_flac'] != null) types.add('flac');
      if ('${file['size_320mp3'] ?? 0}' != '0' && file['size_320mp3'] != null) types.add('320k');
      if (types.isEmpty && '${file['size_128mp3'] ?? 0}' != '0') types.add('128k');
      final singers = (m['singer'] as List?)?.map((x) => (x as Map)['name']).join('、') ?? '';
      final album = m['album'] is Map ? Map<String, dynamic>.from(m['album']) : <String, dynamic>{};
      final mid = (m['mid'] ?? m['songmid'] ?? '').toString();
      final albumMid = album['mid']?.toString() ?? '';
      final interval = int.tryParse('${m['interval'] ?? 0}') ?? 0;
      return MusicItem(
        id: mid,
        name: (m['title'] ?? m['name'] ?? '').toString(),
        singer: singers,
        album: album['name']?.toString() ?? '',
        duration: Duration(seconds: interval),
        source: 'tx',
        platform: 'tx',
        songmid: mid,
        hash: mid,
        artwork: albumMid.isNotEmpty ? 'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg' : '',
        meta: {'source': 'tx', 'songmid': mid, 'types': types, 'albumName': album['name']},
      );
    }).where((s) => s.songmid != null && s.songmid!.isNotEmpty).toList();

    return ImportedPlaylist(
      name: (cd['dissname'] ?? 'QQ 歌单').toString(),
      source: 'tx',
      sourceId: id,
      songs: songs,
    );
  }

  Future<ImportedPlaylist> _importKw(String id) async {
    final url =
        'https://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=$id&pn=0&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1';
    final resp = await _dio.get(url);
    final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
    if (data is! Map || data['musiclist'] == null) {
      throw Exception('获取酷我歌单失败');
    }
    final re = RegExp(r'level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)');
    final musiclist = data['musiclist'] as List;
    final songs = musiclist.map((s) {
      final m = Map<String, dynamic>.from(s as Map);
      final types = <String>[];
      for (final part in '${m['N_MINFO'] ?? ''}'.split(';')) {
        final match = re.firstMatch(part);
        if (match != null) {
          switch (match.group(2)) {
            case '4000':
              types.add('flac24bit');
            case '2000':
              types.add('flac');
            case '320':
              types.add('320k');
            case '128':
              types.add('128k');
          }
        }
      }
      final rid = (m['rid'] ?? m['id'] ?? '').toString();
      final duration = int.tryParse('${m['duration'] ?? 0}') ?? 0;
      return MusicItem(
        id: rid,
        name: (m['name'] ?? '').toString(),
        singer: (m['artist'] ?? '').toString(),
        album: (m['album'] ?? '').toString(),
        duration: Duration(seconds: duration),
        source: 'kw',
        platform: 'kw',
        songmid: rid,
        hash: rid,
        artwork: (m['pic'] ?? '').toString(),
        meta: {'source': 'kw', 'songmid': rid, 'types': types},
      );
    }).where((s) => s.songmid != null && s.songmid!.isNotEmpty).toList();

    return ImportedPlaylist(
      name: (data['title'] ?? data['info']?['name'] ?? '酷我歌单').toString(),
      source: 'kw',
      sourceId: id,
      songs: songs,
    );
  }

  Future<ImportedPlaylist> _importWy(String id) async {
    // 公开详情接口（部分环境可用）；失败再试 playlist/detail
    try {
      final resp = await _dio.get(
        'https://music.163.com/api/playlist/detail',
        queryParameters: {'id': id},
        options: Options(headers: {
          'Referer': 'https://music.163.com/',
          'Origin': 'https://music.163.com',
        }),
      );
      final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
      if (data is Map && (data['code'] == 200 || data['result'] != null)) {
        final pl = data['result'] ?? data['playlist'];
        if (pl is Map) {
          final tracks = pl['tracks'] as List? ?? [];
          final songs = tracks.map((t) {
            final m = Map<String, dynamic>.from(t as Map);
            final ar = (m['artists'] ?? m['ar']);
            final singers = ar is List ? ar.map((a) => (a as Map)['name']).join('、') : '';
            final al = m['album'] ?? m['al'];
            final album = al is Map ? Map<String, dynamic>.from(al) : <String, dynamic>{};
            final sid = '${m['id'] ?? ''}';
            final dt = m['duration'] ?? m['dt'] ?? 0;
            final sec = dt is int ? (dt > 10000 ? dt ~/ 1000 : dt) : int.tryParse('$dt') ?? 0;
            return MusicItem(
              id: sid,
              name: (m['name'] ?? '').toString(),
              singer: singers,
              album: album['name']?.toString() ?? '',
              duration: Duration(seconds: sec),
              source: 'wy',
              platform: 'wy',
              songmid: sid,
              hash: sid,
              artwork: (album['picUrl'] ?? '').toString(),
              meta: {'source': 'wy', 'songmid': sid, 'types': ['320k', '128k']},
            );
          }).where((s) => s.songmid != null && s.songmid!.isNotEmpty).toList();
          if (songs.isNotEmpty) {
            return ImportedPlaylist(
              name: (pl['name'] ?? '网易云歌单').toString(),
              source: 'wy',
              sourceId: id,
              songs: songs,
            );
          }
        }
      }
    } catch (_) {}

    // 备用：v3 playlist detail（可能只返回部分 tracks）
    final resp2 = await _dio.get(
      'https://music.163.com/api/v3/playlist/detail',
      queryParameters: {'id': id, 'n': 1000},
      options: Options(headers: {
        'Referer': 'https://music.163.com/',
      }),
    );
    final data2 = resp2.data is String ? jsonDecode(resp2.data) : resp2.data;
    if (data2 is! Map || data2['playlist'] == null) {
      throw Exception('获取网易云歌单失败');
    }
    final pl = Map<String, dynamic>.from(data2['playlist'] as Map);
    final tracks = pl['tracks'] as List? ?? [];
    final songs = tracks.map((t) {
      final m = Map<String, dynamic>.from(t as Map);
      final ar = m['ar'] as List? ?? [];
      final singers = ar.map((a) => (a as Map)['name']).join('、');
      final al = m['al'] is Map ? Map<String, dynamic>.from(m['al']) : <String, dynamic>{};
      final sid = '${m['id'] ?? ''}';
      final dt = m['dt'] ?? 0;
      final sec = dt is int ? dt ~/ 1000 : 0;
      return MusicItem(
        id: sid,
        name: (m['name'] ?? '').toString(),
        singer: singers,
        album: al['name']?.toString() ?? '',
        duration: Duration(seconds: sec),
        source: 'wy',
        platform: 'wy',
        songmid: sid,
        hash: sid,
        artwork: (al['picUrl'] ?? '').toString(),
        meta: {'source': 'wy', 'songmid': sid, 'types': ['320k', '128k']},
      );
    }).where((s) => s.songmid != null && s.songmid!.isNotEmpty).toList();

    if (songs.isEmpty) throw Exception('歌单为空或无法解析');
    return ImportedPlaylist(
      name: (pl['name'] ?? '网易云歌单').toString(),
      source: 'wy',
      sourceId: id,
      songs: songs,
    );
  }
}
