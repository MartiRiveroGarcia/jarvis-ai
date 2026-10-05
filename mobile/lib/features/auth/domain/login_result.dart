import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../../../core/storage/auth_session.dart';
import 'user.dart';

/// Format of tokens issued by the backend: 32 random bytes, URL-safe base64.
final _sessionTokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// A successful login: the user plus the session to store on the device.
@immutable
class LoginResult {
  const LoginResult({required this.user, required this.session});

  /// Parses the backend's LoginResponse. Throws [FormatException] if invalid.
  factory LoginResult.fromJson(JsonObject json) {
    if (json
        case {
          'user': final Map<String, Object?> user,
          'session_token': final String token,
          'token_type': 'bearer',
          'expires_at': final String expiresAt,
        }
        when _sessionTokenPattern.hasMatch(token)) {
      return LoginResult(
        user: User.fromJson(user),
        session: AuthSession(
          token: token,
          expiresAt: DateTime.parse(expiresAt).toUtc(),
        ),
      );
    }
    throw const FormatException('Invalid login response');
  }

  final User user;
  final AuthSession session;

  @override
  String toString() => 'LoginResult(user: $user, session: $session)';
}
