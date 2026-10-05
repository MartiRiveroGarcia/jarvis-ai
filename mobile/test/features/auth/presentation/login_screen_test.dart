import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/api/api_exception.dart';
import 'package:jarvis/features/auth/domain/login_result.dart';

import '../../../support/fake_auth_api.dart';
import '../../../support/in_memory_token_store.dart';
import '../../../support/test_app.dart';

Future<FakeAuthApi> _openLogin(WidgetTester tester, [FakeAuthApi? api]) async {
  final fake = api ?? FakeAuthApi();
  await pumpJarvis(tester, api: fake, store: InMemoryTokenStore());
  await tester.pumpAndSettle();
  return fake;
}

Future<void> _fill(WidgetTester tester) async {
  await tester.enterText(field('login-email'), 'marti@example.com');
  await tester.enterText(field('login-password'), 'correct horse battery');
}

TextField _passwordField(WidgetTester tester) => tester.widget<TextField>(
  find.descendant(
    of: field('login-password'),
    matching: find.byType(TextField),
  ),
);

void main() {
  testWidgets('empty fields show validation errors and call nothing', (
    tester,
  ) async {
    final api = await _openLogin(tester);

    await tester.tap(field('login-submit'));
    await tester.pump();

    expect(find.text('Enter your email'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
    expect(api.calls, isEmpty);
  });

  testWidgets('show/hide toggles password visibility', (tester) async {
    await _openLogin(tester);
    expect(_passwordField(tester).obscureText, isTrue);

    await tester.tap(field('login-toggle-password'));
    await tester.pump();
    expect(_passwordField(tester).obscureText, isFalse);

    await tester.tap(field('login-toggle-password'));
    await tester.pump();
    expect(_passwordField(tester).obscureText, isTrue);
  });

  testWidgets('loading disables duplicate submission', (tester) async {
    final pending = Completer<LoginResult>();
    final api = FakeAuthApi()..onLogin = () => pending.future;
    await _openLogin(tester, api);
    await _fill(tester);

    await tester.tap(field('login-submit'));
    await tester.pump();
    await tester.tap(field('login-submit'));
    await tester.pump();

    expect(api.calls.where((c) => c == 'login'), hasLength(1));
    final button = tester.widget<FilledButton>(field('login-submit'));
    expect(button.onPressed, isNull);

    pending.complete(LoginResult(user: testUser, session: testSession()));
    await tester.pumpAndSettle();
  });

  for (final entry in <String, (ApiException, String)>{
    '401': (
      const UnauthorizedException(
        method: 'POST',
        path: '/api/auth/login',
        message: 'Invalid email or password',
      ),
      'Incorrect email or password.',
    ),
    '403': (
      const ForbiddenException(
        method: 'POST',
        path: '/api/auth/login',
        message: 'Account is disabled',
      ),
      'This account is disabled.',
    ),
    'network': (
      networkError('/api/auth/login'),
      "Couldn't reach Jarvis. Check your connection and try again.",
    ),
  }.entries) {
    testWidgets('${entry.key} shows "${entry.value.$2}"', (tester) async {
      final api = FakeAuthApi()..onLogin = () => throw entry.value.$1;
      await _openLogin(tester, api);
      await _fill(tester);

      await tester.tap(field('login-submit'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('auth-error-banner')), findsOneWidget);
      expect(find.text(entry.value.$2), findsOneWidget);
      expect(
        find.text('correct horse battery'),
        findsOneWidget,
      ); // kept to retry
    });
  }

  testWidgets('422 field errors render under the field', (tester) async {
    final api = FakeAuthApi()
      ..onLogin = () => throw const ValidationException(
        method: 'POST',
        path: '/api/auth/login',
        message: 'Invalid request',
        fieldErrors: [
          FieldError(location: ['body', 'email'], message: 'Too long'),
        ],
      );
    await _openLogin(tester, api);
    await _fill(tester);

    await tester.tap(field('login-submit'));
    await tester.pumpAndSettle();

    expect(find.text('Too long'), findsOneWidget);
  });

  testWidgets('after a failed attempt the user can correct the password', (
    tester,
  ) async {
    var attempts = 0;
    final api = FakeAuthApi()
      ..onLogin = () async {
        attempts++;
        if (attempts == 1) {
          throw const UnauthorizedException(
            method: 'POST',
            path: '/api/auth/login',
            message: 'Invalid email or password',
          );
        }
        return LoginResult(user: testUser, session: testSession());
      };
    await _openLogin(tester, api);
    await _fill(tester);
    await tester.tap(field('login-submit'));
    await tester.pumpAndSettle();
    expect(find.text('Incorrect email or password.'), findsOneWidget);

    await tester.tap(field('login-password'));
    await tester.enterText(field('login-password'), 'the correct passphrase');
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: field('login-password'),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      'the correct passphrase',
    );
    await tester.tap(field('login-submit'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.byKey(const Key('home-signed-in')), findsOneWidget);
  });

  testWidgets('success navigates to the authenticated home', (tester) async {
    await _openLogin(tester);
    await _fill(tester);

    await tester.tap(field('login-submit'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-signed-in')), findsOneWidget);
  });
}
