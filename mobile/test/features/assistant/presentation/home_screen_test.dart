import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/assistant/presentation/widgets/voice_button.dart';
import 'package:jarvis/features/auth/application/auth_controller.dart';
import 'package:jarvis/features/auth/application/auth_state.dart';
import 'package:jarvis/features/voice/application/voice_conversation_controller.dart';
import 'package:jarvis/features/voice/application/voice_conversation_state.dart';
import 'package:jarvis/features/voice/data/voice_api.dart';
import 'package:jarvis/features/voice/presentation/voice_messages.dart';

import '../../../support/fake_auth_api.dart';
import '../../../support/in_memory_token_store.dart';
import '../../../support/test_app.dart';
import '../../voice/voice_test_fakes.dart';

typedef _Voice = ({
  ProviderContainer container,
  FakeAuthApi auth,
  InMemoryTokenStore store,
  FakeVoiceRecorder recorder,
  FakeVoicePlayer player,
  FakeVoiceApi api,
});

/// Signed in on home with the real controller over fake voice dependencies.
Future<_Voice> _signedIn(WidgetTester tester) async {
  final auth = FakeAuthApi();
  final store = InMemoryTokenStore(testSession());
  final recorder = FakeVoiceRecorder();
  final player = FakeVoicePlayer();
  final api = FakeVoiceApi();
  final container = await pumpJarvis(
    tester,
    api: auth,
    store: store,
    recorder: recorder,
    player: player,
    voiceApi: api,
  );
  await tester.pumpAndSettle();
  return (
    container: container,
    auth: auth,
    store: store,
    recorder: recorder,
    player: player,
    api: api,
  );
}

/// A controller whose state the test sets; it records the calls it receives.
class _StubVoice extends VoiceConversationController {
  _StubVoice(this._initial);

  final VoiceConversationState _initial;
  final List<String> calls = [];

  @override
  VoiceConversationState build() => _initial;

  void show(VoiceConversationState next) => state = next;

  @override
  Future<void> start() async => calls.add('start');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> cancel() async => calls.add('cancel');
}

/// Signed in on home, showing [initial] from a stub controller.
Future<_StubVoice> _showing(
  WidgetTester tester,
  VoiceConversationState initial,
) async {
  final stub = _StubVoice(initial);
  await pumpJarvis(
    tester,
    api: FakeAuthApi(),
    store: InMemoryTokenStore(testSession()),
    overrides: [voiceConversationControllerProvider.overrideWith(() => stub)],
  );
  await tester.pumpAndSettle();
  return stub;
}

Finder get _button => find.byKey(const Key('voice-button'));

String _status(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('voice-status'))).data!;

VoiceButtonVisual _visual(WidgetTester tester) =>
    tester.widget<VoiceButton>(find.byType(VoiceButton)).visual;

VoiceConversationState _voiceState(ProviderContainer container) =>
    container.read(voiceConversationControllerProvider);

const _states = <VoiceConversationState>[
  VoiceIdle(),
  VoiceRecording(),
  VoiceProcessing(),
  VoicePlaying(),
];

