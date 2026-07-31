import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/qrc_decoder.dart';

void main() {
  test('decryptQrc known vector', () {
    const hex =
        '7b686ceb7cf010e042098af433d1b1495fbcb874e46a64ecba96808256148eae81b89f6a49539fe187fddad18cf16b109a000dfc631d0953';
    const expected =
        '[00:10.00]<0,180>AB<180,200>CD\n[00:15.00]<0,300>EF<300,200>GH\n';
    expect(decryptQrc(hex), expected);
  });

  test('decryptQrc rejects invalid length', () {
    expect(() => decryptQrc('abcd'), throwsFormatException);
  });
}
