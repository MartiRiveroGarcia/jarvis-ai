import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/assistant/presentation/widgets/voice_button.dart';

Widget _app({VoidCallback? onPressed, bool reduceMotion = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Center(
            child: VoiceButton(
              onPressed: onPressed,
              semanticLabel: 'Talk to Jarvis',
              semanticHint: 'Voice interaction is coming soon.',
            ),
          ),
        ),
      ),
    );

double _pressScale(WidgetTester tester) => tester
    .widget<AnimatedScale>(
      find.descendant(
        of: find.byType(VoiceButton),
        matching: find.byType(AnimatedScale),
      ),
    )
    .scale;

double _ringScale(WidgetTester tester) => tester
    .widget<ScaleTransition>(
      find.ancestor(
        of: find.byKey(const Key('voice-button-pulse')),
        matching: find.byType(ScaleTransition),
      ),
    )
    .scale
    .value;

void main() {
  testWidgets('is an enabled button with a label and hint', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(onPressed: () {}));

    expect(
      tester.getSemantics(find.bySemanticsLabel('Talk to Jarvis')),
      isSemantics(
        label: 'Talk to Jarvis',
        hint: 'Voice interaction is coming soon.',
        isButton: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('tapping calls onPressed once', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(onPressed: () => taps++));

    await tester.tap(find.byKey(const Key('voice-button')));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('the semantic tap action also activates it', (tester) async {
    final semantics = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(_app(onPressed: () => taps++));

    tester.semantics.tap(find.semantics.byLabel('Talk to Jarvis'));
    await tester.pump();

    expect(taps, 1);
    semantics.dispose();
  });

  testWidgets('shrinks while pressed and recovers on release', (tester) async {
    await tester.pumpWidget(_app(onPressed: () {}));
    expect(_pressScale(tester), 1);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('voice-button'))),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(_pressScale(tester), VoiceButton.pressedScale);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_pressScale(tester), 1);
  });

  testWidgets('disabled when onPressed is null', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app());

    expect(
      tester.getSemantics(find.bySemanticsLabel('Talk to Jarvis')),
      isSemantics(isButton: true, isEnabled: false, hasTapAction: false),
    );
    semantics.dispose();
  });

  testWidgets('pulses while idle', (tester) async {
    await tester.pumpWidget(_app(onPressed: () {}));

    final start = _ringScale(tester);
    await tester.pump(const Duration(milliseconds: 600));

    expect(_ringScale(tester), isNot(start));
  });

  testWidgets('reduced motion stops the pulse', (tester) async {
    await tester.pumpWidget(_app(onPressed: () {}, reduceMotion: true));

    await tester.pump(const Duration(milliseconds: 600));

    expect(_ringScale(tester), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('disposes its animation when removed', (tester) async {
    await tester.pumpWidget(_app(onPressed: () {}));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.pumpWidget(const SizedBox());

    // A leaked ticker would fail the test with "disposed with an active Ticker".
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('shrinks on very narrow screens', (tester) async {
    tester.view.physicalSize = const Size(240, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(onPressed: () {}));

    final size = tester.getSize(find.byKey(const Key('voice-button')));

    expect(size.width, lessThan(168));
    expect(size.width, closeTo(120, 0.01));
  });
}
