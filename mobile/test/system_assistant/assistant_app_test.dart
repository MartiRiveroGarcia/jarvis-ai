import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/providers.dart';
import 'package:jarvis/features/assistant/presentation/widgets/voice_button.dart';
import 'package:jarvis/features/auth/application/auth_controller.dart';
import 'package:jarvis/features/auth/domain/user.dart';
import 'package:jarvis/features/voice/application/voice_conversation_controller.dart';
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

  group('no voice action yet', () {
    testWidgets('the push-to-talk control is disabled', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester);

      expect(
        tester.getSemantics(find.bySemanticsLabel('Talk to Jarvis')),
        isSemantics(isButton: true, isEnabled: false, hasTapAction: false),
      );
      semantics.dispose();
    });

    testWidgets('pressing it records nothing and sends nothing', (
      tester,
    ) async {
      final h = await _pump(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('voice-button'))),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pump();

      expect(h.recorder.calls, isEmpty);
      expect(h.player.calls, isEmpty);
      expect(h.voiceApi.requests, isEmpty);
      expect(h.container.exists(voiceConversationControllerProvider), isFalse);
    });
  });
}
