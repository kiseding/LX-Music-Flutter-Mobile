import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/source_request_policy.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local script over byte limit is rejected before persistence', () async {
    final service = CustomSourceService();
    SharedPreferences.setMockInitialValues({});
    await service.init();
    addTearDown(service.dispose);

    final oversized = List.filled(
      CustomSourceService.maximumScriptBytes + 1,
      'a',
    ).join();
    expect(await service.importLxMusicScript(oversized), isFalse);
    expect(service.sources, isEmpty);
  });

  test('remote import allows http and reaches transport', () async {
    var transports = 0;
    final sandbox = SourceRequestSandbox(
      policy: SourceRequestPolicy(
          resolve: (_) async => [InternetAddress('93.184.216.34')],
          maximumResponseBytes: 16),
      transport: (request, cancellation) async {
        transports++;
        return SourceTransportResponse(
            statusCode: 200,
            headers: const {},
            body: Stream.value(utf8.encode('x')));
      },
    );
    final service = CustomSourceService(importSandbox: sandbox);
    addTearDown(service.dispose);

    // http 已放行：应发起传输；脚本内容无效（非 LX 脚本）导致导入失败。
    expect(
        await service.importSourceFromUrl('http://source.example/a.js'),
        isFalse);
    expect(transports, 1);
  });

  test('remote import follows redirect and rejects blocked IPv6 target',
      () async {
    final requests = <Uri>[];
    final sandbox = SourceRequestSandbox(
      policy: SourceRequestPolicy(
          resolve: (host) async => host == 'public.example'
              ? [InternetAddress('93.184.216.34')]
              : [InternetAddress('::1')]),
      transport: (request, cancellation) async {
        requests.add(request.uri);
        return SourceTransportResponse(
          statusCode: 302,
          headers: const {
            'location': ['https://private.example/source.js']
          },
          body: const Stream.empty(),
        );
      },
    );
    final service = CustomSourceService(importSandbox: sandbox);
    addTearDown(service.dispose);

    // IPv6 回环（::1）仍被拦截：首个请求发出，重定向目标被拒。
    expect(
        await service
            .importSourceFromUrl('https://public.example/source.js'),
        isFalse);
    expect(requests, [Uri.parse('https://public.example/source.js')]);
  });

  test('remote response over script limit is rejected and released', () async {
    var closed = 0;
    final sandbox = SourceRequestSandbox(
      policy: SourceRequestPolicy(
        resolve: (_) async => [InternetAddress('93.184.216.34')],
        maximumResponseBytes: CustomSourceService.maximumScriptBytes,
      ),
      transport: (request, cancellation) async => SourceTransportResponse(
        statusCode: 200,
        headers: const {},
        body: Stream.value(List<int>.filled(
            CustomSourceService.maximumScriptBytes + 1, 65)),
        close: () => closed++,
      ),
    );
    final service = CustomSourceService(importSandbox: sandbox);
    addTearDown(service.dispose);

    expect(
        await service
            .importSourceFromUrl('https://public.example/source.js'),
        isFalse);
    expect(closed, 1);
  });

  test('validateScript accepts obfuscated scripts with header comment', () {
    final service = CustomSourceService();
    addTearDown(service.dispose);

    // 混淆脚本（如 lx / sixyin）：以 /*! ... @name */ 头开始，正文无关键字
    final obfuscated = '''
/*!
 * @name [独家音源]
 * @description 音源更新
 * @version 4
 * @author 洛雪科技
 */
;(function ꄲᐤ(ₒΟ,ᐤO,ᴑᣞ){function ⲟꓳ(Oᐤ){return Oᐤ}})(1);
''';
    expect(service.validateScript(obfuscated), isTrue);

    // obfuscator.io 风格（_0x 变量名）
    final obfuscatorStyle = '''
/*!
 * @name 六音音源
 * @description v1.2.1
 * @version v1.2.1
 */
(function(_0x5a3ad1,_0x22cd49){function _0x156754(){return _0x234f(0x1);}})(1,2);
''';
    expect(service.validateScript(obfuscatorStyle), isTrue);
  });

  test('validateScript rejects non-script content', () {
    final service = CustomSourceService();
    addTearDown(service.dispose);

    expect(service.validateScript('hello world'), isFalse);
    expect(service.validateScript('const a = 1;'), isFalse);
    expect(service.validateScript('// just a comment\nconst b = 2;'), isFalse);
    expect(service.validateScript('/* unterminated header'), isFalse);
  });
}
