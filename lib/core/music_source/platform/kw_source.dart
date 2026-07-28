import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../features/player/domain/music_item.dart';
import 'music_platform.dart';
import 'source_utils.dart';
import 'wbd_crypto.dart';

const kuwoSearchBaseUrl = 'https://search.kuwo.cn';
const kuwoArtworkEndpoint = 'https://artistpicserver.kuwo.cn/pic.web';
const kuwoAntiServerEndpoint = 'https://antiserver.kuwo.cn/anti.s';
const kuwoPlayInfoEndpoint = 'https://www.kuwo.cn/api/v1/www/music/playInfo';
const kuwoLegacyPlayEndpoint = 'https://www.kuwo.cn/url';
const kuwoLyricEndpoint = 'https://newlyric.kuwo.cn/newlyric.lrc';
const kuwoPlaylistEndpoint = 'https://nplserver.kuwo.cn/pl.svc';

class _KwToken {
  final String name;
  final String value;
  _KwToken({required this.name, required this.value});
}

class KwSource extends MusicPlatform {
  @override
  String get id => 'kw';

  @override
  String get name => '酷我音乐';

  late final Dio _dio;

  KwSource() {
    _dio = createDio();
    _dio.options.baseUrl = kuwoSearchBaseUrl;
    _dio.options.headers.addAll({
      'Referer': 'https://www.kuwo.cn/',
      'Cookie': 'kw_token=',
    });
  }

  @override
  Future<List<MusicItem>> search(String keyword,
      {int page = 1, int limit = 20}) async {
    try {
      final response = await _dio.get(
        '/r.s',
        queryParameters: {
          'client': 'kt',
          'all': keyword,
          'pn': (page - 1).toString(),
          'rn': limit.toString(),
          'uid': '794762570',
          'ver': 'kwplayer_ar_9.2.2.1',
          'vipver': '1',
          'show_copyright_off': '1',
          'newver': '1',
          'ft': 'music',
          'cluster': '0',
          'strategy': '2012',
          'encoding': 'utf8',
          'rformat': 'json',
          'vermerge': '1',
          'mobi': '1',
          'issubtitle': '1',
        },
      ).timeout(const Duration(seconds: 10));

      final data = response.data;
      if (data == null) return [];

      // 使用 compute 在后台线程解析，防止 UI 卡顿
      final results = await compute(_parseSearchResult, data);
      return results;
    } catch (e) {
      return [];
    }
  }

  static List<MusicItem> _parseSearchResult(dynamic data) {
    final body = data is Map<String, dynamic>
        ? data
        : (data is String ? jsonDecode(data) : null);
    if (body == null) return [];

    final abslist = body['abslist'] as List<dynamic>?;
    if (abslist == null || abslist.isEmpty) return [];

    final list = <MusicItem>[];
    for (final item in abslist) {
      final parsed = _staticParseItem(item as Map<String, dynamic>);
      if (parsed != null) list.add(parsed);
    }
    return list;
  }

  static MusicItem? _staticParseItem(Map<String, dynamic> item) {
    // 支持搜索 API（大写字段）和排行榜 API（小写字段）
    // 搜索 API: MUSICRID (格式: MUSIC_12345)
    // 排行榜 API: id (纯数字)
    String songmid;
    final musicRid = item['MUSICRID'] as String? ?? item['rid'] as String?;
    if (musicRid != null) {
      songmid = musicRid.replaceAll('MUSIC_', '');
    } else {
      // 排行榜 API 使用 id 字段
      songmid = item['id']?.toString() ?? '';
    }
    if (songmid.isEmpty) return null;

    final duration = int.tryParse(item['DURATION']?.toString() ??
            item['duration']?.toString() ??
            '') ??
        0;

    // 排行榜 API 使用 artistPic 作为封面
    final artwork = item['pic'] as String? ??
        item['artistPic'] as String? ??
        ((songmid.isNotEmpty && songmid.length > 5)
            ? 'https://img.kuwo.cn/star/starheads/${songmid}_small.jpg'
            : '');

    return MusicItem(
      id: songmid,
      name:
          (item['SONGNAME'] as String? ?? item['name'] as String? ?? '').trim(),
      singer: (item['ARTIST'] as String? ?? item['artist'] as String? ?? '')
          .replaceAll('&', '、'),
      source: 'kw',
      platform: 'kw',
      artwork: artwork,
      url: '',
      songmid: songmid,
      hash: songmid,
      duration: Duration(seconds: duration),
      album:
          (item['ALBUM'] as String? ?? item['album'] as String? ?? '').trim(),
    );
  }

