import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';

/// Why an assistant request failed, independent of HTTP. The presentation layer
/// turns these into user-facing messages; it never sees backend strings.
enum AssistantFailure {
  /// 401, or no stored session: the Jarvis session is no longer valid.
  sessionExpired,

  /// 422 with field errors: the message did not pass the backend's validation.
  invalidInput,

  /// 422: the assistant declined the request (content filter or refusal).
  rejected,

  /// 429.
  busy,

  /// 503: the assistant is not configured on the backend.
  notAvailable,

  /// 503: the assistant failed temporarily.
  unavailable,

  /// 504, or no response within [AssistantApi.respondTimeout].
  tooSlow,

  /// The backend could not be reached.
  network,

  /// Any other status, or a response that is not exactly `{"reply": "..."}`.
  unexpected,
}

/// Thrown by [AssistantApi]. Carries only the [failure] kind: no message text,
/// reply, backend detail or token.
final class AssistantException implements Exception {
  const AssistantException(this.failure);

  final AssistantFailure failure;

  @override
  String toString() => 'AssistantException(${failure.name})';
}

/// The backend's assistant endpoint: one stateless text request, one reply.
///
/// Authenticated with the stored Jarvis session only; the app never handles
/// cloud credentials or AI service configuration.
class AssistantApi {
  AssistantApi(this._client);

  static const respondPath = '/api/assistant/respond';

  /// Longer than the backend's own model timeout (25 s), so the backend can
  /// answer with a controlled 504 before this request gives up.
  static const respondTimeout = Duration(seconds: 35);

  // Fixed backend details used to tell assistant states apart. Private: nothing
  // outside this class compares backend strings.
  static const _notAvailableDetail = 'The assistant is not available';
  static const _rejectedDetail = "The assistant couldn't answer that request";

  final ApiClient _client;

  /// Returns the reply to [message]. Throws [AssistantException].
  Future<String> respond(String message) async {
    final JsonObject? json;
    try {
      json = await _client.post(
        respondPath,
        body: {'message': message},
        authenticated: true,
        timeout: respondTimeout,
      );
    } on ApiException catch (error) {
      throw AssistantException(_failureFrom(error));
    }
    return _reply(json);
  }

  /// Accepts exactly `{"reply": "<non-blank string>"}`.
  static String _reply(JsonObject? json) {
    if (json != null && json.length == 1) {
      final reply = json['reply'];
      if (reply is String && reply.trim().isNotEmpty) {
        return reply;
      }
    }
    throw const AssistantException(AssistantFailure.unexpected);
  }

  static AssistantFailure _failureFrom(ApiException error) => switch (error) {
    UnauthorizedException() => AssistantFailure.sessionExpired,
    ValidationException(:final message, :final fieldErrors)
        when fieldErrors.isEmpty && message == _rejectedDetail =>
      AssistantFailure.rejected,
    ValidationException() => AssistantFailure.invalidInput,
    UnexpectedResponseException(statusCode: 429) => AssistantFailure.busy,
    ServerException(statusCode: 503, :final detail) =>
      detail == _notAvailableDetail
          ? AssistantFailure.notAvailable
          : AssistantFailure.unavailable,
    ServerException(statusCode: 504) => AssistantFailure.tooSlow,
    NetworkException(isTimeout: true) => AssistantFailure.tooSlow,
    NetworkException() => AssistantFailure.network,
    _ => AssistantFailure.unexpected,
  };
}
