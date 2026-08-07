import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/io/bounded_input.dart';

void main() {
  test('bounded file reader rejects content larger than the limit', () async {
    final dir = await Directory.systemTemp.createTemp('bounded_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/input.json')
      ..writeAsBytesSync(List<int>.filled(9, 1));

    await expectLater(
      readFileBytesBounded(file, maximumBytes: 8),
      throwsA(isA<InputLimitException>()
          .having((error) => error.code, 'code', 'bytes')),
    );
  });

  test('JSON budget rejects excessive nesting before domain decode', () {
    Object value = 'leaf';
    for (var index = 0; index < 21; index++) {
      value = [value];
    }
    expect(
      () => validateJsonBudget(value, const JsonBudget(maximumDepth: 20)),
      throwsA(isA<InputLimitException>()),
    );
  });

  test('bounded file reader accepts content within the limit', () async {
    final dir = await Directory.systemTemp.createTemp('bounded_ok_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/input.json')
      ..writeAsBytesSync(List<int>.filled(8, 7));

    final bytes = await readFileBytesBounded(file, maximumBytes: 8);
    expect(bytes, List<int>.filled(8, 7));
  });

  test('JSON budget rejects oversized strings and collection counts', () {
    expect(
      () => validateJsonBudget(
        'x' * 5,
        const JsonBudget(maximumStringLength: 4),
      ),
      throwsA(isA<InputLimitException>()
          .having((error) => error.code, 'code', 'string')),
    );
    expect(
      () => validateJsonBudget(
        List<int>.filled(3, 1),
        const JsonBudget(maximumCollectionItems: 2),
      ),
      throwsA(isA<InputLimitException>()
          .having((error) => error.code, 'code', 'collection')),
    );
  });
}
