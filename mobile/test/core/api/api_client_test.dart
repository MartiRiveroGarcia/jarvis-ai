import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis/core/api/api_client.dart';
import 'package:jarvis/core/api/api_exception.dart';
import 'package:jarvis/core/storage/auth_session.dart';

import '../../support/in_memory_token_store.dart';

const _token = 'Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_xyz';
const _password = 'correct horse battery staple';

final _base = Uri.parse('https://api.example.com');

AuthSession _session() =>
    AuthSession(token: _token, expiresAt: DateTime.utc(2030));

/// Builds a client whose server replies with [handler] and records requests.
({ApiClient client, List<http.Request> requests, InMemoryTokenStore store})
_setUp(
  Future<http.Response> Function(http.Request request) handler, {
  Uri? baseUrl,
  AuthSession? session,
  Duration timeout = const Duration(seconds: 15),
}) {
  final requests = <http.Request>[];
  final store = InMemoryTokenStore(session);
  final client = ApiClient(
    baseUrl: baseUrl ?? _base,
    httpClient: MockClient((request) {
      requests.add(request);
      return handler(request);
    }),
    tokenStore: store,
    timeout: timeout,
  );
  return (client: client, requests: requests, store: store);
}

Future<http.Response> _json(Object? body, [int status = 200]) async =>
    http.Response(jsonEncode(body), status);

