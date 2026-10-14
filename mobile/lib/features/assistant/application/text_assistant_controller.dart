import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../data/assistant_api.dart';
import 'text_assistant_state.dart';

final assistantApiProvider = Provider<AssistantApi>(
  (ref) => AssistantApi(ref.watch(apiClientProvider)),
);

/// Auto-disposed: leaving the screen discards the state and any late result.
final textAssistantControllerProvider =
    NotifierProvider.autoDispose<TextAssistantController, TextAssistantState>(
      TextAssistantController.new,
    );

/// Same limit as the backend.
const maxAssistantMessageLength = 4000;

/// Length as the backend counts it: Unicode code points after trimming, so an
/// emoji counts as one (Dart's String.length would count it as two).
int assistantMessageLength(String text) => text.trim().runes.length;

bool isValidAssistantMessage(String text) {
  final length = assistantMessageLength(text);
  return length >= 1 && length <= maxAssistantMessageLength;
}

class TextAssistantController extends Notifier<TextAssistantState> {
  @override
  TextAssistantState build() => const TextAssistantIdle();

  /// Sends [text] (trimmed). Ignored while a request is in flight or when the
  /// text is not 1-4000 characters.
  Future<void> submit(String text) async {
    if (state is TextAssistantSubmitting || !isValidAssistantMessage(text)) {
      return;
    }
    // Read before awaiting: the provider may be disposed by then.
    final api = ref.read(assistantApiProvider);
    final auth = ref.read(authControllerProvider.notifier);
    state = const TextAssistantSubmitting();

    TextAssistantState next;
    try {
      next = TextAssistantSuccess(await api.respond(text.trim()));
    } on AssistantException catch (error) {
      if (error.failure == AssistantFailure.sessionExpired) {
        // The session is invalid whether or not this screen is still open. The
        // router moves to login; no assistant error is shown first.
        await auth.sessionExpired();
        return;
      }
      next = TextAssistantFailure(error.failure);
    } on Exception {
      // For example, secure storage could not be read.
      next = const TextAssistantFailure(AssistantFailure.unexpected);
    }
    if (ref.mounted) {
      state = next;
    }
  }
}
