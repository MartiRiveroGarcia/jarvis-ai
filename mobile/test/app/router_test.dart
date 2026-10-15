import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jarvis/app/router.dart';
import 'package:jarvis/core/storage/auth_session.dart';
import 'package:jarvis/features/auth/application/auth_controller.dart';
import 'package:jarvis/features/auth/application/auth_failure.dart';
import 'package:jarvis/features/auth/application/auth_state.dart';

import '../support/fake_auth_api.dart';
import '../support/in_memory_token_store.dart';
import '../support/test_app.dart';

final _states = <AuthState>[
  const AuthInitializing(),
  const AuthUnauthenticated(),
  AuthAuthenticated(testUser),
  const AuthRestoreFailed(NetworkFailure()),
  const AuthSignOutFailed(),
];

const _paths = [
  Routes.splash,
  Routes.login,
  Routes.register,
  Routes.home,
  Routes.settings,
  '/unknown',
];

void main() {
  group('authRedirect (pure)', () {
    test('initializing, restore failed and sign-out failed stay on splash', () {
      for (final state in [_states[0], _states[3], _states[4]]) {
        for (final path in _paths) {
          expect(
            authRedirect(state, path),
            path == Routes.splash ? isNull : Routes.splash,
            reason: '$state $path',
          );
        }
      }
    });

    test('unauthenticated: login and register allowed, others -> login', () {
      const state = AuthUnauthenticated();
      expect(authRedirect(state, Routes.login), isNull);
      expect(authRedirect(state, Routes.register), isNull);
      for (final path in [Routes.splash, Routes.home, Routes.settings, '/x']) {
        expect(authRedirect(state, path), Routes.login, reason: path);
      }
    });

    test('authenticated: home and settings allowed, others -> home', () {
      final state = AuthAuthenticated(testUser);
      expect(authRedirect(state, Routes.home), isNull);
      expect(authRedirect(state, Routes.settings), isNull);
      for (final path in [Routes.splash, Routes.login, Routes.register, '/x']) {
        expect(authRedirect(state, path), Routes.home, reason: path);
      }
    });

    test('no redirect loops: every target is allowed in its own state', () {
      for (final state in _states) {
        for (final path in _paths) {
          final target = authRedirect(state, path);
          if (target != null) {
            expect(authRedirect(state, target), isNull, reason: '$state $path');
          }
        }
      }
    });
  });

  group('router (widgets)', () {
    String location(WidgetTester tester) =>
        GoRouter.of(tester.element(find.byType(Navigator).first))
            .routeInformationProvider
            .value
            .uri
            .path;

    testWidgets('initializing shows splash and never login', (tester) async {
      final pendingMe = Completer<Never>();
      final api = FakeAuthApi()..onMe = () => pendingMe.future;
      await pumpJarvis(
        tester,
        api: api,
        store: InMemoryTokenStore(testSession()),
      );
      await tester.pump();

      expect(find.byKey(const Key('splash-progress')), findsOneWidget);
      expect(find.byKey(const Key('login-email')), findsNothing);
    });

    testWidgets('signed out goes to login; register is allowed', (
      tester,
    ) async {
      await pumpJarvis(tester, api: FakeAuthApi(), store: InMemoryTokenStore());
      await tester.pumpAndSettle();
      expect(location(tester), Routes.login);

      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();
      expect(location(tester), Routes.register);
    });

    testWidgets('signed out protected route -> login', (tester) async {
      final container = await pumpJarvis(
        tester,
        api: FakeAuthApi(),
        store: InMemoryTokenStore(),
      );
      await tester.pumpAndSettle();

      container.read(routerProvider).go(Routes.settings);
      await tester.pumpAndSettle();

      expect(location(tester), Routes.login);
    });

    testWidgets('signed in: login/register -> home, settings allowed', (
      tester,
    ) async {
      final container = await pumpJarvis(
        tester,
        api: FakeAuthApi(),
        store: InMemoryTokenStore(testSession()),
      );
      await tester.pumpAndSettle();
      final router = container.read(routerProvider);
      expect(location(tester), Routes.home);

      for (final path in [Routes.login, Routes.register]) {
        router.go(path);
        await tester.pumpAndSettle();
        expect(location(tester), Routes.home, reason: path);
      }
      router.go(Routes.settings);
      await tester.pumpAndSettle();
      expect(location(tester), Routes.settings);
    });

    testWidgets('the router instance survives auth changes', (tester) async {
      final container = await pumpJarvis(
        tester,
        api: FakeAuthApi(),
        store: InMemoryTokenStore(),
      );
      await tester.pumpAndSettle();
      final before = container.read(routerProvider);

      await container
          .read(authControllerProvider.notifier)
          .login(email: 'marti@example.com', password: 'x' * 20);
      await tester.pumpAndSettle();

      expect(identical(container.read(routerProvider), before), isTrue);
      expect(location(tester), Routes.home);
    });

    testWidgets('home -> settings -> back arrow -> home', (tester) async {
      await pumpJarvis(
        tester,
        api: FakeAuthApi(),
        store: InMemoryTokenStore(testSession()),
      );
      await tester.pumpAndSettle();

      // Settings is pushed on top of home, so check what is on screen.
      await tester.tap(find.byKey(const Key('home-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-screen')), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-screen')), findsNothing);
      expect(find.byKey(const Key('assistant-home')), findsOneWidget);
    });

    testWidgets('system back from settings returns home', (tester) async {
      await pumpJarvis(
        tester,
        api: FakeAuthApi(),
        store: InMemoryTokenStore(testSession()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-settings')));
      await tester.pumpAndSettle();

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(find.byKey(const Key('assistant-home')), findsOneWidget);
    });

    testWidgets('sign out from settings returns to login with nothing to '
        'go back to', (tester) async {
      final store = InMemoryTokenStore(
        AuthSession(token: testToken, expiresAt: DateTime.utc(2030)),
      );
      await pumpJarvis(tester, api: FakeAuthApi(), store: store);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-settings')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-sign-out')));
      await tester.pumpAndSettle();

      expect(location(tester), Routes.login);
      expect(store.session, isNull);
      expect(find.byKey(const Key('settings-screen')), findsNothing);
    });
  });

  group('developer tools route', () {
    const dev = Routes.developerTextAssistant;

    test('authenticated: allowed only with developer tools', () {
      final state = AuthAuthenticated(testUser);

      expect(authRedirect(state, dev, developerTools: true), isNull);
      expect(authRedirect(state, dev, developerTools: false), Routes.home);
      expect(authRedirect(state, dev), Routes.home);
    });

    test('other states redirect as before, with or without the flag', () {
      for (final developerTools in [true, false]) {
        expect(
          authRedirect(
            const AuthUnauthenticated(),
            dev,
            developerTools: developerTools,
          ),
          Routes.login,
        );
        for (final state in [_states[0], _states[3], _states[4]]) {
          expect(
            authRedirect(state, dev, developerTools: developerTools),
            Routes.splash,
          );
        }
      }
    });

    test('the flag changes nothing for the other paths', () {
      for (final state in _states) {
        for (final path in _paths) {
          expect(
            authRedirect(state, path, developerTools: true),
            authRedirect(state, path),
            reason: '$state $path',
          );
        }
      }
    });

    test('no redirect loops with developer tools enabled', () {
      for (final state in _states) {
        for (final path in [..._paths, dev]) {
          final target = authRedirect(state, path, developerTools: true);
          if (target != null) {
            expect(
              authRedirect(state, target, developerTools: true),
              isNull,
              reason: '$state $path',
            );
          }
        }
      }
    });

    for (final developerTools in [true, false]) {
      testWidgets('direct navigation with developer tools '
          '${developerTools ? 'enabled opens' : 'disabled goes home'}', (
        tester,
      ) async {
        final container = await pumpJarvis(
          tester,
          api: FakeAuthApi(),
          store: InMemoryTokenStore(testSession()),
          developerTools: developerTools,
        );
        await tester.pumpAndSettle();

        container.read(routerProvider).go(dev);
        await tester.pumpAndSettle();

        final screen = find.byKey(const Key('developer-text-assistant-screen'));
        expect(screen, developerTools ? findsOneWidget : findsNothing);
        expect(
          find.byKey(const Key('assistant-home')),
          developerTools ? findsNothing : findsOneWidget,
        );
      });
    }

    for (final developerTools in [true, false]) {
      testWidgets(
        'the route is registered only with developer tools ($developerTools)',
        (tester) async {
          final container = await pumpJarvis(
            tester,
            api: FakeAuthApi(),
            store: InMemoryTokenStore(testSession()),
            developerTools: developerTools,
          );
          await tester.pumpAndSettle();

          final paths = [
            for (final route
                in container.read(routerProvider).configuration.routes)
              if (route is GoRoute) route.path,
          ];
          expect(paths.contains(dev), developerTools);
          expect(paths, containsAll([Routes.home, Routes.settings]));
        },
      );
    }

    testWidgets('signed out, the developer route goes to login', (
      tester,
    ) async {
      final container = await pumpJarvis(
        tester,
        api: FakeAuthApi(),
        store: InMemoryTokenStore(),
        developerTools: true,
      );
      await tester.pumpAndSettle();

      container.read(routerProvider).go(dev);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('login-email')), findsOneWidget);
    });
  });
}
