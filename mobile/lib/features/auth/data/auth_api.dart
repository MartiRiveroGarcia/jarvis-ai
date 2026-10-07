import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/storage/auth_session.dart';
import '../domain/login_result.dart';
import '../domain/user.dart';

/// The backend's authentication endpoints.
///
/// Throws [ApiException]s from [ApiClient]; responses that do not match the
/// expected shape become [UnexpectedResponseException].
class AuthApi {
  AuthApi(this._client);

  static const registerPath = '/api/auth/register';
  static const loginPath = '/api/auth/login';
  static const mePath = '/api/auth/me';
  static const logoutPath = '/api/auth/logout';

  final ApiClient _client;

  Future<User> register({
    required String email,
    required String password,
  }) async {
    final json = await _client.post(
      registerPath,
      body: {'email': email, 'password': password},
    );
    return _parse('POST', registerPath, json, User.fromJson);
  }

  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    final json = await _client.post(
      loginPath,
      body: {'email': email, 'password': password},
    );
    return _parse('POST', loginPath, json, LoginResult.fromJson);
  }

  Future<User> me() async {
    final json = await _client.get(mePath, authenticated: true);
    return _parse('GET', mePath, json, User.fromJson);
  }

  /// Revokes the stored session, or [session] if given (used for a session that
  /// was issued but could not be stored).
  Future<void> logout({AuthSession? session}) async {
    await _client.post(
      logoutPath,
      authenticated: session == null,
      bearerToken: session?.token,
    );
  }

  static T _parse<T>(
    String method,
    String path,
    JsonObject? json,
    T Function(JsonObject json) fromJson,
  ) {
    if (json == null) {
      throw UnexpectedResponseException(method: method, path: path);
    }
    try {
      return fromJson(json);
    } on FormatException {
      throw UnexpectedResponseException(method: method, path: path);
    }
  }
}
