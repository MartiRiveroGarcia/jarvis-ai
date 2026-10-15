import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis/core/api/api_client.dart';
import 'package:jarvis/core/storage/auth_session.dart';
import 'package:jarvis/features/voice/data/voice_api.dart';

import '../../../support/fake_auth_api.dart' show testToken;
import '../../../support/in_memory_token_store.dart';

const _host = 'jarvis-api.example.com';
final _wav = Uint8List.fromList([
  ...ascii.encode('RIFF'),
  ...List.generate(512, (i) => i % 256),
  ...ascii.encode('WAVSECRET'),
]);
final _mp3 = Uint8List.fromList([
  0xFF,
  0xF3,
  0x84,
  0xC4,
  ...ascii.encode('MP3SECRET'),
]);

typedef _Sent = ({http.BaseRequest request, Uint8List body});

({VoiceApi api, List<_Sent> sent}) _setUp(
  FutureOr<http.StreamedResponse> Function() respond, {
  bool signedIn = true,
  Duration clientTimeout = const Duration(seconds: 15),
}) {
  final sent = <_Sent>[];
  final client = ApiClient(
    baseUrl: Uri.parse('https://$_host'),
    httpClient: MockClient.streaming((request, bodyStream) async {
      sent.add((request: request, body: await bodyStream.toBytes()));
      return respond();
    }),
    tokenStore: InMemoryTokenStore(
      signedIn
          ? AuthSession(token: testToken, expiresAt: DateTime.utc(2030))
          : null,
    ),
    timeout: clientTimeout,
  );
  return (api: VoiceApi(client), sent: sent);
}

http.StreamedResponse _response(
  List<int> body, {
  int status = 200,
  String? contentType = 'audio/mpeg',
  bool declareLength = true,
}) => http.StreamedResponse(
  Stream.value(body),
  status,
  contentLength: declareLength ? body.length : null,
  headers: {'content-type': ?contentType},
);

http.StreamedResponse _error(int status, [String? detail]) => _response(
  utf8.encode(detail == null ? '{}' : jsonEncode({'detail': detail})),
  status: status,
  contentType: 'application/json',
);

Future<VoiceFailure> _failureFor(
  FutureOr<http.StreamedResponse> Function() respond, {
  bool signedIn = true,
}) async {
  final (:api, sent: _) = _setUp(respond, signedIn: signedIn);
  try {
    await api.respond(_wav);
  } on VoiceException catch (error) {
    return error.failure;
  }
  fail('expected VoiceException');
}

