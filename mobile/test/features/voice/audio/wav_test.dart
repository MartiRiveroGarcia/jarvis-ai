import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/voice/audio/voice_audio_format.dart';
import 'package:jarvis/features/voice/audio/wav.dart';

int _u16(Uint8List b, int at) =>
    ByteData.sublistView(b).getUint16(at, Endian.little);
int _u32(Uint8List b, int at) =>
    ByteData.sublistView(b).getUint32(at, Endian.little);
String _tag(Uint8List b, int at) => ascii.decode(b.sublist(at, at + 4));

void main() {
  test('format constants match the backend contract', () {
    expect(VoiceAudioFormat.pcmBytesPerSecond, 32000);
    expect(VoiceAudioFormat.minPcmBytes, 32000 * 3 ~/ 10); // 0.3 s
    expect(VoiceAudioFormat.maxPcmBytes, 32000 * 30); // 30 s
    expect(VoiceAudioFormat.maxPcmBytes.isEven, isTrue);
  });

  test('empty PCM gives exactly the 44-byte header', () {
    final wav = pcm16MonoToWav(Uint8List(0));

    expect(wav, [
      ...ascii.encode('RIFF'), 36, 0, 0, 0, ...ascii.encode('WAVE'),
      ...ascii.encode('fmt '), 16, 0, 0, 0, 1, 0, 1, 0,
      0x80, 0x3E, 0, 0, // 16000
      0x00, 0x7D, 0, 0, // 32000
      2, 0, 16, 0,
      ...ascii.encode('data'), 0, 0, 0, 0,
    ]);
  });

  test('every header field is correct and little-endian', () {
    final pcm = Uint8List.fromList(List.generate(1000, (i) => (i * 7) % 256));

    final wav = pcm16MonoToWav(pcm);

    expect(wav.length, 44 + 1000);
    expect(_tag(wav, 0), 'RIFF');
    expect(_u32(wav, 4), 36 + 1000);
    expect(wav.sublist(4, 8), [0x0C, 0x04, 0, 0]); // 1036, low byte first
    expect(_tag(wav, 8), 'WAVE');
    expect(_tag(wav, 12), 'fmt ');
    expect(_u32(wav, 16), 16);
    expect(_u16(wav, 20), 1, reason: 'PCM');
    expect(_u16(wav, 22), 1, reason: 'mono');
    expect(_u32(wav, 24), 16000);
    expect(_u32(wav, 28), 32000, reason: 'byte rate');
    expect(_u16(wav, 32), 2, reason: 'block align');
    expect(_u16(wav, 34), 16, reason: 'bits per sample');
    expect(_tag(wav, 36), 'data');
    expect(_u32(wav, 40), 1000);
  });

  test('the PCM is copied unchanged after the header', () {
    final pcm = Uint8List.fromList(List.generate(512, (i) => 255 - i % 256));

    final wav = pcm16MonoToWav(pcm);

    expect(wav.sublist(44), pcm);
    pcm[0] = 0; // the WAV is an independent copy
    expect(wav[44], 255);
  });

  test('30 s of PCM gives a 960,044-byte WAV', () {
    final wav = pcm16MonoToWav(Uint8List(VoiceAudioFormat.maxPcmBytes));

    expect(wav.length, 960044);
    expect(_u32(wav, 40), 960000);
    expect(_u32(wav, 4), 960036);
  });

  test(
    'a PCM length that is not whole samples is rejected without its size',
    () {
      try {
        pcm16MonoToWav(Uint8List(12345));
        fail('expected ArgumentError');
      } on ArgumentError catch (error) {
        expect(error.toString(), isNot(contains('12345')));
        expect(error.message, 'PCM must be a whole number of 16-bit samples');
      }
    },
  );

  test('a non-positive sample rate is rejected', () {
    expect(
      () => pcm16MonoToWav(Uint8List(2), sampleRate: 0),
      throwsArgumentError,
    );
  });
}
