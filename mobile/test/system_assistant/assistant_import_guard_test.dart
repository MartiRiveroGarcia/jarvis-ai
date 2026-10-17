import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The assistant can be shown over the lock screen, so the private parts of
/// the normal app must not be reachable from its entrypoint at all. This walks
/// the transitive import graph that the compiler follows from that entrypoint.

const _entrypoint = 'lib/assistant_main.dart';

/// Libraries that must never be part of the assistant entrypoint.
const _forbiddenFiles = {
  'lib/main.dart',
  'lib/app/app.dart',
  'lib/app/router.dart',
  'lib/features/assistant/presentation/home_screen.dart',
  'lib/features/assistant/presentation/developer_text_assistant_screen.dart',
  'lib/features/assistant/application/text_assistant_controller.dart',
  'lib/features/assistant/application/text_assistant_state.dart',
  'lib/features/assistant/data/assistant_api.dart',
  'lib/features/auth/presentation/login_screen.dart',
  'lib/features/auth/presentation/register_screen.dart',
  'lib/features/auth/presentation/splash_screen.dart',
};

/// Whole directories that must never be part of the assistant entrypoint.
const _forbiddenDirectories = {'lib/features/settings/'};

/// Packages that must never be part of the assistant entrypoint.
const _forbiddenPackages = {'go_router'};

final _directive = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// Every library reachable from [entry], as `lib/...` paths, plus every
/// external package it uses.
({Set<String> files, Set<String> packages}) _reachable(String entry) {
  final files = <String>{};
  final packages = <String>{};
  final pending = [entry];
  while (pending.isNotEmpty) {
    final file = pending.removeLast();
    if (!files.add(file)) {
      continue;
    }
    final source = File(file).readAsStringSync();
    for (final match in _directive.allMatches(source)) {
      final uri = Uri.parse(match.group(1)!);
      if (uri.scheme == 'dart') {
        continue;
      }
      if (uri.scheme == 'package') {
        final [package, ...rest] = uri.pathSegments;
        if (package == 'jarvis') {
          pending.add('lib/${rest.join('/')}');
        } else {
          packages.add(package);
        }
        continue;
      }
      pending.add(Uri(path: file).resolveUri(uri).path);
    }
  }
  return (files: files, packages: packages);
}

void main() {
  final graph = _reachable(_entrypoint);

  test('the walk sees the real graph, not just the entrypoint', () {
    // Sanity: shared code the assistant is meant to reuse is reached.
    expect(graph.files, contains('lib/system_assistant/assistant_app.dart'));
    expect(
      graph.files,
      contains('lib/features/auth/application/auth_controller.dart'),
    );
    expect(graph.files, contains('lib/core/providers.dart'));
    expect(graph.packages, contains('flutter_riverpod'));
    expect(graph.files.length, greaterThan(10));
  });

  test('main.dart keeps the assistant entrypoint in the compiled program', () {
    // Flutter compiles from lib/main.dart only; the export is what includes
    // the assistant library. The dependency only points this way.
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains("export 'assistant_main.dart' show assistantMain;"),
    );
    expect(_reachable('lib/main.dart').files, contains(_entrypoint));
    expect(graph.files, isNot(contains('lib/main.dart')));
  });

  test('a debug build contains the assistant entrypoint', () {
    final kernel = File(
      'build/app/intermediates/flutter/debug/flutter_assets/kernel_blob.bin',
    );
    if (!kernel.existsSync()) {
      markTestSkipped('No debug build output: run flutter build apk --debug.');
      return;
    }
    final bytes = String.fromCharCodes(kernel.readAsBytesSync());
    expect(bytes, contains('package:jarvis/assistant_main.dart'));
    expect(
      bytes,
      contains('package:jarvis/system_assistant/assistant_app.dart'),
    );
    expect(bytes, contains('assistantMain'));
  });

  test('the walk would catch a forbidden import', () {
    // The normal entrypoint reaches the router, so the walk detects it.
    final normal = _reachable('lib/main.dart');
    expect(normal.files, contains('lib/app/router.dart'));
    expect(normal.packages, contains('go_router'));
  });

  test('no private normal-app library is reachable from the assistant', () {
    expect(graph.files.intersection(_forbiddenFiles), isEmpty);
    for (final directory in _forbiddenDirectories) {
      expect(
        graph.files.where((file) => file.startsWith(directory)),
        isEmpty,
        reason: directory,
      );
    }
  });

  test('no navigation package is reachable from the assistant', () {
    expect(graph.packages.intersection(_forbiddenPackages), isEmpty);
  });

  test('assistantMain is marked as a native entrypoint', () {
    // The VM drops unreferenced top-level functions unless they carry this
    // pragma; Android starts the assistant through it by name.
    final source = File(_entrypoint).readAsStringSync();
    expect(
      RegExp(r"@pragma\('vm:entry-point'\)\s*void assistantMain\(\)")
          .hasMatch(source),
      isTrue,
    );
  });
}