void main() {
  group('request', () {
    test(
      'POSTs the WAV unchanged with the voice headers and Bearer auth',
      () async {
        final (:api, :sent) = _setUp(() => _response(_mp3));

        await api.respond(_wav);

        final [(:request, :body)] = sent;
        expect(request.method, 'POST');
        expect(request.url.toString(), 'https://$_host/api/voice/respond');
        expect(body, _wav);
        expect(request.headers, {
          'Accept': 'audio/mpeg',
          'Content-Type': 'audio/wav',
          'Authorization': 'Bearer $testToken',
        });
      },
    );

    test('an empty WAV is sent as is (the backend validates it)', () async {
      final (:api, :sent) = _setUp(
        () => _error(422, 'The recording could not be processed'),
      );

      await expectLater(
        api.respond(Uint8List(0)),
        throwsA(isA<VoiceException>()),
      );
      expect(sent.single.body, isEmpty);
    });

    test('without a stored session nothing is sent', () async {
      final (:api, :sent) = _setUp(() => _response(_mp3), signedIn: false);

      await expectLater(
        api.respond(_wav),
        throwsA(
          isA<VoiceException>().having(
            (e) => e.failure,
            'failure',
            VoiceFailure.sessionExpired,
          ),
        ),
      );
      expect(sent, isEmpty);
    });
  });

  group('timeout', () {
    test('respondTimeout is 100 seconds', () {
      expect(VoiceApi.respondTimeout, const Duration(seconds: 100));
    });

    testWidgets('waits past 35 s and gives up at 100 s (fake clock)', (
      tester,
    ) async {
      final never = Completer<http.StreamedResponse>();
      final (:api, sent: _) = _setUp(() => never.future);

      VoiceFailure? failure;
      unawaited(
        api
            .respond(_wav)
            .then<void>(
              (_) {},
              onError: (Object error) =>
                  failure = (error as VoiceException).failure,
            ),
      );

      await tester.pump(const Duration(seconds: 36));
      expect(failure, isNull); // the text assistant's 35 s does not apply
      await tester.pump(const Duration(seconds: 63));
      expect(failure, isNull); // 99 s
      await tester.pump(const Duration(seconds: 2));
      expect(failure, VoiceFailure.tooSlow);
    });
  });

  group('success', () {
    test('returns the exact MP3 bytes', () async {
      final (:api, sent: _) = _setUp(() => _response(_mp3));

      expect(await api.respond(_wav), _mp3);
    });

    for (final type in [
      'AUDIO/MPEG',
      'audio/mpeg; codecs=mp3',
      'Audio/Mpeg ; x=y',
    ]) {
      test('accepts the media type "$type"', () async {
        final (:api, sent: _) = _setUp(
          () => _response(_mp3, contentType: type),
        );

        expect(await api.respond(_wav), _mp3);
      });
    }

    test('exactly 5 MiB is accepted', () async {
      final big = Uint8List(VoiceApi.maxResponseBytes)..[0] = 0xFF;
      final (:api, sent: _) = _setUp(() => _response(big));

      expect((await api.respond(_wav)).length, VoiceApi.maxResponseBytes);
    });
  });

  group('bad successful responses are unexpected', () {
    final cases = <String, http.StreamedResponse Function()>{
      'empty body': () => _response(const []),
      'over 5 MiB (declared)': () =>
          _response(Uint8List(VoiceApi.maxResponseBytes + 1)),
      'over 5 MiB (streamed)': () => _response(
        Uint8List(VoiceApi.maxResponseBytes + 1),
        declareLength: false,
      ),
      'missing content type': () => _response(_mp3, contentType: null),
      'audio/mp3': () => _response(_mp3, contentType: 'audio/mp3'),
      'audio/mpeg3': () => _response(_mp3, contentType: 'audio/mpeg3'),
      'audio/wav': () => _response(_mp3, contentType: 'audio/wav'),
      'audio/ogg': () => _response(_mp3, contentType: 'audio/ogg'),
      'application/octet-stream': () =>
          _response(_mp3, contentType: 'application/octet-stream'),
      'application/json': () =>
          _response(_mp3, contentType: 'application/json'),
      '201 instead of 200': () => _response(_mp3, status: 201),
    };
    for (final MapEntry(key: name, value: respond) in cases.entries) {
      test(name, () async {
        expect(await _failureFor(respond), VoiceFailure.unexpected);
      });
    }
  });

  group('failure mapping', () {
    final cases = <String, (http.StreamedResponse Function(), VoiceFailure)>{
      '401': (
        () => _error(401, 'Invalid or expired session'),
        VoiceFailure.sessionExpired,
      ),
      '413': (
        () => _error(413, 'The recording is too large'),
        VoiceFailure.invalidAudio,
      ),
      '415': (
        () => _error(415, 'The recording must be a WAV file'),
        VoiceFailure.invalidAudio,
      ),
      '422 invalid audio': (
        () => _error(422, 'The recording could not be processed'),
        VoiceFailure.invalidAudio,
      ),
      '422 no speech': (
        () => _error(422, "Jarvis didn't hear anything"),
        VoiceFailure.noSpeech,
      ),
      '422 rejected': (
        () => _error(422, "The assistant couldn't answer that request"),
        VoiceFailure.rejected,
      ),
      '422 near-miss case': (
        () => _error(422, "jarvis didn't hear anything"),
        VoiceFailure.unexpected,
      ),
      '422 near-miss punctuation': (
        () => _error(422, 'Jarvis didnt hear anything'),
        VoiceFailure.unexpected,
      ),
      '422 unknown detail': (
        () => _error(422, 'Something else'),
        VoiceFailure.unexpected,
      ),
      '422 field errors': (
        () => _response(
          utf8.encode(
            jsonEncode({
              'detail': [
                {
                  'loc': ['body'],
                  'msg': "Jarvis didn't hear anything",
                  'type': 'x',
                },
              ],
            }),
          ),
          status: 422,
          contentType: 'application/json',
        ),
        VoiceFailure.unexpected,
      ),
      '422 no body': (() => _error(422), VoiceFailure.unexpected),
      '429': (
        () => _error(429, 'The assistant is busy. Please try again shortly'),
        VoiceFailure.busy,
      ),
      '503 not available': (
        () => _error(503, 'The assistant is not available'),
        VoiceFailure.notAvailable,
      ),
      '503 temporarily unavailable': (
        () => _error(503, 'The assistant is temporarily unavailable'),
        VoiceFailure.unavailable,
      ),
      '503 near-miss': (
        () => _error(503, 'the assistant is not available'),
        VoiceFailure.unavailable,
      ),
      '503 no detail': (() => _error(503), VoiceFailure.unavailable),
      '503 HTML': (
        () => _response(
          utf8.encode('<html>busy</html>'),
          status: 503,
          contentType: 'text/html',
        ),
        VoiceFailure.unavailable,
      ),
      '504': (
        () => _error(504, 'The assistant took too long to respond'),
        VoiceFailure.tooSlow,
      ),
      '403': (() => _error(403, 'x'), VoiceFailure.unexpected),
      '409': (() => _error(409, 'x'), VoiceFailure.unexpected),
      '500': (() => _error(500), VoiceFailure.unexpected),
      '502': (() => _error(502), VoiceFailure.unexpected),
      '418': (() => _error(418), VoiceFailure.unexpected),
    };
    for (final MapEntry(key: name, value: (respond, expected))
        in cases.entries) {
      test('$name -> ${expected.name}', () async {
        expect(await _failureFor(respond), expected);
      });
    }

    test('connection failure -> network', () async {
      expect(
        await _failureFor(() => throw http.ClientException('refused')),
        VoiceFailure.network,
      );
    });
  });

  group('security', () {
    test('VoiceException carries only the failure', () async {
      final (:api, sent: _) = _setUp(
        () => _error(503, 'The assistant is not available'),
      );

      try {
        await api.respond(_wav);
        fail('expected VoiceException');
      } on VoiceException catch (error) {
        expect(error.toString(), 'VoiceException(notAvailable)');
      }
    });

    test('no failure exposes the token, audio, detail or host', () async {
      final responses = <http.StreamedResponse Function()>[
        () => _error(401, 'backend secret detail'),
        () => _error(422, 'backend secret detail'),
        () => _error(429, 'backend secret detail'),
        () => _error(503, 'backend secret detail'),
        () => _error(504, 'backend secret detail'),
        () => _response(
          utf8.encode('backend secret detail'),
          contentType: 'text/plain',
        ),
        () => throw http.ClientException(
          'backend secret detail',
          Uri.parse('https://$_host'),
        ),
      ];
      for (final respond in responses) {
        final (:api, sent: _) = _setUp(respond);
        try {
          await api.respond(_wav);
          fail('expected VoiceException');
        } on VoiceException catch (error) {
          final text = error.toString();
          for (final secret in [
            testToken,
            'Bearer',
            'backend secret detail',
            'WAVSECRET',
            'MP3SECRET',
            _host,
          ]) {
            expect(text, isNot(contains(secret)));
          }
        }
      }
    });

    test('voice data code has no UI, logging or developer imports', () {
      final sources = Directory('lib/features/voice/data')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      final forbidden = RegExp(
        r'package:flutter/(material|widgets|cupertino)|dart:developer|'
        r'debugPrint|print\(|BuildContext|package:logging',
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
