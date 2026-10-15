import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/voice/application/voice_conversation_controller.dart';
import 'package:jarvis/features/voice/application/voice_conversation_state.dart';
import 'package:jarvis/features/voice/presentation/voice_lifecycle_bridge.dart';

import '../../../support/fake_auth_api.dart';
import '../../../support/in_memory_token_store.dart';
import '../../../support/test_app.dart';
import '../voice_test_fakes.dart';

typedef _App = ({
  ProviderContainer container,
  FakeVoiceRecorder recorder,
  FakeVoicePlayer player,
  FakeVoiceApi api,
});

Future<_App> _pump(WidgetTester tester, {bool signedIn = true}) async {
  final recorder = FakeVoiceRecorder();
  final player = FakeVoicePlayer();
  final api = FakeVoiceApi();
  final container = await pumpJarvis(
    tester,
    api: FakeAuthApi(),
    store: InMemoryTokenStore(signedIn ? testSession() : null),
    recorder: recorder,
    player: player,
    voiceApi: api,
  );
  await tester.pumpAndSettle();
  return (container: container, recorder: recorder, player: player, api: api);
}

/// Lifecycle states in the order Flutter moves through them when leaving the
/// foreground; returning walks the same list backwards.
const _order = [
  AppLifecycleState.resumed,
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
  AppLifecycleState.detached,
];

Future<void> _enter(WidgetTester tester, AppLifecycleState state) async {
  tester.binding.handleAppLifecycleStateChanged(state);
  await tester.pumpAndSettle();
}

/// Moves to [target] through every intermediate state, as the platform does.
Future<void> _goTo(WidgetTester tester, AppLifecycleState target) async {
  final from = _order.indexOf(
    tester.binding.lifecycleState ?? AppLifecycleState.resumed,
  );
  final to = _order.indexOf(target);
  final step = to > from ? 1 : -1;
  for (var i = from + step; to != from && i != to + step; i += step) {
    await _enter(tester, _order[i]);
  }
}

Finder get _button => find.byKey(const Key('voice-button'));

VoiceConversationState _state(_App app) =>
    app.container.read(voiceConversationControllerProvider);

VoiceConversationController _voice(_App app) =>
    app.container.read(voiceConversationControllerProvider.notifier);

