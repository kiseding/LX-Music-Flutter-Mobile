// Tencent QRC lyric decoder.
//
// Ported from the MIT-licensed qrc-decoder package
// (https://github.com/apoint123/qrc-decoder), which itself is a TypeScript
// port of SuJiKiNen/LyricDecoder. The algorithm is a non-standard DES-like
// block cipher used only for QQ Music QRC lyrics, followed by zlib inflate.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const List<int> _key1 = [33, 64, 35, 41, 40, 42, 36, 37];
const List<int> _key2 = [49, 50, 51, 90, 88, 67, 33, 64];
const List<int> _key3 = [33, 64, 35, 41, 40, 78, 72, 76];

const List<List<int>> _sBoxes = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
];

const List<int> _pBox = [
    16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26,
    5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9,
    19, 13, 30, 6, 22, 11, 4, 25,
];

const List<int> _eBoxTable = [
    32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9,
    8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
    16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25,
    24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
];

const List<int> _keyRoundShift = [
    1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2,
    2, 2, 2, 1,
];

const List<int> _keyPermC = [
    56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33,
    25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2,
    59, 51, 43, 35,
];

const List<int> _keyPermD = [
    62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37,
    29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4,
    27, 19, 11, 3,
];

const List<int> _keyCompression = [
    13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9,
    22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1,
    40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47,
    43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
];

const List<int> _ipRule = [
    34, 42, 50, 58, 2, 10, 18, 26, 36, 44, 52, 60,
    4, 12, 20, 28, 38, 46, 54, 62, 6, 14, 22, 30,
    40, 48, 56, 64, 8, 16, 24, 32, 33, 41, 49, 57,
    1, 9, 17, 25, 35, 43, 51, 59, 3, 11, 19, 27,
    37, 45, 53, 61, 5, 13, 21, 29, 39, 47, 55, 63,
    7, 15, 23, 31,
];

const List<int> _invIpRule = [
    37, 5, 45, 13, 53, 21, 61, 29, 38, 6, 46, 14,
    54, 22, 62, 30, 39, 7, 47, 15, 55, 23, 63, 31,
    40, 8, 48, 16, 56, 24, 64, 32, 33, 1, 41, 9,
    49, 17, 57, 25, 34, 2, 42, 10, 50, 18, 58, 26,
    35, 3, 43, 11, 51, 19, 59, 27, 36, 4, 44, 12,
    52, 20, 60, 28,
];

final Uint32List _ipLeftTable = _buildIpTables(_ipRule).$1;
final Uint32List _ipRightTable = _buildIpTables(_ipRule).$2;
final Uint32List _invIpLeftTable = _buildIpTables(_invIpRule).$1;
final Uint32List _invIpRightTable = _buildIpTables(_invIpRule).$2;
final Int32List _spTable = _buildSpTable();
final Int32List _eboxHighTable = _buildEboxTables().$1;
final Int32List _eboxLowTable = _buildEboxTables().$2;

final List<int> _decryptSchedule0 = _keySchedule(_key3, decrypt: true);
final List<int> _decryptSchedule1 = _keySchedule(_key2, decrypt: false);
final List<int> _decryptSchedule2 = _keySchedule(_key1, decrypt: true);

/// Decrypts hex-encoded Tencent QRC lyric data and returns the plaintext.
String decryptQrc(String hex) {
  final encrypted = _hexToBytes(hex);
  if (encrypted.isEmpty || encrypted.length % 8 != 0) {
    throw FormatException('QRC data length must be a multiple of 8');
  }
  final decrypted = Uint8List(encrypted.length);
  for (var i = 0; i < encrypted.length; i += 8) {
    _desCrypt(
      encrypted,
      i,
      decrypted,
      i,
      _decryptSchedule0,
      _decryptSchedule1,
      _decryptSchedule2,
    );
  }
  final inflated = _inflate(decrypted);
  var start = 0;
  if (inflated.length >= 3 &&
      inflated[0] == 0xEF &&
      inflated[1] == 0xBB &&
      inflated[2] == 0xBF) {
    start = 3;
  }
  return utf8.decode(inflated.sublist(start));
}

