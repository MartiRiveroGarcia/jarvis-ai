import 'dart:typed_data';

import 'voice_audio_format.dart';

/// Wraps raw signed 16-bit little-endian mono PCM in a standard 44-byte WAV
/// header. The samples are copied unchanged: no resampling or transcoding.
///
/// Throws [ArgumentError] (with a fixed message, never a length or content)
/// if [pcm] is not a whole number of 16-bit samples.
Uint8List pcm16MonoToWav(
  Uint8List pcm, {
  int sampleRate = VoiceAudioFormat.sampleRate,
}) {
  if (pcm.length.isOdd) {
    throw ArgumentError('PCM must be a whole number of 16-bit samples');
  }
  if (sampleRate <= 0) {
    throw ArgumentError('Sample rate must be positive');
  }
  const header = VoiceAudioFormat.wavHeaderBytes;
  if (pcm.length > 0xFFFFFFFF - (header - 8)) {
    throw ArgumentError('PCM is too long for a WAV file');
  }

  const channels = 1;
  const bitsPerSample = 16;
  const blockAlign = channels * bitsPerSample ~/ 8;
  final byteRate = sampleRate * blockAlign;

  final wav = Uint8List(header + pcm.length);
  final fields = ByteData.sublistView(wav)
    ..setUint32(0, 0x52494646) // "RIFF"
    ..setUint32(4, header - 8 + pcm.length, Endian.little)
    ..setUint32(8, 0x57415645) // "WAVE"
    ..setUint32(12, 0x666d7420) // "fmt "
    ..setUint32(16, 16, Endian.little) // fmt chunk size
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, channels, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, byteRate, Endian.little)
    ..setUint16(32, blockAlign, Endian.little)
    ..setUint16(34, bitsPerSample, Endian.little)
    ..setUint32(36, 0x64617461) // "data"
    ..setUint32(40, pcm.length, Endian.little);
  assert(fields.lengthInBytes == wav.length);
  wav.setRange(header, wav.length, pcm);
  return wav;
}