void main() {
  group('policy', () {
    test('which lifecycle states cancel which voice states', () {
      const active = [VoiceRecording(), VoiceProcessing(), VoicePlaying()];
      const idle = [VoiceIdle(), VoiceIdle(VoiceConversationFailure.network)];
      for (final state in [...active, ...idle]) {
        expect(voiceCancelsOn(AppLifecycleState.resumed, state), isFalse);
        expect(voiceCancelsOn(AppLifecycleState.hidden, state), isTrue);
        expect(voiceCancelsOn(AppLifecycleState.paused, state), isTrue);
        expect(voiceCancelsOn(AppLifecycleState.detached, state), isTrue);
      }
      for (final state in active) {
        expect(voiceCancelsOn(AppLifecycleState.inactive, state), isTrue);
      }
      for (final state in idle) {
        expect(voiceCancelsOn(AppLifecycleState.inactive, state), isFalse);
      }
    });
  });

  group('the permission prompt (inactive while starting)', () {
    testWidgets('inactive does not cancel a start awaiting permission', (
      tester,
    ) async {
      final app = await _pump(tester);
      final permission = app.recorder.permissionGate = Completer<bool>();
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pumpAndSettle();

      await _enter(tester, AppLifecycleState.inactive); // the dialog appears

      expect(app.recorder.count('cancel'), 0);
      expect(find.text('Hold to talk'), findsOneWidget);
      expect(find.text('Listening…'), findsNothing);
      permission.complete(true);
      await tester.pumpAndSettle();
      await gesture.up();
    });

    testWidgets('granted after the prompt, recording starts normally', (
      tester,
    ) async {
      final app = await _pump(tester);
      final permission = app.recorder.permissionGate = Completer<bool>();
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pumpAndSettle();
      await _enter(tester, AppLifecycleState.inactive);

      await _enter(tester, AppLifecycleState.resumed); // the dialog closes
      permission.complete(true);
      await tester.pumpAndSettle();

      expect(_state(app), const VoiceRecording());
      expect(find.text('Listening…'), findsOneWidget);
      expect(app.recorder.count('start'), 1);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(app.api.requests, hasLength(1));
    });

    testWidgets('a release during the prompt abandons the start', (
      tester,
    ) async {
      final app = await _pump(tester);
      final permission = app.recorder.permissionGate = Completer<bool>();
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pumpAndSettle();
      await _enter(tester, AppLifecycleState.inactive);

      await gesture.up();
      await tester.pumpAndSettle();
      await _enter(tester, AppLifecycleState.resumed);
      permission.complete(true);
      await tester.pumpAndSettle();

      expect(_state(app), const VoiceIdle());
      expect(app.recorder.count('start'), 0);
      expect(app.api.requests, isEmpty);
    });
  });

  group('inactive with real voice activity', () {
    testWidgets('recording -> inactive: idle and the recorder cancelled', (
      tester,
    ) async {
      final app = await _pump(tester);
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pumpAndSettle();
      expect(_state(app), const VoiceRecording());

      await _enter(tester, AppLifecycleState.inactive);

      expect(_state(app), const VoiceIdle());
      expect(app.recorder.count('cancel'), 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(app.recorder.count('stop'), 0); // the release finds nothing
      expect(app.api.requests, isEmpty);
    });

    testWidgets('processing -> inactive: idle; the late reply is ignored', (
      tester,
    ) async {
      final app = await _pump(tester);
      final reply = app.api.gate = Completer<Uint8List>();
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_state(app), const VoiceProcessing());

      await _enter(tester, AppLifecycleState.inactive);
      expect(_state(app), const VoiceIdle());

      reply.complete(app.api.reply);
      await tester.pumpAndSettle();
      expect(_state(app), const VoiceIdle());
      expect(app.player.played, isEmpty);
    });

    testWidgets('playing -> inactive: idle and playback stopped', (
      tester,
    ) async {
      final app = await _pump(tester);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_state(app), const VoicePlaying());

      await _enter(tester, AppLifecycleState.inactive);

      expect(_state(app), const VoiceIdle());
      expect(app.player.count('stop'), 1);
      expect(app.player.isPlaying, isFalse);
    });
  });

  group('hidden, paused and detached always cancel', () {
    // Each starts a conversation in the state just before, where nothing was
    // active yet, so only the target state can be what cancels it.
    final before = {
      AppLifecycleState.hidden: AppLifecycleState.inactive,
      AppLifecycleState.paused: AppLifecycleState.hidden,
      AppLifecycleState.detached: AppLifecycleState.paused,
    };
    for (final MapEntry(key: target, value: previous) in before.entries) {
      testWidgets('${target.name} cancels a pending start', (tester) async {
        final app = await _pump(tester);
        await _goTo(tester, previous);
        final permission = app.recorder.permissionGate = Completer<bool>();
        unawaited(_voice(app).start());
        await tester.pumpAndSettle();

        await _enter(tester, target);
        permission.complete(true);
        await tester.pumpAndSettle();

        expect(app.recorder.count('start'), 0);
        expect(_state(app), const VoiceIdle());
      });
    }

    testWidgets('processing -> paused: the late reply is ignored', (
      tester,
    ) async {
      final app = await _pump(tester);
      final reply = app.api.gate = Completer<Uint8List>();
      await tester.tap(_button);
      await tester.pumpAndSettle();

      await _goTo(tester, AppLifecycleState.paused);
      reply.complete(app.api.reply);
      await tester.pumpAndSettle();

      expect(_state(app), const VoiceIdle());
      expect(app.player.played, isEmpty);
    });

    testWidgets('playing -> hidden: playback stopped', (tester) async {
      final app = await _pump(tester);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_state(app), const VoicePlaying());

      await _goTo(tester, AppLifecycleState.hidden);

      expect(_state(app), const VoiceIdle());
      expect(app.player.count('stop'), greaterThanOrEqualTo(1));
    });
  });

  group('resumed', () {
    testWidgets('leaving and returning starts and cancels nothing', (
      tester,
    ) async {
      final app = await _pump(tester);

      await _goTo(tester, AppLifecycleState.paused);
      await _goTo(tester, AppLifecycleState.resumed);

      expect(app.recorder.calls, isEmpty);
      expect(app.player.calls, isEmpty);
      expect(_state(app), const VoiceIdle());
    });

    testWidgets('resumed during a recording leaves it running', (tester) async {
      final app = await _pump(tester);
      // Arrive at inactive with nothing active, then record.
      await _enter(tester, AppLifecycleState.inactive);
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pumpAndSettle();
      expect(_state(app), const VoiceRecording());

      await _enter(tester, AppLifecycleState.resumed);

      expect(_state(app), const VoiceRecording());
      expect(app.recorder.count('cancel'), 0);
      expect(app.recorder.count('start'), 1);
      await gesture.up();
    });
  });

  testWidgets('a lifecycle change never creates the controller', (
    tester,
  ) async {
    final app = await _pump(tester, signedIn: false);
    expect(find.byKey(const Key('login-email')), findsOneWidget);

    await _goTo(tester, AppLifecycleState.detached);

    expect(app.container.exists(voiceConversationControllerProvider), isFalse);
    expect(app.recorder.calls, isEmpty);
  });
}
