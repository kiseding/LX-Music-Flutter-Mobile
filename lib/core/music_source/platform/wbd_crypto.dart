import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';

class WbdCrypto {
  static const String aesMode = 'aes-128-ecb';
  static final Uint8List aesKey = Uint8List.fromList([
    112, 87, 39, 61, 199, 250, 41, 191, 57, 68, 45, 114, 221, 94, 140, 228
  ]);
  static const String appId = 'y67sprxhhpws';

  static String decodeData(String base64Result) {
    final data = base64.decode(Uri.decodeComponent(base64Result));
    final key = Key(aesKey);
    final encrypter = Encrypter(AES(key, mode: AESMode.ecb));
    final decrypted = encrypter.decrypt(Encrypted(data));
    return decrypted;
  }

  static String createSign(String data, int time) {
    final str = '$appId$data$time';
    return md5.convert(utf8.encode(str)).toString().toUpperCase();
  }

  static String buildParam(Map<String, dynamic> jsonData) {
    final data = utf8.encode(jsonEncode(jsonData));
    final time = DateTime.now().millisecondsSinceEpoch;

    final key = Key(aesKey);
    final encrypter = Encrypter(AES(key, mode: AESMode.ecb));
    final encrypted = encrypter.encryptBytes(data);
    final encodeData = encrypted.base64;
    final sign = createSign(encodeData, time);

    return 'data=${Uri.encodeComponent(encodeData)}&time=$time&appId=$appId&sign=$sign';
  }
}
