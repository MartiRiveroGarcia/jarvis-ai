import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis/core/api/api_client.dart';
import 'package:jarvis/core/api/api_exception.dart';
import 'package:jarvis/core/storage/auth_session.dart';
import 'package:jarvis/features/auth/data/auth_api.dart';
import 'package:jarvis/features/auth/domain/user.dart';

import '../../../support/fake_auth_api.dart' show otherToken, testToken;
import '../../../support/in_memory_token_store.dart';

const _password = 'correct horse battery staple';

const _userJson = {
  'id': '3f1c2d4e-0000-4000-8000-000000000001',
  'email': 'marti@example.com',
  'created_at': '2026-10-05T10:00:00.123456Z',
};

({AuthApi api, List<http.Request> requests}) _setUp(
  http.Response Function(http.Request request) respond, {
  AuthSession? stored,
}) {
  final requests = <http.Request>[];
  final client = ApiClient(
    baseUrl: Uri.parse('https://api.example.com'),
    httpClient: MockClient((request) async {
      requests.add(request);
      return respond(request);
    }),
    tokenStore: InMemoryTokenStore(stored),
  );
  return (api: AuthApi(client), requests: requests);
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

Map<String, Object?> _loginJson({
  String token = testToken,
  String tokenType = 'bearer',
}) => {
  'user': _userJson,
  'session_token': token,
  'token_type': tokenType,
  'expires_at': '2026-10-12T10:00:00Z',
};

void main() {
  test('register posts email and password and parses the user', () async {
    final (:api, :requests) = _setUp((_) => _json(_userJson, 201));

    final user = await api.register(
      email: 'marti@example.com',
      password: _password,
    );

    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/api/auth/register');
    expect(jsonDecode(request.body), {
      'email': 'marti@example.com',
      'password': _password,
    });
    expect(request.headers.keys, isNot(contains('authorization')));
    expect(user.email, 'marti@example.com');
  });

  test('login posts credentials and parses user, token and expiry', () async {
    final (:api, :requests) = _setUp((_) => _json(_loginJson()));

    final result = await api.login(
      email: 'marti@example.com',
      password: _password,
    );

    expect(requests.single.url.path, '/api/auth/login');
    expect(jsonDecode(requests.single.body), {
      'email': 'marti@example.com',
      'password': _password,
    });
    expect(result.user.id, '3f1c2d4e-0000-4000-8000-000000000001');
    expect(result.session.token, testToken);
    expect(result.session.expiresAt, DateTime.utc(2026, 10, 12, 10));
    expect(result.session.expiresAt.isUtc, isTrue);
  });

  test('me sends the stored Bearer token', () async {
    final (:api, :requests) = _setUp(
      (_) => _json(_userJson),
      stored: AuthSession(token: testToken, expiresAt: DateTime.utc(2030)),
    );

    final user = await api.me();

    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/api/auth/me');
    expect(requests.single.headers['Authorization'], 'Bearer $testToken');
    expect(user.createdAt, DateTime.utc(2026, 10, 5, 10, 0, 0, 123, 456));
  });

  test('logout uses the stored token by default', () async {
    final (:api, :requests) = _setUp(
      (_) => http.Response('', 204),
      stored: AuthSession(token: testToken, expiresAt: DateTime.utc(2030)),
    );

    await api.logout();

    expect(requests.single.url.path, '/api/auth/logout');
    expect(requests.single.headers['Authorization'], 'Bearer $testToken');
  });

  test('logout(session:) revokes that session, not the stored one', () async {
    final (:api, :requests) = _setUp(
      (_) => http.Response('', 204),
      stored: AuthSession(token: testToken, expiresAt: DateTime.utc(2030)),
    );

    await api.logout(
      session: AuthSession(token: otherToken, expiresAt: DateTime.utc(2030)),
    );

    expect(requests.single.headers['Authorization'], 'Bearer $otherToken');
  });

  group('invalid responses become UnexpectedResponseException', () {
    for (final entry in <String, Map<String, Object?>>{
      'wrong token type': _loginJson(tokenType: 'jwt'),
      'malformed token': _loginJson(token: 'short'),
      'missing user': {..._loginJson()}..remove('user'),
      'bad expiry': {..._loginJson(), 'expires_at': 'soon'},
    }.entries) {
      test('login: ${entry.key}', () async {
        final (:api, requests: _) = _setUp((_) => _json(entry.value));

        await expectLater(
          api.login(email: 'marti@example.com', password: _password),
          throwsA(isA<UnexpectedResponseException>()),
        );
      });
    }

    test('me: missing email', () async {
      final (:api, requests: _) = _setUp(
        (_) => _json({'id': '1', 'created_at': '2026-10-05T10:00:00Z'}),
        stored: AuthSession(token: testToken, expiresAt: DateTime.utc(2030)),
      );

      await expectLater(api.me(), throwsA(isA<UnexpectedResponseException>()));
    });
  });

  test('User.toString does not include the email', () {
    final user = User.fromJson(_userJson);

    expect(user.toString(), isNot(contains('marti@example.com')));
  });
}
