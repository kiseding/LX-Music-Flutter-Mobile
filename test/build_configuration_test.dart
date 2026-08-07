import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('root toolchain requirements match the supported Flutter release', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(pubspec, contains("sdk: '>=3.12.0 <4.0.0'"));
    expect(pubspec, contains("flutter: '>=3.44.0'"));
  });

  test('iOS CI gates the build on analysis and deterministic tests', () {
    final workflow =
        File('.github/workflows/build-ios.yml').readAsStringSync();
    final analyze =
        workflow.indexOf('run: flutter analyze --no-fatal-infos');
    final test = workflow.indexOf('run: flutter test --exclude-tags live');
    final build = workflow.indexOf('run: flutter build ios');

    expect(analyze, greaterThanOrEqualTo(0));
    expect(test, greaterThan(analyze));
    expect(build, greaterThan(test));
  });

  test('iOS CI publishes only the Apple ID sideload IPA', () {
    final workflow =
        File('.github/workflows/build-ios.yml').readAsStringSync();

    expect(workflow, contains('LX-Music-Apple-ID-Sideload.ipa'));
    expect(workflow, contains('LX-Music-Apple-ID-Sideload-IPA'));
    expect(workflow, contains("rm -rf build/ios/ipa-sideload/Payload/Runner.app/PlugIns"));
    expect(workflow, isNot(contains('LX-Music-unsigned.ipa')));
    expect(workflow, isNot(contains('LX-Music-unsigned-IPA')));
  });

  test('Widget Extension inherits Flutter build name and number', () {
    final project =
        File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final widgetConfigurations = RegExp(
      r'AA000000000000000000000[DEF] /\* (?:Debug|Release|Profile) \*/ = \{'
      r'.*?CURRENT_PROJECT_VERSION = "\$\(FLUTTER_BUILD_NUMBER\)";'
      r'.*?MARKETING_VERSION = "\$\(FLUTTER_BUILD_NAME\)";',
      dotAll: true,
    ).allMatches(project);

    expect(widgetConfigurations, hasLength(3));
  });
}
