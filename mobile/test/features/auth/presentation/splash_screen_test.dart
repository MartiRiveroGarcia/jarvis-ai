import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/auth/application/auth_controller.dart';

import '../../../support/fake_auth_api.dart';
import '../../../support/in_memory_token_store.dart';
import '../../../support/test_app.dart';

void main() {
  testWidgets('restore failure offers Retry, which can succeed', (
    tester,
  ) async {
    final api = FakeAuthApi()..onMe = () => throw networkError('/api/auth/me');
    final store = InMemoryTokenStore(testSession());
    await pumpJarvis(tester, api: api, store: store);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('restore-failed')), findsOneWidget);
    expect(find.text("Can't reach Jarvis right now."), findsOneWidget);
    expect(store.session, isNotNull);

    api.onMe = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('assistant-home')), findsOneWidget);
  });

  testWidgets('restore failure offers "Sign out of this device"', (
    tester,
  ) async {
    final api = FakeAuthApi()..onMe = () => throw networkError('/api/auth/me');
    final store = InMemoryTokenStore(testSession());
    await pumpJarvis(tester, api: api, store: store);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign out of this device'));
    await tester.pumpAndSettle();

    expect(store.session, isNull);
    expect(find.byKey(const Key('login-email')), findsOneWidget);
  });

  testWidgets('sign-out failure blocks the app until Retry succeeds', (
    tester,
  ) async {
    final store = InMemoryTokenStore(testSession());
    final container = await pumpJarvis(
      tester,
      api: FakeAuthApi(),
      store: store,
    );
    await tester.pumpAndSettle();

    store.failClear = true;
    await container.read(authControllerProvider.notifier).logout();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sign-out-failed')), findsOneWidget);
    expect(find.byKey(const Key('assistant-home')), findsNothing);
    expect(find.byKey(const Key('login-email')), findsNothing);

    store.failClear = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(store.session, isNull);
    expect(find.byKey(const Key('login-email')), findsOneWidget);
  });
}
