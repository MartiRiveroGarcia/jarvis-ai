import 'package:jarvis/features/assistant/data/assistant_api.dart';

/// Scriptable [AssistantApi]. Replies with [defaultReply] unless [onRespond]
/// is set. Records every message it receives.
class FakeAssistantApi implements AssistantApi {
  static const defaultReply = 'Hello from the fake assistant.';

  final List<String> messages = [];

  Future<String> Function(String message)? onRespond;

  @override
  Future<String> respond(String message) {
    messages.add(message);
    return onRespond?.call(message) ?? Future.value(defaultReply);
  }
}

AssistantException assistantError(AssistantFailure failure) =>
    AssistantException(failure);
