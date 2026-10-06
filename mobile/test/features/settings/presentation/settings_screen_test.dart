import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/app/app_info.dart';
import 'package:jarvis/features/settings/presentation/settings_screen.dart';

import '../../../support/fake_auth_api.dart';
import '../../../support/in_memory_token_store.dart';
import '../../../support/test_app.dart';

Future<(FakeAuthApi, InMemoryTokenStore)> _openSettings(
  WidgetTester tester, {
  FakeAuthApi? api,
}) async {
  final fake = api ?? FakeAuthApi();
  final store = InMemoryTokenStore(testSession());
  await pumpJarvis(tester, api: fake, store: store);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('home-settings')));
  await tester.pumpAndSettle();
  return (fake, store);
}

Future<void> _confirmSignOut(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('sign-out')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('confirm-sign-out')));
}

void main() {
  group('formatMemberSince', () {
    test('formats a calendar date without time zone conversion', () {
      // Local DateTime constructors: no conversion, same result in any time zone.
      expect(formatMemberSince(DateTime(2026, 10, 5)), '5 October 2026');
      expect(
        formatMemberSince(DateTime(2026, 1, 31, 23, 59)),
        '31 January 2026',
      );
      expect(formatMemberSince(DateTime(2027, 12, 1)), '1 December 2027');
    });
  });

  testWidgets('shows the account email and member-since date', (tester) async {
    await _openSettings(tester);

    expect(find.text(testUser.email), findsOneWidget);
    // Expected value derived the same way the screen does, so it holds in
    // whatever time zone the tests run.
    expect(
      find.text(formatMemberSince(testUser.createdAt.toLocal())),
      findsOneWidget,
    );
  });

  testWidgets('shows the app name, and the version only when known', (
    tester,
  ) async {
    await _openSettings(tester);

    expect(find.text(AppInfo.name), findsOneWidget);
    final version = AppInfo.version;
    expect(
      find.textContaining('Version'),
      version == null ? findsNothing : findsOneWidget,
    );
  });

  testWidgets('cancelling the confirmation does nothing', (tester) async {
    final (api, store) = await _openSettings(tester);

    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(api.calls, isNot(contains('logout')));
    expect(store.session, isNotNull);
    expect(find.byKey(const Key('settings-screen')), findsOneWidget);
  });

  testWidgets('confirming signs out and returns to login', (tester) async {
    final (api, store) = await _openSettings(tester);

    await _confirmSignOut(tester);
    await tester.pumpAndSettle();

    expect(api.calls.where((c) => c == 'logout'), hasLength(1));
    expect(store.session, isNull);
    expect(find.byKey(const Key('login-email')), findsOneWidget);
  });

  testWidgets('sign out cannot run twice while in progress', (tester) async {
    final pending = Completer<void>();
    final api = FakeAuthApi()..onLogout = () => pending.future;
    await _openSettings(tester, api: api);

    await _confirmSignOut(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('sign-out')),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.byKey(const Key('sign-out')), warnIfMissed: false);
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);

    pending.complete();
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c == 'logout'), hasLength(1));
    expect(find.byKey(const Key('login-email')), findsOneWidget);
  });

  testWidgets('a network failure during server logout still signs out', (
    tester,
  ) async {
    final api = FakeAuthApi()
      ..onLogout = () => throw networkError('/api/auth/logout');
    final (_, store) = await _openSettings(tester, api: api);

    await _confirmSignOut(tester);
    await tester.pumpAndSettle();

    expect(store.session, isNull);
    expect(find.byKey(const Key('login-email')), findsOneWidget);
  });

  testWidgets('a local clear failure shows the protected retry screen', (
    tester,
  ) async {
    final (_, store) = await _openSettings(tester);
    store.failClear = true;

    await _confirmSignOut(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sign-out-failed')), findsOneWidget);
    expect(find.byKey(const Key('settings-screen')), findsNothing);
    expect(store.session, isNotNull);
  });
}
