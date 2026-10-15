import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/providers.dart';
import 'package:jarvis/features/auth/application/auth_controller.dart';
import 'package:jarvis/features/auth/application/auth_state.dart';
import 'package:jarvis/features/voice/application/voice_conversation_controller.dart';
import 'package:jarvis/features/voice/application/voice_conversation_state.dart';
import 'package:jarvis/features/voice/audio/voice_audio_errors.dart';
import 'package:jarvis/features/voice/audio/voice_player.dart';
import 'package:jarvis/features/voice/audio/voice_recorder.dart';
import 'package:jarvis/features/voice/data/voice_api.dart';

import '../../../support/fake_auth_api.dart';
import '../../../support/in_memory_token_store.dart';
import '../voice_test_fakes.dart';

typedef _Harness = ({
  ProviderContainer container,
  VoiceConversationController controller,
  FakeVoiceRecorder recorder,
  FakeVoicePlayer player,
  FakeVoiceApi api,
  InMemoryTokenStore store,
  List<VoiceConversationState> states,
});

/// A signed-in container. With [listen], a listener records every published
/// state; without it, nothing watches the controller.
Future<_Harness> _setUp({bool listen = true}) async {
  final recorder = FakeVoiceRecorder();
  final player = FakeVoicePlayer();
  final api = FakeVoiceApi();
  final store = InMemoryTokenStore(testSession());
  final container = ProviderContainer.test(
    retry: (_, _) => null,
    overrides: [
      authApiProvider.overrideWithValue(FakeAuthApi()),
      tokenStoreProvider.overrideWithValue(store),
      clockProvider.overrideWithValue(() => DateTime.utc(2026, 10, 5)),
      voiceRecorderProvider.overrideWithValue(recorder),
      voicePlayerProvider.overrideWithValue(player),
      voiceApiProvider.overrideWithValue(api),
    ],
  );
  container.read(authControllerProvider);
  await _flush();
  expect(container.read(authControllerProvider), isA<AuthAuthenticated>());

  final states = <VoiceConversationState>[];
  if (listen) {
    container.listen(
      voiceConversationControllerProvider,
      (_, next) => states.add(next),
      fireImmediately: true,
    );
  }
  return (
    container: container,
    controller: container.read(voiceConversationControllerProvider.notifier),
    recorder: recorder,
    player: player,
    api: api,
    store: store,
    states: states,
  );
}

Future<void> _flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

VoiceConversationState _state(_Harness h) =>
    h.container.read(voiceConversationControllerProvider);

/// Starts a recording and waits until it is really recording.
Future<void> _record(_Harness h) async {
  await h.controller.start();
  expect(_state(h), const VoiceRecording());
}

/// Records, stops and waits until the reply is playing.
Future<void> _toPlaying(_Harness h) async {
  await _record(h);
  unawaited(h.controller.stop());
  await _flush();
  expect(_state(h), const VoicePlaying());
}

/// Records, stops, and leaves the request pending.
Future<Completer<Uint8List>> _toProcessing(_Harness h) async {
  final gate = h.api.gate = Completer<Uint8List>();
  await _record(h);
  unawaited(h.controller.stop());
  await _flush();
  expect(_state(h), const VoiceProcessing());
  expect(h.api.requests, hasLength(1));
  return gate;
}

const _idle = VoiceIdle();
VoiceIdle _failed(VoiceConversationFailure failure) => VoiceIdle(failure);

