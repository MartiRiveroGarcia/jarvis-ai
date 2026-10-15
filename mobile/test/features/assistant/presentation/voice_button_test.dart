import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/assistant/presentation/widgets/voice_button.dart';

/// Records which callbacks the button invoked, in order.
class _Calls {
  final List<String> log = [];
  void Function() call(String name) =>
      () => log.add(name);
}

Widget _app({
  VoiceButtonVisual visual = VoiceButtonVisual.idle,
  _Calls? calls,
  bool pressable = true,
  bool activatable = true,
  bool reduceMotion = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(
      body: Center(
        child: VoiceButton(
          visual: visual,
          semanticLabel: 'Talk to Jarvis',
          semanticValue: 'Hold to talk',
          semanticHint: 'Hold to talk, or double-tap to start',
          onPressStart: pressable ? calls?.call('start') : null,
          onPressEnd: calls?.call('end'),
          onPressCancel: calls?.call('cancel'),
          onActivate: activatable ? calls?.call('activate') : null,
        ),
      ),
    ),
  ),
);

Finder get _button => find.byKey(const Key('voice-button'));

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

IconData? _icon(WidgetTester tester) =>
    tester.widget<Icon>(find.byKey(const Key('voice-button-icon'))).icon;

void main() {
  group('pointer', () {
    testWidgets('down calls onPressStart and up calls onPressEnd', (
      tester,
    ) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(calls: calls));

      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();
      expect(calls.log, ['start']);

      await gesture.up();
      await tester.pump();
      expect(calls.log, ['start', 'end']);
    });

    testWidgets('a press and release never also activates', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(calls: calls));

      await tester.tap(_button);
      await tester.pump(const Duration(milliseconds: 500));

      expect(calls.log, ['start', 'end']);
    });

    testWidgets('a cancelled pointer calls onPressCancel, not onPressEnd', (
      tester,
    ) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(calls: calls));

      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();
      await gesture.cancel();
      await tester.pump();

      expect(calls.log, ['start', 'cancel']);
    });

    testWidgets('only the first pointer counts', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(calls: calls));
      final center = tester.getCenter(_button);

      final first = await tester.startGesture(center, pointer: 1);
      final second = await tester.startGesture(
        center + const Offset(10, 0),
        pointer: 2,
      );
      await second.up();
      await tester.pump();
      expect(calls.log, ['start']); // the second finger changes nothing

      await first.up();
      await tester.pump();
      expect(calls.log, ['start', 'end']);
    });

    testWidgets('a release is reported even if pressing became unavailable', (
      tester,
    ) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(calls: calls));
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();

      // For example the recording limit moved the conversation on.
      await tester.pumpWidget(
        _app(
          calls: calls,
          visual: VoiceButtonVisual.thinking,
          pressable: false,
          activatable: false,
        ),
      );
      await gesture.up();
      await tester.pump();

      expect(calls.log, ['start', 'end']);
    });

    testWidgets('no press starts while pressing is unavailable', (
      tester,
    ) async {
      final calls = _Calls();
      await tester.pumpWidget(
        _app(calls: calls, pressable: false, activatable: false),
      );

      await tester.tap(_button);
      await tester.pump();

      expect(calls.log, isEmpty);
    });

    testWidgets('shrinks while pressed and recovers on release', (
      tester,
    ) async {
      await tester.pumpWidget(_app(calls: _Calls()));
      expect(_pressScale(tester), 1);

      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_pressScale(tester), VoiceButton.pressedScale);

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_pressScale(tester), 1);
    });

    testWidgets('a press gives one light haptic tick', (tester) async {
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
      await tester.pumpWidget(_app(calls: _Calls()));

      await tester.tap(_button);
      await tester.pump();

      expect(haptics, hasLength(1));
      expect('${haptics.single}', contains('lightImpact'));
    });
  });

  group('semantics and keyboard', () {
    testWidgets('an enabled button with label, value and hint', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_app(calls: _Calls()));

      expect(
        tester.getSemantics(find.bySemanticsLabel('Talk to Jarvis')),
        isSemantics(
          label: 'Talk to Jarvis',
          value: 'Hold to talk',
          hint: 'Hold to talk, or double-tap to start',
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
          isFocusable: true,
        ),
      );
      semantics.dispose();
    });

    testWidgets('the semantic tap activates, without a press', (tester) async {
      final semantics = tester.ensureSemantics();
      final calls = _Calls();
      await tester.pumpWidget(_app(calls: calls));

      tester.semantics.tap(find.semantics.byLabel('Talk to Jarvis'));
      await tester.pump();

      expect(calls.log, ['activate']);
      semantics.dispose();
    });

    testWidgets('Enter and Space activate when focused', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(calls: calls));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(calls.log, ['activate', 'activate']);
    });

    testWidgets('disabled without press or activation', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(calls: _Calls(), pressable: false, activatable: false),
      );

      expect(
        tester.getSemantics(find.bySemanticsLabel('Talk to Jarvis')),
        isSemantics(isButton: true, isEnabled: false, hasTapAction: false),
      );
      semantics.dispose();
    });

    testWidgets('the touch target is far above 48 dp', (tester) async {
      await tester.pumpWidget(_app(calls: _Calls()));

      expect(tester.getSize(_button).width, greaterThanOrEqualTo(120));
    });
  });

  group('visuals', () {
    final icons = {
      VoiceButtonVisual.idle: Icons.mic_rounded,
      VoiceButtonVisual.listening: Icons.mic_rounded,
      VoiceButtonVisual.thinking: Icons.more_horiz_rounded,
      VoiceButtonVisual.speaking: Icons.graphic_eq_rounded,
    };
    for (final MapEntry(key: visual, value: icon) in icons.entries) {
      testWidgets('${visual.name} shows its icon', (tester) async {
        await tester.pumpWidget(
          _app(visual: visual, calls: _Calls(), reduceMotion: true),
        );

        expect(_icon(tester), icon);
      });
    }

    testWidgets('listening uses a distinct colour from idle', (tester) async {
      Color? coreColour() {
        final box = tester.widget<DecoratedBox>(_button);
        return ((box.decoration as BoxDecoration).gradient! as RadialGradient)
            .colors
            .first;
      }

      await tester.pumpWidget(_app(calls: _Calls(), reduceMotion: true));
      final idle = coreColour();
      await tester.pumpWidget(
        _app(
          visual: VoiceButtonVisual.listening,
          calls: _Calls(),
          reduceMotion: true,
        ),
      );

      expect(coreColour(), isNot(idle));
    });

    testWidgets('thinking shows progress instead of the pulse', (tester) async {
      await tester.pumpWidget(
        _app(visual: VoiceButtonVisual.thinking, calls: _Calls()),
      );

      expect(find.byKey(const Key('voice-button-progress')), findsOneWidget);
      expect(find.byKey(const Key('voice-button-pulse')), findsNothing);
    });

    testWidgets('pulses while idle', (tester) async {
      await tester.pumpWidget(_app(calls: _Calls()));

      final start = _ringScale(tester);
      await tester.pump(const Duration(milliseconds: 600));

      expect(_ringScale(tester), isNot(start));
    });

    testWidgets('listening pulses faster than idle', (tester) async {
      await tester.pumpWidget(
        _app(visual: VoiceButtonVisual.listening, calls: _Calls()),
      );
      final controller = tester
          .widget<ScaleTransition>(
            find.ancestor(
              of: find.byKey(const Key('voice-button-pulse')),
              matching: find.byType(ScaleTransition),
            ),
          )
          .scale;

      // It moves, and is back where it was after one fast cycle; the slow
      // idle pulse would still be mid-cycle.
      final before = controller.value;
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.value, isNot(closeTo(before, 0.01)));
      await tester.pump(
        VoiceButton.listeningPulseDuration - const Duration(milliseconds: 300),
      );
      expect(controller.value, closeTo(before, 0.001));
    });

    for (final visual in VoiceButtonVisual.values) {
      testWidgets('reduced motion leaves nothing animating: ${visual.name}', (
        tester,
      ) async {
        await tester.pumpWidget(
          _app(visual: visual, calls: _Calls(), reduceMotion: true),
        );

        await tester.pump(const Duration(milliseconds: 600));

        expect(tester.binding.transientCallbackCount, 0);
        expect(find.byKey(const Key('voice-button-progress')), findsNothing);
      });
    }

    testWidgets('disposes its animation when removed', (tester) async {
      await tester.pumpWidget(_app(calls: _Calls()));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await tester.pumpWidget(const SizedBox());

      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('shrinks on very narrow screens', (tester) async {
      tester.view.physicalSize = const Size(240, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(calls: _Calls()));

      final size = tester.getSize(_button);

      expect(size.width, lessThan(168));
      expect(size.width, closeTo(120, 0.01));
    });
  });

  test('the button holds no conversation logic', () {
    final source = File(
      'lib/features/assistant/presentation/widgets/voice_button.dart',
    ).readAsStringSync();

    for (final forbidden in [
      'riverpod',
      'VoiceConversation',
      'VoiceApi',
      'VoiceRecorder',
      'VoicePlayer',
      'voice/',
      'bool _recording',
      'bool _pressed',
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
