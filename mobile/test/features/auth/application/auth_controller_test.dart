import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/api/api_exception.dart';
import 'package:jarvis/core/providers.dart';
import 'package:jarvis/core/storage/auth_session.dart';
import 'package:jarvis/features/auth/application/auth_controller.dart';
import 'package:jarvis/features/auth/application/auth_failure.dart';
import 'package:jarvis/features/auth/application/auth_state.dart';
import 'package:jarvis/features/auth/domain/login_result.dart';

import '../../../support/fake_auth_api.dart';
import '../../../support/in_memory_token_store.dart';

final _now = DateTime.utc(2026, 10, 5, 12);

const _email = 'marti@example.com';
const _password = 'correct horse battery staple';

class Harness {
  Harness({AuthSession? stored}) {
    store = InMemoryTokenStore(stored)..events = events;
    api = FakeAuthApi(events: events);
    container = ProviderContainer.test(
      retry: (_, _) => null,
      overrides: [
        authApiProvider.overrideWithValue(api),
        tokenStoreProvider.overrideWithValue(store),
        clockProvider.overrideWithValue(() => _now),
      ],
    );
    container.listen<AuthState>(authControllerProvider, (_, next) {
      states.add(next);
      events.add('state.${next.runtimeType}');
      // The invariant: signed out means nothing is stored on the device.
      if (next is AuthUnauthenticated && store.session != null) {
        invariantViolations.add('AuthUnauthenticated with a stored session');
      }
    }, fireImmediately: true);
  }

  final events = <String>[];
  final states = <AuthState>[];
  final invariantViolations = <String>[];
  late final InMemoryTokenStore store;
  late final FakeAuthApi api;
  late final ProviderContainer container;

  AuthController get controller =>
      container.read(authControllerProvider.notifier);

  AuthState get state => container.read(authControllerProvider);

