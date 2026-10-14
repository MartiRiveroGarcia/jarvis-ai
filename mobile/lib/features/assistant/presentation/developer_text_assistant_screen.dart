import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/text_assistant_controller.dart';
import '../application/text_assistant_state.dart';
import '../data/assistant_api.dart';

/// User-facing text for a failure. Null for [AssistantFailure.sessionExpired],
/// which the auth flow handles by returning to login.
String? assistantFailureMessage(AssistantFailure failure) => switch (failure) {
  AssistantFailure.sessionExpired => null,
  AssistantFailure.invalidInput => 'Check your message and try again.',
  AssistantFailure.rejected => "Jarvis couldn't answer that request.",
  AssistantFailure.busy => 'Jarvis is busy. Try again shortly.',
  AssistantFailure.notAvailable => 'Jarvis is not available.',
  AssistantFailure.unavailable => 'Jarvis is temporarily unavailable.',
  AssistantFailure.tooSlow => 'Jarvis took too long to respond.',
  AssistantFailure.network =>
    "Couldn't reach Jarvis. Check your connection and try again.",
  AssistantFailure.unexpected => 'Something went wrong. Try again.',
};

/// Temporary, debug-only screen to test the assistant by text before speech
/// exists. One request at a time and only the latest result: no history, and
/// nothing is saved.
class DeveloperTextAssistantScreen extends ConsumerStatefulWidget {
  const DeveloperTextAssistantScreen({super.key});

  @override
  ConsumerState<DeveloperTextAssistantScreen> createState() =>
      _DeveloperTextAssistantScreenState();
}

class _DeveloperTextAssistantScreenState
    extends ConsumerState<DeveloperTextAssistantScreen> {
  final _message = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Rebuild for the counter and the Send button's enabled state.
    _message.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  void _send() {
    FocusScope.of(context).unfocus();
    ref.read(textAssistantControllerProvider.notifier).submit(_message.text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(textAssistantControllerProvider);
    final theme = Theme.of(context);
    final submitting = state is TextAssistantSubmitting;
    final length = assistantMessageLength(_message.text);
    final canSend = !submitting && isValidAssistantMessage(_message.text);

    return Scaffold(
      key: const Key('developer-text-assistant-screen'),
      appBar: AppBar(title: const Text('Ask Jarvis (developer)')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Temporary text test. Nothing is saved.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('assistant-message'),
              controller: _message,
              minLines: 3,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Message',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '$length / $maxAssistantMessageLength',
                key: const Key('assistant-counter'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: length > maxAssistantMessageLength
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('assistant-send'),
              onPressed: canSend ? _send : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              icon: submitting
                  ? const SizedBox.square(
                      key: Key('assistant-sending'),
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: const Text('Send'),
            ),
            const SizedBox(height: 24),
            ...switch (state) {
              TextAssistantSuccess(:final reply) => [
                SelectableText(
                  reply,
                  key: const Key('assistant-reply'),
                  style: theme.textTheme.bodyLarge,
                ),
              ],
              TextAssistantFailure(:final failure) => [
                if (assistantFailureMessage(failure) case final message?)
                  Text(
                    message,
                    key: const Key('assistant-error'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
              TextAssistantIdle() || TextAssistantSubmitting() => const [],
            },
          ],
        ),
      ),
    );
  }
}
