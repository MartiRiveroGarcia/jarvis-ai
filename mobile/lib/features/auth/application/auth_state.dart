import 'package:flutter/foundation.dart';

import '../domain/user.dart';
import 'auth_failure.dart';

/// Global authentication state.
///
/// Invariant: [AuthUnauthenticated] means no session credential is stored on
/// this device. If removing it fails, the state is [AuthSignOutFailed] instead.
@immutable
sealed class AuthState {
  const AuthState();
}

/// Restoring the stored session at startup.
final class AuthInitializing extends AuthState {
  const AuthInitializing();
}

/// Signed out, and no session is stored on the device.
final class AuthUnauthenticated extends AuthState {
  const AuthUnauthenticated();
}

final class AuthAuthenticated extends AuthState {
  const AuthAuthenticated(this.user);

  final User user;
}

/// The stored session could not be checked (network, server or storage error).
/// The session is kept: this is not a sign-out.
final class AuthRestoreFailed extends AuthState {
  const AuthRestoreFailed(this.cause);

  final AuthFailure cause;
}

/// A sign-out could not remove the stored session from the device. The app stays
/// blocked until removal succeeds.
final class AuthSignOutFailed extends AuthState {
  const AuthSignOutFailed();
}
