import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/app/app.dart';
import 'package:jarvis/core/providers.dart';
import 'package:jarvis/features/auth/application/auth_controller.dart';

import 'fake_auth_api.dart';
import 'in_memory_token_store.dart';

/// Pumps the real app with a fake AuthApi and an in-memory token store.
Future<ProviderContainer> pumpJarvis(
  WidgetTester tester, {
  required FakeAuthApi api,
  required InMemoryTokenStore store,
  DateTime? now,
}) async {
  final container = ProviderContainer.test(
    retry: (_, _) => null,
    overrides: [
      authApiProvider.overrideWithValue(api),
      tokenStoreProvider.overrideWithValue(store),
      clockProvider.overrideWithValue(() => now ?? DateTime.utc(2026, 10, 5)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const JarvisApp()),
  );
  return container;
}

/// Finds a [TextField] by the key of its [TextFormField].
Finder field(String key) => find.byKey(Key(key));