void main() {
  group('home', () {
    testWidgets('signed-in user lands on the voice home', (tester) async {
      await _signedIn(tester);

      expect(find.byKey(const Key('assistant-home')), findsOneWidget);
      expect(find.byType(VoiceButton), findsOneWidget);
      expect(_status(tester), 'Hold to talk');
      expect(find.byTooltip('Settings'), findsOneWidget);
    });

    testWidgets('the coming-soon placeholder is gone', (tester) async {
      await _signedIn(tester);

      expect(find.textContaining('coming soon'), findsNothing);
      expect(find.text('Tap to talk'), findsNothing);

      await tester.tap(_button);
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('account details are not shown on home', (tester) async {
      await _signedIn(tester);

      expect(find.textContaining(testUser.email), findsNothing);
    });

    testWidgets('settings action opens settings', (tester) async {
      await _signedIn(tester);

      await tester.tap(find.byKey(const Key('home-settings')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-screen')), findsOneWidget);
    });
  });

  group('state presentation', () {
    final expected = {
      const VoiceIdle(): (
        VoiceButtonVisual.idle,
        'Hold to talk',
        null as String?,
      ),
      const VoiceRecording(): (
        VoiceButtonVisual.listening,
        'Listening…',
        'Release to send',
      ),
      const VoiceProcessing(): (
        VoiceButtonVisual.thinking,
        'Jarvis is thinking…',
        null,
      ),
      const VoicePlaying(): (
        VoiceButtonVisual.speaking,
        'Jarvis is speaking…',
        'Press to interrupt',
      ),
    };
    for (final MapEntry(key: state, value: (visual, status, hint))
        in expected.entries) {
      testWidgets('$state', (tester) async {
        await _showing(tester, state);

        expect(_visual(tester), visual);
        expect(_status(tester), status);
        expect(find.byKey(const Key('voice-failure')), findsNothing);
        if (hint == null) {
          expect(find.byKey(const Key('voice-hint')), findsNothing);
        } else {
          expect(
            tester.widget<Text>(find.byKey(const Key('voice-hint'))).data,
            hint,
          );
        }
      });
    }

    for (final failure in VoiceConversationFailure.values) {
      testWidgets('failure ${failure.name} shows its message', (tester) async {
        await _showing(tester, VoiceIdle(failure));

        expect(_status(tester), 'Hold to talk');
        expect(_visual(tester), VoiceButtonVisual.idle);
        final message = tester
            .widget<Text>(find.byKey(const Key('voice-failure')))
            .data!;
        expect(message, voiceFailureMessage(failure));
        expect(message, isNot(failure.name));
        expect(message, isNot(contains('VoiceConversationFailure')));
      });
    }

    testWidgets('the status is a live region', (tester) async {
      final semantics = tester.ensureSemantics();
      await _showing(tester, const VoiceRecording());

      expect(
        tester.getSemantics(find.text('Listening…')),
        isSemantics(isLiveRegion: true),
      );
      semantics.dispose();
    });

    testWidgets('a failure is replaced as soon as the next start begins', (
      tester,
    ) async {
      final stub = await _showing(
        tester,
        const VoiceIdle(VoiceConversationFailure.network),
      );

      stub.show(const VoiceIdle());
      await tester.pump();

      expect(find.byKey(const Key('voice-failure')), findsNothing);
    });
  });

  group('pointer', () {
    for (final state in [
      const VoiceIdle(),
      const VoiceRecording(),
      const VoicePlaying(),
    ]) {
      testWidgets('$state: down -> start, up -> stop', (tester) async {
        final stub = await _showing(tester, state);

        final gesture = await tester.startGesture(tester.getCenter(_button));
        await tester.pump();
        expect(stub.calls, ['start']);
        await gesture.up();
        await tester.pump();

        expect(stub.calls, ['start', 'stop']);
      });
    }

    testWidgets('a cancelled pointer -> cancel', (tester) async {
      final stub = await _showing(tester, const VoiceIdle());

      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();
      await gesture.cancel();
      await tester.pump();

      expect(stub.calls, ['start', 'cancel']);
    });

    testWidgets('processing: a press starts nothing', (tester) async {
      final stub = await _showing(tester, const VoiceProcessing());

      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();

      expect(stub.calls, isEmpty);
      await gesture.up();
    });

    testWidgets('press and release: one start, one stop, one request', (
      tester,
    ) async {
      final h = await _signedIn(tester);
      final reply = h.api.gate = Completer<Uint8List>();

      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pumpAndSettle();
      expect(_status(tester), 'Listening…');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_status(tester), 'Jarvis is thinking…');

      reply.complete(h.api.reply);
      await tester.pumpAndSettle();
      expect(_status(tester), 'Jarvis is speaking…');
      h.player.complete();
      await tester.pumpAndSettle();

      expect(_status(tester), 'Hold to talk');
      expect(h.recorder.calls, ['ensurePermission', 'start', 'stop']);
      expect(h.api.requests, hasLength(1));
      expect(h.player.played.single, same(h.api.reply));
    });

    testWidgets('a press while thinking makes no second request', (
      tester,
    ) async {
      final h = await _signedIn(tester);
      h.api.gate = Completer<Uint8List>();
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_status(tester), 'Jarvis is thinking…');

      await tester.tap(_button);
      await tester.pumpAndSettle();

      expect(h.recorder.count('start'), 1);
      expect(h.api.requests, hasLength(1));
      expect(_status(tester), 'Jarvis is thinking…');
    });

    testWidgets('a press while speaking interrupts and listens', (
      tester,
    ) async {
      final h = await _signedIn(tester);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_status(tester), 'Jarvis is speaking…');

      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pumpAndSettle();

      expect(h.player.count('stop'), 1);
      expect(h.recorder.count('start'), 2);
      expect(_status(tester), 'Listening…');
      await gesture.up();
    });
  });

  group('semantics', () {
    final taps = {
      const VoiceIdle(): 'start',
      const VoiceIdle(VoiceConversationFailure.noSpeech): 'start',
      const VoiceRecording(): 'stop',
      const VoicePlaying(): 'start',
    };
    for (final MapEntry(key: state, value: call) in taps.entries) {
      testWidgets('$state: double-tap -> $call', (tester) async {
        final semantics = tester.ensureSemantics();
        final stub = await _showing(tester, state);

        tester.semantics.tap(find.semantics.byLabel('Talk to Jarvis'));
        await tester.pump();

        expect(stub.calls, [call]);
        semantics.dispose();
      });
    }

    testWidgets('processing: unavailable, no tap action', (tester) async {
      final semantics = tester.ensureSemantics();
      await _showing(tester, const VoiceProcessing());

      expect(
        tester.getSemantics(find.bySemanticsLabel('Talk to Jarvis')),
        isSemantics(
          label: 'Talk to Jarvis',
          value: 'Jarvis is thinking…',
          isButton: true,
          isEnabled: false,
          hasTapAction: false,
        ),
      );
      semantics.dispose();
    });

    for (final state in _states) {
      testWidgets('$state: label, value and hint', (tester) async {
        final semantics = tester.ensureSemantics();
        await _showing(tester, state);

        expect(
          tester.getSemantics(find.bySemanticsLabel('Talk to Jarvis')),
          isSemantics(
            label: 'Talk to Jarvis',
            value: voiceStatusText(state),
            hint: voiceSemanticHint(state) ?? '',
          ),
        );
        semantics.dispose();
      });
    }

    testWidgets('a full spoken exchange works by double-tap alone', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final h = await _signedIn(tester);
      final talk = find.semantics.byLabel('Talk to Jarvis');

      tester.semantics.tap(talk);
      await tester.pumpAndSettle();
      expect(_status(tester), 'Listening…');
      tester.semantics.tap(talk);
      await tester.pumpAndSettle();

      expect(_status(tester), 'Jarvis is speaking…');
      expect(h.api.requests, hasLength(1));
      semantics.dispose();
    });
  });

  group('permission', () {
    testWidgets('while permission is pending the screen stays idle', (
      tester,
    ) async {
      final h = await _signedIn(tester);
      final permission = h.recorder.permissionGate = Completer<bool>();

      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pumpAndSettle();
      expect(_status(tester), 'Hold to talk');
      expect(find.text('Listening…'), findsNothing);
      expect(_visual(tester), VoiceButtonVisual.idle);

      permission.complete(true);
      await tester.pumpAndSettle();
      expect(_status(tester), 'Listening…');
      await gesture.up();
    });

    testWidgets('releasing while permission is pending stays idle', (
      tester,
    ) async {
      final h = await _signedIn(tester);
      final permission = h.recorder.permissionGate = Completer<bool>();

      await tester.tap(_button);
      await tester.pumpAndSettle();
      permission.complete(true);
      await tester.pumpAndSettle();

      expect(_status(tester), 'Hold to talk');
      expect(find.byKey(const Key('voice-failure')), findsNothing);
      expect(h.recorder.count('start'), 0);
      expect(h.api.requests, isEmpty);
    });

    testWidgets('a denial shows the generic permission message', (
      tester,
    ) async {
      final h = await _signedIn(tester);
      h.recorder.permission = false;

      await tester.tap(_button);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Microphone access is off. Allow microphone access to talk to '
          'Jarvis.',
        ),
        findsOneWidget,
      );
    });
  });

  group('failures and privacy', () {
    testWidgets('backend or platform text is never shown', (tester) async {
      final h = await _signedIn(tester);
      h.api.error = StateError('secret backend detail');

      await tester.tap(_button);
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong. Try again.'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
    });

    testWidgets('a short press shows the too-short message, no request', (
      tester,
    ) async {
      final h = await _signedIn(tester);
      h.recorder.wav = wavOf(9598);

      await tester.tap(_button);
      await tester.pumpAndSettle();

      expect(find.text('Hold the button a little longer.'), findsOneWidget);
      expect(h.api.requests, isEmpty);
    });

    testWidgets('session expiry goes to login with no voice message', (
      tester,
    ) async {
      final h = await _signedIn(tester);
      h.api.error = const VoiceException(VoiceFailure.sessionExpired);

      await tester.tap(_button);
      await tester.pumpAndSettle();

      expect(
        h.container.read(authControllerProvider),
        isA<AuthUnauthenticated>(),
      );
      expect(find.byKey(const Key('login-email')), findsOneWidget);
      expect(find.byKey(const Key('assistant-home')), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(_voiceState(h.container), const VoiceIdle());
    });
  });
}
