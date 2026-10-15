import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/voice/audio/voice_audio_errors.dart';
import 'package:jarvis/features/voice/audio/voice_audio_format.dart';
import 'package:jarvis/features/voice/audio/voice_recorder.dart';
import 'package:record/record.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

/// Fake native side of the `record` plugin; the real AudioRecorder talks to it.
class FakeRecordPlatform extends RecordPlatform {
  final List<String> calls = [];
  final List<RecordConfig> configs = [];
  bool permission = true;
  bool throwOnPermission = false;
  bool throwOnStart = false;
  bool throwOnStop = false;
  bool throwOnCancel = false;
  StreamController<Uint8List>? _audio;
  void Function(RecordConfig config)? onConfigChanged;

  /// Simulates the native side reporting an adjusted configuration.
  void reportConfig(RecordConfig config) => onConfigChanged?.call(config);

  @override
  void setOnConfigChanged(
    String recorderId,
    void Function(RecordConfig config)? handler,
  ) => onConfigChanged = handler;

  void emit(List<int> chunk) => _audio!.add(Uint8List.fromList(chunk));
  void fail() => _audio!.addError(Exception('native secret text'));

  @override
  Future<void> create(String recorderId) async => calls.add('create');

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async {
    calls.add('hasPermission(request: $request)');
    if (throwOnPermission) throw Exception('native secret text');
    return permission;
  }

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    calls.add('startStream');
    if (throwOnStart) throw Exception('native secret text');
    configs.add(config);
    _audio = StreamController<Uint8List>();
    return _audio!.stream;
  }

  @override
  Future<String?> stop(String recorderId) async {
    calls.add('stop');
    if (throwOnStop) throw Exception('native secret text');
    await _audio?.close();
    return null;
  }

  @override
  Future<void> cancel(String recorderId) async {
    calls.add('cancel');
    if (throwOnCancel) throw Exception('native secret text');
    await _audio?.close();
  }

  @override
  Future<void> dispose(String recorderId) async => calls.add('dispose');

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) => throw UnsupportedError('file recording is never used');

  @override
  Future<void> pause(String recorderId) async {}
  @override
  Future<void> resume(String recorderId) async {}
  @override
  Future<bool> isRecording(String recorderId) async => false;
  @override
  Future<bool> isPaused(String recorderId) async => false;
  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -160, max: -160);
  @override
  Future<bool> isEncoderSupported(
    String recorderId,
    AudioEncoder encoder,
  ) async => true;
  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async =>
      const [];
}

/// A controllable monotonic clock for the mono guard.
class FakeElapsed {
  Duration now = Duration.zero;
  Duration call() => now;
}

late FakeRecordPlatform platform;

({RecordVoiceRecorder recorder, FakeElapsed elapsed, List<String> limits})
setUpRecorder() {
  final elapsed = FakeElapsed();
  final limits = <String>[];
  return (
    recorder: RecordVoiceRecorder(startTimer: () => elapsed.call),
    elapsed: elapsed,
    limits: limits,
  );
}

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Uint8List pcmOf(Uint8List wav) => Uint8List.sublistView(wav, 44);

Future<VoiceRecorderFailure> failureOf(Future<Object?> future) async {
  try {
    await future;
  } on VoiceRecorderException catch (error) {
    return error.failure;
  }
  fail('expected VoiceRecorderException');
}

