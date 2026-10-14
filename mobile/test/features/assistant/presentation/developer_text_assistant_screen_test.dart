import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/assistant/data/assistant_api.dart';
import 'package:jarvis/features/assistant/presentation/developer_text_assistant_screen.dart';

import '../../../support/fake_assistant_api.dart';
import '../../../support/fake_auth_api.dart';
import '../../../support/in_memory_token_store.dart';
import '../../../support/test_app.dart';

final _screen = find.byKey(const Key('developer-text-assistant-screen'));
final _input = find.byKey(const Key('assistant-message'));
final _send = find.byKey(const Key('assistant-send'));
final _reply = find.byKey(const Key('assistant-reply'));
final _error = find.byKey(const Key('assistant-error'));
final _spinner = find.byKey(const Key('assistant-sending'));
final _counter = find.byKey(const Key('assistant-counter'));

/// Signs in, then opens the screen through Settings like a user would.
Future<(FakeAssistantApi, InMemoryTokenStore)> _open(
  WidgetTester tester, {
  FakeAssistantApi? api,
}) async {
  final assistant = api ?? FakeAssistantApi();
  final store = InMemoryTokenStore(testSession());
  await pumpJarvis(
    tester,
    api: FakeAuthApi(),
    store: store,
    assistantApi: assistant,
    developerTools: true,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('home-settings')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('developer-text-assistant')));
  await tester.pumpAndSettle();
  expect(_screen, findsOneWidget);
  return (assistant, store);
}

bool _sendEnabled(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(_send).onPressed != null;

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await tester.pump();
}

