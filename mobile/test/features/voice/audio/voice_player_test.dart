import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/voice/audio/voice_audio_errors.dart';
import 'package:jarvis/features/voice/audio/voice_player.dart';

/// Fake native side of `audioplayers`; the real AudioPlayer talks to it.
class FakeAudioplayersPlatform extends AudioplayersPlatformInterface {
  final List<String> calls = [];
  final List<String> created = [];
  final Map<String, StreamController<AudioEvent>> _events = {};
  final List<({String playerId, Uint8List bytes, String? mimeType})> sources =
      [];
  bool throwOnResume = false;
  bool throwOnStop = false;

  StreamController<AudioEvent> _controller(String playerId) =>
      _events.putIfAbsent(playerId, StreamController<AudioEvent>.broadcast);

  /// Natural end of playback for [playerId].
  void complete(String playerId) =>
      _controller(playerId)
          .add(const AudioEvent(eventType: AudioEventType.complete));

  /// A platform error for [playerId].
  void error(String playerId) => _controller(playerId).addError(
    PlatformException(code: 'AndroidAudioError', message: 'native secret text'),
  );

  @override
  Future<void> create(String playerId) async {
    created.add(playerId);
    calls.add('create');
  }

  @override
  Stream<AudioEvent> getEventStream(String playerId) =>
      _controller(playerId).stream;

  @override
  Future<void> setSourceBytes(
    String playerId,
    Uint8List bytes, {
    String? mimeType,
  }) async {
    calls.add('setSourceBytes');
    sources.add((playerId: playerId, bytes: bytes, mimeType: mimeType));
    _controller(playerId).add(
      const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true),
    );
  }

  @override
  Future<void> setSourceUrl(
    String playerId,
    String url, {
    bool? isLocal,
    String? mimeType,
  }) => throw UnsupportedError('URL and file sources are never used');

  @override
  Future<void> resume(String playerId) async {
    calls.add('resume');
    if (throwOnResume) {
      throw PlatformException(code: 'x', message: 'native secret text');
    }
  }

  @override
  Future<void> stop(String playerId) async {
    calls.add('stop');
    if (throwOnStop) {
      throw PlatformException(code: 'x', message: 'native secret text');
    }
  }

  @override
  Future<void> release(String playerId) async => calls.add('release');

  @override
  Future<void> dispose(String playerId) async {
    calls.add('dispose');
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> pause(String playerId) async {}
  @override
  Future<void> seek(String playerId, Duration position) async {}
  @override
  Future<void> setBalance(String playerId, double balance) async {}
  @override
  Future<void> setVolume(String playerId, double volume) async {}
  @override
  Future<void> setReleaseMode(String playerId, ReleaseMode releaseMode) async {}
  @override
  Future<void> setPlaybackRate(String playerId, double playbackRate) async {}
  @override
  Future<void> setAudioContext(
    String playerId,
    AudioContext audioContext,
  ) async {}
  @override
  Future<void> setPlayerMode(String playerId, PlayerMode playerMode) async {}
  @override
  Future<int?> getDuration(String playerId) async => null;
  @override
  Future<int?> getCurrentPosition(String playerId) async => null;
  @override
  Future<void> emitLog(String playerId, String message) async {}
  @override
  Future<void> emitError(String playerId, String code, String message) async {}
}

/// Fake of the package's separate global platform. AudioPlayer creation awaits
/// its init() before registering the player, so it must be faked too.
class FakeGlobalAudioplayersPlatform
    extends GlobalAudioplayersPlatformInterface {
  int inits = 0;

  @override
  Future<void> init() async => inits++;

  @override
  Future<void> setGlobalAudioContext(AudioContext ctx) async {}

  @override
  Future<void> emitGlobalLog(String message) async {}

  @override
  Future<void> emitGlobalError(String code, String message) async {}

  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => const Stream.empty();
}

final _mp3 = Uint8List.fromList([0xFF, 0xF3, 0x84, 0xC4, 1, 2, 3, 4]);

late FakeAudioplayersPlatform platform;

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Starts play() and records how it ends, without awaiting it.
({Future<void> future, List<Object?> outcome}) startPlay(
  VoicePlayer player,
  Uint8List mp3,
) {
  final outcome = <Object?>[];
  final future = player.play(mp3);
  future.then<void>((_) => outcome.add('completed'), onError: outcome.add);
  return (future: future, outcome: outcome);
}