void main() {
  setUp(() {
    platform = FakeRecordPlatform();
    RecordPlatform.instance = platform;
  });

  group('configuration', () {
    test(
      'records 16 kHz mono PCM16 for speech recognition, nothing default',
      () async {
        final (:recorder, elapsed: _, limits: _) = setUpRecorder();

        await recorder.start(onLimitReached: () {});

        final [config] = platform.configs;
        expect(config.encoder, AudioEncoder.pcm16bits);
        expect(config.sampleRate, 16000);
        expect(config.numChannels, 1);
        expect(config.autoGain, isFalse);
        expect(config.echoCancel, isFalse);
        expect(config.noiseSuppress, isFalse);
        expect(
          config.androidConfig.audioSource,
          AndroidAudioSource.voiceRecognition,
        );
        expect(config.androidConfig.manageBluetooth, isFalse);
        expect(config.androidConfig.useLegacy, isFalse);
        await recorder.cancel();
      },
    );

    test('the native recorder is created lazily', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();
      await settle();
      expect(platform.calls, isEmpty);

      await recorder.ensurePermission();

      expect(platform.calls.first, 'create');
    });
  });

  group('permission', () {
    test('granted', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();

      expect(await recorder.ensurePermission(), isTrue);
      expect(platform.calls, contains('hasPermission(request: true)'));
    });

    test('denied (including "don\'t ask again")', () async {
      platform.permission = false;
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();

      expect(await recorder.ensurePermission(), isFalse);
    });

    test('a platform failure counts as not granted', () async {
      platform.throwOnPermission = true;
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();

      expect(await recorder.ensurePermission(), isFalse);
    });
  });

  group('recording', () {
    test('chunks are joined unchanged into a WAV', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();
      await recorder.start(onLimitReached: () {});

      platform
        ..emit([1, 2, 3]) // odd chunk boundaries do not matter
        ..emit([4, 5, 6, 7, 8])
        ..emit(List.generate(100, (i) => i));
      await settle();
      final wav = await recorder.stop();

      expect(pcmOf(wav), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        ...List.generate(100, (i) => i),
      ]);
      expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
      expect(ByteData.sublistView(wav).getUint32(40, Endian.little), 108);
    });

    test(
      'a trailing half sample is dropped and nothing else changes',
      () async {
        final (:recorder, elapsed: _, limits: _) = setUpRecorder();
        await recorder.start(onLimitReached: () {});

        platform.emit([10, 20, 30, 40, 50]);
        await settle();
        final wav = await recorder.stop();

        expect(pcmOf(wav), [10, 20, 30, 40]);
      },
    );

    test(
      'a very short recording is still returned (policy is the caller\'s)',
      () async {
        final (:recorder, elapsed: _, limits: _) = setUpRecorder();
        await recorder.start(onLimitReached: () {});

        platform.emit([1, 2]);
        await settle();

        expect(pcmOf(await recorder.stop()), [1, 2]);
      },
    );

    test('stop releases the buffer: the next recording starts empty', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();
      await recorder.start(onLimitReached: () {});
      platform.emit([1, 2, 3, 4]);
      await settle();
      await recorder.stop();

      await recorder.start(onLimitReached: () {});
      platform.emit([9, 9]);
      await settle();

      expect(pcmOf(await recorder.stop()), [9, 9]);
    });

    test('cancel discards everything', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();
      await recorder.start(onLimitReached: () {});
      platform.emit([1, 2, 3, 4]);
      await settle();

      await recorder.cancel();

      expect(platform.calls, contains('cancel'));
      expect(
        await failureOf(recorder.stop()),
        VoiceRecorderFailure.notRecording,
      );
      await recorder.start(onLimitReached: () {});
      platform.emit([5, 6]);
      await settle();
      expect(pcmOf(await recorder.stop()), [5, 6]);
    });

    test('cancel when idle is safe', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();

      await recorder.cancel();

      expect(platform.calls, isNot(contains('cancel')));
    });
  });

  group('maximum length', () {
    const max = VoiceAudioFormat.maxPcmBytes;

    test('a crossing chunk is trimmed to exactly 960,000 bytes; later chunks ignored', () async {
      final (:recorder, :elapsed, limits: _) = setUpRecorder();
      elapsed.now = const Duration(seconds: 30);
      var limitCalls = 0;
      await recorder.start(onLimitReached: () => limitCalls++);

      platform
        ..emit(List.filled(max - 10, 1))
        ..emit(List.generate(40, (i) => 100 + i)) // crosses the cap
        ..emit(List.filled(5000, 7)); // after the cap
      await settle();
      final wav = await recorder.stop();

      final pcm = pcmOf(wav);
      expect(pcm.length, max);
      expect(wav.length, 960044);
      expect(pcm.sublist(max - 10), List.generate(10, (i) => 100 + i));
      expect(limitCalls, 1);
    });

    test(
      'exactly 960,000 bytes signals the limit once and keeps everything',
      () async {
        final (:recorder, :elapsed, limits: _) = setUpRecorder();
        elapsed.now = const Duration(seconds: 30);
        var limitCalls = 0;
        await recorder.start(onLimitReached: () => limitCalls++);

        platform
          ..emit(List.filled(max ~/ 2, 1))
          ..emit(List.filled(max ~/ 2, 2))
          ..emit([3, 3]);
        await settle();

        expect(pcmOf(await recorder.stop()).length, max);
        expect(limitCalls, 1);
      },
    );

    test('the default limit timer is 30 seconds', () {
      expect(RecordVoiceRecorder().maxDuration, const Duration(seconds: 30));
    });

    test('the limit timer signals once', () async {
      final recorder = RecordVoiceRecorder(
        maxDuration: const Duration(milliseconds: 50),
      );
      var limitCalls = 0;
      await recorder.start(onLimitReached: () => limitCalls++);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(limitCalls, 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(limitCalls, 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(limitCalls, 1);
      await recorder.cancel();
    });

    test('the limit timer is cancelled by stop', () async {
      final recorder = RecordVoiceRecorder(
        maxDuration: const Duration(milliseconds: 50),
      );
      var limitCalls = 0;
      await recorder.start(onLimitReached: () => limitCalls++);
      platform.emit([1, 2]);
      await settle();
      await recorder.stop();

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(limitCalls, 0);
    });

    test(
      'the byte cap and the timer together still signal only once',
      () async {
        final recorder = RecordVoiceRecorder(
          maxDuration: const Duration(milliseconds: 50),
          startTimer: () =>
              () => const Duration(seconds: 30),
        );
        var limitCalls = 0;
        await recorder.start(onLimitReached: () => limitCalls++);
        platform.emit(Uint8List(max + 2));
        await settle();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(limitCalls, 1);
        expect(pcmOf(await recorder.stop()).length, max);
      },
    );
  });

  group('mono sanity guard', () {
    Future<VoiceRecorderFailure?> recordAt(
      Duration duration,
      int totalBytes, {
      int chunks = 10,
    }) async {
      final (:recorder, :elapsed, limits: _) = setUpRecorder();
      await recorder.start(onLimitReached: () {});
      final per = (totalBytes ~/ chunks) & ~1;
      for (var i = 0; i < chunks; i++) {
        platform.emit(
          Uint8List(i == chunks - 1 ? totalBytes - per * (chunks - 1) : per),
        );
      }
      await settle();
      elapsed.now = duration;
      try {
        await recorder.stop();
        return null;
      } on VoiceRecorderException catch (error) {
        return error.failure;
      }
    }

    test('normal mono-rate delivery is accepted', () async {
      expect(await recordAt(const Duration(seconds: 5), 32000 * 5), isNull);
    });

    test('bursty but plausible mono delivery is accepted', () async {
      // Half a second of audio buffered ahead of the timer, in two big bursts.
      expect(
        await recordAt(
          const Duration(seconds: 2),
          32000 * 2 + 16000,
          chunks: 2,
        ),
        isNull,
      );
    });

    // The tolerance is 1.5x the mono rate plus half a second of audio.
    int allowance(Duration elapsed) =>
        (32000 * elapsed.inMicroseconds / Duration.microsecondsPerSecond * 1.5)
            .floor() +
        16000;

    test('delivery within the documented tolerance is accepted', () async {
      const elapsed = Duration(seconds: 4);
      // 1.4x the mono rate plus the slack: generous buffering, still mono.
      expect(
        await recordAt(elapsed, (32000 * 4 * 1.4).floor() + 16000),
        isNull,
      );
      // Exactly at the allowance.
      expect(await recordAt(elapsed, allowance(elapsed) & ~1), isNull);
    });

    test('delivery just past the tolerance is rejected', () async {
      const elapsed = Duration(seconds: 4);

      expect(
        await recordAt(elapsed, (allowance(elapsed) + 2) & ~1),
        VoiceRecorderFailure.unsupportedAudio,
      );
    });

    test('stereo-rate delivery is rejected as unsupported audio', () async {
      expect(
        await recordAt(const Duration(seconds: 3), 64000 * 3),
        VoiceRecorderFailure.unsupportedAudio,
      );
    });

    test(
      'stereo-rate delivery is caught even when it hits the byte cap',
      () async {
        // Stereo fills 960,000 bytes in 15 s.
        expect(
          await recordAt(const Duration(seconds: 16), 64000 * 16),
          VoiceRecorderFailure.unsupportedAudio,
        );
      },
    );

    test('very short recordings are never judged', () async {
      // Even a burst well above the mono rate, under the observation window.
      expect(await recordAt(const Duration(milliseconds: 900), 64000), isNull);
    });

    test(
      'a rejected recording is discarded and the exception leaks nothing',
      () async {
        final (:recorder, :elapsed, limits: _) = setUpRecorder();
        await recorder.start(onLimitReached: () {});
        platform.emit(Uint8List(64000 * 3));
        await settle();
        elapsed.now = const Duration(seconds: 3);

        try {
          await recorder.stop();
          fail('expected VoiceRecorderException');
        } on VoiceRecorderException catch (error) {
          expect(error.toString(), 'VoiceRecorderException(unsupportedAudio)');
        }
        // Nothing kept: a new recording starts empty.
        await recorder.start(onLimitReached: () {});
        platform.emit([1, 2]);
        await settle();
        elapsed.now = const Duration(seconds: 3);
        expect(pcmOf(await recorder.stop()), [1, 2]);
      },
    );
  });

  group('adjusted format reported by the platform', () {
    for (final (name, adjusted) in [
      ('stereo', RecordVoiceRecorder.config.copyWith(numChannels: 2)),
      ('48 kHz', RecordVoiceRecorder.config.copyWith(sampleRate: 48000)),
      (
        'another encoder',
        RecordVoiceRecorder.config.copyWith(encoder: AudioEncoder.wav),
      ),
    ]) {
      test('$name is rejected even at a plausible byte rate', () async {
        final (:recorder, :elapsed, limits: _) = setUpRecorder();
        await recorder.start(onLimitReached: () {});
        platform.reportConfig(adjusted);
        platform.emit(Uint8List(32000));
        await settle();
        elapsed.now = const Duration(seconds: 1);

        expect(
          await failureOf(recorder.stop()),
          VoiceRecorderFailure.unsupportedAudio,
        );
      });
    }

    test('a report that keeps the requested format is accepted', () async {
      final (:recorder, :elapsed, limits: _) = setUpRecorder();
      await recorder.start(onLimitReached: () {});
      platform.reportConfig(
        RecordVoiceRecorder.config.copyWith(bitRate: 64000),
      );
      platform.emit([1, 2]);
      await settle();
      elapsed.now = const Duration(seconds: 1);

      expect(pcmOf(await recorder.stop()), [1, 2]);
    });

    for (final ending in ['stop', 'cancel']) {
      test('the callback is unregistered after $ending', () async {
        final (:recorder, elapsed: _, limits: _) = setUpRecorder();
        await recorder.start(onLimitReached: () {});
        platform.emit([1, 2]);
        await settle();

        if (ending == 'stop') {
          await recorder.stop();
        } else {
          await recorder.cancel();
        }

        expect(platform.onConfigChanged, isNull);
      });
    }

    test('the callback is unregistered after a failed start', () async {
      platform.throwOnStart = true;
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();

      await failureOf(recorder.start(onLimitReached: () {}));

      expect(platform.onConfigChanged, isNull);
    });

    test('the callback is registered before the stream starts', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();

      await recorder.start(onLimitReached: () {});

      expect(platform.onConfigChanged, isNotNull);
      await recorder.cancel();
    });
  });

  group('failures', () {
    test('start failure', () async {
      platform.throwOnStart = true;
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();

      expect(
        await failureOf(recorder.start(onLimitReached: () {})),
        VoiceRecorderFailure.startFailed,
      );
      platform.throwOnStart = false;
      await recorder.start(onLimitReached: () {}); // usable again
      await recorder.cancel();
    });

    test('start while recording', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();
      await recorder.start(onLimitReached: () {});

      expect(
        await failureOf(recorder.start(onLimitReached: () {})),
        VoiceRecorderFailure.alreadyRecording,
      );
      await recorder.cancel();
    });

    test('a stream error discards the recording', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();
      await recorder.start(onLimitReached: () {});
      platform
        ..emit([1, 2])
        ..fail();
      await settle();

      expect(
        await failureOf(recorder.stop()),
        VoiceRecorderFailure.captureFailed,
      );
    });

    test('stop failure discards the recording', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();
      await recorder.start(onLimitReached: () {});
      platform.emit([1, 2]);
      await settle();
      platform.throwOnStop = true;

      expect(await failureOf(recorder.stop()), VoiceRecorderFailure.stopFailed);
      expect(
        await failureOf(recorder.stop()),
        VoiceRecorderFailure.notRecording,
      );
    });

    test('stop without recording', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();

      expect(
        await failureOf(recorder.stop()),
        VoiceRecorderFailure.notRecording,
      );
    });

    test('a native cancel failure is absorbed', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();
      await recorder.start(onLimitReached: () {});
      platform.throwOnCancel = true;

      await recorder.cancel(); // no exception
    });

    test('exceptions carry only the failure kind', () {
      for (final failure in VoiceRecorderFailure.values) {
        expect(
          VoiceRecorderException(failure).toString(),
          'VoiceRecorderException(${failure.name})',
        );
      }
    });
  });

  group('dispose', () {
    test('releases the native recorder and is idempotent', () async {
      final (:recorder, elapsed: _, limits: _) = setUpRecorder();
      await recorder.start(onLimitReached: () {});

      await recorder.dispose();
      await recorder.dispose();

      expect(platform.calls.where((call) => call == 'dispose'), hasLength(1));
      expect(platform.calls, contains('cancel'));
      expect(await recorder.ensurePermission(), isFalse);
      expect(
        await failureOf(recorder.start(onLimitReached: () {})),
        VoiceRecorderFailure.disposed,
      );
      expect(await failureOf(recorder.stop()), VoiceRecorderFailure.disposed);
    });
  });
}