void main() {
  testWidgets('shows the temporary screen with no result yet', (tester) async {
    await _open(tester);

    expect(find.text('Ask Jarvis (developer)'), findsOneWidget);
    expect(find.text('Temporary text test. Nothing is saved.'), findsOneWidget);
    expect(_counter, findsOneWidget);
    expect(find.text('0 / 4000'), findsOneWidget);
    expect(_reply, findsNothing);
    expect(_error, findsNothing);
    expect(_sendEnabled(tester), isFalse);
  });

  group('validation', () {
    testWidgets('Send is enabled only for 1-4000 characters after trimming', (
      tester,
    ) async {
      await _open(tester);

      for (final (text, enabled) in [
        ('', false),
        ('   \n  ', false),
        ('x', true),
        ('  x  ', true),
        ('x' * 4000, true),
        ('x' * 4001, false),
      ]) {
        await _type(tester, text);
        expect(_sendEnabled(tester), enabled, reason: '${text.length} chars');
      }
    });

    testWidgets('the counter counts Unicode characters, not code units', (
      tester,
    ) async {
      await _open(tester);

      await _type(tester, ' 🤖🤖 ');
      expect(find.text('2 / 4000'), findsOneWidget);

      await _type(tester, '🤖' * 4000);
      expect(find.text('4000 / 4000'), findsOneWidget);
      expect(_sendEnabled(tester), isTrue);

      await _type(tester, '🤖' * 4001);
      expect(find.text('4001 / 4000'), findsOneWidget);
      expect(_sendEnabled(tester), isFalse);
    });
  });

  testWidgets('sends the trimmed text and shows the reply', (tester) async {
    final (api, _) = await _open(tester);

    await _type(tester, '  What is RAG?  ');
    await tester.tap(_send);
    await tester.pumpAndSettle();

    expect(api.messages, ['What is RAG?']);
    expect(find.text(FakeAssistantApi.defaultReply), findsOneWidget);
    // The text stays so it can be edited and sent again.
    expect(find.text('  What is RAG?  '), findsOneWidget);
  });

  testWidgets('spinner and disabled Send while submitting', (tester) async {
    final pending = Completer<String>();
    final api = FakeAssistantApi()..onRespond = (_) => pending.future;
    await _open(tester, api: api);

    await _type(tester, 'Hello');
    await tester.tap(_send);
    await tester.pump();

    expect(_spinner, findsOneWidget);
    expect(_sendEnabled(tester), isFalse);
    await tester.tap(_send, warnIfMissed: false);
    expect(api.messages, hasLength(1));

    pending.complete('Done');
    await tester.pumpAndSettle();
    expect(_spinner, findsNothing);
    expect(_sendEnabled(tester), isTrue);
  });

  testWidgets('a new response replaces the previous one', (tester) async {
    final api = FakeAssistantApi();
    await _open(tester, api: api);
    await _type(tester, 'first');

    api.onRespond = (_) async => 'First reply';
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(find.text('First reply'), findsOneWidget);

    final pending = Completer<String>();
    api.onRespond = (_) => pending.future;
    await tester.tap(_send);
    await tester.pump();
    // The old reply is gone while the new request runs.
    expect(find.text('First reply'), findsNothing);
    expect(_reply, findsNothing);

    pending.complete('Second reply');
    await tester.pumpAndSettle();
    expect(find.text('Second reply'), findsOneWidget);
    expect(find.text('First reply'), findsNothing);
    expect(_reply, findsOneWidget);
  });

  testWidgets('a new request clears a previous error', (tester) async {
    final pending = Completer<String>();
    final api = FakeAssistantApi()
      ..onRespond = (_) => Future.error(assistantError(AssistantFailure.busy));
    await _open(tester, api: api);
    await _type(tester, 'Hello');
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(_error, findsOneWidget);

    api.onRespond = (_) => pending.future;
    await tester.tap(_send);
    await tester.pump();
    expect(_error, findsNothing);

    pending.complete('ok');
    await tester.pumpAndSettle();
  });

  group('errors', () {
    const expected = {
      AssistantFailure.invalidInput: 'Check your message and try again.',
      AssistantFailure.rejected: "Jarvis couldn't answer that request.",
      AssistantFailure.busy: 'Jarvis is busy. Try again shortly.',
      AssistantFailure.notAvailable: 'Jarvis is not available.',
      AssistantFailure.unavailable: 'Jarvis is temporarily unavailable.',
      AssistantFailure.tooSlow: 'Jarvis took too long to respond.',
      AssistantFailure.network:
          "Couldn't reach Jarvis. Check your connection and try again.",
      AssistantFailure.unexpected: 'Something went wrong. Try again.',
    };

    test('every failure except sessionExpired has a message', () {
      for (final failure in AssistantFailure.values) {
        expect(
          assistantFailureMessage(failure),
          expected[failure],
          reason: failure.name,
        );
      }
    });

    for (final MapEntry(key: failure, value: message) in expected.entries) {
      testWidgets('${failure.name} shows a safe message', (tester) async {
        final api = FakeAssistantApi()
          ..onRespond = (_) => Future.error(assistantError(failure));
        await _open(tester, api: api);

        await _type(tester, 'Hello');
        await tester.tap(_send);
        await tester.pumpAndSettle();

        expect(find.text(message), findsOneWidget);
        expect(_reply, findsNothing);
        expect(_sendEnabled(tester), isTrue);
      });
    }

    testWidgets('no technical or provider text is ever shown', (tester) async {
      final api = FakeAssistantApi();
      await _open(tester, api: api);
      final forbidden = RegExp(
        r'foundry|azure|gpt|model|openai|\b[1-5]\d\d\b|http|exception|'
        r'detail',
        caseSensitive: false,
      );

      Future<void> checkScreen(String label) async {
        final texts = [
          for (final widget in tester.widgetList<Text>(find.byType(Text)))
            widget.data ?? widget.textSpan?.toPlainText() ?? '',
          for (final widget in tester.widgetList<SelectableText>(
            find.byType(SelectableText),
          ))
            widget.data ?? '',
        ].join('\n');
        expect(forbidden.hasMatch(texts), isFalse, reason: '$label: $texts');
      }

      await _type(tester, 'Hello');
      await checkScreen('idle');
      for (final failure in AssistantFailure.values.where(
        (f) => f != AssistantFailure.sessionExpired,
      )) {
        api.onRespond = (_) => Future.error(assistantError(failure));
        await tester.tap(_send);
        await tester.pumpAndSettle();
        await checkScreen(failure.name);
      }
    });
  });

  testWidgets('an expired session goes to login without an assistant error', (
    tester,
  ) async {
    final pending = Completer<String>();
    final api = FakeAssistantApi()..onRespond = (_) => pending.future;
    final (_, store) = await _open(tester, api: api);

    await _type(tester, 'Hello');
    await tester.tap(_send);
    await tester.pump();
    pending.completeError(assistantError(AssistantFailure.sessionExpired));

    // Check every frame on the way to login: no error is ever shown.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(_error, findsNothing);
    }
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('login-email')), findsOneWidget);
    expect(_screen, findsNothing);
    expect(store.session, isNull);
  });

  testWidgets('Back returns to Settings and a reopened screen starts empty', (
    tester,
  ) async {
    await _open(tester);
    await _type(tester, 'Hello');
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(_reply, findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-screen')), findsOneWidget);

    await tester.tap(find.byKey(const Key('developer-text-assistant')));
    await tester.pumpAndSettle();
    expect(_reply, findsNothing);
    expect(find.text('0 / 4000'), findsOneWidget);
  });
}
