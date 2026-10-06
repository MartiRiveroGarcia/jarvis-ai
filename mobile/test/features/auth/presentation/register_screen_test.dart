import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/api/api_exception.dart';

import '../../../support/fake_auth_api.dart';
import '../../../support/in_memory_token_store.dart';
import '../../../support/test_app.dart';

Future<FakeAuthApi> _openRegister(
  WidgetTester tester, [
  FakeAuthApi? api,
]) async {
  final fake = api ?? FakeAuthApi();
  await pumpJarvis(tester, api: fake, store: InMemoryTokenStore());
  await tester.pumpAndSettle();
  await tester.tap(find.text('Create an account'));
  await tester.pumpAndSettle();
  return fake;
}

Future<void> _fill(
  WidgetTester tester, {
  String password = 'correct horse battery',
  String? confirm,
}) async {
  await tester.enterText(field('register-email'), 'marti@example.com');
  await tester.enterText(field('register-password'), password);
  await tester.enterText(
    field('register-confirm-password'),
    confirm ?? password,
  );
}

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(field('register-submit'));
  await tester.tap(field('register-submit'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the 15–128 character hint', (tester) async {
    await _openRegister(tester);

    expect(find.textContaining('15–128 characters'), findsOneWidget);
  });

  testWidgets('14 characters is rejected locally', (tester) async {
    final api = await _openRegister(tester);
    await _fill(tester, password: 'p' * 14);

    await _submit(tester);

    expect(find.text('Use 15–128 characters'), findsOneWidget);
    expect(api.calls, isEmpty);
  });

  testWidgets('129 characters is rejected locally', (tester) async {
    final api = await _openRegister(tester);
    await _fill(tester, password: 'p' * 129);

    await _submit(tester);

    expect(api.calls, isEmpty);
  });

  testWidgets('15 characters registers and signs in', (tester) async {
    final api = await _openRegister(tester);
    await _fill(tester, password: 'p' * 15);

    await _submit(tester);

    expect(api.calls, ['register', 'login']);
    expect(find.byKey(const Key('assistant-home')), findsOneWidget);
  });

  testWidgets('confirm-password mismatch is rejected locally', (tester) async {
    final api = await _openRegister(tester);
    await _fill(tester, confirm: 'something else entirely');

    await _submit(tester);

    expect(find.text("Passwords don't match"), findsOneWidget);
    expect(api.calls, isEmpty);
  });

  testWidgets('duplicate email shows a clear error', (tester) async {
    final api = FakeAuthApi()
      ..onRegister = () => throw const ConflictException(
        method: 'POST',
        path: '/api/auth/register',
        message: 'Email is already registered',
      );
    await _openRegister(tester, api);
    await _fill(tester);

    await _submit(tester);

    expect(
      find.text('An account with this email already exists. Try logging in.'),
      findsOneWidget,
    );
  });

  testWidgets('network failure on register does not claim failure', (
    tester,
  ) async {
    final api = FakeAuthApi()
      ..onRegister = () => throw networkError('/api/auth/register');
    await _openRegister(tester, api);
    await _fill(tester);

    await _submit(tester);

    expect(
      find.text(
        "Couldn't reach the server. If your account was created, try logging in.",
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'registered but auto-login failed -> login with email prefilled',
    (tester) async {
      final api = FakeAuthApi()
        ..onLogin = () => throw networkError('/api/auth/login');
      await _openRegister(tester, api);
      await _fill(tester);

      await _submit(tester);

      expect(find.byKey(const Key('auth-info-banner')), findsOneWidget);
      expect(find.textContaining('Your account was created'), findsOneWidget);
      final email = tester.widget<TextField>(
        find.descendant(
          of: field('login-email'),
          matching: find.byType(TextField),
        ),
      );
      expect(email.controller!.text, 'marti@example.com');
      final password = tester.widget<TextField>(
        find.descendant(
          of: field('login-password'),
          matching: find.byType(TextField),
        ),
      );
      expect(password.controller!.text, isEmpty);
    },
  );
}
