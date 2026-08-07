import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/custom_source/domain/source_script_validation.dart';

void main() {
  test('parses metadata from the leading block header', () {
    final header = parseSourceScriptHeader('''
/*!
 * @name Pasted source
 * @version 1.2
 */
globalThis.someObfuscatedName = 1;
''');

    expect(header?['name'], 'Pasted source');
    expect(header?['version'], '1.2');
    expect(isValidSourceScript('const x = 1;'), isFalse);
  });
}
