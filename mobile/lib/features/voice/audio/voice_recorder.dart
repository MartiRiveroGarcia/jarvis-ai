import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import 'voice_audio_errors.dart';
import 'voice_audio_format.dart';
import 'wav.dart';

/// Records one utterance at a time into memory and returns it as a WAV.
///
/// UI-independent: no widgets, no BuildContext, no files.
abstract interface class VoiceRecorder {
  /// Asks for microphone access if needed (or only checks it, when the
  /// recorder must never show the system dialog). False when not granted,
  /// including "don't ask again", which Android reports the same way.
  Future<bool> ensurePermission();

  /// Starts capturing. [onLimitReached] is called once when the 30-second
  /// limit is reached; the caller decides what to do (normally stop()).
  Future<void> start({required void Function() onLimitReached});

  /// Stops capturing and returns the recording as a WAV. Throws
  /// [VoiceRecorderException]. The adapter keeps nothing afterwards.
  Future<Uint8List> stop();

  /// Stops capturing and discards everything. Safe when not recording.
  Future<void> cancel();

  /// Releases the native recorder. Idempotent.
  Future<void> dispose();
}

final voiceRecorderProvider = Provider<VoiceRecorder>((ref) {
  final recorder = RecordVoiceRecorder();
  ref.onDispose(() => unawaited(recorder.dispose()));
  return recorder;
});

/// Monotonic elapsed time since a recording started.
typedef ElapsedTime = Duration Function();

ElapsedTime _startStopwatch() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}

/// [VoiceRecorder] backed by the `record` package's PCM stream.
class RecordVoiceRecorder implements VoiceRecorder {
  RecordVoiceRecorder({
    AudioRecorder Function()? createRecorder,
    ElapsedTime Function()? startTimer,
    this.maxDuration = VoiceAudioFormat.maxDuration,
    this.requestPermission = true,
  }) : _createRecorder = createRecorder ?? AudioRecorder.new,
       _startTimer = startTimer ?? _startStopwatch;

  /// When [VoiceRecorder.start]'s onLimitReached fires, measured by a Dart
  /// Timer (monotonic, not wall-clock). The byte cap stays authoritative.
  final Duration maxDuration;

  /// Whether [ensurePermission] may show Android's permission dialog. False
  /// only checks the current grant: for surfaces that can be shown over the
  /// lock screen, which must never prompt.
  final bool requestPermission;