  /// Lets the restore started in build() finish.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

late Harness h;

Future<Harness> _start({AuthSession? stored}) async {
  h = Harness(stored: stored);
  await h.settle();
  return h;
}

void main() {
  tearDown(() => expect(h.invariantViolations, isEmpty));

  group('startup', () {
    test('no stored session -> signed out, no network call', () async {
      await _start();

      expect(h.state, isA<AuthUnauthenticated>());
      expect(h.api.calls, isEmpty);
    });

    test('starts in AuthInitializing', () async {
      h = Harness(stored: testSession());

      expect(h.states.first, isA<AuthInitializing>());
      await h.settle();
    });

    test('expired session -> cleared without network, signed out', () async {
      await _start(stored: testSession(expiresAt: _now));

      expect(h.state, isA<AuthUnauthenticated>());
      expect(h.store.session, isNull);
      expect(h.api.calls, isEmpty);
    });

    test('expired session + clear fails -> sign-out failed', () async {
      h = Harness(stored: testSession(expiresAt: _now));
      h.store.failClear = true;
      await h.settle();

      expect(h.state, isA<AuthSignOutFailed>());
      expect(h.store.session, isNotNull);
    });

    test('valid session + /me 200 -> authenticated', () async {
      await _start(stored: testSession());

      expect(h.state, isA<AuthAuthenticated>());
      expect((h.state as AuthAuthenticated).user, testUser);
      expect(h.api.calls, ['me']);
    });

    test('/me 401 -> cleared and signed out', () async {
      h = Harness(stored: testSession());
      h.api.onMe = () => throw const UnauthorizedException(
        method: 'GET',
        path: '/api/auth/me',
        message: 'Invalid or expired session',
      );
      await h.settle();

      expect(h.state, isA<AuthUnauthenticated>());
      expect(h.store.session, isNull);
    });

    test('/me 401 + clear fails -> sign-out failed', () async {
      h = Harness(stored: testSession());
      h.api.onMe = () => throw const UnauthorizedException(
        method: 'GET',
        path: '/api/auth/me',
        message: 'Invalid',
      );
      h.store.failClear = true;
      await h.settle();

      expect(h.state, isA<AuthSignOutFailed>());
    });

    test('network error -> restore failed, session kept', () async {
      h = Harness(stored: testSession());
      h.api.onMe = () => throw networkError('/api/auth/me');
      await h.settle();

      expect(h.state, isA<AuthRestoreFailed>());
      expect((h.state as AuthRestoreFailed).cause, isA<NetworkFailure>());
      expect(h.store.session, testSession());
      expect(h.store.clears, 0);
    });

    test('server error -> restore failed, session kept', () async {
      h = Harness(stored: testSession());
      h.api.onMe = () => throw const ServerException(
        method: 'GET',
        path: '/api/auth/me',
        statusCode: 503,
      );
      await h.settle();

      expect((h.state as AuthRestoreFailed).cause, isA<ServerFailure>());
      expect(h.store.session, isNotNull);
    });

    test('storage read error -> restore failed', () async {
      h = Harness(stored: testSession());
      h.store.failRead = true;
      await h.settle();

      expect((h.state as AuthRestoreFailed).cause, isA<StorageFailure>());
    });

    test('retry after a network error succeeds', () async {
      h = Harness(stored: testSession());
      h.api.onMe = () => throw networkError('/api/auth/me');
      await h.settle();
      h.api.onMe = null;

      await h.controller.retry();

      expect(h.state, isA<AuthAuthenticated>());
      expect(
        h.states.map((s) => s.runtimeType),
        containsAllInOrder([
          AuthRestoreFailed,
          AuthInitializing,
          AuthAuthenticated,
        ]),
      );
    });

    test('"sign out of this device" from restore failed', () async {
      h = Harness(stored: testSession());
      h.api.onMe = () => throw networkError('/api/auth/me');
      await h.settle();

      h.store.failClear = true;
      await h.controller.signOutOnThisDevice();
      expect(h.state, isA<AuthSignOutFailed>());

      h.store.failClear = false;
      await h.controller.signOutOnThisDevice();
      expect(h.state, isA<AuthUnauthenticated>());
      expect(h.store.session, isNull);
    });
  });

  group('login', () {
    test('stores the session before becoming authenticated', () async {
      await _start();

      await h.controller.login(email: _email, password: _password);

      expect(h.state, isA<AuthAuthenticated>());
      expect(h.store.session, testSession());
      expect(
        h.events.indexOf('store.write'),
        lessThan(h.events.indexOf('state.AuthAuthenticated')),
      );
    });

    for (final entry in <String, (ApiException, Type)>{
      '401': (
        const UnauthorizedException(
          method: 'POST',
          path: '/api/auth/login',
          message: 'Invalid email or password',
        ),
        InvalidCredentials,
      ),
      '403': (
        const ForbiddenException(
          method: 'POST',
          path: '/api/auth/login',
          message: 'Account is disabled',
        ),
        AccountDisabled,
      ),
      '422': (
        const ValidationException(
          method: 'POST',
          path: '/api/auth/login',
          message: 'Invalid request',
        ),
        ValidationFailed,
      ),
      'network': (networkError('/api/auth/login'), NetworkFailure),
    }.entries) {
      test('${entry.key} -> ${entry.value.$2}, nothing stored', () async {
        await _start();
        h.api.onLogin = () => throw entry.value.$1;

        await expectLater(
          h.controller.login(email: _email, password: _password),
          throwsA(
            isA<AuthFailure>().having(
              (f) => f.runtimeType,
              'type',
              entry.value.$2,
            ),
          ),
        );
        expect(h.store.writes, 0);
        expect(h.state, isA<AuthUnauthenticated>());
      });
    }

    test('storage write failure never authenticates and revokes the new '
        'session', () async {
      await _start();
      h.store.failWrite = true;

      await expectLater(
        h.controller.login(email: _email, password: _password),
        throwsA(isA<StorageFailure>()),
      );
      expect(h.states, isNot(contains(isA<AuthAuthenticated>())));
      expect(h.api.logoutSessions.single, testSession());
      expect(h.store.clears, 1);
      expect(h.state, isA<AuthUnauthenticated>());
    });

    test('partial write is cleaned up', () async {
      await _start();
      h.store.partialWrite = true;

      await expectLater(
        h.controller.login(email: _email, password: _password),
        throwsA(isA<StorageFailure>()),
      );
      expect(h.store.session, isNull);
      expect(h.state, isA<AuthUnauthenticated>());
    });

    test('partial write + cleanup clear fails -> sign-out failed', () async {
      await _start();
      h.store
        ..partialWrite = true
        ..failClear = true;

      await expectLater(
        h.controller.login(email: _email, password: _password),
        throwsA(isA<StorageFailure>()),
      );
      expect(h.state, isA<AuthSignOutFailed>());
      expect(h.states, isNot(contains(isA<AuthAuthenticated>())));
    });

    test('cleanup logout network failure is ignored', () async {
      await _start();
      h.store.failWrite = true;
      h.api.onLogout = () => throw networkError('/api/auth/logout');

      await expectLater(
        h.controller.login(email: _email, password: _password),
        throwsA(isA<StorageFailure>()),
      );
      expect(h.state, isA<AuthUnauthenticated>());
    });
  });

  group('register', () {
    test('success logs in automatically', () async {
      await _start();

      await h.controller.register(email: _email, password: _password);

      expect(h.api.calls, ['register', 'login']);
      expect(h.state, isA<AuthAuthenticated>());
      expect(h.store.session, testSession());
    });

    test('duplicate email -> EmailAlreadyRegistered, no login', () async {
      await _start();
      h.api.onRegister = () => throw const ConflictException(
        method: 'POST',
        path: '/api/auth/register',
        message: 'Email is already registered',
      );

      await expectLater(
        h.controller.register(email: _email, password: _password),
        throwsA(isA<EmailAlreadyRegistered>()),
      );
      expect(h.api.calls, ['register']);
    });

    test('registration disabled -> RegistrationDisabled', () async {
      await _start();
      h.api.onRegister = () => throw const ForbiddenException(
        method: 'POST',
        path: '/api/auth/register',
        message: 'Registration is disabled',
      );

      await expectLater(
        h.controller.register(email: _email, password: _password),
        throwsA(isA<RegistrationDisabled>()),
      );
    });

    test('network failure on register -> NetworkFailure', () async {
      await _start();
      h.api.onRegister = () => throw networkError('/api/auth/register');

      await expectLater(
        h.controller.register(email: _email, password: _password),
        throwsA(isA<NetworkFailure>()),
      );
    });

    test('registered but auto-login network failure', () async {
      await _start();
      h.api.onLogin = () => throw networkError('/api/auth/login');

      await expectLater(
        h.controller.register(email: _email, password: _password),
        throwsA(
          isA<RegisteredButSignInFailed>()
              .having((f) => f.email, 'email', _email)
              .having((f) => f.cause, 'cause', isA<NetworkFailure>()),
        ),
      );
      expect(h.state, isA<AuthUnauthenticated>());
      expect(h.store.session, isNull);
    });
  });

  group('logout', () {
    Future<void> signedIn() async {
      await _start(stored: testSession());
      expect(h.state, isA<AuthAuthenticated>());
    }

    test('revokes on the server, clears locally, signs out', () async {
      await signedIn();

      await h.controller.logout();

      expect(h.api.logoutSessions.single, testSession());
      expect(h.store.session, isNull);
      expect(h.state, isA<AuthUnauthenticated>());
    });

    test('network failure still clears locally', () async {
      await signedIn();
      h.api.onLogout = () => throw networkError('/api/auth/logout');

      await h.controller.logout();

      expect(h.store.session, isNull);
      expect(h.state, isA<AuthUnauthenticated>());
    });

    test('clear failure -> sign-out failed, then retry succeeds', () async {
      await signedIn();
      h.store.failClear = true;

      await h.controller.logout();

      expect(h.state, isA<AuthSignOutFailed>());
      expect(h.store.session, isNotNull);

      h.store.failClear = false;
      await h.controller.signOutOnThisDevice();

      expect(h.state, isA<AuthUnauthenticated>());
      expect(h.store.session, isNull);
    });

    test('storage read failure still attempts to clear', () async {
      await signedIn();
      h.store.failRead = true;

      await h.controller.logout();

      expect(h.api.calls, isNot(contains('logout')));
      expect(h.state, isA<AuthUnauthenticated>());
    });
  });

  group('sessionExpired', () {
    test('clears and signs out', () async {
      await _start(stored: testSession());

      await h.controller.sessionExpired();

      expect(h.state, isA<AuthUnauthenticated>());
      expect(h.store.session, isNull);
    });

    test('clear failure -> sign-out failed', () async {
      await _start(stored: testSession());
      h.store.failClear = true;

      await h.controller.sessionExpired();

      expect(h.state, isA<AuthSignOutFailed>());
    });
  });

  test('LoginResult and failures never expose the token or email', () {
    final result = LoginResult(user: testUser, session: testSession());
    const failure = RegisteredButSignInFailed(
      email: _email,
      cause: NetworkFailure(),
    );

    expect(result.toString(), isNot(contains(testToken)));
    expect(result.toString(), isNot(contains(_email)));
    expect(failure.toString(), isNot(contains(_email)));
  });
}