  Map<String, dynamic>? _jsonDecode(String data) {
    try {
      return jsonDecode(data) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  MusicItem? _parseSearchItem(Map<String, dynamic> item) {
    return _staticParseItem(item);
  }

  @override
  Future<String?> getArtwork(MusicItem music) async {
    final rid = music.songmid ?? music.id;
    if (rid.isEmpty) return null;

    try {
      final response = await _dio.get(
        kuwoArtworkEndpoint,
        queryParameters: {
          'corp': 'kuwo',
          'type': 'rid_pic',
          'pictype': '500',
          'size': '500',
          'rid': rid,
        },
      ).timeout(const Duration(seconds: 5));

      final url = response.data?.toString().trim() ?? '';
      if (url.startsWith('http')) {
        return url;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  // 从首页提取 CSRF token（Kuwo 改用 Hm_Iuvt_* cookie）
  Future<_KwToken?> _fetchKwToken() async {
    try {
      final dio = createDioForService(headers: {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1',
      });
      final response = await dio
          .get(
            'https://www.kuwo.cn/',
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(seconds: 8));
      final body = response.data?.toString() ?? '';
      // 从 Set-Cookie 中提取 Hm_Iuvt_* cookie
      if (response.headers.map['set-cookie'] != null) {
        for (final cookie in response.headers.map['set-cookie']!) {
          debugPrint('[KW] Cookie: $cookie');
          final cookieMatch =
              RegExp(r'(Hm_Iuvt_\w+)=([^;]+)').firstMatch(cookie);
          if (cookieMatch != null) {
            final name = cookieMatch.group(1)!;
            final value = cookieMatch.group(2)!;
            debugPrint('[KW] 提取 CSRF: $name=$value');
            return _KwToken(name: name, value: value);
          }
        }
      }
      // 兜底从 body 搜 Hm_Iuvt
      final idx = body.indexOf('Hm_Iuvt');
      if (idx >= 0) {
        debugPrint(
            '[KW] 页面中找到 Hm_Iuvt, 上下文: ${body.substring(idx, (idx + 100).clamp(0, body.length))}');
      }
      debugPrint('[KW] 未能提取 CSRF token, body length=${body.length}');
      return null;
    } catch (e) {
      debugPrint('[KW] 获取 CSRF token 失败: $e');
      return null;
    }
  }

  @override
  Future<String?> getMusicUrl(MusicItem music,
      {String quality = '128k'}) async {
    return _getMusicUrl(music, quality: quality, exact: false);
  }

  @override
  Future<String?> getMusicUrlExact(MusicItem music,
      {required String quality}) async {
    return _getMusicUrl(music, quality: quality, exact: true);
  }

  @override
  Future<ExactPlayUrl?> getMusicUrlExactDetailed(MusicItem music,
      {required String quality}) async {
    final key = exactAttemptKeyForQuality(quality);
    if (key == null) return null;
    final url = await getMusicUrlExact(music, quality: quality);
    return url == null
        ? null
        : ExactPlayUrl(
            url: url,
            actualQuality: actualQualityForExactUrl(key, url),
          );
  }

  Future<String?> _getMusicUrl(MusicItem music,
      {required String quality, required bool exact}) async {
    final rid = music.songmid ?? music.id;
    debugPrint('[KW] getMusicUrl: rid=$rid, quality=$quality');

    // 方案1: kuwo.cn H5 接口（需先获取 csrf token）
    try {
      final kwToken = await _fetchKwToken();
      if (kwToken != null) {
        final urlDio = createDioForService(headers: {
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1',
          'Referer': 'https://www.kuwo.cn/',
          'Cookie': '${kwToken.name}=${kwToken.value}',
          'csrf': kwToken.value,
        });

        final response = await urlDio.get(
          kuwoPlayInfoEndpoint,
          queryParameters: {
            'mid': rid,
            'type': exact
                ? exactAttemptKeyForQuality(quality)
                : _qualityToType(quality),
            'httpsStatus': '1',
            'reqId': DateTime.now().millisecondsSinceEpoch.toString(),
          },
        ).timeout(const Duration(seconds: 8));

        debugPrint('[KW] playInfo 接口: status=${response.statusCode}');
        final data = response.data;
        if (data is Map && data['code'] == 200) {
          final url = data['data']?['url'] as String?;
          if (url != null && url.isNotEmpty) {
            debugPrint('[KW] playInfo 接口成功: $url');
            return url;
          }
          debugPrint('[KW] playInfo 接口: url为空, code=${data["code"]}');
        } else {
          debugPrint(
              '[KW] playInfo 接口: 非期望响应, success=${data is Map ? data["success"] : "N/A"}');
        }
      } else {
        debugPrint('[KW] playInfo 接口: 无 csrf token, 跳过');
      }
    } catch (e) {
      debugPrint('[KW] playInfo 接口失败: $e');
    }

    if (exact && exactAttemptKeyForQuality(quality) == null) return null;
    final format =
        exact ? exactAttemptKeyForQuality(quality)! : _qualityToFormat(quality);
    // 方案2: antiserver 接口（返回纯文本 URL），分别尝试两种 rid 格式
    for (final ridFormat in ['MUSIC_$rid', rid]) {
      try {
        final urlDio = createDioForService(headers: {
          'User-Agent': 'okhttp/3.10.0',
        });

        final response = await urlDio
            .get(
              kuwoAntiServerEndpoint,
              queryParameters: {
                'type': 'convert_url',
                'rid': ridFormat,
                'format': format,
                'response': 'url',
              },
              options: Options(responseType: ResponseType.plain),
            )
            .timeout(const Duration(seconds: 8));

        debugPrint(
            '[KW] antiserver 接口(rid=$ridFormat): status=${response.statusCode}, data=$response.data');
        String url = response.data?.toString().trim() ?? '';
        // 去掉末尾的 .data 后缀（Android ExoPlayer 不识别 .data 扩展名）
        if (url.endsWith('.data')) {
          url = url.substring(0, url.length - 5);
        }
        if (url.startsWith('http')) {
          debugPrint('[KW] antiserver 接口(rid=$ridFormat)成功: $url');
          return url;
        }
        debugPrint('[KW] antiserver 接口(rid=$ridFormat): 返回非 URL 内容: "$url"');
      } catch (e) {
        debugPrint('[KW] antiserver 接口(rid=$ridFormat)失败: $e');
      }
    }

    // 方案3: 旧版 convert_url3 接口，分别尝试两种 rid 格式
    for (final ridFormat in ['MUSIC_$rid', rid]) {
      try {
        final urlDio = createDioForService(headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36',
          'Referer': 'https://www.kuwo.cn/',
        });

        final response = await urlDio.get(
          kuwoLegacyPlayEndpoint,
          queryParameters: {
            'format': format,
            'rid': ridFormat,
            'response': 'url',
            'type': 'convert_url3',
          },
        );

        debugPrint(
            '[KW] convert_url3 接口(rid=$ridFormat): status=${response.statusCode}, data=$response.data');
        final data = response.data;
        if (data is Map && data['url'] != null) {
          final url = data['url'] as String;
          debugPrint('[KW] convert_url3 接口(rid=$ridFormat)成功: $url');
          return url;
        }
        debugPrint('[KW] convert_url3 接口: 非期望响应, type=${data.runtimeType}');
      } catch (e) {
        debugPrint('[KW] convert_url3 接口(rid=$ridFormat)失败: $e');
      }
    }

    debugPrint('[KW] getMusicUrl: 所有接口均失败, 返回 null');
    return null;
  }

  String _qualityToType(String quality) {
    switch (quality) {
      case '320k':
        return 'mp3';
      case 'flac':
      case 'flac24bit':
        return 'flac';
      default:
        return 'mp3';
    }
  }

  static String? exactAttemptKeyForQuality(String quality) {
    switch (quality) {
      case 'hires':
      case 'flac24bit':
      case 'flac':
        return 'flac';
      case '320k':
      case '192k':
      case '128k':
        return 'mp3';
      default:
        return null;
    }
  }

  static String actualQualityForAttemptKey(String key) =>
      key == 'flac' ? 'flac' : '128k';

  static String actualQualityForExactUrl(String key, String url) {
    if (key == 'flac' && url.toLowerCase().contains('.flac')) return 'flac';
    return '128k';
  }

  @override
  String? exactAttemptKey(String quality) => exactAttemptKeyForQuality(quality);

  String _qualityToFormat(String quality) {
    switch (quality) {
      case 'flac':
      case 'flac24bit':
        return 'flac';
      default:
        return 'mp3';
    }
  }

  @override
  Future<String?> getLyric(MusicItem music) async {
    try {
      final songmid = music.songmid ?? music.id;
      if (songmid.isEmpty) {
        debugPrint('[KW] getLyric: songmid 为空');
        return null;
      }

      debugPrint('[KW] getLyric: songmid=$songmid');
      final params = kwBuildParams(songmid, true);
      final lyricDio = createDioForService(
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36',
          'Referer': 'https://www.kuwo.cn/',
        },
      );
      lyricDio.options.responseType = ResponseType.bytes;

      final response = await lyricDio.get(
        '$kuwoLyricEndpoint?$params',
      );

      final data = response.data;
      if (data is! List) {
        debugPrint('[KW] getLyric: 响应不是 List, type=${data.runtimeType}');
        return null;
      }

      final result = kwDecodeResponse(data.cast<int>(), true);
      debugPrint('[KW] getLyric: 解码成功, length=${result?.length ?? 0}');
      return result;
    } catch (e) {
      debugPrint('[KW] getLyric 失败: $e');
      return null;
    }
  }

  @override
  MusicItem parseItem(Map<String, dynamic> raw, String source) {
    return _parseSearchItem(raw) ??
        MusicItem(id: '', name: '', singer: '', source: 'kw', platform: 'kw');
  }

  @override
  Future<List<MusicItem>> searchSongLists(String keyword,
      {int page = 1, int limit = 20}) async {
    try {
      final response = await _dio.get(
        '/r.s',
        queryParameters: {
          'client': 'kt',
          'all': keyword,
          'pn': (page - 1).toString(),
          'rn': limit.toString(),
          'ft': 'songlist',
          'cluster': '0',
          'strategy': '2012',
          'encoding': 'utf8',
          'rformat': 'json',
          'vermerge': '1',
          'mobi': '1',
        },
      ).timeout(const Duration(seconds: 10));

      final data = response.data;
      if (data == null) return [];
      final body = data is Map<String, dynamic>
          ? data
          : (data is String ? _jsonDecode(data) : null);
      if (body == null) return [];

      final abslist = body['abslist'] as List<dynamic>?;
      if (abslist == null) return [];

      return abslist
          .map((item) {
            final m = item as Map<String, dynamic>;
            return MusicItem(
              id: (m['playlistid'] ?? m['DC_TARGETID'] ?? '').toString(),
              name: (m['name'] ?? m['SONGNAME'] ?? '').toString().trim(),
              singer: (m['nickname'] ?? m['ARTIST'] ?? '').toString().trim(),
              source: 'kw',
              platform: 'kw',
              artwork: (m['img300'] ?? m['img'] ?? '').toString(),
              album: '${(m['songnum'] ?? 0)} 首',
              isPlayable: false,
            );
          })
          .where((m) => m.id.isNotEmpty)
          .toList();
    } catch (e) {
      return [];
    }
  }

  @override
  Future<List<MusicItem>> getSongListDetail(String songListId,
      {int page = 1, int limit = 50}) async {
    try {
      final dio = createDioForService(headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36',
        'Referer': 'https://www.kuwo.cn/',
      });
      final response = await dio.get(
        kuwoPlaylistEndpoint,
        queryParameters: {
          'op': 'getlistinfo',
          'pid': songListId,
          'pn': (page - 1).toString(),
          'rn': limit.toString(),
          'encode': 'utf8',
          'keyset': 'pl2012',
          'identity': 'kuwo',
          'pcjson': '1',
        },
      ).timeout(const Duration(seconds: 10));

      final data = response.data;
      if (data == null) return [];
      final body = data is Map<String, dynamic>
          ? data
          : (data is String ? _jsonDecode(data) : null);
      if (body == null) return [];

      final musiclist = body['musiclist'] as List<dynamic>?;
      if (musiclist == null) return [];

      return musiclist
          .map((item) => _staticParseItem(item as Map<String, dynamic>))
          .whereType<MusicItem>()
          .toList();
    } catch (e) {
      return [];
    }
  }

  @override
  Future<List<LeaderboardCategory>> getLeaderboardCategories() async {
    final fallback = const [
      LeaderboardCategory(id: 'kw:93', name: '飙升榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:17', name: '新歌榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:16', name: '热歌榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:158', name: '抖音热歌榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:292', name: '铃声榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:284', name: '热评榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:290', name: 'ACG新歌榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:286', name: '台湾KKBOX榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:279', name: '冬日暖心榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:281', name: '巴士随身听榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:255', name: 'KTV点唱榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:280', name: '家务进行曲榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:282', name: '熬夜修仙榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:283', name: '枕边轻音乐榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:278', name: '古风音乐榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:264', name: 'Vlog音乐榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:242', name: '电音榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:187', name: '流行趋势榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:204', name: '现场音乐榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:186', name: 'ACG神曲榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:185', name: '最强翻唱榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:26', name: '经典怀旧榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:104', name: '华语榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:182', name: '粤语榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:22', name: '欧美榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:184', name: '韩语榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:183', name: '日语榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:145', name: '会员畅听榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:153', name: '网红新歌榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:64', name: '影视金曲榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:176', name: 'DJ嗨歌榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:106', name: '真声音', platform: 'kw'),
      LeaderboardCategory(id: 'kw:12', name: 'Billboard榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:49', name: 'iTunes音乐榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:180', name: 'beatport电音榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:13', name: '英国UK榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:164', name: '百大DJ榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:246', name: 'YouTube音乐排行榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:265', name: '韩国Genie榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:14', name: '韩国M-net榜', platform: 'kw'),
      LeaderboardCategory(id: 'kw:8', name: '香港电台中文歌曲龙虎榜', platform: 'kw'),
    ];

    // 统一：榜单封面 = 榜内首曲 artwork
    return Future.wait(fallback.map((c) async {
      try {
        final songs = await getLeaderboardSongs(c.id, limit: 1);
        final art = songs.isNotEmpty ? songs.first.artwork : null;
        return c.copyWith(
          coverUrl: (art != null && art.isNotEmpty) ? art : null,
        );
      } catch (_) {
        return c;
      }
    }));
  }

  @override
  Future<List<MusicItem>> getLeaderboardSongs(String leaderboardId,
      {int page = 1, int limit = 100}) async {
    try {
      final parts = leaderboardId.split(':');
      final bangid = parts.length == 2 ? parts[1] : leaderboardId;

      debugPrint('[KW] getLeaderboardSongs: bangid=$bangid, page=$page');

      // 桌面版使用的 API: https://wbd.kuwo.cn/api/bd/bang/bang_info
      final requestBody = {
        'uid': '',
        'devId': '',
        'sFrom': 'kuwo_sdk',
        'user_type': 'AP',
        'carSource': 'kwplayercar_ar_6.0.1.0_apk_keluze.apk',
        'id': bangid,
        'pn': page - 1,
        'rn': limit,
      };

      final url =
          'https://wbd.kuwo.cn/api/bd/bang/bang_info?${WbdCrypto.buildParam(requestBody)}';
      debugPrint('[KW] Request URL: $url');

      final response = await _dio
          .get(
            url,
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(seconds: 10));

      final data = response.data;
      debugPrint('[KW] Response status: ${response.statusCode}');
      debugPrint('[KW] Response type: ${data.runtimeType}');
      debugPrint(
          '[KW] Response data (first 500 chars): ${data.toString().substring(0, data.toString().length > 500 ? 500 : data.toString().length)}');

      // API 返回 base64 编码的加密数据（text/plain），Dio 返回 String
      String base64Result;
      if (data is String) {
        base64Result = data;
      } else if (data is Map) {
        base64Result = data['data']?.toString() ?? '';
      } else {
        debugPrint('[KW] getLeaderboardSongs: unexpected type');
        return [];
      }

      if (base64Result.isEmpty) {
        debugPrint('[KW] getLeaderboardSongs: empty data');
        return [];
      }

      debugPrint('[KW] Decoding base64 data...');
      final decrypted = WbdCrypto.decodeData(base64Result);
      debugPrint(
          '[KW] Decrypted data (first 500 chars): ${decrypted.substring(0, decrypted.length > 500 ? 500 : decrypted.length)}');

      final bodyMap = jsonDecode(decrypted) as Map<String, dynamic>;
      debugPrint('[KW] Parsed JSON code: ${bodyMap['code']}');

      if (bodyMap['code'] != 200) {
        debugPrint('[KW] getLeaderboardSongs: code=${bodyMap['code']}');
        return [];
      }

      final musiclist = bodyMap['data']?['musiclist'] as List<dynamic>?;
      if (musiclist == null) {
        debugPrint('[KW] getLeaderboardSongs: no musiclist');
        debugPrint('[KW] data keys: ${bodyMap['data']?.keys}');
        return [];
      }

      debugPrint('[KW] getLeaderboardSongs: ${musiclist.length} songs');
      if (musiclist.isNotEmpty) {
        debugPrint('[KW] First song: ${musiclist[0]}');
      }

      return musiclist
          .map((item) => _staticParseItem(item as Map<String, dynamic>))
          .whereType<MusicItem>()
          .toList();
    } catch (e) {
      debugPrint('[KW] getLeaderboardSongs error: $e');
      return [];
    }
  }

  void dispose() {
    _dio.close();
  }
}
