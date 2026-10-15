import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/voice_conversation_controller.dart';
import '../application/voice_conversation_state.dart';

/// Whether moving to [lifecycle] must cancel a conversation currently in
/// [state].
///
/// Hidden, paused and detached always cancel: the app is no longer in the
/// foreground. Inactive cancels only real voice activity. A start waiting for
/// the microphone permission prompt (which itself makes the app inactive) is
/// publicly idle and must survive it; a release during the prompt still
/// abandons it through the controller.
bool voiceCancelsOn(
  AppLifecycleState lifecycle,
  VoiceConversationState state,
) => switch (lifecycle) {
  AppLifecycleState.resumed => false,
  AppLifecycleState.inactive => state is! VoiceIdle,
  AppLifecycleState.hidden ||
  AppLifecycleState.paused ||
  AppLifecycleState.detached => true,
};

/// Cancels voice activity when the app leaves the foreground, so the
/// microphone and playback never continue in the background and a late reply
/// is discarded. Kept outside the controller, which stays trigger- and
/// platform-independent.
class VoiceLifecycleBridge extends ConsumerStatefulWidget {
  const VoiceLifecycleBridge({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<VoiceLifecycleBridge> createState() =>
      _VoiceLifecycleBridgeState();
}

class _VoiceLifecycleBridgeState extends ConsumerState<VoiceLifecycleBridge> {
  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onStateChange: _handle);
  }

  void _handle(AppLifecycleState lifecycle) {
    // Never create the controller just to cancel it.
    if (!ref.exists(voiceConversationControllerProvider)) {
      return;
    }
    if (voiceCancelsOn(
      lifecycle,
      ref.read(voiceConversationControllerProvider),
    )) {
      unawaited(
        ref.read(voiceConversationControllerProvider.notifier).cancel(),
      );
    }
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
