import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/providers.dart';
import 'package:jarvis/features/assistant/presentation/widgets/voice_button.dart';
import 'package:jarvis/features/auth/application/auth_controller.dart';
import 'package:jarvis/features/auth/domain/user.dart';
import 'package:jarvis/features/voice/application/voice_conversation_controller.dart';
import 'package:jarvis/features/voice/data/voice_api.dart';
import 'package:jarvis/features/voice/audio/voice_player.dart';
import 'package:jarvis/features/voice/audio/voice_recorder.dart';
import 'package:jarvis/system_assistant/assistant_app.dart';
import 'package:jarvis/system_assistant/assistant_close.dart';

import '../features/voice/voice_test_fakes.dart';
import '../support/fake_auth_api.dart';
import '../support/in_memory_token_store.dart';

typedef _Assistant = ({
  ProviderContainer container,
  FakeAuthApi api,
  InMemoryTokenStore store,
  FakeVoiceRecorder recorder,
  FakeVoicePlayer player,
  FakeVoiceApi voiceApi,
  List<String> closes,
});

/// Pumps [AssistantApp] alone, as its entrypoint does, with fakes underneath.
Future<_Assistant> _pump(
  WidgetTester tester, {
  InMemoryTokenStore? store,
  FakeAuthApi? api,
}) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final auth = api ?? FakeAuthApi();
  final tokens = store ?? InMemoryTokenStore(testSession());
  final recorder = FakeVoiceRecorder();
  final player = FakeVoicePlayer();
  final voiceApi = FakeVoiceApi();
  final closes = <String>[];
  final container = ProviderContainer.test(
    retry: (_, _) => null,
    overrides: [
      authApiProvider.overrideWithValue(auth),
      tokenStoreProvider.overrideWithValue(tokens),
      clockProvider.overrideWithValue(() => DateTime.utc(2026, 10, 5)),
      voiceRecorderProvider.overrideWithValue(recorder),
      voicePlayerProvider.overrideWithValue(player),
      voiceApiProvider.overrideWithValue(voiceApi),
      assistantCloseProvider.overrideWithValue(() => closes.add('close')),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const AssistantApp(),
    ),
  );
  await tester.pump();
  await tester.pump();
  return (
    container: container,
    api: auth,
    store: tokens,
    recorder: recorder,
    player: player,
    voiceApi: voiceApi,
    closes: closes,
  );
}

Finder _key(String key) => find.byKey(Key(key));

/// Nothing private or account-related may ever be on the assistant surface.
void _expectNothingPrivate(WidgetTester tester) {
  expect(find.textContaining(testUser.email), findsNothing);
  for (final private in [
    'Settings',
    'Sign out',
    'Developer',
    'Log in',
    'Register',
    'Email',
    'Password',
  ]) {
    expect(find.textContaining(private), findsNothing, reason: private);
  }
  expect(find.byType(TextField), findsNothing); // no login form
  expect(find.byType(AppBar), findsNothing); // no navigation actions
}

