import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:charset/charset.dart';

String md5String(String input) {
  return crypto.md5.convert(utf8.encode(input)).toString();
}

String sha1String(String input) {
  return crypto.sha1.convert(utf8.encode(input)).toString();
}

String formatSeconds(int seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

int parseDuration(String? input) {
  if (input == null || input.isEmpty) return 0;
  final parts = input.split(':');
  if (parts.length == 2) {
    return int.tryParse(parts[0])! * 60 + int.tryParse(parts[1])!;
  }
  return int.tryParse(input) ?? 0;
}

String aes128EcbHex(String data, String keyStr) {
  final key = encrypt.Key.fromUtf8(keyStr);
  final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.ecb));
  final encrypted = encrypter.encrypt(data);
  return encrypted.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').toUpperCase();
}

String formatSingerName(List<dynamic> singers, {String nameKey = 'name', String join = '、'}) {
  if (singers.isEmpty) return '';
  return singers.map((s) => (s is Map ? s[nameKey] : s?.toString()) ?? '').join(join);
}

const _kwKeyBytes = [121, 101, 101, 108, 105, 111, 110];

String kwBuildParams(String id, bool isGetLyricx) {
  var params = 'user=12345,web,web,web&requester=localhost&req=1&rid=MUSIC_$id';
  if (isGetLyricx) params += '&lrcx=1';
  final buf = utf8.encode(params);
  final output = List<int>.filled(buf.length, 0);
  var i = 0;
  while (i < buf.length) {
    var j = 0;
    while (j < _kwKeyBytes.length && i < buf.length) {
      output[i] = _kwKeyBytes[j] ^ buf[i];
      i++;
      j++;
    }
  }
  return base64Encode(output);
}

String? kwDecodeResponse(List<int> data, bool isGetLyricx) {
  if (data.length < 10) return null;
  final header = String.fromCharCodes(data.sublist(0, 10));
  if (header != 'tp=content') return null;

  final separator = [13, 10, 13, 10];
  var sepIndex = -1;
  for (var i = 0; i < data.length - 3; i++) {
    if (data[i] == separator[0] && data[i + 1] == separator[1] &&
        data[i + 2] == separator[2] && data[i + 3] == separator[3]) {
      sepIndex = i;
      break;
    }
  }
  if (sepIndex == -1) return null;

  final compressedData = data.sublist(sepIndex + 4);
  List<int> inflated;
  try {
    inflated = gzip.decode(compressedData);
  } catch (_) {
    return null;
  }

  if (!isGetLyricx) {
    return gbk.decode(inflated);
  }

  final decoded = base64Decode(String.fromCharCodes(inflated));
  final output = List<int>.filled(decoded.length, 0);
  var i = 0;
  while (i < decoded.length) {
    var j = 0;
    while (j < _kwKeyBytes.length && i < decoded.length) {
      output[i] = _kwKeyBytes[j] ^ decoded[i];
      i++;
      j++;
    }
  }
  return gbk.decode(output);
}
