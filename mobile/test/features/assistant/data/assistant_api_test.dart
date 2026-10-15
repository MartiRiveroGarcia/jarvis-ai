import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis/core/api/api_client.dart';
import 'package:jarvis/core/storage/auth_session.dart';
import 'package:jarvis/features/assistant/data/assistant_api.dart';

import '../../../support/fake_auth_api.dart' show testToken;
import '../../../support/in_memory_token_store.dart';

const _message = 'Explain what RAG is in one short sentence.';
const _reply = 'A way to ground answers in retrieved documents.';

final _session = AuthSession(token: testToken, expiresAt: DateTime.utc(2030));

({AssistantApi api, List<http.Request> requests, InMemoryTokenStore store})
_setUp(
  Future<http.Response> Function(http.Request request) respond, {
  AuthSession? stored,
  bool signedIn = true,
  Duration clientTimeout = const Duration(seconds: 15),
}) {
  final requests = <http.Request>[];
  final store = InMemoryTokenStore(signedIn ? (stored ?? _session) : null);
  final client = ApiClient(
    baseUrl: Uri.parse('https://api.example.com'),
    httpClient: MockClient((request) {
      requests.add(request);
      return respond(request);
    }),
    tokenStore: store,
    timeout: clientTimeout,
  );
  return (api: AssistantApi(client), requests: requests, store: store);
}

// Like the backend: JSON without an explicit charset, which package:http decodes
// as UTF-8.
Future<http.Response> _json(Object? body, [int status = 200]) async =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );

Future<AssistantFailure> _failureFor(
  Future<http.Response> Function(http.Request request) respond, {
  bool signedIn = true,
}) async {
  final (:api, requests: _, store: _) = _setUp(respond, signedIn: signedIn);
  try {
    await api.respond(_message);
  } on AssistantException catch (error) {
    return error.failure;
  }
  fail('expected AssistantException');
}

