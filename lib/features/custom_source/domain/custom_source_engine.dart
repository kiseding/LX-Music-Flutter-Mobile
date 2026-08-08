import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:pointycastle/export.dart' as pc;
import 'lx_source_capabilities.dart';
import 'source_runtime_polyfill.dart';
import 'source_script_safety.dart';
import '../../../core/network/source_request_policy.dart';
import '../../../core/network/ios_source_transport.dart';
import '../domain/custom_source.dart';
import '../../player/domain/music_item.dart';

Map<String, dynamic> _decodeMap(String s) =>
    json.decode(s) as Map<String, dynamic>;
dynamic _decodeDynamic(String s) => json.decode(s);

/// 保证脚本可见的 types 列表含本次请求音质，避免空 types 触发低码率回退。
List<String> ensureMusicInfoTypes(Map<String, dynamic> meta, String type) {
  const official = ['hires', 'flac24bit', 'flac', '320k', '128k'];
  final raw = meta['types'] ?? meta['qualitys'] ?? meta['quality'];
  final out = <String>[];
  if (raw is List) {
    for (final e in raw) {
      final s = e.toString().trim().toLowerCase();
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
  } else if (raw is Map) {
    for (final k in raw.keys) {
      final s = k.toString().trim().toLowerCase();
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
  }
  final req = type.trim().toLowerCase();
  if (req.isNotEmpty && !out.contains(req)) {
    out.insert(0, req);
  }
  if (out.isEmpty) {
    out.addAll([if (req.isNotEmpty) req, ...official.where((q) => q != req)]);
  } else {
    for (final q in official) {
      if (!out.contains(q)) out.add(q);
    }
  }
  return out;
}

List<int> secureRandomBytes(int size, {Random? random}) {
  RangeError.checkValueInInterval(size, 0, 65536, 'size');
  final source = random ?? Random.secure();
  return List<int>.generate(size, (_) => source.nextInt(256), growable: false);
}

Map<String, dynamic> buildLxMobileMusicInfo(MusicItem music, String platform) {
  final meta = music.meta ?? const <String, dynamic>{};
  final songmid = music.songmid?.isNotEmpty == true
      ? music.songmid!
      : (meta['songmid'] ?? meta['mid'] ?? music.id).toString();
  final interval = music.duration.inSeconds > 0
      ? '${(music.duration.inSeconds ~/ 60).toString().padLeft(2, '0')}:${(music.duration.inSeconds % 60).toString().padLeft(2, '0')}'
      : (meta['interval']?.toString() ?? '');
  final album = meta['album'];
  final albumMap = album is Map ? album : const <dynamic, dynamic>{};
  final file = meta['file'];
  final fileMap = file is Map ? file : const <dynamic, dynamic>{};
  final albumName = music.album.isNotEmpty
      ? music.album
      : (meta['albumName'] ?? albumMap['name'] ?? album).toString();
  final albumId = (meta['albumId'] ?? albumMap['id'] ?? albumMap['mid'] ?? '')
      .toString();
  final qualities = meta['qualitys'] ?? meta['types'] ?? const <dynamic>[];
  final privateQualities = meta['_qualitys'] ?? meta['_types'] ?? const {};

  final info = <String, dynamic>{
    'name': music.name,
    'singer': music.singer,
    'source': platform,
    'songmid': songmid,
    'interval': interval,
    'albumName': albumName,
    'img': music.artwork ?? meta['picUrl']?.toString() ?? '',
    'typeUrl': <String, dynamic>{},
  };

  if (platform == 'local') {
    info.addAll({
      'filePath': meta['filePath']?.toString() ?? songmid,
      'ext': meta['ext']?.toString() ?? '',
      'albumId': '',
      'types': <dynamic>[],
      '_types': <String, dynamic>{},
    });
    return info;
  }

  info.addAll({
    'albumId': albumId,
    'types': qualities,
    '_types': privateQualities,
  });

  switch (platform) {
    case 'kg':
      final hash = music.hash ?? meta['hash'] ?? meta['FileHash'];
      if (hash != null && hash.toString().isNotEmpty) {
        info['hash'] = hash.toString();
      }
    case 'tx':
      info.addAll({
        'strMediaMid':
            (meta['strMediaMid'] ??
                    meta['media_mid'] ??
                    fileMap['media_mid'] ??
                    '')
                .toString(),
        'albumMid': (meta['albumMid'] ?? albumMap['mid'] ?? '').toString(),
        'songId': (meta['songId'] ?? meta['id'] ?? music.id).toString(),
      });
    case 'mg':
      info.addAll({
        'copyrightId': meta['copyrightId'],
        'lrcUrl': meta['lrcUrl'],
        'mrcUrl': meta['mrcUrl'] ?? meta['mrcurl'],
        'trcUrl': meta['trcUrl'],
      });
  }
  return info;
}

Map<String, dynamic> buildSongListDetailParams(
  String id,
  String source,
  int page,
) => {
  'action': 'songListDetail',
  'source': source,
  'info': {'id': id, 'page': page},
};

class CustomSourceEngine {
  JavascriptRuntime? _runtime;
  late final SourceRequestSandbox _requestSandbox;
  CustomSource? _currentSource;
  bool _initialized = false;

  /// 仅在 inited + 能力校验成功后为 true（避免失败 init 被当成成功缓存）
  bool _sourceReady = false;
  Future<bool>? _loadInFlight;
  final _uuid = const Uuid();
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  final Map<String, Completer<dynamic>> _pendingRequests = {};
  final Map<String, SourceRequestCancellation> _httpCancellations = {};
  Completer<void>? _initCompleter;
  LxSourceCapabilities _capabilities = LxSourceCapabilities.fromInitData(null);
  final List<Map<String, dynamic>> _deferredMessages = [];
  Future<void> Function(dynamic)? _handleLxRequest;
  int _timeoutGeneration = 0;

  CustomSourceEngine({
    SourceRequestPolicy? requestPolicy,
    SourceTransport? requestTransport,
  }) {
    _requestSandbox = SourceRequestSandbox(
      policy: requestPolicy ?? SourceRequestPolicy(),
      transport: requestTransport ?? IOSSourceTransport().call,
      maximumRedirects: 10,
    );
  }

  /// 取消在途 HTTP/请求，防止 dispose/reload 后回调打到已销毁 runtime
  void _invalidateSession(String reason) {
    _timeoutGeneration++;
    for (final t in _httpCancellations.values) {
      t.cancel(reason);
    }
    _httpCancellations.clear();
    for (final c in _pendingRequests.values) {
      if (!c.isCompleted) {
        c.completeError(StateError(reason));
      }
    }
    _pendingRequests.clear();
    _deferredMessages.clear();
    final init = _initCompleter;
    if (init != null && !init.isCompleted) {
      init.completeError(StateError(reason));
    }
    _initCompleter = null;
    _sourceReady = false;
    _capabilities = LxSourceCapabilities.fromInitData(null);
  }

  Stream<Map<String, dynamic>> get eventStream => _eventController.stream;

  String? effectiveMusicQuality(String platform, String requested) {
    return _capabilities.effectiveQuality(platform, 'musicUrl', requested);
  }

  Future<void> _ensureInitialized() async {
    if (_initialized && _runtime != null) return;

    // 给 UI 线程一个机会去渲染（如显示加载动画）
    await Future.delayed(Duration.zero);

    try {
      _runtime = getJavascriptRuntime();
      _setupBaseEnvironment();
      _initialized = true;
    } catch (e) {
      _initialized = false;
    }
  }

  void _setupBaseEnvironment() {
    if (_runtime == null) return;

    _runtime!.onMessage('lx_secure_random', (dynamic size) {
      final count = size is num ? size.toInt() : int.parse(size.toString());
      return base64Encode(secureRandomBytes(count));
    });

    // 保存原始的 sendMessage 函数，用于在加载脚本时缓冲消息，避免 iOS 平台通道死锁
    _runtime!.evaluate(
      'globalThis._originalSendMessage = globalThis.sendMessage;',
    );

    // 1. Console & Environment 桥接
    _runtime!.evaluate('''
      // 关键修复：flutter_js 的 JSC 端 _sendMessage 内部会 jsonDecode(message)，
      // 如果 message 不是合法 JSON，整个 _sendMessage 会抛 native 异常。
      // 必须用 JSON.stringify 包装所有 sendMessage 的 message 参数。
      globalThis.console = {
        log: function() {
          var msg = Array.prototype.slice.call(arguments).map(function(v) {
            try { return typeof v === 'object' ? JSON.stringify(v) : String(v); } catch(e) { return "[Object]"; }
          }).join(' ');
          sendMessage('console_log', JSON.stringify(msg));
        },
        error: function() {
          var msg = Array.prototype.slice.call(arguments).map(function(v) {
            try { return typeof v === 'object' ? JSON.stringify(v) : String(v); } catch(e) { return "[Object]"; }
          }).join(' ');
          sendMessage('console_error', JSON.stringify(msg));
        },
        group: function() {},
        groupEnd: function() {}
      };
      
      globalThis.window = globalThis;
      globalThis.process = { env: { NODE_ENV: 'production' } };
      globalThis.navigator = { userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' };

      (function() {
        var pool = '';
        var offset = 0;
        globalThis.__lxResetSecureRandomPool = function(encoded) {
          pool = globalThis.atob(encoded);
          offset = 0;
        };
        globalThis.__lxSecureRandomBytes = function(size) {
          if (size < 0 || size > 65536) throw new RangeError('Invalid random byte count');
          if (pool.length - offset < size) {
            globalThis.__lxResetSecureRandomPool(sendMessage('lx_secure_random', size));
          }
          var result = pool.slice(offset, offset + size);
          offset += size;
          return result;
        };
      })();

      // 对齐官方移动版：注入 Web Crypto 兜底。混淆/打包脚本内嵌的
      // sha256/md5 等库在 QuickJS（无原生 Web Crypto）下会直接访问
      // crypto.getRandomValues，缺了会抛 "Cannot read properties of
      // undefined (reading 'crypto')" 导致整个源无法加载。
      if (typeof globalThis.crypto === 'undefined' ||
          typeof globalThis.crypto.getRandomValues !== 'function') {
        globalThis.crypto = {
          getRandomValues: function(arr) {
            if (!arr || typeof arr.length !== 'number') throw new TypeError('Expected a typed array');
            var bytes = globalThis.__lxSecureRandomBytes(arr.length);
            for (var i = 0; i < arr.length; i++) arr[i] = bytes.charCodeAt(i) & 255;
            return arr;
          }
        };
      }
      
      // 关键修复：使用数字 id (Date.now() + counter) 而不是字符串，
      // 这样脚本里 `clearTimeout(id)` 能用相等的 id 准确取消回调。
      // 字符串 id 在某些边界情况下（如 setTimeout 内部把 id 存到 Set/Map
      // 时）会失配。
      globalThis._timeoutCounter = 0;
      globalThis.setTimeout = function(fn, ms) {
        globalThis._timeoutCounter = (globalThis._timeoutCounter || 0) + 1;
        var id = Date.now() + globalThis._timeoutCounter;
        globalThis._callbacks['timeout_' + id] = fn;
        sendMessage('set_timeout', JSON.stringify({ id: id, ms: ms || 0 }));
        return id;
      };

      globalThis.clearTimeout = function(id) {
        // 同时清掉 _callbacks 里的字符串 key 与 Dart 端的 Future
        if (globalThis._callbacks) delete globalThis._callbacks['timeout_' + id];
        sendMessage('clear_timeout', id);
      };

      (function() {
        var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
        globalThis.atob = globalThis.atob || function(input) {
          var str = String(input).replace(/[=]+\$/, '');
          for (var bc = 0, bs, buffer, idx = 0, output = ''; buffer = str.charAt(idx++); ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4) ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
            buffer = chars.indexOf(buffer);
          }
          return output;
        };
        globalThis.btoa = globalThis.btoa || function(input) {
          var str = String(input);
          for (var block, charCode, idx = 0, map = chars, output = ''; str.charAt(idx | 0) || (map = '=', idx % 1); output += map.charAt(63 & block >> 8 - idx % 1 * 8)) {
            charCode = str.charCodeAt(idx += 3 / 4);
            if (charCode > 0xFF) throw new Error("'btoa' failed");
            block = block << 8 | charCode;
          }
          return output;
        };
      })();
    ''');

    // 完整 DOM/浏览器 polyfill + 原生 sha256（借鉴 phg-music），
    // 让对环境敏感的混淆音源（如 sixyin）通过 self-defending 自校验。
    _runtime!.evaluate(SourceRuntimePolyfill.js());

    _runtime!.onMessage('set_timeout', (dynamic args) {
      final data = json.decode(args);
      final id = data['id'];
      final ms = data['ms'] as int;
      final timeoutGeneration = _timeoutGeneration;
      Future.delayed(Duration(milliseconds: ms), () {
        if (_runtime != null && timeoutGeneration == _timeoutGeneration) {
          // 修复：id 是数字，必须拼成 'timeout_'+id 字符串 key 才能正确
          // 取到 _callbacks 里的回调。clearTimeout 已经把 callback 删了，
          // 所以这里再次 delete 是 no-op，安全。
          _runtime!.evaluate(
            'if(globalThis._callbacks["timeout_$id"]) { globalThis._callbacks["timeout_$id"](); delete globalThis._callbacks["timeout_$id"]; }',
          );
          // 推动 microtask 队列（例如 setTimeout 回调里再 await lx.request）
          _flushMicrotasks(maxIterations: 4);
        }
      });
    });
    _runtime!.onMessage('clear_timeout', (dynamic id) {
      // 同步清掉 JS 端 callbacks（防止 timeout 触发时重复调用）
      if (_runtime != null) {
        _runtime!.evaluate(
          'if(globalThis._callbacks) delete globalThis._callbacks["timeout_$id"];',
        );
      }
    });
    _runtime!.onMessage('console_log', (msg) {
      _eventController.add({'type': 'log', 'message': msg});
    });
    _runtime!.onMessage('console_error', (msg) {
      _eventController.add({'type': 'error', 'message': msg});
    });

    // 2. HTTP 桥接 (lx.request)
    _handleLxRequest = (dynamic args) async {
      Map<String, dynamic> data;
      debugPrint('[LX] lx_request received args type=${args.runtimeType}');
      try {
        if (args is String) {
          final String argsStr = args;
          data = argsStr.length > 10000
              ? await compute<String, Map<String, dynamic>>(_decodeMap, argsStr)
              : json.decode(argsStr) as Map<String, dynamic>;
        } else {
          data = args;
        }
      } catch (e) {
        return;
      }

      final callbackId = data['callbackId']?.toString();
      final url = data['url']?.toString();
      if (callbackId == null || url == null || url.isEmpty) {
        debugPrint('[LX] lx_request missing callbackId or url');
        return;
      }
      debugPrint(
        '[LX] lx_request callbackId=${callbackId.hashCode} url=${_redactUrl(url)}',
      );
      final Map<String, dynamic> options = data['options'] ?? {};
      SourceRequestCancellation? requestCancellation;
      try {
        final isBinary = options['binary'] == true;

        // 提取并处理 params (Query Parameters)
        Map<String, dynamic>? queryParams;
        if (options['params'] != null && options['params'] is Map) {
          queryParams = Map<String, dynamic>.from(options['params']);
        }

        final cancellation = SourceRequestCancellation();
        requestCancellation = cancellation;
        _httpCancellations[callbackId] = cancellation;
        final response = await _makeHttpRequest(
          url,
          options,
          isBinary: isBinary,
          queryParams: queryParams,
          cancellation: cancellation,
        );
        await withSourceResponseLease(response, (response) async {
          final rawBytes = response.bytes;
          dynamic body = utf8.decode(rawBytes, allowMalformed: true);
          if (!isBinary) {
            if (body is String && body.isNotEmpty) {
              final String bodyStr = body;
              try {
                if (bodyStr.length > 50000) {
                  final dynamic decoded = await compute<String, dynamic>(
                    _decodeDynamic,
                    bodyStr,
                  );
                  body = decoded;
                } else {
                  body = json.decode(bodyStr);
                }
              } catch (e) {
                // 忽略解析错误，保持原始字符串
              }
            }
          }

          final statusCode = response.statusCode;
          if (statusCode != null && (statusCode < 200 || statusCode >= 300)) {
            final diagnostic = <String, dynamic>{
              'statusCode': response.statusCode,
              'bodyType': body.runtimeType.toString(),
            };
            if (body is Map) {
              diagnostic['code'] = body['code'];
              diagnostic['message'] = body['message']?.toString();
            } else if (body is String) {
              diagnostic['bodyLength'] = body.length;
              diagnostic['bodyPrefix'] = body.length <= 80
                  ? body
                  : body.substring(0, 80);
            }
            _emitDiagnostic('http_error_response', diagnostic);
          }

          final Map<String, String> flatHeaders = {};
          response.headers.forEach((name, values) {
            flatHeaders[name.toLowerCase()] = values.join(', ');
          });
          final rawB64 = base64Encode(rawBytes);
          debugPrint(
            '[LX] lx_request HTTP done callbackId=$callbackId status=${response.statusCode} bytes=${rawBytes.length}',
          );
          if (!response.isCancelled) {
            _executeJsCallback(callbackId, [
              null,
              {
                'statusCode': response.statusCode,
                'statusMessage': response.statusMessage,
                'body': body,
                'headers': flatHeaders,
                'bytes': rawBytes.length,
                'responseRaw': rawB64,
                'rawData': rawB64,
              },
              body,
            ], url: url);
          }
        });
      } catch (e) {
        final message = _formatRequestError(e);
        debugPrint(
          '[LX] lx_request HTTP FAIL callbackId=$callbackId err=$message',
        );
        if (requestCancellation?.isCancelled != true) {
          _executeJsCallback(callbackId, [message, null, null], url: url);
        }
      } finally {
        _httpCancellations.remove(callbackId);
      }
    };
    _runtime!.onMessage('lx_request', _handleLxRequest!);

    _runtime!.onMessage('lx_request_cancel', (dynamic args) {
      final data = args is String
          ? json.decode(args) as Map<String, dynamic>
          : args as Map;
      final callbackId = data['callbackId']?.toString();
      if (callbackId != null) {
        _httpCancellations
            .remove(callbackId)
            ?.cancel('Source canceled request');
      }
    });

    _runtime!.onMessage('lx_send', (dynamic args) async {
      Map<String, dynamic> data;
      try {
        if (args is String) {
          final String argsStr = args;
          data = argsStr.length > 10000
              ? await compute<String, Map<String, dynamic>>(_decodeMap, argsStr)
              : json.decode(argsStr) as Map<String, dynamic>;
        } else {
          data = args;
        }
      } catch (e) {
        return;
      }

      _handleLxSend(data);
    });

    _runtime!.onMessage('lx_response', (dynamic args) async {
      try {
        Map<String, dynamic> data;
        if (args is String) {
          final String argsStr = args;
          data = argsStr.length > 10000
              ? await compute<String, Map<String, dynamic>>(_decodeMap, argsStr)
              : json.decode(argsStr) as Map<String, dynamic>;
        } else {
          data = args;
        }

        final String? reqId = data['reqId'];
        final dynamic result = data['data'];
        final String? error = data['error'];
        debugPrint(
          '[LX] lx_response arrived reqId=$reqId hasError=${error != null} hasData=${result != null} pending=${_pendingRequests.keys.toList()}',
        );

        if (reqId != null && _pendingRequests.containsKey(reqId)) {
          final completer = _pendingRequests.remove(reqId);
          if (error != null) {
            debugPrint(
              '[LX] lx_response completing reqId=$reqId with ERROR: $error',
            );
            completer?.completeError(error);
          } else {
            debugPrint('[LX] lx_response completing reqId=$reqId with data');
            completer?.complete(result);
          }
        } else {
          debugPrint(
            '[LX] lx_response reqId=$reqId NOT in pending (stale or unknown)',
          );
        }
      } catch (e) {
        debugPrint('[LX] lx_response parse failed: $e');
        // 解析错误，忽略
      }
      // 让后续可能的 microtask (例如 lx.send 或 console) 跑掉
      _flushMicrotasks();
    });

    // 3. Crypto 桥接 (lx.utils.crypto)
    _runtime!.onMessage('lx_crypto', (dynamic args) {
      final Map<String, dynamic> data = (args is String)
          ? json.decode(args)
          : args;
      final String method = data['method'];
      final dynamic input = data['input'];

      try {
        if (method == 'md5') {
          return md5.convert(utf8.encode(input.toString())).toString();
        }
        if (method == 'randomBytes') {
          final size = input is num
              ? input.toInt()
              : int.parse(input.toString());
          return base64Encode(secureRandomBytes(size));
        }
        if (method == 'aesEncrypt') {
          final dynamic inputData = data['input'];
          List<int> inputBytes;
          if (inputData is String) {
            // 如果是合法的 Base64 则解码，否则按 UTF8 编码
            try {
              inputBytes =
                  (inputData.length % 4 == 0 &&
                      RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(inputData))
                  ? base64Decode(inputData)
                  : utf8.encode(inputData);
            } catch (_) {
              inputBytes = utf8.encode(inputData);
            }
          } else {
            inputBytes = utf8.encode(inputData.toString());
          }

          final String mode = data['mode'] ?? 'aes-128-cbc';
          final String keyText = data['key'] ?? '';
          final String ivText = data['iv'] ?? '';

          final key = encrypt_lib.Key.fromUtf8(
            keyText.padRight(16, '\x00').substring(0, 16),
          );
          final iv = encrypt_lib.IV.fromUtf8(
            ivText.padRight(16, '\x00').substring(0, 16),
          );

          final aesMode = mode.toLowerCase().contains('cbc')
              ? encrypt_lib.AESMode.cbc
              : encrypt_lib.AESMode.ecb;

          final encrypter = encrypt_lib.Encrypter(
            encrypt_lib.AES(key, mode: aesMode),
          );
          // 桌面版返回的是 Buffer，这里对应 Base64
          final encrypted = encrypter.encryptBytes(inputBytes, iv: iv);
          return encrypted.base64;
        }
        if (method == 'rsaEncrypt') {
          final dynamic inputData = data['input'];
          final List<int> inputBytes =
              (inputData is String && inputData.length % 4 == 0)
              ? base64Decode(inputData)
              : utf8.encode(inputData.toString());

          final String publicKey = data['key'] ?? '';
          final parser = encrypt_lib.RSAKeyParser();
          final pc.RSAPublicKey key =
              parser.parse(publicKey) as pc.RSAPublicKey;

          // 对齐桌面版：真正的 RSA_NO_PADDING 实现。
          // 输入必须是 128 字节，直接进行模幂运算。
          List<int> paddedBytes = inputBytes;
          if (paddedBytes.length < 128) {
            paddedBytes =
                List<int>.filled(128 - paddedBytes.length, 0) + paddedBytes;
          } else if (paddedBytes.length > 128) {
            paddedBytes = paddedBytes.sublist(paddedBytes.length - 128);
          }

          // 使用 PointyCastle 进行模幂运算 (RSA_NO_PADDING)
          final engine = pc.RSAEngine()
            ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(key));
          final encrypted = engine.process(Uint8List.fromList(paddedBytes));

          return base64Encode(encrypted);
        }
      } catch (e) {
        // crypto error, return empty
      }
      return '';
    });

    // 4. Zlib 桥接 (lx.utils.zlib)
    _runtime!.onMessage('lx_zlib', (dynamic args) {
      try {
        final Map<String, dynamic> data = (args is String)
            ? json.decode(args)
            : args;
        final String method = data['method'];
        final String inputBase64 = data['data'] ?? '';
        final List<int> inputBytes = base64Decode(inputBase64);

        if (method == 'inflate') {
          final inflated = ZLibCodec().decode(inputBytes);
          return base64Encode(inflated);
        }
        if (method == 'deflate') {
          final deflated = ZLibCodec().encode(inputBytes);
          return base64Encode(deflated);
        }
      } catch (e) {
        // zlib error, return empty
      }
      return '';
    });

    // 4. 事件回调桥接已在前面定义，此处移除冗余

    // 5. 初始化核心 JS 环境
    _runtime!.evaluate(r'''
      var globalThis = globalThis || window || {};
      
      (function() {
        var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
        globalThis.btoa = globalThis.btoa || function(input) {
          var str = String(input);
          for (var block, charCode, idx = 0, map = chars, output = ''; str.charAt(idx | 0) || (map = '=', idx % 1); output += map.charAt(63 & block >> 8 - idx % 1 * 8)) {
            charCode = str.charCodeAt(idx += 3 / 4);
            if (charCode > 0xFF) throw new Error("'btoa' failed");
            block = block << 8 | charCode;
          }
          return output;
        };
        globalThis.atob = globalThis.atob || function(input) {
          var str = String(input).replace(/[=]+$/, '');
          for (var bc = 0, bs, buffer, idx = 0, output = ''; buffer = str.charAt(idx++); ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4) ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
            buffer = chars.indexOf(buffer);
          }
          return output;
        };
      })();

      (function() {
        function md5Utf8(string) {
          // Official mobile hashes UTF-8 bytes, including raw scripts with
          // Unicode identifiers, rather than JavaScript UTF-16 code units.
          var input = unescape(encodeURIComponent(string));
          var bytes = [];
          for (var i = 0; i < input.length; i++) bytes.push(input.charCodeAt(i));
          var bitLength = bytes.length * 8;
          bytes.push(0x80);
          while (bytes.length % 64 !== 56) bytes.push(0);
          for (i = 0; i < 8; i++) bytes.push(Math.floor(bitLength / Math.pow(256, i)) & 0xff);

          var shifts = [
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
          ];
          var constants = [];
          for (i = 0; i < 64; i++) {
            constants[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) | 0;
          }

          var a0 = 0x67452301;
          var b0 = 0xefcdab89 | 0;
          var c0 = 0x98badcfe | 0;
          var d0 = 0x10325476;
          for (var offset = 0; offset < bytes.length; offset += 64) {
            var words = [];
            for (i = 0; i < 16; i++) {
              var wordOffset = offset + i * 4;
              words[i] = bytes[wordOffset] |
                (bytes[wordOffset + 1] << 8) |
                (bytes[wordOffset + 2] << 16) |
                (bytes[wordOffset + 3] << 24);
            }
            var a = a0, b = b0, c = c0, d = d0;
            for (i = 0; i < 64; i++) {
              var f, g;
              if (i < 16) {
                f = (b & c) | (~b & d);
                g = i;
              } else if (i < 32) {
                f = (d & b) | (~d & c);
                g = (5 * i + 1) % 16;
              } else if (i < 48) {
                f = b ^ c ^ d;
                g = (3 * i + 5) % 16;
              } else {
                f = c ^ (b | ~d);
                g = (7 * i) % 16;
              }
              var sum = (a + f + constants[i] + words[g]) | 0;
              a = d;
              d = c;
              c = b;
              b = (b + ((sum << shifts[i]) | (sum >>> (32 - shifts[i])))) | 0;
            }
            a0 = (a0 + a) | 0;
            b0 = (b0 + b) | 0;
            c0 = (c0 + c) | 0;
            d0 = (d0 + d) | 0;
          }

          var hex = '';
          [a0, b0, c0, d0].forEach(function(value) {
            for (var i = 0; i < 4; i++) {
              var byte = (value >>> (i * 8)) & 0xff;
              hex += (byte < 16 ? '0' : '') + byte.toString(16);
            }
          });
          return hex;
        }
        globalThis._md5 = md5Utf8;
      })();

      // 官方 preload 用原生 b642buf/str2b64 + Uint8Array，这里提供等价辅助
      var __lxBufferUtf8 = function(s) {
        var bytes = [];
        for (var i = 0; i < s.length; i++) {
          var code = s.charCodeAt(i);
          if (code < 0x80) bytes.push(code);
          else if (code < 0x800) {
            bytes.push((code >> 6) | 0xC0, (code & 0x3F) | 0x80);
          } else {
            bytes.push((code >> 12) | 0xE0, ((code >> 6) & 0x3F) | 0x80, (code & 0x3F) | 0x80);
          }
        }
        return bytes;
      };
      var __lxBufferUtf8Str = function(bytes) {
        var s = '';
        for (var i = 0; i < bytes.length; ) {
          var b = bytes[i] & 255;
          if (b < 0x80) { s += String.fromCharCode(b); i++; }
          else if (b < 0xE0) { s += String.fromCharCode(((b & 0x1F) << 6) | (bytes[i + 1] & 0x3F)); i += 2; }
          else { s += String.fromCharCode(((b & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F)); i += 3; }
        }
        return s;
      };
      var __lxBufferB64 = function(bytes) {
        var s = '';
        for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i] & 255);
        return globalThis.btoa(s);
      };
      var __lxBufferBytesB64 = function(b64) {
        var s = globalThis.atob(b64);
        var b = [];
        for (var i = 0; i < s.length; i++) b.push(s.charCodeAt(i) & 255);
        return b;
      };

      globalThis.lx = {
        version: '2.0.0',
        env: 'mobile',
        EVENT_NAMES: {
          request: 'request',
          inited: 'inited',
          updateAlert: 'updateAlert'
        },
        request: function(url, options, callback) {
          if (typeof options === 'function') { callback = options; options = {}; }
          if (options.form && !options.body) options.body = options.form; 

          // 记录请求 URL 以便调试
          if (url.indexOf('http') !== 0 && globalThis.lx.currentScriptInfo && globalThis.lx.currentScriptInfo.baseUrl) {
             // 某些脚本可能使用相对路径（虽然少见）
          }

          if (typeof globalThis._pendingRequests === 'undefined') {
            globalThis._pendingRequests = 0;
          }

          var requestInternal = function(cb) {
              var callbackId = 'cb_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
              globalThis._callbacks[callbackId] = function(err, res, body) {
                if (res && res.responseRaw) {
                  res.responseRaw = globalThis.lx.utils.buffer.from(res.responseRaw, 'base64');
                }
                if (res) res.rawData = res.responseRaw;
                if (res && options.binary) {
                  res.body = res.responseRaw;
                  body = res.responseRaw;
                }
                if (err) console.error('[JS Debug] Request Error: ' + url + ' -> ' + (err.message || err));
                else if (res) console.log('[JS Debug] Request Success: ' + url + ' [' + res.statusCode + ']');

                // 对齐官方移动端 UserApi preload：无论 callback 的声明形状如何，
                // 始终调用 (err, response, body)。混淆器常会改变 Function.length，
                // 基于 arity 重排参数会让源将 body 当成 error 或 response。
                try {
                  cb(err, res, body);
                }
                finally { globalThis._pendingRequests--; }
              };
              // 对齐官方移动版 fetchData：默认带 Accept: application/json
              //（脚本显式设置的头优先），部分 API 服务器校验该头。
              options.headers = options.headers || {};
              if (!options.headers.Accept && !options.headers.accept) {
                options.headers.Accept = 'application/json';
              }
              if (options.body && typeof URLSearchParams !== 'undefined' && options.body instanceof URLSearchParams) {
                options.body = options.body.toString();
                if (!options.headers['Content-Type'] && !options.headers['content-type']) {
                  options.headers['Content-Type'] = 'application/x-www-form-urlencoded';
                }
              }
              if (options.body && options.body._data instanceof Array) {
                options.formData = {};
                options.body._data.forEach(function(pair) { options.formData[pair[0]] = pair[1]; });
                options.body = undefined;
              }
              if (options.formData && options.formData._data instanceof Array) {
                var fd = {};
                options.formData._data.forEach(function(pair) { fd[pair[0]] = pair[1]; });
                options.formData = fd;
              }
              // 二进制 body/formData 不能直接 JSON 序列化（Uint8Array 会变成索引对象），
              // 转 base64 标记后由 Dart 侧解码，对齐官方 fetchData 的 binary body 处理。
              if (options.body &&
                  (ArrayBuffer.isView(options.body) || Array.isArray(options.body))) {
                options._binaryBodyBase64 =
                    globalThis.lx.utils.buffer.bufToString(options.body, 'base64');
                options.body = undefined;
              }
              if (options.formData &&
                  (ArrayBuffer.isView(options.formData) ||
                      Array.isArray(options.formData))) {
                options._formDataBase64 = globalThis.lx.utils.buffer
                    .bufToString(options.formData, 'base64');
                options.formData = undefined;
              }
              globalThis._pendingRequests++;
              sendMessage('lx_request', JSON.stringify({ url: url, options: options, callbackId: callbackId }));
              return function() {
                if (globalThis._callbacks[callbackId]) {
                  delete globalThis._callbacks[callbackId];
                  globalThis._pendingRequests--;
                  sendMessage('lx_request_cancel', JSON.stringify({ callbackId: callbackId }));
                }
              };
          };
          if (typeof callback === 'function') return requestInternal(callback);
          else return new Promise(function(resolve, reject) {
              requestInternal(function(err, res, body) { if (err) reject(new Error(err)); else resolve(res); });
          });
        },
        send: function(eventName, data) {
          if (eventName !== globalThis.lx.EVENT_NAMES.inited && eventName !== globalThis.lx.EVENT_NAMES.updateAlert) {
            return Promise.reject(new Error('The event is not supported: ' + eventName));
          }
          sendMessage('lx_send', JSON.stringify({ event: eventName, data: data }));
          return Promise.resolve();
        },
        on: function(eventName, handler) {
          if (eventName !== globalThis.lx.EVENT_NAMES.request) {
            return Promise.reject(new Error('The event is not supported: ' + eventName));
          }
          // 官方移动端只保留当前脚本的 request handler。
          globalThis._requestHandler = handler;
          return Promise.resolve();
        },
        utils: {
          buffer: {
            from: function(input, encoding) {
              if (input && (ArrayBuffer.isView(input) || Array.isArray(input))) return new Uint8Array(input);
              if (typeof input === 'string') {
                if (encoding === 'hex') {
                  var m = input.match(/.{1,2}/g) || [];
                  var out = new Uint8Array(m.length);
                  for (var i = 0; i < m.length; i++) out[i] = parseInt(m[i], 16);
                  return out;
                }
                if (encoding === 'base64') {
                  var b64 = __lxBufferBytesB64(input);
                  var o = new Uint8Array(b64.length);
                  for (var j = 0; j < b64.length; j++) o[j] = b64[j];
                  return o;
                }
                var u = __lxBufferUtf8(input);
                var o2 = new Uint8Array(u.length);
                for (var k = 0; k < u.length; k++) o2[k] = u[k];
                return o2;
              }
              throw new Error('Unsupported input type: ' + input + ' encoding: ' + encoding);
            },
            alloc: function(size, fill) {
              var out = new Uint8Array(size);
              if (fill !== undefined) {
                var f = typeof fill === 'string' ? (fill.charCodeAt(0) || 0) : (typeof fill === 'number' ? fill : 0);
                for (var i = 0; i < size; i++) out[i] = f;
              }
              return out;
            },
            concat: function(list, totalLength) {
              if (!Array.isArray(list)) throw new TypeError('list must be an Array');
              var bytes = [];
              for (var i = 0; i < list.length; i++) {
                var item = list[i];
                if (typeof item === 'string') {
                  var u = __lxBufferUtf8(item);
                  for (var j = 0; j < u.length; j++) bytes.push(u[j]);
                } else if (item && (ArrayBuffer.isView(item) || Array.isArray(item))) {
                  for (var j2 = 0; j2 < item.length; j2++) bytes.push(item[j2] & 255);
                }
              }
              if (totalLength !== undefined && bytes.length > totalLength) bytes = bytes.slice(0, totalLength);
              var out = new Uint8Array(bytes.length);
              for (var k = 0; k < bytes.length; k++) out[k] = bytes[k];
              return out;
            },
            bufToString: function(buf, format) {
              if (Array.isArray(buf) || ArrayBuffer.isView(buf)) {
                if (format === 'hex') {
                  var hex = '';
                  for (var i = 0; i < buf.length; i++) {
                    var x = buf[i].toString(16);
                    hex += x.length === 1 ? '0' + x : x;
                  }
                  return hex;
                }
                if (format === 'base64') return __lxBufferB64(buf);
                return __lxBufferUtf8Str(buf);
              }
              throw new Error('Input is not a valid buffer: ' + buf + ' format: ' + format);
            }
          },
          crypto: {
            md5: function(str) {
              if (globalThis._md5) return globalThis._md5(str);
              console.error('Crypto error: _md5 not found');
              return "";
            },
            aesEncrypt: function(data, mode, key, iv) {
              if (globalThis.__aesEncrypt) return globalThis.__aesEncrypt(data, mode, key, iv);
              return Promise.resolve(sendMessage('lx_crypto', JSON.stringify({ method: 'aesEncrypt', input: data, mode: mode, key: key, iv: iv })));
            },
            rsaEncrypt: function(data, key) {
              if (globalThis.__rsaEncrypt) return globalThis.__rsaEncrypt(data, key);
              return Promise.resolve(sendMessage('lx_crypto', JSON.stringify({ method: 'rsaEncrypt', input: data, key: key })));
            }
          }
        },
        env: 'mobile', version: '2.0.0', currentScriptInfo: { rawScript: '' }
      };
      globalThis.lx.utils.zlib = {
        inflate: function(buf) { return Promise.resolve(sendMessage('lx_zlib', JSON.stringify({ method: 'inflate', data: globalThis.lx.utils.buffer.bufToString(buf, 'base64') }))).then(function(data) { return globalThis.lx.utils.buffer.from(data, 'base64'); }); },
        deflate: function(data) { return Promise.resolve(sendMessage('lx_zlib', JSON.stringify({ method: 'deflate', data: globalThis.lx.utils.buffer.bufToString(data, 'base64') }))).then(function(result) { return globalThis.lx.utils.buffer.from(result, 'base64'); }); }
      };
      globalThis.lx.utils.crypto.randomBytes = function(size) {
        var bytes = globalThis.__lxSecureRandomBytes(size);
        var result = new Uint8Array(size);
        for (var i = 0; i < bytes.length; i++) result[i] = bytes.charCodeAt(i) & 255;
        return result;
      };
      globalThis.Buffer = globalThis.lx.utils.buffer;
      globalThis._callbacks = {};
      globalThis._requestHandler = null;
      globalThis._initComplete = false;
      globalThis._deferredResolvers = {};
    ''');
  }

  bool _validateCapabilities(dynamic data) {
    _capabilities = LxSourceCapabilities.fromInitData(data);
    if (!LxSourceCapabilities.hasSupportedSource(data)) {
      _emitError('Source initialization did not declare supported sources.');
      return false;
    }
    return true;
  }

  void _handleLxSend(Map<String, dynamic> data) {
    final String? event = data['event']?.toString();
    if (event == 'inited' && _validateCapabilities(data['data'])) {
      final completer = _initCompleter;
      if (completer != null && !completer.isCompleted) completer.complete();
    }
    _eventController.add({
      'type': 'event',
      'event': event,
      'data': data['data'],
    });
  }

  void _emitError(String message) {
    _eventController.add({
      'type': 'error',
      'sourceId': _currentSource?.id,
      'message': message,
    });
  }

  void _emitDiagnostic(String code, Map<String, dynamic> data) {
    _eventController.add({
      'type': 'diagnostic',
      'sourceId': _currentSource?.id,
      'code': code,
      'data': data,
    });
  }

  void _executeJsCallback(
    String callbackId,
    List<dynamic> args, {
    String? url,
  }) {
    if (_runtime == null) return;
    final safeUrl = _redactUrl(url);
    debugPrint(
      '[LX] _executeJsCallback callbackId=${callbackId.hashCode} url=$safeUrl argc=${args.length}',
    );
    final argsJson = json.encode(args);
    final idJson = json.encode(callbackId);
    final varName =
        'temp_args_${DateTime.now().millisecondsSinceEpoch}_${callbackId.hashCode.abs()}';

    _runtime!.evaluate('globalThis.$varName = $argsJson;');

    _runtime!.evaluate('''
      (function() {
        var id = $idJson;
        var cb = globalThis._callbacks[id];
        if (cb) {
          console.log('[JS Debug] invoking HTTP callback length=' + cb.length);
          cb.apply(null, globalThis.$varName);
          delete globalThis._callbacks[id];
        } else {
          console.error('[JS Debug] HTTP callback missing');
        }
        delete globalThis.$varName;
      })()
    ''');

    // 关键修复：flutter_js 的 evaluate 不会自动 flush JS microtask 队列。
    // cb.apply 内部 resolve 了 await lx.request() 的 promise，但后续代码
    // (例如 sendMessage('lx_response', ...) 仍然在 microtask 队列里) 不会
    // 被自动执行。这里通过 evaluate 一个简单的循环让 QuickJS 跑 microtask，
    // 直到队列清空或达到最大轮询次数。
    _flushMicrotasks();
  }

  /// 反复 evaluate 极简表达式以触发 JS 引擎内部的 microtask flush。
  /// 必须在异步回调（如 _executeJsCallback / onMessage）末尾调用，
  /// 否则 await 链无法推进、`sendMessage('lx_response', ...)` 等消息
  /// 永远不会发出，导致 _callRequestEvent 15 秒超时。
  void _flushMicrotasks({int maxIterations = 64}) {
    if (_runtime == null) return;
    for (int i = 0; i < maxIterations; i++) {
      try {
        // HTTP 计数只描述网络请求，不代表 Promise reaction 已经执行完。
        // 即使计数归零也继续推进，避免深层 await 链被提前截断。
        _runtime!.evaluate('void 0;');
      } catch (_) {
        break;
      }
    }
  }

  Future<bool> loadSource(CustomSource source) async {
    if (hasUnsafeSynchronousLoop(source.script)) return false;

    // 串行化并发 load，避免 A dispose 时 B 仍在 evaluate
    while (_loadInFlight != null) {
      try {
        await _loadInFlight;
      } catch (_) {}
    }
    final op = _loadSourceBody(source);
    _loadInFlight = op;
    try {
      return await op;
    } finally {
      if (identical(_loadInFlight, op)) _loadInFlight = null;
    }
  }

  Future<bool> _loadSourceBody(CustomSource source) async {
    // 仅当脚本未变且 inited 成功时短路
    if (_sourceReady &&
        _initialized &&
        _currentSource?.script == source.script) {
      return true;
    }

    // 切换/重载前作废在途请求
    _invalidateSession('Source reloading');
    if (_runtime != null) {
      _runtime!.dispose();
      _runtime = null;
      _initialized = false;
    }

    // 3. 重新初始化基础环境
    await _ensureInitialized();
    if (!_initialized || _runtime == null) return false;

    try {
      _currentSource = source;
      _initCompleter = Completer<void>();
      // 部分音源（如 sixyin 混淆版）会校验 currentScriptInfo 的
      // name/description/version 必须与脚本头部注释一致，否则抛
      // "加载音源脚本失败"。这里直接从脚本头重新解析，覆盖用户可能编辑
      // 过的 source 元数据，确保脚本自校验通过。
      final headerEnd = source.script.indexOf('*/');
      final header = headerEnd > 0 ? source.script.substring(0, headerEnd) : '';
      String? headerMeta(String key) {
        if (header.isEmpty) return null;
        final m = RegExp(
          '@$key\\s+(.+)',
          caseSensitive: false,
        ).firstMatch(header);
        return m?.group(1)?.trim();
      }

      final scriptInfo = {
        'id': source.id,
        'name': headerMeta('name') ?? source.name,
        'description': headerMeta('description') ?? source.description,
        'version': headerMeta('version') ?? source.version,
        'author': headerMeta('author') ?? source.author,
        'homepage': headerMeta('homepage') ?? (source.homepage ?? ''),
        'rawScript': '', // 占位
      };

      // 官方 preload 在创建 lx_setup 环境时原子地传入 rawScript。
      scriptInfo['rawScript'] = source.script;
      debugPrint(
        '[LX Runtime] source id=${source.id} version=${scriptInfo['version']} bytes=${utf8.encode(source.script).length} sha256=${sha256.convert(utf8.encode(source.script))}',
      );
      _runtime!.evaluate(
        'globalThis.lx.currentScriptInfo = ${json.encode(scriptInfo)};',
      );
      _runtime!.evaluate(
        'globalThis.__lxResetSecureRandomPool(${json.encode(base64Encode(secureRandomBytes(65536)))});',
      );

      // 3. 执行新脚本

      // JSC must not synchronously re-enter the native bridge while evaluate is
      // active. Keep messages in JavaScript, then transfer and dispatch them
      // from Dart after evaluation has returned.
      _runtime!.evaluate(r'''
        globalThis._frozenMessages = [];
        globalThis.sendMessage = function(channel, message) {
          if (channel === 'lx_zlib') {
            var id = 'deferred_' + Date.now() + '_' + Math.random().toString(36).slice(2);
            return new Promise(function(resolve, reject) {
              globalThis._deferredResolvers[id] = { resolve: resolve, reject: reject };
              globalThis._frozenMessages.push({ channel: channel, message: message, deferredId: id });
            });
          }
          globalThis._frozenMessages.push({ channel: channel, message: message });
        };
      ''');
      // 对齐官方 UserApi preload：在执行用户脚本前递归锁定全局属性
      // 描述符，并按属性描述符呈现宿主函数。
      _runtime!.evaluate(r'''
        (function() {
          var freezeObject = function(obj, seen) {
            if (!obj || typeof obj !== 'object' || seen.indexOf(obj) !== -1) return;
            seen.push(obj);
            Object.freeze(obj);
            Object.keys(obj).forEach(function(key) {
              freezeObject(obj[key], seen);
            });
          };
          freezeObject(globalThis.lx, []);

          var nativeToString = Function.prototype.toString;
          Function.prototype.toString = function() {
            var descriptor = Object.getOwnPropertyDescriptor(this, 'name');
            if (descriptor && !descriptor.configurable) {
              return 'function ' + this.name + '() { [native code] }';
            }
            return nativeToString.call(this);
          };
          globalThis.eval = function() {
            throw new Error('eval is not available');
          };
          var blockedFunction = new Proxy(Function.prototype.constructor, {
            apply: function() { throw new Error('Dynamic code execution is not allowed.'); },
            construct: function() { throw new Error('Dynamic code execution is not allowed.'); }
          });
          Object.defineProperty(Function.prototype, 'constructor', {
            value: blockedFunction,
            writable: false,
            configurable: false,
            enumerable: false
          });
          globalThis.Function = blockedFunction;

          var lockProperties = function(obj, seen) {
            if (obj == null || (typeof obj !== 'object' && typeof obj !== 'function')) return;
            if (seen.indexOf(obj) !== -1) return;
            seen.push(obj);
            Object.getOwnPropertyNames(obj).forEach(function(name) {
              // The official preload keeps these bridge-owned values in its
              // closure. Our host stores them on globalThis, so they must stay
              // mutable for native callbacks and timers.
              if (obj === globalThis && (
                name === '_callbacks' || name === '_requestHandler' ||
                name === '_frozenMessages' || name === '_deferredResolvers' ||
                name === '_pendingRequests' || name === '_timeoutCounter' ||
                name === '_originalSendMessage' || name === 'sendMessage' ||
                name === '__lxResetSecureRandomPool' || name === '__lxSecureRandomBytes'
              )) return;
              var descriptor;
              try { descriptor = Object.getOwnPropertyDescriptor(obj, name); } catch (_) { return; }
              if (!descriptor) return;
              var changed = false;
              if (descriptor.writable || descriptor.configurable) {
                if (descriptor.writable) descriptor.writable = false;
                if (descriptor.configurable) descriptor.configurable = false;
                changed = true;
              }
              if (changed) {
                try { Object.defineProperty(obj, name, descriptor); } catch (_) {}
              }
              if ('value' in descriptor) lockProperties(descriptor.value, seen);
            });
          };
          lockProperties(globalThis, []);
        })();
      ''');

      final evalStopwatch = Stopwatch()..start();

      // Evaluate the imported text directly: source-defined globals and errors
      // must retain Desktop semantics rather than being hidden by a wrapper.
      final result = _runtime!.evaluate(source.script);
      evalStopwatch.stop();

      // Keep the dispatcher installed while every deferred continuation is
      // pumped. A continuation can emit a new message during evaluate, and
      // calling the original native bridge there would re-enter JSC.
      _captureFrozenMessages();
      await _drainDeferredMessages();
      _restoreSourceMessageDispatcher();

      if (result.isError) {
        _emitError('Script execution failed: ${result.stringResult}');
        _sourceReady = false;
        return false;
      }

      // 5. 等待脚本内部完成 lx.send('inited')。
      // 关键修复：5 秒太短，复杂脚本需要更多时间做 token 拉取 / setTimeout
      // 初始化。同时在等待期间定期 flush microtask，确保脚本里 setTimeout
      // 链上的 lx.send('inited') 能被调度。
      final initTimeout = const Duration(seconds: 30);
      final deadline = DateTime.now().add(initTimeout);
      while (!_initCompleter!.isCompleted &&
          DateTime.now().isBefore(deadline)) {
        // 轮询 flush microtask，让 setTimeout 链上的 lx.send('inited') 跑掉
        _flushMicrotasks(maxIterations: 4);
        try {
          await _initCompleter!.future.timeout(
            const Duration(milliseconds: 500),
          );
          break;
        } catch (_) {
          // 500ms 内没完成就继续轮询
        }
      }
      if (!_initCompleter!.isCompleted) {
        _emitError('Source initialization timed out or was rejected.');
        _sourceReady = false;
        return false;
      }
      _sourceReady = true;
      return true;
    } catch (e) {
      _emitError('Source loading failed: $e');
      _sourceReady = false;
      return false;
    }
  }

  Future<dynamic> _callRequestEvent(Map<String, dynamic> params) async {
    final action = params['action'];

    await _ensureInitialized();
    if (_runtime == null || !_initialized) {
      _eventController.add({'type': 'error', 'message': '引擎未初始化或已销毁'});
      return null;
    }
    final source = params['source']?.toString() ?? '';
    final requestedQuality = action == 'musicUrl' && params['info'] is Map
        ? (params['info'] as Map)['type']?.toString()
        : null;
    if (!_capabilities.allowsAction(source, action.toString())) {
      _emitDiagnostic('capability_rejected', {
        'action': action,
        'platform': source,
        'quality': requestedQuality,
      });
      return null;
    }
    final quality = requestedQuality == null
        ? null
        : _capabilities.effectiveQuality(
            source,
            action.toString(),
            requestedQuality.toLowerCase(),
          );
    if (quality == null && requestedQuality != null) {
      _emitDiagnostic('capability_rejected', {
        'action': action,
        'platform': source,
        'quality': requestedQuality,
      });
      // 能力拒绝是正常回退路径：源未声明 lyric/pic/musicUrl 时直接返回 null，
      // MusicSourceService 会回退到内置源或其它自定义源。不冒充为错误事件，
      // 否则 UI 会刷出“Source does not support lyric for …”红字噪音。
      return null;
    }

    if (requestedQuality != null && quality != requestedQuality) {
      final info = params['info'];
      if (info is Map) {
        info['type'] = quality;
        info['quality'] = quality;
      }
      _emitDiagnostic('quality_downgraded', {
        'action': action,
        'platform': source,
        'requestedQuality': requestedQuality,
        'effectiveQuality': quality,
      });
    }

    final String reqId =
        'req_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 4)}';
    debugPrint(
      '[LX] _callRequestEvent start reqId=$reqId action=${params['action']} source=${params['source']}',
    );
    final paramsJson = json.encode(params);
    final varName =
        'temp_params_${reqId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}';

    // 使用变量注入防止大 JSON 字符串在 evaluate 时导致卡顿
    _runtime!.evaluate('globalThis.$varName = $paramsJson;');

    final completer = Completer<dynamic>();
    _pendingRequests[reqId] = completer;

    final script =
        '''
      (async function() {
        try {
          var params = globalThis.$varName;
          delete globalThis.$varName;
          var action = params.action;
          var reqId = ${json.encode(reqId)};
          console.log('[JS Debug] callRequestEvent start reqId=' + reqId + ' action=' + action + ' source=' + params.source);

          var handler = globalThis._requestHandler;
          if (typeof handler !== 'function') {
            console.error('[JS Debug] no handler registered for reqId=' + reqId);
            sendMessage('lx_response', JSON.stringify({ reqId: reqId, error: 'No request handler is registered.' }));
            return;
          }
          console.log('[JS Debug] invoking request handler for reqId=' + reqId);
          var result = await handler(params);
          console.log('[JS Debug] sending lx_response reqId=' + reqId + ' hasData=' + (result != null));
          sendMessage('lx_response', JSON.stringify({ reqId: reqId, data: result }));
        } catch (e) {
          console.error('[JS Debug] Runtime error during _callRequestEvent: ' + (e && e.message ? e.message : e));
          sendMessage('lx_response', JSON.stringify({ reqId: '$reqId', error: e.message }));
        }
      })();
    ''';

    final evalResult = _runtime!.evaluate(script);
    if (evalResult.isError) {
      debugPrint(
        '[LX] _callRequestEvent JS eval FAILED reqId=$reqId: ${evalResult.stringResult}',
      );
      final errMsg = 'JS调用异常: ${evalResult.stringResult}';
      _eventController.add({'type': 'error', 'message': errMsg});
      _pendingRequests.remove(reqId);
      return null;
    }

    // 关键修复：JS 端 evaluate 后的 (async function(){})() 立即返回，
    // 但 await handlers[i](params) 内部创建的 Promise 不会自动 resolve。
    // 立刻 flush microtask，让同步分支（无 HTTP 请求的 handler）能直接
    // 发出 lx_response，避免不必要的 15 秒等待。
    // 对于 Android QuickJS，一次 flush 不够（Promise 链需要多次事件循环），
    // 使用轮询方式每 500ms flush 一次，直到 completer 完成或超时。
    _flushMicrotasks();

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    debugPrint(
      '[LX] _callRequestEvent polling reqId=$reqId pending=${_pendingRequests.length} handlers set',
    );
    while (!completer.isCompleted && DateTime.now().isBefore(deadline)) {
      _flushMicrotasks(maxIterations: 4);
      try {
        final result = await completer.future.timeout(
          const Duration(milliseconds: 500),
        );
        return result;
      } on TimeoutException {
        // 继续轮询
      } catch (e) {
        _pendingRequests.remove(reqId);
        if (e is TimeoutException) {
          final errMsg = '请求超时(15s): ${params['action']}';
          _eventController.add({'type': 'error', 'message': errMsg});
        } else {
          _eventController.add({'type': 'error', 'message': '请求失败: $e'});
        }
        return null;
      }
    }

    // 超时
    _pendingRequests.remove(reqId);
    debugPrint(
      '[LX] _callRequestEvent TIMEOUT reqId=$reqId action=${params['action']} — lx_response never arrived',
    );
    final errMsg = '请求超时(15s): ${params['action']}';
    _eventController.add({'type': 'error', 'message': errMsg});
    return null;
  }

  void _enqueueDeferredMessages(String encodedMessages) {
    try {
      final messages = json.decode(encodedMessages);
      if (messages is List) {
        for (final message in messages) {
          if (message is Map) {
            _deferredMessages.add(Map<String, dynamic>.from(message));
          }
        }
      }
    } catch (_) {
      _emitError('Source initialization emitted malformed deferred messages.');
    }
  }

  Future<void> _drainDeferredMessages() async {
    while (_deferredMessages.isNotEmpty) {
      final message = _deferredMessages.removeAt(0);
      final channel = message['channel']?.toString();
      final payload = message['message'];
      if (channel == 'lx_send') {
        try {
          _handleLxSend(json.decode(payload as String) as Map<String, dynamic>);
        } catch (_) {
          _emitError('Source initialization emitted an invalid event.');
        }
      } else if (channel == 'console_log' || channel == 'console_error') {
        _eventController.add({
          'type': channel == 'console_log' ? 'log' : 'error',
          'message': payload,
        });
      } else if (channel == 'lx_zlib') {
        final result = _runZlib(payload);
        _resolveDeferredMessage(message['deferredId']?.toString(), result);
      } else if (channel == 'lx_request') {
        final handler = _handleLxRequest;
        if (handler == null) {
          _emitError('Source initialization request bridge is unavailable.');
        } else {
          await handler(payload);
        }
      } else if (channel == 'set_timeout') {
        // 脚本初始化阶段的 setTimeout 会被冻结到 deferred 队列（evaluate
        // 期间 sendMessage 不能同步回原生）。必须在这里调度，否则依赖
        // setTimeout 链做初始化（如 sixyin）的源永远无法完成 inited，
        // 最终 30s 超时。
        _scheduleDeferredTimeout(payload);
      } else if (channel == 'clear_timeout') {
        _clearDeferredTimeout(payload);
      } else {
        _emitError(
          'Source initialization used unsupported deferred channel: $channel.',
        );
      }
      // HTTP callbacks and deferred promise resolution can enqueue another
      // source message while Dart is awaiting this message's result.
      _captureFrozenMessages();
    }
  }

  void _captureFrozenMessages() {
    if (_runtime == null) return;
    final frozenMessages = _runtime!.evaluate(r'''
      (function() {
        var msgs = globalThis._frozenMessages || [];
        globalThis._frozenMessages = [];
        return JSON.stringify(msgs);
      })()
    ''');
    _enqueueDeferredMessages(frozenMessages.stringResult);
  }

  void _restoreSourceMessageDispatcher() {
    if (_runtime == null) return;
    _runtime!.evaluate(r'''
      globalThis.sendMessage = globalThis._originalSendMessage || globalThis.sendMessage;
      delete globalThis._frozenMessages;
    ''');
  }

  String _runZlib(dynamic args) {
    try {
      final data = args is String
          ? json.decode(args) as Map<String, dynamic>
          : args as Map<String, dynamic>;
      final input = base64Decode(data['data']?.toString() ?? '');
      if (data['method'] == 'inflate') {
        return base64Encode(ZLibCodec().decode(input));
      }
      if (data['method'] == 'deflate') {
        return base64Encode(ZLibCodec().encode(input));
      }
    } catch (_) {
      // A malformed source input resolves to the host's empty zlib result.
    }
    return '';
  }

  /// 初始化阶段被冻结的 setTimeout：在 Dart 侧调度延迟回调。
  void _scheduleDeferredTimeout(dynamic payload) {
    try {
      final data = payload is String ? json.decode(payload) : payload;
      final id = data['id'];
      final ms = (data['ms'] as num?)?.toInt() ?? 0;
      Future<void>.delayed(Duration(milliseconds: ms), () async {
        // 引擎可能已被 dispose（runtime 释放），此时直接忽略延迟回调。
        if (_runtime == null) return;
        try {
          _runtime!.evaluate(
            'if(globalThis._callbacks && globalThis._callbacks["timeout_$id"]) { globalThis._callbacks["timeout_$id"](); delete globalThis._callbacks["timeout_$id"]; }',
          );
          _flushMicrotasks(maxIterations: 4);
          _captureFrozenMessages();
          await _drainDeferredMessages();
          _flushMicrotasks(maxIterations: 4);
          _captureFrozenMessages();
        } catch (_) {
          // dispose 竞态：runtime 已释放，忽略。
        }
      });
    } catch (_) {
      // 消息格式异常时忽略，等待脚本自身的其他初始化路径。
    }
  }

  /// 初始化阶段被冻结的 clearTimeout：直接删除 JS 侧回调，防止延迟触发。
  void _clearDeferredTimeout(dynamic id) {
    if (_runtime == null) return;
    _runtime!.evaluate(
      'if(globalThis._callbacks) delete globalThis._callbacks["timeout_${id ?? ''}"];',
    );
  }

  void _resolveDeferredMessage(String? id, String result) {
    if (id == null || _runtime == null) return;
    _runtime!.evaluate('''
      (function() {
        var deferred = globalThis._deferredResolvers[${json.encode(id)}];
        if (deferred) {
          delete globalThis._deferredResolvers[${json.encode(id)}];
          deferred.resolve(${json.encode(result)});
        }
      })()
    ''');
    _flushMicrotasks(maxIterations: 4);
    _captureFrozenMessages();
  }

  Future<List<MusicItem>> search(
    String keyword, {
    String? source,
    int page = 1,
    int limit = 20,
    String type = 'music',
  }) async {
    final platform = source ?? 'kw';
    final result = await _callRequestEvent({
      'action': 'search',
      'source': platform,
      'info': {'keyword': keyword, 'page': page, 'limit': limit, 'type': type},
    });
    if (result == null || result['list'] == null) return [];

    final List list = result['list'];
    if (type == 'songlist') {
      return list.map((item) {
        final Map<String, dynamic> mapItem = item is Map
            ? Map<String, dynamic>.from(item)
            : {};
        return MusicItem(
          id: mapItem['id']?.toString() ?? _uuid.v4(),
          name: mapItem['name']?.toString() ?? '未知歌单',
          singer:
              mapItem['author']?.toString() ??
              mapItem['creator']?.toString() ??
              '未知作者',
          album: mapItem['play_count']?.toString() ?? '',
          duration: Duration.zero,
          source: _currentSource?.id ?? 'custom',
          platform: platform,
          artwork: mapItem['img']?.toString() ?? '',
          isPlayable: false,
          meta: mapItem,
        );
      }).toList();
    }

    return list
        .map((item) => _parseMusicItem(item, platform: platform))
        .toList();
  }

  Future<List<MusicItem>> getSongListDetail(
    String id, {
    String source = 'kw',
    int page = 1,
  }) async {
    final result = await _callRequestEvent(
      buildSongListDetailParams(id, source, page),
    );
    if (result == null || result['list'] == null) return [];

    final List list = result['list'];
    // 歌单详情通常也是特定平台的
    return list
        .map(
          (item) => _parseMusicItem(
            item,
            platform: result['source']?.toString() ?? source,
          ),
        )
        .toList();
  }

  Duration _parseDuration(dynamic interval) {
    if (interval == null) return Duration.zero;
    final String s = interval.toString();
    if (s.contains(':')) {
      final parts = s.split(':');
      if (parts.length == 2) {
        final m = int.tryParse(parts[0]) ?? 0;
        final s_ = int.tryParse(parts[1]) ?? 0;
        return Duration(minutes: m, seconds: s_);
      }
    }
    return Duration(seconds: int.tryParse(s) ?? 0);
  }

  MusicItem _parseMusicItem(
    Map<String, dynamic> item, {
    String platform = 'kw',
  }) {
    final rawSongmid = item['songmid']?.toString().trim() ?? '';
    final rawId = item['id']?.toString().trim() ?? '';
    final id = rawSongmid.isNotEmpty
        ? rawSongmid
        : (rawId.isNotEmpty ? rawId : _uuid.v4());
    return MusicItem(
      id: id,
      name: item['name']?.toString() ?? '未知歌名',
      singer: item['singer']?.toString() ?? '未知歌手',
      album: item['album']?.toString() ?? '',
      duration: _parseDuration(item['interval']),
      source: _currentSource?.id ?? 'custom',
      platform: item['source']?.toString() ?? platform,
      artwork: item['img']?.toString() ?? '',
      songmid: rawSongmid.isNotEmpty ? rawSongmid : id,
      hash: item['hash']?.toString(),
      meta: item, // 保存完整的原始数据，供后续 getMusicUrl 使用
    );
  }

  Future<String?> getMusicUrl(
    MusicItem music, {
    String quality = '320k',
  }) async {
    final detailed = await getMusicUrlDetailed(music, quality: quality);
    return detailed?.url;
  }

  /// 返回 URL + 脚本声明的实际音质（若有），避免仅靠扩展名误判。
  Future<({String url, String? type})?> getMusicUrlDetailed(
    MusicItem music, {
    String quality = '320k',
  }) async {
    try {
      // Mobile UserApi receives the original song object; source is the music
      // platform (kw/tx/wy), not the custom source id.
      final resolvedQuality = quality.isEmpty ? '320k' : quality;
      final platform = _resolveScriptSource(music);
      final musicInfo = buildLxMobileMusicInfo(music, platform);

      final result = await _callRequestEvent({
        'action': 'musicUrl',
        'source': platform,
        'info': {'type': resolvedQuality, 'musicInfo': musicInfo},
      });
      if (result == null) {
        _emitDiagnostic('empty_result', {
          'platform': platform,
          'quality': resolvedQuality,
        });
        return null;
      }

      if (result is String) {
        final s = result.trim();
        if (s.startsWith('http')) return (url: s, type: null);
        _emitDiagnostic('invalid_result', {
          'platform': platform,
          'quality': resolvedQuality,
          'kind': 'string',
        });
        return null;
      }
      if (result is! Map) {
        _emitDiagnostic('invalid_result', {
          'platform': platform,
          'quality': resolvedQuality,
          'kind': result.runtimeType.toString(),
        });
        return null;
      }

      String? type =
          result['type']?.toString() ??
          result['quality']?.toString() ??
          result['br']?.toString();

      final direct = result['url'] ?? result['music_url'] ?? result['musicUrl'];
      if (direct != null) {
        final url = direct.toString().trim();
        if (url.startsWith('http')) return (url: url, type: type);
      }
      final data = result['data'];
      if (data is Map) {
        type ??= data['type']?.toString() ?? data['quality']?.toString();
        final nested = data['url'] ?? data['music_url'] ?? data['musicUrl'];
        if (nested != null) {
          final url = nested.toString().trim();
          if (url.startsWith('http')) return (url: url, type: type);
        }
      }
      final body = result['body'];
      if (body is Map) {
        type ??= body['type']?.toString() ?? body['quality']?.toString();
        final u = body['url']?.toString().trim();
        if (u != null && u.startsWith('http')) return (url: u, type: type);
      }

      _emitDiagnostic('invalid_result', {
        'platform': platform,
        'quality': resolvedQuality,
        'kind': 'map_without_url',
      });
      return null;
    } catch (e) {
      debugPrint(
        '[LX] getMusicUrlDetailed failed source=${music.source} id=${music.id}: $e',
      );
      _emitDiagnostic('request_error', {
        'platform': _resolveScriptSource(music),
        'quality': quality,
        'error': e.toString(),
      });
      return null;
    }
  }

  /// 脚本里的 source 是平台 id，不是自定义源的脚本 id。
  String _resolveScriptSource(MusicItem music) {
    const platforms = {'kw', 'tx', 'wy', 'kg', 'mg', 'local'};
    final p = music.platform.toLowerCase();
    if (platforms.contains(p)) return p;
    final meta = music.meta?['source']?.toString().toLowerCase();
    if (meta != null && platforms.contains(meta)) return meta;
    final s = music.source.toLowerCase();
    if (platforms.contains(s)) return s;
    return '';
  }

  Future<String?> getLyric(MusicItem music) async {
    try {
      final platform = _resolveScriptSource(music);
      final String songmid = music.songmid ?? music.id;
      final String hash = (music.hash == null || music.hash!.isEmpty)
          ? songmid
          : music.hash!;

      final Map<String, dynamic> musicInfo = {
        'songmid': songmid,
        'hash': hash,
        'name': music.name,
        'singer': music.singer,
        'album': music.album,
        'img': music.artwork,
        'source': platform,
      };

      if (music.meta != null) {
        musicInfo.addAll(music.meta!);
      }

      final result = await _callRequestEvent({
        'action': 'lyric',
        'source': platform,
        'info': {'musicInfo': musicInfo},
      });
      if (result == null) return null;
      if (result is String) return result;

      // 处理对象返回格式 { lyric: "...", tlyric: "..." }
      final lyric = result['lyric'] ?? result['lrc'];
      final tlyric = result['tlyric'];

      // 如果有翻译歌词，合并它们（LX Music 惯用做法）
      if (tlyric != null && tlyric.toString().isNotEmpty) {
        return '$lyric\n$tlyric';
      }

      return lyric?.toString();
    } catch (e) {
      return null;
    }
  }

  Future<SourceRequestResponse> _makeHttpRequest(
    String url,
    Map<String, dynamic> options, {
    bool isBinary = false,
    Map<String, dynamic>? queryParams,
    SourceRequestCancellation? cancellation,
  }) async {
    final method = (options['method'] as String?)?.toUpperCase() ?? 'GET';
    final headers = <String, dynamic>{};

    // 规范化 Headers 处理
    if (options['headers'] != null) {
      (options['headers'] as Map).forEach((k, v) {
        headers[k.toString()] = v.toString();
      });
    }

    bool hasHeader(String name) =>
        headers.keys.any((k) => k.toString().toLowerCase() == name);

    void setHeaderIfMissing(String name, String value) {
      if (!hasHeader(name.toLowerCase())) headers[name] = value;
    }

    // 对齐官方移动端 fetchData：默认声明 JSON 响应，但脚本显式设置优先。
    setHeaderIfMissing('Accept', 'application/json');

    // 确保 User-Agent 存在
    bool hasUA = hasHeader('user-agent');
    if (!hasUA) {
      headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36';
    }

    dynamic body = options['body'];
    if (options['_binaryBodyBase64'] != null) {
      body = base64Decode(options['_binaryBodyBase64'] as String);
      setHeaderIfMissing('Content-Type', 'application/octet-stream');
    } else if (options['_formDataBase64'] != null) {
      body = base64Decode(options['_formDataBase64'] as String);
      setHeaderIfMissing('Content-Type', 'multipart/form-data');
    } else if (options['form'] != null) {
      body = options['form'];
      setHeaderIfMissing('Content-Type', 'application/x-www-form-urlencoded');
      if (body is Map) {
        body = _encodeFormBody(Map<dynamic, dynamic>.from(body));
      }
    } else if (body != null && (body is Map || body is List)) {
      body = json.encode(body);
      setHeaderIfMissing('Content-Type', 'application/json');
    }

    if (options['formData'] != null) {
      final formData = _normalizeFormDataMap(options['formData']);
      if (formData != null) {
        body = FormData.fromMap(formData);
      }
    }

    final uri = _mergeRequestUri(url, queryParams);
    return _requestSandbox.request(uri, {
      ...options,
      'method': method,
      'headers': headers,
      'body': body,
    }, cancellation: cancellation);
  }

  String _encodeFormBody(Map<dynamic, dynamic> form) {
    final parts = <String>[];
    form.forEach((key, value) {
      if (value == null) return;
      final name = Uri.encodeQueryComponent(key.toString());
      if (value is Iterable && value is! String) {
        for (final item in value) {
          parts.add('$name=${Uri.encodeQueryComponent(item.toString())}');
        }
      } else {
        parts.add('$name=${Uri.encodeQueryComponent(value.toString())}');
      }
    });
    return parts.join('&');
  }

  Map<String, dynamic>? _normalizeFormDataMap(dynamic formData) {
    if (formData is! Map) return null;
    final rawPairs = formData['_data'];
    if (rawPairs is List) {
      final out = <String, dynamic>{};
      for (final pair in rawPairs) {
        if (pair is List && pair.isNotEmpty) {
          out[pair[0].toString()] = pair.length > 1 ? pair[1] : '';
        }
      }
      return out;
    }
    return Map<String, dynamic>.from(formData);
  }

  Uri _mergeRequestUri(String url, Map<String, dynamic>? queryParams) {
    final base = Uri.parse(url);
    if (queryParams == null || queryParams.isEmpty) return base;

    final merged = <String, List<String>>{};
    base.queryParametersAll.forEach((key, values) {
      merged[key] = List<String>.from(values);
    });
    queryParams.forEach((key, value) {
      final name = key.toString();
      if (value == null) {
        merged.remove(name);
        return;
      }
      if (value is Iterable && value is! String) {
        merged[name] = value.map((item) => item.toString()).toList();
      } else {
        merged[name] = [value.toString()];
      }
    });
    return base.replace(queryParameters: merged);
  }

  String _formatRequestError(Object error) {
    if (error is SourceRequestPolicyException) {
      return '${error.code}: ${error.message}';
    }
    return error.toString();
  }

  String _redactUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    final uri = Uri.tryParse(url);
    if (uri == null) return '(invalid-url)';
    return '${uri.scheme}://${uri.host}${uri.path}';
  }

  void dispose() {
    _invalidateSession('Source disposed');
    _eventController.close();
    _runtime?.dispose();
    _runtime = null;
    _initialized = false;
  }
}
