/// Why recording failed. Carries no audio, sizes, timings or platform text.
enum VoiceRecorderFailure {
  /// The recorder could not start.
  startFailed,

  /// start() while a recording is already in progress.
  alreadyRecording,

  /// The audio stream failed while recording.
  captureFailed,

  /// The recorder could not be stopped cleanly; the recording is discarded.
  stopFailed,

  /// stop() without a recording in progress.
  notRecording,

  /// The recorder has been disposed.
  disposed,

  /// The device delivered audio that is not 16 kHz mono PCM (for example
  /// silently stereo); the recording is discarded and never sent.
  unsupportedAudio,
}

/// Why playback failed or ended early. Carries no audio or platform text.
enum VoicePlayerFailure {
  /// The platform player failed.
  playbackFailed,

  /// play() while another playback is active.
  busy,

  /// stop() or dispose() ended the playback before it finished.
  stopped,

  /// The player has been disposed.
  disposed,
}

final class VoiceRecorderException implements Exception {
  const VoiceRecorderException(this.failure);

  final VoiceRecorderFailure failure;

  @override
  String toString() => 'VoiceRecorderException(${failure.name})';
}

final class VoicePlayerException implements Exception {
  const VoicePlayerException(this.failure);

  final VoicePlayerFailure failure;

  @override
  String toString() => 'VoicePlayerException(${failure.name})';
}
