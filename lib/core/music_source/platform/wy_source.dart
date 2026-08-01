import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import '../../../features/player/domain/music_item.dart';
import 'music_platform.dart';
import 'source_utils.dart';

const neteaseSearchEndpoint = 'https://interface.music.163.com/eapi/batch';
const neteaseLyricEndpoint =
    'https://interface.music.163.com/eapi/song/lyric/v1';

const _eapiKey = 'e82ckenh8dichen8';
const _presetKey = '0CoJUm6Qyw8W8jud';
const _iv = '0102030405060708';
const _base62 =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
// 从桌面版 crypto.js 的 PEM 公钥中提取的 RSA 模数 (128 字节)
const _rsaModulusHex =
    'e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7';
const _rsaExponentHex = '010001';

class WySource extends MusicPlatform {
  @override
  String get id => 'wy';

  @override
  String get name => '网易云音乐';

  late final Dio _dio;

  WySource() {
    _dio = createDio();
    _dio.options.headers.addAll({
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Origin': 'https://music.163.com',
      'Referer': 'https://music.163.com/',
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Connection': 'keep-alive',
    });
  }

  // ==================== 加密方法 ====================

  /// 桌面版 weapi 加密 (AES-128-CBC 两次 + RSA 无填充)
  Map<String, String> weapi(Map<String, dynamic> object) {
    final text = jsonEncode(object);
    final random = Random.secure();

    // 生成 16 字节随机密钥 (base62 字符) - 匹配桌面版: randomBytes(16).map(n => (base62.charAt(n % 62).charCodeAt()))
    final randomBytes = List<int>.generate(16, (_) => random.nextInt(256));
    final secretKeyBytes =
        randomBytes.map((n) => _base62.codeUnitAt(n % 62)).toList();
    final secretKey = String.fromCharCodes(secretKeyBytes);

    // 第一次 AES-128-CBC 加密 (presetKey + iv)
    final firstEncrypted = _aesCbcEncrypt(text, _presetKey, _iv);
    final firstBase64 = base64.encode(firstEncrypted);

    // 第二次 AES-128-CBC 加密 (secretKey + iv)
    final secondEncrypted = _aesCbcEncrypt(firstBase64, secretKey, _iv);
    final params = base64.encode(secondEncrypted);

    // RSA 加密 secretKey (反转后，无填充)
    final reversedKey = secretKey.split('').reversed.join('');
    final encSecKey = _rsaEncryptNoPadding(reversedKey);

    return {
      'params': params,
      'encSecKey': encSecKey,
    };
  }

  /// eapi 加密 (AES-128-ECB hex)
  Map<String, String> eapi(String url, Map<String, dynamic> object) {
    final text = jsonEncode(object);
    final message = 'nobody${url}use${text}md5forencrypt';
    final digest = md5String(message);
    final data = '$url-36cd479b6b5-$text-36cd479b6b5-$digest';
    final params = aes128EcbHex(data, _eapiKey);
    return {'params': params};
  }

  List<int> _aesCbcEncrypt(String data, String keyStr, String ivStr) {
    final key = encrypt.Key.fromUtf8(keyStr);
    final iv = encrypt.IV.fromUtf8(ivStr);
    final encrypter =
        encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
    final encrypted = encrypter.encrypt(data, iv: iv);
    return encrypted.bytes;
  }

  /// RSA 加密（无填充），对应桌面版 rsaEncrypt
  /// 桌面版: buffer = Buffer.concat([Buffer.alloc(128 - buffer.length), buffer])
  String _rsaEncryptNoPadding(String text) {
    final textBytes = utf8.encode(text);

    // 关键：在 RSA 加密前，将输入填充到 128 字节（与桌面版一致）
    // 桌面版: Buffer.concat([Buffer.alloc(128 - buffer.length), buffer])
    final paddedBytes = List<int>.filled(128, 0);
    final offset = 128 - textBytes.length;
    for (var i = 0; i < textBytes.length; i++) {
      paddedBytes[offset + i] = textBytes[i];
    }

    final n = BigInt.parse(_rsaModulusHex, radix: 16);
    final e = BigInt.parse(_rsaExponentHex, radix: 16);

    // 将填充后的字节转为 BigInt
    var m = BigInt.zero;
    for (final byte in paddedBytes) {
      m = (m << 8) | BigInt.from(byte);
    }

    // RSA: c = m^e mod n
    final c = m.modPow(e, n);

    // 转为十六进制，填充到 256 字符 (128 bytes)
    return c.toRadixString(16).padLeft(256, '0');
  }

