import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/assistant/presentation/home_screen.dart';
import 'package:jarvis/features/assistant/presentation/widgets/voice_button.dart';

import '../../../support/fake_auth_api.dart';
import '../../../support/in_memory_token_store.dart';
import '../../../support/test_app.dart';

Future<(FakeAuthApi, InMemoryTokenStore)> _signedIn(WidgetTester tester) async {
  final api = FakeAuthApi();
  final store = InMemoryTokenStore(testSession());
  await pumpJarvis(tester, api: api, store: store);
  await tester.pumpAndSettle();
  return (api, store);
}

void main() {
  testWidgets('signed-in user lands on the assistant home', (tester) async {
    await _signedIn(tester);

    expect(find.byKey(const Key('assistant-home')), findsOneWidget);
    expect(find.byType(VoiceButton), findsOneWidget);
    expect(find.text('Tap to talk'), findsOneWidget);
    expect(find.text(HomeScreen.comingSoonMessage), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
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

  testWidgets('tapping the voice button shows the coming-soon message', (
    tester,
  ) async {
    await _signedIn(tester);

    await tester.tap(find.byKey(const Key('voice-button')));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(HomeScreen.comingSoonMessage),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the voice button gives a light haptic tick', (tester) async {
    await _signedIn(tester);
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.tap(find.byKey(const Key('voice-button')));
    await tester.pump();

    // Only our behaviour: exactly one light-impact haptic. The exact argument
    // encoding belongs to Flutter, so match it loosely.
    expect(haptics, hasLength(1));
    expect('${haptics.single}', contains('lightImpact'));
  });

  testWidgets('repeated taps do no auth, storage or network work and keep at '
      'most one message', (tester) async {
    final (api, store) = await _signedIn(tester);
    final apiCalls = List.of(api.calls);
    final storeUse = (store.reads, store.writes, store.clears);

    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(const Key('voice-button')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SnackBar).evaluate().length, lessThanOrEqualTo(1));
    }
    await tester.pumpAndSettle();

    expect(api.calls, apiCalls);
    expect((store.reads, store.writes, store.clears), storeUse);
    expect(find.byType(SnackBar).evaluate().length, lessThanOrEqualTo(1));
  });
}
