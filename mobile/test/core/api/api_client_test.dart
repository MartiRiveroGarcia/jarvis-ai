import 'dart:async';
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

    test('5xx keeps a short JSON detail, outside toString()', () async {
      final error = await errorFor(
        http.Response('{"detail": "Server detail text"}', 503),
      );

      expect(error, isA<ServerException>());
      expect((error as ServerException).detail, 'Server detail text');
      expect(error.message, 'The server encountered an error');
      expect(error.toString(), isNot(contains('Server detail text')));
    });

    test('5xx without a JSON detail has a null detail', () async {
      for (final body in ['<html>Bad gateway</html>', '', '{"other": 1}']) {
        final error = await errorFor(http.Response(body, 502));

        expect((error as ServerException).detail, isNull, reason: body);
      }
    });

    test('5xx detail is truncated like other details', () async {
      final error = await errorFor(
        http.Response(jsonEncode({'detail': 'x' * 1000}), 503),
      );

      expect((error as ServerException).detail!.length, 200);
    });

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

  group('timeouts', () {
    Future<http.Response> slow(http.Request _) => Future.delayed(
      const Duration(milliseconds: 200),
      () => http.Response('{}', 200),
    );

    test('the default timeout is 15 seconds', () {
      final client = ApiClient(
        baseUrl: _base,
        httpClient: MockClient((_) => _json({})),
        tokenStore: InMemoryTokenStore(),
      );

      expect(client.timeout, const Duration(seconds: 15));
    });

    test('calls without an override use the client timeout', () async {
      final (:client, requests: _, store: _) = _setUp(
        slow,
        timeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        client.post('/api/auth/login', body: {}),
        throwsA(isA<NetworkException>()),
      );
    });

    test('a longer per-request timeout lets a slow request finish', () async {
      final (:client, requests: _, store: _) = _setUp(
        slow,
        timeout: const Duration(milliseconds: 10),
      );

      expect(
        await client.post(
          '/api/auth/login',
          body: {},
          timeout: const Duration(seconds: 5),
        ),
        <String, Object?>{},
      );
    });

    test(
      'a shorter per-request timeout applies to that request only',
      () async {
        final (:client, requests: _, store: _) = _setUp(slow);

        await expectLater(
          client.post(
            '/api/auth/login',
            body: {},
            timeout: const Duration(milliseconds: 10),
          ),
          throwsA(
            isA<NetworkException>().having(
              (e) => e.isTimeout,
              'isTimeout',
              true,
            ),
          ),
        );
        expect(await client.post('/api/auth/login', body: {}), isEmpty);
      },
    );
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

  group('postBinary', () {
    final payload = Uint8List.fromList(List.generate(1024, (i) => i % 256));
    final audio = Uint8List.fromList(List.generate(300, (i) => 255 - i % 256));
    const maxBytes = 1000;

    ({
      ApiClient client,
      List<({http.BaseRequest request, Uint8List body})> sent,
      InMemoryTokenStore store,
      List<int> pulled,
    })
    binarySetUp(
      http.StreamedResponse Function(List<int> pulled) respond, {
      AuthSession? session,
      Duration timeout = const Duration(seconds: 15),
    }) {
      final sent = <({http.BaseRequest request, Uint8List body})>[];
      final pulled = <int>[];
      final store = InMemoryTokenStore(session);
      final client = ApiClient(
        baseUrl: _base,
        httpClient: MockClient.streaming((request, bodyStream) async {
          sent.add((request: request, body: await bodyStream.toBytes()));
          return respond(pulled);
        }),
        tokenStore: store,
        timeout: timeout,
      );
      return (client: client, sent: sent, store: store, pulled: pulled);
    }

    /// A response whose body arrives in [chunks]; records each chunk pulled.
    http.StreamedResponse streamed(
      List<int> pulled,
      List<List<int>> chunks, {
      int status = 200,
      Map<String, String> headers = const {'content-type': 'audio/mpeg'},
      bool declareLength = true,
    }) {
      Stream<List<int>> body() async* {
        for (final chunk in chunks) {
          pulled.add(chunk.length);
          yield chunk;
        }
      }

      final total = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
      return http.StreamedResponse(
        body(),
        status,
        contentLength: declareLength ? total : null,
        headers: headers,
      );
    }

    Future<BinaryResponse> post(
      ApiClient client, {
      bool authenticated = true,
    }) => client.postBinary(
      '/api/voice/respond',
      body: payload,
      contentType: 'audio/wav',
      accept: 'audio/mpeg',
      maxResponseBytes: maxBytes,
      authenticated: authenticated,
    );

    test('sends the exact bytes and headers, with Bearer auth', () async {
      final (:client, :sent, store: _, pulled: _) = binarySetUp(
        (pulled) => streamed(pulled, [audio]),
        session: _session(),
      );

      await post(client);

      final [(:request, :body)] = sent;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://api.example.com/api/voice/respond',
      );
      expect(body, payload); // every byte value 0..255, unchanged
      expect(request.headers, {
        'Accept': 'audio/mpeg',
        'Content-Type': 'audio/wav',
        'Authorization': 'Bearer $_token',
      });
    });

    test('an unauthenticated binary request sends no Authorization', () async {
      final (:client, :sent, store: _, pulled: _) = binarySetUp(
        (pulled) => streamed(pulled, [audio]),
        session: _session(),
      );

      await post(client, authenticated: false);

      expect(sent.single.request.headers.containsKey('Authorization'), isFalse);
    });

    test('without a stored session nothing is sent', () async {
      final (:client, :sent, store: _, pulled: _) = binarySetUp(
        (pulled) => streamed(pulled, [audio]),
      );

      await expectLater(post(client), throwsA(isA<UnauthorizedException>()));
      expect(sent, isEmpty);
    });

    test('returns the exact bytes and the parsed media type', () async {
      final (:client, sent: _, store: _, pulled: _) = binarySetUp(
        (pulled) => streamed(
          pulled,
          [audio.sublist(0, 100), audio.sublist(100)],
          headers: {'content-type': 'AUDIO/MPEG; charset=x'},
        ),
        session: _session(),
      );

      final response = await post(client);

      expect(response.bytes, audio);
      expect(response.mediaType, 'audio/mpeg');
    });

    test('a missing content type is reported as null', () async {
      final (:client, sent: _, store: _, pulled: _) = binarySetUp(
        (pulled) => streamed(pulled, [audio], headers: const {}),
        session: _session(),
      );

      expect((await post(client)).mediaType, isNull);
    });

    test('exactly the maximum size is accepted', () async {
      final (:client, sent: _, store: _, pulled: _) = binarySetUp(
        (pulled) => streamed(pulled, [List.filled(maxBytes, 7)]),
        session: _session(),
      );

      expect((await post(client)).bytes.length, maxBytes);
    });

    test(
      'a declared Content-Length over the cap is rejected before reading',
      () async {
        final (:client, sent: _, store: _, :pulled) = binarySetUp(
          (pulled) => streamed(pulled, [
            for (var i = 0; i < 10; i++) List.filled(200, 1),
          ]),
          session: _session(),
        );

        await expectLater(
          post(client),
          throwsA(
            isA<UnexpectedResponseException>().having(
              (e) => e.statusCode,
              'status',
              200,
            ),
          ),
        );
        expect(pulled.length, lessThan(10));
        expect(
          pulled.fold<int>(0, (a, b) => a + b),
          lessThanOrEqualTo(maxBytes),
        );
      },
    );

    test('an undeclared body over the cap is rejected while reading', () async {
      final (:client, sent: _, store: _, :pulled) = binarySetUp(
        (pulled) => streamed(pulled, [
          for (var i = 0; i < 10; i++) List.filled(400, 1),
        ], declareLength: false),
        session: _session(),
      );

      await expectLater(
        post(client),
        throwsA(isA<UnexpectedResponseException>()),
      );
      expect(pulled, hasLength(3)); // 1200 > 1000: reading stopped there
    });

    group('error bodies', () {
      test(
        'a small JSON error keeps the shared status/detail mapping',
        () async {
          final cases = <int, Matcher>{
            401: isA<UnauthorizedException>(),
            413: isA<UnexpectedResponseException>().having(
              (e) => e.statusCode,
              's',
              413,
            ),
            415: isA<UnexpectedResponseException>().having(
              (e) => e.statusCode,
              's',
              415,
            ),
            422: isA<ValidationException>().having(
              (e) => e.message,
              'detail',
              'Nope',
            ),
            429: isA<UnexpectedResponseException>().having(
              (e) => e.statusCode,
              's',
              429,
            ),
            503: isA<ServerException>().having(
              (e) => e.detail,
              'detail',
              'Nope',
            ),
            504: isA<ServerException>().having((e) => e.statusCode, 's', 504),
          };
          for (final MapEntry(key: status, value: matcher) in cases.entries) {
            final (:client, sent: _, store: _, pulled: _) = binarySetUp(
              (pulled) => streamed(
                pulled,
                [utf8.encode('{"detail": "Nope"}')],
                status: status,
                headers: const {'content-type': 'application/json'},
              ),
              session: _session(),
            );
            await expectLater(
              post(client),
              throwsA(matcher),
              reason: '$status',
            );
          }
        },
      );

      test(
        'an error body over 64 KiB is bounded and becomes status-only',
        () async {
          final big = utf8.encode('{"detail": "${'x' * 70000}"}');
          final (:client, sent: _, store: _, :pulled) = binarySetUp(
            (pulled) => streamed(
              pulled,
              [
                for (var i = 0; i < big.length; i += 8192)
                  big.sublist(i, (i + 8192).clamp(0, big.length)),
              ],
              status: 503,
              declareLength: false,
            ),
            session: _session(),
          );

          try {
            await post(client);
            fail('expected ServerException');
          } on ServerException catch (error) {
            expect(error.statusCode, 503);
            expect(error.detail, isNull);
            expect(error.toString(), isNot(contains('xxxx')));
          }
          expect(
            pulled.fold<int>(0, (a, b) => a + b),
            lessThan(64 * 1024 + 8192 + 1),
          );
        },
      );

      test('a non-JSON error body becomes status-only', () async {
        final (:client, sent: _, store: _, pulled: _) = binarySetUp(
          (pulled) => streamed(pulled, [
            utf8.encode('<html>Traceback: token=$_token</html>'),
          ], status: 422),
          session: _session(),
        );

        try {
          await post(client);
          fail('expected ValidationException');
        } on ValidationException catch (error) {
          expect(error.message, 'Invalid request');
          expect(error.toString(), isNot(contains('Traceback')));
          expect(error.toString(), isNot(contains(_token)));
        }
      });

      test('a 2xx other than 200 is unexpected', () async {
        final (:client, sent: _, store: _, pulled: _) = binarySetUp(
          (pulled) => streamed(pulled, [audio], status: 201),
          session: _session(),
        );

        await expectLater(
          post(client),
          throwsA(
            isA<UnexpectedResponseException>().having(
              (e) => e.statusCode,
              's',
              201,
            ),
          ),
        );
      });
    });

    test('ClientException -> NetworkException without the URL', () async {
      final store = InMemoryTokenStore(_session());
      final client = ApiClient(
        baseUrl: Uri.parse('https://internal-host.example'),
        httpClient: MockClient.streaming(
          (request, _) => throw http.ClientException('refused', request.url),
        ),
        tokenStore: store,
      );

      try {
        await post(client);
        fail('expected NetworkException');
      } on NetworkException catch (error) {
        expect(error.isTimeout, isFalse);
        expect(error.toString(), isNot(contains('internal-host.example')));
      }
    });

    testWidgets('the per-request timeout applies (fake clock)', (tester) async {
      final never = Completer<http.StreamedResponse>();
      final client = ApiClient(
        baseUrl: _base,
        httpClient: MockClient.streaming((_, _) => never.future),
        tokenStore: InMemoryTokenStore(_session()),
      );

      Object? error;
      unawaited(
        client
            .postBinary(
              '/api/voice/respond',
              body: payload,
              contentType: 'audio/wav',
              accept: 'audio/mpeg',
              maxResponseBytes: maxBytes,
              authenticated: true,
              timeout: const Duration(seconds: 100),
            )
            .then<void>((_) {}, onError: (Object e) => error = e),
      );

      await tester.pump(const Duration(seconds: 99));
      expect(error, isNull); // past the 15 s default, still waiting
      await tester.pump(const Duration(seconds: 2));
      expect(
        error,
        isA<NetworkException>().having((e) => e.isTimeout, 'timeout', true),
      );
    });

    test(
      'no exception or response string contains the token or body',
      () async {
        final (:client, sent: _, store: _, pulled: _) = binarySetUp(
          (pulled) => streamed(pulled, [audio]),
          session: _session(),
        );

        final response = await post(client);

        expect(response.toString(), 'BinaryResponse(<hidden>)');
        for (final status in [401, 413, 422, 500, 503]) {
          final (client: failing, sent: _, store: _, pulled: _) = binarySetUp(
            (pulled) => streamed(pulled, [
              utf8.encode('{"detail": "Generic"}'),
            ], status: status),
            session: _session(),
          );
          try {
            await post(failing);
            fail('expected ApiException');
          } on ApiException catch (error) {
            expect(
              error.toString(),
              isNot(contains(_token)),
              reason: '$status',
            );
            expect(
              error.toString(),
              isNot(contains('Bearer')),
              reason: '$status',
            );
          }
        }
      },
    );
  });
}