Uint8List _hexToBytes(String hex) {
  final normalized = hex.trim();
  if (normalized.isEmpty) return Uint8List(0);
  if (normalized.length % 2 != 0) {
    throw FormatException('QRC hex string must have even length');
  }
  final bytes = Uint8List(normalized.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

Uint8List _inflate(List<int> data) {
  try {
    return Uint8List.fromList(zlib.decode(data));
  } catch (_) {
    // The decrypted stream may carry zero-byte block padding; retry after
    // trimming it and fall back to raw deflate for robustness.
  }
  var end = data.length;
  while (end > 0 && data[end - 1] == 0) {
    end--;
  }
  final trimmed = Uint8List.fromList(data.sublist(0, end));
  try {
    return Uint8List.fromList(zlib.decode(trimmed));
  } catch (_) {
    return Uint8List.fromList(ZLibCodec(raw: true).decode(trimmed));
  }
}

List<int> _keySchedule(List<int> key, {required bool decrypt}) {
  final schedule = List<int>.filled(32, 0);
  var c = _permuteFromKeyBytes(key, _keyPermC) << 4;
  var d = _permuteFromKeyBytes(key, _keyPermD) << 4;
  for (var i = 0; i < 16; i++) {
    final shift = _keyRoundShift[i];
    c = _rotateLeft28Bit(c, shift);
    d = _rotateLeft28Bit(d, shift);
    final toGen = decrypt ? 15 - i : i;
    var subkey48 = 0;
    for (var k = 0; k < _keyCompression.length; k++) {
      final pos = _keyCompression[k];
      final bit = pos < 28
          ? (c >> (31 - pos)) & 1
          : (d >> (31 - (pos - 27))) & 1;
      if (bit == 1) subkey48 |= 1 << (47 - k);
    }
    final b5 = (subkey48 >> 40) & 0xFF;
    final b4 = (subkey48 >> 32) & 0xFF;
    final b3 = (subkey48 >> 24) & 0xFF;
    final high24 = (b5 << 16) | (b4 << 8) | b3;
    final b2 = (subkey48 >> 16) & 0xFF;
    final b1 = (subkey48 >> 8) & 0xFF;
    final b0 = subkey48 & 0xFF;
    final low24 = (b2 << 16) | (b1 << 8) | b0;
    schedule[toGen * 2] = high24;
    schedule[toGen * 2 + 1] = low24;
  }
  return schedule;
}

int _permuteFromKeyBytes(List<int> key, List<int> table) {
  var output = 0;
  var currentBitMask = 1 << (table.length - 1);
  for (final pos in table) {
    final wordIndex = pos >> 5;
    final bitInWord = pos & 31;
    final byteInWord = bitInWord >> 3;
    final bitInByte = bitInWord & 7;
    if (((key[wordIndex * 4 + 3 - byteInWord] >> (7 - bitInByte)) & 1) != 0) {
      output |= currentBitMask;
    }
    currentBitMask >>= 1;
  }
  return output;
}

int _rotateLeft28Bit(int value, int amount) {
  const mask = 0xFFFFFFF0;
  final val = value & mask;
  return ((val << amount) | (val >> (28 - amount))) & mask;
}

BigInt _applyPermutation(BigInt input, List<int> rule) {
  var output = BigInt.zero;
  for (var i = 0; i < 64; i++) {
    final srcBit1Based = rule[i];
    if (((input >> (64 - srcBit1Based)) & BigInt.one) == BigInt.one) {
      output |= BigInt.one << (63 - i);
    }
  }
  return output;
}

(Uint32List, Uint32List) _buildIpTables(List<int> rule) {
  final left = Uint32List(2048);
  final right = Uint32List(2048);
  for (var bytePos = 0; bytePos < 8; bytePos++) {
    for (var byteVal = 0; byteVal < 256; byteVal++) {
      final permuted = _applyPermutation(
        BigInt.from(byteVal) << (56 - bytePos * 8),
        rule,
      );
      final idx = (bytePos << 8) | byteVal;
      left[idx] = (permuted >> 32).toInt() & 0xFFFFFFFF;
      right[idx] = (permuted & BigInt.from(0xFFFFFFFF)).toInt();
    }
  }
  return (left, right);
}

int _calculateSboxIndex(int a) {
  return (a & 32) | ((a & 31) >> 1) | ((a & 1) << 4);
}

int _applyQqPboxPermutation(int input) {
  var output = 0;
  for (var i = 0; i < 32; i++) {
    final sourceBit1Based = _pBox[i];
    final destBitMask = 1 << (31 - i);
    if ((input & (1 << (32 - sourceBit1Based))) != 0) {
      output |= destBitMask;
    }
  }
  return output;
}

Int32List _buildSpTable() {
  final table = Int32List(512);
  for (var sBoxIdx = 0; sBoxIdx < 8; sBoxIdx++) {
    for (var sBoxInput = 0; sBoxInput < 64; sBoxInput++) {
      final sBoxIndex = _calculateSboxIndex(sBoxInput);
      final prePBoxVal = _sBoxes[sBoxIdx][sBoxIndex] << (28 - sBoxIdx * 4);
      table[(sBoxIdx << 6) | sBoxInput] =
          _applyQqPboxPermutation(prePBoxVal);
    }
  }
  return table;
}

(Int32List, Int32List) _buildEboxTables() {
  final high = Int32List(1024);
  final low = Int32List(1024);
  for (var chunkIdx = 0; chunkIdx < 4; chunkIdx++) {
    final shiftIn32 = (3 - chunkIdx) * 8;
    for (var byteVal = 0; byteVal < 256; byteVal++) {
      var high24 = 0;
      var low24 = 0;
      final input = byteVal << shiftIn32;
      for (var i = 0; i < 24; i++) {
        final shift = (32 - _eBoxTable[i]) & 31;
        if (((input >>> shift) & 1) != 0) high24 |= 1 << (23 - i);
      }
      for (var i = 24; i < 48; i++) {
        final shift = (32 - _eBoxTable[i]) & 31;
        if (((input >>> shift) & 1) != 0) low24 |= 1 << (47 - i);
      }
      final tableIdx = (chunkIdx << 8) | byteVal;
      high[tableIdx] = high24;
      low[tableIdx] = low24;
    }
  }
  return (high, low);
}

int _fFunction(int state, int keyHigh24, int keyLow24) {
  final b0 = (state >>> 24) & 255;
  final b1 = (state >>> 16) & 255;
  final b2 = (state >>> 8) & 255;
  final b3 = state & 255;
  final eboxHigh24 = _eboxHighTable[b0] |
      _eboxHighTable[256 | b1] |
      _eboxHighTable[512 | b2] |
      _eboxHighTable[768 | b3];
  final eboxLow24 = _eboxLowTable[b0] |
      _eboxLowTable[256 | b1] |
      _eboxLowTable[512 | b2] |
      _eboxLowTable[768 | b3];
  final xorHigh24 = eboxHigh24 ^ keyHigh24;
  final xorLow24 = eboxLow24 ^ keyLow24;
  return _spTable[(xorHigh24 >>> 18) & 63] |
      _spTable[64 | ((xorHigh24 >>> 12) & 63)] |
      _spTable[128 | ((xorHigh24 >>> 6) & 63)] |
      _spTable[192 | (xorHigh24 & 63)] |
      _spTable[256 | ((xorLow24 >>> 18) & 63)] |
      _spTable[320 | ((xorLow24 >>> 12) & 63)] |
      _spTable[384 | ((xorLow24 >>> 6) & 63)] |
      _spTable[448 | (xorLow24 & 63)];
}

void _desCrypt(
  List<int> input,
  int inputOffset,
  List<int> output,
  int outputOffset,
  List<int> schedule0,
  List<int> schedule1,
  List<int> schedule2,
) {
  var left = 0;
  var right = 0;
  for (var i = 0; i < 8; i++) {
    final idx = (i << 8) | input[inputOffset + i];
    left |= _ipLeftTable[idx];
    right |= _ipRightTable[idx];
  }
  for (var i = 0; i < 15; i++) {
    final temp = right;
    right = (left ^ _fFunction(right, schedule0[i * 2], schedule0[i * 2 + 1])) &
        0xFFFFFFFF;
    left = temp;
  }
  left = (left ^ _fFunction(right, schedule0[30], schedule0[31])) & 0xFFFFFFFF;
  for (var i = 0; i < 15; i++) {
    final temp = right;
    right = (left ^ _fFunction(right, schedule1[i * 2], schedule1[i * 2 + 1])) &
        0xFFFFFFFF;
    left = temp;
  }
  left = (left ^ _fFunction(right, schedule1[30], schedule1[31])) & 0xFFFFFFFF;
  for (var i = 0; i < 15; i++) {
    final temp = right;
    right = (left ^ _fFunction(right, schedule2[i * 2], schedule2[i * 2 + 1])) &
        0xFFFFFFFF;
    left = temp;
  }
  left = (left ^ _fFunction(right, schedule2[30], schedule2[31])) & 0xFFFFFFFF;
  var outLeft = 0;
  var outRight = 0;
  for (var i = 0; i < 4; i++) {
    final idxL = (i << 8) | ((left >>> (24 - i * 8)) & 255);
    outLeft |= _invIpLeftTable[idxL];
    outRight |= _invIpRightTable[idxL];
    final idxR = ((i + 4) << 8) | ((right >>> (24 - i * 8)) & 255);
    outLeft |= _invIpLeftTable[idxR];
    outRight |= _invIpRightTable[idxR];
  }
  output[outputOffset] = (outLeft >>> 24) & 255;
  output[outputOffset + 1] = (outLeft >>> 16) & 255;
  output[outputOffset + 2] = (outLeft >>> 8) & 255;
  output[outputOffset + 3] = outLeft & 255;
  output[outputOffset + 4] = (outRight >>> 24) & 255;
  output[outputOffset + 5] = (outRight >>> 16) & 255;
  output[outputOffset + 6] = (outRight >>> 8) & 255;
  output[outputOffset + 7] = outRight & 255;
}