Matcher failedWith(VoicePlayerFailure failure) =>
    isA<VoicePlayerException>().having((e) => e.failure, 'failure', failure);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final originalPlatform = AudioplayersPlatformInterface.instance;
  final originalGlobalPlatform = GlobalAudioplayersPlatformInterface.instance;
  final originalLogLevel = AudioLogger.logLevel;
  late FakeGlobalAudioplayersPlatform globalPlatform;

  setUp(() {
    platform = FakeAudioplayersPlatform();
    globalPlatform = FakeGlobalAudioplayersPlatform();
    AudioplayersPlatformInterface.instance = platform;
    GlobalAudioplayersPlatformInterface.instance = globalPlatform;
    AudioLogger.logLevel = AudioLogLevel.error; // the package default
  });

  tearDown(() {
    AudioplayersPlatformInterface.instance = originalPlatform;
    GlobalAudioplayersPlatformInterface.instance = originalGlobalPlatform;
    AudioLogger.logLevel = originalLogLevel;
  });

  test(
    'the real AudioPlayer initialises through both fake platforms',
    () async {
      final player = AudioplayersVoicePlayer();
      final (:future, outcome: _) = startPlay(player, _mp3);
      await settle();

      expect(globalPlatform.inits, greaterThanOrEqualTo(1));
      expect(platform.calls.first, 'create');
      platform.complete(platform.created.single);
      await future;
    },
  );

  test('creating the adapter switches package logging off', () {
    AudioplayersVoicePlayer();

    expect(AudioLogger.logLevel, AudioLogLevel.none);
  });

  test('plays the exact bytes as audio/mpeg from memory', () async {
    final player = AudioplayersVoicePlayer();

    final (:future, outcome: _) = startPlay(player, _mp3);
    await settle();

    final [source] = platform.sources;
    expect(source.bytes, _mp3);
    expect(source.mimeType, 'audio/mpeg');
    expect(platform.calls, containsAllInOrder(['setSourceBytes', 'resume']));
    platform.complete(source.playerId);
    await future;
  });

  test('play stays pending after playback starts until it completes', () async {
    final player = AudioplayersVoicePlayer();

    final (:future, :outcome) = startPlay(player, _mp3);
    await settle();
    expect(platform.calls, contains('resume'));
    expect(outcome, isEmpty); // started, not finished

    platform.complete(platform.created.single);
    await future;
    expect(outcome, ['completed']);
    await settle();
    expect(platform.calls, contains('dispose')); // the player is released
  });

  test('a platform error fails the playback', () async {
    final player = AudioplayersVoicePlayer();

    final (:future, outcome: _) = startPlay(player, _mp3);
    await settle();
    platform.error(platform.created.single);

    await expectLater(
      future,
      throwsA(failedWith(VoicePlayerFailure.playbackFailed)),
    );
  });

  test('a failing native start fails the playback', () async {
    platform.throwOnResume = true;
    final player = AudioplayersVoicePlayer();

    await expectLater(
      player.play(_mp3),
      throwsA(failedWith(VoicePlayerFailure.playbackFailed)),
    );
    await settle();
    expect(platform.calls, contains('dispose'));
  });

  test('stop settles the active playback as stopped and releases it', () async {
    final player = AudioplayersVoicePlayer();
    final (:future, outcome: _) = startPlay(player, _mp3);
    await settle();

    await player.stop();

    await expectLater(future, throwsA(failedWith(VoicePlayerFailure.stopped)));
    await settle();
    expect(platform.calls, containsAllInOrder(['stop', 'dispose']));
  });

  test('a failing native stop still settles the playback', () async {
    platform.throwOnStop = true;
    final player = AudioplayersVoicePlayer();
    final (:future, outcome: _) = startPlay(player, _mp3);
    await settle();

    await player.stop();

    await expectLater(future, throwsA(failedWith(VoicePlayerFailure.stopped)));
  });

  test('stop when idle is safe and idempotent', () async {
    final player = AudioplayersVoicePlayer();

    await player.stop();
    await player.stop();

    expect(platform.calls, isEmpty);
  });

  test('overlapping play is rejected as busy', () async {
    final player = AudioplayersVoicePlayer();
    final (:future, outcome: _) = startPlay(player, _mp3);
    await settle();

    await expectLater(
      player.play(_mp3),
      throwsA(failedWith(VoicePlayerFailure.busy)),
    );

    platform.complete(platform.created.single);
    await future; // the first playback is unaffected
  });

  test('each playback uses a fresh player; a late completion cannot reach a newer one', () async {
    final player = AudioplayersVoicePlayer();
    final first = startPlay(player, _mp3);
    await settle();
    final firstId = platform.created.single;
    await player.stop();
    await expectLater(
      first.future,
      throwsA(failedWith(VoicePlayerFailure.stopped)),
    );

    final second = startPlay(player, _mp3);
    await settle();
    final secondId = platform.created.last;
    expect(secondId, isNot(firstId));

    platform.complete(firstId); // late event from the stopped player
    await settle();
    expect(second.outcome, isEmpty);

    platform.complete(secondId);
    await second.future;
    expect(second.outcome, ['completed']);
  });

  test('completion and stop racing settle exactly once', () async {
    final player = AudioplayersVoicePlayer();
    final (:future, :outcome) = startPlay(player, _mp3);
    await settle();

    platform.complete(platform.created.single);
    await player.stop();
    await settle();

    expect(outcome, hasLength(1));
  });

  test(
    'dispose settles an active playback, releases it, and is idempotent',
    () async {
      final player = AudioplayersVoicePlayer();
      final (:future, outcome: _) = startPlay(player, _mp3);
      await settle();

      await player.dispose();
      await player.dispose();

      await expectLater(
        future,
        throwsA(failedWith(VoicePlayerFailure.stopped)),
      );
      await settle();
      expect(platform.calls, contains('dispose'));
      await expectLater(
        player.play(_mp3),
        throwsA(failedWith(VoicePlayerFailure.disposed)),
      );
    },
  );

  test('exceptions carry only the failure kind', () {
    for (final failure in VoicePlayerFailure.values) {
      expect(
        VoicePlayerException(failure).toString(),
        'VoicePlayerException(${failure.name})',
      );
    }
  });

  test('the platform error text never reaches the caller', () async {
    final player = AudioplayersVoicePlayer();
    final (:future, outcome: _) = startPlay(player, _mp3);
    await settle();
    platform.error(platform.created.single);

    try {
      await future;
      fail('expected VoicePlayerException');
    } on VoicePlayerException catch (error) {
      expect(error.toString(), 'VoicePlayerException(playbackFailed)');
      expect(error.toString(), isNot(contains('secret')));
    }
  });
}
