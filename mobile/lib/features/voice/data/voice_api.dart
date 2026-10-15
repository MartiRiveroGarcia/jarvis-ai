import 'dart:typed_data';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';

/// Why a voice request failed, independent of HTTP. Callers turn these into
/// user-facing messages; they never see backend strings.
enum VoiceFailure {
  /// 401, or no stored session: the Jarvis session is no longer valid.
  sessionExpired,

  /// The recording was not accepted (wrong format, too large, unusable).
  invalidAudio,

  /// The recording contained no recognisable speech.
  noSpeech,

  /// The assistant declined the request (content filter or refusal).
  rejected,

  /// 429.
  busy,

  /// 503: the voice assistant is not configured on the backend.
  notAvailable,

  /// 503: the voice assistant failed temporarily.
  unavailable,

  /// 504, or no response within [VoiceApi.respondTimeout].
  tooSlow,

  /// The backend could not be reached.
  network,

  /// Any other status, or a response that is not a non-empty MP3.
  unexpected,
}

/// Thrown by [VoiceApi]. Carries only the [failure] kind: no backend detail,
/// audio, token or URL.
final class VoiceException implements Exception {
  const VoiceException(this.failure);

  final VoiceFailure failure;

  @override
  String toString() => 'VoiceException(${failure.name})';
}

/// The backend's voice endpoint: one raw WAV recording in, Jarvis's spoken
/// reply as raw MP3 out.
///
/// Authenticated with the stored Jarvis session only; the app never handles
/// cloud credentials or AI service configuration. Independent of any UI.
class VoiceApi {
  VoiceApi(this._client);

  static const respondPath = '/api/voice/respond';

  /// Longer than the sum of the backend's own stage limits (speech-to-text
  /// 45 s, model 25 s, text-to-speech 20 s), so the backend always answers
  /// first while it still considers the request valid.
  static const respondTimeout = Duration(seconds: 100);

  /// Far above the longest possible reply (5000 characters of speech).
  static const maxResponseBytes = 5 * 1024 * 1024;

  static const _wavMediaType = 'audio/wav';
  static const _mp3MediaType = 'audio/mpeg';

  // Fixed backend details used to tell outcomes apart. Private: nothing outside
  // this class compares backend strings.
  static const _invalidAudioDetail = 'The recording could not be processed';
  static const _noSpeechDetail = "Jarvis didn't hear anything";
  static const _rejectedDetail = "The assistant couldn't answer that request";
  static const _notAvailableDetail = 'The assistant is not available';

  final ApiClient _client;

  /// Sends [wav] unchanged and returns the exact MP3 reply.
  /// Throws [VoiceException].
  Future<Uint8List> respond(Uint8List wav) async {
    final BinaryResponse response;
    try {
      response = await _client.postBinary(
        respondPath,
        body: wav,
        contentType: _wavMediaType,
        accept: _mp3MediaType,
        maxResponseBytes: maxResponseBytes,
        authenticated: true,
        timeout: respondTimeout,
      );
    } on ApiException catch (error) {
      throw VoiceException(_failureFrom(error));
    }
    if (response.mediaType != _mp3MediaType || response.bytes.isEmpty) {
      throw const VoiceException(VoiceFailure.unexpected);
    }
    return response.bytes;
  }

  static VoiceFailure _failureFrom(ApiException error) => switch (error) {
    UnauthorizedException() => VoiceFailure.sessionExpired,
    UnexpectedResponseException(statusCode: 413 || 415) =>
      VoiceFailure.invalidAudio,
    ValidationException(:final message, :final fieldErrors)
        when fieldErrors.isEmpty =>
      switch (message) {
        _invalidAudioDetail => VoiceFailure.invalidAudio,
        _noSpeechDetail => VoiceFailure.noSpeech,
        _rejectedDetail => VoiceFailure.rejected,
        _ => VoiceFailure.unexpected,
      },
    UnexpectedResponseException(statusCode: 429) => VoiceFailure.busy,
    ServerException(statusCode: 503, :final detail) =>
      detail == _notAvailableDetail
          ? VoiceFailure.notAvailable
          : VoiceFailure.unavailable,
    ServerException(statusCode: 504) => VoiceFailure.tooSlow,
    NetworkException(isTimeout: true) => VoiceFailure.tooSlow,
    NetworkException() => VoiceFailure.network,
    _ => VoiceFailure.unexpected,
  };
}