void main() {
  group('resolve', () {
    test('joins onto a base URL without a path', () {
      final (:client, requests: _, store: _) = _setUp((_) => _json({}));

      expect(
        client.resolve('/api/auth/me').toString(),
        'https://api.example.com/api/auth/me',
      );
    });

    test('preserves a base path', () {
      final (:client, requests: _, store: _) = _setUp(
        (_) => _json({}),
        baseUrl: Uri.parse('https://example.com/jarvis'),
      );

      expect(
        client.resolve('/api/auth/me').toString(),
        'https://example.com/jarvis/api/auth/me',
      );
    });

    test('keeps the port of the base URL', () {
      final (:client, requests: _, store: _) = _setUp(
        (_) => _json({}),
        baseUrl: Uri.parse('http://192.168.1.20:8000'),
      );

      expect(
        client.resolve('/api/health').toString(),
        'http://192.168.1.20:8000/api/health',
      );
    });

    for (final path in [
      '',
      'api/auth/me',
      '//evil.example/api',
      'https://evil.example/api',
      'http://evil.example',
      '/api/auth/me?token=x',
      '/api/auth/me#fragment',
      '/api/../admin',
      '/api/./auth',
      '/api/%2e%2e/admin',
      r'/\evil.example',
    ]) {
      test('rejects "$path"', () {
        final (:client, requests: _, store: _) = _setUp((_) => _json({}));

        expect(() => client.resolve(path), throwsArgumentError);
      });
    }

    test('an unsafe path never reads the token or sends a request', () async {
      final (:client, :requests, :store) = _setUp(
        (_) => _json({}),
        session: _session(),
      );

      await expectLater(
        client.get('//evil.example/steal', authenticated: true),
        throwsArgumentError,
      );
      expect(store.reads, 0);
      expect(requests, isEmpty);
    });
  });

  group('headers', () {
    test('unauthenticated requests carry no Authorization header', () async {
      final (:client, :requests, store: _) = _setUp(
        (_) => _json({'status': 'ok'}),
        session: _session(),
      );

      await client.get('/api/health');

      expect(requests.single.headers.keys, isNot(contains('authorization')));
      expect(requests.single.headers['Accept'], 'application/json');
    });

    test(
      'authenticated requests carry exactly Authorization: Bearer <token>',
      () async {
        final (:client, :requests, store: _) = _setUp(
          (_) => _json({'id': '1'}),
          session: _session(),
        );

        await client.get('/api/auth/me', authenticated: true);

        expect(requests.single.headers['Authorization'], 'Bearer $_token');
        expect(requests.single.url.toString(), isNot(contains(_token)));
      },
    );

    test('authenticated call without a session sends nothing', () async {
      final (:client, :requests, store: _) = _setUp((_) => _json({}));

      await expectLater(
        client.get('/api/auth/me', authenticated: true),
        throwsA(isA<UnauthorizedException>()),
      );
      expect(requests, isEmpty);
    });

    test('POST sends a JSON body with Content-Type', () async {
      final (:client, :requests, store: _) = _setUp((_) => _json({'ok': true}));

      await client.post(
        '/api/auth/login',
        body: {'email': 'me@example.com', 'password': _password},
      );

      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(request.body), {
        'email': 'me@example.com',
        'password': _password,
      });
    });
  });

  group('successful responses', () {
    test('200 returns the decoded object', () async {
      final (:client, requests: _, store: _) = _setUp(
        (_) => _json({'status': 'ok'}),
      );

      expect(await client.get('/api/health'), {'status': 'ok'});
    });

    test('201 returns the decoded object', () async {
      final (:client, requests: _, store: _) = _setUp(
        (_) => _json({'id': '1'}, 201),
      );

      expect(await client.post('/api/auth/register', body: {}), {'id': '1'});
    });

    test('204 returns null', () async {
      final (:client, requests: _, store: _) = _setUp(
        (_) async => http.Response('', 204),
        session: _session(),
      );

      expect(
        await client.post('/api/auth/logout', authenticated: true),
        isNull,
      );
    });

    test('a non-object or invalid JSON body is unexpected', () async {
      for (final body in ['[1, 2]', 'not json', '']) {
        final (:client, requests: _, store: _) = _setUp(
          (_) async => http.Response(body, 200),
        );

        await expectLater(
          client.get('/api/health'),
          throwsA(isA<UnexpectedResponseException>()),
          reason: body,
        );
      }
    });
  });

  group('error mapping', () {
    Future<ApiException> errorFor(http.Response response) async {
      final (:client, requests: _, store: _) = _setUp(
        (_) async => response,
        session: _session(),
      );
      try {
        await client.post(
          '/api/auth/login',
          body: {'password': _password},
          authenticated: true,
        );
      } on ApiException catch (error) {
        return error;
      }
      fail('expected an ApiException');
    }

    test('401 -> UnauthorizedException with the server detail', () async {
      final error = await errorFor(
        http.Response('{"detail": "Invalid or expired session"}', 401),
      );

      expect(error, isA<UnauthorizedException>());
      expect(error.statusCode, 401);
      expect(error.message, 'Invalid or expired session');
    });

    test('403 -> ForbiddenException', () async {
      expect(
        await errorFor(http.Response('{"detail": "Account is disabled"}', 403)),
        isA<ForbiddenException>(),
      );
    });

    test('409 -> ConflictException', () async {
      expect(
        await errorFor(
          http.Response('{"detail": "Email is already registered"}', 409),
        ),
        isA<ConflictException>(),
      );
    });

    test('422 with field errors keeps only location and message', () async {
      final error = await errorFor(
        http.Response(
          jsonEncode({
            'detail': [
              {
                'loc': ['body', 'password'],
                'msg': 'String should have at least 15 characters',
                'type': 'string_too_short',
                'input': _password,
              },
            ],
          }),
          422,
        ),
      );

      expect(error, isA<ValidationException>());
      final fieldError = (error as ValidationException).fieldErrors.single;
      expect(fieldError.location, ['body', 'password']);
      expect(fieldError.message, 'String should have at least 15 characters');
      expect(error.toString(), isNot(contains(_password)));
    });

    test('422 with a string detail', () async {
      final error = await errorFor(
        http.Response(
          '{"detail": "Password must be between 15 and 128 characters long"}',
          422,
        ),
      );

      expect(error, isA<ValidationException>());
      expect(error.message, startsWith('Password must be'));
      expect((error as ValidationException).fieldErrors, isEmpty);
    });

    for (final status in [500, 502, 503]) {
      test('$status -> ServerException without the response body', () async {
        final error = await errorFor(
          http.Response('Traceback: token=$_token', status),
        );

        expect(error, isA<ServerException>());
        expect(error.statusCode, status);
        expect(error.toString(), isNot(contains('Traceback')));
      });
    }

    test('other status codes -> UnexpectedResponseException', () async {
      expect(
        await errorFor(http.Response('{"detail": "teapot"}', 418)),
        isA<UnexpectedResponseException>(),
      );
    });

    test('very long details are truncated', () async {
      final error = await errorFor(
        http.Response(jsonEncode({'detail': 'x' * 1000}), 403),
      );

      expect(error.message.length, 200);
    });

    test('no exception ever contains the token or the password', () async {
      for (final status in [400, 401, 403, 404, 409, 422, 500]) {
        final error = await errorFor(
          http.Response('{"detail": "Generic message"}', status),
        );
        for (final text in [error.toString(), error.message]) {
          expect(text, isNot(contains(_token)), reason: '$status');
          expect(text, isNot(contains(_password)), reason: '$status');
          expect(text, isNot(contains('Bearer')), reason: '$status');
        }
      }
    });

    test('a 401 does not modify the token store', () async {
      final (:client, requests: _, :store) = _setUp(
        (_) async => http.Response('{"detail": "Invalid"}', 401),
        session: _session(),
      );

      await expectLater(
        client.get('/api/auth/me', authenticated: true),
        throwsA(isA<UnauthorizedException>()),
      );
      expect(store.session, _session());
      expect(store.writes, 0);
      expect(store.clears, 0);
    });
  });

  group('network failures', () {
    test('timeout -> NetworkException(isTimeout: true)', () async {
      final (:client, requests: _, store: _) = _setUp(
        (_) => Future.delayed(
          const Duration(milliseconds: 200),
          () => http.Response('{}', 200),
        ),
        timeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        client.get('/api/health'),
        throwsA(
          isA<NetworkException>().having((e) => e.isTimeout, 'isTimeout', true),
        ),
      );
    });

    test('ClientException -> NetworkException without the URL', () async {
      final (:client, requests: _, store: _) = _setUp(
        (request) =>
            throw http.ClientException('connection refused', request.url),
        baseUrl: Uri.parse('https://internal-host.example'),
      );

      try {
        await client.get('/api/health');
        fail('expected NetworkException');
      } on NetworkException catch (error) {
        expect(error.isTimeout, isFalse);
        expect(error.toString(), isNot(contains('internal-host.example')));
      }
    });
  });

  test('the client never prints anything', () async {
    final printed = <String?>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message);
    addTearDown(() => debugPrint = original);

    final (:client, requests: _, store: _) = _setUp(
      (_) async => http.Response('{"detail": "Invalid"}', 401),
      session: _session(),
    );
    await client
        .post('/api/auth/login', body: {'password': _password})
        .then((_) {}, onError: (Object _) {});
    await client
        .get('/api/auth/me', authenticated: true)
        .then((_) {}, onError: (Object _) {});

    expect(printed, isEmpty);
  });
}