  // ==================== 搜索 ====================

  @override
  Future<List<MusicItem>> search(String keyword,
      {int page = 1, int limit = 20}) async {
    try {
      final data = {
        'keyword': keyword,
        'needCorrect': '1',
        'channel': 'typing',
        'offset': limit * (page - 1),
        'scene': 'normal',
        'total': page == 1,
        'limit': limit,
      };
      final eapiParams = eapi('/api/search/song/list/page', data);

      final response = await _dio
          .post(
            neteaseSearchEndpoint,
            data: eapiParams,
            options: Options(contentType: 'application/x-www-form-urlencoded'),
          )
          .timeout(const Duration(seconds: 10));

      final respBody = response.data;
      if (respBody is! Map) return [];

      final results = await compute(_parseSearchResult, respBody);
      return results;
    } catch (e) {
      return [];
    }
  }

  static List<MusicItem> _parseSearchResult(dynamic respBody) {
    if (respBody is! Map || respBody['code'] != 200) return [];

    final result = respBody['data'] as Map?;
    if (result == null) return [];

    final resources = result['resources'] as List<dynamic>?;
    if (resources == null || resources.isEmpty) return [];

    return _staticHandleResult(resources);
  }

  static List<MusicItem> _staticHandleResult(List<dynamic> rawList) {
    final list = <MusicItem>[];
    for (final item in rawList) {
      final map = item as Map<String, dynamic>;
      final baseInfo = map['baseInfo'] as Map?;
      if (baseInfo == null) continue;

      final songData = baseInfo['simpleSongData'] as Map?;
      if (songData == null) continue;

      final id = songData['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final ar = songData['ar'] as List<dynamic>? ?? [];
      final al = songData['al'] as Map?;
      final dt = int.tryParse(songData['dt']?.toString() ?? '0') ?? 0;

      list.add(MusicItem(
        id: id,
        name: (songData['name'] as String? ?? '').trim(),
        singer: _staticFormatSingerName(ar, nameKey: 'name'),
        source: 'wy',
        platform: 'wy',
        artwork: _normalizeArtwork(al?['picUrl']),
        url: '',
        songmid: id,
        duration: Duration(milliseconds: dt),
        album: al?['name'] as String? ?? '',
      ));
    }
    return list;
  }

  static String _staticFormatSingerName(List<dynamic> singers,
      {String nameKey = 'name'}) {
    if (singers.isEmpty) return '未知歌手';
    return singers
        .map((s) => (s as Map)[nameKey]?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .join('、');
  }

  static String _normalizeArtwork(dynamic value) {
    final artwork = value?.toString().trim() ?? '';
    final uri = Uri.tryParse(artwork);
    if (uri?.scheme == 'http') {
      return uri!.replace(scheme: 'https').toString();
    }
    return artwork;
  }

  List<MusicItem> _handleResult(List<dynamic> rawList) {
    return _staticHandleResult(rawList);
  }

  // ==================== 播放链接 ====================

  @override
  Future<String?> getMusicUrl(MusicItem music,
      {String quality = '128k'}) async {
    return _getMusicUrl(music, quality: quality, exact: false);
  }

  @override
  Future<String?> getMusicUrlExact(MusicItem music,
      {required String quality}) async {
    if (exactBitrateForQuality(quality) == null) return null;
    return _getMusicUrl(music, quality: quality, exact: true);
  }

  @override
  Future<ExactPlayUrl?> getMusicUrlExactDetailed(MusicItem music,
      {required String quality}) async {
    return _getMusicUrlDetailed(music, quality: quality, exact: true);
  }

  Future<String?> _getMusicUrl(MusicItem music,
      {required String quality, required bool exact}) async {
    return (await _getMusicUrlDetailed(music, quality: quality, exact: exact))
        ?.url;
  }

  Future<ExactPlayUrl?> _getMusicUrlDetailed(MusicItem music,
      {required String quality, required bool exact}) async {
    try {
      final id = music.songmid ?? music.id;
      if (id.isEmpty) return null;

      final br = exact
          ? exactBitrateForQuality(quality)
          : legacyBitrateForQuality(quality);
      if (br == null) return null;

      final urlDio =
          createDioForService(headers: {'Referer': 'https://music.163.com/'});

      final response = await urlDio.get(
        'https://music.163.com/api/song/enhance/player/url',
        queryParameters: {
          'id': id,
          'ids': '[$id]',
          'br': br.toString(),
        },
      );

      final body = response.data;
      if (body is! Map) return null;

      final data = body['data'] as List<dynamic>?;
      if (data == null || data.isEmpty) return null;

      final first = data[0] as Map;
      final url = first['url'] as String?;
      if (url != null && url.isNotEmpty) {
        final responseBitrate = int.tryParse(first['br']?.toString() ?? '');
        return ExactPlayUrl(
          url: url,
          actualQuality: qualityFromBitrate(responseBitrate ?? br),
        );
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  static int? exactBitrateForQuality(String quality) => switch (quality) {
        'hires' || 'flac24bit' || 'flac' => 999000,
        '320k' => 320000,
        '192k' => 192000,
        '128k' => 128000,
        _ => null,
      };

  static int legacyBitrateForQuality(String quality) => switch (quality) {
        'hires' || 'flac24bit' || 'flac' => 999000,
        '320k' => 320000,
        '192k' => 192000,
        _ => 128000,
      };

  static String qualityFromBitrate(int bitrate) => switch (bitrate) {
        >= 900000 => 'flac',
        >= 280000 => '320k',
        >= 160000 => '192k',
        _ => '128k',
      };

  @override
  String? exactAttemptKey(String quality) =>
      exactBitrateForQuality(quality)?.toString();

  // ==================== 歌词 ====================

  @override
  Future<String?> getLyric(MusicItem music) async {
    try {
      final id = music.songmid ?? music.id;
      if (id.isEmpty) return null;

      final data = {
        'id': id,
        'cp': false,
        'tv': 0,
        'lv': 0,
        'rv': 0,
        'kv': 0,
        'yv': 0,
        'ytv': 0,
        'yrv': 0,
      };
      final eapiParams = eapi('/api/song/lyric/v1', data);

      final lyricDio = createDioForService(headers: {
        'User-Agent':
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36',
        'Origin': 'https://music.163.com',
        'Content-Type': 'application/x-www-form-urlencoded',
      });

      final response = await lyricDio.post(
        neteaseLyricEndpoint,
        data: 'params=${eapiParams['params']}',
      );

      final rawData = response.data;
      final body = rawData is String ? jsonDecode(rawData) : rawData;
      if (body is! Map) return null;

      if (body['code'] != 200) return null;

      // 网易云逐字歌词在 yrc 字段（YRC 字级标签）。优先返回 yrc，
      // 让解析器进入逐字渲染；无 yrc 时回退普通 lrc。
      final yrc = body['yrc'] as Map?;
      final yrcLyric = yrc?['lyric'] as String?;
      if (yrcLyric != null && yrcLyric.isNotEmpty) {
        return yrcLyric;
      }

      final lrc = body['lrc'] as Map?;
      if (lrc == null) return null;

      final lyric = lrc['lyric'] as String?;
      if (lyric == null || lyric.isEmpty) return null;

      return lyric;
    } catch (e) {
      return null;
    }
  }

  @override
  MusicItem parseItem(Map<String, dynamic> raw, String source) {
    final list = _handleResult([raw]);
    return list.isNotEmpty
        ? list.first
        : MusicItem(id: '', name: '', singer: '', source: 'wy', platform: 'wy');
  }

  // ==================== 排行榜 ====================

  @override
  Future<List<LeaderboardCategory>> getLeaderboardCategories() async {
    final base = const [
      LeaderboardCategory(id: 'wy:19723756', name: '飙升榜', platform: 'wy'),
      LeaderboardCategory(id: 'wy:3778678', name: '热歌榜', platform: 'wy'),
      LeaderboardCategory(id: 'wy:3779629', name: '新歌榜', platform: 'wy'),
      LeaderboardCategory(id: 'wy:2884035', name: '原创榜', platform: 'wy'),
      LeaderboardCategory(id: 'wy:71384707', name: '古典榜', platform: 'wy'),
      LeaderboardCategory(id: 'wy:1978921795', name: '电音榜', platform: 'wy'),
      LeaderboardCategory(id: 'wy:745956260', name: '韩语榜', platform: 'wy'),
      LeaderboardCategory(id: 'wy:60198', name: '美国Billboard榜', platform: 'wy'),
    ];
    // 统一：榜单封面 = 榜内首曲 artwork
    final results = await Future.wait(base.map((c) async {
      try {
        final songs = await getLeaderboardSongs(c.id, limit: 1);
        final art = songs.isNotEmpty ? songs.first.artwork : null;
        var cover = (art != null && art.isNotEmpty) ? art : null;
        cover = cover == null ? null : _normalizeArtwork(cover);
        return c.copyWith(coverUrl: cover);
      } catch (_) {
        return c;
      }
    }));
    return results;
  }

  @override
  Future<List<MusicItem>> getLeaderboardSongs(String leaderboardId,
      {int page = 1, int limit = 100}) async {
    try {
      final parts = leaderboardId.split(':');
      final id = parts.length == 2 ? parts[1] : leaderboardId;

      // 桌面版流程: 1) weapi 获取 playlist.trackIds, 2) song/detail 获取歌曲详情
      final playlistParams = weapi({
        'id': int.parse(id),
        'n': 100000,
        'p': 1,
      });

      final playlistResponse = await _dio.post(
        'https://music.163.com/weapi/v3/playlist/detail',
        data: {
          'params': playlistParams['params'],
          'encSecKey': playlistParams['encSecKey'],
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
        ),
      );

      final playlistBody = playlistResponse.data;
      Map<String, dynamic> playlistMap;
      if (playlistBody is String) {
        try {
          playlistMap = (jsonDecode(playlistBody) as Map)
              .map((k, v) => MapEntry(k.toString(), v));
        } catch (e) {
          return [];
        }
      } else if (playlistBody is Map) {
        playlistMap = playlistBody.map((k, v) => MapEntry(k.toString(), v));
      } else {
        return [];
      }

      if (playlistMap['code'] != 200) {
        return [];
      }

      final playlist = playlistMap['playlist'] as Map<String, dynamic>?;
      if (playlist == null) {
        return [];
      }

      final trackIds = playlist['trackIds'] as List<dynamic>?;
      if (trackIds == null || trackIds.isEmpty) {
        return [];
      }

      // 提取 id 列表
      final ids = trackIds.map((t) => (t as Map)['id']).toList();

      // 桌面版: weapi /weapi/v3/song/detail
      final detailParams = weapi({
        'c': '[${ids.map((id) => '{"id":$id}').join(',')}]',
        'ids': '[${ids.join(',')}]',
      });

      final detailResponse = await _dio.post(
        'https://music.163.com/weapi/v3/song/detail',
        data: {
          'params': detailParams['params'],
          'encSecKey': detailParams['encSecKey'],
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
        ),
      );

      final detailBody = detailResponse.data;
      Map<String, dynamic> detailMap;
      if (detailBody is String) {
        try {
          detailMap = (jsonDecode(detailBody) as Map)
              .map((k, v) => MapEntry(k.toString(), v));
        } catch (e) {
          return [];
        }
      } else if (detailBody is Map) {
        detailMap = detailBody.map((k, v) => MapEntry(k.toString(), v));
      } else {
        return [];
      }

      if (detailMap['code'] != 200) {
        return [];
      }

      final songs = detailMap['songs'] as List<dynamic>?;
      final privileges = detailMap['privileges'] as List<dynamic>?;
      if (songs == null || songs.isEmpty) {
        return [];
      }

      return _filterLeaderboardTracks(songs, privileges);
    } catch (e) {
      return [];
    }
  }

  /// 桌面版 musicDetail.js filterList - 解析 songs 和 privileges
  List<MusicItem> _filterLeaderboardTracks(
      List<dynamic> songs, List<dynamic>? privileges) {
    final list = <MusicItem>[];
    for (var i = 0; i < songs.length; i++) {
      final item = songs[i] as Map<String, dynamic>;
      final id = item['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      // 桌面版: 优先使用 pc 字段（用户上传歌曲），否则使用 ar/al
      final pc = item['pc'] as Map<String, dynamic>?;
      String singer;
      String name;
      String album;
      String artwork;

      if (pc != null) {
        singer = pc['ar'] as String? ?? '未知歌手';
        name = pc['sn'] as String? ?? '';
        album = pc['alb'] as String? ?? '';
        artwork = _normalizeArtwork((item['al'] as Map?)?['picUrl']);
      } else {
        final ar = item['ar'] as List<dynamic>? ?? [];
        singer = ar
            .map((a) => (a as Map)['name']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .join('、');
        if (singer.isEmpty) singer = '未知歌手';
        name = (item['name'] as String? ?? '').trim();
        final al = item['al'] as Map<String, dynamic>?;
        album = (al?['name'] as String? ?? '').trim();
        artwork = _normalizeArtwork(al?['picUrl']);
      }

      final dt = item['dt'] as int? ?? 0;

      list.add(MusicItem(
        id: id,
        name: name,
        singer: singer,
        album: album,
        duration: Duration(milliseconds: dt),
        source: 'wy',
        platform: 'wy',
        songmid: id,
        artwork: artwork,
      ));
    }
    return list;
  }

  void dispose() {
    _dio.close();
  }
}