void main() {
  group('auth states', () {
    testWidgets('initializing shows neutral progress and Close', (
      tester,
    ) async {
      final api = FakeAuthApi()..onMe = () => Completer<User>().future;

      await _pump(tester, api: api);

      expect(_key('assistant-progress'), findsOneWidget);
      expect(_key('assistant-voice'), findsNothing);
      expect(_key('assistant-close'), findsOneWidget);
      _expectNothingPrivate(tester);
    });

    testWidgets('authenticated shows the assistant-only voice shell', (
      tester,
    ) async {
      await _pump(tester);

      expect(_key('assistant-voice'), findsOneWidget);
      expect(find.byType(VoiceButton), findsOneWidget);
      expect(find.text('Hold to talk'), findsOneWidget);
      expect(_key('assistant-close'), findsOneWidget);
      expect(_key('assistant-retry'), findsNothing);
      _expectNothingPrivate(tester);
    });

    testWidgets('signed out shows the safe message and Close only', (
      tester,
    ) async {
      await _pump(tester, store: InMemoryTokenStore());

      expect(_key('assistant-signed-out'), findsOneWidget);
      expect(find.text(AssistantGate.signedOutMessage), findsOneWidget);
      expect(_key('assistant-close'), findsOneWidget);
      expect(_key('assistant-retry'), findsNothing);
      expect(_key('assistant-voice'), findsNothing);
      _expectNothingPrivate(tester);
    });

    testWidgets('an expired session shows the signed-out message', (
      tester,
    ) async {
      final store = InMemoryTokenStore(
        testSession(expiresAt: DateTime.utc(2026, 10, 1)),
      );

      final h = await _pump(tester, store: store);

      expect(find.text(AssistantGate.signedOutMessage), findsOneWidget);
      expect(h.store.session, isNull); // the existing restore cleared it
      _expectNothingPrivate(tester);
    });

    testWidgets('a network failure shows Retry and Close, no sign out', (
      tester,
    ) async {
      final api = FakeAuthApi()
        ..onMe = () => Future.error(networkError('/api/auth/me'));

      await _pump(tester, api: api);

      expect(_key('assistant-unreachable'), findsOneWidget);
      expect(find.text(AssistantGate.unreachableMessage), findsOneWidget);
      expect(_key('assistant-retry'), findsOneWidget);
      expect(_key('assistant-close'), findsOneWidget);
      _expectNothingPrivate(tester);
    });

    testWidgets('a storage failure is shown as unreachable too', (
      tester,
    ) async {
      final store = InMemoryTokenStore(testSession())..failRead = true;

      await _pump(tester, store: store);

      expect(_key('assistant-unreachable'), findsOneWidget);
      _expectNothingPrivate(tester);
    });

    testWidgets('Retry restores the session again', (tester) async {
      var fail = true;
      final api = FakeAuthApi()
        ..onMe = () => fail
            ? Future.error(networkError('/api/auth/me'))
            : Future.value(testUser);
      await _pump(tester, api: api);
      expect(_key('assistant-unreachable'), findsOneWidget);

      fail = false;
      await tester.tap(_key('assistant-retry'));
      await tester.pump();
      await tester.pump();

      expect(_key('assistant-voice'), findsOneWidget);
      expect(api.calls.where((c) => c == 'me'), hasLength(2));
    });
  });

  group('bottom panel presentation', () {
    testWidgets('nothing opaque is painted outside the panel', (tester) async {
      await _pump(tester);

      final scaffold = tester.widget<Scaffold>(_key('assistant-surface'));
      expect(scaffold.backgroundColor, Colors.transparent);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.theme!.scaffoldBackgroundColor, Colors.transparent);
      // The only Material surfaces are the transparent scaffold and the panel.
      final opaque = tester
          .widgetList<Material>(find.byType(Material))
          .where((m) => m.type != MaterialType.transparency)
          .where((m) => (m.color ?? Colors.transparent).a > 0)
          .map((m) => m.key);
      expect(opaque.toSet(), {const Key('assistant-panel')});
    });

    for (final (name, store) in [
      ('authenticated', InMemoryTokenStore(testSession())),
      ('signed out', InMemoryTokenStore()),
    ]) {
      testWidgets('the panel is compact and at the bottom when $name', (
        tester,
      ) async {
        await _pump(tester, store: store);
        final screen = tester.getSize(_key('assistant-surface'));
        final panel = tester.getRect(_key('assistant-panel'));

        expect(panel.bottom, screen.height);
        expect(panel.height, lessThan(screen.height / 2));
        expect(panel.top, greaterThan(0));
      });
    }

    testWidgets('a tap outside the panel ends the session', (tester) async {
      final h = await _pump(tester);

      await tester.tapAt(const Offset(20, 20));
      await tester.pump();

      expect(h.closes, ['close']);
    });

    testWidgets('a tap inside the panel does not', (tester) async {
      final h = await _pump(tester);

      await tester.tap(find.text('Jarvis'));
      await tester.pump();

      expect(h.closes, isEmpty);
    });

    testWidgets('holding and double-tapping the control keep the panel open', (
      tester,
    ) async {
      final h = await _pump(tester);
      final control = tester.getCenter(find.byKey(const Key('voice-button')));

      final hold = await tester.startGesture(control);
      await tester.pump(const Duration(seconds: 2));
      await hold.up();
      await tester.pump();
      await tester.tapAt(control);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(control);
      await tester.pump(const Duration(milliseconds: 500));

      expect(h.closes, isEmpty);
      expect(_key('assistant-voice'), findsOneWidget);
    });

    testWidgets('taps on empty panel space keep it open', (tester) async {
      final h = await _pump(tester);
      final panel = tester.getRect(_key('assistant-panel'));
      final voice = tester.getRect(find.byKey(const Key('voice-button')));

      for (final point in [
        panel.topLeft + const Offset(6, 6), // corner padding
        panel.topRight + const Offset(-6, 6),
        Offset(panel.left + 8, voice.center.dy), // beside the control
        panel.bottomCenter + const Offset(0, -2), // below Close
      ]) {
        await tester.tapAt(point);
        await tester.pump();
      }

      expect(h.closes, isEmpty);
    });

    testWidgets('the outside area is a labelled Close action', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await _pump(tester);

      tester.semantics.tap(find.semantics.byLabel('Close Jarvis'));
      await tester.pump();

      expect(h.closes, ['close']);
      semantics.dispose();
    });
  });

  group('Close', () {
    for (final (name, store) in [
      ('authenticated', InMemoryTokenStore(testSession())),
      ('signed out', InMemoryTokenStore()),
    ]) {
      testWidgets('Close ends the session when $name', (tester) async {
        final h = await _pump(tester, store: store);

        await tester.tap(_key('assistant-close'));
        await tester.pump();

        expect(h.closes, ['close']);
      });
    }
  });

  group('push-to-talk in the panel', () {
    Finder control() => find.byKey(const Key('voice-button'));
    String status(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('voice-status'))).data!;

    testWidgets('opening the panel starts nothing on its own', (tester) async {
      final h = await _pump(tester);
      await tester.pump(const Duration(seconds: 3));

      expect(status(tester), 'Hold to talk');
      expect(h.recorder.calls, isEmpty); // not even a permission check
      expect(h.player.calls, isEmpty);
      expect(h.voiceApi.requests, isEmpty);
    });

    testWidgets('hold records; release sends, plays the reply, returns idle', (
      tester,
    ) async {
      final h = await _pump(tester);

      final gesture = await tester.startGesture(tester.getCenter(control()));
      await tester.pump();
      expect(h.recorder.calls, ['ensurePermission', 'start']);
      expect(status(tester), 'Listening…');

      await gesture.up();
      await tester.pump();
      await tester.pump();
      expect(h.recorder.count('stop'), 1);
      expect(h.voiceApi.requests, [h.recorder.wav]);
      expect(h.player.played, [h.voiceApi.reply]);
      expect(status(tester), 'Jarvis is speaking…');

      h.player.complete();
      await tester.pump();
      await tester.pump();
      expect(status(tester), 'Hold to talk');
      expect(h.voiceApi.requests, hasLength(1));
      expect(h.closes, isEmpty);
    });

    testWidgets('pressing while speaking interrupts, as in the normal app', (
      tester,
    ) async {
      final h = await _pump(tester);
      await tester.tap(control());
      await tester.pump();
      await tester.pump();
      expect(status(tester), 'Jarvis is speaking…');

      final gesture = await tester.startGesture(tester.getCenter(control()));
      await tester.pump();
      await tester.pump();

      expect(h.player.count('stop'), 1);
      expect(h.recorder.count('start'), 2);
      expect(status(tester), 'Listening…');
      await gesture.up();
    });

    testWidgets('presses while thinking are ignored, as in the normal app', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.voiceApi.gate = Completer<Uint8List>();
      await tester.tap(control());
      await tester.pump();
      await tester.pump();
      expect(status(tester), 'Jarvis is thinking…');

      await tester.tap(control());
      await tester.pump();

      expect(h.recorder.count('start'), 1);
      expect(h.voiceApi.requests, hasLength(1));
    });

    Future<void> leaveForeground(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('leaving the foreground while recording discards it', (
      tester,
    ) async {
      final h = await _pump(tester);
      final gesture = await tester.startGesture(tester.getCenter(control()));
      await tester.pump();
      expect(status(tester), 'Listening…');

      await leaveForeground(tester);

      expect(h.recorder.count('cancel'), 1);
      expect(h.recorder.count('stop'), 0);
      expect(h.voiceApi.requests, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(h.voiceApi.requests, isEmpty);
    });

    testWidgets('leaving while thinking ignores the late reply', (
      tester,
    ) async {
      final h = await _pump(tester);
      final reply = h.voiceApi.gate = Completer<Uint8List>();
      await tester.tap(control());
      await tester.pump();
      await tester.pump();
      expect(status(tester), 'Jarvis is thinking…');

      await leaveForeground(tester);
      reply.complete(h.voiceApi.reply);
      await tester.pump();
      await tester.pump();

      expect(h.player.played, isEmpty); // no late playback
      expect(status(tester), 'Hold to talk');
    });

    testWidgets('leaving while speaking stops the reply', (tester) async {
      final h = await _pump(tester);
      await tester.tap(control());
      await tester.pump();
      await tester.pump();
      expect(status(tester), 'Jarvis is speaking…');

      await leaveForeground(tester);

      expect(h.player.count('stop'), 1);
      expect(h.player.isPlaying, isFalse);
      expect(status(tester), 'Hold to talk');
    });

    testWidgets('without microphone access it records nothing and says why', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.recorder.permission = false;

      await tester.tap(control());
      await tester.pump();
      await tester.pump();

      expect(h.recorder.calls, ['ensurePermission']); // never start
      expect(h.voiceApi.requests, isEmpty);
      expect(
        tester.widget<Text>(find.byKey(const Key('voice-failure'))).data,
        'Open Jarvis to allow microphone access',
      );
      expect(h.closes, isEmpty);
    });

    testWidgets('a voice failure shows the normal fixed message', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.voiceApi.error = const VoiceException(VoiceFailure.network);

      await tester.tap(control());
      await tester.pump();
      await tester.pump();

      expect(
        tester.widget<Text>(find.byKey(const Key('voice-failure'))).data,
        "Couldn't reach Jarvis. Check your connection and try again.",
      );
      expect(h.player.played, isEmpty);
    });

    testWidgets('an expired session during voice shows the signed-out panel', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.voiceApi.error = const VoiceException(VoiceFailure.sessionExpired);

      await tester.tap(control());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text(AssistantGate.signedOutMessage), findsOneWidget);
      expect(_key('assistant-voice'), findsNothing);
      expect(h.store.session, isNull);
      expect(h.player.played, isEmpty);
      expect(h.closes, isEmpty); // no navigation, the panel stays
      _expectNothingPrivate(tester);
    });

    for (final (name, store, api) in [
      ('signed out', InMemoryTokenStore(), FakeAuthApi()),
      (
        'unreachable',
        InMemoryTokenStore(testSession()),
        FakeAuthApi()..onMe = () => Future.error(networkError('/api/auth/me')),
      ),
    ]) {
      testWidgets('$name: no voice controller exists', (tester) async {
        final h = await _pump(tester, store: store, api: api);

        expect(
          h.container.exists(voiceConversationControllerProvider),
          isFalse,
        );
        expect(h.recorder.calls, isEmpty);
      });
    }
  });
}
