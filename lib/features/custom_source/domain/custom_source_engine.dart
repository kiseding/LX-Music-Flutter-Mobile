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
import '../../../core/network/source_request_policy.dart';
import '../../../core/network/source_pinned_transport.dart';
import '../domain/custom_source.dart';
import '../../player/domain/music_item.dart';

Map<String, dynamic> _decodeMap(String s) =>
    json.decode(s) as Map<String, dynamic>;
dynamic _decodeDynamic(String s) => json.decode(s);

/// 保证脚本可见的 types 列表含本次请求音质，避免空 types 触发低码率回退。
List<String> ensureMusicInfoTypes(Map<String, dynamic> meta, String type) {
  const official = ['hires', 'flac24bit', 'flac', '320k', '192k', '128k'];
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
    out.addAll([
      if (req.isNotEmpty) req,
      ...official.where((q) => q != req),
    ]);
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
  final Map<String, Map<String, String>> _cookieJar = {};
  Completer<void>? _initCompleter;
  LxSourceCapabilities _capabilities = LxSourceCapabilities.fromInitData(null);
  final List<Map<String, dynamic>> _deferredMessages = [];
  Future<void> Function(dynamic)? _handleLxRequest;

  CustomSourceEngine({
    SourceRequestPolicy? requestPolicy,
    SourceTransport? requestTransport,
  }) {
    _requestSandbox = SourceRequestSandbox(
      policy: requestPolicy ?? SourceRequestPolicy(),
      transport: requestTransport ?? SourcePinnedTransport().call,
      maximumRedirects: 10,
    );
  }

  /// 取消在途 HTTP/请求，防止 dispose/reload 后回调打到已销毁 runtime
  void _invalidateSession(String reason) {
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
    _cookieJar.clear();
    final init = _initCompleter;
    if (init != null && !init.isCompleted) {
      init.completeError(StateError(reason));
    }
    _initCompleter = null;
    _sourceReady = false;
    _capabilities = LxSourceCapabilities.fromInitData(null);
  }

  Stream<Map<String, dynamic>> get eventStream => _eventController.stream;

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

    // 保存原始的 sendMessage 函数，用于在加载脚本时缓冲消息，避免 iOS 平台通道死锁
    _runtime!
        .evaluate('globalThis._originalSendMessage = globalThis.sendMessage;');

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

      // 对齐官方移动版：注入 Web Crypto 兜底。混淆/打包脚本内嵌的
      // sha256/md5 等库在 QuickJS（无原生 Web Crypto）下会直接访问
      // crypto.getRandomValues，缺了会抛 "Cannot read properties of
      // undefined (reading 'crypto')" 导致整个源无法加载。
      if (typeof globalThis.crypto === 'undefined') {
        globalThis.crypto = {
          getRandomValues: function(arr) {
            if (!arr) return arr;
            for (var i = 0; i < arr.length; i++) {
              arr[i] = Math.floor(Math.random() * 256);
            }
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
      Future.delayed(Duration(milliseconds: ms), () {
        if (_runtime != null) {
          // 修复：id 是数字，必须拼成 'timeout_'+id 字符串 key 才能正确
          // 取到 _callbacks 里的回调。clearTimeout 已经把 callback 删了，
          // 所以这里再次 delete 是 no-op，安全。
          _runtime!.evaluate(
              'if(globalThis._callbacks["timeout_$id"]) { globalThis._callbacks["timeout_$id"](); delete globalThis._callbacks["timeout_$id"]; }');
          // 推动 microtask 队列（例如 setTimeout 回调里再 await lx.request）
          _flushMicrotasks(maxIterations: 4);
        }
      });
    });
    _runtime!.onMessage('clear_timeout', (dynamic id) {
      // 同步清掉 JS 端 callbacks（防止 timeout 触发时重复调用）
      if (_runtime != null) {
        _runtime!.evaluate(
            'if(globalThis._callbacks) delete globalThis._callbacks["timeout_$id"];');
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

      final String callbackId = data['callbackId'];
      final String url = data['url'];
      debugPrint(
          '[LX] lx_request callbackId=${callbackId.hashCode} url=${_redactUrl(url)}');
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
                  final dynamic decoded =
                      await compute<String, dynamic>(_decodeDynamic, bodyStr);
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
              diagnostic['bodyPrefix'] =
                  body.length <= 80 ? body : body.substring(0, 80);
            }
            _emitDiagnostic('http_error_response', diagnostic);
          }

          final Map<String, String> flatHeaders = {};
          response.headers.forEach((name, values) {
            flatHeaders[name.toLowerCase()] = values.join(', ');
          });
          _storeCookiesFromResponse(url, response.headers);

          final rawB64 = base64Encode(rawBytes);
          debugPrint(
              '[LX] lx_request HTTP done callbackId=$callbackId status=${response.statusCode} bytes=${rawBytes.length}');
          if (!response.isCancelled) {
            _executeJsCallback(
                callbackId,
                [
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
                ],
                url: url);
          }
        });
      } catch (e) {
        final message = _formatRequestError(e);
        debugPrint(
            '[LX] lx_request HTTP FAIL callbackId=$callbackId err=$message');
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
            '[LX] lx_response arrived reqId=$reqId hasError=${error != null} hasData=${result != null} pending=${_pendingRequests.keys.toList()}');

        if (reqId != null && _pendingRequests.containsKey(reqId)) {
          final completer = _pendingRequests.remove(reqId);
          if (error != null) {
            debugPrint(
                '[LX] lx_response completing reqId=$reqId with ERROR: $error');
            completer?.completeError(error);
          } else {
            debugPrint('[LX] lx_response completing reqId=$reqId with data');
            completer?.complete(result);
          }
        } else {
          debugPrint(
              '[LX] lx_response reqId=$reqId NOT in pending (stale or unknown)');
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
      final Map<String, dynamic> data =
          (args is String) ? json.decode(args) : args;
      final String method = data['method'];
      final dynamic input = data['input'];

      try {
        if (method == 'md5') {
          return md5.convert(utf8.encode(input.toString())).toString();
        }
        if (method == 'randomBytes') {
          final size =
              input is num ? input.toInt() : int.parse(input.toString());
          return base64Encode(secureRandomBytes(size));
        }
        if (method == 'aesEncrypt') {
          final dynamic inputData = data['input'];
          List<int> inputBytes;
          if (inputData is String) {
            // 如果是合法的 Base64 则解码，否则按 UTF8 编码
            try {
              inputBytes = (inputData.length % 4 == 0 &&
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
              keyText.padRight(16, '\x00').substring(0, 16));
          final iv = encrypt_lib.IV
              .fromUtf8(ivText.padRight(16, '\x00').substring(0, 16));

          final aesMode = mode.toLowerCase().contains('cbc')
              ? encrypt_lib.AESMode.cbc
              : encrypt_lib.AESMode.ecb;

          final encrypter =
              encrypt_lib.Encrypter(encrypt_lib.AES(key, mode: aesMode));
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
        final Map<String, dynamic> data =
            (args is String) ? json.decode(args) : args;
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
        function md5(string) {
          function md5_Cycle(x, k) {
            var a = x[0], b = x[1], c = x[2], d = x[3];
            a = ff(a, b, c, d, k[0], 7, -680876936);
            d = ff(d, a, b, c, k[1], 12, -389564586);
            c = ff(c, d, a, b, k[2], 17, 606105819);
            b = ff(b, c, d, a, k[3], 22, -1044525330);
            a = ff(a, b, c, d, k[4], 7, -176418897);
            d = ff(d, a, b, c, k[5], 12, 1200080426);
            c = ff(c, d, a, b, k[6], 17, -1473231341);
            b = ff(b, c, d, a, k[7], 22, -45705983);
            a = ff(a, b, c, d, k[8], 7, 1770035416);
            d = ff(d, a, b, c, k[9], 12, -1958414417);
            c = ff(c, d, a, b, k[10], 17, -42063);
            b = ff(b, c, d, a, k[11], 22, -1990404162);
            a = ff(a, b, c, d, k[12], 7, 1804603682);
            d = ff(d, a, b, c, k[13], 12, -40341101);
            c = ff(c, d, a, b, k[14], 17, -1502002290);
            b = ff(b, c, d, a, k[15], 22, 1236535329);
            a = gg(a, b, c, d, k[1], 5, -165796510);
            d = gg(d, a, b, c, k[6], 9, -1069501632);
            c = gg(c, d, a, b, k[11], 14, 643717713);
            b = gg(b, c, d, a, k[0], 20, -373897302);
            a = gg(a, b, c, d, k[5], 5, -701558691);
            d = gg(d, a, b, c, k[10], 9, 38016083);
            c = gg(c, d, a, b, k[15], 14, -660478335);
            b = gg(b, c, d, a, k[4], 20, -405537848);
            a = gg(a, b, c, d, k[9], 5, 568446438);
            d = gg(d, a, b, c, k[14], 9, -1019803690);
            c = gg(c, d, a, b, k[3], 14, -187363961);
            b = gg(b, c, d, a, k[8], 20, 1163531501);
            a = gg(a, b, c, d, k[13], 5, -1444681467);
            d = gg(d, a, b, c, k[2], 9, -51403784);
            c = gg(c, d, a, b, k[7], 14, 1735328473);
            b = gg(b, c, d, a, k[12], 20, -1926607734);
            a = hh(a, b, c, d, k[5], 4, -378558);
            d = hh(d, a, b, c, k[8], 11, -2022574463);
            c = hh(c, d, a, b, k[11], 16, 1839030562);
            b = hh(b, c, d, a, k[14], 23, -35309556);
            a = hh(a, b, c, d, k[1], 4, -1530992060);
            d = hh(d, a, b, c, k[4], 11, 1272893353);
            c = hh(c, d, a, b, k[7], 16, -155497632);
            b = hh(b, c, d, a, k[10], 23, -1094730640);
            a = hh(a, b, c, d, k[13], 4, 681279174);
            d = hh(d, a, b, c, k[0], 11, -358537222);
            c = hh(c, d, a, b, k[3], 16, -722521979);
            b = hh(b, c, d, a, k[6], 23, 76029189);
            a = hh(a, b, c, d, k[9], 4, -640364487);
            d = hh(d, a, b, c, k[12], 11, -421815835);
            c = hh(c, d, a, b, k[15], 16, 530742520);
            b = hh(b, c, d, a, k[2], 23, -995338651);
            a = ii(a, b, c, d, k[0], 6, -198630844);
            d = ii(d, a, b, c, k[7], 10, 1126891415);
            c = ii(c, d, a, b, k[14], 15, -1416354905);
            b = ii(b, c, d, a, k[5], 21, -57434055);
            a = ii(a, b, c, d, k[12], 6, 1700485571);
            d = ii(d, a, b, c, k[3], 10, -1894986606);
            c = ii(c, d, a, b, k[10], 15, -1051523);
            b = ii(b, c, d, a, k[1], 21, -2054922799);
            a = ii(a, b, c, d, k[8], 6, 1873313359);
            d = ii(d, a, b, c, k[15], 10, -30611744);
            c = ii(c, d, a, b, k[6], 15, -1560198380);
            b = ii(b, c, d, a, k[13], 21, 1309151649);
            a = ii(a, b, c, d, k[4], 6, -145523070);
            d = ii(d, a, b, c, k[11], 10, -1120210379);
            c = ii(c, d, a, b, k[2], 15, 718787280);
            b = ii(b, c, d, a, k[9], 21, -343485551);
            state[0] = a + state[0] | 0;
            state[1] = b + state[1] | 0;
            state[2] = c + state[2] | 0;
            state[3] = d + state[3] | 0;
          }
          function ff(a, b, c, d, x, s, t) { a = a + (b & c | ~b & d) + x + t | 0; return (a << s | a >>> 32 - s) + b | 0; }
          function gg(a, b, c, d, x, s, t) { a = a + (b & d | c & ~d) + x + t | 0; return (a << s | a >>> 32 - s) + b | 0; }
          function hh(a, b, c, d, x, s, t) { a = a + (b ^ c ^ d) + x + t | 0; return (a << s | a >>> 32 - s) + b | 0; }
          function ii(a, b, c, d, x, s, t) { a = a + (c ^ (b | ~d)) + x + t | 0; return (a << s | a >>> 32 - s) + b | 0; }
          var n = string.length, state = [1732584193, -271733879, -1732584194, 271733878], i;
          var words = [];
          for (i = 0; i < n; i++) words[i >> 2] |= string.charCodeAt(i) << (i % 4 << 3);
          words[n >> 2] |= 0x80 << (n % 4 << 3);
          words[(n + 8 >> 6 << 4) + 14] = n << 3;
          for (i = 0; i < words.length; i += 16) md5_Cycle(state, words.slice(i, i + 16));
          var hex = "";
          for (i = 0; i < 4; i++) {
            var val = state[i];
            for (var j = 0; j < 4; j++) {
              var b = (val >> (j * 8)) & 0xFF;
              hex += (b < 16 ? "0" : "") + b.toString(16);
            }
          }
          return hex;
        }
        globalThis._md5 = md5;
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
        env: 'desktop',
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

                // 与 LX Desktop / Node 约定一致：每次请求只回调一次。
                // length===1 → body
                // length===2 → (err, response)  —— 脚本写 (err, resp)=>{ if(err) reject; const {body}=resp }
                // length===3 → (err, response, body)
                try {
                  if (cb.length === 1) cb(body !== undefined ? body : (res ? res.body : null));
                  else if (cb.length === 2) cb(err, res);
                  else cb(err, res, body);
                }
                finally { globalThis._pendingRequests--; }
              };
              // 对齐官方移动版 fetchData：默认带 Accept: application/json
              //（脚本显式设置的头优先），部分 API 服务器校验该头。
              options.headers = options.headers || {};
              if (!options.headers.Accept && !options.headers.accept) {
                options.headers.Accept = 'application/json';
              }
              if (options.method && String(options.method).toUpperCase() === 'GET') {
                delete options.headers['Content-Type'];
                delete options.headers['content-type'];
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
          // 支持多 handler：旧脚本可能注册多个 request 处理器做优先级链。
          // _callRequestEvent 会按顺序迭代，取第一个返回非空结果的 handler。
          globalThis._requestHandlers = globalThis._requestHandlers || [];
          globalThis._requestHandlers.push(handler);
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
        // 对齐官方移动版：纯 JS 生成随机字节并返回 Uint8Array，避免同步
        // 走平台通道（iOS 上易触发通道死锁），也无需 await。
        var arr = new Uint8Array(size);
        for (var i = 0; i < size; i++) {
          arr[i] = Math.floor(Math.random() * 256);
        }
        return arr;
      };
      globalThis.Buffer = globalThis.lx.utils.buffer;
      globalThis._callbacks = {};
      globalThis._requestHandlers = [];
      globalThis._initComplete = false;
      globalThis._deferredResolvers = {};
    ''');
  }

  bool _validateCapabilities(dynamic data) {
    _capabilities = LxSourceCapabilities.fromInitData(data);
    if (data is! Map || data['sources'] is! Map) {
      _emitError('Source initialization did not declare supported sources.');
      return false;
    }
    if (_capabilities.isEmpty) {
      _emitError('Source initialization did not declare a supported action.');
      return false;
    }
    return true;
  }

  bool _supportsAction(String platform, String action, [String? quality]) {
    return !LxSourceCapabilities.requiresDeclaration(action) ||
        _capabilities.supports(platform, action, quality);
  }

  void _handleLxSend(Map<String, dynamic> data) {
    final String? event = data['event']?.toString();
    if (event == 'inited' && _validateCapabilities(data['data'])) {
      final completer = _initCompleter;
      if (completer != null && !completer.isCompleted) completer.complete();
    }
    _eventController
        .add({'type': 'event', 'event': event, 'data': data['data']});
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

  void _executeJsCallback(String callbackId, List<dynamic> args,
      {String? url}) {
    if (_runtime == null) return;
    final safeUrl = _redactUrl(url);
    debugPrint(
        '[LX] _executeJsCallback callbackId=${callbackId.hashCode} url=$safeUrl argc=${args.length}');
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

  /// 反复 evaluate 极简表达式以触发 QuickJS 内部的 microtask flush。
  /// 必须在异步回调（如 _executeJsCallback / onMessage）末尾调用，
  /// 否则 await 链无法推进、`sendMessage('lx_response', ...)` 等消息
  /// 永远不会发出，导致 _callRequestEvent 15 秒超时。
  void _flushMicrotasks({int maxIterations = 64}) {
    if (_runtime == null) return;
    for (int i = 0; i < maxIterations; i++) {
      try {
        // 检查 JS 端维护的 pending request 计数器。
        // 只要还有未完成的 lx.request，就继续推 noop 让 QuickJS
        // 跑 microtask。
        final checkResult = _runtime!.evaluate(
          '(globalThis._pendingRequests || 0)',
        );
        final pending = checkResult.rawResult;
        if (pending is int && pending <= 0) {
          // 没有 pending request 了，再多 evaluate 几次让 microtask 队列跑空
          // (例如 lx_response 的 sendMessage 也是 microtask 调度)
          for (int j = 0; j < 3; j++) {
            _runtime!.evaluate('void 0;');
          }
          break;
        }

        // 推一个 noop 表达式，让 QuickJS 进入事件循环
        _runtime!.evaluate('void 0;');
      } catch (_) {
        break;
      }
    }
  }

  Future<bool> loadSource(CustomSource source) async {
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
        final m =
            RegExp('@$key\\s+(.+)', caseSensitive: false).firstMatch(header);
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

      // 1. 先注入基础信息
      _runtime!.evaluate(
          'globalThis.lx.currentScriptInfo = ${json.encode(scriptInfo)};');

      // 2. 尝试注入完整的 rawScript (使用特殊变量绕过某些解析限制)
      final encodedScript = json.encode(source.script);
      final rawScriptResult = _runtime!.evaluate(
          'globalThis.lx.currentScriptInfo.rawScript = $encodedScript;');

      if (rawScriptResult.isError) {
        // rawScript injection failed (possibly too large)
      }

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
      while (
          !_initCompleter!.isCompleted && DateTime.now().isBefore(deadline)) {
        // 轮询 flush microtask，让 setTimeout 链上的 lx.send('inited') 跑掉
        _flushMicrotasks(maxIterations: 4);
        try {
          await _initCompleter!.future
              .timeout(const Duration(milliseconds: 500));
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
    final quality = params['info'] is Map
        ? (params['info'] as Map)['type']?.toString()
        : null;
    if (!_supportsAction(source, action.toString(), quality)) {
      _emitDiagnostic('capability_rejected', {
        'action': action,
        'platform': source,
        'quality': quality,
      });
      // 能力拒绝是正常回退路径：源未声明 lyric/pic/musicUrl 时直接返回 null，
      // MusicSourceService 会回退到内置源或其它自定义源。不冒充为错误事件，
      // 否则 UI 会刷出“Source does not support lyric for …”红字噪音。
      return null;
    }

    final String reqId =
        'req_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 4)}';
    debugPrint(
        '[LX] _callRequestEvent start reqId=$reqId action=${params['action']} source=${params['source']}');
    final paramsJson = json.encode(params);
    final varName =
        'temp_params_${reqId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}';

    // 使用变量注入防止大 JSON 字符串在 evaluate 时导致卡顿
    _runtime!.evaluate('globalThis.$varName = $paramsJson;');

    final completer = Completer<dynamic>();
    _pendingRequests[reqId] = completer;

    final script = '''
      (async function() {
        try {
          var params = globalThis.$varName;
          delete globalThis.$varName;
          var action = params.action;
          var reqId = ${json.encode(reqId)};
          console.log('[JS Debug] callRequestEvent start reqId=' + reqId + ' action=' + action + ' source=' + params.source);

          var handlers = globalThis._requestHandlers || [];
          if (handlers.length === 0) {
            console.error('[JS Debug] no handler registered for reqId=' + reqId);
            sendMessage('lx_response', JSON.stringify({ reqId: reqId, error: 'No request handler is registered.' }));
            return;
          }
          var result = null;
          var lastError = null;
          for (var i = 0; i < handlers.length; i++) {
            console.log('[JS Debug] invoking handler #' + i + ' for reqId=' + reqId);
            try {
              result = await handlers[i](params);
              lastError = null;
            } catch (e) {
              lastError = (e && e.message) ? e.message : String(e);
              console.error('[JS Debug] handler #' + i + ' threw: ' + lastError);
              result = null;
            }
            console.log('[JS Debug] handler #' + i + ' returned type=' + (result === null ? 'null' : typeof result) + ' for reqId=' + reqId);
            if (result) break;
          }
          if (result == null && lastError) {
            console.error('[JS Debug] all handlers failed reqId=' + reqId + ' err=' + lastError);
            sendMessage('lx_response', JSON.stringify({ reqId: reqId, error: lastError }));
          } else {
            console.log('[JS Debug] sending lx_response reqId=' + reqId + ' hasData=' + (result != null));
            sendMessage('lx_response', JSON.stringify({ reqId: reqId, data: result }));
          }
        } catch (e) {
          console.error('[JS Debug] Runtime error during _callRequestEvent: ' + (e && e.message ? e.message : e));
          sendMessage('lx_response', JSON.stringify({ reqId: '$reqId', error: e.message }));
        }
      })();
    ''';

    final evalResult = _runtime!.evaluate(script);
    if (evalResult.isError) {
      debugPrint(
          '[LX] _callRequestEvent JS eval FAILED reqId=$reqId: ${evalResult.stringResult}');
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
        '[LX] _callRequestEvent polling reqId=$reqId pending=${_pendingRequests.length} handlers set');
    while (!completer.isCompleted && DateTime.now().isBefore(deadline)) {
      _flushMicrotasks(maxIterations: 4);
      try {
        final result =
            await completer.future.timeout(const Duration(milliseconds: 500));
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
        '[LX] _callRequestEvent TIMEOUT reqId=$reqId action=${params['action']} — lx_response never arrived');
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
            'Source initialization used unsupported deferred channel: $channel.');
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
      Future<void>.delayed(Duration(milliseconds: ms), () {
        // 引擎可能已被 dispose（runtime 释放），此时直接忽略延迟回调。
        if (_runtime == null) return;
        try {
          _runtime!.evaluate(
              'if(globalThis._callbacks && globalThis._callbacks["timeout_$id"]) { globalThis._callbacks["timeout_$id"](); delete globalThis._callbacks["timeout_$id"]; }');
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
        'if(globalThis._callbacks) delete globalThis._callbacks["timeout_${id ?? ''}"];');
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

  Future<List<MusicItem>> search(String keyword,
      {String? source,
      int page = 1,
      int limit = 20,
      String type = 'music'}) async {
    final platform = source ?? 'kw';
    final result = await _callRequestEvent({
      'action': 'search',
      'source': platform,
      'info': {'keyword': keyword, 'page': page, 'limit': limit, 'type': type}
    });
    if (result == null || result['list'] == null) return [];

    final List list = result['list'];
    if (type == 'songlist') {
      return list.map((item) {
        final Map<String, dynamic> mapItem =
            item is Map ? Map<String, dynamic>.from(item) : {};
        return MusicItem(
          id: mapItem['id']?.toString() ?? _uuid.v4(),
          name: mapItem['name']?.toString() ?? '未知歌单',
          singer: mapItem['author']?.toString() ??
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

  Future<List<MusicItem>> getSongListDetail(String id, {int page = 1}) async {
    final result = await _callRequestEvent({
      'action': 'songListDetail',
      'info': {'id': id, 'page': page}
    });
    if (result == null || result['list'] == null) return [];

    final List list = result['list'];
    // 歌单详情通常也是特定平台的
    return list
        .map((item) => _parseMusicItem(item,
            platform: result['source']?.toString() ?? 'kw'))
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

  MusicItem _parseMusicItem(Map<String, dynamic> item,
      {String platform = 'kw'}) {
    return MusicItem(
      id: item['songmid']?.toString() ?? item['id']?.toString() ?? _uuid.v4(),
      name: item['name']?.toString() ?? '未知歌名',
      singer: item['singer']?.toString() ?? '未知歌手',
      album: item['album']?.toString() ?? '',
      duration: _parseDuration(item['interval']),
      source: _currentSource?.id ?? 'custom',
      platform: item['source']?.toString() ?? platform,
      artwork: item['img']?.toString() ?? '',
      songmid: item['songmid']?.toString(),
      hash: item['hash']?.toString(),
      meta: item, // 保存完整的原始数据，供后续 getMusicUrl 使用
    );
  }

  /// 仿桌面版 utils.ts 的 toOldMusicInfo：把 MusicItem 转成桌面版脚本
  /// 期望的旧格式 songInfo（包含 albumName / picUrl / types / _interval 等）。
  /// 桌面版脚本 (kg / tx / wy) 大多读 `songInfo.albumName` 和
  /// `songInfo.picUrl`，Flutter 版之前只输出 `album` / `img` 字段，
  /// 导致脚本拿不到正确值，getMusicUrl 返回 null。
  Map<String, dynamic> _toOldMusicInfo(MusicItem music,
      {String type = '320k'}) {
    final meta =
        Map<String, dynamic>.from(music.meta ?? const <String, dynamic>{});
    final String songmid = music.songmid ?? music.id;
    final String hash =
        (music.hash == null || music.hash!.isEmpty) ? songmid : music.hash!;
    final String interval = music.duration.inSeconds > 0
        ? '${(music.duration.inSeconds ~/ 60).toString().padLeft(2, '0')}:${(music.duration.inSeconds % 60).toString().padLeft(2, '0')}'
        : (meta['interval']?.toString() ?? '03:50');

    // 1) 先用 meta 填充脚本可能用到的扩展字段（qualitys / privilege / flac
    //    / strMediaMid / file / types 等）
    final Map<String, dynamic> info = <String, dynamic>{};
    for (final entry in meta.entries) {
      info[entry.key] = entry.value;
    }

    // 2) 覆盖最关键的标准字段，确保不会被 meta 里的脏数据替换
    info['songmid'] = songmid;
    info['hash'] = hash;
    info['name'] = music.name;
    info['singer'] = music.singer;
    info['source'] = _resolveScriptSource(music);
    info['interval'] = interval;
    info['_interval'] = music.duration.inSeconds;
    info['type'] = type;
    // 搜刮曲目常无 types：脚本 if (!types.includes(quality)) 会落到默认低码率。
    // 保证 types/qualitys 至少覆盖本次请求音质与官方降级链。
    info['types'] = ensureMusicInfoTypes(meta, type);
    info['qualitys'] = info['types'];
    info['privilege'] = meta['privilege'];

    // 兼容新旧两种字段名
    info['albumName'] = music.album.isNotEmpty
        ? music.album
        : (meta['albumName']?.toString() ?? meta['album']?.toString() ?? '');
    info['album'] = music.album.isNotEmpty
        ? music.album
        : (meta['album']?.toString() ?? '');
    info['albumId'] = meta['albumId']?.toString() ?? '';
    info['picUrl'] = music.artwork ??
        meta['img']?.toString() ??
        meta['picUrl']?.toString() ??
        '';
    info['img'] = music.artwork ?? meta['img']?.toString() ?? '';

    return info;
  }

  Future<String?> getMusicUrl(MusicItem music,
      {String quality = '320k'}) async {
    final detailed = await getMusicUrlDetailed(music, quality: quality);
    return detailed?.url;
  }

  /// 返回 URL + 脚本声明的实际音质（若有），避免仅靠扩展名误判。
  Future<({String url, String? type})?> getMusicUrlDetailed(MusicItem music,
      {String quality = '320k'}) async {
    try {
      // 使用仿桌面版 toOldMusicInfo 的转换，补齐脚本期望的 albumName / picUrl
      // 等字段名，并保留 meta 中的 qualitys / privilege 等扩展数据。
      // 脚本读 info.type 作为 quality；source 为平台 kw/tx/wy（不是脚本 id）。
      final resolvedQuality = quality.isEmpty ? '320k' : quality;
      final platform = _resolveScriptSource(music);
      final musicInfo = _toOldMusicInfo(
        music.copyWith(platform: platform),
        type: resolvedQuality,
      );

      final result = await _callRequestEvent({
        'action': 'musicUrl',
        'source': platform,
        'info': {
          'type': resolvedQuality,
          // 部分脚本只读 info.quality
          'quality': resolvedQuality,
          'musicInfo': musicInfo,
        }
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

      String? type = result['type']?.toString() ??
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
          '[LX] getMusicUrlDetailed failed source=${music.source} id=${music.id}: $e');
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
      final String hash =
          (music.hash == null || music.hash!.isEmpty) ? songmid : music.hash!;

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
        'info': {'musicInfo': musicInfo}
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
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
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
    _applyStoredCookies(uri, headers);
    return _requestSandbox.request(
      uri,
      {
        ...options,
        'method': method,
        'headers': headers,
        'body': body,
      },
      cancellation: cancellation,
    );
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

  void _applyStoredCookies(Uri uri, Map<String, dynamic> headers) {
    if (headers.keys.any((k) => k.toLowerCase() == 'cookie')) return;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return;
    final pairs = <String>[];
    _cookieJar.forEach((cookieHost, cookies) {
      if (host == cookieHost || host.endsWith('.$cookieHost')) {
        cookies.forEach((name, value) {
          pairs.add('$name=$value');
        });
      }
    });
    if (pairs.isNotEmpty) {
      headers['Cookie'] = pairs.join('; ');
    }
  }

  void _storeCookiesFromResponse(
    String url,
    Map<String, List<String>> headers,
  ) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    if (host == null || host.isEmpty) return;
    final setCookies = <String>[];
    headers.forEach((name, values) {
      if (name.toLowerCase() == 'set-cookie') {
        setCookies.addAll(values);
      }
    });
    if (setCookies.isEmpty) return;

    final jar = _cookieJar.putIfAbsent(host, () => <String, String>{});
    for (final raw in setCookies) {
      final first = raw.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq <= 0) continue;
      final name = first.substring(0, eq).trim();
      final value = first.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      if (value.isEmpty ||
          value.toLowerCase() == 'delete' ||
          value == '""' ||
          value == "''") {
        jar.remove(name);
      } else {
        jar[name] = value;
      }
    }
    if (jar.isEmpty) _cookieJar.remove(host);
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
