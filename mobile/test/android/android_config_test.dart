import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Source-level checks of the Android configuration. The compiled APKs are also
// inspected with aapt2 when verifying a change (see mobile/README.md).

const _src = 'android/app/src';

String _read(String path) => File('$_src/$path').readAsStringSync();

void main() {
  group('main manifest (all build types)', () {
    late String manifest;

    setUpAll(() => manifest = _read('main/AndroidManifest.xml'));

    test('declares the INTERNET permission', () {
      expect(manifest, contains('android.permission.INTERNET'));
    });

    test('disables backup and device-to-device transfer', () {
      expect(manifest, contains('android:allowBackup="false"'));
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
    });

    test('uses the network security config and never enables cleartext', () {
      expect(
        manifest,
        contains(
          'android:networkSecurityConfig="@xml/network_security_config"',
        ),
      );
      expect(manifest, isNot(contains('usesCleartextTraffic')));
    });
  });

  test('main (profile and release) network config denies cleartext', () {
    final config = _read('main/res/xml/network_security_config.xml');

    expect(config, contains('cleartextTrafficPermitted="false"'));
    expect(config, isNot(contains('cleartextTrafficPermitted="true"')));
  });

  test('debug network config allows cleartext for local development', () {
    final config = _read('debug/res/xml/network_security_config.xml');

    expect(config, contains('<base-config cleartextTrafficPermitted="true"'));
  });

  test('profile and release do not override the main network config', () {
    for (final buildType in ['profile', 'release']) {
      expect(
        File('$_src/$buildType/res/xml/network_security_config.xml')
            .existsSync(),
        isFalse,
        reason: buildType,
      );
    }
  });

  test('data extraction rules exclude cloud backup and device transfer', () {
    final rules = _read('main/res/xml/data_extraction_rules.xml');

    for (final section in ['cloud-backup', 'device-transfer']) {
      final body = RegExp(
        '<$section>(.*?)</$section>',
        dotAll: true,
      ).firstMatch(rules)?.group(1);
      expect(body, isNotNull, reason: section);
      for (final domain in ['root', 'file', 'database', 'sharedpref']) {
        expect(body, contains('domain="$domain"'), reason: '$section/$domain');
      }
    }
  });
}
