import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/custom_source/domain/source_runtime_polyfill.dart';
import 'package:pointycastle/export.dart' as pc;

void main() {
  group('source runtime 同步加密与 Dart 侧一致', () {
    test('AES-128-CBC (UTF8 key/iv padRight) 与 JS 同步 __aesEncrypt 一致', () {
      const data = 'hello world, aes test 123';
      const keyText = '0CoJUm6Qyw8W8jud';
      const ivText = '0123456789abcdef';

      final inputBytes = utf8.encode(data);
      final key = encrypt_lib.Key.fromUtf8(
          keyText.padRight(16, '\x00').substring(0, 16));
      final iv = encrypt_lib.IV
          .fromUtf8(ivText.padRight(16, '\x00').substring(0, 16));
      final encrypter = encrypt_lib.Encrypter(
          encrypt_lib.AES(key, mode: encrypt_lib.AESMode.cbc));

      final encrypted = encrypter.encryptBytes(inputBytes, iv: iv);

      // 与 node crypto / JS 同步实现一致的期望值
      expect(encrypted.base64, 'o7IIXlPagH9EpYEx0JpUKFZOIaAqVZ+LXisswjVVO9M=');
    });

    test('AES-128-ECB NoPadding (16 字节块，对齐官方 AES/ECB/NoPadding)', () {
      // 官方 preload 的 aes-128-ecb 走 AES/ECB/NoPadding（不填充），
      // 明文必须是 16 的倍数。JS 同步 __aesEncrypt 已按此实现。
      const data = '1234567890123456';
      const keyText = '0CoJUm6Qyw8W8jud';

      final inputBytes = utf8.encode(data);
      final keyBytes = utf8.encode(keyText.padRight(16, '\x00').substring(0, 16));
      final cipher = pc.ECBBlockCipher(pc.AESEngine())
        ..init(true, pc.KeyParameter(Uint8List.fromList(keyBytes)));
      final out = Uint8List(inputBytes.length);
      var offset = 0;
      while (offset < inputBytes.length) {
        offset += cipher.processBlock(
          Uint8List.fromList(inputBytes.sublist(offset, offset + 16)),
          0,
          out,
          offset,
        );
      }

      // node crypto AES-128-ECB NoPadding 验证过的期望值（与 JS 同步实现一致）
      expect(base64Encode(out), 'Vdxc0F/sQmVdAgDUEWYUWA==');
    });

    test('RSA_NO_PADDING (128 字节模幂) 与 JS 同步 __rsaEncrypt 一致', () {
      const pubKeyPem = '''
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDGEFkdlay3/V7XNK/AQ0v1pAd5
lsQfLHDA7eIyYNeWsMWsjAL2oTry6Le4xjMUYJDQuD6RapfXvmt4k3lEdo+jrKB4
mv/R1T48DE2LxzPYHUMND7ylm00gKzGFs5HUAq/oVgFbqiKrO1D8AfAperUHFxoj
qx5umN9MR4eB/8GXgwIDAQAB
-----END PUBLIC KEY-----
''';

      final inputBytes = List<int>.filled(128, 0x11);

      final parser = encrypt_lib.RSAKeyParser();
      final key = parser.parse(pubKeyPem) as pc.RSAPublicKey;
      final engine = pc.RSAEngine()
        ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(key));
      final encrypted = engine.process(Uint8List.fromList(inputBytes));

      // 与 pycryptodome / jsbn 同步实现一致的期望值
      expect(
        base64Encode(encrypted),
        'xBaMU9kyhG8UbXlr/XKJdUtkPwrGwBFzGDvVcZSDJH3gDu3SIjVT+a0oO6R+G8ectnml5OzMfVPpUYd2C8OCtAZsOTgNAGanUyVRHLWVSDp/MROlMYW/LjcQHCrTJECA7jc94flBJlB64pYGdHaEUiNDfeH6ybsDFj98WJ4Rujg=',
      );
    });

    test('polyfill 包含同步 AES/RSA 实现', () {
      final js = SourceRuntimePolyfill.js();
      expect(js, contains('__aesCore'));
      expect(js, contains('__aesEncrypt'));
      expect(js, contains('__rsaEncrypt'));
      expect(js, contains('jsbn'));
    });
  });
}