void main() {
  group('request', () {
    test('POSTs exactly {"message"} to the assistant endpoint', () async {
      final (:api, :requests, store: _) = _setUp(
        (_) => _json({'reply': _reply}),
      );

      await api.respond(_message);

      final [request] = requests;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://api.example.com/api/assistant/respond',
      );
      expect(jsonDecode(request.body), {'message': _message});
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(request.headers['accept'], 'application/json');
    });

    test('sends the stored Jarvis session as the Bearer token', () async {
      final (:api, :requests, :store) = _setUp((_) => _json({'reply': _reply}));

      await api.respond(_message);

      expect(requests.single.headers['authorization'], 'Bearer $testToken');
      expect(store.reads, 1);
      // Reading the session never changes it.
      expect(store.writes, 0);
      expect(store.clears, 0);
    });

    test('sends no other credentials or headers', () async {
      final (:api, :requests, store: _) = _setUp(
        (_) => _json({'reply': _reply}),
      );

      await api.respond(_message);

      expect(requests.single.headers.keys.map((k) => k.toLowerCase()).toSet(), {
        'accept',
        'authorization',
        'content-type',
      });
    });

    test('the message is sent as given', () async {
      final (:api, :requests, store: _) = _setUp(
        (_) => _json({'reply': _reply}),
      );

      await api.respond('  ¿Qué es RAG? 🤖\nline two  ');

      expect(jsonDecode(requests.single.body), {
        'message': '  ¿Qué es RAG? 🤖\nline two  ',
      });
    });

    test('without a stored session nothing is sent', () async {
      final (:api, :requests, store: _) = _setUp(
        (_) => _json({'reply': _reply}),
        signedIn: false,
      );

      await expectLater(
        api.respond(_message),
        throwsA(
          isA<AssistantException>().having(
            (e) => e.failure,
            'failure',
            AssistantFailure.sessionExpired,
          ),
        ),
      );
      expect(requests, isEmpty);
    });
  });

  group('timeout', () {
    test('respondTimeout is 35 seconds', () {
      expect(AssistantApi.respondTimeout, const Duration(seconds: 35));
    });

    test('overrides a shorter client timeout', () async {
      final (:api, requests: _, store: _) = _setUp(
        (_) => Future.delayed(
          const Duration(milliseconds: 100),
          () => http.Response(jsonEncode({'reply': _reply}), 200),
        ),
        clientTimeout: const Duration(milliseconds: 10),
      );

      expect(await api.respond(_message), _reply);
    });

    testWidgets('gives up at 35 seconds, not before (fake clock)', (
      tester,
    ) async {
      final never = Completer<http.Response>();
      final (:api, requests: _, store: _) = _setUp((_) => never.future);

      AssistantFailure? failure;
      var done = false;
      unawaited(
        api
            .respond(_message)
            .then<void>(
              (_) => done = true,
              onError: (Object error) {
                failure = (error as AssistantException).failure;
                done = true;
              },
            ),
      );

      // Past the client's normal 15 s, still waiting.
      await tester.pump(const Duration(seconds: 34));
      expect(done, isFalse);

      await tester.pump(const Duration(seconds: 2));
      expect(done, isTrue);
      expect(failure, AssistantFailure.tooSlow);
    });
  });

  group('response shape', () {
    test('returns the reply', () async {
      final (:api, requests: _, store: _) = _setUp(
        (_) => _json({'reply': _reply}),
      );

      expect(await api.respond(_message), _reply);
    });

    test('returns the reply unchanged', () async {
      const reply = 'Line one.\n\n  Line two with ünïcode 🤖 ';
      final (:api, requests: _, store: _) = _setUp(
        (_) => _json({'reply': reply}),
      );

      expect(await api.respond(_message), reply);
    });

    final malformed = <String, http.Response>{
      'missing reply': http.Response('{}', 200),
      'null reply': http.Response('{"reply": null}', 200),
      'empty reply': http.Response('{"reply": ""}', 200),
      'whitespace-only reply': http.Response('{"reply": " \\n\\t "}', 200),
      'number reply': http.Response('{"reply": 42}', 200),
      'list reply': http.Response('{"reply": ["a"]}', 200),
      'object reply': http.Response('{"reply": {"text": "a"}}', 200),
      'extra key': http.Response('{"reply": "ok", "model": "x"}', 200),
      'misspelled key': http.Response('{"Reply": "ok"}', 200),
      'JSON array': http.Response('["ok"]', 200),
      'JSON string': http.Response('"ok"', 200),
      'invalid JSON': http.Response('{"reply": "ok"', 200),
      'empty body': http.Response('', 200),
      'no content': http.Response('', 204),
    };
    for (final MapEntry(key: name, value: response) in malformed.entries) {
      test('$name -> unexpected', () async {
        expect(
          await _failureFor((_) async => response),
          AssistantFailure.unexpected,
        );
      });
    }
  });

  group('status mapping', () {
    final cases = <String, (http.Response, AssistantFailure)>{
      '401': (
        http.Response('{"detail": "Invalid or expired session"}', 401),
        AssistantFailure.sessionExpired,
      ),
      '422 field errors': (
        http.Response(
          jsonEncode({
            'detail': [
              {
                'loc': ['body', 'message'],
                'msg': 'String should have at least 1 character',
                'type': 'string_too_short',
              },
            ],
          }),
          422,
        ),
        AssistantFailure.invalidInput,
      ),
      '422 assistant rejected': (
        http.Response(
          jsonEncode({'detail': "The assistant couldn't answer that request"}),
          422,
        ),
        AssistantFailure.rejected,
      ),
      '422 unknown single detail': (
        http.Response('{"detail": "Something else"}', 422),
        AssistantFailure.invalidInput,
      ),
      '422 without a body': (
        http.Response('', 422),
        AssistantFailure.invalidInput,
      ),
      '429': (
        http.Response(
          '{"detail": "The assistant is busy. Please try again shortly"}',
          429,
          headers: {'retry-after': '7'},
        ),
        AssistantFailure.busy,
      ),
      '429 without a body': (http.Response('', 429), AssistantFailure.busy),
      '503 not configured': (
        http.Response('{"detail": "The assistant is not available"}', 503),
        AssistantFailure.notAvailable,
      ),
      '503 temporarily unavailable': (
        http.Response(
          '{"detail": "The assistant is temporarily unavailable"}',
          503,
        ),
        AssistantFailure.unavailable,
      ),
      '503 null detail': (
        http.Response('{"detail": null}', 503),
        AssistantFailure.unavailable,
      ),
      '503 no body': (http.Response('', 503), AssistantFailure.unavailable),
      '503 HTML from a proxy': (
        http.Response('<html>Service Unavailable</html>', 503),
        AssistantFailure.unavailable,
      ),
      '503 unknown detail': (
        http.Response('{"detail": "Some future detail"}', 503),
        AssistantFailure.unavailable,
      ),
      '503 near-miss detail': (
        http.Response('{"detail": "the assistant is not available"}', 503),
        AssistantFailure.unavailable,
      ),
      '504': (
        http.Response(
          '{"detail": "The assistant took too long to respond"}',
          504,
        ),
        AssistantFailure.tooSlow,
      ),
      '500': (http.Response('', 500), AssistantFailure.unexpected),
      '502': (http.Response('', 502), AssistantFailure.unexpected),
      '403': (
        http.Response('{"detail": "x"}', 403),
        AssistantFailure.unexpected,
      ),
      '404': (
        http.Response('{"detail": "x"}', 404),
        AssistantFailure.unexpected,
      ),
      '409': (
        http.Response('{"detail": "x"}', 409),
        AssistantFailure.unexpected,
      ),
      '418': (http.Response('', 418), AssistantFailure.unexpected),
    };
    for (final MapEntry(key: name, value: (response, expected))
        in cases.entries) {
      test('$name -> ${expected.name}', () async {
        expect(await _failureFor((_) async => response), expected);
      });
    }

    test('connection failure -> network', () async {
      expect(
        await _failureFor(
          (request) => throw http.ClientException('refused', request.url),
        ),
        AssistantFailure.network,
      );
    });
  });

  group('security', () {
    test('exceptions carry only the failure kind', () async {
      final (:api, requests: _, store: _) = _setUp(
        (_) async => http.Response(
          jsonEncode({'detail': 'The assistant is not available'}),
          503,
        ),
      );

      try {
        await api.respond('my private message');
        fail('expected AssistantException');
      } on AssistantException catch (error) {
        expect(error.toString(), 'AssistantException(notAvailable)');
      }
    });

    test(
      'no failure ever exposes the token, message or backend text',
      () async {
        final responses = [
          http.Response('{"detail": "backend secret detail"}', 401),
          http.Response('{"detail": "backend secret detail"}', 422),
          http.Response('{"detail": "backend secret detail"}', 429),
          http.Response('{"detail": "backend secret detail"}', 503),
          http.Response('{"detail": "backend secret detail"}', 504),
          http.Response(
            '{"reply": "ok", "debug": "backend secret detail"}',
            200,
          ),
        ];
        for (final response in responses) {
          final (:api, requests: _, store: _) = _setUp((_) async => response);
          try {
            await api.respond('my private message');
            fail('expected AssistantException');
          } on AssistantException catch (error) {
            final text = error.toString();
            for (final secret in [
              testToken,
              'Bearer',
              'my private message',
              'backend secret detail',
              'api.example.com',
            ]) {
              expect(text, isNot(contains(secret)), reason: '$response');
            }
          }
        }
      },
    );

    test('app code contains no Azure, Foundry or model configuration', () {
      final sources = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      final forbidden = RegExp(
        r'foundry|azure|services\.ai|openai|gpt-|deployment|api[_-]?key|'
        r'client[_-]?secret',
        caseSensitive: false,
      );

      for (final file in sources) {
        expect(
          forbidden.hasMatch(file.readAsStringSync()),
          isFalse,
          reason: file.path,
        );
      }
    });
  });
}
