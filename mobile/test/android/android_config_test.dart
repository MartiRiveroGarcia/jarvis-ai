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
      'activity io.github.martiriverogarcia.jarvis.AssistantActivity',
      'provider androidx.startup.InitializationProvider',
      'receiver androidx.profileinstaller.ProfileInstallReceiver',
    });
    for (final forbidden in _forbiddenManifestTerms) {
      expect(merged, isNot(contains(forbidden)), reason: forbidden);
    }
    // No library adds another assistant handler.
    expect(_assistHandlers(_activities(merged)), {
      'io.github.martiriverogarcia.jarvis.AssistantActivity',
    });
  });

  group('assistant activity (main manifest)', () {
    late Map<String, _Activity> activities;

    setUpAll(() => activities = _activities(_read('main/AndroidManifest.xml')));

    test('the parser sees both activities', () {
      expect(activities.keys, {'.MainActivity', '.AssistantActivity'});
    });

    test('AssistantActivity is the only ACTION_ASSIST handler', () {
      expect(_assistHandlers(activities), {'.AssistantActivity'});
      expect(_describe(activities['.AssistantActivity']!.filters), [
        'android.intent.action.ASSIST | android.intent.category.DEFAULT',
      ]);
    });

    test('MainActivity stays the private launcher entry only', () {
      final main = activities['.MainActivity']!;
      expect(_describe(main.filters), [
        'android.intent.action.MAIN | android.intent.category.LAUNCHER',
      ]);
      expect(main.attributes.keys, isNot(contains('showWhenLocked')));
    });

    test('AssistantActivity runs in its own task, out of Recents', () {
      final assistant = activities['.AssistantActivity']!.attributes;
      expect(assistant['exported'], 'true'); // the system starts it
      expect(assistant['excludeFromRecents'], 'true');
      expect(assistant['launchMode'], 'singleTask');
      expect(
        assistant['taskAffinity'],
        'io.github.martiriverogarcia.jarvis.assistant',
      );
      expect(
        assistant['taskAffinity'],
        isNot(activities['.MainActivity']!.attributes['taskAffinity']),
      );
      expect(assistant.keys, isNot(contains('showWhenLocked')));
      expect(assistant.keys, isNot(contains('noHistory')));
    });

    test('only AssistantActivity uses the translucent assistant theme', () {
      expect(
        activities['.AssistantActivity']!.attributes['theme'],
        '@style/AssistantTheme',
      );
      expect(
        activities['.MainActivity']!.attributes['theme'],
        '@style/LaunchTheme',
      );
      // The opaque NormalTheme switch stays on MainActivity only.
      expect(
        activities['.MainActivity']!.metaData,
        contains('io.flutter.embedding.android.NormalTheme'),
      );
      expect(activities['.AssistantActivity']!.metaData, isEmpty);
    });

    test(
      'AssistantTheme is translucent and transparent; app themes are not',
      () {
        final styles = _styles(_read('main/res/values/styles.xml'));
        expect(styles['AssistantTheme'], {
          'android:windowIsTranslucent': 'true',
          'android:windowBackground': '@android:color/transparent',
          'android:backgroundDimEnabled': 'false',
        });
        for (final variant in ['values', 'values-night']) {
          final app = _styles(_read('main/res/$variant/styles.xml'));
          for (final theme in ['LaunchTheme', 'NormalTheme']) {
            expect(
              app[theme]!.keys,
              isNot(contains('android:windowIsTranslucent')),
              reason: '$variant $theme',
            );
            expect(
              app[theme]!['android:windowBackground'],
              isNot('@android:color/transparent'),
            );
          }
          if (variant == 'values-night') {
            expect(app.keys, isNot(contains('AssistantTheme')));
          }
        }
      },
    );

    test('no other manifest declares an assistant handler', () {
      for (final buildType in ['debug', 'profile']) {
        final manifest = _read('$buildType/AndroidManifest.xml');
        expect(manifest, isNot(contains('android.intent.action.ASSIST')));
      }
    });
  });

  group('AssistantActivity source', () {
    const kotlin = 'main/kotlin/io/github/martiriverogarcia/jarvis';
    late String assistant;

    setUpAll(
      () => assistant = _withoutComments(_read('$kotlin/AssistantActivity.kt')),
    );

    test('reads nothing from the Intent except its action', () {
      final intentReads = RegExp(
        r'extras\b|Extras?\(|Extra\(|getData\b|dataString|\.data\b|'
        r'clipData|ClipData|getBundle|Bundle\(|Parcelable|Serializable',
      );
      expect(intentReads.allMatches(assistant).map((m) => m[0]), isEmpty);
      expect(assistant, contains('intent?.action == Intent.ACTION_ASSIST'));
    });

    test('every Intent-reading FlutterActivity hook is overridden', () {
      final embedding = _flutterActivitySource();
      if (embedding == null) {
        markTestSkipped('Flutter embedding source not found (FLUTTER_ROOT).');
        return;
      }
      final hooks = _methodsReadingIntent(embedding);
      expect(hooks, contains('getDartEntrypointFunctionName')); // sanity
      for (final hook in hooks) {
        expect(
          assistant,
          contains('override fun $hook('),
          reason: '$hook reads the Intent in FlutterActivity',
        );
      }
      // The fixed values never fall back to the Intent-reading defaults.
      expect(assistant, isNot(matches(RegExp(r'super\.(get|should)'))));
    });

    test('the Flutter entrypoint is the assistant library, fixed', () {
      expect(assistant, contains('DART_ENTRYPOINT = "assistantMain"'));
      expect(
        assistant,
        contains('DART_LIBRARY = "package:jarvis/assistant_main.dart"'),
      );
      expect(
        File('lib/assistant_main.dart').readAsStringSync(),
        contains('void assistantMain()'),
      );
      expect(assistant, contains('shouldHandleDeeplinking(): Boolean = false'));
      expect(assistant, contains('getCachedEngineId(): String? = null'));
      expect(
        assistant,
        contains('getDartEntrypointArgs(): List<String>? = null'),
      );
      expect(
        assistant,
        contains('shouldRestoreAndSaveState(): Boolean = false'),
      );
      expect(
        assistant,
        contains(
          'getBackgroundMode(): BackgroundMode = BackgroundMode.transparent',
        ),
      );
    });

    test('a session needs ACTION_ASSIST and the assistant role', () {
      expect(
        assistant,
        contains(
          'intent?.action == Intent.ACTION_ASSIST && assistantRoleHeld()',
        ),
      );
      expect(assistant, contains('isRoleHeld(RoleManager.ROLE_ASSISTANT)'));
      expect(assistant, isNot(contains('createRequestRoleIntent')));
      // Show-when-locked is only enabled for a valid invocation.
      expect(
        RegExp(r'if \(valid && [^)]*\) \{\s*setShowWhenLocked\(true\)')
            .hasMatch(assistant),
        isTrue,
      );
      expect('setShowWhenLocked(true)'.allMatches(assistant), hasLength(1));
    });

    test('every session ends through one path', () {
      final endSession = RegExp(
        r'private fun endSession\(\) \{(.*?)\n    \}',
        dotAll: true,
      ).firstMatch(assistant)![1]!;
      // Idempotent: the guard comes first, then the session is marked as
      // ending, then it ends; later calls (e.g. onStop after Close) do nothing.
      expect(
        RegExp(
          r'^\s*if \(sessionEnding\) \{\s*return\s*\}\s*'
          r'sessionEnding = true\s*if \(Build[^\n]*\{\s*'
          r'setShowWhenLocked\(false\)\s*\}\s*finishAndRemoveTask\(\)\s*$',
        ).hasMatch(endSession),
        isTrue,
        reason: endSession,
      );
      expect('sessionEnding = true'.allMatches(assistant), hasLength(1));
      // Never reset: the declaration is its only `= false`.
      expect('sessionEnding = false'.allMatches(assistant), hasLength(1));
      expect(assistant, contains('private var sessionEnding = false'));
      expect(endSession, contains('setShowWhenLocked(false)'));
      expect(endSession, contains('finishAndRemoveTask()'));
      expect('finishAndRemoveTask()'.allMatches(assistant), hasLength(1));
      expect(assistant, isNot(contains('finish()')));
      expect(
        RegExp(
          r'override fun popSystemNavigator\(\): Boolean \{\s*endSession\(\)',
        ).hasMatch(assistant),
        isTrue,
      );
      expect(
        RegExp(
          r'if \(!isChangingConfigurations\) \{\s*(//[^\n]*\s*)*endSession\(\)',
        ).hasMatch(_read('$kotlin/AssistantActivity.kt')),
        isTrue,
      );
    });

    test('MainActivity is unchanged and never shown over the lock screen', () {
      final main = _withoutComments(_read('$kotlin/MainActivity.kt'));
      expect(main.trim(), endsWith('class MainActivity : FlutterActivity()'));
      expect(main, isNot(contains('ShowWhenLocked')));
    });
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
  'android.intent.action.VOICE_COMMAND',
  'android.speech',
  'BIND_ACCESSIBILITY_SERVICE',
  'android.accessibilityservice',
  // Show-when-locked is set at runtime by AssistantActivity only.
  'showWhenLocked',
  'turnScreenOn',
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

typedef _Filter = ({Set<String> actions, Set<String> categories});

typedef _Activity = ({
  Map<String, String> attributes,
  List<_Filter> filters,
  Set<String> metaData,
});

/// Every `<activity>` of [manifest], by `android:name`, with its attributes and
/// intent filters.
Map<String, _Activity> _activities(String manifest) {
  final result = <String, _Activity>{};
  final blocks = RegExp(
    r'<activity\b([^>]*?)(?:/>|>(.*?)</activity>)',
    dotAll: true,
  );
  for (final block in blocks.allMatches(manifest)) {
    final attributes = {
      for (final m in RegExp(r'android:(\w+)="([^"]*)"').allMatches(block[1]!))
        m[1]!: m[2]!,
    };
    final filters = [
      for (final f in RegExp(
        r'<intent-filter\b[^>]*>(.*?)</intent-filter>',
        dotAll: true,
      ).allMatches(block[2] ?? ''))
        (
          actions: _names('action', f[1]!),
          categories: _names('category', f[1]!),
        ),
    ];
    result[attributes['name']!] = (
      attributes: attributes,
      filters: filters,
      metaData: _names('meta-data', block[2] ?? ''),
    );
  }
  return result;
}

Set<String> _names(String tag, String xml) =>
    RegExp('<$tag\\b[^>]*android:name="([^"]+)"')
        .allMatches(xml)
        .map((m) => m[1]!)
        .toSet();

/// Each filter as "actions | categories", sorted, for value comparison.
List<String> _describe(List<_Filter> filters) => [
  for (final f in filters)
    '${(f.actions.toList()..sort()).join(',')} | '
        '${(f.categories.toList()..sort()).join(',')}',
];

/// Names of the activities that handle ACTION_ASSIST.
Set<String> _assistHandlers(Map<String, _Activity> activities) => {
  for (final MapEntry(:key, :value) in activities.entries)
    if (value.filters.any(
      (f) => f.actions.contains('android.intent.action.ASSIST'),
    ))
      key,
};

/// [source] without `//` and `/* */` comments, so prose cannot hide or fake code.
String _withoutComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// The installed embedding's FlutterActivity.java, or null if not found.
String? _flutterActivitySource() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) {
    return null;
  }
  final file = File(
    '$root/engine/src/flutter/shell/platform/android/io/flutter/embedding/'
    'android/FlutterActivity.java',
  );
  return file.existsSync() ? file.readAsStringSync() : null;
}

/// Public or protected FlutterActivity methods whose body calls getIntent().
Set<String> _methodsReadingIntent(String java) {
  final methods = <String>{};
  final header = RegExp(
    r'\n  (?:public|protected) [^\n(]*?\b(\w+)\([^)]*\)[^{;]*\{',
  );
  final headers = header.allMatches(java).toList();
  for (var i = 0; i < headers.length; i++) {
    final end = i + 1 < headers.length ? headers[i + 1].start : java.length;
    if (java.substring(headers[i].end, end).contains('getIntent()')) {
      methods.add(headers[i][1]!);
    }
  }
  return methods;
}

/// Each `<style>` of a styles.xml, by name, with its items.
Map<String, Map<String, String>> _styles(String xml) => {
  for (final style in RegExp(
    r'<style\b[^>]*name="([^"]+)"[^>]*>(.*?)</style>',
    dotAll: true,
  ).allMatches(xml))
    style[1]!: {
      for (final item in RegExp(
        r'<item\b[^>]*name="([^"]+)"[^>]*>([^<]*)</item>',
      ).allMatches(style[2]!))
        item[1]!: item[2]!.trim(),
    },
};
