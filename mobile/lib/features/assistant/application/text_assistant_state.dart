import '../data/assistant_api.dart';

/// State of the temporary developer text assistant: one request at a time and
/// only the latest result. Nothing is kept once the screen is closed.
sealed class TextAssistantState {
  const TextAssistantState();
}

final class TextAssistantIdle extends TextAssistantState {
  const TextAssistantIdle();
}

final class TextAssistantSubmitting extends TextAssistantState {
  const TextAssistantSubmitting();
}

final class TextAssistantSuccess extends TextAssistantState {
  const TextAssistantSuccess(this.reply);

  final String reply;
}

/// Never [AssistantFailure.sessionExpired]: that is handled by the auth flow.
final class TextAssistantFailure extends TextAssistantState {
  const TextAssistantFailure(this.failure);

  final AssistantFailure failure;
}
