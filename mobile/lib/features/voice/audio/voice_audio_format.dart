/// The one audio format Jarvis records and the backend accepts: WAV with
/// signed 16-bit little-endian PCM, 16 kHz, mono, 0.3–30 seconds.
abstract final class VoiceAudioFormat {
  static const sampleRate = 16000;
  static const channels = 1;
  static const bytesPerSample = 2;

  /// 16000 samples/s × 1 channel × 2 bytes.
  static const pcmBytesPerSecond = sampleRate * channels * bytesPerSample;

  /// 0.3 s: shorter recordings are not worth sending (the controller decides).
  static const minPcmBytes = 9600;

  /// 30 s: the authoritative maximum. Even, so it falls on a sample boundary.
  static const maxPcmBytes = 960000;

  static const maxDuration = Duration(seconds: 30);

  static const wavHeaderBytes = 44;
}