void main() {
  group('happy path', () {
    test('starts idle', () async {
      final h = await _setUp();

      expect(h.states, [_idle]);
    });

    test('idle -> recording -> processing -> playing -> idle', () async {
      final h = await _setUp();

      await h.controller.start();
      unawaited(h.controller.stop());
      await _flush();
      h.player.complete();
      await _flush();

      expect(h.states, [
        _idle,
        const VoiceRecording(),
        const VoiceProcessing(),
        const VoicePlaying(),
        _idle,
      ]);
      expect(h.recorder.calls, ['ensurePermission', 'start', 'stop']);
    });

    test('the exact recording is sent and the exact reply played', () async {
      final h = await _setUp();

      await _toPlaying(h);

      expect(h.api.requests.single, same(h.recorder.wav));
      expect(h.player.played.single, same(h.api.reply));
    });

    test('a second conversation works after the first ends', () async {
      final h = await _setUp();
      await _toPlaying(h);
      h.player.complete();
      await _flush();

      await _toPlaying(h);

      expect(h.api.requests, hasLength(2));
    });
  });

  group('private starting phase', () {
    test('state is not recording while permission is pending', () async {
      final h = await _setUp();
      final permission = h.recorder.permissionGate = Completer<bool>();

      unawaited(h.controller.start());
      await _flush();

      expect(_state(h), _idle);
      expect(h.recorder.calls, ['ensurePermission']);
      permission.complete(true);
      await _flush();
      expect(_state(h), const VoiceRecording());
      expect(h.states, [_idle, const VoiceRecording()]);
    });

    test('state is not recording while the native start is pending', () async {
      final h = await _setUp();
      final started = h.recorder.startGate = Completer<void>();

      unawaited(h.controller.start());
      await _flush();

      expect(h.recorder.calls, ['ensurePermission', 'start']);
      expect(_state(h), _idle);
      started.complete();
      await _flush();
      expect(_state(h), const VoiceRecording());
    });

    test('a duplicate start during permission is ignored', () async {
      final h = await _setUp();
      final permission = h.recorder.permissionGate = Completer<bool>();

      unawaited(h.controller.start());
      await _flush();
      await h.controller.start();
      permission.complete(true);
      await _flush();

      expect(h.recorder.count('ensurePermission'), 1);
      expect(h.recorder.count('start'), 1);
      expect(_state(h), const VoiceRecording());
    });

    test('a duplicate start during the native start is ignored', () async {
      final h = await _setUp();
      final started = h.recorder.startGate = Completer<void>();

      unawaited(h.controller.start());
      await _flush();
      await h.controller.start();
      started.complete();
      await _flush();

      expect(h.recorder.count('start'), 1);
    });

    test(
      'stop while permission is pending abandons the start silently',
      () async {
        final h = await _setUp();
        final permission = h.recorder.permissionGate = Completer<bool>();
        unawaited(h.controller.start());
        await _flush();

        await h.controller.stop();
        expect(_state(h), _idle);

        permission.complete(true); // granted after the release
        await _flush();

        expect(h.recorder.calls, ['ensurePermission']); // never started
        expect(h.api.requests, isEmpty);
        expect(h.states, [_idle]); // no recording, no tooShort
      },
    );

    test(
      'stop while the native start is pending cancels it exactly once',
      () async {
        final h = await _setUp();
        final started = h.recorder.startGate = Completer<void>();
        unawaited(h.controller.start());
        await _flush();

        await h.controller.stop();
        expect(_state(h), _idle);
        expect(h.recorder.count('cancel'), 0); // not while the start runs

        started.complete();
        await _flush();

        expect(h.recorder.count('cancel'), 1);
        expect(h.states, [_idle]); // recording was never published
        expect(h.api.requests, isEmpty);
      },
    );

    test(
      'cancel while the native start is pending cancels it exactly once',
      () async {
        final h = await _setUp();
        final started = h.recorder.startGate = Completer<void>();
        unawaited(h.controller.start());
        await _flush();

        await h.controller.cancel();
        expect(h.recorder.count('cancel'), 0);
        started.complete();
        await _flush();

        expect(h.recorder.count('cancel'), 1);
        expect(h.states, [_idle]);
      },
    );

    test(
      'a new start waits for an abandoned native start to be cancelled',
      () async {
        final h = await _setUp();
        final first = h.recorder.startGate = Completer<void>();
        unawaited(h.controller.start());
        await _flush();
        await h.controller.stop();

        h.recorder.startGate = null;
        unawaited(h.controller.start());
        await _flush();
        expect(h.recorder.count('start'), 1); // still waiting

        first.complete();
        await _flush();

        expect(h.recorder.calls, [
          'ensurePermission',
          'start',
          'ensurePermission',
          'cancel',
          'start',
        ]);
        expect(_state(h), const VoiceRecording());
      },
    );

    test('a stale start failure publishes nothing', () async {
      final h = await _setUp();
      final started = h.recorder.startGate = Completer<void>();
      h.recorder.startError = const VoiceRecorderException(
        VoiceRecorderFailure.startFailed,
      );
      unawaited(h.controller.start());
      await _flush();
      await h.controller.stop();

      started.complete();
      await _flush();

      expect(h.states, [_idle]);
      expect(h.recorder.count('cancel'), 0);
    });
  });

  group('start', () {
    test('permission denied', () async {
      final h = await _setUp();
      h.recorder.permission = false;

      await h.controller.start();

      expect(h.states, [
        _idle,
        _failed(VoiceConversationFailure.permissionDenied),
      ]);
      expect(h.recorder.calls, ['ensurePermission']);
    });

    test('a permission check that throws is unexpected', () async {
      final h = await _setUp();
      h.recorder.permissionError = StateError('platform text');

      await h.controller.start();

      expect(_state(h), _failed(VoiceConversationFailure.unexpected));
    });

    test('start failed -> microphoneFailed', () async {
      final h = await _setUp();
      h.recorder.startError = const VoiceRecorderException(
        VoiceRecorderFailure.startFailed,
      );

      await h.controller.start();

      expect(_state(h), _failed(VoiceConversationFailure.microphoneFailed));
      expect(h.recorder.count('cancel'), 0);
    });

    for (final failure in [
      VoiceRecorderFailure.alreadyRecording,
      VoiceRecorderFailure.disposed,
    ]) {
      test('start ${failure.name} -> unexpected, recorder cancelled', () async {
        final h = await _setUp();
        h.recorder.startError = VoiceRecorderException(failure);

        await h.controller.start();

        expect(_state(h), _failed(VoiceConversationFailure.unexpected));
        expect(h.recorder.count('cancel'), 1);
      });
    }

    test('start is ignored while recording', () async {
      final h = await _setUp();
      await _record(h);

      await h.controller.start();

      expect(h.recorder.count('start'), 1);
      expect(_state(h), const VoiceRecording());
    });

    test('start is ignored while processing', () async {
      final h = await _setUp();
      await _toProcessing(h);

      await h.controller.start();

      expect(_state(h), const VoiceProcessing());
      expect(h.recorder.count('start'), 1);
      expect(h.recorder.count('ensurePermission'), 1);
    });

    test('start clears a previous failure while still idle', () async {
      final h = await _setUp();
      h.recorder.permission = false;
      await h.controller.start();
      h.recorder.permission = true;
      final permission = h.recorder.permissionGate = Completer<bool>();

      unawaited(h.controller.start());
      await _flush();

      expect(_state(h), _idle);
      permission.complete(true);
      await _flush();
      expect(h.states, [
        _idle,
        _failed(VoiceConversationFailure.permissionDenied),
        _idle,
        const VoiceRecording(),
      ]);
    });
  });

  group('start while playing', () {
    test('stops the reply first, then records', () async {
      final h = await _setUp();
      await _toPlaying(h);

      await h.controller.start();

      expect(h.player.calls, ['play', 'stop']);
      expect(h.recorder.calls.sublist(3), ['ensurePermission', 'start']);
      expect(_state(h), const VoiceRecording());
      expect(h.states.sublist(3), [
        const VoicePlaying(),
        _idle,
        const VoiceRecording(),
      ]);
    });

    test('invalidates the old playback before awaiting player.stop', () async {
      final h = await _setUp();
      await _toPlaying(h);
      final stopping = h.player.stopGate = Completer<void>();

      unawaited(h.controller.start());
      await _flush();
      expect(_state(h), _idle); // published before stop completes
      expect(h.recorder.count('ensurePermission'), 1); // not yet

      // The old playback ends naturally while stop is still running.
      h.player.complete();
      await _flush();
      expect(_state(h), _idle);

      stopping.complete();
      await _flush();
      expect(_state(h), const VoiceRecording());
      expect(h.api.requests, hasLength(1));
    });

    test('the old playback ending as stopped is ignored', () async {
      final h = await _setUp();
      await _toPlaying(h);

      await h.controller.start();
      await _flush();

      expect(_state(h), const VoiceRecording());
      expect(
        h.states.whereType<VoiceIdle>().every((s) => s.failure == null),
        isTrue,
      );
    });

    test('a second start during the transition is ignored', () async {
      final h = await _setUp();
      await _toPlaying(h);
      final stopping = h.player.stopGate = Completer<void>();
      unawaited(h.controller.start());
      await _flush();

      await h.controller.start();
      stopping.complete();
      await _flush();

      expect(h.player.count('stop'), 1);
      expect(h.recorder.count('ensurePermission'), 2);
      expect(h.recorder.count('start'), 2);
      expect(_state(h), const VoiceRecording());
    });

    test('stop during the transition abandons the new start', () async {
      final h = await _setUp();
      await _toPlaying(h);
      final stopping = h.player.stopGate = Completer<void>();
      unawaited(h.controller.start());
      await _flush();

      await h.controller.stop();
      stopping.complete();
      await _flush();

      expect(_state(h), _idle);
      expect(h.recorder.count('start'), 1); // only the first conversation's
    });
  });

  group('stop', () {
    test('stop is ignored when idle, processing or playing', () async {
      final h = await _setUp();
      await h.controller.stop();
      expect(h.recorder.count('stop'), 0);

      final gate = await _toProcessing(h);
      await h.controller.stop();
      expect(h.recorder.count('stop'), 1);

      gate.complete(h.api.reply);
      await _flush();
      expect(_state(h), const VoicePlaying());
      await h.controller.stop();
      expect(h.recorder.count('stop'), 1);
      expect(_state(h), const VoicePlaying());
    });

    test('processing is published before the recorder stops', () async {
      final h = await _setUp();
      await _record(h);
      final stopped = h.recorder.stopGate = Completer<Uint8List>();

      unawaited(h.controller.stop());

      expect(_state(h), const VoiceProcessing());
      stopped.complete(h.recorder.wav);
      await _flush();
      expect(_state(h), const VoicePlaying());
    });

    final recorderFailures = {
      VoiceRecorderFailure.captureFailed:
          VoiceConversationFailure.microphoneFailed,
      VoiceRecorderFailure.stopFailed:
          VoiceConversationFailure.microphoneFailed,
      VoiceRecorderFailure.startFailed:
          VoiceConversationFailure.microphoneFailed,
      VoiceRecorderFailure.unsupportedAudio:
          VoiceConversationFailure.unsupportedAudio,
      VoiceRecorderFailure.notRecording: VoiceConversationFailure.unexpected,
      VoiceRecorderFailure.alreadyRecording:
          VoiceConversationFailure.unexpected,
      VoiceRecorderFailure.disposed: VoiceConversationFailure.unexpected,
    };
    for (final MapEntry(key: from, value: to) in recorderFailures.entries) {
      test('recorder stop ${from.name} -> ${to.name}, nothing sent', () async {
        final h = await _setUp();
        await _record(h);
        h.recorder.stopError = VoiceRecorderException(from);

        await h.controller.stop();

        expect(_state(h), _failed(to));
        expect(h.api.requests, isEmpty);
      });
    }

    test('every recorder failure kind is mapped', () {
      expect(
        recorderFailures.keys,
        unorderedEquals(VoiceRecorderFailure.values),
      );
    });

    test('a recorder stop that throws something else is unexpected', () async {
      final h = await _setUp();
      await _record(h);
      h.recorder.stopError = StateError('platform text');

      await h.controller.stop();

      expect(_state(h), _failed(VoiceConversationFailure.unexpected));
    });
  });

  group('minimum duration', () {
    test('9598 PCM bytes is too short and is not sent', () async {
      final h = await _setUp();
      h.recorder.wav = wavOf(9598);
      await _record(h);

      await h.controller.stop();

      expect(_state(h), _failed(VoiceConversationFailure.tooShort));
      expect(h.api.requests, isEmpty);
    });

    test('exactly 9600 PCM bytes (0.3 s) is sent', () async {
      final h = await _setUp();
      h.recorder.wav = wavOf(9600);
      await _record(h);

      unawaited(h.controller.stop());
      await _flush();

      expect(h.api.requests.single, same(h.recorder.wav));
    });

    test('an empty WAV (header only) is too short', () async {
      final h = await _setUp();
      h.recorder.wav = wavOf(0);
      await _record(h);

      await h.controller.stop();

      expect(_state(h), _failed(VoiceConversationFailure.tooShort));
      expect(h.api.requests, isEmpty);
    });

    test('a malformed WAV smaller than its header is unexpected', () async {
      final h = await _setUp();
      h.recorder.wav = Uint8List(10);
      await _record(h);

      await h.controller.stop();

      expect(_state(h), _failed(VoiceConversationFailure.unexpected));
      expect(h.api.requests, isEmpty);
    });
  });

  group('recording limit', () {
    test('the limit stops and sends the recording', () async {
      final h = await _setUp();
      await _record(h);

      h.recorder.reachLimit();
      expect(_state(h), const VoiceProcessing());
      await _flush();

      expect(h.api.requests, hasLength(1));
      expect(_state(h), const VoicePlaying());
    });

    test('limit then manual stop: one recorder stop, one request', () async {
      final h = await _setUp();
      await _record(h);
      h.recorder.stopGate = Completer<Uint8List>();

      h.recorder.reachLimit();
      await h.controller.stop().timeout(const Duration(seconds: 1));
      h.recorder.stopGate!.complete(h.recorder.wav);
      await _flush();

      expect(h.recorder.count('stop'), 1);
      expect(h.api.requests, hasLength(1));
    });

    test('manual stop then limit: one recorder stop, one request', () async {
      final h = await _setUp();
      await _record(h);
      h.recorder.stopGate = Completer<Uint8List>();

      unawaited(h.controller.stop());
      h.recorder.reachLimit();
      h.recorder.stopGate!.complete(h.recorder.wav);
      await _flush();

      expect(h.recorder.count('stop'), 1);
      expect(h.api.requests, hasLength(1));
    });

    test("an old recording's limit cannot stop a new one", () async {
      final h = await _setUp();
      await _record(h);
      final staleLimit = h.recorder.limitCallback;
      await h.controller.cancel();

      await _record(h);
      staleLimit();
      await _flush();

      expect(_state(h), const VoiceRecording());
      expect(h.recorder.count('stop'), 0);
    });
  });

  group('API failures', () {
    final apiFailures = {
      VoiceFailure.invalidAudio: VoiceConversationFailure.invalidAudio,
      VoiceFailure.noSpeech: VoiceConversationFailure.noSpeech,
      VoiceFailure.rejected: VoiceConversationFailure.rejected,
      VoiceFailure.busy: VoiceConversationFailure.busy,
      VoiceFailure.notAvailable: VoiceConversationFailure.notAvailable,
      VoiceFailure.unavailable: VoiceConversationFailure.unavailable,
      VoiceFailure.tooSlow: VoiceConversationFailure.tooSlow,
      VoiceFailure.network: VoiceConversationFailure.network,
      VoiceFailure.unexpected: VoiceConversationFailure.unexpected,
    };
    for (final MapEntry(key: from, value: to) in apiFailures.entries) {
      test('${from.name} -> ${to.name}, nothing played', () async {
        final h = await _setUp();
        h.api.error = VoiceException(from);
        await _record(h);

        await h.controller.stop();

        expect(_state(h), _failed(to));
        expect(h.player.played, isEmpty);
      });
    }

    test('every API failure except sessionExpired is mapped', () {
      expect({
        ...apiFailures.keys,
        VoiceFailure.sessionExpired,
      }, unorderedEquals(VoiceFailure.values));
    });

    test('a non-VoiceException error is unexpected', () async {
      final h = await _setUp();
      h.api.error = StateError('backend text');
      await _record(h);

      await h.controller.stop();

      expect(_state(h), _failed(VoiceConversationFailure.unexpected));
    });
  });

  group('session expiry', () {
    test(
      'clears the session, goes idle without a failure, plays nothing',
      () async {
        final h = await _setUp();
        h.api.error = const VoiceException(VoiceFailure.sessionExpired);
        await _record(h);

        await h.controller.stop();
        await _flush();

        expect(h.store.session, isNull);
        expect(
          h.container.read(authControllerProvider),
          isA<AuthUnauthenticated>(),
        );
        expect(h.states, [
          _idle,
          const VoiceRecording(),
          const VoiceProcessing(),
          _idle,
        ]);
        expect(h.player.played, isEmpty);
      },
    );

    test('a stale sessionExpired does not touch the session', () async {
      final h = await _setUp();
      final gate = await _toProcessing(h);
      await h.controller.cancel();

      gate.completeError(const VoiceException(VoiceFailure.sessionExpired));
      await _flush();

      expect(h.store.session, isNotNull);
      expect(
        h.container.read(authControllerProvider),
        isA<AuthAuthenticated>(),
      );
    });

    test(
      'a failing session removal still ends idle without a failure',
      () async {
        final h = await _setUp();
        h.store.failClear = true;
        h.api.error = const VoiceException(VoiceFailure.sessionExpired);
        await _record(h);

        await h.controller.stop();
        await _flush();

        expect(
          h.container.read(authControllerProvider),
          isA<AuthSignOutFailed>(),
        );
        expect(_state(h), _idle);
      },
    );
  });

  group('auth listener', () {
    test(
      'works with no widget watching: logout while processing resets at once',
      () async {
        final h = await _setUp(listen: false);
        final gate = h.api.gate = Completer<Uint8List>();
        await h.controller.start();
        unawaited(h.controller.stop());
        await _flush();
        expect(_state(h), const VoiceProcessing());

        await h.container
            .read(authControllerProvider.notifier)
            .signOutOnThisDevice();

        expect(_state(h), _idle); // before the request completes
        gate.complete(h.api.reply);
        await _flush();
        expect(_state(h), _idle);
        expect(h.player.played, isEmpty);
      },
    );

    test('logout while recording cancels the recorder', () async {
      final h = await _setUp();
      await _record(h);

      await h.container
          .read(authControllerProvider.notifier)
          .signOutOnThisDevice();
      await _flush();

      expect(_state(h), _idle);
      expect(h.recorder.count('cancel'), 1);
    });

    test('logout while playing stops the player', () async {
      final h = await _setUp();
      await _toPlaying(h);

      await h.container
          .read(authControllerProvider.notifier)
          .signOutOnThisDevice();
      await _flush();

      expect(_state(h), _idle);
      expect(h.player.count('stop'), 1);
    });

    test('logout keeps no failure from an earlier conversation', () async {
      final h = await _setUp();
      h.recorder.permission = false;
      await h.controller.start();

      await h.container
          .read(authControllerProvider.notifier)
          .signOutOnThisDevice();

      expect(_state(h), _idle);
    });
  });

  group('player', () {
    test('a playback failure -> playbackFailed', () async {
      final h = await _setUp();
      await _toPlaying(h);

      h.player.fail(VoicePlayerFailure.playbackFailed);
      await _flush();

      expect(_state(h), _failed(VoiceConversationFailure.playbackFailed));
    });

    test('a current playback ending as stopped is not an error', () async {
      final h = await _setUp();
      await _toPlaying(h);

      h.player.fail(VoicePlayerFailure.stopped);
      await _flush();

      expect(_state(h), _idle);
    });

    for (final failure in [
      VoicePlayerFailure.busy,
      VoicePlayerFailure.disposed,
    ]) {
      test('play ${failure.name} -> unexpected, player stopped', () async {
        final h = await _setUp();
        h.player.playError = VoicePlayerException(failure);
        await _record(h);

        await h.controller.stop();

        expect(_state(h), _failed(VoiceConversationFailure.unexpected));
        expect(h.player.count('stop'), 1);
      });
    }

    test('a play that throws something else is unexpected', () async {
      final h = await _setUp();
      h.player.playError = StateError('platform text');
      await _record(h);

      await h.controller.stop();

      expect(_state(h), _failed(VoiceConversationFailure.unexpected));
    });

    test('a stale playback failure publishes nothing', () async {
      final h = await _setUp();
      await _toPlaying(h);
      h.player.stopGate = Completer<void>();
      unawaited(h.controller.cancel());
      expect(_state(h), _idle);

      h.player.fail(VoicePlayerFailure.playbackFailed);
      h.player.stopGate!.complete();
      await _flush();

      expect(_state(h), _idle);
    });
  });

  group('cancel', () {
    test('when idle is a no-op', () async {
      final h = await _setUp();

      await h.controller.cancel();

      expect(h.recorder.calls, isEmpty);
      expect(h.player.calls, isEmpty);
      expect(h.states, [_idle]);
    });

    test('clears a failure', () async {
      final h = await _setUp();
      h.recorder.permission = false;
      await h.controller.start();

      await h.controller.cancel();

      expect(_state(h), _idle);
    });

    test('while recording discards the recording', () async {
      final h = await _setUp();
      await _record(h);

      await h.controller.cancel();

      expect(_state(h), _idle);
      expect(h.recorder.count('cancel'), 1);
      expect(h.recorder.count('stop'), 0);
      expect(h.api.requests, isEmpty);
    });

    test(
      'while processing is idle at once and ignores the late reply',
      () async {
        final h = await _setUp();
        final gate = await _toProcessing(h);

        unawaited(h.controller.cancel());
        expect(_state(h), _idle); // before the request completes

        gate.complete(h.api.reply);
        await _flush();

        expect(_state(h), _idle);
        expect(h.player.played, isEmpty);
        expect(h.states.last, _idle);
      },
    );

    test('while processing ignores a late error', () async {
      final h = await _setUp();
      final gate = await _toProcessing(h);
      await h.controller.cancel();

      gate.completeError(const VoiceException(VoiceFailure.network));
      await _flush();

      expect(_state(h), _idle);
    });

    test('while the recorder is stopping ignores the late recording', () async {
      final h = await _setUp();
      await _record(h);
      final stopped = h.recorder.stopGate = Completer<Uint8List>();
      unawaited(h.controller.stop());

      await h.controller.cancel();
      stopped.complete(h.recorder.wav);
      await _flush();

      expect(_state(h), _idle);
      expect(h.api.requests, isEmpty);
    });

    test('while playing is idle at once and stops the player', () async {
      final h = await _setUp();
      await _toPlaying(h);
      h.player.stopGate = Completer<void>();

      unawaited(h.controller.cancel());
      expect(_state(h), _idle); // before the player has stopped

      h.player.stopGate!.complete();
      await _flush();
      expect(h.player.count('stop'), 1);
      expect(_state(h), _idle);
    });

    test('cleanup failures are not reported', () async {
      final h = await _setUp();
      await _toPlaying(h);
      h.recorder.cancelError = StateError('x');
      h.player.stopError = StateError('x');

      await h.controller.cancel();

      expect(_state(h), _idle);
    });

    test('is idempotent', () async {
      final h = await _setUp();
      await _record(h);

      await h.controller.cancel();
      await h.controller.cancel();

      expect(h.recorder.count('cancel'), 1);
      expect(_state(h), _idle);
    });
  });

  group('disposal', () {
    test(
      'disposing mid-request releases audio and ignores the reply',
      () async {
        final h = await _setUp();
        final gate = await _toProcessing(h);

        h.container.dispose();
        await _flush();
        gate.complete(h.api.reply);
        await _flush();

        expect(h.player.played, isEmpty);
        expect(h.recorder.count('cancel'), 1);
      },
    );

    test('disposing mid-start cancels the started recorder', () async {
      final h = await _setUp();
      final started = h.recorder.startGate = Completer<void>();
      unawaited(h.controller.start());
      await _flush();

      h.container.dispose();
      started.complete();
      await _flush();

      expect(h.recorder.count('cancel'), 1);
    });
  });

  group('privacy', () {
    test('states print only their kind', () {
      expect(const VoiceRecording().toString(), 'VoiceRecording()');
      expect(const VoiceProcessing().toString(), 'VoiceProcessing()');
      expect(const VoicePlaying().toString(), 'VoicePlaying()');
      expect(_idle.toString(), 'VoiceIdle()');
      for (final failure in VoiceConversationFailure.values) {
        expect(VoiceIdle(failure).toString(), 'VoiceIdle(${failure.name})');
      }
    });

    test('idle states compare by failure', () {
      expect(_idle, const VoiceIdle());
      expect(
        _failed(VoiceConversationFailure.network),
        isNot(_failed(VoiceConversationFailure.busy)),
      );
      expect(_failed(VoiceConversationFailure.network), isNot(_idle));
    });
  });
}