  /// Everything set explicitly: the plugin defaults (AAC, 44.1 kHz, stereo)
  /// must never apply.
  static const config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: VoiceAudioFormat.sampleRate,
    numChannels: VoiceAudioFormat.channels,
    autoGain: false,
    echoCancel: false,
    noiseSuppress: false,
    androidConfig: AndroidRecordConfig(
      // Android's capture path tuned for speech recognition.
      audioSource: AndroidAudioSource.voiceRecognition,
      // Use the device's normal input; no Bluetooth SCO switching.
      manageBluetooth: false,
    ),
  );

  // --- Format guards ---------------------------------------------------------
  // The record plugin may adjust the requested format to what the input device
  // supports (for example mono to stereo). Audio in another format must never
  // be wrapped as 16 kHz mono and sent, so it is detected two ways:
  //
  // 1. Primary: the plugin reports an adjusted configuration through
  //    setOnConfigChanged; any change of encoder, rate or channels rejects the
  //    recording.
  // 2. Backstop, in case that report is late or missing: stereo labelled as mono
  //    arrives at twice the expected byte rate, so a recording whose byte count
  //    is clearly above the mono rate is rejected. This is a coarse
  //    compatibility check, not a duration limit.

  /// Before this much monotonic time has passed there is too little data to
  /// judge: very short recordings are never checked.
  static const guardMinObservation = Duration(seconds: 1);

  /// Mono delivers at most about 1x the expected rate; stereo is exactly 2x.
  /// 1.5x sits well between them.
  static const guardMaxRateFactor = 1.5;

  /// Native and stream buffering can deliver audio in bursts and slightly
  /// ahead of our timer; half a second of mono audio absorbs that.
  static const guardSlackBytes = VoiceAudioFormat.pcmBytesPerSecond ~/ 2;

  final AudioRecorder Function() _createRecorder;
  final ElapsedTime Function() _startTimer;

  AudioRecorder? _recorder;
  bool _disposed = false;
  _Capture? _capture;

  AudioRecorder get _audioRecorder => _recorder ??= _createRecorder();

  @override
  Future<bool> ensurePermission() async {
    if (_disposed) {
      return false;
    }
    try {
      return await _audioRecorder.hasPermission(request: requestPermission);
    } on Object {
      return false;
    }
  }

  @override
  Future<void> start({required void Function() onLimitReached}) async {
    if (_disposed) {
      throw const VoiceRecorderException(VoiceRecorderFailure.disposed);
    }
    if (_capture != null) {
      throw const VoiceRecorderException(VoiceRecorderFailure.alreadyRecording);
    }
    // Timed from before the native start, so any audio captured while starting
    // only adds to the allowance of the mono guard.
    final capture = _Capture(_startTimer(), onLimitReached);
    _capture = capture;
    try {
      await _audioRecorder.setOnConfigChanged((effective) {
        if (!_isRequestedFormat(effective)) {
          capture.unsupportedFormat = true;
        }
      });
      final stream = await _audioRecorder.startStream(config);
      capture.subscription = stream.listen(
        capture.add,
        onError: (Object _) => capture.failed = true,
        cancelOnError: true,
      );
      capture.timer = Timer(maxDuration, capture.signalLimit);
    } on Object {
      _capture = null;
      await _end(capture);
      throw const VoiceRecorderException(VoiceRecorderFailure.startFailed);
    }
  }

  @override
  Future<Uint8List> stop() async {
    final capture = _capture;
    if (capture == null) {
      throw VoiceRecorderException(
        _disposed
            ? VoiceRecorderFailure.disposed
            : VoiceRecorderFailure.notRecording,
      );
    }
    _capture = null;
    capture.timer?.cancel();
    try {
      try {
        await _audioRecorder.stop();
      } on Object {
        throw const VoiceRecorderException(VoiceRecorderFailure.stopFailed);
      }
      await capture.subscription?.cancel();
      if (capture.failed) {
        throw const VoiceRecorderException(VoiceRecorderFailure.captureFailed);
      }
      if (capture.unsupportedFormat || !capture.plausiblyMono()) {
        throw const VoiceRecorderException(
          VoiceRecorderFailure.unsupportedAudio,
        );
      }
      var pcm = capture.pcm.takeBytes();
      if (pcm.length.isOdd) {
        // A trailing half sample: drop only that byte.
        pcm = Uint8List.sublistView(pcm, 0, pcm.length - 1);
      }
      return pcm16MonoToWav(pcm);
    } finally {
      await _end(capture);
    }
  }

  @override
  Future<void> cancel() async {
    final capture = _capture;
    if (capture == null) {
      return;
    }
    _capture = null;
    try {
      await _audioRecorder.cancel();
    } on Object {
      // Discarding is best effort; nothing is kept either way.
    }
    await _end(capture);
  }

  /// Releases one recording's resources and stops listening for format
  /// reports about it. Never throws.
  Future<void> _end(_Capture capture) async {
    await capture.release();
    final recorder = _recorder;
    if (recorder != null) {
      try {
        await recorder.setOnConfigChanged(null);
      } on Object {
        // Best effort: a late report could only mark an already ended capture.
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    await cancel();
    _disposed = true;
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      try {
        await recorder.dispose();
      } on Object {
        // Nothing more can be done; the recorder is unusable either way.
      }
    }
  }
}

bool _isRequestedFormat(RecordConfig effective) =>
    effective.encoder == RecordVoiceRecorder.config.encoder &&
    effective.sampleRate == RecordVoiceRecorder.config.sampleRate &&
    effective.numChannels == RecordVoiceRecorder.config.numChannels;

/// The state of one recording. Owned by [RecordVoiceRecorder].
class _Capture {
  _Capture(this.elapsed, this.onLimitReached);

  final ElapsedTime elapsed;
  final void Function() onLimitReached;
  final BytesBuilder pcm = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? subscription;
  Timer? timer;
  bool failed = false;

  /// Set when the platform reports a format other than the one requested.
  bool unsupportedFormat = false;
  bool _limitSignalled = false;

  /// Every byte the device delivered, including any beyond the cap.
  int received = 0;

  void add(Uint8List chunk) {
    received += chunk.length;
    final remaining = VoiceAudioFormat.maxPcmBytes - pcm.length;
    if (remaining <= 0) {
      return; // full: later chunks are ignored
    }
    if (chunk.length <= remaining) {
      pcm.add(chunk);
    } else {
      // Keep exactly the prefix that fills the cap (an even byte count, so it
      // ends on a sample boundary), and stop accepting audio.
      pcm.add(Uint8List.sublistView(chunk, 0, remaining));
    }
    if (pcm.length >= VoiceAudioFormat.maxPcmBytes) {
      signalLimit();
    }
  }

  void signalLimit() {
    if (_limitSignalled) {
      return;
    }
    _limitSignalled = true;
    onLimitReached();
  }

  bool plausiblyMono() {
    final observed = elapsed();
    if (observed < RecordVoiceRecorder.guardMinObservation) {
      return true;
    }
    final seconds = observed.inMicroseconds / Duration.microsecondsPerSecond;
    final allowed =
        VoiceAudioFormat.pcmBytesPerSecond *
            seconds *
            RecordVoiceRecorder.guardMaxRateFactor +
        RecordVoiceRecorder.guardSlackBytes;
    return received <= allowed;
  }

  Future<void> release() async {
    timer?.cancel();
    timer = null;
    final sub = subscription;
    subscription = null;
    await sub?.cancel();
    pcm.clear();
  }
}
