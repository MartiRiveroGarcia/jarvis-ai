import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_session.dart';

/// Persists the current [AuthSession] between app launches.
abstract interface class TokenStore {
  Future<AuthSession?> read();

  Future<void> write(AuthSession session);

  Future<void> clear();
}

/// [TokenStore] backed by flutter_secure_storage.
///
/// On Android, values are encrypted with AES-GCM under a key wrapped by an
/// RSA key pair held in the Android Keystore. Uninstalling the app removes both
/// the data and the keys.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const tokenKey = 'jarvis.session_token';
  static const expiresAtKey = 'jarvis.session_expires_at';

  final FlutterSecureStorage _storage;

  @override
  Future<AuthSession?> read() async {
    final token = await _storage.read(key: tokenKey);
    final rawExpiresAt = await _storage.read(key: expiresAtKey);
    if (token == null && rawExpiresAt == null) {
      return null;
    }

    final expiresAt = rawExpiresAt == null
        ? null
        : DateTime.tryParse(rawExpiresAt);
    if (token == null || token.isEmpty || expiresAt == null) {
      // A half-written or corrupt session must never count as signed in.
      await clear();
      return null;
    }
    return AuthSession(token: token, expiresAt: expiresAt.toUtc());
  }

  @override
  Future<void> write(AuthSession session) async {
    await _storage.write(key: tokenKey, value: session.token);
    await _storage.write(
      key: expiresAtKey,
      value: session.expiresAt.toUtc().toIso8601String(),
    );
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: tokenKey);
    await _storage.delete(key: expiresAtKey);
  }
}
