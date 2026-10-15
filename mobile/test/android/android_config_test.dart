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

  test('the main manifest requests exactly INTERNET and RECORD_AUDIO', () {
    expect(_permissions(_read('main/AndroidManifest.xml')), {
      'android.permission.INTERNET',
      'android.permission.RECORD_AUDIO',
    });
  });

  test('debug and profile manifests add nothing beyond INTERNET', () {
    // Flutter's template repeats INTERNET there for development tooling.
    for (final buildType in ['debug', 'profile']) {
      expect(
        _permissions(_read('$buildType/AndroidManifest.xml')),
        everyElement('android.permission.INTERNET'),
        reason: buildType,
      );
    }
  });

  test('no background, foreground-service or assistant microphone use', () {
    for (final buildType in ['main', 'debug', 'profile']) {
      final manifest = _read('$buildType/AndroidManifest.xml');
      for (final forbidden in _forbiddenManifestTerms) {
        expect(
          manifest,
          isNot(contains(forbidden)),
          reason: '$buildType: $forbidden',
        );
      }
    }
  });

  test('the merged debug manifest adds only RECORD_AUDIO for audio', () {
    final merged = _mergedDebugManifest();
    if (merged == null) {
      markTestSkipped('No debug build output: run flutter build apk --debug.');
      return;
    }
    expect(_permissions(merged), {
      'android.permission.INTERNET',
      'android.permission.RECORD_AUDIO',
      // Added by androidx.core for dynamically registered receivers.
      'io.github.martiriverogarcia.jarvis.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
    });
    expect(_components(merged), {
      'activity io.github.martiriverogarcia.jarvis.MainActivity',
      'provider androidx.startup.InitializationProvider',
      'receiver androidx.profileinstaller.ProfileInstallReceiver',
    });
    for (final forbidden in _forbiddenManifestTerms) {
      expect(merged, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('audio packages are exactly record and audioplayers', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final dependencies = _section(pubspec, 'dependencies');
    final devDependencies = _section(pubspec, 'dev_dependencies');
    final audioRelated = RegExp(
      r'audio|record|speech|microphone|sound|voice|tts|stt',
    );

    expect(dependencies.where(audioRelated.hasMatch).toSet(), {
      'record',
      'audioplayers',
    });
    // Test-only: fakes of the two plugins' platform interfaces.
    expect(devDependencies.where(audioRelated.hasMatch).toSet(), {
      'record_platform_interface',
      'audioplayers_platform_interface',
    });
    expect(dependencies, contains('flutter')); // the parser found the section
  });

  test('no speech, cloud speech or AI SDK is a dependency', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final packages = {
      ..._section(pubspec, 'dependencies'),
      ..._section(pubspec, 'dev_dependencies'),
    };
    final forbidden = RegExp(
      r'speech_to_text|flutter_tts|text_to_speech|azure|microsoft|cognitive|'
      r'openai|whisper|vosk|deepgram|google_speech|google_cloud|firebase_ml|'
      r'foundry|assistant',
    );

    expect(packages.where(forbidden.hasMatch), isEmpty);
  });
}

const _forbiddenManifestTerms = [
  'FOREGROUND_SERVICE',
  'RECORD_BACKGROUND_AUDIO',
  'CAPTURE_AUDIO_OUTPUT',
  'CAPTURE_AUDIO_HOTWORD',
  'MODIFY_AUDIO_SETTINGS',
  'BIND_VOICE_INTERACTION',
  'android.service.voice',
  'VoiceInteractionService',
  'RecognitionService',
  'android.intent.action.ASSIST',
  'android.intent.action.VOICE_COMMAND',
  'android.speech',
];

Set<String> _permissions(String manifest) =>
    RegExp(r'<uses-permission[^>]*android:name="([^"]+)"')
        .allMatches(manifest)
        .map((m) => m.group(1)!)
        .toSet();

Set<String> _components(String manifest) => RegExp(
  r'<(activity|service|receiver|provider)\b[^>]*?android:name="([^"]+)"',
  dotAll: true,
).allMatches(manifest).map((m) => '${m.group(1)} ${m.group(2)}').toSet();

String? _mergedDebugManifest() {
  final root = Directory('build/app/intermediates/merged_manifest/debug');
  if (!root.existsSync()) {
    return null;
  }
  final manifests = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('AndroidManifest.xml'));
  return manifests.isEmpty ? null : manifests.first.readAsStringSync();
}

/// Package names declared directly under a top-level pubspec [section].
Set<String> _section(String pubspec, String section) {
  final match = RegExp(
    '^$section:\\n((?:(?:  .*)?\\n)*)',
    multiLine: true,
  ).firstMatch(pubspec);
  if (match == null) {
    return const {};
  }
  return RegExp(
    r'^  ([a-z0-9_]+):',
    multiLine: true,
  ).allMatches(match.group(1)!).map((m) => m.group(1)!).toSet();
}
