import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_exception.dart';
import '../../../core/providers.dart';
import '../../../core/storage/auth_session.dart';
import '../../../core/storage/token_store.dart';
import '../../../core/time/clock.dart';
import '../data/auth_api.dart';
import '../domain/login_result.dart';
import 'auth_failure.dart';
import 'auth_state.dart';

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(apiClientProvider)),
);

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

/// Owns the global [AuthState] and every change to the stored session.
///
/// Invariant: the state only becomes [AuthUnauthenticated] after the stored
/// session has been removed successfully; otherwise it is [AuthSignOutFailed].
///
/// Form-level failures are thrown as [AuthFailure] and leave the state as is.
class AuthController extends Notifier<AuthState> {
  late AuthApi _api;
  late TokenStore _tokenStore;
  late Clock _clock;

  @override
  AuthState build() {
    _api = ref.read(authApiProvider);
    _tokenStore = ref.read(tokenStoreProvider);
    _clock = ref.read(clockProvider);
    Future.microtask(_restore);
    return const AuthInitializing();
  }

  /// Retries restoring the stored session after [AuthRestoreFailed].
  Future<void> retry() async {
    if (state is! AuthRestoreFailed) {
      return;
    }
    _set(const AuthInitializing());
    await _restore();
  }

  Future<void> login({required String email, required String password}) async {
    final LoginResult result;
    try {
      result = await _api.login(email: email, password: password);
    } on ApiException catch (error) {
      throw _failureFrom(error, _Operation.login);
    }

    try {
      await _tokenStore.write(result.session);
    } on Exception {
      await _discardUnsavedSession(result.session);
      throw const StorageFailure();
    }
    _set(AuthAuthenticated(result.user));
  }

  /// Creates an account, then logs in with the same credentials.
  ///
  /// Throws [RegisteredButSignInFailed] if the account was created but the
  /// automatic login did not complete.
  Future<void> register({
    required String email,
    required String password,
  }) async {
    try {
      await _api.register(email: email, password: password);
    } on ApiException catch (error) {
      throw _failureFrom(error, _Operation.register);
    }

    try {
      await login(email: email, password: password);
    } on AuthFailure catch (cause) {
      throw RegisteredButSignInFailed(email: email, cause: cause);
    }
  }

  /// Best-effort server logout, then removes the stored session.
  Future<void> logout() async {
    AuthSession? session;
    try {
      session = await _tokenStore.read();
    } on Exception {
      session = null;
    }
    if (session != null) {
      try {
        await _api.logout(session: session);
      } on ApiException {
        // The server session expires on its own; the local token goes regardless.
      }
    }
    await _clearStoredSession();
  }

  /// Removes the stored session without contacting the server. Used from the
  /// restore-failed screen and to retry a failed sign-out.
  Future<void> signOutOnThisDevice() => _clearStoredSession();

  /// For features whose API calls receive a 401: the session is no longer valid.
  Future<void> sessionExpired() => _clearStoredSession();

  Future<void> _restore() async {
    final AuthSession? session;
    try {
      session = await _tokenStore.read();
    } on Exception {
      _set(const AuthRestoreFailed(StorageFailure()));
      return;
    }

    if (session == null) {
      _set(const AuthUnauthenticated());
      return;
    }
    if (session.isExpiredAt(_clock())) {
      await _clearStoredSession();
      return;
    }

    try {
      _set(AuthAuthenticated(await _api.me()));
    } on UnauthorizedException {
      await _clearStoredSession();
    } on ApiException catch (error) {
      _set(AuthRestoreFailed(_failureFrom(error, _Operation.restore)));
    }
  }

  /// The only path to [AuthUnauthenticated].
  Future<void> _clearStoredSession() async {
    try {
      await _tokenStore.clear();
    } on Exception {
      _set(const AuthSignOutFailed());
      return;
    }
    _set(const AuthUnauthenticated());
  }

  /// A session was issued but could not be stored: revoke it on the server and
  /// remove anything partially written, both best-effort.
  Future<void> _discardUnsavedSession(AuthSession session) async {
    try {
      await _api.logout(session: session);
    } on ApiException {
      // It will expire on the server.
    }
    try {
      await _tokenStore.clear();
    } on Exception {
      _set(const AuthSignOutFailed());
    }
  }

  void _set(AuthState next) {
    if (ref.mounted) {
      state = next;
    }
  }

  static AuthFailure _failureFrom(ApiException error, _Operation operation) =>
      switch (error) {
        NetworkException(:final isTimeout) => NetworkFailure(
          isTimeout: isTimeout,
        ),
        UnauthorizedException() when operation == _Operation.login =>
          const InvalidCredentials(),
        ForbiddenException() when operation == _Operation.login =>
          const AccountDisabled(),
        ForbiddenException() when operation == _Operation.register =>
          const RegistrationDisabled(),
        ConflictException() => const EmailAlreadyRegistered(),
        ValidationException(:final message, :final fieldErrors) =>
          ValidationFailed(message: message, fieldErrors: fieldErrors),
        _ => const ServerFailure(),
      };
}

enum _Operation { restore, login, register }
