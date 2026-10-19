import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/assistant_main.dart';
import 'package:jarvis/system_assistant/assistant_app.dart';

// Its own file: assistantMain() calls runApp() directly, which needs a fresh
// test binding rather than one already advanced by other tests.
void main() {
  testWidgets('assistantMain runs the assistant app alone', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    assistantMain();
    await tester.pump();
    await tester.pump();

    expect(find.byType(AssistantApp), findsOneWidget);
    expect(find.byKey(const Key('assistant-surface')), findsOneWidget);
    // Nothing of the normal app: no home, no router-driven screens.
    expect(find.byKey(const Key('assistant-home')), findsNothing);
    expect(find.byKey(const Key('settings-screen')), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });
}
