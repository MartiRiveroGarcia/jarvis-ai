import 'package:flutter/foundation.dart';

/// The credentials kept on the device: the opaque session token and its expiry.
///
/// Nothing else (email, password, hashes, token type) is ever stored.
@immutable
class AuthSession {
  AuthSession({required this.token, required DateTime expiresAt})
    : expiresAt = expiresAt.toUtc();

  /// Raw Bearer token. Never log it or put it in a URL.
  final String token;

  /// Always UTC.
  final DateTime expiresAt;

  /// Same rule as the backend: a session expiring exactly now is expired.
  bool isExpiredAt(DateTime now) => !now.toUtc().isBefore(expiresAt);

  @override
  bool operator ==(Object other) =>
      other is AuthSession &&
      other.token == token &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(token, expiresAt);

  @override
  String toString() => 'AuthSession(token: <redacted>, expiresAt: $expiresAt)';
}
